"""Frozen crews, responsible-only commands and current rights before replay."""
import copy
import hashlib
from datetime import timedelta

import pytest
import sqlalchemy as sa
from fastapi.testclient import TestClient

from app.main import create_app
from app.models import Area, AuthSession, Brigade, ClientCommand, Employee, Equipment, FaultCode, Material, Notification, Order, OrderAssignment, OrderAssignmentParticipant, Photo, PushTask, utcnow
from app.security import token_hash
from app.schemas import OrderCreate
from test_idempotency import legacy_json_hash, photo_bytes
from test_postgresql import parallel_requests


def headers(employee_id, **extra):
    return {"Authorization": f"Bearer synthetic-brigade-{employee_id}", **extra}


@pytest.fixture(params=["sqlite", "postgresql"])
def brigade_client(request, tmp_path, monkeypatch):
    monkeypatch.setenv("PUSH_ENABLED", "false")
    url = request.getfixturevalue("pg_database").url if request.param == "postgresql" else f"sqlite:///{tmp_path / 'brigade.sqlite'}"
    app = create_app(url, seed=False, monitor=False)
    try:
        with TestClient(app) as client:
            with app.state.sessions() as db:
                db.add_all([Area(id=1, name="Synthetic area"), Brigade(id=1, name="Crew A"), Brigade(id=2, name="Crew B")])
                db.flush()
                for id_, role, brigade, on_shift in [(1, "master", None, True), (2, "admin", None, True),
                    (5, "worker", 1, True), (6, "worker", 1, True), (7, "worker", 1, False),
                    (8, "manager", 1, True), (9, "worker", 2, True), (10, "worker", 1, False)]:
                    db.add(Employee(id=id_, name=f"Person {id_}", login=f"person{id_}", role=role,
                        pin_hash="synthetic", specialty="", grade=0, brigade_id=brigade, on_shift=on_shift))
                db.add_all([Equipment(id=3, name="Pump", inventory_number="SYN-3", area_id=1, type="pump", criticality="medium"),
                    Material(id=1, name="Part", unit="piece"), FaultCode(id=1, code="SYN-1", name="Fault")])
                db.flush()
                db.add_all([AuthSession(token_hash=token_hash(f"synthetic-brigade-{id_}"), employee_id=id_,
                    expires_at=utcnow() + timedelta(hours=1)) for id_ in [1, 2, 5, 6, 7, 8, 9, 10]])
                db.commit()
            yield client
    finally:
        app.state.engine.dispose()


def body(**assignment):
    return {"title": "Synthetic crew repair", "description": "Verify the synthetic pump", "work_type": "planned",
        "area_id": 1, "equipment_id": 3, "deadline": (utcnow() + timedelta(hours=2)).isoformat(), **assignment}


def create(client, **assignment):
    response = client.post("/api/orders", json=body(**assignment), headers=headers(1))
    assert response.status_code == 201, response.text
    return response.json()


def act(client, order_id, action, employee_id=6, key=None, **fields):
    response = client.post(f"/api/orders/{order_id}/transition", json={"action": action, **fields},
        headers=headers(employee_id, **({"X-Client-Command-Id": key} if key else {})))
    assert response.status_code == 200, response.text
    return response.json()


def report():
    return {"work_done": "Replace the synthetic part and verify operation", "fault_code_id": 1,
        "materials": [{"material_id": 1, "quantity": 2}]}


