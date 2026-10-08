from datetime import timedelta

import httpx
import pytest
from sqlalchemy import delete, select

from app.models import DeviceToken, IntegrationLog, Notification, Order, PushTask, utcnow
from app.push import FCM_ERROR_TYPE, DisabledSender, FcmSender, SendResult, build_message, dispatch_push, enqueue_push, get_sender, token_fingerprint
from app.services import aware, notify


@pytest.fixture(autouse=True)
def isolate_push_credentials(monkeypatch):
    # These tests must not inherit a developer's live Firebase configuration.
    for name in ("FIREBASE_CREDENTIALS", "FIREBASE_CREDENTIALS_JSON", "FIREBASE_PROJECT_ID", "PUSH_ENABLED", "PUSH_MAX_ATTEMPTS"):
        monkeypatch.delenv(name, raising=False)


class FakeSender:
    def __init__(self, *results):
        self.results = list(results)
        self.calls = []

    def send(self, token, message):
        self.calls.append((token, dict(message)))
        if not self.results:
            raise AssertionError("unexpected extra send")
        result = self.results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


def purge_push(db):
    db.execute(delete(PushTask))
    db.execute(delete(DeviceToken))
    db.commit()


def add_device(db, employee_id, token):
    now = utcnow()
    device = DeviceToken(employee_id=employee_id, token=token, platform="android", app_version="1.0.0", created_at=now, last_seen_at=now)
    db.add(device)
    db.commit()
    return device


def make_task(db, employee_id=6, kind="assigned", order_id=None):
    notification = Notification(employee_id=employee_id, title="Новая задача", message="Текст уведомления", kind=kind, order_id=order_id)
    db.add(notification)
    db.flush()
    task = enqueue_push(db, notification)
    db.commit()
    return task


def device_row(db, token):
    return db.scalar(select(DeviceToken).where(DeviceToken.token == token))


def test_device_registration_upsert(client, worker):
    worker_id = client.get("/api/auth/me", headers=worker).json()["id"]
    body = {"token": "device-token-0001", "platform": "android", "app_version": "1.0.0"}
    first = client.post("/api/devices", json=body, headers=worker)
    assert first.status_code == 201, first.text
    created = first.json()
    assert set(created) == {"id", "token", "platform", "app_version", "created_at", "last_seen_at"}
    assert created["token"] == "device-token-0001"
    assert created["app_version"] == "1.0.0"
    assert created["created_at"] == created["last_seen_at"]
    second = client.post("/api/devices", json=body, headers=worker)
    assert second.status_code == 201, second.text
    assert second.json()["id"] == created["id"]
    with client.app.state.sessions() as db:
        rows = list(db.scalars(select(DeviceToken).where(DeviceToken.token == "device-token-0001")))
        assert len(rows) == 1
        assert rows[0].employee_id == worker_id
        assert rows[0].revoked_at is None
    assert client.post("/api/devices", json=body).status_code == 401
    assert client.post("/api/devices", json={"token": "short", "platform": "android"}, headers=worker).status_code == 422
    assert client.post("/api/devices", json={"token": "x" * 4097, "platform": "android"}, headers=worker).status_code == 422
    assert client.post("/api/devices", json={"token": "valid-token-0002", "platform": "ios"}, headers=worker).status_code == 422
    assert client.post("/api/devices", json={"token": "valid-token-0002", "platform": "android", "extra": 1}, headers=worker).status_code == 422


def test_device_unregister_is_idempotent_and_scoped(client, worker, master):
    worker_id = client.get("/api/auth/me", headers=worker).json()["id"]
    token = "device-token-unregister"
    assert client.post("/api/devices", json={"token": token, "platform": "android"}, headers=worker).status_code == 201
    assert client.post("/api/devices/unregister", json={"token": "unknown-token-value"}, headers=worker).json() == {"ok": True}
    assert client.post("/api/devices/unregister", json={"token": token}, headers=master).json() == {"ok": True}
    with client.app.state.sessions() as db:
        assert device_row(db, token).revoked_at is None
    response = client.post("/api/devices/unregister", json={"token": token}, headers=worker)
    assert response.status_code == 200 and response.json() == {"ok": True}
    with client.app.state.sessions() as db:
        revoked = device_row(db, token)
        assert revoked.revoked_at is not None
        assert revoked.employee_id == worker_id
    assert client.post("/api/devices/unregister", json={"token": token}, headers=worker).json() == {"ok": True}
    assert client.post("/api/devices/unregister", json={}, headers=worker).status_code == 422
    assert client.post("/api/devices/unregister", json={"token": token, "extra": 1}, headers=worker).status_code == 422
    assert client.post("/api/devices/unregister", json={"token": token}).status_code == 401


