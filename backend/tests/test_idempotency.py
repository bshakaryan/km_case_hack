import hashlib
import json
from datetime import timedelta

import pytest

from sqlalchemy import func, select
from sqlalchemy.orm.attributes import flag_modified

from app.models import ClientCommand, MaterialWriteoff, Order, Photo, utcnow
from app.schemas import Completion, OrderCreate, Transition
from conftest import auth_headers


def create_payload(**overrides):
    payload = {"title": "Проверка повторной команды", "description": "Офлайн-очередь в тесте", "work_type": "planned", "area_id": 1, "equipment_id": 3, "assignee_id": 6, "priority": "normal", "deadline": (utcnow() + timedelta(hours=4)).isoformat()}
    payload.update(overrides)
    return payload


def new_order(client, headers, key=None, **overrides):
    request_headers = dict(headers)
    if key:
        request_headers["X-Client-Command-Id"] = key
    response = client.post("/api/orders", json=create_payload(**overrides), headers=request_headers)
    assert response.status_code == 201, response.text
    return response.json()


def cancel_test_order(client, master, order):
    response = client.post(
        f"/api/orders/{order['id']}/transition",
        json={"action": "cancel", "reason": "Очистка тестовых данных"},
        headers=master,
    )
    assert response.status_code == 200, response.text


def photo_bytes():
    import io

    from PIL import Image

    output = io.BytesIO()
    Image.new("RGB", (40, 30), "green").save(output, format="PNG")
    return output.getvalue()


def test_create_replay_returns_stored_response_without_duplicate(client, master):
    payload = create_payload(title="Повтор выдачи наряда")
    key = "offline-create-0001"
    first = client.post("/api/orders", json=payload, headers={**master, "X-Client-Command-Id": key})
    assert first.status_code == 201, first.text
    second = client.post("/api/orders", json=payload, headers={**master, "X-Client-Command-Id": key})
    assert second.status_code == 201, second.text
    assert second.json() == first.json()
    with client.app.state.sessions() as db:
        assert db.scalar(select(func.count()).select_from(Order).where(Order.title == "Повтор выдачи наряда")) == 1
        stored = db.scalar(select(ClientCommand).where(ClientCommand.client_id == key))
        assert stored is not None and stored.kind == "order_create" and stored.response_status == 201


def test_same_key_with_different_payload_conflicts(client, master):
    key = "offline-create-0002"
    first = client.post("/api/orders", json=create_payload(title="Первый вариант наряда"), headers={**master, "X-Client-Command-Id": key})
    assert first.status_code == 201, first.text
    second = client.post("/api/orders", json=create_payload(title="Другой вариант наряда"), headers={**master, "X-Client-Command-Id": key})
    assert second.status_code == 409, second.text
    assert "другим содержанием" in second.json()["detail"]


def test_missing_header_keeps_previous_behavior(client, master):
    payload = create_payload(title="Без ключа команды")
    first = client.post("/api/orders", json=payload, headers=master)
    second = client.post("/api/orders", json=payload, headers=master)
    assert first.status_code == 201 and second.status_code == 201
    assert first.json()["id"] != second.json()["id"]


def test_invalid_key_format_rejected(client, master):
    response = client.post("/api/orders", json=create_payload(title="Некорректный ключ"), headers={**master, "X-Client-Command-Id": "abc"})
    assert response.status_code == 422
    assert "X-Client-Command-Id" in response.json()["detail"]


def test_failed_validation_releases_key_for_retry(client, master):
    key = "offline-create-0003"
    past = create_payload(title="Просроченный наряд", deadline=(utcnow() - timedelta(hours=1)).isoformat())
    first = client.post("/api/orders", json=past, headers={**master, "X-Client-Command-Id": key})
    second = client.post("/api/orders", json=past, headers={**master, "X-Client-Command-Id": key})
    assert first.status_code == 422 and second.status_code == 422
    with client.app.state.sessions() as db:
        assert db.scalar(select(func.count()).select_from(ClientCommand).where(ClientCommand.client_id == key)) == 0


