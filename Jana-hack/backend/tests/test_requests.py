"""End-to-end commands and effects; SQLite races do not prove PostgreSQL locking."""
from concurrent.futures import ThreadPoolExecutor
from datetime import date
from threading import Barrier

import pytest
from sqlalchemy import select


def test_idempotent_create_preserves_all_effects_and_rejects_changed_payload(api):
    api.headers("employee")
    profile = api.get("/api/me").json()
    before = api.db.snapshot()
    created = api.leave()
    after = api.db.snapshot()
    assert created["status"] == "submitted"
    assert created["version"] == 1
    assert created["days_count"] == 5
    assert [item["status"] for item in created["history"]] == ["submitted"]
    assert len(after["leave_requests"]) == len(before["leave_requests"]) + 1
    assert len(after["request_history"]) == len(before["request_history"]) + 1
    assert len(after["audit_events"]) == len(before["audit_events"]) + 1
    # Author and direct manager receive one notification; HR is notified after manager approval.
    assert len(after["notifications"]) == len(before["notifications"]) + 2
    replay = api.create()
    assert replay.status_code == 201
    assert replay.json() == created
    assert api.db.snapshot() == after
    for changes in ({"comment": "changed"}, {"start_date": "2027-01-12"}, {"end_date": "2027-01-16"}):
        response = api.create(**changes)
        assert response.status_code == 409
        assert api.db.snapshot() == after
    assert api.get("/api/me").json() == profile
    for actor, kind in (("employee", "request_submitted"), ("manager", "request_manager_review")):
        matching = [item for item in api.get("/api/notifications", actor).json() if item["kind"] == kind]
        assert len(matching) == 1
    assert not [item for item in api.get("/api/notifications", "hr").json() if item["kind"] == "request_hr_review"]


def test_idempotency_keys_are_scoped_to_author(api):
    first = api.leave()
    assert api.create(key="other-command", start_date="2027-02-01", end_date="2027-02-05").status_code == 201
    assert api.create("outsider").status_code == 409
    assert first["employee_id"] == 1


@pytest.mark.parametrize(
    "actor,visible",
    [("employee", True), ("manager", True), ("hr", True), ("outsider", False)],
)
def test_request_lists_and_details_share_object_permissions(api, actor, visible):
    created = api.leave()
    response = api.get("/api/requests", actor)
    assert response.status_code == 200
    items = response.json()
    assert (created["id"] in {item["id"] for item in items}) is visible
    ids = [item["id"] for item in items]
    assert ids == sorted(ids, reverse=True)
    detail = api.get(f"/api/requests/{created['id']}", actor)
    assert detail.status_code == (200 if visible else 404)
    assert api.get("/api/requests/999999", actor).status_code == 404


def test_employee_is_forbidden_to_approve_own_request(api):
    item = api.leave()
    before = api.db.snapshot()
    assert api.decide(item, "employee").status_code == 403
    assert api.db.snapshot() == before


@pytest.mark.parametrize("actor", ["manager", "hr", "outsider"])
def test_request_without_configured_manager_is_not_created(api, actor):
    api.headers(actor)
    before = api.db.snapshot()
    response = api.create(actor)
    assert response.status_code == 409
    assert "не настроен маршрут" in response.json()["detail"]
    assert api.db.snapshot() == before


def test_unrelated_manager_cannot_see_or_decide_outsider_request(api):
    from app.models import Employee, LeaveRequest, RequestHistory

    # A matching department label does not make somebody a direct report.
    with api.db.session() as db:
        db.get(Employee, 4).department = db.get(Employee, 2).department
        request = LeaveRequest(employee_id=4, start_date=date(2027, 4, 1), end_date=date(2027, 4, 2), comment="Imported request", idempotency_key="imported-outsider", payload_hash="imported")
        db.add(request)
        db.flush()
        db.add(RequestHistory(request_id=request.id, actor_id=4, status="submitted", comment="Imported request"))
        db.commit()
        outsider_id = request.id
    outsider = api.get(f"/api/requests/{outsider_id}", "outsider").json()
    employee = api.leave("employee")
    api.headers("manager")
    before = api.db.snapshot()
    assert api.decide(outsider, "manager").status_code == 404
    assert api.decide(employee, "outsider").status_code == 404
    assert api.db.snapshot() == before


