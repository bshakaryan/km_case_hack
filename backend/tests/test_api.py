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


def test_worker_owns_acceptance_and_queue_order_is_automatic(client, master, worker):
    first = new_order(client, master, priority="normal")
    path = f"/api/orders/{first['id']}"
    assert client.post(path + "/transition", json={"action": "accept"}, headers=master).status_code == 403
    accepted = client.post(path + "/transition", json={"action": "accept"}, headers=worker).json()
    assert accepted["status"] == "accepted" and accepted["queue_position"] == 1
    assert client.post(path + "/transition", json={"action": "start"}, headers=master).status_code == 403
    report = {"work_done": "Отчёт не должен приниматься мастером", "fault_code_id": 1, "materials": []}
    assert client.post(path + "/complete", json=report, headers=master).status_code == 403

    second = new_order(client, master, priority="normal")
    second_path = f"/api/orders/{second['id']}"
    assert client.post(second_path + "/transition", json={"action": "accept"}, headers=worker).status_code == 409
    assert client.post(second_path + "/transition", json={"action": "queue"}, headers=master).status_code == 403
    assert client.post(path + "/transition", json={"action": "start"}, headers=worker).json()["status"] == "in_progress"
    queued = client.post(second_path + "/transition", json={"action": "queue"}, headers=worker).json()
    assert queued["status"] == "queued" and queued["queue_position"] == 1
    repeated_queue = client.post(second_path + "/transition", json={"action": "queue"}, headers=worker)
    assert repeated_queue.status_code == 200 and repeated_queue.json()["status"] == "queued"

    emergency = new_order(client, master, priority="emergency")
    emergency_path = f"/api/orders/{emergency['id']}"
    assert client.post(emergency_path + "/transition", json={"action": "accept"}, headers=worker).status_code == 409
    queued_emergency = client.post(emergency_path + "/transition", json={"action": "queue"}, headers=worker).json()
    assert queued_emergency["status"] == "queued" and queued_emergency["queue_position"] == 1
    assert client.get(second_path, headers=worker).json()["queue_position"] == 2
    deferred_start = client.post(emergency_path + "/transition", json={"action": "start"}, headers=worker)
    assert deferred_start.status_code == 409
    assert client.get(emergency_path, headers=worker).json()["status"] == "queued"
    worker_id = client.get("/api/auth/me", headers=worker).json()["id"]
    worker_row = next(item for item in client.get("/api/employees", headers=master).json() if item["id"] == worker_id)
    assert worker_row["current_order"] == first["number"] and worker_row["queue_count"] == 2

    assert client.post(path + "/transition", json={"action": "pause", "reason": "Освободить пост"}, headers=worker).status_code == 200
    blocked = client.post(second_path + "/transition", json={"action": "start"}, headers=worker)
    assert blocked.status_code == 409 and first["number"] in blocked.json()["detail"]
    paused_start = client.post(emergency_path + "/transition", json={"action": "start"}, headers=worker)
    assert paused_start.status_code == 409
    assert client.post(path + "/transition", json={"action": "cancel", "reason": "Освободить наряд теста"}, headers=master).status_code == 200
    started = client.post(emergency_path + "/transition", json={"action": "start"}, headers=worker)
    assert started.status_code == 200 and started.json()["status"] == "in_progress"
    lower_priority_start = client.post(second_path + "/transition", json={"action": "start"}, headers=worker)
    assert lower_priority_start.status_code == 409
    assert client.post(emergency_path + "/transition", json={"action": "cancel", "reason": "Очистка теста очереди"}, headers=master).status_code == 200
    assert client.post(second_path + "/transition", json={"action": "start"}, headers=worker).json()["status"] == "in_progress"
    cancelled = client.post(f"/api/orders/{second['id']}/transition", json={"action": "cancel", "reason": "Очистка теста очереди"}, headers=master)
    assert cancelled.status_code == 200


def test_legacy_multiple_accepts_are_exposed_as_queue_without_data_rewrite(client, master, worker):
    normal = new_order(client, master, priority="normal")
    high = new_order(client, master, priority="high")
    emergency = new_order(client, master, priority="emergency")
    with client.app.state.sessions() as db:
        for record in (normal, high, emergency):
            db.get(Order, record["id"]).status = "accepted"
        db.commit()

    response = client.get("/api/orders", headers=worker)
    assert response.status_code == 200
    by_id = {item["id"]: item for item in response.json()}
    assert by_id[emergency["id"]]["status"] == "accepted"
    assert by_id[emergency["id"]]["queue_position"] == 1
    assert by_id[high["id"]]["status"] == "queued"
    assert by_id[high["id"]]["queue_position"] == 2
    assert by_id[normal["id"]]["status"] == "queued"
    assert by_id[normal["id"]]["queue_position"] == 3
    filtered_queue = client.get("/api/orders?status=queued", headers=worker).json()
    assert {item["id"] for item in filtered_queue} >= {normal["id"], high["id"]}
    filtered_accepted = client.get("/api/orders?status=accepted", headers=worker).json()
    assert emergency["id"] in {item["id"] for item in filtered_accepted}
    assert normal["id"] not in {item["id"] for item in filtered_accepted}
    with client.app.state.sessions() as db:
        assert [db.get(Order, item["id"]).status for item in (normal, high, emergency)] == ["accepted"] * 3
    for record in (normal, high, emergency):
        assert client.post(f"/api/orders/{record['id']}/transition", json={"action": "cancel", "reason": "Очистка проверки очереди"}, headers=master).status_code == 200


def test_legacy_paused_jobs_can_be_resumed_one_at_a_time(client, master, worker):
    first = new_order(client, master)
    second = new_order(client, master)
    with client.app.state.sessions() as db:
        for record in (first, second):
            order = db.get(Order, record["id"])
            order.status = "paused"
            order.started_at = utcnow() - timedelta(minutes=5)
        db.commit()

    resumed = client.post(f"/api/orders/{first['id']}/transition", json={"action": "resume"}, headers=worker)
    assert resumed.status_code == 200 and resumed.json()["status"] == "in_progress"
    blocked = client.post(f"/api/orders/{second['id']}/transition", json={"action": "resume"}, headers=worker)
    assert blocked.status_code == 409 and first["number"] in blocked.json()["detail"]
    for record in (first, second):
        assert client.post(f"/api/orders/{record['id']}/transition", json={"action": "cancel", "reason": "Очистка проверки возобновления"}, headers=master).status_code == 200


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
        emergency.assigned_at = now - timedelta(minutes=4)
        normal = db.get(Order, second["id"])
        normal.created_at = now - timedelta(minutes=4)
        normal.assigned_at = now - timedelta(minutes=4)
        normal.deadline = now - timedelta(minutes=2)
        finished = db.get(Order, third["id"])
        finished.status = "ai_review"
        finished.deadline = now - timedelta(hours=1)
        db.commit()
        assert monitor_deadlines(db, now) > 0
        assert monitor_deadlines(db, now) == 0
        assert len(list(db.scalars(select(Notification).where(Notification.order_id == first["id"], Notification.kind == "unaccepted")))) == 2
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
