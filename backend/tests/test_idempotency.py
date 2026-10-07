from datetime import timedelta

from sqlalchemy import func, select

from app.models import ClientCommand, MaterialWriteoff, Order, Photo, utcnow
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


def test_command_key_is_scoped_per_user(client, master, worker):
    shared_key = "offline-shared-0001"
    created = new_order(client, master, key=shared_key, title="Наряд мастера с общим ключом")
    assert created["id"]
    other = new_order(client, master, title="Наряд для проверки перехода")
    accepted = client.post(f"/api/orders/{other['id']}/transition", json={"action": "accept"}, headers={**worker, "X-Client-Command-Id": shared_key})
    assert accepted.status_code == 200, accepted.text
    assert accepted.json()["status"] == "accepted"


def test_manager_cannot_use_master_key_to_create(client, master, worker):
    manager = auth_headers(client, "manager")
    key = "offline-role-0001"
    allowed = client.post("/api/orders", json=create_payload(title="Наряд от мастера"), headers={**master, "X-Client-Command-Id": key})
    assert allowed.status_code == 201
    denied = client.post("/api/orders", json=create_payload(title="Наряд от менеджера"), headers={**manager, "X-Client-Command-Id": key})
    assert denied.status_code == 403
