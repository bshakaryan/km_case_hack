import asyncio
import io
import json
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image, ImageDraw

from app.analytics import AnalyticsService
from app.config import Settings
from app.datasource import DataSource
from app.llm_client import LLMClient
from app.main import create_app
from app.photos import PhotoReviewService, compare_images
from app.schemas import Snapshot
from app.storage import AIStore
from data_gen.generate import generate
from eval.run import evaluate_analytics, evaluate_photo_duplicates


NOW = datetime(2026, 10, 7, 9, tzinfo=timezone.utc)


class MemorySource(DataSource):
    def __init__(self, snapshot, photos):
        self.value = Snapshot.model_validate(snapshot)
        self.photos = photos
        self.reads = 0

    async def snapshot(self):
        return self.value

    async def photo_bytes(self, photo):
        self.reads += 1
        return self.photos[photo.id]


def drawing(color):
    image = Image.new("RGB", (160, 160), (225, 221, 201))
    artist = ImageDraw.Draw(image)
    if color[0] > color[1]:
        artist.ellipse((8, 8, 78, 78), fill=color)
        artist.line((0, 160, 160, 0), fill=(35, 35, 35), width=9)
    else:
        artist.rectangle((82, 82, 152, 152), fill=color)
        artist.line((0, 0, 160, 160), fill=(35, 35, 35), width=9)
    output = io.BytesIO()
    image.save(output, format="PNG")
    return output.getvalue()


def photo_snapshot(include_after=True):
    photos = [{"id": 1, "kind": "before", "created_at": NOW + timedelta(minutes=2)}]
    if include_after:
        photos.append({"id": 2, "kind": "after", "created_at": NOW + timedelta(minutes=28)})
    return {"areas": [{"id": 1, "name": "Учебный участок"}],
            "employees": [{"id": 1, "name": "Арман Сериков", "role": "master"},
                          {"id": 2, "name": "Елена Садыкова", "role": "worker"}],
            "equipment": [{"id": 1, "name": "Насос", "inventory_number": "N-1", "area_id": 1}],
            "orders": [{"id": 7, "number": "147", "title": "Течь", "description": "Арман Сериков увидел течь.",
                        "work_type": "unplanned", "area_id": 1, "equipment_id": 1, "assignee_id": 2,
                        "master_id": 1, "priority": "normal", "status": "closed",
                        "created_at": NOW, "started_at": NOW, "completed_at": NOW + timedelta(minutes=30),
                        "deadline": NOW + timedelta(hours=1),
                        "completion": {"work_done": "Устранена течь насоса.", "fault_code_id": 1,
                                       "materials": []}, "photos": photos,
                        "events": [{"id": 1, "action": "complete", "to_status": "completed",
                                    "created_at": NOW + timedelta(minutes=30)}]}]}


def run(coroutine):
    return asyncio.run(coroutine)


def test_photo_fallback_duplicate_and_missing_after():
    before = drawing((190, 30, 20))
    after = drawing((25, 135, 80))
    assert compare_images(before, before)["duplicate"]
    assert not compare_images(before, after)["duplicate"]
    source = MemorySource(photo_snapshot(), {1: before, 2: before})
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    service = PhotoReviewService(source, store, LLMClient(Settings(), store), Settings())
    result = run(service.review(7))
    assert result["duplicate_before"]["duplicate"] and result["score"] is None
    assert result["needs_master_review"] and result["capture_time_status"] == "unknown"
    read_count = source.reads
    assert run(service.review(7)) == result and source.reads == read_count
    store.close()

    source = MemorySource(photo_snapshot(include_after=False), {1: before})
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    result = run(PhotoReviewService(source, store, LLMClient(Settings(), store), Settings()).review(7))
    assert result["after_photo_id"] is None and result["score"] is None
    store.close()