def test_device_reassignment_on_relogin(client, worker, master):
    token = "shared-device-token"
    worker_id = client.get("/api/auth/me", headers=worker).json()["id"]
    master_id = client.get("/api/auth/me", headers=master).json()["id"]
    registered = client.post("/api/devices", json={"token": token, "platform": "android", "app_version": "1.0.0"}, headers=worker)
    assert registered.status_code == 201
    with client.app.state.sessions() as db:
        assert device_row(db, token).employee_id == worker_id
    assert client.post("/api/devices/unregister", json={"token": token}, headers=worker).status_code == 200
    reassigned = client.post("/api/devices", json={"token": token, "platform": "android", "app_version": "2.0.0"}, headers=master)
    assert reassigned.status_code == 201
    assert reassigned.json()["id"] == registered.json()["id"]
    assert reassigned.json()["app_version"] == "2.0.0"
    with client.app.state.sessions() as db:
        row = device_row(db, token)
        assert row.employee_id == master_id
        assert row.revoked_at is None


def test_order_assignment_enqueues_push_task(client, master):
    payload = {"title": "Проверка push-очереди", "description": "Наряд для проверки outbox", "work_type": "planned", "area_id": 1, "equipment_id": 3, "assignee_id": 6, "priority": "emergency", "deadline": (utcnow() + timedelta(hours=4)).isoformat()}
    response = client.post("/api/orders", json=payload, headers=master)
    assert response.status_code == 201, response.text
    order_id = response.json()["id"]
    with client.app.state.sessions() as db:
        task = db.scalar(select(PushTask).where(PushTask.order_id == order_id))
        assert task is not None
        assert task.employee_id == 6
        assert task.status == "pending"
        assert task.attempts == 0
        assert task.priority == "high"
        assert aware(task.next_attempt_at) <= utcnow()
        assert task.notification_id is not None
        notification = db.get(Notification, task.notification_id)
        assert notification is not None
        assert notification.employee_id == 6
        assert notification.order_id == order_id
        assert task.payload["data"]["order_id"] == str(order_id)
        assert task.payload["android"]["notification"]["channel_id"] == "naryad_emergency"


def test_notify_push_task_lives_in_same_transaction(client):
    with client.app.state.sessions() as db:
        assert notify(db, [6], "До срока менее 30 минут", "Сообщение монитора", "due_soon", None) == 1
        task = db.scalar(select(PushTask).where(PushTask.employee_id == 6, PushTask.kind == "due_soon"))
        assert task is not None
        assert task.status == "pending"
        assert task.notification_id is not None
        db.rollback()
        assert db.scalar(select(PushTask).where(PushTask.employee_id == 6, PushTask.kind == "due_soon")) is None
        assert db.scalar(select(Notification).where(Notification.kind == "due_soon", Notification.employee_id == 6)) is None


def test_build_message_channels_and_data():
    notification = Notification(id=42, employee_id=6, title="Заголовок", message="Текст", kind="assigned", order_id=None)
    message = build_message(notification)
    assert message["token"] == ""
    assert message["data"] == {"order_id": "", "notification_id": "42", "kind": "assigned", "emergency": "false", "route": "order"}
    assert message["android"]["priority"] == "normal"
    assert message["android"]["notification"] == {"channel_id": "naryad_default", "sound": "default", "title": "Заголовок", "body": "Текст", "click_action": "FLUTTER_NOTIFICATION_CLICK"}
    assert message["notification"] == {"title": "Заголовок", "body": "Текст"}
    unassigned = Notification(id=43, employee_id=6, title="Т", message="М", kind="unassigned", order_id=1)
    emergency = build_message(unassigned)
    assert emergency["data"]["emergency"] == "true"
    assert emergency["android"]["priority"] == "high"
    assert emergency["android"]["notification"]["channel_id"] == "naryad_emergency"
    order = Order(id=7, priority="emergency")
    linked = build_message(notification, order, token="device-token")
    assert linked["token"] == "device-token"
    assert linked["data"]["order_id"] == "7"
    assert linked["android"]["priority"] == "high"
    assert linked["android"]["notification"]["channel_id"] == "naryad_emergency"
    calm = Order(id=8, priority="normal")
    assert build_message(notification, calm)["android"]["priority"] == "normal"


