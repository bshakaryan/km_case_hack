import io
from datetime import timedelta
from PIL import Image
from sqlalchemy import func, select
from app.models import AIAssessment, AuthSession, Employee, IntegrationLog, MaterialWriteoff, Notification, Order, OrderEvent, utcnow
from app.services import monitor_deadlines
from conftest import auth_headers


def new_order(client, master, **kwargs):
    payload = {"title": "Проверка ремонтного узла", "description": "Проверка наряда в тесте", "work_type": "planned", "area_id": 1, "equipment_id": 3, "assignee_id": 6, "priority": "normal", "deadline": (utcnow() + timedelta(hours=4)).isoformat(), **kwargs}
    response = client.post("/api/orders", json=payload, headers=master)
    assert response.status_code == 201, response.text
    return response.json()


def photo_bytes():
    output = io.BytesIO()
    Image.new("RGB", (40, 30), "green").save(output, format="PNG")
    return output.getvalue()


def test_seed_and_authentication(client, master):
    assert client.get("/api/health").json()["database"] == "connected"
    assert client.get("/api/orders").status_code == 401
    assert client.post("/api/auth/login", json={"login": "master", "pin": "0000"}).status_code == 401
    reference = client.get("/api/reference", headers=master).json()
    assert len(reference["areas"]) == 4
    assert len(reference["equipment"]) == 25
    assert len(reference["fault_codes"]) == 20
    assert len(reference["materials"]) == 40
    assert len([p for p in reference["employees"] if p["role"] == "worker"]) == 15
    orders = client.get("/api/orders", headers=master).json()
    assert len(orders) >= 550
    with client.app.state.sessions() as db:
        assert db.get(Employee, 1).pin_hash.startswith("pbkdf2_sha256$")
        assert db.scalar(select(AuthSession.token_hash)) != master["Authorization"][7:]
        assert db.scalar(select(func.count()).select_from(MaterialWriteoff)) >= 540
        assert db.scalar(select(func.count()).select_from(AIAssessment)) >= 540


def test_full_lifecycle_requires_master_decision(client, master, worker):
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    assert client.post(path + "/transition", json={"action": "start"}, headers=worker).status_code == 409
    assert client.post(path + "/transition", json={"action": "accept"}, headers=worker).json()["status"] == "accepted"
    assert client.post(path + "/transition", json={"action": "start"}, headers=worker).json()["status"] == "in_progress"
    assert client.post(path + "/transition", json={"action": "pause"}, headers=worker).status_code == 422
    assert client.post(path + "/transition", json={"action": "pause", "reason": "Нет допуска"}, headers=worker).json()["status"] == "paused"
    assert client.post(path + "/transition", json={"action": "resume"}, headers=worker).json()["status"] == "in_progress"
    completed = client.post(path + "/complete", json={"work_done": "Заменен узел и проверен под нагрузкой", "fault_code_id": 1, "materials": [{"material_id": 1, "quantity": 2}]}, headers=worker)
    assert completed.status_code == 200, completed.text
    assert completed.json()["status"] == "ai_review"
    assert completed.json()["ai_review"]["is_stub"] is True
    assert completed.json()["score"] is None
    assert client.post(path + "/transition", json={"action": "close", "score": 5}, headers=worker).status_code == 403
    assert client.post(path + "/transition", json={"action": "close"}, headers=master).status_code == 422
    closed = client.post(path + "/transition", json={"action": "close", "score": 4.5}, headers=master).json()
    assert closed["status"] == "closed"
    assert closed["score"] == 4.5
    assert closed["ai_review"]["master_score"] == 4.5
    assert len(closed["events"]) >= 8
    assert client.patch(path, json={"priority": "high"}, headers=master).status_code == 409


def test_unplanned_photos_and_upload_validation(client, master, worker):
    order = new_order(client, master, work_type="unplanned")
    path = f"/api/orders/{order['id']}"
    client.post(path + "/transition", json={"action": "accept"}, headers=worker)
    # Before photos are optional in the case; after photos are mandatory.
    assert client.post(path + "/photos", data={"kind": "before"}, files={"file": ("bad.jpg", b"not an image", "image/jpeg")}, headers=worker).status_code == 422
    before = client.post(path + "/photos", data={"kind": "before"}, files={"file": ("before.png", photo_bytes(), "image/png")}, headers=worker)
    assert before.status_code == 201, before.text
    url = before.json()["url"]
    assert client.get(url).status_code == 401
    assert client.get(url, headers=worker).headers["content-type"] == "image/jpeg"
    assert client.post(path + "/transition", json={"action": "start"}, headers=worker).status_code == 200
    completion = {"work_done": "Выполнена замена изношенного подшипника", "fault_code_id": 1, "materials": []}
    assert client.post(path + "/complete", json=completion, headers=worker).status_code == 422
    assert client.post(path + "/photos", data={"kind": "after"}, files={"file": ("after.png", photo_bytes(), "image/png")}, headers=worker).status_code == 201
    result = client.post(path + "/complete", json=completion, headers=worker).json()
    assert result["status"] == "ai_review"
    assert result["ai_review"]["verdict"] == "passed"
    assert client.post(path + "/transition", json={"action": "rework", "reason": "Проверить затяжку"}, headers=master).json()["status"] == "rework"


