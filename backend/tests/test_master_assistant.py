from app import master_assistant
from conftest import auth_headers


def test_master_assistant_uses_current_read_only_data_and_role(client, master, worker, monkeypatch):
    monkeypatch.setattr(master_assistant, "classify", lambda question: (
        "free_workers" if "свобод" in question else
        "overdue" if "просроч" in question else "weekly_report", False,
    ))
    before = len(client.get("/api/orders", headers=master).json())
    assert client.post("/api/assistant/ask", json={"message": "Кто свободен?"}, headers=worker).status_code == 403
    assert client.post("/api/assistant/ask", json={"message": "Кто свободен?"}, headers=auth_headers(client, "admin")).status_code == 403
    assert client.post("/api/assistant/ask", json={"message": "x"}, headers=master).status_code == 422

    free = client.post("/api/assistant/ask", json={"message": "Кто свободен из электриков?"}, headers=master)
    assert free.status_code == 200
    assert free.json()["kind"] == "free_workers"
    assert "электриков" in free.json()["answer"]
    overdue = client.post("/api/assistant/ask", json={"message": "Что просрочено?"}, headers=master)
    assert overdue.status_code == 200
    assert "просрочено" in overdue.json()["answer"]
    report = client.post("/api/assistant/ask", json={"message": "Отчёт за неделю по участку обогащения"}, headers=master)
    assert report.status_code == 200
    assert "Обогатительная фабрика" in report.json()["answer"]
    assert len(client.get("/api/orders", headers=master).json()) == before


def test_llm_only_selects_allowed_intent(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-key")
    sent = {}

    class Response:
        def raise_for_status(self):
            pass

        def json(self):
            return {"choices": [{"finish_reason": "stop", "message": {"content": '{"kind":"overdue"}'}}]}

    def fake_post(url, **kwargs):
        sent.update(kwargs["json"])
        return Response()

    monkeypatch.setattr(master_assistant.httpx, "post", fake_post)
    assert master_assistant.classify("Что просрочено?") == ("overdue", True)
    assert sent["store"] is False
    assert sent["response_format"]["json_schema"]["schema"]["properties"]["kind"]["enum"] == ["free_workers", "overdue", "weekly_report", "other"]