def test_transition_replay_keeps_single_event(client, master, worker):
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    headers = {**worker, "X-Client-Command-Id": "offline-accept-0001"}
    first = client.post(path + "/transition", json={"action": "accept"}, headers=headers)
    second = client.post(path + "/transition", json={"action": "accept"}, headers=headers)
    assert first.status_code == 200 and second.status_code == 200
    assert second.json() == first.json()
    events = client.get(path, headers=worker).json()["events"]
    assert len([event for event in events if event["action"] == "accept"]) == 1
    cancel_test_order(client, master, order)


def test_replay_returns_stored_response_even_if_state_moved_on(client, master, worker):
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    headers = {**worker, "X-Client-Command-Id": "offline-accept-0002"}
    assert client.post(path + "/transition", json={"action": "accept"}, headers=headers).status_code == 200
    assert client.post(path + "/transition", json={"action": "start"}, headers=worker).status_code == 200
    replay = client.post(path + "/transition", json={"action": "accept"}, headers=headers)
    assert replay.status_code == 200
    assert replay.json()["status"] == "accepted"
    assert client.get(path, headers=worker).json()["status"] == "in_progress"
    assert client.post(path + "/transition", json={"action": "cancel", "reason": "Очистка теста"}, headers=master).status_code == 200


def test_failed_transition_does_not_block_retry_with_same_key(client, master, worker):
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    headers = {**worker, "X-Client-Command-Id": "offline-start-0001"}
    first = client.post(path + "/transition", json={"action": "start"}, headers=headers)
    second = client.post(path + "/transition", json={"action": "start"}, headers=headers)
    assert first.status_code == 409 and second.status_code == 409
    assert "недоступно" in first.json()["detail"] and "недоступно" in second.json()["detail"]


def test_photo_upload_replay_stores_one_photo(client, master, worker):
    order = new_order(client, master, work_type="unplanned")
    path = f"/api/orders/{order['id']}"
    client.post(path + "/transition", json={"action": "accept"}, headers=worker)
    headers = {**worker, "X-Client-Command-Id": "offline-photo-0001"}
    data = {"kind": "before"}
    first = client.post(path + "/photos", data=data, files={"file": ("before.png", photo_bytes(), "image/png")}, headers=headers)
    second = client.post(path + "/photos", data=data, files={"file": ("before.png", photo_bytes(), "image/png")}, headers=headers)
    assert first.status_code == 201 and second.status_code == 201
    assert second.json() == first.json()
    with client.app.state.sessions() as db:
        assert db.scalar(select(func.count()).select_from(Photo).where(Photo.order_id == order["id"], Photo.kind == "before")) == 1
    cancel_test_order(client, master, order)


def test_photo_upload_same_key_different_file_conflicts(client, master, worker):
    order = new_order(client, master, work_type="unplanned")
    path = f"/api/orders/{order['id']}"
    client.post(path + "/transition", json={"action": "accept"}, headers=worker)
    headers = {**worker, "X-Client-Command-Id": "offline-photo-0002"}
    first = client.post(path + "/photos", data={"kind": "before"}, files={"file": ("a.png", photo_bytes(), "image/png")}, headers=headers)
    assert first.status_code == 201
    other = photo_bytes() + b"\x00"
    second = client.post(path + "/photos", data={"kind": "before"}, files={"file": ("b.png", other, "image/png")}, headers=headers)
    assert second.status_code == 409
    cancel_test_order(client, master, order)


def test_complete_replay_does_not_duplicate_material_writeoff(client, master, worker):
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    client.post(path + "/transition", json={"action": "accept"}, headers=worker)
    client.post(path + "/transition", json={"action": "start"}, headers=worker)
    completion = {"work_done": "Заменён узел и проведена проверка", "fault_code_id": 1, "materials": [{"material_id": 1, "quantity": 2}]}
    headers = {**worker, "X-Client-Command-Id": "offline-complete-0001"}
    first = client.post(path + "/complete", json=completion, headers=headers)
    second = client.post(path + "/complete", json=completion, headers=headers)
    assert first.status_code == 200 and second.status_code == 200
    assert second.json() == first.json()
    detail = client.get(path, headers=worker).json()
    quantities = [material["quantity"] for material in detail["completion"]["materials"] if material["material_id"] == 1]
    assert quantities == [2]
    with client.app.state.sessions() as db:
        assert db.scalar(select(func.count()).select_from(MaterialWriteoff).where(MaterialWriteoff.order_id == order["id"])) == 1
    cancel_test_order(client, master, order)


