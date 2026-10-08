from datetime import timedelta

from sqlalchemy import select

from app.models import Notification, Order, OrderEvent, utcnow
from app.services import monitor_deadlines


def create_order(client, master, deadline, priority="normal"):
    response = client.post(
        "/api/orders",
        json={
            "title": "Устранить неисправность насоса",
            "description": "Устранить течь на насосе и проверить герметичность",
            "work_type": "unplanned",
            "area_id": 1,
            "equipment_id": 3,
            "assignee_id": 6,
            "priority": priority,
            "deadline": deadline.isoformat(),
        },
        headers=master,
    )
    assert response.status_code == 201, response.text
    return response.json()


def alerts(db, order_id, kind):
    return list(db.scalars(select(Notification).where(Notification.order_id == order_id, Notification.kind == kind).order_by(Notification.id)))


def test_deadline_reminders_repeats_and_manager_escalation(client, master, monkeypatch):
    monkeypatch.setenv("DUE_SOON_MINUTES", "30")
    monkeypatch.setenv("REMINDER_REPEAT_MINUTES", "30")
    monkeypatch.setenv("MANAGER_ESCALATION_MINUTES", "60")
    now = utcnow()
    order = create_order(client, master, now + timedelta(minutes=20))
    with client.app.state.sessions() as db:
        assert monitor_deadlines(db, now) >= 1
        assert [alert.employee_id for alert in alerts(db, order["id"], "due_soon")] == [6]
        monitor_deadlines(db, now + timedelta(minutes=1))
        assert len(alerts(db, order["id"], "due_soon")) == 1

        record = db.get(Order, order["id"])
        record.deadline = now - timedelta(minutes=70)
        record.status = "in_progress"
        record.started_at = now - timedelta(minutes=80)
        db.add(OrderEvent(order_id=record.id, action="start", from_status="accepted", to_status="in_progress", actor_id=6, created_at=now - timedelta(minutes=65), comment="ждём подшипник со склада"))
        db.commit()

        monitor_deadlines(db, now)
        overdue = alerts(db, order["id"], "overdue")
        assert {alert.employee_id for alert in overdue} == {1, 6}
        assert "Оборудование:" in overdue[0].message
        assert "участок:" in overdue[0].message
        assert "Статус: в работе" in overdue[0].message
        assert "Просрочка: 70 мин" in overdue[0].message
        assert "ждём подшипник со склада" in overdue[0].message
        assert [alert.employee_id for alert in alerts(db, order["id"], "overdue_escalated")] == [3]
        monitor_deadlines(db, now + timedelta(minutes=15))
        assert len(alerts(db, order["id"], "overdue")) == 2
        monitor_deadlines(db, now + timedelta(minutes=31))
        assert len(alerts(db, order["id"], "overdue")) == 4
        assert len(alerts(db, order["id"], "overdue_escalated")) == 1


def test_unaccepted_thresholds_replacement_and_reassignment(client, master, monkeypatch):
    monkeypatch.setenv("REMINDER_REPEAT_MINUTES", "30")
    monkeypatch.setenv("EMERGENCY_ACCEPT_MINUTES", "3")
    monkeypatch.setenv("ACCEPT_MINUTES", "10")
    now = utcnow()
    emergency = create_order(client, master, now + timedelta(hours=4), priority="emergency")
    normal = create_order(client, master, now + timedelta(hours=4))
    with client.app.state.sessions() as db:
        for order_id in (emergency["id"], normal["id"]):
            issue = db.scalar(select(OrderEvent).where(OrderEvent.order_id == order_id, OrderEvent.action == "issue"))
            issue.created_at = now - timedelta(minutes=4)
        db.commit()
        monitor_deadlines(db, now)
        emergency_alerts = alerts(db, emergency["id"], "unaccepted")
        assert len(emergency_alerts) == 1
        assert emergency_alerts[0].employee_id == 1
        assert "Предложение замены:" in emergency_alerts[0].message
        assert not alerts(db, normal["id"], "unaccepted")
        monitor_deadlines(db, now + timedelta(minutes=7))
        assert len(alerts(db, emergency["id"], "unaccepted")) == 1
        assert len(alerts(db, normal["id"], "unaccepted")) == 1

    response = client.patch(f"/api/orders/{emergency['id']}", json={"assignee_id": 6}, headers=master)
    assert response.status_code == 200, response.text
    with client.app.state.sessions() as db:
        monitor_deadlines(db, now + timedelta(minutes=2))
        assert len(alerts(db, emergency["id"], "unaccepted")) == 1
        monitor_deadlines(db, now + timedelta(minutes=11))
        assert len(alerts(db, emergency["id"], "unaccepted")) == 2
