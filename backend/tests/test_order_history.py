"""Assignment boundaries, immutable submissions and exact offline replays."""
import copy
from datetime import timedelta

import pytest
import sqlalchemy as sa
from fastapi.testclient import TestClient

from app.main import create_app
from app.models import AIAssessment, Area, AuthSession, Brigade, ClientCommand, Employee, Equipment, FaultCode, Material, MaterialWriteoff, Order, OrderAssignment, Photo, SubmissionAttempt, SubmissionDecision, SubmissionPhoto, SubmissionWriteoff, utcnow
from app.security import token_hash
from test_idempotency import photo_bytes
from test_postgresql import MASTER, WORKER, new_order, parallel_requests, pg_client


@pytest.fixture
def history_client(tmp_path, monkeypatch):
    monkeypatch.setenv("PUSH_ENABLED", "false")
    app = create_app(f"sqlite:///{tmp_path / 'history.db'}", seed=False, monitor=False)
    try:
        with TestClient(app) as client:
            with app.state.sessions() as db:
                db.add_all([Area(id=1, name="Synthetic area"), Brigade(id=1, name="Synthetic brigade")])
                db.flush()
                db.add_all([Employee(id=id_, name=f"Synthetic person {id_}", login=f"person{id_}", role=role, pin_hash="synthetic", specialty="", grade=0, on_shift=True) for id_, role in [(1, "master"), (5, "worker"), (6, "worker")]])
                db.add_all([Equipment(id=3, name="Pump", inventory_number="SYN-3", area_id=1, type="pump", criticality="medium"), Material(id=1, name="Original part", unit="piece"), FaultCode(id=1, code="SYN-1", name="Fault")])
                db.flush()
                db.add_all([AuthSession(token_hash=token_hash(token), employee_id=id_, expires_at=utcnow() + timedelta(hours=1)) for token, id_ in [("pg-master-token", 1), ("pg-worker-token", 6), ("history-other-worker", 5)]])
                db.commit()
            yield client
    finally:
        app.state.engine.dispose()


def act(client, id_, action, headers=WORKER, key=None, **fields):
    response = client.post(f"/api/orders/{id_}/transition", json={"action": action, **fields}, headers={**headers, **({"X-Client-Command-Id": key} if key else {})})
    assert response.status_code == 200, response.text
    return response.json()


def start(client, id_):
    act(client, id_, "accept")
    act(client, id_, "start")


def complete(client, id_, quantity=2, key="history-complete-001"):
    report = {"work_done": "Replace the synthetic part and verify operation", "fault_code_id": 1, "materials": [{"material_id": 1, "quantity": quantity}]}
    response = client.post(f"/api/orders/{id_}/complete", json=report, headers={**WORKER, "X-Client-Command-Id": key})
    assert response.status_code == 200, response.text
    return response.json(), report


def detail(client, id_, headers=MASTER):
    response = client.get(f"/api/orders/{id_}", headers=headers)
    assert response.status_code == 200, response.text
    return response.json()


def add_photo(client, id_):
    response = client.post(f"/api/orders/{id_}/photos", data={"kind": "after"}, files={"file": ("after.png", photo_bytes(), "image/png")}, headers=WORKER)
    assert response.status_code == 201, response.text
    return response.json()["id"]


