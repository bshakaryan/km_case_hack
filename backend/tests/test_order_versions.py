"""Optimistic versions, immutable receipts and safe offline command chains."""
from datetime import timedelta

import pytest
import sqlalchemy as sa

from app.models import ClientCommand, MaterialWriteoff, Order, OrderEvent, Photo, utcnow
from test_idempotency import photo_bytes
from test_order_history import MASTER, WORKER, detail, history_client as sqlite_fixture, new_order
from test_postgresql import pg_client as postgres_fixture, parallel_requests


@pytest.fixture
def version_client(request, tmp_path, monkeypatch):
    if getattr(request, "param", None) == "postgresql":
        yield from postgres_fixture.__wrapped__(request.getfixturevalue("pg_database"), monkeypatch)
    else:
        yield from sqlite_fixture.__wrapped__(tmp_path, monkeypatch)


def basis(headers, *, version=None, previous=None, key=None):
    return {**headers, **({"X-Expected-Order-Version": str(version)} if version is not None else {}),
        **({"X-Previous-Client-Command-Id": previous} if previous is not None else {}),
        **({"X-Client-Command-Id": key} if key is not None else {})}


def transition(client, id_, action, headers, **fields):
    return client.post(f"/api/orders/{id_}/transition", headers=headers, json={"action": action, **fields})


def assert_ok(response, status=200):
    assert response.status_code == status, response.text
    return response.json()


def worker_chain(client):
    id_ = new_order(client)
    assert detail(client, id_)["version"] == 1
    accept = basis(WORKER, version=1, key="version-accept-001")
    assert assert_ok(transition(client, id_, "accept", accept))["version"] == 2
    start = basis(WORKER, previous="version-accept-001", key="version-start-001")
    assert assert_ok(transition(client, id_, "start", start))["version"] == 3
    return id_


def test_chain_receipts_photo_complete_and_old_successful_replay(version_client):
    client = version_client
    id_ = worker_chain(client)
    path = f"/api/orders/{id_}"
    headers = basis(WORKER, previous="version-start-001", key="version-photo-001")
    photo = assert_ok(client.post(path + "/photos", headers=headers, data={"kind": "after"}, files={"file": ("after.png", photo_bytes(), "image/png")}), 201)
    assert photo["order_version"] == 4
    report = {"work_done": "Replaced synthetic part and checked operation", "fault_code_id": 1, "materials": [{"material_id": 1, "quantity": 2}]}
    headers = basis(WORKER, previous="version-photo-001", key="version-complete-001")
    cached = assert_ok(client.post(path + "/complete", headers=headers, json=report))
    assert cached["version"] == 5 and cached["status"] == "completed"
    assert detail(client, id_)["version"] == 5
    assert assert_ok(client.post(path + "/complete", headers=headers, json=report)) == cached
    changed_basis = basis(WORKER, version=7, key="version-complete-001")
    assert client.post(path + "/complete", headers=changed_basis, json=report).status_code == 409
    with client.app.state.sessions() as db:
        receipt = db.scalar(sa.select(ClientCommand).where(ClientCommand.client_id == "version-complete-001"))
        assert (receipt.order_id, receipt.order_version) == (id_, 5)
        assert db.scalar(sa.select(sa.func.count()).select_from(MaterialWriteoff)) == 1
        assert db.scalar(sa.select(sa.func.count()).select_from(Photo)) == 1
    # Historical photo snapshots carry their original photo fields only.
    assert "order_version" not in detail(client, id_)["submission_attempts"][0]["photos"][0]


@pytest.mark.parametrize("assignees", [[6], [5, 6]])
def test_same_worker_and_away_back_assignment_block_old_commands(version_client, assignees):
    client = version_client
    id_ = new_order(client)
    for assignee in assignees:
        assert_ok(client.patch(f"/api/orders/{id_}", headers=MASTER, json={"assignee_id": assignee}))
    headers = basis(WORKER, version=1, key="stale-assignment-001")
    stale = transition(client, id_, "accept", headers)
    assert stale.status_code == 409
    assert stale.json()["detail"] == {"code": "order_version_conflict", "message": "Наряд изменён. Сохранённое действие требует проверки.", "expected_version": 1, "current_version": 1 + len(assignees)}
    current = detail(client, id_)
    assert current["status"] == "issued"
    assert not any(event["action"] == "accept" for event in current["events"])
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(ClientCommand).where(ClientCommand.client_id == "stale-assignment-001")) is None


