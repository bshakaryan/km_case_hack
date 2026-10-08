"""Attempt-bound service transport and durable primary-server results."""
import asyncio
from copy import deepcopy
import hashlib
import json
from pathlib import Path

import httpx
import pytest
import sqlalchemy as sa

from app import ai_jobs as jobs
from app.ai_adapter import AttemptServiceAdapter, canonical
from app.main import create_app
from app.models import AIAssessment, AIReviewJob, MaterialWriteoff, Order, Photo, SubmissionAttempt
from test_ai_jobs import job_client, submitted
from test_order_history import MASTER, WORKER, act, detail, history_client

TOKEN = "synthetic-bridge-token-long-enough"


@pytest.fixture
def service_client(tmp_path, monkeypatch):
    monkeypatch.setenv("AI_REVIEW_MODE", "queued_service")
    monkeypatch.setenv("AI_SERVICE_URL", "http://127.0.0.1:8010")
    monkeypatch.setenv("AI_SERVICE_TOKEN", TOKEN)
    yield from history_client.__wrapped__(tmp_path, monkeypatch)


def unknown():
    return {"verdict": "needs_attention", "score": None, "explanation": "Synthetic unknown recommendation; master must review.",
            "is_stub": True, "master_score": None, "source_verdict": "needs_master_review", "llm_used": False, "is_recommendation": True}


def reply(request, result=None, **changes):
    sent = json.loads(request.content)
    result = deepcopy(result or unknown())
    if sent["schema_version"] == 2:
        result.setdefault("photo_check", {"status": "no_after", "method": "local_cv", "scope": "submission_selected_pair",
            "before_id": None, "after_id": None, "duplicate_before": None, "exact_duplicate_groups": [],
            "equipment_status": "unknown", "model_available": False, "capture_time_status": "unknown",
            "repair_status": "unknown", "history_status": "not_checked"})
    response = {"schema_version": sent["schema_version"], "attempt_id": sent["attempt_id"], "input_sha256": sent["input_sha256"], "result": result, **changes}
    return httpx.Response(200, json=response)


def adapter(handler, version=2):
    return AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN, httpx.MockTransport(handler), version=version)


def test_context_is_frozen_and_old_stub_jobs_keep_binding(job_client):
    client = job_client
    id_, attempt_id, original, report = submitted(client)
    with client.app.state.sessions() as db:
        attempt = db.get(SubmissionAttempt, attempt_id)
        frozen = deepcopy(attempt.ai_input)
        order = db.get(Order, id_)
        order.description = "Changed AFTER submitting"
        order.normal_hours = 100
        db.add(Photo(order_id=id_, kind="after", author_id=6, data=b"late-photo"))
        db.commit()
    claim = jobs.claim_job(client.app.state.sessions)
    assert claim["provider"] == "stub" and claim["snapshot"]["ai_input"] == frozen
    assert claim["snapshot"]["photos"] == []
    assert claim["snapshot"]["report"]["materials"][0]["quantity"] == 2
    assert jobs.finish_job(client.app.state.sessions, claim, jobs.FormalStub().review(claim["snapshot"]))
    assert detail(client, id_)["ai_review"]["score"] == 4
    assert original["ai_review"] is None and report["materials"][0]["quantity"] == 2