def test_manager_approval_then_hr_approval_has_ordered_history_and_effects(api):
    from app.models import AuditEvent, LeaveDeduction, Notification, RequestHistory

    initial_balance = api.get("/api/me").json()["leave_balance"]
    item = api.leave()
    assert api.decide(item, "hr").status_code == 409
    api.headers("manager")
    before = api.db.snapshot()
    manager_response = api.decide(item, "manager", "approved")
    assert manager_response.status_code == 200, manager_response.text
    manager_approved = manager_response.json()
    assert manager_approved["status"] == "manager_approved"
    assert manager_approved["version"] == item["version"] + 1
    assert [entry["status"] for entry in manager_approved["history"]] == ["submitted", "manager_approved"]
    after_manager = api.db.snapshot()
    assert len(after_manager["request_history"]) == len(before["request_history"]) + 1
    assert len(after_manager["audit_events"]) == len(before["audit_events"]) + 1
    assert len(after_manager["notifications"]) == len(before["notifications"]) + 2
    assert api.get("/api/me").json()["leave_balance"] == initial_balance
    assert api.decide(manager_approved, "manager", "approved").status_code == 409

    final_response = api.decide(manager_approved, "hr", "approved")
    assert final_response.status_code == 200, final_response.text
    decided = final_response.json()
    assert decided["status"] == "approved"
    assert decided["version"] == item["version"] + 2
    assert [entry["status"] for entry in decided["history"]] == ["submitted", "manager_approved", "approved"]
    after = api.db.snapshot()
    for table in ("request_history", "notifications", "leave_deductions", "zup_deliveries"):
        assert len(after[table]) == len(after_manager[table]) + 1
    assert len(after["audit_events"]) == len(after_manager["audit_events"]) + 3
    with api.db.session() as db:
        history = db.scalars(select(RequestHistory).where(RequestHistory.request_id == item["id"])).all()
        assert [entry.actor_id for entry in history] == [1, 2, 3]
        events = db.scalars(select(AuditEvent).where(AuditEvent.entity_type == "request", AuditEvent.entity_id == item["id"])).all()
        assert sorted(event.action for event in events) == sorted(["request.created", "request.manager_approved", "request.approved", "leave.deducted", "zup.leave_registered"])
        deduction = db.scalar(select(LeaveDeduction).where(LeaveDeduction.request_id == item["id"]))
        assert (deduction.employee_id, deduction.actor_id, deduction.days) == (1, 3, 5)
        notifications = db.scalars(select(Notification).where(Notification.employee_id == 1, Notification.kind == "request_status")).all()
        assert len(notifications) == len([n for n in before["notifications"] if n.employee_id == 1 and n.kind == "request_status"]) + 1
        assert "Списано 5 календ. дн." in notifications[-1].body
    assert api.get("/api/me").json()["leave_balance"] == initial_balance - 5
    assert api.decide(decided, "hr", "rejected").status_code == 409
    assert api.db.snapshot() == after
    assert api.get(f"/api/requests/{item['id']}").json() == decided


@pytest.mark.parametrize("actor", ["manager", "hr"])
def test_rejection_at_each_stage_is_final(api, actor):
    initial_balance = api.get("/api/me").json()["leave_balance"]
    item = api.leave(key=f"reject-at-{actor}")
    if actor == "hr":
        item = api.decide(item, "manager", "approved").json()
    response = api.decide(item, actor, "rejected")
    assert response.status_code == 200
    rejected = response.json()
    assert rejected["status"] == "rejected"
    assert api.decide(rejected, "hr", "approved").status_code == 409
    assert api.get("/api/me").json()["leave_balance"] == initial_balance
    assert not api.db.snapshot()["leave_deductions"]


def test_request_cannot_exceed_available_balance(api):
    import sqlite3

    api.headers()
    with sqlite3.connect(api.db.zup_path) as db:
        db.execute("UPDATE balances SET initial_days=4 WHERE employee_id='demo-1'")
    before = api.db.snapshot()
    response = api.create()
    assert response.status_code == 409
    assert response.json()["detail"] == "Недостаточно дней отпуска: запрошено 5, доступно 4"
    assert api.db.snapshot() == before