def test_dispatch_success_marks_sent(client):
    with client.app.state.sessions() as db:
        purge_push(db)
        add_device(db, 6, "token-success")
        task = make_task(db, 6)
        sender = FakeSender(SendResult(ok=True, provider_message_id="projects/km/messages/abc"))
        assert dispatch_push(db, sender) == 1
        assert task.status == "sent"
        assert task.sent_at is not None
        assert task.provider_message_id == "projects/km/messages/abc"
        assert [token for token, _ in sender.calls] == ["token-success"]
        assert sender.calls[0][1]["token"] == "token-success"
        trace = db.scalar(select(IntegrationLog).where(IntegrationLog.adapter == "fcm", IntegrationLog.operation == "push_sent"))
        assert trace is not None
        assert "token" not in trace.payload
        assert trace.payload["token_fingerprint"] == token_fingerprint("token-success")
        assert device_row(db, "token-success").revoked_at is None


def test_dispatch_invalid_token_revokes_and_tries_next(client):
    with client.app.state.sessions() as db:
        purge_push(db)
        add_device(db, 6, "token-invalid")
        add_device(db, 6, "token-valid")
        task = make_task(db, 6)
        sender = FakeSender(SendResult(ok=False, invalid_token=True, error="UNREGISTERED"), SendResult(ok=True, provider_message_id="projects/km/messages/ok"))
        assert dispatch_push(db, sender) == 1
        assert [token for token, _ in sender.calls] == ["token-invalid", "token-valid"]
        assert device_row(db, "token-invalid").revoked_at is not None
        assert device_row(db, "token-valid").revoked_at is None
        assert task.status == "sent"
        assert task.provider_message_id == "projects/km/messages/ok"


def test_dispatch_without_devices_fails(client):
    with client.app.state.sessions() as db:
        purge_push(db)
        task = make_task(db, 6)
        sender = FakeSender()
        assert dispatch_push(db, sender) == 0
        assert sender.calls == []
        assert task.status == "failed"
        assert task.last_error == "no_active_device"


def test_dispatch_transient_error_reschedules(client):
    with client.app.state.sessions() as db:
        purge_push(db)
        add_device(db, 6, "token-transient")
        task = make_task(db, 6)
        failing = FakeSender(SendResult(ok=False, error="backend unavailable"), SendResult(ok=False, error="backend unavailable"))
        assert dispatch_push(db, failing) == 0
        assert task.status == "pending"
        assert task.attempts == 1
        assert task.last_error == "backend unavailable"
        assert aware(task.next_attempt_at) > utcnow()
        waiting = FakeSender()
        assert dispatch_push(db, waiting) == 0
        assert waiting.calls == []
        task.next_attempt_at = utcnow() - timedelta(seconds=1)
        db.commit()
        assert dispatch_push(db, failing) == 0
        assert task.attempts == 2
        assert task.status == "pending"
        assert aware(task.next_attempt_at) > utcnow()


def test_dispatch_stops_after_max_attempts(client, monkeypatch):
    monkeypatch.setenv("PUSH_MAX_ATTEMPTS", "3")
    with client.app.state.sessions() as db:
        purge_push(db)
        add_device(db, 6, "token-exhaust")
        task = make_task(db, 6)
        task.attempts = 2
        db.commit()
        sender = FakeSender(SendResult(ok=False, error="still down"))
        assert dispatch_push(db, sender) == 0
        assert len(sender.calls) == 1
        assert task.attempts == 3
        assert task.status == "failed"
        assert task.last_error == "still down"


def test_disabled_sender_does_not_mark_delivery_as_success(client, monkeypatch):
    monkeypatch.delenv("FIREBASE_CREDENTIALS", raising=False)
    monkeypatch.setenv("PUSH_ENABLED", "true")
    assert isinstance(get_sender(), DisabledSender)
    with client.app.state.sessions() as db:
        purge_push(db)
        add_device(db, 6, "token-disabled")
        task = make_task(db, 6)
        assert dispatch_push(db) == 0
        assert task.status == "pending"
        assert task.provider_message_id is None
        assert task.attempts == 0
        assert db.scalar(select(IntegrationLog).where(IntegrationLog.adapter == "fcm", IntegrationLog.operation == "push_not_sent")) is None


