from datetime import timedelta

import httpx
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.ai import process_one_review
from app.ai_service_client import AIServiceProvider
from app.main import create_app
from app.models import AIReviewJob, utcnow


class FakeService:
    mode = "service"
    model = "ai_service"

    def review(self, snapshot, images):
        return {
            "verdict": "passed", "service_verdict": "accepted", "score": 4,
            "confidence": 0.8, "explanation": "Работы соответствуют задаче",
            "explanation_worker": "Работы описаны", "photo_summary": "Время съёмки неизвестно",
            "issues": ["Проверьте время съёмки"], "flags": {"time_status": "within_norm"},
            "remarks": [{"text": "Проверьте фото", "evidence_ref": "after_photo"}],
            "needs_master_review": True, "photo_review": {"after_photo_id": None},
            "checked_without_llm": True,
        }


class FailingService(FakeService):
    def review(self, snapshot, images):
        raise httpx.TimeoutException("service timeout")


class GatewayService(FakeService):
    async def download(self, path, params):
        return b"%PDF-test" if params["format"] == "pdf" else b"PK-test"

    async def get(self, path, params=None):
        if path == "/ai/analytics":
            return {"orders_analyzed": 12, "findings": [{"kind": "high_failure_equipment",
                    "summary": "Насос: 12 внеплановых нарядов", "recommendation": "Проверить насос",
                    "order_ids": [1, 2]}]}
        if path.startswith("/ai/reports/orders/"):
            return {"audience": params["audience"], "order_id": int(path.rsplit("/", 1)[1])}
        if path == "/ai/reports/shift":
            return {"issued": 2, "completed": 1}
        if path == "/ai/ratings":
            return {"ratings": [{"employee_id": 6, "score": 80}, {"employee_id": 7, "score": 50}]}
        raise AssertionError(path)

    async def post(self, path, payload):
        if path == "/ai/assistant/ask":
            return {"status": "answered", "tool": "available_workers", "answer": "Свободных: 2",
                    "facts": {"free_workers": 2}}
        if path == "/ai/intake/text":
            return {"draft": {"fault_code_id": 1, "time_norm_id": 2}}
        raise AssertionError(path)


def headers(client, login):
    response = client.post("/api/auth/login", json={"login": login, "pin": "1234"})
    assert response.status_code == 200, response.text
    return {"Authorization": "Bearer " + response.json()["token"]}


def submit(client, master, worker):
    created = client.post("/api/orders", json={
        "title": "Проверка насоса", "description": "Проверить вибрацию насоса",
        "work_type": "planned", "area_id": 1, "equipment_id": 3, "assignee_id": 6,
        "deadline": (utcnow() + timedelta(hours=4)).isoformat(),
    }, headers=master)
    assert created.status_code == 201, created.text
    order_id = created.json()["id"]
    path = f"/api/orders/{order_id}"
    assert client.post(path + "/transition", json={"action": "accept"}, headers=worker).status_code == 200
    assert client.post(path + "/transition", json={"action": "start"}, headers=worker).status_code == 200
    completed = client.post(path + "/complete", json={
        "work_done": "Проверена вибрация и выполнен ремонт насоса", "fault_code_id": 1,
    }, headers=worker)
    assert completed.status_code == 200, completed.text
    return path, completed.json()


def test_service_review_is_pending_then_requires_human_decision(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'review.db'}", monitor=False, ai_provider=FakeService(), ai_worker=False)
    with TestClient(app) as client:
        master = headers(client, "master")
        worker = headers(client, "worker2")
        path, pending = submit(client, master, worker)
        assert pending["status"] == "ai_review"
        assert pending["ai_review"] is None
        assert client.post(path + "/transition", json={"action": "close", "score": 4}, headers=master).status_code == 409
        assert process_one_review(app.state.sessions, FakeService()) is True
        reviewed = client.get(path, headers=master).json()
        assert reviewed["ai_review"]["flags"]["time_status"] == "within_norm"
        assert reviewed["ai_review"]["checked_without_llm"] is True
        assert client.post(path + "/transition", json={"action": "close", "score": 5}, headers=master).status_code == 422
        closed = client.post(path + "/transition", json={"action": "close", "score": 5, "reason": "Осмотр подтвердил качество"}, headers=master)
        assert closed.status_code == 200, closed.text
        assert closed.json()["status"] == "closed"
        assert closed.json()["ai_review"]["master_score"] == 5


def test_read_only_service_snapshot_requires_its_own_token(tmp_path, monkeypatch):
    monkeypatch.setenv("AI_SERVICE_TOKEN", "private-service-token")
    app = create_app(f"sqlite:///{tmp_path / 'source.db'}", monitor=False, ai_provider=False)
    with TestClient(app) as client:
        assert client.get("/api/ai-service/snapshot").status_code == 401
        assert client.get("/api/ai-service/snapshot", headers={"Authorization": "Bearer wrong"}).status_code == 401
        response = client.get("/api/ai-service/snapshot", headers={"Authorization": "Bearer private-service-token"})
        assert response.status_code == 200, response.text
        assert response.json()["orders"]
        assert "pin_hash" not in response.text
        assert client.post("/api/ai-service/snapshot", headers={"Authorization": "Bearer private-service-token"}).status_code == 405