def test_predecessor_must_be_own_successful_same_order_receipt(version_client):
    client = version_client
    id_ = new_order(client)
    other = new_order(client)
    assert_ok(transition(client, id_, "queue", basis(WORKER, version=1, key="own-queue-proof-001")))
    assert_ok(client.patch(f"/api/orders/{id_}", headers=basis(MASTER, version=2, key="master-edit-proof-001"), json={"comment": "Changed"}))
    with client.app.state.sessions() as db:
        db.add_all([ClientCommand(employee_id=6, client_id="legacy-proof-001", kind="transition", request_hash="a" * 64, response_status=200, response_body={"id": id_}),
            ClientCommand(employee_id=6, client_id="unfinished-proof-001", kind="transition", request_hash="b" * 64, order_id=id_, order_version=3)])
        db.commit()
    for previous, target in [("absent-proof-001", id_), ("master-edit-proof-001", id_), ("own-queue-proof-001", other), ("legacy-proof-001", id_), ("unfinished-proof-001", id_)]:
        response = transition(client, target, "queue", basis(WORKER, previous=previous, key="unavailable-current-001"))
        assert response.status_code == 409, response.text
        assert response.json()["detail"]["code"] == "order_precondition_unavailable"
    # Current rights are checked before a version or receipt can reveal data.
    assert_ok(client.patch(f"/api/orders/{id_}", headers=MASTER, json={"assignee_id": 5}))
    denied = transition(client, id_, "queue", basis(WORKER, version=1, key="denied-current-001"))
    assert denied.status_code == 403


def test_external_mutation_blocks_chain_without_rebasing_predecessor(version_client):
    client = version_client
    id_ = new_order(client)
    accepted = basis(WORKER, version=1, key="chain-accepted-001")
    cached = assert_ok(transition(client, id_, "accept", accepted))
    assert_ok(client.patch(f"/api/orders/{id_}", headers=MASTER, json={"comment": "Master changed assignment context"}))
    assert detail(client, id_)["version"] == 3
    assert assert_ok(transition(client, id_, "accept", accepted)) == cached
    stale = transition(client, id_, "start", basis(WORKER, previous="chain-accepted-001", key="chain-start-001"))
    assert stale.status_code == 409 and stale.json()["detail"]["expected_version"] == 2
    assert detail(client, id_)["status"] == "accepted"


def test_create_receipt_and_keyed_patch_predecessor_exact_replay(version_client):
    client = version_client
    body = {"title": "Synthetic creation receipt", "description": "Immutable predecessor", "work_type": "planned", "area_id": 1, "equipment_id": 3, "assignee_id": 6, "deadline": (utcnow() + timedelta(hours=2)).isoformat()}
    created = assert_ok(client.post("/api/orders", headers=basis(MASTER, key="master-create-proof-001"), json=body), 201)
    assert created["version"] == 1
    path = f"/api/orders/{created['id']}"
    patch = basis(MASTER, previous="master-create-proof-001", key="master-patch-proof-001")
    updated = assert_ok(client.patch(path, headers=patch, json={"comment": "First update"}))
    assert updated["version"] == 2
    assert_ok(client.patch(path, headers=MASTER, json={"comment": "Another update"}))
    assert assert_ok(client.patch(path, headers=patch, json={"comment": "First update"})) == updated
    with client.app.state.sessions() as db:
        receipts = list(db.scalars(sa.select(ClientCommand).order_by(ClientCommand.id)))
        assert [(row.order_id, row.order_version) for row in receipts] == [(created["id"], 1), (created["id"], 2)]