def test_assignment_history_tracks_same_worker_reassignment_and_cancel(history_client):
    client = history_client
    id_ = new_order(client)
    initial = detail(client, id_)["assignment_history"]
    assert len(initial) == 1 and initial[0]["number"] == 1
    assert initial[0]["source"] == "live" and initial[0]["assigned_by_id"] == 1
    for assignee in [6, 5]:
        response = client.patch(f"/api/orders/{id_}", json={"assignee_id": assignee}, headers=MASTER)
        assert response.status_code == 200, response.text
    rows = detail(client, id_)["assignment_history"]
    assert [row["number"] for row in rows] == [1, 2, 3]
    assert [row["assignee_id"] for row in rows] == [6, 6, 5]
    assert rows[0]["ended_at"] == rows[1]["assigned_at"]
    assert rows[1]["ended_at"] == rows[2]["assigned_at"]
    assert rows[2]["ended_at"] is None
    assert client.get(f"/api/orders/{id_}", headers=WORKER).status_code == 403
    # A failed PATCH after staging an assignment must roll all history back.
    failed = client.patch(f"/api/orders/{id_}", json={"assignee_id": 6, "deadline": (utcnow() - timedelta(hours=1)).isoformat()}, headers=MASTER)
    assert failed.status_code == 422
    assert detail(client, id_)["assignment_history"] == rows
    closed = act(client, id_, "cancel", headers=MASTER, key="history-cancel-001", reason="Cancelled synthetic task")
    replay = act(client, id_, "cancel", headers=MASTER, key="history-cancel-001", reason="Cancelled synthetic task")
    assert replay == closed
    assert closed["assignment_history"][-1]["ended_at"] == closed["closed_at"]
    assert len(closed["assignment_history"]) == 3


def test_submissions_freeze_photos_extra_materials_ai_and_master_decisions(history_client):
    client = history_client
    id_ = new_order(client)
    start(client, id_)
    photo1 = add_photo(client, id_)
    first, report1 = complete(client, id_)
    frozen = copy.deepcopy(first["submission_attempts"][0])
    assert frozen["source"] == "live" and frozen["number"] == 1
    assert frozen["author_id"] == 6 and frozen["assessment_id"] is not None
    assert frozen["assignment_id"] == first["assignment_history"][0]["id"]
    assert [photo["id"] for photo in frozen["photos"]] == [photo1]
    assert frozen["completion"]["materials"][0]["quantity"] == 2
    assert frozen["materials"][0]["name"] == "Original part"
    act(client, id_, "rework", headers=MASTER, key="history-rework-001", reason="Check the repair again")
    act(client, id_, "rework", headers=MASTER, key="history-rework-001", reason="Check the repair again")
    with client.app.state.sessions() as db:
        material = db.get(Material, 1)
        material.name = "Renamed part"
        material.unit = "updated unit"
        db.commit()
    start(client, id_)
    photo2 = add_photo(client, id_)
    second, _ = complete(client, id_, quantity=3, key="history-complete-002")
    closed = act(client, id_, "close", headers=MASTER, key="history-close-001", score=4, comment="Repair accepted")
    assert act(client, id_, "close", headers=MASTER, key="history-close-001", score=4, comment="Repair accepted") == closed
    attempts = closed["submission_attempts"]
    assert [attempt["number"] for attempt in attempts] == [1, 2]
    assert {key: value for key, value in attempts[0].items() if key != "decisions"} == {key: value for key, value in frozen.items() if key != "decisions"}
    assert [row["action"] for row in attempts[0]["decisions"]] == ["rework"]
    assert [row["id"] for row in attempts[1]["photos"]] == [photo1, photo2]
    assert attempts[1]["completion"]["materials"][0]["quantity"] == 3
    assert attempts[1]["materials"][0]["quantity"] == 3
    assert attempts[1]["materials"][0]["name"] == "Renamed part"
    assert attempts[1]["ai_review"] == second["submission_attempts"][1]["ai_review"]
    assert attempts[1]["ai_review"]["master_score"] is None
    assert attempts[1]["decisions"][0]["score"] == 4
    assert closed["ai_review"]["master_score"] == 4
    assert closed["completion"]["materials"][0]["quantity"] == 5
    assert closed["assignment_history"][0]["ended_at"] == closed["closed_at"]
    replay = client.post(f"/api/orders/{id_}/complete", json=report1, headers={**WORKER, "X-Client-Command-Id": "history-complete-001"})
    assert replay.status_code == 200 and replay.json() == first
    assert detail(client, id_) == closed