def test_get_sender_configuration(monkeypatch, tmp_path):
    monkeypatch.delenv("FIREBASE_CREDENTIALS", raising=False)
    monkeypatch.delenv("PUSH_ENABLED", raising=False)
    assert isinstance(get_sender(), DisabledSender)
    monkeypatch.setenv("FIREBASE_CREDENTIALS", str(tmp_path / "missing.json"))
    assert isinstance(get_sender(), DisabledSender)
    credentials = tmp_path / "service-account.json"
    credentials.write_text("{}")
    monkeypatch.setenv("FIREBASE_CREDENTIALS", str(credentials))
    # Merely placing credentials on disk must never enable real delivery.
    assert isinstance(get_sender(), DisabledSender)
    monkeypatch.setenv("PUSH_ENABLED", "true")
    sender = get_sender()
    assert isinstance(sender, FcmSender)
    assert sender.project_id == "km-case-hack"
    assert not hasattr(sender, "_credentials") or sender._credentials is None
    monkeypatch.setenv("PUSH_ENABLED", "false")
    assert isinstance(get_sender(), DisabledSender)
    monkeypatch.setenv("PUSH_ENABLED", "0")
    assert isinstance(get_sender(), DisabledSender)
    monkeypatch.setenv("PUSH_ENABLED", "unexpected")
    assert isinstance(get_sender(), DisabledSender)


def test_integrations_only_report_real_native_and_realtime_status(client, master, monkeypatch):
    monkeypatch.delenv("FIREBASE_CREDENTIALS", raising=False)
    monkeypatch.setenv("PUSH_ENABLED", "true")
    data = client.get("/api/integrations", headers=master).json()
    assert data["native"] == {"mode": "disabled", "status": "not_configured", "description": "Push отключён или не настроен. События сохраняются в БД; отправки на устройства нет."}
    assert set(data) == {"native", "realtime"}
    assert data["realtime"] == {"mode": "websocket", "status": "active", "description": "Авторизованный WebSocket и резервный опрос каждые 5 секунд."}


def test_integrations_native_fcm_when_configured(client, master, tmp_path, monkeypatch):
    credentials = tmp_path / "firebase.json"
    credentials.write_text("{}")
    monkeypatch.setenv("FIREBASE_CREDENTIALS", str(credentials))
    monkeypatch.setenv("PUSH_ENABLED", "true")
    data = client.get("/api/integrations", headers=master).json()
    assert data["native"] == {"mode": "fcm", "status": "configured", "description": "Firebase Cloud Messaging (HTTP v1) настроен для Android. Успешная доставка зависит от регистрации устройства и ответа FCM."}
    monkeypatch.setenv("PUSH_ENABLED", "false")
    assert client.get("/api/integrations", headers=master).json()["native"]["mode"] == "disabled"


@pytest.mark.parametrize("http_status,error,invalid_token", [
    (400, {"status": "INVALID_ARGUMENT", "message": "Invalid message.data value", "details": [{"@type": "type.googleapis.com/google.rpc.BadRequest", "fieldViolations": [{"field": "message.data"}]}]}, False),
    (404, {"status": "NOT_FOUND", "message": "Firebase project does not exist"}, False),
    (404, {"status": "NOT_FOUND", "message": "Requested entity was not found", "details": [{"@type": FCM_ERROR_TYPE, "errorCode": "UNREGISTERED"}]}, True),
    (400, {"status": "INVALID_ARGUMENT", "message": "The registration token is not a valid FCM registration token", "details": [{"@type": FCM_ERROR_TYPE, "errorCode": "INVALID_ARGUMENT"}]}, True),
    (400, {"status": "INVALID_ARGUMENT", "message": "Message too big", "details": [{"@type": FCM_ERROR_TYPE, "errorCode": "INVALID_ARGUMENT"}]}, False),
])
def test_fcm_revokes_only_explicit_device_token_errors(monkeypatch, http_status, error, invalid_token):
    sender = FcmSender("fake-project")
    monkeypatch.setattr(sender, "_access_token", lambda: "fake-access-token")
    response = httpx.Response(http_status, json={"error": error})
    monkeypatch.setattr("app.push.httpx.post", lambda *args, **kwargs: response)
    result = sender.send("valid-device-token", {"notification": {"title": "Test"}})
    assert result.ok is False
    assert result.invalid_token is invalid_token


def test_failed_delivery_trace_redacts_device_token(client):
    with client.app.state.sessions() as db:
        purge_push(db)
        token = "sensitive-fcm-device-token"
        add_device(db, 6, token)
        task = make_task(db, 6)
        sender = FakeSender(SendResult(ok=False, error=f"Delivery rejected for {token}"))
        assert dispatch_push(db, sender) == 0
        assert token not in task.last_error
        trace = db.scalar(select(IntegrationLog).where(IntegrationLog.adapter == "fcm", IntegrationLog.operation == "push_failed").order_by(IntegrationLog.id.desc()))
        assert trace is not None
        assert "token" not in trace.payload
        assert trace.payload["token_fingerprint"] == token_fingerprint(token)
        assert token not in str(trace.payload)
