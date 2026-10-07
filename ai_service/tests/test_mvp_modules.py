import asyncio
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path

import httpx
from fastapi.testclient import TestClient

from app.config import Settings
from app.datasource import DataSource
from app.deadlines import DeadlineController
from app.llm_client import LLMClient
from app.main import create_app
from app.notifier import TelegramNotifier
from app.rating import RatingService
from app.reports import ReportService, export_pdf, export_xlsx
from app.schemas import OrderRecord, Snapshot
from app.storage import AIStore
from app.verification import CompletionVerifier, calculate_flags, decide_verdict, rule_semantics
from app.synthetic_source import SyntheticDataSource
from data_gen.generate import generate


NOW = datetime(2026, 10, 7, 9, tzinfo=timezone.utc)


class MemorySource(DataSource):
    def __init__(self, snapshot):
        self.value = Snapshot.model_validate(snapshot)

    async def snapshot(self):
        return self.value

    async def photo_bytes(self, photo):
        return b"image"


class CaptureNotifier:
    def __init__(self):
        self.sent = []

    async def send(self, recipient, title, message, idempotency_key):
        self.sent.append((recipient, title, message, idempotency_key))
        return True


def snapshot_data(status="closed"):
    completed = NOW + timedelta(minutes=40)
    return {
        "areas": [{"id": 1, "name": "Дробление"}],
        "employees": [
            {"id": 1, "name": "Арман Сериков", "role": "master"},
            {"id": 2, "name": "Елена Садыкова", "role": "worker", "specialty": "Слесарь"},
            {"id": 3, "name": "Алексей Ким", "role": "worker", "specialty": "Слесарь"},
            {"id": 4, "name": "Руководитель", "role": "manager"},
        ],
        "equipment": [{"id": 1, "name": "Насос НС-01", "inventory_number": "КМ-1", "area_id": 1}],
        "fault_codes": [{"id": 1, "code": "Г-01", "name": "Утечка масла"},
                        {"id": 2, "code": "Э-01", "name": "Повреждение кабеля"}],
        "materials": [{"id": 1, "name": "Масло", "unit": "л"}],
        "material_norms": [{"fault_code_id": 1, "material_id": 1, "quantity": 1}],
        "orders": [{
            "id": 7, "number": "147", "title": "Течь насоса",
            "description": "Арман Сериков заметил утечку масла; устранить на насосе.",
            "work_type": "unplanned", "area_id": 1, "equipment_id": 1,
            "assignee_id": 2, "master_id": 1, "priority": "emergency", "status": status,
            "deadline": NOW + timedelta(hours=1), "created_at": NOW,
            "started_at": NOW + timedelta(minutes=10), "completed_at": completed if status == "closed" else None,
            "closed_at": completed + timedelta(minutes=5) if status == "closed" else None,
            "normal_hours": 1, "downtime_minutes": 40, "score": 4.5 if status == "closed" else None,
            "comment": "Ждём подшипник со склада",
            "completion": {"work_done": "Устранена утечка масла, проверен насос.", "fault_code_id": 1,
                           "materials": [{"material_id": 1, "quantity": 1}]}
            if status == "closed" else None,
            "photos": [{"id": 5, "kind": "after", "created_at": completed - timedelta(minutes=2),
                        "path": "photos/after.png"}] if status == "closed" else [],
            "events": [{"id": 1, "action": "issue", "to_status": "issued", "created_at": NOW},
                       {"id": 2, "action": "complete", "from_status": "in_progress",
                        "to_status": "completed", "created_at": completed}]
            if status == "closed" else [{"id": 1, "action": "issue", "to_status": "issued", "created_at": NOW}],
        }],
    }


def run(coroutine):
    return asyncio.run(coroutine)


def test_deadline_tick_thresholds_repeats_and_persistence():
    data = snapshot_data("issued")
    data["orders"][0]["deadline"] = NOW + timedelta(minutes=45)
    source = MemorySource(data)
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    notifier = CaptureNotifier()
    controller = DeadlineController(source, store, notifier, Settings())
    escalation = run(controller.tick(NOW + timedelta(minutes=3)))
    assert len(escalation) == 1
    assert escalation[0]["type"] == "acceptance_escalation"
    assert "Алексей Ким" in escalation[0]["message"]
    warning = run(controller.tick(NOW + timedelta(minutes=15)))
    assert len(warning) == 1 and warning[0]["type"] == "deadline_warning"
    assert run(controller.tick(NOW + timedelta(minutes=15))) == []
    overdue = run(controller.tick(NOW + timedelta(minutes=45)))
    assert len(overdue) == 2 and {item["recipient"] for item in overdue} == {"E-02", "M-01"}
    assert "Насос НС-01" in overdue[0]["message"] and "Ждём подшипник" in overdue[0]["message"]
    repeated = run(controller.tick(NOW + timedelta(minutes=75)))
    assert len(repeated) == 2 and all(item["type"] == "overdue_repeat" for item in repeated)
    manager = run(controller.tick(NOW + timedelta(minutes=135)))
    assert any(item["type"] == "long_overdue" and item["recipient"] == "G-04" for item in manager)
    assert run(DeadlineController(source, store, notifier, Settings()).tick(NOW + timedelta(minutes=135))) == []
    store.close()