def test_command_key_is_scoped_per_user(client, master, worker):
    shared_key = "offline-shared-0001"
    created = new_order(client, master, key=shared_key, title="Наряд мастера с общим ключом")
    assert created["id"]
    other = new_order(client, master, title="Наряд для проверки перехода")
    accepted = client.post(f"/api/orders/{other['id']}/transition", json={"action": "accept"}, headers={**worker, "X-Client-Command-Id": shared_key})
    assert accepted.status_code == 200, accepted.text
    assert accepted.json()["status"] == "accepted"
    cancel_test_order(client, master, other)


def test_manager_cannot_use_master_key_to_create(client, master, worker):
    manager = auth_headers(client, "manager")
    key = "offline-role-0001"
    allowed = client.post("/api/orders", json=create_payload(title="Наряд от мастера"), headers={**master, "X-Client-Command-Id": key})
    assert allowed.status_code == 201
    denied = client.post("/api/orders", json=create_payload(title="Наряд от менеджера"), headers={**manager, "X-Client-Command-Id": key})
    assert denied.status_code == 403


def legacy_json_hash(schema, payload):
    normalized = schema.model_validate(payload).model_dump()
    if schema is OrderCreate:
        # Emulate the frozen pre-D04 request shape, before responsible_id.
        normalized.pop("responsible_id", None)
    encoded = json.dumps(normalized, sort_keys=True, ensure_ascii=False, default=str)
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def convert_to_legacy(client, key, schema, payload):
    with client.app.state.sessions() as db:
        stored = db.scalar(select(ClientCommand).where(ClientCommand.client_id == key))
        assert stored is not None
        stored.request_hash = legacy_json_hash(schema, payload)
        db.commit()


def test_transition_key_cannot_replay_on_another_order(client, master, worker):
    first_order = new_order(client, master)
    other_order = new_order(client, master)
    headers = {**worker, "X-Client-Command-Id": "target-accept-0001"}
    accepted = client.post(f"/api/orders/{first_order['id']}/transition", json={"action": "accept"}, headers=headers)
    assert accepted.status_code == 200
    conflict = client.post(f"/api/orders/{other_order['id']}/transition", json={"action": "accept"}, headers=headers)
    assert conflict.status_code == 409, conflict.text
    other = client.get(f"/api/orders/{other_order['id']}", headers=worker).json()
    assert other["status"] == "issued"
    assert not any(event["action"] == "accept" for event in other["events"])
    cancel_test_order(client, master, first_order)


def test_complete_key_cannot_replay_on_another_order(client, master, worker):
    completion = {"work_done": "Заменён узел и проведена проверка", "fault_code_id": 1, "materials": [{"material_id": 1, "quantity": 2}]}
    headers = {**worker, "X-Client-Command-Id": "target-complete-0001"}
    first_order = new_order(client, master)
    other_order = new_order(client, master)
    for order in [first_order, other_order]:
        path = f"/api/orders/{order['id']}"
        assert client.post(path + "/transition", json={"action": "accept"}, headers=worker).status_code == 200
        assert client.post(path + "/transition", json={"action": "start"}, headers=worker).status_code == 200
        result = client.post(path + "/complete", json=completion, headers=headers)
        if order is first_order:
            assert result.status_code == 200
        else:
            assert result.status_code == 409, result.text
    with client.app.state.sessions() as db:
        assert db.scalar(select(func.count()).select_from(MaterialWriteoff).where(MaterialWriteoff.order_id == other_order["id"])) == 0
    other_path = f"/api/orders/{other_order['id']}"
    assert client.get(other_path, headers=worker).json()["status"] == "in_progress"
    assert client.post(other_path + "/transition", json={"action": "cancel", "reason": "Очистка проверки"}, headers=master).status_code == 200
    client.post(f"/api/orders/{first_order['id']}/transition", json={"action": "cancel", "reason": "Очистка проверки"}, headers=master)