def test_photo_review_does_not_call_vision_without_cpu_model():
    class ForbiddenVision:
        def vision_enabled(self):
            return True

        async def inspect_photo(self, *_args):
            raise AssertionError("Vision API вызван без проверки оборудования")

    class MissingMatcher:
        def compare(self, *_args):
            return {"status": "unknown", "model_available": False, "embedding_cosine": None,
                    "orb_inliers": None, "orb_overlap": None, "ssim": None}

    source = MemorySource(photo_snapshot(), {1: drawing((190, 30, 20)),
                                             2: drawing((25, 135, 80))})
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    service = PhotoReviewService(source, store, ForbiddenVision(), Settings(data_source="synthetic"))
    service.equipment_matcher = MissingMatcher()
    result = run(service.review(7))
    assert result["equipment_check"]["status"] == "unknown"
    assert result["vision"] is None and result["needs_master_review"]
    store.close()


def test_reused_historical_photo_is_flagged():
    before = drawing((190, 30, 20))
    after = drawing((25, 135, 80))
    snapshot = photo_snapshot()
    older = json.loads(json.dumps(snapshot["orders"][0], default=str))
    older.update(id=8, number="146", created_at=NOW - timedelta(days=2),
                 started_at=NOW - timedelta(days=2), completed_at=NOW - timedelta(days=2, minutes=-30),
                 deadline=NOW - timedelta(days=1))
    older["photos"] = [{"id": 3, "kind": "after", "created_at": NOW - timedelta(days=1)}]
    snapshot["orders"].append(older)
    source = MemorySource(snapshot, {1: before, 2: after, 3: after})
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    result = run(PhotoReviewService(source, store, LLMClient(Settings(), store), Settings()).review(7))
    assert result["duplicate_history"]["photo_id"] == 3
    assert result["duplicate_history"]["order_id"] == 8
    assert result["needs_master_review"] and result["score"] is None
    store.close()


def test_old_after_photo_is_not_reused_for_new_completion_attempt():
    snapshot = photo_snapshot()
    snapshot["orders"][0]["events"].insert(0, {"id": 2, "action": "rework", "to_status": "rework",
                                                 "created_at": NOW + timedelta(minutes=29)})
    source = MemorySource(snapshot, {1: drawing((190, 30, 20)), 2: drawing((25, 135, 80))})
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    result = run(PhotoReviewService(source, store, LLMClient(Settings(), store), Settings()).review(7))
    assert result["after_photo_id"] is None
    assert result["needs_master_review"] and result["score"] is None
    store.close()


def test_mock_vision_uses_sanitized_images_and_rule_owned_score():
    sent = []

    def handler(request):
        payload = json.loads(request.content)
        sent.append(payload)
        assessment = {"same_equipment": True, "defect_resolved": True, "quality": "excellent",
                      "confidence": 0.92, "issues": [], "explanation": "Видимая течь устранена."}
        return httpx.Response(200, json={"output": [{"content": [{"type": "output_text",
                                                                "text": json.dumps(assessment)}]}]})

    before = drawing((190, 30, 20))
    after = drawing((25, 135, 80))
    source = MemorySource(photo_snapshot(), {1: before, 2: after})
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    settings = Settings(data_source="synthetic", demo_mode=False, llm_provider="openai",
                        llm_model_vision="mock-vision", openai_api_key="mock-key")
    llm = LLMClient(settings, store, httpx.MockTransport(handler))
    result = run(PhotoReviewService(source, store, llm, settings).review(7))
    assert result["status"] == "visual_assessment_available" and result["score"] == 5
    assert result["is_recommendation"] and result["needs_master_review"]
    assert "Время съёмки не подтверждено" in result["reasons"]
    serialized = json.dumps(sent, ensure_ascii=False)
    assert "Арман Сериков" not in serialized and "Елена Садыкова" not in serialized
    assert serialized.count("data:image/jpeg;base64") == 2
    assert len(sent) == 1 and llm.request_count == 1
    store.close()


def test_backend_vision_stays_disabled_even_with_key():
    settings = Settings(data_source="backend", demo_mode=False, llm_provider="openai",
                        llm_model_vision="mock-vision", openai_api_key="mock-key")
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    assert not LLMClient(settings, store).vision_enabled()
    store.close()