def test_rule_verdicts_and_unknown_not_zero():
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    settings = Settings(demo_mode=True)
    data = snapshot_data()
    accepted = run(CompletionVerifier(MemorySource(data), store, LLMClient(settings, store)).verify(7))
    assert accepted["verdict"] == "accepted" and not accepted["llm_used"]
    assert accepted["suggested_score"] == 5
    assert run(CompletionVerifier(MemorySource(data), store, LLMClient(settings, store)).verify(7)) == accepted
    store.close()


def test_rule_verdicts_fresh_store_per_card():
    def verdict(change):
        data = snapshot_data()
        change(data["orders"][0])
        store = AIStore("sqlite:///:memory:")
        store.initialize()
        result = run(CompletionVerifier(MemorySource(data), store, LLMClient(Settings(), store)).verify(7))
        store.close()
        return result

    assert verdict(lambda order: order["photos"].clear())["verdict"] == "needs_rework"
    assert verdict(lambda order: order["completion"]["materials"][0].update(quantity=2))["verdict"] == "accepted_with_remarks"
    assert verdict(lambda order: order["completion"].update(work_done="Заменён кабель на другом участке."))["verdict"] == "needs_rework"
    unknown = verdict(lambda order: order.update(normal_hours=None))
    assert unknown["verdict"] == "needs_master_review"
    assert unknown["flags"]["time_status"] == "unknown"
    assert unknown["suggested_score"] is None


def test_llm_prompt_is_anonymized_and_result_cached():
    seen = []

    def handler(request):
        payload = json.loads(request.content)
        seen.append(payload)
        answer = {"works_match_problem": True, "match_confidence": 0.9, "remarks": [],
                  "explanation_worker": "Работы соответствуют проблеме.",
                  "explanation_master": "Основание: описание работ."}
        return httpx.Response(200, json={"output": [{"content": [{"type": "output_text",
                                                               "text": json.dumps(answer)}]}],
                                         "usage": {"input_tokens": 20, "output_tokens": 10}})

    store = AIStore("sqlite:///:memory:")
    store.initialize()
    settings = Settings(demo_mode=False, llm_provider="openai", llm_model_fast="mock-model",
                        openai_api_key="mock-key")
    client = LLMClient(settings, store, httpx.MockTransport(handler))
    verifier = CompletionVerifier(MemorySource(snapshot_data()), store, client)
    result = run(verifier.verify(7))
    assert result["verdict"] == "accepted" and result["llm_used"]
    prompt = json.dumps(seen, ensure_ascii=False)
    assert "Арман Сериков" not in prompt and "Елена Садыкова" not in prompt
    assert seen[0]["text"]["format"]["type"] == "json_schema"
    assert len(seen) == 1
    assert run(client.interpret({"test": "same"})) is not None
    assert run(client.interpret({"test": "same"})) is not None
    assert len(seen) == 2
    assert client.request_count == 2 and client.cache_hits == 1
    assert client.input_tokens == 40 and client.output_tokens == 20
    assert len(client.request_latencies_ms) == 2
    store.close()


def test_invalid_llm_retries_then_falls_back():
    attempts = []

    def handler(request):
        attempts.append(request)
        return httpx.Response(200, json={"output": [{"content": [{"type": "output_text", "text": "not-json"}]}]})

    store = AIStore("sqlite:///:memory:")
    store.initialize()
    settings = Settings(demo_mode=False, llm_provider="openai", llm_model_fast="mock-model",
                        openai_api_key="mock-key")
    client = LLMClient(settings, store, httpx.MockTransport(handler))
    assert run(client.interpret({"problem": "течь"})) is None
    assert len(attempts) == 2
    store.close()


def test_anthropic_tool_result_and_bad_evidence_requires_review():
    calls = []

    def handler(request):
        payload = json.loads(request.content)
        calls.append(payload)
        answer = {"works_match_problem": True, "match_confidence": 0.95,
                  "remarks": [{"text": "Проверить доказательство", "evidence_ref": "event:999"}],
                  "explanation_worker": "Работы завершены.", "explanation_master": "Проверить ссылки."}
        return httpx.Response(200, json={"content": [{"type": "tool_use", "name": "maintenance_review",
                                                     "input": answer}]})

    store = AIStore("sqlite:///:memory:")
    store.initialize()
    settings = Settings(demo_mode=False, llm_provider="anthropic", llm_model_fast="mock-model",
                        anthropic_api_key="mock-key")
    client = LLMClient(settings, store, httpx.MockTransport(handler))
    result = run(CompletionVerifier(MemorySource(snapshot_data()), store, client).verify(7))
    assert result["verdict"] == "needs_master_review" and not result["llm_used"]
    assert calls[0]["tools"][0]["input_schema"]["type"] == "object"
    store.close()