def test_photo_replay_keeps_old_receipt_but_fresh_stale_photo_is_rejected(version_client):
    client = version_client
    id_ = new_order(client)
    path = f"/api/orders/{id_}/photos"
    headers = basis(WORKER, version=1, key="photo-first-proof-001")
    def photo(headers):
        return client.post(path, headers=headers, data={"kind": "after"}, files={"file": ("after.png", photo_bytes(), "image/png")})
    cached = assert_ok(photo(headers), 201)
    assert cached["order_version"] == 2
    assert_ok(client.patch(f"/api/orders/{id_}", headers=MASTER, json={"assignee_id": 6}))
    assert assert_ok(photo(headers), 201) == cached
    stale = photo(basis(WORKER, version=1, key="photo-second-proof-001"))
    assert stale.status_code == 409 and stale.json()["detail"]["code"] == "order_version_conflict"
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(Photo)) == 1
        receipt = db.scalar(sa.select(ClientCommand).where(ClientCommand.client_id == "photo-first-proof-001"))
        assert receipt.order_version == 2


@pytest.mark.parametrize("decision,fields", [("close", {"score": 4}), ("rework", {"reason": "Check the repair again"})])
def test_manual_acceptance_requires_current_version(version_client, decision, fields):
    client = version_client
    id_ = worker_chain(client)
    path = f"/api/orders/{id_}"
    report = {"work_done": "Checked the synthetic equipment and repaired the part", "fault_code_id": 1}
    completed = assert_ok(client.post(path + "/complete", headers=basis(WORKER, version=3, key="manual-complete-001"), json=report))
    assert completed["version"] == 4
    stale = transition(client, id_, decision, basis(MASTER, version=3, key="stale-manual-decision-001"), **fields)
    assert stale.status_code == 409 and stale.json()["detail"]["code"] == "order_version_conflict"
    accepted = assert_ok(transition(client, id_, decision, basis(MASTER, version=4, key="master-manual-decision-001"), **fields))
    assert accepted["version"] == 5 and accepted["status"] == ("closed" if decision == "close" else "rework")


def test_header_validation_noop_and_cors(version_client):
    client = version_client
    id_ = new_order(client)
    path = f"/api/orders/{id_}/transition"
    for headers in [basis(WORKER, version=0), basis(WORKER, version="-1"), basis(WORKER, version="bad"), basis(WORKER, version=2_147_483_648), basis(WORKER, previous="previous-proof-001"), basis(WORKER, previous="bad", key="current-proof-001"), basis(WORKER, version=1, previous="previous-proof-001", key="current-proof-001")]:
        assert client.post(path, headers=headers, json={"action": "queue"}).status_code == 422
    assert assert_ok(transition(client, id_, "queue", basis(WORKER, version=1)))["version"] == 2
    assert assert_ok(transition(client, id_, "queue", basis(WORKER, version=2)))["version"] == 2
    response = client.options(path, headers={"Origin": "http://localhost:5173", "Access-Control-Request-Method": "POST", "Access-Control-Request-Headers": "X-Expected-Order-Version,X-Previous-Client-Command-Id,X-Client-Command-Id"})
    assert response.status_code == 200


@pytest.mark.parametrize("version_client", ["postgresql"], indirect=True)
def test_pg_parallel_same_version_mutations_have_single_effect(version_client):
    client = version_client
    id_ = new_order(client)
    path = f"/api/orders/{id_}"
    requests = [("PATCH", path, {"comment": text}, basis(MASTER, version=1, key=f"parallel-edit-{index:03d}")) for index, text in enumerate(["First edit", "Second edit"])]
    responses = parallel_requests(client, *requests)
    assert sorted(response.status_code for response in responses) == [200, 409], [response.text for response in responses]
    rejected = next(response for response in responses if response.status_code == 409)
    assert rejected.json()["detail"]["code"] == "order_version_conflict"
    current = detail(client, id_)
    assert current["version"] == 2
    assert len([event for event in current["events"] if event["action"] == "edit"]) == 1