def test_failed_completion_rolls_back_attempt_links_and_offline_claim(history_client, monkeypatch):
    import app.main as main_module
    client = history_client
    id_ = new_order(client)
    start(client, id_)
    add_photo(client, id_)
    def fail_after_history(*args, **kwargs):
        raise RuntimeError("Injected notification failure")
    with monkeypatch.context() as patch:
        patch.setattr(main_module, "notify", fail_after_history)
        with pytest.raises(RuntimeError, match="Injected notification failure"):
            complete(client, id_)
    with client.app.state.sessions() as db:
        assert db.get(Order, id_).status == "in_progress"
        assert db.get(Order, id_).completion is None
        for model in [SubmissionAttempt, SubmissionPhoto, SubmissionWriteoff, SubmissionDecision, MaterialWriteoff, AIAssessment, ClientCommand]:
            assert db.scalar(sa.select(sa.func.count()).select_from(model)) == 0
        assert db.scalar(sa.select(sa.func.count()).select_from(OrderAssignment)) == 1
    retried, _ = complete(client, id_)
    assert len(retried["submission_attempts"]) == 1


def test_legacy_snapshot_keeps_unknown_links_and_accepts_new_master_decision(history_client):
    client = history_client
    id_ = new_order(client)
    add_photo(client, id_)
    payload = {"work_done": "Preserved old report", "materials": [{"material_id": 1, "quantity": 7, "name": "Old name", "unit": "piece"}]}
    review = {"verdict": "passed", "score": 4, "master_score": None, "is_stub": True}
    with client.app.state.sessions() as db:
        order = db.get(Order, id_)
        order.status = "ai_review"
        order.completion = payload
        order.ai_review = review
        db.add(MaterialWriteoff(order_id=id_, material_id=1, quantity=7, author_id=6))
        db.add(SubmissionAttempt(order_id=id_, sequence=1, payload=payload, ai_review=review, source="legacy_snapshot"))
        db.commit()
    before = detail(client, id_)["submission_attempts"][0]
    assert before["source"] == "legacy_snapshot"
    assert all(before[key] is None for key in ["submitted_at", "author_id", "author_name", "assignment_id", "assessment_id"])
    assert before["photos"] == before["materials"] == []
    closed = act(client, id_, "close", headers=MASTER, score=5)
    after = closed["submission_attempts"][0]
    assert after["completion"] == payload and after["ai_review"] == review
    assert after["decisions"][0]["action"] == "close"
    assert after["decisions"][0]["score"] == 5


@pytest.mark.parametrize("decision,fields", [("close", {"score": 4}), ("rework", {"reason": "Review repair"})])
def test_pg_parallel_replays_create_one_attempt_and_one_decision(pg_client, decision, fields):
    client = pg_client
    id_ = new_order(client)
    start(client, id_)
    report = {"work_done": "Repair synthetic pump and verify operation", "fault_code_id": 1, "materials": [{"material_id": 1, "quantity": 2}]}
    request = ("POST", f"/api/orders/{id_}/complete", report, {**WORKER, "X-Client-Command-Id": "pg-history-completion"})
    responses = parallel_requests(client, request, request)
    assert [r.status_code for r in responses] == [200, 200]
    assert responses[0].json() == responses[1].json()
    request = ("POST", f"/api/orders/{id_}/transition", {"action": decision, **fields}, {**MASTER, "X-Client-Command-Id": "pg-history-decision"})
    responses = parallel_requests(client, request, request)
    assert [r.status_code for r in responses] == [200, 200]
    assert responses[0].json() == responses[1].json()
    with client.app.state.sessions() as db:
        for model in [OrderAssignment, SubmissionAttempt, SubmissionDecision, MaterialWriteoff, SubmissionWriteoff, AIAssessment]:
            assert db.scalar(sa.select(sa.func.count()).select_from(model)) == 1


def test_pg_parallel_same_worker_reassignment_preserves_each_boundary(pg_client):
    client = pg_client
    id_ = new_order(client)
    request = ("PATCH", f"/api/orders/{id_}", {"assignee_id": 6}, MASTER)
    responses = parallel_requests(client, request, request)
    assert [r.status_code for r in responses] == [200, 200]
    rows = detail(client, id_)["assignment_history"]
    assert [row["number"] for row in rows] == [1, 2, 3]
    assert all(row["assignee_id"] == 6 for row in rows)
    assert rows[0]["ended_at"] == rows[1]["assigned_at"]
    assert rows[1]["ended_at"] == rows[2]["assigned_at"]
    assert rows[2]["ended_at"] is None