def test_key_cannot_be_reused_for_another_route(client, master):
    key = "route-create-transition-0001"
    order = new_order(client, master, key=key)
    result = client.post(f"/api/orders/{order['id']}/transition", json={"action": "cancel", "reason": "Повтор ключа"}, headers={**master, "X-Client-Command-Id": key})
    assert result.status_code == 409
    assert client.get(f"/api/orders/{order['id']}", headers=master).json()["status"] == "issued"


@pytest.mark.parametrize("stored_target", ["correct", "foreign", "missing", "string", "float", "boolean", "null"])
def test_legacy_transition_replay_requires_proven_target(client, master, worker, stored_target):
    key = f"legacy-accept-target-{stored_target}"
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    payload = {"action": "accept"}
    headers = {**worker, "X-Client-Command-Id": key}
    first = client.post(path + "/transition", json=payload, headers=headers)
    assert first.status_code == 200
    convert_to_legacy(client, key, Transition, payload)
    with client.app.state.sessions() as db:
        stored = db.scalar(select(ClientCommand).where(ClientCommand.client_id == key))
        body = dict(stored.response_body)
        if stored_target == "foreign":
            body["id"] += 1
        elif stored_target == "missing":
            body.pop("id")
        elif stored_target == "string":
            body["id"] = str(body["id"])
        elif stored_target == "float":
            body["id"] = float(body["id"])
        elif stored_target == "boolean":
            body["id"] = True
        elif stored_target == "null":
            body = None
        stored.response_body = body
        # JSON equality treats an integer and its float equivalent as equal;
        # force this deliberately malformed legacy fixture to reach the DB.
        flag_modified(stored, "response_body")
        db.commit()
    # Reassignment makes accept possible again: replay must never execute it.
    assert client.patch(path, json={"assignee_id": 6}, headers=master).status_code == 200
    replay = client.post(path + "/transition", json=payload, headers=headers)
    if stored_target == "correct":
        assert replay.status_code == 200 and replay.json() == first.json()
    else:
        assert replay.status_code == 409
    current = client.get(path, headers=worker).json()
    assert current["status"] == "issued"
    assert len([event for event in current["events"] if event["action"] == "accept"]) == 1


def test_legacy_transition_same_key_on_different_order_conflicts(client, master, worker):
    key = "legacy-accept-other-order"
    order = new_order(client, master)
    other = new_order(client, master)
    payload = {"action": "accept"}
    headers = {**worker, "X-Client-Command-Id": key}
    assert client.post(f"/api/orders/{order['id']}/transition", json=payload, headers=headers).status_code == 200
    convert_to_legacy(client, key, Transition, payload)
    assert client.post(f"/api/orders/{other['id']}/transition", json=payload, headers=headers).status_code == 409
    assert client.get(f"/api/orders/{other['id']}", headers=worker).json()["status"] == "issued"
    cancel_test_order(client, master, order)


def test_legacy_command_kind_is_checked_even_when_payload_hash_matches(client, master, worker):
    key = "legacy-kind-mismatch-0001"
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    payload = {"action": "accept"}
    headers = {**worker, "X-Client-Command-Id": key}
    assert client.post(path + "/transition", json=payload, headers=headers).status_code == 200
    convert_to_legacy(client, key, Transition, payload)
    with client.app.state.sessions() as db:
        stored = db.scalar(select(ClientCommand).where(ClientCommand.client_id == key))
        stored.kind = "complete"
        db.commit()
    assert client.post(path + "/transition", json=payload, headers=headers).status_code == 409
    cancel_test_order(client, master, order)


