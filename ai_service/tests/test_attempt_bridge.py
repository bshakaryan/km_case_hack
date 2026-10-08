import asyncio
import copy
import json

import pytest
from fastapi.testclient import TestClient

from app import attempt_bridge
from app.attempt_bridge import create_attempt_app, input_digest
from app.config import Settings
from app.llm_client import LLMClient
from app.storage import AIStore


TOKEN = "test-service-token"
HEADERS = {"Authorization": f"Bearer {TOKEN}"}
ROUTE = "/internal/v1/submission-review"


def signed_packet():
    photos = [{"id": 20, "kind": "before", "sha256": "1" * 64},
              {"id": 21, "kind": "after", "sha256": "2" * 64}]
    value = {
        "schema_version": 1, "attempt_id": 11, "order_id": 7,
        "context": {
            "order": {"id": 7, "number": "Н-2026-0007", "title": "Заменить подшипник",
                      "description": "Износ подшипника привода", "work_type": "unplanned",
                      "area_id": 1, "equipment_id": 3, "assignee_id": 5,
                      "brigade_id": 1, "master_id": 1, "priority": "normal",
                      "status": "completed", "deadline": "2026-10-08T14:00:00+00:00",
                      "created_at": "2026-10-08T10:00:00+00:00",
                      "started_at": "2026-10-08T11:00:00+00:00",
                      "completed_at": "2026-10-08T12:00:00+00:00", "normal_hours": 2.0},
            "fault_codes": [{"id": 1, "code": "F01", "name": "Износ подшипника"},
                            {"id": 2, "code": "F02", "name": "Утечка масла"}],
            "submission_order_version": 4, "assignment_id": 8, "sequence": 1,
            "photos": copy.deepcopy(photos),
        },
        "report": {"work_done": "Подшипник заменён, контроль выполнен", "fault_code_id": 1,
                   "comment": "", "materials": [{"material_id": 1, "name": "Подшипник",
                                                   "unit": "шт", "quantity": 1.0}]},
        "photos": photos,
    }
    return resign(value)


def resign(value):
    value["input_sha256"] = input_digest(value)
    return value


def client_for(llm=None, settings=None):
    return TestClient(create_attempt_app(settings or Settings(ai_service_token=TOKEN), llm))


def semantic(match):
    return {"works_match_problem": match, "match_confidence": 0.9, "remarks": [],
            "explanation_worker": "Требуется проверка мастера.",
            "explanation_master": "Текст работ сопоставлен с задачей."}


class Interpreter:
    def __init__(self, result):
        self.result = result
        self.prompts = []

    async def interpret(self, prompt):
        self.prompts.append(copy.deepcopy(prompt))
        return self.result


def test_default_rules_preserve_unknown_and_metadata_only_provenance():
    packet = signed_packet()
    with client_for() as client:
        response = client.post(ROUTE, json=packet, headers=HEADERS)
    assert response.status_code == 200
    value = response.json()
    assert set(value) == {"schema_version", "attempt_id", "input_sha256", "result"}
    assert (value["attempt_id"], value["input_sha256"]) == (11, packet["input_sha256"])
    result = value["result"]
    assert result["source_verdict"] == "needs_master_review"
    assert result["verdict"] == "needs_attention"
    assert result["score"] is None and result["master_score"] is None
    assert result["is_stub"] is True and result["llm_used"] is False
    assert result["is_recommendation"] is True
    assert "Изображения не анализировались" in result["explanation"]
    assert "внешний ИИ отключён" in result["explanation"]
    assert len(result["explanation"]) <= 2000
    assert len(response.content) < 64 * 1024
    assert packet["report"]["work_done"] not in response.text


def test_auth_precedes_body_schema_and_size_validation():
    interpreter = Interpreter(semantic(True))
    with client_for(interpreter) as client:
        for headers in ({}, {"Authorization": "Bearer wrong"},
                        [("Authorization", f"Bearer {TOKEN}"), ("Authorization", "Bearer wrong")]):
            response = client.post(ROUTE, content=b"not JSON", headers=headers)
            assert response.status_code == 401
            assert response.json() == {"detail": "unauthorized_submission_review"}
        assert client.post(ROUTE, content=b"x" * (1024 * 1024 + 1)).status_code == 401
    assert not interpreter.prompts
    with client_for(settings=Settings()) as client:
        assert client.post(ROUTE, content=b"not JSON", headers=HEADERS).status_code == 503


def test_size_bound_includes_chunked_body_and_content_length():
    interpreter = Interpreter(semantic(True))
    with client_for(interpreter) as client:
        declared = {**HEADERS, "Content-Length": str(1024 * 1024 + 1)}
        assert client.post(ROUTE, content=b"{}", headers=declared).status_code == 413
        chunks = (b"x" * (512 * 1024) for _ in range(3))
        response = client.post(ROUTE, content=chunks, headers=HEADERS)
        assert response.status_code == 413
        for length in ("invalid", "-1"):
            assert client.post(ROUTE, content=b"{}", headers={**HEADERS, "Content-Length": length}).status_code == 400
    assert not interpreter.prompts