def test_assignment_selection_validation_and_individual_compatibility(brigade_client):
    client = brigade_client
    first = create(client, brigade_id=1)
    second = create(client, brigade_id=1)
    explicit = create(client, brigade_id=1, responsible_id=6)
    assert [first["assignee_id"], second["assignee_id"], explicit["assignee_id"]] == [5, 6, 6]
    assert first["participants"] == [
        {"employee_id": 5, "name": "Person 5", "is_responsible": True, "source": "live"},
        {"employee_id": 6, "name": "Person 6", "is_responsible": False, "source": "live"}]
    assert first["participants_source"] == "live"
    individual = create(client, assignee_id=6)
    assert [person["employee_id"] for person in individual["participants"]] == [6]
    for assignment in [{"assignee_id": 6, "responsible_id": 6}, {"assignee_id": 6, "responsible_id": None}, {"brigade_id": 1, "responsible_id": 7},
        {"brigade_id": 1, "responsible_id": 8}, {"brigade_id": 1, "responsible_id": 9}]:
        assert client.post("/api/orders", json=body(**assignment), headers=headers(1)).status_code == 422
    assert client.patch(f"/api/orders/{first['id']}", json={"responsible_id": 6}, headers=headers(1)).status_code == 422
    assert client.patch(f"/api/orders/{first['id']}", json={"assignee_id": 6, "responsible_id": 6}, headers=headers(1)).status_code == 422
    with client.app.state.sessions() as db:
        assert set(db.scalars(sa.select(Notification.employee_id).where(Notification.order_id == first["id"], Notification.kind == "assigned"))) == {5, 6}
        assert set(db.scalars(sa.select(PushTask.employee_id).where(PushTask.order_id == first["id"]))) == {5, 6}


def test_pre_brigade_create_receipt_keeps_its_original_hash_and_body(brigade_client):
    client = brigade_client
    payload = body(brigade_id=1)
    request_headers = headers(1, **{"X-Client-Command-Id": "crew-old-create-receipt"})
    response = client.post("/api/orders", json=payload, headers=request_headers)
    assert response.status_code == 201, response.text
    original = copy.deepcopy(response.json())
    original.pop("participants")
    original.pop("participants_source")
    for assignment in original["assignment_history"]:
        assignment.pop("participants")
        assignment.pop("participants_source")
    old_hash = legacy_json_hash(OrderCreate, payload)
    old_scoped_hash = hashlib.sha256("\x1f".join(["client-command-v2", "order_create", "", old_hash]).encode("utf-8")).hexdigest()
    with client.app.state.sessions() as db:
        receipt = db.scalar(sa.select(ClientCommand).where(ClientCommand.client_id == "crew-old-create-receipt"))
        receipt.request_hash = old_scoped_hash
        receipt.response_body = original
        db.commit()
    replay = client.post("/api/orders", json=payload, headers=request_headers)
    assert replay.status_code == 201 and replay.json() == original
    different = client.post("/api/orders", json={**payload, "responsible_id": 6}, headers=request_headers)
    assert different.status_code == 409
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(Order)) == 1


def test_frozen_names_roster_photo_author_and_reassignment_revoke_access(brigade_client):
    client = brigade_client
    order = create(client, brigade_id=1, responsible_id=6)
    path = f"/api/orders/{order['id']}"
    changed = client.patch("/api/reference/employees/5", json={"name": "Renamed worker", "brigade_id": 2, "on_shift": False}, headers=headers(2))
    assert changed.status_code == 200, changed.text
    assert client.patch("/api/reference/employees/10", json={"on_shift": True}, headers=headers(2)).status_code == 200
    current = client.get(path, headers=headers(5))
    assert current.status_code == 200
    assert current.json()["participants"] == order["participants"]
    assert order["id"] in [item["id"] for item in client.get("/api/orders", headers=headers(5)).json()]
    assert client.get(path, headers=headers(10)).status_code == 403
    assert client.get(path, headers=headers(9)).status_code == 403
    photo_headers = headers(5, **{"X-Client-Command-Id": "crew-photo-first-001"})
    photo = client.post(path + "/photos", data={"kind": "before"},
        files={"file": ("before.png", photo_bytes(), "image/png")}, headers=photo_headers)
    assert photo.status_code == 201, photo.text
    photo_path = photo.json()["url"]
    assert client.get(photo_path, headers=headers(6)).status_code == 200
    assert client.get(photo_path, headers=headers(9)).status_code == 403
    assert client.post(path + "/transition", json={"action": "accept"}, headers=headers(5)).status_code == 403
    assert client.post(path + "/complete", json=report(), headers=headers(5)).status_code == 403
    revised = client.patch(path, json={"brigade_id": 1, "responsible_id": 6}, headers=headers(1))
    assert revised.status_code == 200, revised.text
    revised = revised.json()
    assert revised["version"] == photo.json()["order_version"] + 1
    assert [row["employee_id"] for row in revised["participants"]] == [6, 10]
    assert revised["assignment_history"][0]["participants"] == order["participants"]
    assert revised["assignment_history"][0]["ended_at"] == revised["assigned_at"]
    assert client.get(path, headers=headers(5)).status_code == 403
    assert order["id"] not in [item["id"] for item in client.get("/api/orders", headers=headers(5)).json()]
    assert client.get(photo_path, headers=headers(5)).status_code == 403
    assert client.get(photo_path, headers=headers(10)).status_code == 200
    assert client.post(path + "/photos", data={"kind": "before"},
        files={"file": ("before.png", photo_bytes(), "image/png")}, headers=photo_headers).status_code == 403
    cancelled = act(client, order["id"], "cancel", employee_id=1, reason="Synthetic cancellation")
    assert cancelled["assignment_history"][-1]["ended_at"] is not None
    assert client.get(path, headers=headers(10)).status_code == 200
    assert client.get(photo_path, headers=headers(10)).status_code == 200
    assert client.post(path + "/photos", data={"kind": "after"},
        files={"file": ("after.png", photo_bytes(), "image/png")}, headers=headers(10)).status_code == 409
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(Photo.author_id).where(Photo.id == photo.json()["id"])) == 5
        assert db.scalar(sa.select(sa.func.count()).select_from(Photo)) == 1


