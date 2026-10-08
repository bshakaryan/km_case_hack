import asyncio
import json
from datetime import datetime, timezone

import pytest
import httpx
from fastapi.testclient import TestClient

from app.assistant import MasterAssistant, ToolChoice, choose_by_rules
from app.config import Settings
from app.intake import IntakeSelection, OpenAITranscriber, OrderIntake
from app.llm_client import LLMClient
from app.main import create_app
from app.storage import AIStore
from app.synthetic_source import SyntheticDataSource
from data_gen.generate import generate
from eval.run import evaluate_assistant, evaluate_intake


@pytest.fixture(scope="module")
def dataset(tmp_path_factory):
    root = tmp_path_factory.mktemp("phase6")
    data_dir, cases_dir = root / "data", root / "cases"
    generate(data_dir, cases_dir, photo_cases=False)
    return SyntheticDataSource(data_dir / "snapshot.json"), cases_dir


def run(coroutine):
    return asyncio.run(coroutine)


def test_fixed_intake_and_assistant_cases(dataset):
    source, cases_dir = dataset
    snapshot = run(source.snapshot())
    intake_cases = json.loads((cases_dir / "intake.json").read_text(encoding="utf-8"))
    assistant_cases = json.loads((cases_dir / "assistant.json").read_text(encoding="utf-8"))
    intake = run(evaluate_intake(snapshot, intake_cases))
    assistant = run(evaluate_assistant(snapshot, assistant_cases))
    assert intake["cases"] == 40
    assert all(accuracy == 1 for accuracy in intake["field_accuracy"].values())
    assert intake["valid_id_rate"] == 1
    assert assistant["cases"] == 25
    assert assistant["tool_accuracy"] == assistant["numeric_answer_accuracy"] == 1


def test_electrician_alias_selects_electrical_specialty(dataset):
    source, _ = dataset
    choice = choose_by_rules("Кто сейчас свободен из электриков?", run(source.snapshot()))
    assert choice.tool == "available_workers"
    assert choice.specialty == "электромонтёр"


def test_unknown_intake_is_draft_only_and_invalid_ids_are_rejected(dataset):
    source, _ = dataset
    store = AIStore("sqlite:///:memory:")
    store.initialize()

    class InvalidChoiceLLM(LLMClient):
        def safe_text_enabled(self):
            return True

        async def structured_response(self, purpose, prompt, schema, response_model, smart=False):
            return IntakeSelection(equipment_id=99999, area_id=99999, fault_code_id=99999)

    service = OrderIntake(source, InvalidChoiceLLM(Settings(), store))
    result = run(service.from_text("На неизвестном агрегате поломка, за 2 ч", datetime.now(timezone.utc)))
    assert result["status"] == "needs_master_review"
    assert result["draft"]["equipment_id"] is None
    assert result["draft"]["fault_code_id"] is None
    assert result["creates_order"] is False
    store.close()


def test_voice_fallback_and_transcriber_adapter(dataset):
    source, cases_dir = dataset
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    llm = LLMClient(Settings(), store)
    now = datetime.fromisoformat("2026-07-01T03:00:00Z")
    service = OrderIntake(source, llm)
    assert run(service.from_voice(b"audio", "recording.wav", now))["status"] == "needs_transcript"

    class StubTranscriber:
        async def transcribe(self, audio, filename):
            return json.loads((cases_dir / "intake.json").read_text(encoding="utf-8"))[0]["phrase"]

    service = OrderIntake(source, llm, StubTranscriber())
    result = run(service.from_voice(b"audio", "recording.wav", now))
    assert result["status"] == "draft"
    assert result["draft"]["equipment_id"] == 1
    with pytest.raises(ValueError):
        run(service.from_voice(b"x" * 10_000_001, "recording.wav", now))
    store.close()


def test_assistant_only_reads_and_returns_computed_numbers(dataset):
    source, _ = dataset
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    service = MasterAssistant(source, LLMClient(Settings(), store))
    result = run(service.ask("Кто свободен из слесарей?", datetime.fromisoformat("2026-09-29T03:00:00Z")))
    assert result["tool"] == "available_workers"
    assert result["tool_calls"] == 1
    assert result["facts"]["free_workers"] == 5
    assert all(alias.startswith("E-") for alias in result["facts"]["worker_ids"])
    problems = run(service.ask("Покажи проблемы участка дробления за месяц",
                               datetime.fromisoformat("2026-09-29T03:00:00Z")))
    assert problems["tool"] == "area_problems"
    assert problems["facts"]["area_id"] == 1
    assert problems["facts"]["top_fault_codes"]
    assert run(service.ask("Подпиши закрытие", datetime.now(timezone.utc)))["status"] == "needs_clarification"
    store.close()


