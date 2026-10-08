"""Foundation regressions: isolated SQLite and opt-in PostgreSQL schemas."""
import importlib
import io
import threading
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta

import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from PIL import Image
from sqlalchemy import event, func, select

from app.main import create_app
from app.models import ClientCommand, Notification, Order, OrderEvent, Photo, PushTask, utcnow
from conftest import auth_headers

main_module = importlib.import_module("app.main")


@pytest.fixture(scope="module")
def foundation_client(tmp_path_factory):
    path = tmp_path_factory.mktemp("foundation") / "foundation.db"
    with TestClient(create_app(f"sqlite:///{path}", monitor=False)) as client:
        yield client


def payload(**overrides):
    return {
        "title": "Проверка серверной основы",
        "description": "Проверить подшипник после остановки",
        "work_type": "planned",
        "area_id": 1,
        "equipment_id": 3,
        "assignee_id": 6,
        "priority": "normal",
        "deadline": (utcnow() + timedelta(hours=4)).isoformat(),
        **overrides,
    }


def issue(client, master, **overrides):
    response = client.post("/api/orders", json=payload(**overrides), headers=master)
    assert response.status_code == 201, response.text
    return response.json()


def counts(client):
    with client.app.state.sessions() as db:
        return tuple(db.scalar(select(func.count()).select_from(model)) for model in
                     (Order, OrderEvent, Notification, PushTask, ClientCommand))


@pytest.mark.parametrize("description", [None, "", " \t\n", "x" * 5001])
def test_create_requires_nonempty_description(foundation_client, description):
    client = foundation_client
    master = auth_headers(client)
    body = payload(description=description)
    if description is None:
        del body["description"]
    before = counts(client)
    response = client.post("/api/orders", json=body, headers=master)
    assert response.status_code == 422, response.text
    assert any(error["loc"][-1] == "description" for error in response.json()["detail"])
    assert counts(client) == before


def test_patch_description_trims_audits_and_preserves_when_omitted(foundation_client):
    client = foundation_client
    master = auth_headers(client)
    order = issue(client, master, description="  Осмотр  ")
    assert order["description"] == "Осмотр"
    path = f"/api/orders/{order['id']}"
    for value in ["", " \t", None, "x" * 5001]:
        response = client.patch(path, json={"description": value}, headers=master)
        assert response.status_code == 422, response.text
    response = client.patch(path, json={"description": "  Замена узла  "}, headers=master)
    assert response.status_code == 200, response.text
    assert response.json()["description"] == "Замена узла"
    assert response.json()["events"][-1]["comment"] == "description=Замена узла"
    updated = client.patch(path, json={"priority": "high"}, headers=master)
    assert updated.status_code == 200
    assert updated.json()["description"] == "Замена узла"
    # The agreed rule is nonempty text, without an invented minimum length.
    assert client.patch(path, json={"description": "Я"}, headers=master).status_code == 200
    worker = auth_headers(client, "worker2")
    assert client.patch(path, json={"description": "Правка"}, headers=worker).status_code == 403


def assert_collision_retry(client, monkeypatch):
    master = auth_headers(client)
    original = issue(client, master)
    candidates = iter([original["number"], f"Н-{utcnow().year}-BEEFFE"])
    monkeypatch.setattr(main_module, "order_number", lambda assigned: next(candidates))
    before = counts(client)
    headers = {**master, "X-Client-Command-Id": "foundation-collision-success"}
    body = payload(title="Выдача после коллизии номера")
    created = client.post("/api/orders", json=body, headers=headers)
    assert created.status_code == 201, created.text
    assert created.json()["number"] == f"Н-{utcnow().year}-BEEFFE"
    assert counts(client) == tuple(value + 1 for value in before)
    replay = client.post("/api/orders", json=body, headers=headers)
    assert replay.status_code == 201 and replay.json() == created.json()
    assert counts(client) == tuple(value + 1 for value in before)


def test_number_collision_retries_without_duplicate_effects(foundation_client, monkeypatch):
    assert_collision_retry(foundation_client, monkeypatch)


