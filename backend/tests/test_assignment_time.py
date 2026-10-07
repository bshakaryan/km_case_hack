from datetime import datetime, timedelta

import pytest
from sqlalchemy import select

from app import main as main_module
from app.models import Notification, Order, utcnow
from app.services import monitor_deadlines


def create_order(client, master, priority="normal", deadline=None):
    response = client.post("/api/orders", headers=master, json={"title": "Проверка времени назначения",
        "description": "Синтетическая проверка таймера", "work_type": "planned", "area_id": 1,
        "equipment_id": 3, "assignee_id": 6, "priority": priority,
        "deadline": (deadline or (utcnow() + timedelta(hours=4))).isoformat()})
    assert response.status_code == 201, response.text
    return response.json()


def unaccepted(db, order_id):
    return list(db.scalars(select(Notification).where(Notification.order_id == order_id, Notification.kind == "unaccepted")))


@pytest.mark.parametrize("priority,threshold", [("normal", 10), ("emergency", 3)])
@pytest.mark.parametrize("assignee", [5, 6])
def test_reassignment_renews_acceptance_timer_and_dedupe_even_for_same_worker(client, master, monkeypatch, priority, threshold, assignee):
    order = create_order(client, master, priority)
    path = f"/api/orders/{order['id']}"
    now = utcnow()
    original_created = now - timedelta(hours=2)
    with client.app.state.sessions() as db:
        stored = db.get(Order, order["id"])
        stored.created_at = original_created
        stored.assigned_at = now - timedelta(minutes=threshold + 1)
        db.commit()
        monitor_deadlines(db, now)
        assert len(unaccepted(db, order["id"])) == 2
    monkeypatch.setattr(main_module, "utcnow", lambda: now)
    renewed = client.patch(path, json={"assignee_id": assignee}, headers=master)
    assert renewed.status_code == 200, renewed.text
    assert datetime.fromisoformat(renewed.json()["assigned_at"]) == now
    assert datetime.fromisoformat(renewed.json()["created_at"]) == original_created
    with client.app.state.sessions() as db:
        monitor_deadlines(db, now + timedelta(minutes=threshold) - timedelta(microseconds=1))
        assert len(unaccepted(db, order["id"])) == 2
        monitor_deadlines(db, now + timedelta(minutes=threshold))
        assert len(unaccepted(db, order["id"])) == 4
        assert monitor_deadlines(db, now + timedelta(minutes=threshold)) == 0
    # The clock is deliberately identical; every explicit reassignment still
    # needs a distinct timestamp/key, including another assignment to that worker.
    again = client.patch(path, json={"assignee_id": assignee}, headers=master)
    assert again.status_code == 200
    assert datetime.fromisoformat(again.json()["assigned_at"]) == now + timedelta(microseconds=1)
    with client.app.state.sessions() as db:
        monitor_deadlines(db, now + timedelta(minutes=threshold))
        assert len(unaccepted(db, order["id"])) == 4
        monitor_deadlines(db, now + timedelta(minutes=threshold, microseconds=1))
        notifications = unaccepted(db, order["id"])
        assert len(notifications) == 6
        assert len({item.dedupe_key for item in notifications}) == 6
        assert all(len(item.dedupe_key) <= 180 for item in notifications)


def test_deadline_edit_keeps_assignment_time_and_deadline_notifications_dedupe(client, master, monkeypatch):
    now = utcnow()
    monkeypatch.setattr(main_module, "utcnow", lambda: now)
    order = create_order(client, master, deadline=now + timedelta(minutes=20))
    assert order["assigned_at"] == order["created_at"]
    path = f"/api/orders/{order['id']}"
    with client.app.state.sessions() as db:
        monitor_deadlines(db, now)
    renewed = client.patch(path, json={"assignee_id": 6}, headers=master).json()
    with client.app.state.sessions() as db:
        monitor_deadlines(db, now + timedelta(minutes=1))
        assert len(list(db.scalars(select(Notification).where(Notification.order_id == order["id"], Notification.kind == "due_soon")))) == 2
    changed = client.patch(path, json={"deadline": (now + timedelta(minutes=25)).isoformat()}, headers=master)
    assert changed.status_code == 200
    assert changed.json()["assigned_at"] == renewed["assigned_at"]
    assert changed.json()["created_at"] == order["created_at"]
    with client.app.state.sessions() as db:
        monitor_deadlines(db, now + timedelta(minutes=2))
        assert len(list(db.scalars(select(Notification).where(Notification.order_id == order["id"], Notification.kind == "due_soon")))) == 4


def test_invalid_reassignment_rolls_back_assignment_time_and_notifications(client, master):
    order = create_order(client, master)
    path = f"/api/orders/{order['id']}"
    with client.app.state.sessions() as db:
        before_count = len(list(db.scalars(select(Notification).where(Notification.order_id == order["id"], Notification.kind == "assigned"))))
    rejected = client.patch(path, json={"assignee_id": 5, "deadline": (utcnow() - timedelta(hours=1)).isoformat()}, headers=master)
    assert rejected.status_code == 422
    after = client.get(path, headers=master).json()
    assert after["assignee_id"] == order["assignee_id"]
    assert after["assigned_at"] == order["assigned_at"]
    with client.app.state.sessions() as db:
        assert len(list(db.scalars(select(Notification).where(Notification.order_id == order["id"], Notification.kind == "assigned")))) == before_count