def test_anthropic_vision_retries_invalid_response_and_low_confidence_falls_back():
    calls = []

    def handler(request):
        payload = json.loads(request.content)
        calls.append(payload)
        assessment = {"same_equipment": True, "defect_resolved": True, "quality": "good",
                      "confidence": 0.2, "issues": [], "explanation": "Изображение нечёткое."}
        content = [] if len(calls) == 1 else [{"type": "tool_use", "name": "maintenance_photo_review",
                                               "input": assessment}]
        return httpx.Response(200, json={"content": content})

    source = MemorySource(photo_snapshot(), {1: drawing((190, 30, 20)), 2: drawing((25, 135, 80))})
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    settings = Settings(data_source="synthetic", demo_mode=False, llm_provider="anthropic",
                        llm_model_vision="mock-vision", anthropic_api_key="mock-key")
    llm = LLMClient(settings, store, httpx.MockTransport(handler))
    result = run(PhotoReviewService(source, store, llm, settings).review(7))
    assert result["score"] is None and result["needs_master_review"]
    assert any("Низкая уверенность" in reason for reason in result["reasons"])
    assert llm.request_count == 2 and len(calls) == 2
    assert calls[0]["tools"][0]["input_schema"]["type"] == "object"
    store.close()


@pytest.fixture(scope="module")
def generated(tmp_path_factory):
    root = tmp_path_factory.mktemp("phase5")
    data = root / "data"
    cases = root / "cases"
    generate(data, cases, photo_cases=False)
    return data, cases


def test_analytics_finds_seeded_patterns_and_no_decoys(generated):
    data, cases = generated
    snapshot = Snapshot.model_validate_json((data / "snapshot.json").read_text(encoding="utf-8"))
    truth = json.loads((cases / "analytics.json").read_text(encoding="utf-8"))
    result = run(evaluate_analytics(snapshot, truth))
    assert result["found_of_six"] == 6 and result["false_positive_decoys"] == 0
    assert result["additional_unlabeled_findings"] == 2
    service = AnalyticsService(MemorySource(snapshot, {}))
    full = run(service.analyze(datetime.fromisoformat(truth["period"]["from"]),
                               datetime.fromisoformat(truth["period"]["to"]) + timedelta(seconds=1)))
    assert full["top_equipment"][0]["id"] == 3
    assert all(set(item["order_ids"]) <= {order.id for order in snapshot.orders} for item in full["findings"])
    assert all(item["summary"] and item["recommendation"] for item in full["findings"])
    assert {item["dimension"] for item in full["associations"]} == {
        "shift", "hour", "employee_id", "brigade_id"}
    assert all("bonferroni_alpha" in item for item in full["associations"])
    assert not full["reported_downtime_verified"] and not full["causality_proven"]


def test_phase5_routes_use_service_token_and_do_not_change_order():
    before = drawing((190, 30, 20))
    after = drawing((25, 135, 80))
    source = MemorySource(photo_snapshot(), {1: before, 2: after})
    settings = Settings(ai_service_token="secret", ai_database_url="sqlite:///:memory:")
    app = create_app(settings, source)
    headers = {"Authorization": "Bearer secret"}
    with TestClient(app) as client:
        assert client.post("/ai/photos/7/review").status_code == 401
        assert client.post("/ai/photos/7/review", headers=headers).status_code == 202
        response = client.get("/ai/photos/7/review", headers=headers)
        assert response.status_code == 200 and response.json()["payload"]["needs_master_review"]
        report = client.get("/ai/reports/orders/7?audience=master", headers=headers).json()
        assert report["photo_review"]["needs_master_review"]
        params = {"start": NOW.isoformat(), "end": (NOW + timedelta(days=1)).isoformat()}
        assert client.get("/ai/analytics", headers=headers, params=params).status_code == 200
        assert client.get("/ai/analytics/weekly", headers=headers,
                          params={"end": (NOW + timedelta(days=1)).isoformat()}).status_code == 200
    assert source.value.orders[0].status == "closed"