def test_leadership_change_blocks_successful_command_replay(brigade_client):
    client = brigade_client
    order = create(client, brigade_id=1, responsible_id=5)
    path = f"/api/orders/{order['id']}"
    act(client, order["id"], "accept", employee_id=5, key="crew-accept-first-001")
    act(client, order["id"], "start", employee_id=5)
    complete_headers = headers(5, **{"X-Client-Command-Id": "crew-complete-first-001"})
    finished = client.post(path + "/complete", json=report(), headers=complete_headers)
    assert finished.status_code == 200, finished.text
    attempt_id = finished.json()["submission_attempts"][-1]["id"]
    assert client.get(path + f"/submissions/{attempt_id}/ai-review", headers=headers(6)).status_code == 404
    act(client, order["id"], "rework", employee_id=1, reason="Synthetic recheck")
    changed = client.patch(path, json={"brigade_id": 1, "responsible_id": 6}, headers=headers(1))
    assert changed.status_code == 200, changed.text
    assert client.get(path, headers=headers(5)).status_code == 200
    assert client.post(path + "/complete", json=report(), headers=complete_headers).status_code == 403
    assert client.post(path + "/transition", json={"action": "accept"},
        headers=headers(5, **{"X-Client-Command-Id": "crew-accept-first-001"})).status_code == 403
    assert client.get(path + f"/submissions/{attempt_id}/ai-review", headers=headers(5)).status_code == 404
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(ClientCommand)) == 2
        assert db.scalar(sa.select(Order.status).where(Order.id == order["id"])) == "issued"


def test_participation_does_not_copy_queue_personal_stats_or_rating(brigade_client):
    client = brigade_client
    own = create(client, assignee_id=5)
    crew = create(client, brigade_id=1, responsible_id=6)
    act(client, crew["id"], "queue")
    listed = client.get("/api/orders", headers=headers(5)).json()
    assert {row["id"] for row in listed} == {own["id"], crew["id"]}
    assert next(row for row in listed if row["id"] == crew["id"])["queue_position"] == 1
    # A crew participant can still accept their own responsible assignment.
    act(client, own["id"], "accept", employee_id=5)
    assert client.get("/api/dashboard", headers=headers(5)).json()["total"] == 1
    assert client.get("/api/analytics", headers=headers(5)).json()["summary"]["total"] == 1
    assert client.get("/api/analytics", params={"assignee_id": 6}, headers=headers(5)).json()["summary"]["total"] == 0
    with client.app.state.sessions() as db:
        row = db.get(Order, crew["id"])
        row.status = "closed"
        row.score = 5
        row.completed_at = utcnow()
        row.closed_at = utcnow()
        db.commit()
    ranking = client.get("/api/analytics", headers=headers(1)).json()["rankings"]
    assert [row["id"] for row in ranking] == [6]
    workers = {row["id"]: row for row in client.get("/api/employees", headers=headers(1)).json()}
    assert workers[5]["completed_count"] == 0 and workers[6]["completed_count"] == 1