def test_number_collision_exhaustion_rolls_back_command(foundation_client, monkeypatch):
    client = foundation_client
    master = auth_headers(client)
    original = issue(client, master)
    attempted = []

    def collision(assigned):
        attempted.append(assigned)
        return original["number"]

    monkeypatch.setattr(main_module, "order_number", collision)
    before = counts(client)
    body = payload(title="Выдача с исчерпанным номером")
    headers = {**master, "X-Client-Command-Id": "foundation-collision-exhausted"}
    response = client.post("/api/orders", json=body, headers=headers)
    assert response.status_code == 503, response.text
    assert response.headers["Retry-After"] == "1"
    assert len(attempted) == main_module.ORDER_NUMBER_ATTEMPTS
    assert counts(client) == before
    monkeypatch.setattr(main_module, "order_number", lambda assigned: f"Н-{assigned.year}-C0FFEE")
    assert client.post("/api/orders", json=body, headers=headers).status_code == 201


def test_create_without_command_id_rolls_back_released_savepoint(foundation_client, monkeypatch):
    client = foundation_client
    master = auth_headers(client)
    before = counts(client)

    def fail_notification(*args, **kwargs):
        raise HTTPException(503, "Test notification failure after insert")

    monkeypatch.setattr(main_module, "notify", fail_notification)
    response = client.post("/api/orders", json=payload(), headers=master)
    assert response.status_code == 503
    assert counts(client) == before


def test_database_wait_does_not_block_event_loop(foundation_client):
    client = foundation_client
    master = auth_headers(client)
    entered, release = threading.Event(), threading.Event()

    def block_insert(connection, cursor, statement, parameters, context, executemany):
        if statement.startswith("INSERT INTO orders "):
            entered.set()
            assert release.wait(5), "Test must release the database operation"

    engine = client.app.state.engine
    event.listen(engine, "before_cursor_execute", block_insert)
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            pending = pool.submit(client.post, "/api/orders", json=payload(), headers=master)
            assert entered.wait(3)
            try:
                health = pool.submit(client.get, "/api/health")
                assert health.result(timeout=2).status_code == 200
                assert not pending.done(), "SQL write must still be blocked while health responds"
            finally:
                release.set()
            assert pending.result(timeout=3).status_code == 201
    finally:
        release.set()
        event.remove(engine, "before_cursor_execute", block_insert)


def image_bytes():
    output = io.BytesIO()
    Image.new("RGB", (40, 30), "green").save(output, format="PNG")
    return output.getvalue()


def assert_photo_rechecks(client, monkeypatch, change):
    master = auth_headers(client)
    worker = auth_headers(client, "worker2")
    order = issue(client, master)
    path = f"/api/orders/{order['id']}"
    entered, release = threading.Event(), threading.Event()
    original = main_module.prepare_photo

    def slow_prepare(data):
        entered.set()
        assert release.wait(5), "Test must release photo processing"
        return original(data)

    monkeypatch.setattr(main_module, "prepare_photo", slow_prepare)
    with ThreadPoolExecutor(max_workers=2) as pool:
        pending = pool.submit(client.post, path + "/photos", headers={**worker, "X-Client-Command-Id": f"foundation-photo-{change}"},
                              files={"file": ("test.png", image_bytes(), "image/png")}, data={"kind": "after"})
        assert entered.wait(3)
        try:
            if change == "reassign":
                changing = pool.submit(client.patch, path, json={"assignee_id": 7}, headers=master)
                expected = 403
            elif change == "cancel":
                changing = pool.submit(client.post, path + "/transition", json={"action": "cancel", "reason": "Отмена во время обработки"}, headers=master)
                expected = 409
            else:
                changing = pool.submit(client.post, "/api/auth/logout", headers=worker)
                expected = 401
            response = changing.result(timeout=2)
            assert response.status_code == 200, response.text
            assert not pending.done()
        finally:
            release.set()
        response = pending.result(timeout=3)
        assert response.status_code == expected, response.text
    with client.app.state.sessions() as db:
        assert db.scalar(select(func.count()).select_from(Photo).where(Photo.order_id == order["id"])) == 0
        assert db.scalar(select(ClientCommand).where(ClientCommand.client_id == f"foundation-photo-{change}")) is None


@pytest.mark.parametrize("change", ["reassign", "cancel", "logout"])
def test_photo_rechecks_current_permissions_and_state(foundation_client, monkeypatch, change):
    assert_photo_rechecks(foundation_client, monkeypatch, change)


def test_postgresql_number_collision_uses_savepoint(pg_database, monkeypatch):
    with TestClient(create_app(pg_database.url, monitor=False)) as client:
        assert_collision_retry(client, monkeypatch)


def test_postgresql_photo_does_not_hold_order_lock(pg_database, monkeypatch):
    with TestClient(create_app(pg_database.url, monitor=False)) as client:
        assert_photo_rechecks(client, monkeypatch, "reassign")