@pytest.mark.parametrize("target", ["same", "other", "missing"])
def test_legacy_complete_replay_never_reapplies_materials(client, master, worker, target):
    key = f"legacy-complete-target-{target}"
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    payload = {"work_done": "Заменён узел и проведена проверка", "fault_code_id": 1, "materials": [{"material_id": 1, "quantity": 2}]}
    headers = {**worker, "X-Client-Command-Id": key}
    assert client.post(path + "/transition", json={"action": "accept"}, headers=worker).status_code == 200
    assert client.post(path + "/transition", json={"action": "start"}, headers=worker).status_code == 200
    first = client.post(path + "/complete", json=payload, headers=headers)
    assert first.status_code == 200
    convert_to_legacy(client, key, Completion, payload)
    if target == "other":
        other = new_order(client, master)
        requested_path = f"/api/orders/{other['id']}"
    else:
        requested_path = path
        if target == "missing":
            with client.app.state.sessions() as db:
                stored = db.scalar(select(ClientCommand).where(ClientCommand.client_id == key))
                body = dict(stored.response_body)
                body.pop("id")
                stored.response_body = body
                db.commit()
        assert client.post(path + "/transition", json={"action": "rework", "reason": "Проверка сохранённой команды"}, headers=master).status_code == 200
    assert client.post(requested_path + "/transition", json={"action": "accept"}, headers=worker).status_code == 200
    assert client.post(requested_path + "/transition", json={"action": "start"}, headers=worker).status_code == 200
    replay = client.post(requested_path + "/complete", json=payload, headers=headers)
    if target == "same":
        assert replay.status_code == 200 and replay.json() == first.json()
    else:
        assert replay.status_code == 409
    current = client.get(requested_path, headers=worker).json()
    assert current["status"] == "in_progress"
    assert len([event for event in current["events"] if event["action"] == "complete"]) == (0 if target == "other" else 1)
    with client.app.state.sessions() as db:
        assert db.scalar(select(func.count()).select_from(MaterialWriteoff).where(MaterialWriteoff.order_id == order["id"])) == 1
        if target == "other":
            assert db.scalar(select(func.count()).select_from(MaterialWriteoff).where(MaterialWriteoff.order_id == other["id"])) == 0
    assert client.post(requested_path + "/transition", json={"action": "cancel", "reason": "Очистка проверки"}, headers=master).status_code == 200


def test_legacy_create_replay_keeps_applied_command(client, master):
    key = "legacy-create-0001"
    payload = create_payload(title="Сохранённая старая выдача")
    headers = {**master, "X-Client-Command-Id": key}
    first = client.post("/api/orders", json=payload, headers=headers)
    assert first.status_code == 201
    convert_to_legacy(client, key, OrderCreate, payload)
    replay = client.post("/api/orders", json=payload, headers=headers)
    assert replay.status_code == 201 and replay.json() == first.json()
    with client.app.state.sessions() as db:
        assert db.scalar(select(func.count()).select_from(Order).where(Order.title == payload["title"])) == 1


def test_legacy_photo_replay_keeps_one_file_after_order_closes(client, master, worker):
    key = "legacy-photo-0001"
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    headers = {**worker, "X-Client-Command-Id": key}
    image = photo_bytes()
    first = client.post(path + "/photos", data={"kind": "before"}, files={"file": ("before.png", image, "image/png")}, headers=headers)
    assert first.status_code == 201
    old_hash_parts = [str(order["id"]), "before", hashlib.sha256(image).hexdigest()]
    with client.app.state.sessions() as db:
        stored = db.scalar(select(ClientCommand).where(ClientCommand.client_id == key))
        stored.request_hash = hashlib.sha256("\x1f".join(old_hash_parts).encode("utf-8")).hexdigest()
        db.commit()
    assert client.post(path + "/transition", json={"action": "cancel", "reason": "Очистка проверки"}, headers=master).status_code == 200
    replay = client.post(path + "/photos", data={"kind": "before"}, files={"file": ("before.png", image, "image/png")}, headers=headers)
    assert replay.status_code == 201 and replay.json() == first.json()
    with client.app.state.sessions() as db:
        assert db.scalar(select(func.count()).select_from(Photo).where(Photo.order_id == order["id"])) == 1


def test_replay_rechecks_current_order_ownership(client, master, worker):
    key = "target-owner-replay-0001"
    order = new_order(client, master)
    path = f"/api/orders/{order['id']}"
    headers = {**worker, "X-Client-Command-Id": key}
    assert client.post(path + "/transition", json={"action": "accept"}, headers=headers).status_code == 200
    foreign = auth_headers(client, "worker")
    assert client.post(path + "/transition", json={"action": "accept"}, headers={**foreign, "X-Client-Command-Id": key}).status_code == 403
    assert client.patch(path, json={"assignee_id": 5}, headers=master).status_code == 200
    assert client.post(path + "/transition", json={"action": "accept"}, headers=headers).status_code == 403