def test_service_unknown_is_durable_without_manual_score_or_second_writeoff(service_client):
    client = service_client
    id_, attempt_id, cached, report = submitted(client)
    captured = []
    def handler(request):
        assert request.headers["authorization"] == "Bearer " + TOKEN
        sent = json.loads(request.content)
        digest = sent.pop("input_sha256")
        assert hashlib.sha256(canonical(sent)).hexdigest() == digest
        assert sent["attempt_id"] == attempt_id and sent["order_id"] == id_
        assert sent["photos"] == sent["context"]["photos"] == []
        captured.append(sent)
        return reply(request)
    assert client.app.state.run_ai_jobs(provider=adapter(handler)) == [id_]
    current = detail(client, id_)
    assert current["status"] == "ai_review" and current["score"] is None
    assert current["ai_review"]["score"] is None and current["ai_review"]["master_score"] is None
    assert current["ai_review_job"]["provider"] == "ai_service" and current["ai_review_job"]["status"] == "succeeded"
    assert current["submission_attempts"][-1]["ai_review"] == current["ai_review"]
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(AIAssessment.score)) is None
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 1
        assert db.scalar(sa.select(sa.func.count()).select_from(MaterialWriteoff)) == 1
        assert db.get(SubmissionAttempt, attempt_id).ai_input == captured[0]["context"]
    replay = client.post(f"/api/orders/{id_}/complete", json=report, headers={**WORKER, "X-Client-Command-Id": "history-complete-001"})
    assert replay.json() == cached
    assert client.app.state.run_ai_jobs(provider=adapter(handler)) == [] and len(captured) == 1
    closed = act(client, id_, "close", headers=MASTER, score=5)
    assert closed["score"] == 5 and closed["ai_review"]["score"] is None


@pytest.mark.parametrize("change", [{"attempt_id": 999}, {"attempt_id": True}, {"schema_version": True}, {"input_sha256": "0" * 64}, {"extra": "not-allowed"}])
def test_wrong_identity_and_extra_response_never_applies(service_client, change):
    id_, _, _, _ = submitted(service_client)
    service_client.app.state.run_ai_jobs(provider=adapter(lambda request: reply(request, **change)))
    current = detail(service_client, id_)
    assert current["status"] == "completed" and current["ai_review"] is None
    assert current["ai_review_job"]["last_error_code"] == "invalid_result"


@pytest.mark.parametrize("patch", [{"score": 0.0}, {"score": float("inf")}, {"score": 3.0},
                                   {"is_stub": False}, {"verdict": "passed"}, {"is_recommendation": False}])
def test_invalid_unknown_or_provenance_does_not_fabricate_score(service_client, patch):
    id_, _, _, _ = submitted(service_client)
    service_client.app.state.run_ai_jobs(provider=adapter(lambda request: reply(request, {**unknown(), **patch})))
    assert detail(service_client, id_)["ai_review_job"]["last_error_code"] == "invalid_result"
    with service_client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 0


def test_declared_semantic_provenance_preserved_without_master_score(service_client):
    id_, _, _, _ = submitted(service_client)
    # Trusted service response double, not an actual paid model call.
    result = {**unknown(), "is_stub": False, "llm_used": True}
    service_client.app.state.run_ai_jobs(provider=adapter(lambda request: reply(request, result), version=1))
    current = detail(service_client, id_)
    assert current["ai_review"]["is_stub"] is False and current["ai_review"]["llm_used"] is True
    assert current["score"] is None and current["ai_review"]["score"] is None


def test_expired_service_lease_never_applies(service_client):
    from datetime import timedelta
    from app.models import utcnow
    id_, _, _, _ = submitted(service_client)
    def handler(request):
        with service_client.app.state.sessions() as db:
            job = db.scalar(sa.select(AIReviewJob))
            job.lease_expires_at = utcnow() - timedelta(seconds=1)
            db.commit()
        return reply(request)
    service_client.app.state.run_ai_jobs(provider=adapter(handler), limit=1)
    assert detail(service_client, id_)["ai_review"] is None


@pytest.mark.parametrize("status", [302, 401, 503])
def test_no_redirect_or_second_request_and_error_preserves_report(service_client, status):
    id_, attempt, _, report = submitted(service_client)
    requests = []
    def handler(request):
        requests.append(request)
        return httpx.Response(status, headers={"Location": "http://another-server.invalid/secret"})
    service_client.app.state.run_ai_jobs(provider=adapter(handler))
    assert len(requests) == 1
    current = detail(service_client, id_)
    assert current["status"] == "completed" and current["ai_review_job"]["last_error_code"] == "provider_error"
    assert current["submission_attempts"][-1]["id"] == attempt
    assert current["submission_attempts"][-1]["completion"]["work_done"] == report["work_done"]