def test_llm_cannot_invent_area_for_assistant(dataset):
    source, _ = dataset
    store = AIStore("sqlite:///:memory:")
    store.initialize()

    class InventedAreaLLM(LLMClient):
        def safe_text_enabled(self):
            return True

        async def structured_response(self, purpose, prompt, schema, response_model, smart=False):
            return ToolChoice(tool="area_report", area_id=1, specialty=None)

    service = MasterAssistant(source, InventedAreaLLM(Settings(), store))
    result = run(service.ask("Дай сводку по неизвестному месту", datetime.now(timezone.utc)))
    assert result["status"] == "needs_clarification"
    assert result["tool_calls"] == 0
    store.close()


def test_new_routes_require_service_token_and_do_not_create_order(dataset):
    source, cases_dir = dataset
    case = json.loads((cases_dir / "intake.json").read_text(encoding="utf-8"))[0]
    settings = Settings(ai_service_token="phase6-token")
    store = AIStore("sqlite:///:memory:")
    with TestClient(create_app(settings, source, store)) as client:
        assert client.post("/ai/intake/text", json={"phrase": case["phrase"]}).status_code == 401
        headers = {"Authorization": "Bearer phase6-token"}
        result = client.post("/ai/intake/text", headers=headers,
                             json={"phrase": case["phrase"], "now": case["reference_time"]})
        assert result.status_code == 200
        assert result.json()["creates_order"] is False
        assert result.json()["draft"]["equipment_id"] == 1
        assistant = client.post("/ai/assistant/ask", headers=headers,
                                json={"question": "Какие работы просрочены?", "now": "2026-09-29T03:00:00Z"})
        assert assistant.status_code == 200
        assert assistant.json()["tool_calls"] == 1


def test_redaction_for_optional_llm_prompts(dataset):
    source, _ = dataset
    snapshot = run(source.snapshot())
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    llm = LLMClient(Settings(), store)
    sample = f"{snapshot.employees[0].name} {snapshot.employees[0].login} +7 701 123 45 67"
    redacted = llm.redact(sample, snapshot.employees)
    assert snapshot.employees[0].name not in redacted
    assert snapshot.employees[0].login not in redacted
    assert "701" not in redacted
    store.close()


def test_structured_llm_intake_redacts_people_and_validates_ids(dataset):
    source, _ = dataset
    snapshot = run(source.snapshot())
    captured = []

    def handler(request):
        captured.append(json.loads(request.content))
        return httpx.Response(200, json={"output": [{"content": [{"type": "output_text", "text": json.dumps(
            {"equipment_id": 1, "area_id": 1, "fault_code_id": 1})}]}]})

    store = AIStore("sqlite:///:memory:")
    store.initialize()
    settings = Settings(data_source="synthetic", demo_mode=False, llm_provider="openai",
                        llm_model_fast="mock-fast", openai_api_key="mock-key")
    llm = LLMClient(settings, store, httpx.MockTransport(handler))
    phrase = f"{snapshot.employees[0].name} {snapshot.employees[0].login}: агрегат неисправен, за 2 ч"
    result = run(OrderIntake(source, llm).from_text(phrase, datetime.now(timezone.utc)))
    assert result["draft"]["equipment_id"] == 1
    assert result["draft"]["fault_code_id"] == 1
    assert result["needs_master_review"]
    outgoing = json.dumps(captured, ensure_ascii=False)
    assert snapshot.employees[0].name not in outgoing
    assert snapshot.employees[0].login not in outgoing
    assert llm.request_count == 1
    store.close()


def test_structured_llm_invalid_twice_falls_back(dataset):
    source, _ = dataset
    attempts = []

    def handler(request):
        attempts.append(request)
        return httpx.Response(200, json={"output": [{"content": [{"type": "output_text", "text": "{}"}]}]})

    store = AIStore("sqlite:///:memory:")
    store.initialize()
    settings = Settings(data_source="synthetic", demo_mode=False, llm_provider="openai",
                        llm_model_fast="mock-fast", openai_api_key="mock-key")
    llm = LLMClient(settings, store, httpx.MockTransport(handler))
    result = run(OrderIntake(source, llm).from_text("Неизвестный агрегат, срок за 2 ч", datetime.now(timezone.utc)))
    assert result["status"] == "needs_master_review"
    assert result["draft"]["equipment_id"] is None
    assert len(attempts) == 2
    store.close()


def test_stt_api_adapter_uses_configured_model_and_mock_transport():
    captured = []

    def handler(request):
        captured.append(request)
        return httpx.Response(200, json={"text": "Проверить конвейер"})

    transcriber = OpenAITranscriber("mock-key", "mock-stt", httpx.MockTransport(handler))
    assert run(transcriber.transcribe(b"audio", "recording.mp3")) == "Проверить конвейер"
    assert len(captured) == 1
    assert captured[0].url.path == "/v1/audio/transcriptions"
    assert b"mock-stt" in captured[0].content
    assert b"audio/mpeg" in captured[0].content