def test_telegram_notifier_only_claims_confirmed_delivery():
    def handler(request):
        assert "Наряд" in json.loads(request.content)["text"]
        return httpx.Response(200, json={"ok": True})

    notifier = TelegramNotifier("mock-token", {"E-02": "123"}, httpx.MockTransport(handler))
    assert run(notifier.send("E-02", "Наряд", "Проверьте", "key")) is True
    assert run(notifier.send("E-03", "Наряд", "Проверьте", "key")) is False


def test_reports_exports_rating_and_override():
    source = MemorySource(snapshot_data())
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    review = run(CompletionVerifier(source, store, LLMClient(Settings(), store)).verify(7))
    reports = ReportService(source, store)
    worker = run(reports.order_report(7, "worker"))
    master = run(reports.order_report(7, "master"))
    assert worker["score"] == 4.5 and worker["score_source"] == "master"
    assert master["review"]["verdict"] == review["verdict"]
    assert master["actual_downtime_verified"] is False and len(master["events"]) == 2
    shift = run(reports.shift_report(NOW, NOW + timedelta(hours=12)))
    assert shift["issued"] == 1 and shift["completed"] == 1
    assert export_pdf(worker).startswith(b"%PDF")
    assert export_xlsx(master).startswith(b"PK")
    rating = run(RatingService(source, Settings()).calculate(NOW, NOW + timedelta(days=1)))
    assert rating["ratings"][0]["quality_sources"]["master"] == 1
    assert store.set_master_override("review", "7", review["source_version"],
                                     {"master_id": 1, "verdict": "accepted_with_remarks", "score": 4, "reason": "осмотр"})
    assert run(reports.order_report(7, "master"))["final_verdict"] == "accepted_with_remarks"
    store.close()


def test_rest_mvp_routes_protected_and_versioned():
    source = MemorySource(snapshot_data())
    settings = Settings(ai_service_token="secret", ai_database_url="sqlite:///:memory:")
    app = create_app(settings, source)
    headers = {"Authorization": "Bearer secret"}
    with TestClient(app) as client:
        assert client.post("/ai/deadlines/tick", json={"now": NOW.isoformat()}).status_code == 401
        response = client.post("/ai/reviews/7", headers=headers)
        assert response.status_code == 202
        review = client.get("/ai/reviews/7", headers=headers).json()
        assert review["payload"]["verdict"] == "accepted"
        override = client.post("/ai/reviews/7/master-override", headers=headers, json={
            "source_version": review["source_version"], "master_id": 1,
            "verdict": "accepted_with_remarks", "score": 4, "reason": "Проверено"})
        assert override.status_code == 200
        stale = client.post("/ai/reviews/7/master-override", headers=headers, json={
            "source_version": "old", "master_id": 1,
            "verdict": "accepted", "score": 5, "reason": "Проверено"})
        assert stale.status_code == 409
        assert client.get("/ai/reports/orders/7?audience=worker", headers=headers).status_code == 200
        assert client.get("/ai/reports/orders/7?format=pdf", headers=headers).content.startswith(b"%PDF")
        assert client.get("/ai/ratings", headers=headers,
                          params={"start": NOW.isoformat(), "end": (NOW + timedelta(days=1)).isoformat()}).status_code == 200


def test_synthetic_rating_targets_lower_third(tmp_path):
    output = tmp_path / "data"
    generate(output, tmp_path / "cases", photo_cases=False)
    ratings = run(RatingService(SyntheticDataSource(output / "snapshot.json"), Settings()).calculate(
        datetime(2026, 7, 1, tzinfo=timezone.utc), datetime(2026, 10, 1, tzinfo=timezone.utc)))
    lower_third = {item["employee_alias"] for item in ratings["ratings"][-5:]}
    assert {"E-04", "E-11"} <= lower_third


def test_rule_verdicts_on_generated_verification_cards(tmp_path):
    output = tmp_path / "data"
    cases_path = tmp_path / "cases"
    generate(output, cases_path, photo_cases=False)
    snapshot = run(SyntheticDataSource(output / "snapshot.json").snapshot())
    cases = json.loads((cases_path / "verification.json").read_text(encoding="utf-8"))
    predictions = []
    for case in cases:
        order = OrderRecord.model_validate(case["order"])
        flags = calculate_flags(order, snapshot)
        match, confidence = rule_semantics(order, snapshot)
        predictions.append(decide_verdict(flags, match, confidence))
    correct = sum(prediction == case["expected_verdict"] for prediction, case in zip(predictions, cases))
    assert correct >= 100, f"Rules matched only {correct} of 120 labelled cards"