@pytest.mark.parametrize("change", [
    lambda value: value.update(schema_version=2),
    lambda value: value.update(attempt_id=True),
    lambda value: value.update(order_id="7"),
    lambda value: value.update(extra_field="secret input"),
    lambda value: value["report"].update(extra_field="secret input"),
    lambda value: value["context"]["order"].update(status="ai_review"),
    lambda value: value["context"]["order"].update(completed_at="2026-10-08T12:00:00"),
    lambda value: value["report"]["materials"][0].update(quantity="1"),
    lambda value: value["photos"][0].update(url="http://secret.invalid/photo"),
    lambda value: value["context"].update(assignment_id=0),
])
def test_strict_schema_rejects_unsupported_or_coerced_inputs_without_echo(change):
    value = signed_packet()
    change(value)
    resign(value)
    with client_for() as client:
        response = client.post(ROUTE, json=value, headers=HEADERS)
    assert response.status_code == 422
    assert response.json() == {"detail": "invalid_submission_review_input"}
    assert "secret" not in response.text


@pytest.mark.parametrize("field", ["attempt_id", "order_id", "report"])
def test_hash_binds_attempt_and_report_before_projection(field):
    value = signed_packet()
    if field == "report":
        value[field]["work_done"] = "Изменённый отчёт"
    else:
        value[field] += 1
    with client_for() as client:
        assert client.post(ROUTE, json=value, headers=HEADERS).status_code == 422


@pytest.mark.parametrize("change", [
    lambda value: value["context"]["order"].update(id=8),
    lambda value: value["context"]["photos"][0].update(sha256="3" * 64),
    lambda value: value["report"]["materials"].append(copy.deepcopy(value["report"]["materials"][0])),
    lambda value: value["context"]["fault_codes"].append(copy.deepcopy(value["context"]["fault_codes"][0])),
])
def test_recomputed_hash_does_not_replace_identity_and_reference_checks(change):
    value = signed_packet()
    change(value)
    resign(value)
    with client_for() as client:
        assert client.post(ROUTE, json=value, headers=HEADERS).status_code == 422


def test_duplicate_photo_ids_are_rejected_even_when_both_lists_match():
    packet = signed_packet()
    packet["photos"].append(copy.deepcopy(packet["photos"][0]))
    packet["context"]["photos"] = copy.deepcopy(packet["photos"])
    resign(packet)
    with client_for() as client:
        assert client.post(ROUTE, json=packet, headers=HEADERS).status_code == 422


def test_canonical_hash_ignores_json_formatting_but_rejects_duplicates_and_nonfinite():
    packet = signed_packet()
    shuffled = dict(reversed(list(packet.items())))
    assert input_digest(shuffled) == packet["input_sha256"]
    with client_for() as client:
        assert client.post(ROUTE, content=json.dumps(shuffled, ensure_ascii=True, indent=2), headers=HEADERS).status_code == 200
        for raw in (b'{"attempt_id":11,"attempt_id":12}', b'{"quantity":NaN}', b'[]'):
            response = client.post(ROUTE, content=raw, headers=HEADERS)
            assert response.json() == {"detail": "invalid_submission_review_input"}
        assert client.post(ROUTE, content=json.dumps(packet).encode("utf-16"), headers=HEADERS).status_code == 422


def test_stateless_requests_return_their_own_attempt_hash_and_report_recommendation():
    first = signed_packet()
    second = copy.deepcopy(first)
    second["attempt_id"] = 12
    second["context"]["sequence"] = 2
    second["report"]["work_done"] = "Устранена утечка масла"
    resign(second)
    with client_for() as client:
        one = client.post(ROUTE, json=first, headers=HEADERS).json()
        two = client.post(ROUTE, json=second, headers=HEADERS).json()
    assert one["result"]["source_verdict"] == "needs_master_review"
    assert two["result"]["source_verdict"] == "needs_rework"
    assert two["result"]["score"] == 2
    assert (two["attempt_id"], two["input_sha256"]) == (12, second["input_sha256"])
    assert two["input_sha256"] != one["input_sha256"]
    assert two["result"]["is_stub"] is True
    assert two["result"]["is_recommendation"] is True


def test_unknown_time_and_norms_remain_unknown_even_with_caller_values():
    packet = signed_packet()
    packet["context"]["order"].update(normal_hours=0.001, started_at="2026-01-01T00:00:00+00:00")
    packet["report"]["materials"][0]["quantity"] = 999999.0
    resign(packet)
    interpreter = Interpreter(semantic(True))
    with client_for(interpreter) as client:
        result = client.post(ROUTE, json=packet, headers=HEADERS).json()["result"]
    flags = interpreter.prompts[0]["flags"]
    assert flags["time_status"] == "unknown" and flags["material_norm_status"] == "unknown"
    assert flags["actual_hours"] is None and flags["normal_hours"] is None
    assert not flags["excess_material_ids"] and not flags["unusual_material_ids"]
    assert result["score"] is None and result["source_verdict"] == "needs_master_review"
    assert result["llm_used"] is True and result["is_stub"] is False