def test_failed_reassignment_rolls_back_roster_version_and_notifications(brigade_client):
    client = brigade_client
    order = create(client, brigade_id=1, responsible_id=6)
    failed = client.patch(f"/api/orders/{order['id']}", json={"brigade_id": 2,
        "deadline": (utcnow() - timedelta(hours=1)).isoformat()}, headers=headers(1, **{"X-Client-Command-Id": "crew-failed-edit-001"}))
    assert failed.status_code == 422
    assert client.get(f"/api/orders/{order['id']}", headers=headers(1)).json() == order
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(OrderAssignment)) == 1
        assert db.scalar(sa.select(sa.func.count()).select_from(OrderAssignmentParticipant)) == 2
        assert db.scalar(sa.select(sa.func.count()).select_from(Notification)) == 2
        assert db.scalar(sa.select(sa.func.count()).select_from(ClientCommand)) == 0


def test_manual_legacy_or_inconsistent_history_grants_known_responsible_only(brigade_client):
    client = brigade_client
    order = create(client, brigade_id=1, responsible_id=6)
    path = f"/api/orders/{order['id']}"
    with client.app.state.sessions() as db:
        row = db.get(Order, order["id"])
        row.brigade_id = 2
        db.commit()
    result = client.get(path, headers=headers(6))
    assert result.status_code == 200
    assert result.json()["participants"] == [{"employee_id": 6, "name": "Person 6",
        "is_responsible": True, "source": "legacy_snapshot"}]
    assert client.get(path, headers=headers(5)).status_code == 403
    with client.app.state.sessions() as db:
        assignment_id = db.scalar(sa.select(OrderAssignment.id).where(OrderAssignment.order_id == order["id"]))
        db.execute(sa.delete(OrderAssignmentParticipant).where(OrderAssignmentParticipant.assignment_id == assignment_id))
        db.execute(sa.delete(OrderAssignment).where(OrderAssignment.id == assignment_id))
        db.commit()
    assert client.get(path, headers=headers(6)).json()["participants_source"] == "legacy_snapshot"
    assert client.get(path, headers=headers(5)).status_code == 403


def test_order_list_preloads_participants_without_per_order_queries(brigade_client):
    client = brigade_client
    ids = [create(client, brigade_id=1)["id"] for _ in range(3)]
    roster_queries = []
    def count_queries(connection, cursor, statement, parameters, context, executemany):
        if "FROM order_assignments" in statement or "FROM order_assignment_participants" in statement:
            roster_queries.append(statement)
    sa.event.listen(client.app.state.engine, "before_cursor_execute", count_queries)
    try:
        response = client.get("/api/orders", headers=headers(1))
        assert response.status_code == 200, response.text
        assert {row["id"] for row in response.json()} == set(ids)
        assert all(len(row["participants"]) == 2 for row in response.json())
    finally:
        sa.event.remove(client.app.state.engine, "before_cursor_execute", count_queries)
    assert len(roster_queries) == 2


def test_postgresql_concurrent_roster_change_and_assignment_is_coherent(brigade_client):
    client = brigade_client
    if client.app.state.engine.dialect.name != "postgresql":
        pytest.skip("Row/advisory locking acceptance requires PostgreSQL")
    responses = parallel_requests(client,
        ("POST", "/api/orders", body(brigade_id=1), headers(1)),
        ("PATCH", "/api/reference/employees/5", {"name": "Moved person", "brigade_id": 2}, headers(2)))
    assert [response.status_code for response in responses] == [201, 200], [r.text for r in responses]
    roster = responses[0].json()["participants"]
    # Either the old whole roster won the lock, or the move completed first.
    assert roster in [
        [{"employee_id": 5, "name": "Person 5", "is_responsible": True, "source": "live"},
         {"employee_id": 6, "name": "Person 6", "is_responsible": False, "source": "live"}],
        [{"employee_id": 6, "name": "Person 6", "is_responsible": True, "source": "live"}]]