def test_permissions_and_assignment_validation(client, master, worker):
    manager = auth_headers(client, "manager")
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    assert client.post(path + "/transition", json={"action": "accept"}, headers=manager).status_code == 403
    other = auth_headers(client, "worker3")
    assert client.get(path, headers=other).status_code == 403
    assert client.post(path + "/transition", json={"action": "accept"}, headers=other).status_code == 403
    assert client.patch(path, json={"assignee_id": 3}, headers=master).status_code == 422
    assert client.patch(path, json={"assignee_id": None}, headers=master).status_code == 422
    assert client.patch(path, json={"deadline": "2026-01-01T10:00:00"}, headers=master).status_code == 422
    assert client.patch(path, json={"priority": "high"}, headers=worker).status_code == 403
    assert client.post(path + "/transition", json={"action": "cancel", "reason": "Дубликат"}, headers=master).json()["status"] == "cancelled"


def test_deadline_monitor_thresholds_deduplication_and_finished_exclusion(client, master):
    first = new_order(client, master, priority="emergency")
    second = new_order(client, master)
    third = new_order(client, master)
    now = utcnow()
    with client.app.state.sessions() as db:
        emergency = db.get(Order, first["id"])
        emergency.created_at = now - timedelta(minutes=4)
        db.scalar(select(OrderEvent).where(OrderEvent.order_id == emergency.id, OrderEvent.action == "issue")).created_at = emergency.created_at
        normal = db.get(Order, second["id"])
        normal.created_at = now - timedelta(minutes=4)
        db.scalar(select(OrderEvent).where(OrderEvent.order_id == normal.id, OrderEvent.action == "issue")).created_at = normal.created_at
        normal.deadline = now - timedelta(minutes=2)
        finished = db.get(Order, third["id"])
        finished.status = "ai_review"
        finished.deadline = now - timedelta(hours=1)
        db.commit()
        assert monitor_deadlines(db, now) > 0
        assert monitor_deadlines(db, now) == 0
        assert len(list(db.scalars(select(Notification).where(Notification.order_id == first["id"], Notification.kind == "unaccepted")))) == 1
        assert not db.scalar(select(Notification).where(Notification.order_id == second["id"], Notification.kind == "unaccepted"))
        assert not db.scalar(select(Notification).where(Notification.order_id == third["id"], Notification.kind.in_(["overdue", "due_soon", "unaccepted"])))
        assert db.scalar(select(IntegrationLog).where(IntegrationLog.adapter == "native_stub"))
    assert not client.get(f"/api/orders/{third['id']}", headers=master).json()["is_overdue"]


def test_analytics_real_filters_csv_xlsx_and_websocket(client, master):
    report = client.get("/api/analytics", headers=master).json()
    assert report["summary"]["total"] >= 540
    assert len(report["trend"]) >= 90
    assert report["rankings"]
    assert report["is_stub"]
    filtered = client.get("/api/analytics?area_id=4", headers=master).json()
    assert filtered["summary"]["total"] < report["summary"]["total"]
    assert client.get("/api/analytics?from_date=bad", headers=master).status_code == 422
    assert client.get("/api/reports/export", headers=master).content.startswith(b"\xef\xbb\xbf")
    assert client.get("/api/reports/export?format=xlsx", headers=master).content.startswith(b"PK")
    with client.websocket_connect("/api/ws?token=" + master["Authorization"][7:]) as ws:
        assert ws.receive_json() == {"type": "connected"}
        order = new_order(client, master)
        assert ws.receive_json() == {"type": "orders.updated", "order_id": order["id"]}


def test_active_downtime_grows_and_stops_at_completion(client, master):
    order = new_order(client, master, work_type="unplanned")
    with client.app.state.sessions() as db:
        record = db.get(Order, order["id"])
        record.created_at = utcnow() - timedelta(minutes=20)
        db.commit()
    active = client.get(f"/api/orders/{order['id']}", headers=master).json()
    assert 19.9 <= active["downtime_minutes"] <= 20.1
    cancelled = client.post(f"/api/orders/{order['id']}/transition", json={"action": "cancel", "reason": "Оборудование исправно"}, headers=master).json()
    assert 19.9 <= cancelled["downtime_minutes"] <= 20.1
