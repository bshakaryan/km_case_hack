"""Real PostgreSQL migrations and concurrent API effects in isolated schemas."""
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta, timezone
from threading import Barrier

import pytest
import sqlalchemy as sa
from fastapi.testclient import TestClient

from app.main import create_app
from app.migrations import expected_schema, upgrade_database, validate_schema
from app.models import AIAssessment, Area, AuthSession, Brigade, ClientCommand, Employee, Equipment, FaultCode, Material, MaterialWriteoff, Notification, Order, OrderEvent, PushTask, utcnow
from app.security import token_hash
from test_migrations import fill_legacy, revision, snapshot


def assert_head(engine):
    with engine.connect() as connection:
        validate_schema(connection)
        assert connection.scalar(sa.text("SELECT version_num FROM alembic_version")) == "0003_push"
    assert set(sa.inspect(engine).get_table_names()) == set(expected_schema("0003_push").tables) | {"alembic_version"}


@pytest.mark.parametrize("legacy", ["unversioned1", "unversioned2", "versioned1", "versioned1-with-commands", "versioned2"])
def test_pg_filled_legacy_upgrade_preserves_data_and_assignment(pg_database, legacy):
    engine = pg_database.engine
    has_commands = legacy in {"unversioned2", "versioned1-with-commands", "versioned2"}
    revision(engine, "0002_client_commands" if has_commands else "0001_initial")
    created = fill_legacy(engine, has_commands).replace(tzinfo=timezone.utc)
    with engine.begin() as connection:
        if legacy.startswith("unversioned"):
            connection.exec_driver_sql("DROP TABLE alembic_version")
        elif legacy == "versioned1-with-commands":
            connection.exec_driver_sql("UPDATE alembic_version SET version_num='0001_initial'")
    before = snapshot(engine)
    upgrade_database(engine)
    after = snapshot(engine)
    assert {name: rows for name, rows in after.items() if name in before} == before
    schema = expected_schema("0003_push")
    with engine.connect() as connection:
        assigned = dict(connection.execute(sa.select(schema.tables["orders"].c.id, schema.tables["orders"].c.assigned_at)).all())
    assert assigned == {1: created + timedelta(minutes=40), 2: created, 3: created, 4: created + timedelta(minutes=30), 5: created}
    assert_head(engine)
    upgrade_database(engine)
    assert snapshot(engine) == after


def test_pg_empty_database_concurrent_process_startup_is_repeatable(pg_database):
    # Separate processes match two API workers starting together and avoid
    # Alembic's process-global command context being shared by test threads.
    code = """
import os, sys
from app.db import make_engine
from app.migrations import upgrade_database
sys.stdin.readline()
engine = make_engine(os.environ['NARYAD_PG_TEST_URL'])
try:
    upgrade_database(engine)
finally:
    engine.dispose()
"""
    environment = {**os.environ, "NARYAD_PG_TEST_URL": pg_database.url, "PUSH_ENABLED": "false"}
    children = [subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment) for _ in range(2)]
    try:
        for child in children:
            child.stdin.write("start\n")
            child.stdin.flush()
        for child in children:
            _, error = child.communicate(timeout=30)
            assert child.returncode == 0, error
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.communicate(timeout=5)
    assert_head(pg_database.engine)
    assert all(not rows for rows in snapshot(pg_database.engine).values())
    upgrade_database(pg_database.engine)
    assert_head(pg_database.engine)


@pytest.fixture
def pg_client(pg_database, monkeypatch):
    monkeypatch.setenv("PUSH_ENABLED", "false")
    app = create_app(pg_database.url, seed=False, monitor=False)
    try:
        with TestClient(app) as client:
            with app.state.sessions() as db:
                db.add_all([Area(id=1, name="Synthetic area"), Brigade(id=1, name="Synthetic brigade")])
                db.flush()
                db.add_all([Employee(id=id_, name=f"Synthetic person {id_}", login=f"person{id_}", role=role, pin_hash="synthetic", specialty="", grade=0, on_shift=True, brigade_id=None if role == "master" else 1) for id_, role in [(1, "master"), (5, "worker"), (6, "worker")]])
                db.add_all([Equipment(id=3, name="Synthetic pump", inventory_number="SYN-3", area_id=1, type="pump", criticality="medium"), Material(id=1, name="Synthetic part", unit="piece"), FaultCode(id=1, code="SYN-1", name="Synthetic fault")])
                db.flush()
                db.add_all([AuthSession(token_hash=token_hash(token), employee_id=id_, expires_at=utcnow() + timedelta(hours=1)) for token, id_ in [("pg-master-token", 1), ("pg-worker-token", 6)]])
                db.commit()
            yield client
    finally:
        app.state.engine.dispose()


MASTER = {"Authorization": "Bearer pg-master-token"}
WORKER = {"Authorization": "Bearer pg-worker-token"}
REPORT = {"work_done": "Replaced synthetic part and checked the pump", "fault_code_id": 1, "materials": [{"material_id": 1, "quantity": 2}]}


def new_order(client):
    response = client.post("/api/orders", headers=MASTER, json={"title": "Synthetic concurrent task", "description": "Check the synthetic pump", "work_type": "planned", "area_id": 1, "equipment_id": 3, "assignee_id": 6, "priority": "normal", "deadline": (utcnow() + timedelta(hours=2)).isoformat()})
    assert response.status_code == 201, response.text
    return response.json()["id"]