def test_service_timeout_falls_back_without_invented_score(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'fallback.db'}", monitor=False, ai_provider=FailingService(), ai_worker=False)
    with TestClient(app) as client:
        master = headers(client, "master")
        worker = headers(client, "worker2")
        path, _ = submit(client, master, worker)
        for attempt in range(3):
            assert process_one_review(app.state.sessions, FailingService()) is True
            with app.state.sessions() as db:
                job = db.scalar(select(AIReviewJob).where(AIReviewJob.order_id == int(path.rsplit("/", 1)[1])))
                if attempt < 2:
                    job.next_run_at = utcnow() - timedelta(seconds=1)
                    db.commit()
        reviewed = client.get(path, headers=master).json()
        assert reviewed["status"] == "ai_review"
        assert reviewed["ai_review"]["score"] is None
        assert reviewed["ai_review"]["service_verdict"] == "needs_master_review"
        assert reviewed["ai_review"]["checked_without_llm"] is True
        assert reviewed["ai_review"]["flags"]["material_norm_status"] == "unknown"
        assert reviewed["ai_review"]["flags"]["time_status"] in {"unknown", "within_norm", "over_norm"}
        assert client.post(path + "/transition", json={"action": "close", "score": 4}, headers=master).status_code == 422
        assert client.post(path + "/transition", json={"action": "close", "score": 4, "reason": "Осмотр выполнен"}, headers=master).status_code == 200


def test_service_client_rejects_result_for_other_submission():
    def respond(request):
        assert request.headers["authorization"] == "Bearer local-secret"
        assert request.url.path == "/ai/reviews/7/evaluate"
        return httpx.Response(200, json={
            "review": {"source_version": "event:9", "verdict": "accepted", "suggested_score": 5,
                       "match_confidence": 0.9, "flags": {}, "remarks": [], "concerns": [],
                       "explanation_worker": "Готово", "explanation_master": "Проверено",
                       "llm_used": False, "needs_master_review": False},
            "photo_review": {"source_version": "event:9", "needs_master_review": True, "reasons": []},
        })

    provider = AIServiceProvider("http://service:8090", "local-secret", httpx.Client(transport=httpx.MockTransport(respond)))
    result = provider.review({"order_id": 7, "source_version": "event:9"}, [])
    assert result["score"] is None
    assert result["service_verdict"] == "needs_master_review"
    assert result["verdict"] == "needs_attention"
    try:
        provider.review({"order_id": 7, "source_version": "event:10"}, [])
    except ValueError:
        pass
    else:
        raise AssertionError("Устаревший ответ ИИ принят")


def test_service_gateway_respects_roles_and_maps_existing_interface(tmp_path):
    app = create_app(f"sqlite:///{tmp_path / 'gateway.db'}", monitor=False, ai_provider=GatewayService(), ai_worker=False)
    with TestClient(app) as client:
        master = headers(client, "master")
        worker = headers(client, "worker2")
        path, _ = submit(client, master, worker)
        report = client.get("/api/ai/reports/orders/" + path.rsplit("/", 1)[1], headers=worker)
        assert report.status_code == 200
        assert report.json()["audience"] == "worker"
        pdf = client.get("/api/ai/reports/orders/" + path.rsplit("/", 1)[1] + "?format=pdf", headers=worker)
        assert pdf.status_code == 200 and pdf.content.startswith(b"%PDF")
        assert client.post("/api/ai/insights", headers=worker).status_code == 403
        insight = client.post("/api/ai/insights", headers=master).json()
        assert insight["insights"][0]["order_ids"] == [1, 2]
        assert client.post("/api/ai/insights?equipment_id=3", headers=master).status_code == 422
        assistant = client.post("/api/ai/assistant", json={"question": "Кто свободен?"}, headers=master).json()
        assert assistant["tool"] == "available_workers"
        hint = client.post("/api/ai/order-hints", json={"description": "Течь в насосе на участке"}, headers=master).json()
        assert hint["fault_code_id"] == 1
        start = (utcnow() - timedelta(days=1)).isoformat()
        end = utcnow().isoformat()
        assert client.get("/api/ai/reports/shift", params={"start": start, "end": end}, headers=worker).status_code == 403
        assert client.get("/api/ai/reports/shift", params={"start": start, "end": end}, headers=master).json()["issued"] == 2
        shift_xlsx = client.get("/api/ai/reports/shift", params={"start": start, "end": end, "format": "xlsx"}, headers=master)
        assert shift_xlsx.status_code == 200 and shift_xlsx.content.startswith(b"PK")
        ratings = client.get("/api/ai/ratings", params={"start": start, "end": end}, headers=worker).json()
        assert [item["employee_id"] for item in ratings["ratings"]] == [6]
