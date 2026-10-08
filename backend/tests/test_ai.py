import json
from datetime import timedelta

import httpx
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from app.ai import OpenAIProvider, process_one_review
from app.main import create_app
from app.models import AIAssessment, AIReviewJob, Order, OrderEvent, utcnow


class FakeAI:
    model = "fake-model"

    def review(self, snapshot, images):
        return {"verdict": "passed", "score": 4.5, "confidence": 0.9, "explanation": "Работы соответствуют описанию", "photo_summary": "Фото не представлены", "issues": []}

    def explain(self, facts, question, schema, name):
        self.last_question = question
        if name == "order_hints":
            return {"fault_code_id": 1, "time_norm_id": 1, "explanation": "Предположение по описанию"}
        if name == "master_answer":
            return {"answer": "Проверьте состояние смены", "fact_ids": [facts[0]["id"]]}
        return {"summary": "Найдены повторные работы", "insights": [{"title": "Проверить оборудование", "description": "В выборке есть внеплановые работы", "recommendation": "Проверить историю", "fact_ids": [facts[0]["id"]]}]}


class FailingAI(FakeAI):
    def review(self, snapshot, images):
        raise httpx.TimeoutException("synthetic timeout")


def headers(client, login):
    response = client.post("/api/auth/login", json={"login": login, "pin": "1234"})
    assert response.status_code == 200
    return {"Authorization": "Bearer " + response.json()["token"]}


def submitted_order(client, master, worker):
    response = client.post("/api/orders", json={"title": "Замена узла насоса", "description": "Алексей Ким сообщил о вибрации насоса", "work_type": "planned", "area_id": 1, "equipment_id": 3, "assignee_id": 6, "deadline": (utcnow() + timedelta(hours=4)).isoformat()}, headers=master)
    assert response.status_code == 201, response.text
    order_id = response.json()["id"]
    path = f"/api/orders/{order_id}"
    assert client.post(path + "/transition", json={"action": "accept"}, headers=worker).status_code == 200
    assert client.post(path + "/transition", json={"action": "start"}, headers=worker).status_code == 200
    response = client.post(path + "/complete", json={"work_done": "Алексей Ким заменил узел и проверил запуск", "fault_code_id": 1, "materials": [{"material_id": 1, "quantity": 1}]}, headers=worker)
    assert response.status_code == 200, response.text
    return order_id, response.json()


def test_persisted_review_human_decision_and_ai_routes(tmp_path):
    provider = FakeAI()
    app = create_app(f"sqlite:///{tmp_path / 'ai.db'}", monitor=False, ai_provider=provider, ai_worker=False)
    with TestClient(app) as client:
        master = headers(client, "master")
        worker = headers(client, "worker2")
        order_id, completed = submitted_order(client, master, worker)
        assert completed["status"] == "completed"
        assert completed["ai_review"] is None
        with app.state.sessions() as db:
            job = db.scalar(select(AIReviewJob).where(AIReviewJob.order_id == order_id))
            assert job.status == "pending"
            assert "Алексей Ким" not in str(job.snapshot)
        assert process_one_review(app.state.sessions, FakeAI()) is True
        assert process_one_review(app.state.sessions, FakeAI()) is False
        reviewed = client.get(f"/api/orders/{order_id}", headers=master).json()
        assert reviewed["status"] == "ai_review"
        assert reviewed["ai_review"]["is_stub"] is False
        assert reviewed["ai_review"]["verdict"] == "passed"
        assert client.post(f"/api/orders/{order_id}/transition", json={"action": "close", "score": 5}, headers=worker).status_code == 403
        closed = client.post(f"/api/orders/{order_id}/transition", json={"action": "close", "score": 5}, headers=master).json()
        assert closed["status"] == "closed"
        with app.state.sessions() as db:
            assert db.scalar(select(func.count()).select_from(AIAssessment).where(AIAssessment.order_id == order_id)) == 1
            assert db.scalar(select(func.count()).select_from(OrderEvent).where(OrderEvent.order_id == order_id, OrderEvent.action == "ai_review")) == 1
        assert client.post("/api/ai/insights", headers=worker).status_code == 403
        insights = client.post("/api/ai/insights", headers=master).json()
        assert insights["insights"][0]["fact_ids"] == ["total"]
        assert any(fact["id"] == "equipment_baseline" for fact in insights["facts"])
        assert any(fact["id"].startswith("maintenance:") for fact in insights["facts"])
        answer = client.post("/api/ai/assistant", json={"question": "Где сейчас Алексей Ким?"}, headers=master).json()
        assert answer["fact_ids"] == ["worker:5"]
        assert answer["facts"][0]["id"] == "worker:5"
        assert "Алексей Ким" not in provider.last_question
        assert client.post("/api/ai/order-hints", json={"description": "Сильная вибрация узла насоса"}, headers=master).json()["fault_code_id"] == 1