def parallel_requests(client, *requests):
    barrier = Barrier(len(requests))
    def send(request):
        # Each caller has its own ASGI portal, database session and connection.
        caller = TestClient(client.app)
        try:
            barrier.wait(timeout=10)
            method, path, body, headers = request
            return caller.request(method, path, json=body, headers=headers)
        finally:
            caller.close()
    with ThreadPoolExecutor(max_workers=len(requests)) as pool:
        futures = [pool.submit(send, request) for request in requests]
        return [future.result(timeout=25) for future in futures]


@pytest.mark.parametrize("action,status", [("accept", "issued"), ("start", "queued")])
def test_pg_worker_cannot_accept_or_start_two_orders(pg_client, action, status):
    ids = [new_order(pg_client), new_order(pg_client)]
    if status != "issued":
        with pg_client.app.state.sessions() as db:
            for order in db.scalars(sa.select(Order).where(Order.id.in_(ids))):
                order.status = status
            db.commit()
    responses = parallel_requests(pg_client, *[("POST", f"/api/orders/{id_}/transition", {"action": action}, WORKER) for id_ in ids])
    assert sorted(response.status_code for response in responses) == [200, 409], [r.text for r in responses]
    with pg_client.app.state.sessions() as db:
        statuses = list(db.scalars(sa.select(Order.status).where(Order.id.in_(ids))))
        assert statuses.count("accepted" if action == "accept" else "in_progress") == 1
        assert db.scalar(sa.select(sa.func.count()).select_from(OrderEvent).where(OrderEvent.order_id.in_(ids), OrderEvent.action == action)) == 1


@pytest.mark.parametrize("key", [None, "pg-completion-same-key"])
def test_pg_parallel_completion_has_one_report_and_writeoff(pg_client, key):
    id_ = new_order(pg_client)
    path = f"/api/orders/{id_}"
    for action in ["accept", "start"]:
        assert pg_client.post(path + "/transition", headers=WORKER, json={"action": action}).status_code == 200
    headers = {**WORKER, **({"X-Client-Command-Id": key} if key else {})}
    request = ("POST", path + "/complete", REPORT, headers)
    responses = parallel_requests(pg_client, request, request)
    assert sorted(response.status_code for response in responses) == ([200, 200] if key else [200, 409]), [r.text for r in responses]
    if key:
        assert responses[0].json() == responses[1].json()
    with pg_client.app.state.sessions() as db:
        assert db.get(Order, id_).status == "ai_review"
        for model, condition in [(MaterialWriteoff, MaterialWriteoff.order_id == id_), (AIAssessment, AIAssessment.order_id == id_), (OrderEvent, sa.and_(OrderEvent.order_id == id_, OrderEvent.action == "complete"))]:
            assert db.scalar(sa.select(sa.func.count()).select_from(model).where(condition)) == 1
        assert db.scalar(sa.select(MaterialWriteoff.quantity).where(MaterialWriteoff.order_id == id_)) == 2
        if key:
            assert db.scalar(sa.select(sa.func.count()).select_from(ClientCommand).where(ClientCommand.client_id == key)) == 1


def test_pg_parallel_same_create_key_is_replayable_without_duplicate_effects(pg_client):
    body = {"title": "Synthetic keyed creation", "description": "Check synthetic pump", "work_type": "planned", "area_id": 1, "equipment_id": 3, "assignee_id": 6, "deadline": (utcnow() + timedelta(hours=2)).isoformat()}
    headers = {**MASTER, "X-Client-Command-Id": "pg-create-same-key"}
    request = ("POST", "/api/orders", body, headers)
    responses = parallel_requests(pg_client, request, request)
    assert all(r.status_code in {201, 409} for r in responses), [r.text for r in responses]
    assert any(r.status_code == 201 for r in responses)
    replay = pg_client.post("/api/orders", json=body, headers=headers)
    assert replay.status_code == 201
    assert all(r.json() == replay.json() for r in responses if r.status_code == 201)
    id_ = replay.json()["id"]
    with pg_client.app.state.sessions() as db:
        for model, condition in [(Order, sa.true()), (ClientCommand, ClientCommand.client_id == "pg-create-same-key"), (OrderEvent, OrderEvent.order_id == id_), (Notification, Notification.order_id == id_), (PushTask, PushTask.order_id == id_)]:
            assert db.scalar(sa.select(sa.func.count()).select_from(model).where(condition)) == 1


def test_pg_completion_cannot_race_reassignment(pg_client):
    id_ = new_order(pg_client)
    path = f"/api/orders/{id_}"
    for action in ["accept", "start"]:
        assert pg_client.post(path + "/transition", headers=WORKER, json={"action": action}).status_code == 200
    responses = parallel_requests(pg_client, ("POST", path + "/complete", REPORT, WORKER), ("PATCH", path, {"assignee_id": 5}, MASTER))
    assert [r.status_code for r in responses] == [200, 409], [r.text for r in responses]
    with pg_client.app.state.sessions() as db:
        order = db.get(Order, id_)
        assert order.status == "ai_review" and order.assignee_id == 6
        assert db.scalar(sa.select(sa.func.count()).select_from(MaterialWriteoff).where(MaterialWriteoff.order_id == id_)) == 1