def test_final_approval_rechecks_balance_without_reserving_pending_requests(api):
    import sqlite3

    with sqlite3.connect(api.db.zup_path) as db:
        db.execute("UPDATE balances SET initial_days=6 WHERE employee_id='demo-1'")
    first = api.leave(key="balance-race-one")
    second = api.leave(key="balance-race-two", start_date="2027-02-01", end_date="2027-02-05")
    first = api.decide(first, "manager").json()
    second = api.decide(second, "manager").json()
    assert api.decide(first, "hr").status_code == 200
    before_failed_approval = api.db.snapshot()
    response = api.decide(second, "hr")
    assert response.status_code == 409
    assert response.json()["detail"] == "Недостаточно дней отпуска: требуется 5, доступно 1"
    assert api.db.snapshot() == before_failed_approval
    assert api.get(f"/api/requests/{second['id']}", "hr").json()["status"] == "manager_approved"
    assert api.get("/api/me").json()["leave_balance"] == 1


def test_final_approval_rolls_back_deduction_when_notification_fails(api, monkeypatch):
    from app.modules import requests

    item = api.decide(api.leave(), "manager").json()
    api.headers("hr")
    before = api.db.snapshot()

    def fail(*args, **kwargs):
        raise RuntimeError("simulated notification storage failure")

    with monkeypatch.context() as patch:
        patch.setattr(requests, "notify", fail)
        with pytest.raises(RuntimeError, match="simulated notification storage failure"):
            api.decide(item, "hr")
    assert api.db.snapshot() == before
    assert api.decide(item, "hr").status_code == 200


def test_stale_version_cannot_change_even_a_submitted_request(api):
    item = api.leave()
    api.headers("manager")
    before = api.db.snapshot()
    assert api.decide(item, version=item["version"] + 1).status_code == 409
    assert api.db.snapshot() == before
    assert api.decide(item).json()["status"] == "manager_approved"


def test_two_concurrent_decisions_have_one_winner_and_one_set_of_effects(api):
    item = api.leave()
    for actor in ("manager", "hr"):
        api.headers(actor)
    before = api.db.snapshot()
    barrier = Barrier(2)

    def decide(actor, status):
        barrier.wait(timeout=10)
        return api.decide(item, actor, status)

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(decide, "manager", "approved"), pool.submit(decide, "hr", "rejected")]
        responses = [future.result(timeout=20) for future in futures]
    assert sorted(response.status_code for response in responses) == [200, 409], [r.text for r in responses]
    winner = next(response.json() for response in responses if response.status_code == 200)
    assert winner["version"] == item["version"] + 1
    assert len(winner["history"]) == 2
    assert api.get(f"/api/requests/{item['id']}").json() == winner
    after = api.db.snapshot()
    for table in ("request_history", "audit_events"):
        assert len(after[table]) == len(before[table]) + 1
    assert len(after["notifications"]) == len(before["notifications"]) + 2


@pytest.mark.parametrize(
    "body,key",
    [
        ({"start_date": "2027-02-02", "end_date": "2027-02-01"}, "valid-test-key"),
        ({"employee_id": 4}, "valid-test-key"),
        ({"status": "approved"}, "valid-test-key"),
        ({"version": 42}, "valid-test-key"),
        ({}, None),
        ({}, "short"),
        ({}, "x" * 129),
    ],
)
def test_invalid_create_and_mass_assignment_cannot_write(api, body, key):
    headers = api.headers()
    if key is not None:
        headers["Idempotency-Key"] = key
    payload = {"start_date": "2027-02-01", "end_date": "2027-02-02", "comment": "validation"} | body
    before = api.db.snapshot()
    response = api.client.post("/api/requests", headers=headers, json=payload)
    assert response.status_code == 422
    assert api.db.snapshot() == before


def test_create_rolls_back_all_effects_when_notification_fails(api, monkeypatch):
    from app.modules import requests

    api.headers()
    before = api.db.snapshot()

    def fail(*args, **kwargs):
        raise RuntimeError("simulated notification storage failure")

    with monkeypatch.context() as patch:
        patch.setattr(requests, "notify", fail)
        with pytest.raises(RuntimeError, match="simulated notification storage failure"):
            api.create()
    assert api.db.snapshot() == before
    assert api.create().status_code == 201