def test_cancelled_submission_ignores_late_ai_result(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'stale.db'}", monitor=False, ai_provider=FakeAI(), ai_worker=False)
    with TestClient(app) as client:
        master = headers(client, "master")
        worker = headers(client, "worker2")
        order_id, _ = submitted_order(client, master, worker)
        cancelled = client.post(f"/api/orders/{order_id}/transition", json={"action": "cancel", "reason": "Ошибка выдачи"}, headers=master)
        assert cancelled.status_code == 200
        assert process_one_review(app.state.sessions, FakeAI()) is True
        with app.state.sessions() as db:
            assert db.get(Order, order_id).status == "cancelled"
            assert db.scalar(select(AIReviewJob).where(AIReviewJob.order_id == order_id)).status == "stale"


def test_failed_model_falls_back_to_manual_review(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'failed.db'}", monitor=False, ai_provider=FailingAI(), ai_worker=False)
    with TestClient(app) as client:
        master = headers(client, "master")
        worker = headers(client, "worker2")
        order_id, _ = submitted_order(client, master, worker)
        for attempt in range(3):
            assert process_one_review(app.state.sessions, FailingAI()) is True
            with app.state.sessions() as db:
                job = db.scalar(select(AIReviewJob).where(AIReviewJob.order_id == order_id))
                assert job.attempts == attempt + 1
                if attempt < 2:
                    job.next_run_at = utcnow() - timedelta(seconds=1)
                    db.commit()
        reviewed = client.get(f"/api/orders/{order_id}", headers=master).json()
        assert reviewed["status"] == "ai_review"
        assert reviewed["ai_review"]["verdict"] == "needs_attention"
        assert reviewed["ai_review"]["is_stub"] is True
        with app.state.sessions() as db:
            assessment = db.scalar(select(AIAssessment).where(AIAssessment.order_id == order_id))
            assert assessment.is_stub is True


def test_openai_request_is_structured_and_not_stored():
    requests = []

    def respond(request):
        requests.append(request)
        return httpx.Response(200, json={"status": "completed", "output": [{"type": "message", "content": [{"type": "output_text", "text": json.dumps({"verdict": "passed", "score": 4, "confidence": 0.9, "explanation": "Проверить мастеру", "photo_summary": "Снимок получен", "issues": []})}]}]})

    client = httpx.Client(transport=httpx.MockTransport(respond))
    provider = OpenAIProvider(api_key="synthetic-key", model="gpt-4.1-mini", client=client)
    result = provider.review({"problem": "Вибрация насоса", "work_done": "Замена узла"}, [("after", b"synthetic-jpeg")])
    assert result["verdict"] == "passed"
    request = requests[0]
    body = json.loads(request.content)
    assert request.headers["authorization"] == "Bearer synthetic-key"
    assert body["store"] is False
    assert body["text"]["format"]["type"] == "json_schema"
    assert body["text"]["format"]["schema"]["properties"]["score"]["maximum"] == 5
    assert body["input"][0]["content"][2]["type"] == "input_image"


def test_migration_preserves_populated_database(tmp_path):
    database = tmp_path / "populated.db"
    app = create_app(f"sqlite:///{database}", monitor=False, ai_provider=False)
    with TestClient(app):
        with app.state.sessions() as db:
            before = db.scalar(select(func.count()).select_from(Order))
            assert before >= 550
    config = Config("alembic.ini")
    config.set_main_option("sqlalchemy.url", f"sqlite:///{database.as_posix()}")
    command.upgrade(config, "head")
    command.upgrade(config, "head")
    with app.state.sessions() as db:
        assert db.scalar(select(func.count()).select_from(Order)) == before
        assert db.scalar(select(func.count()).select_from(AIReviewJob)) == 0