@pytest.mark.parametrize("missing", ["work", "after", "fault"])
def test_formal_missing_evidence_yields_only_recommendation(missing):
    packet = signed_packet()
    if missing == "work":
        packet["report"]["work_done"] = ""
    elif missing == "after":
        packet["photos"] = packet["photos"][:1]
        packet["context"]["photos"] = copy.deepcopy(packet["photos"])
    else:
        packet["report"]["fault_code_id"] = 999
    resign(packet)
    with client_for() as client:
        result = client.post(ROUTE, json=packet, headers=HEADERS).json()["result"]
    assert result["verdict"] == "needs_rework" and result["score"] in (1, 2)
    assert result["is_stub"] is True and result["is_recommendation"] is True


def test_injected_semantic_negative_result_is_used_without_changing_domain_state():
    interpreter = Interpreter(semantic(False))
    with client_for(interpreter) as client:
        result = client.post(ROUTE, json=signed_packet(), headers=HEADERS).json()["result"]
    assert result["verdict"] == "needs_rework" and result["score"] == 2
    assert result["llm_used"] is True and result["is_stub"] is False
    assert result["is_recommendation"] is True and result["master_score"] is None
    assert len(interpreter.prompts) == 1
    assert "Текст работ сопоставлен" in result["explanation"]


@pytest.mark.parametrize("change", [
    lambda value: value.update(works_match_problem="false"),
    lambda value: value.update(score=5),
    lambda value: value.update(explanation_master="Оценка 5"),
    lambda value: value.update(remarks=[{"text": "Есть замечание", "evidence_ref": "attempt:999"}]),
])
def test_invalid_semantic_output_never_claims_model_provenance(change):
    value = semantic(False)
    change(value)
    with client_for(Interpreter(value)) as client:
        result = client.post(ROUTE, json=signed_packet(), headers=HEADERS).json()["result"]
    assert result["source_verdict"] == "needs_master_review" and result["score"] is None
    assert result["is_stub"] is True and result["llm_used"] is False
    assert "не прошёл проверку" in result["explanation"]


def test_injected_timeout_is_single_bounded_call_and_cancels_the_interpreter(monkeypatch):
    monkeypatch.setattr(attempt_bridge, "LLM_TIMEOUT_SECONDS", 0.01)

    class Slow:
        calls = 0
        cancelled = False

        async def interpret(self, _):
            self.calls += 1
            try:
                await asyncio.sleep(1)
            finally:
                self.cancelled = True

    slow = Slow()
    with client_for(slow) as client:
        result = client.post(ROUTE, json=signed_packet(), headers=HEADERS).json()["result"]
    assert slow.calls == 1 and slow.cancelled
    assert result["score"] is None and result["is_stub"] is True
    assert "недоступна" in result["explanation"]


def test_provider_error_never_echoes_secrets_or_input(caplog):
    class Failing:
        async def interpret(self, _):
            raise RuntimeError("private-provider-secret private-work-input")

    with client_for(Failing()) as client:
        response = client.post(ROUTE, json=signed_packet(), headers=HEADERS)
    assert response.status_code == 200
    assert response.json()["result"]["score"] is None
    assert "private-provider-secret" not in response.text + caplog.text
    assert "private-work-input" not in response.text + caplog.text
    assert TOKEN not in response.text + caplog.text


def test_environment_cannot_construct_llm_store_or_activate_paid_calls(monkeypatch):
    def forbidden(*args, **kwargs):
        pytest.fail("The stateless default bridge constructed a runtime dependency")

    monkeypatch.setattr(LLMClient, "__init__", forbidden)
    monkeypatch.setattr(AIStore, "__init__", forbidden)
    monkeypatch.setenv("AI_SERVICE_TOKEN", TOKEN)
    monkeypatch.setenv("DATA_SOURCE", "backend")
    monkeypatch.setenv("DEMO_MODE", "false")
    monkeypatch.setenv("LLM_PROVIDER", "openai")
    monkeypatch.setenv("LLM_MODEL_FAST", "test-model")
    monkeypatch.setenv("OPENAI_API_KEY", "private-test-key")
    with TestClient(create_attempt_app()) as client:
        response = client.post(ROUTE, json=signed_packet(), headers=HEADERS)
        assert response.status_code == 200
        assert response.json()["result"]["llm_used"] is False
        assert client.get("/docs").status_code == 404
        assert client.get("/ai/source/summary").status_code == 404
    settings = Settings(ai_service_token=TOKEN, data_source="backend", demo_mode=False,
                        llm_provider="openai", llm_model_fast="test-model", openai_api_key="private-test-key")
    with client_for(settings=settings) as client:
        assert client.post(ROUTE, json=signed_packet(), headers=HEADERS).status_code == 200
