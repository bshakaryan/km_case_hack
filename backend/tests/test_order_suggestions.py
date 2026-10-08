from app import order_suggestions
from types import SimpleNamespace
from conftest import auth_headers


PAYLOAD = {"description": "Течь масла на насосе, проверить уплотнение", "area_id": 2, "equipment_id": 8}


def test_suggestions_require_master_and_matching_equipment(client, master, worker, monkeypatch):
    monkeypatch.setattr(order_suggestions, "classify_problem", lambda *args: None)
    assert client.post("/api/orders/suggestions", json=PAYLOAD, headers=worker).status_code == 403
    bad = {**PAYLOAD, "area_id": 1}
    assert client.post("/api/orders/suggestions", json=bad, headers=master).status_code == 422
    result = client.post("/api/orders/suggestions", json=PAYLOAD, headers=master)
    assert result.status_code == 200
    assert result.json()["source"] == "unavailable"
    assert result.json()["employee"] is None


def test_suggestions_choose_catalogue_values_and_free_worker(client, master, monkeypatch):
    monkeypatch.setattr(order_suggestions, "classify_problem", lambda *args: {
        "fault_code_id": 5, "time_norm_id": 5, "specialty": "Слесарь-ремонтник",
    })
    before = len(client.get("/api/orders", headers=master).json())
    result = client.post("/api/orders/suggestions", json=PAYLOAD, headers=master)
    assert result.status_code == 200, result.text
    data = result.json()
    assert data["source"] == "openai"
    assert data["fault_code"]["code"] == "F05"
    assert data["time_norm"]["hours"] == 1
    if data["employee"] is not None:
        workers = client.get("/api/employees", headers=master).json()
        chosen = next(row for row in workers if row["id"] == data["employee"]["id"])
        assert chosen["status"] == "free"
        assert chosen["specialty"] == "Слесарь-ремонтник"
    assert len(client.get("/api/orders", headers=master).json()) == before


def test_unknown_model_ids_cannot_leave_catalogue(client, master, monkeypatch):
    monkeypatch.setattr(order_suggestions, "classify_problem", lambda *args: {
        "fault_code_id": 9999, "time_norm_id": 9999, "specialty": "Неизвестная",
    })
    result = client.post("/api/orders/suggestions", json=PAYLOAD, headers=master)
    assert result.status_code == 200
    assert result.json()["fault_code"] is None
    assert result.json()["time_norm"] is None
    assert result.json()["employee"] is None


def test_model_output_is_bounded_and_excludes_personal_data(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    sent = {}

    class Response:
        def raise_for_status(self):
            pass

        def json(self):
            return {"choices": [{"finish_reason": "stop", "message": {
                "content": '{"fault_code_id":999,"time_norm_id":5,"specialty":"Механик"}',
            }}]}

    def fake_post(url, **kwargs):
        sent.update(kwargs["json"])
        return Response()

    monkeypatch.setattr(order_suggestions.httpx, "post", fake_post)
    equipment = SimpleNamespace(type="Насос")
    faults = [SimpleNamespace(id=5, code="F05", name="Утечка масла")]
    norms = [SimpleNamespace(id=5, name="Устранение утечки", hours=1)]
    result = order_suggestions.classify_problem("Течь", equipment, faults, norms, ["Механик"])
    assert result is None
    assert "Данияр" not in str(sent)
    assert sent["store"] is False


def test_worker_fault_hint_is_scoped_read_only_and_catalogue_bounded(client, monkeypatch):
    worker = auth_headers(client, "worker")
    other_worker = auth_headers(client, "worker2")
    active = next(row for row in client.get("/api/orders", headers=worker).json()
                  if row["status"] == "in_progress" and row["assignee_id"] == 5)
    path = f"/api/orders/{active['id']}/fault-suggestion"
    assert client.post(path, json={"work_done": "Проверил насос"}, headers=other_worker).status_code == 403
    assert client.post(path, json={}, headers=auth_headers(client, "master")).status_code == 403
    before = client.get(f"/api/orders/{active['id']}", headers=worker).json()
    monkeypatch.setattr(order_suggestions, "classify_completion_fault", lambda *args: {"fault_code_id": 5})
    answer = client.post(path, json={"work_done": "Устранил течь масла"}, headers=worker)
    assert answer.status_code == 200, answer.text
    assert answer.json()["fault_code"]["code"] == "F05"
    after = client.get(f"/api/orders/{active['id']}", headers=worker).json()
    assert after["version"] == before["version"]
    assert after["completion"] == before["completion"]
    monkeypatch.setattr(order_suggestions, "classify_completion_fault", lambda *args: {"fault_code_id": 9999})
    answer = client.post(path, json={}, headers=worker)
    assert answer.status_code == 200
    assert answer.json()["fault_code"] is None


def test_worker_fault_hint_requires_in_progress_order(client, monkeypatch):
    worker = auth_headers(client, "worker")
    assigned = [row for row in client.get("/api/orders", headers=worker).json()
                if row["assignee_id"] == 5 and row["status"] != "in_progress"]
    assert assigned
    monkeypatch.setattr(order_suggestions, "classify_completion_fault", lambda *args: {"fault_code_id": 5})
    answer = client.post(f"/api/orders/{assigned[0]['id']}/fault-suggestion", json={}, headers=worker)
    assert answer.status_code == 409