def test_old_attempt_context_not_guessed_or_sent(service_client):
    id_, attempt_id, _, _ = submitted(service_client)
    with service_client.app.state.sessions() as db:
        db.get(SubmissionAttempt, attempt_id).ai_input = None
        db.commit()
    requests = []
    service_client.app.state.run_ai_jobs(provider=adapter(lambda request: requests.append(request)))
    assert requests == [] and detail(service_client, id_)["ai_review"] is None


def test_new_submission_after_service_configuration_uses_pinned_provider(service_client):
    id_, _, _, _ = submitted(service_client)
    # A worker without configured service must fail visibly, never silently
    # replace the persisted provider with FormalStub after a restart.
    jobs.dispatch_ai_jobs(service_client.app.state.sessions, providers={"stub": jobs.FormalStub()})
    state = detail(service_client, id_)["ai_review_job"]
    assert state["provider"] == "ai_service" and state["last_error_code"] == "provider_error"


def test_transport_total_deadline(service_client, monkeypatch):
    import app.ai_adapter as module
    monkeypatch.setattr(module, "DEADLINE_SECONDS", 0.02)
    id_, _, _, _ = submitted(service_client)
    async def handler(request):
        await asyncio.sleep(1)
        return reply(request)
    service_client.app.state.run_ai_jobs(provider=adapter(handler))
    assert detail(service_client, id_)["ai_review_job"]["last_error_code"] == "provider_error"


def test_service_response_after_cancellation_does_not_restore_order(service_client):
    id_, _, _, _ = submitted(service_client)
    def handler(request):
        act(service_client, id_, "cancel", headers=MASTER, reason="Synthetic cancellation during read-only service call")
        return reply(request)
    service_client.app.state.run_ai_jobs(provider=adapter(handler))
    current = detail(service_client, id_)
    assert current["status"] == "cancelled" and current["ai_review"] is None
    assert current["ai_review_job"]["status"] == "superseded"


def test_real_service_asgi_contract_and_primary_sqlite(service_client, monkeypatch):
    # Real app handlers/HTTP encoding, isolated SQLite; no socket/provider/CV.
    monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[2]))
    from ai_service.app.attempt_bridge import create_attempt_app
    from ai_service.app.config import Settings
    service = create_attempt_app(Settings(ai_service_token=TOKEN))
    real_adapter = AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN, httpx.ASGITransport(app=service), version=1)
    id_, _, _, _ = submitted(service_client)
    service_client.app.state.run_ai_jobs(provider=real_adapter)
    current = detail(service_client, id_)
    assert current["status"] == "ai_review" and current["ai_review_job"]["status"] == "succeeded"
    assert current["ai_review"]["is_stub"] is True and current["ai_review"]["llm_used"] is False
    assert current["ai_review"]["score"] is None


@pytest.mark.parametrize("url,token", [("https://name:password@example.test", TOKEN), ("http://localhost/?x=1", TOKEN), ("file:///etc/passwd", TOKEN), ("http://localhost", "short"), ("http://localhost:notaport", TOKEN), ("http://localhost:99999", TOKEN)])
def test_invalid_service_config_fails_before_database_creation(tmp_path, monkeypatch, url, token):
    monkeypatch.setenv("AI_REVIEW_MODE", "queued_service")
    monkeypatch.setenv("AI_SERVICE_URL", url)
    monkeypatch.setenv("AI_SERVICE_TOKEN", token)
    database = tmp_path / "uncreated.db"
    with pytest.raises(ValueError, match="AI_SERVICE"):
        create_app(f"sqlite:///{database}", seed=False, monitor=False)
    assert not database.exists()
