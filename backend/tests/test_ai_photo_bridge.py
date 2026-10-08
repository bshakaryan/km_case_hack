"""Pixel transport/result binding for one immutable submission, never a grade."""
import base64
from copy import deepcopy
import hashlib
import io
import json
from pathlib import Path

import httpx
from PIL import Image
import pytest
import sqlalchemy as sa

from app import ai_jobs as jobs
from app.ai_adapter import AttemptServiceAdapter, canonical, envelope
from app.models import AIAssessment, MaterialWriteoff, Order, Photo, SubmissionAttempt
from test_ai_bridge import TOKEN, reply, service_client, unknown
from test_order_history import MASTER, WORKER, act, complete, detail, new_order, start


def jpeg(color):
    output = io.BytesIO()
    Image.new("RGB", (32, 24), color).save(output, "JPEG", quality=85)
    return output.getvalue()


def upload(client, order_id, kind, color):
    response = client.post(f"/api/orders/{order_id}/photos", data={"kind": kind},
        files={"file": ("synthetic.jpg", jpeg(color), "image/jpeg")}, headers=WORKER)
    assert response.status_code == 201, response.text
    return response.json()["id"]


def photo_submission(client):
    order_id = new_order(client)
    start(client, order_id)
    ids = [upload(client, order_id, "before", "red"), upload(client, order_id, "after", "blue"),
        upload(client, order_id, "before", "red"), upload(client, order_id, "after", "red")]
    cached, report = complete(client, order_id)
    with client.app.state.sessions() as db:
        photos = [{"id": row.id, "kind": row.kind, "data": bytes(row.data)} for row in db.scalars(
            sa.select(Photo).where(Photo.id.in_(ids)).order_by(Photo.id))]
    return order_id, cached["submission_attempts"][-1]["id"], cached, report, photos


def checked(photos):
    selected = {kind: max((row["id"] for row in photos if row["kind"] == kind), default=None)
        for kind in ("before", "after")}
    has_pair = selected["before"] is not None
    return {"status": "checked", "method": "openai_vision", "scope": "submission_selected_pair",
        "before_id": selected["before"], "after_id": selected["after"],
        "vision": {"same_equipment": True if has_pair else None, "defect_resolved": None,
            "quality": "unknown", "confidence": 0.5, "issues": [],
            "explanation": "По снимкам нельзя уверенно подтвердить результат.",
            "visual_criteria": {name: {"status": "not_assessable", "observation": ""}
                for name in ("cleanliness", "fasteners", "guards", "leakage")}},
        "capture_time_status": "unknown", "history_status": "not_checked"}


def photo_reply(request, photos, changes=None):
    photo_check = {**checked(photos), **(changes or {})}
    result = {**unknown(), "photo_check": photo_check}
    if photo_check["status"] == "checked":
        result.update(is_stub=False, llm_used=True)
    return reply(request, result)


def test_v2_transfers_exact_linked_jpeg_bytes_and_late_data_never_enters_review(service_client):
    client = service_client
    id_, attempt_id, cached, report, photos = photo_submission(client)
    with client.app.state.sessions() as db:
        frozen = deepcopy(db.get(SubmissionAttempt, attempt_id).ai_input)
        db.get(Order, id_).description = "Changed after completion"
        late = Photo(order_id=id_, kind="after", author_id=6, data=jpeg("green"))
        db.add(late)
        db.commit()
        late_id = late.id
    captured = []
    def handler(request):
        assert request.url.path == "/internal/v2/submission-review"
        sent = json.loads(request.content)
        assert sent["schema_version"] == 2
        unsigned = {key: value for key, value in sent.items() if key != "input_sha256"}
        assert hashlib.sha256(canonical(unsigned)).hexdigest() == sent["input_sha256"]
        assert sent["context"] == frozen and sent["report"]["work_done"] == report["work_done"]
        decoded = {row["id"]: base64.b64decode(row["data_base64"], validate=True) for row in sent["photo_content"]}
        assert list(decoded) == [row["id"] for row in photos]
        assert decoded == {row["id"]: row["data"] for row in photos} and late_id not in decoded
        assert all(data.startswith(b"\xff\xd8") for data in decoded.values())
        # A second connection can commit during HTTP: no write lock crosses IO.
        with client.app.state.sessions() as db:
            db.get(Order, id_).comment = "Synthetic write during photo HTTP"
            db.commit()
        captured.append(sent)
        return photo_reply(request, photos)
    transport = httpx.MockTransport(handler)
    adapter = AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN, transport)
    assert client.app.state.run_ai_jobs(provider=adapter) == [id_]
    current = detail(client, id_)
    assert current["status"] == "ai_review" and current["score"] is None
    assert current["ai_review"]["bridge_version"] == 2 and current["ai_review"]["score"] is None
    assert current["ai_review"]["photo_check"] == checked(photos)
    assert current["submission_attempts"][-1]["ai_review"] == current["ai_review"]
    assert current["ai_review"]["photo_check"]["after_id"] != late_id
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 1
        assert db.scalar(sa.select(sa.func.count()).select_from(MaterialWriteoff)) == 1
    replay = client.post(f"/api/orders/{id_}/complete", json=report,
        headers={**WORKER, "X-Client-Command-Id": "history-complete-001"})
    assert replay.json() == cached
    assert client.app.state.run_ai_jobs(provider=adapter) == [] and len(captured) == 1
    closed = act(client, id_, "close", headers=MASTER, score=5)
    assert closed["score"] == 5 and closed["ai_review"]["score"] is None


@pytest.mark.parametrize("changes", [
    {"after_id": 999}, {"before_id": 1}, {"after_id": 2}, {"before_id": True},
    {"vision": {"same_equipment": "true"}}, {"vision": {"same_equipment": True, "unexpected": 1}},
    {"vision": {"same_equipment": True, "defect_resolved": False, "quality": "unknown",
        "confidence": float("nan"), "issues": [], "explanation": "invalid"}},
    {"vision": {"same_equipment": True, "defect_resolved": False, "quality": "not_a_quality",
        "confidence": 0.5, "issues": [], "explanation": "invalid"}},
    {"capture_time_status": "recent"}, {"history_status": "checked"}, {"unexpected": "not_allowed"},
    {"status": "unavailable"}, {"status": "no_after"},
])
def test_invalid_or_unbound_photo_claim_never_applies(service_client, changes):
    id_, _, _, _, photos = photo_submission(service_client)
    adapter = AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN,
        httpx.MockTransport(lambda request: photo_reply(request, photos, changes)))
    service_client.app.state.run_ai_jobs(provider=adapter)
    current = detail(service_client, id_)
    assert current["status"] == "completed" and current["ai_review"] is None
    assert current["ai_review_job"]["last_error_code"] == "invalid_result"
    with service_client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 0


def test_v2_rework_selects_latest_pair_and_preserves_prior_attempt_evidence(service_client):
    client = service_client
    id_, first_id, _, _, first_photos = photo_submission(client)
    first_adapter = AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN,
        httpx.MockTransport(lambda request: photo_reply(request, first_photos)))
    client.app.state.run_ai_jobs(provider=first_adapter)
    first_review = deepcopy(detail(client, id_)["ai_review"])
    with client.app.state.sessions() as db:
        first_context = deepcopy(db.get(SubmissionAttempt, first_id).ai_input)
    act(client, id_, "rework", headers=MASTER, reason="Synthetic manual rework")
    start(client, id_)
    new_before = upload(client, id_, "before", "green")
    new_after = upload(client, id_, "after", "yellow")
    second, _ = complete(client, id_, quantity=1, key="photo-second-complete-001")
    with client.app.state.sessions() as db:
        photos = [{"id": row.id, "kind": row.kind, "data": bytes(row.data)} for row in db.scalars(
            sa.select(Photo).where(Photo.order_id == id_).order_by(Photo.id))]
    captured = []
    def handler(request):
        sent = json.loads(request.content)
        captured.append(sent)
        assert [row["id"] for row in sent["photo_content"]] == [row["id"] for row in photos]
        assert sent["report"]["materials"][0]["quantity"] == 1
        return photo_reply(request, photos)
    client.app.state.run_ai_jobs(provider=AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN, httpx.MockTransport(handler)))
    current = detail(client, id_)
    assert current["ai_review"]["photo_check"]["before_id"] == new_before
    assert current["ai_review"]["photo_check"]["after_id"] == new_after
    assert current["ai_review"]["photo_check"]["history_status"] == "not_checked"
    assert current["submission_attempts"][0]["ai_review"] == first_review
    assert current["completion"]["materials"][0]["quantity"] == 3
    with client.app.state.sessions() as db:
        assert db.get(SubmissionAttempt, first_id).ai_input == first_context
        assert db.get(SubmissionAttempt, second["submission_attempts"][-1]["id"]).ai_input["photos"] != first_context["photos"]
    assert len(captured) == 1


def test_explicit_v1_rollback_preserves_text_contract_without_photo_transfer(service_client):
    id_, _, _, _, photos = photo_submission(service_client)
    calls = []
    def handler(request):
        assert request.url.path == "/internal/v1/submission-review"
        sent = json.loads(request.content)
        assert sent["schema_version"] == 1 and "photo_content" not in sent
        assert sent["photos"] == [{"id": row["id"], "kind": row["kind"],
            "sha256": hashlib.sha256(row["data"]).hexdigest()} for row in photos]
        calls.append(request)
        return reply(request)
    adapter = AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN, httpx.MockTransport(handler), version=1)
    service_client.app.state.run_ai_jobs(provider=adapter)
    review = detail(service_client, id_)["ai_review"]
    assert review["bridge_version"] == 1 and "photo_check" not in review
    assert len(calls) == 1 and service_client.app.state.run_ai_jobs() == []
    assert detail(service_client, id_)["ai_review"] == review


def test_v2_cannot_claim_an_external_text_model_or_photo_grade(service_client):
    id_, _, _, _, photos = photo_submission(service_client)
    def handler(request):
        result = {**unknown(), "verdict": "passed", "score": 4.5, "source_verdict": "accepted",
                  "is_stub": False, "llm_used": True, "photo_check": checked(photos)}
        return reply(request, result)
    service_client.app.state.run_ai_jobs(provider=AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN,
        httpx.MockTransport(handler)))
    current = detail(service_client, id_)
    assert current["ai_review"] is None and current["score"] is None
    assert current["ai_review_job"]["last_error_code"] == "invalid_result"


def test_after_only_photo_has_no_comparison_claim_or_grade(service_client):
    id_ = new_order(service_client)
    start(service_client, id_)
    after_id = upload(service_client, id_, "after", "green")
    complete(service_client, id_)
    with service_client.app.state.sessions() as db:
        after = db.get(Photo, after_id)
        photos = [{"id": after.id, "kind": after.kind, "data": bytes(after.data)}]
    def handler(request):
        return photo_reply(request, photos)
    service_client.app.state.run_ai_jobs(provider=AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN,
        httpx.MockTransport(handler)))
    result = detail(service_client, id_)["ai_review"]
    assert result["score"] is None and result["source_verdict"] == "needs_master_review"
    assert result["photo_check"]["before_id"] is None and result["photo_check"]["after_id"] == after_id
    assert result["photo_check"]["vision"]["same_equipment"] is None
    assert result["photo_check"]["vision"]["defect_resolved"] is None


def test_v2_does_not_fallback_to_a_v1_response(service_client):
    id_, _, _, _, _ = photo_submission(service_client)
    calls = []
    def handler(request):
        calls.append(request)
        return reply(request, schema_version=1)
    service_client.app.state.run_ai_jobs(provider=AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN,
        httpx.MockTransport(handler)))
    current = detail(service_client, id_)
    assert len(calls) == 1 and current["ai_review"] is None
    assert current["ai_review_job"]["last_error_code"] == "invalid_result"


def tiny_snapshot(data=b"synthetic-pixel-input"):
    metadata = [{"id": 2, "kind": "after", "sha256": hashlib.sha256(data).hexdigest()}]
    return {"attempt_id": 1, "order_id": 1, "ai_input": {"photos": metadata}, "report": {},
        "photos": [{"id": 2, "kind": "after", "data": data}]}


def test_changed_frozen_bytes_or_hash_are_refused_before_http():
    snapshot = tiny_snapshot()
    snapshot["photos"][0]["data"] = b"different-pixel-input"
    requests = []
    adapter = AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN,
        httpx.MockTransport(lambda request: requests.append(request)))
    with pytest.raises(ValueError, match="changed_attempt_photo"):
        adapter.review(snapshot)
    assert requests == []


def test_recommendation_flag_cannot_use_integer_boolean_equality():
    result = {**unknown(), "is_recommendation": 1, "input_sha256": "a" * 64, "bridge_version": 1}
    with pytest.raises(ValueError, match="invalid_result"):
        jobs.validate_result(result, "ai_service")


def test_v2_decoded_photo_and_json_bounds_are_checked_before_http(monkeypatch):
    import app.ai_adapter as module
    assert module.MAX_PHOTO_BYTES == 4 * 1024 * 1024
    assert module.MAX_V2_REQUEST_BYTES == 56 * 1024 * 1024
    with pytest.raises(ValueError, match="attempt_input_too_large"):
        envelope(tiny_snapshot(b"x" * (module.MAX_PHOTO_BYTES + 1)), 2)
    monkeypatch.setattr(module, "MAX_V2_REQUEST_BYTES", 20)
    with pytest.raises(ValueError, match="attempt_input_too_large"):
        envelope(tiny_snapshot(), 2)


def test_actual_v2_asgi_bridge_sends_selected_pixels_to_vision_double(service_client, monkeypatch):
    # Actual HTTP encoding/handlers and SQL, with a provider double (no external request).
    monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[2]))
    from ai_service.app.attempt_bridge import create_attempt_app
    from ai_service.app.config import Settings
    id_, _, _, _, photos = photo_submission(service_client)
    calls = []
    class RecordingVision:
        async def review(self, before, after):
            calls.append((before, after))
            return checked(photos)["vision"]
    service = create_attempt_app(Settings(ai_service_token=TOKEN, openai_api_key="synthetic-key"),
                                 vision_client=RecordingVision())
    adapter = AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN, httpx.ASGITransport(app=service))
    service_client.app.state.run_ai_jobs(provider=adapter)
    current = detail(service_client, id_)
    assert current["status"] == "ai_review" and current["ai_review_job"]["status"] == "succeeded"
    assert current["ai_review"]["photo_check"] == checked(photos) and current["ai_review"]["score"] is None
    selected = {kind: max((row for row in photos if row["kind"] == kind), key=lambda row: row["id"])
                for kind in ("before", "after")}
    assert calls == [(selected["before"]["data"], selected["after"]["data"])]


def test_v2_openai_recommendation_is_persisted_and_master_still_closes_manually(service_client, monkeypatch):
    monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[2]))
    from ai_service.app.attempt_bridge import create_attempt_app
    from ai_service.app.config import Settings
    id_, _, _, _, photos = photo_submission(service_client)

    class Vision:
        async def review(self, before, after):
            assert before and after
            return checked(photos)["vision"]

    service = create_attempt_app(Settings(ai_service_token=TOKEN, openai_api_key="synthetic-key"),
                                 vision_client=Vision())
    adapter = AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN, httpx.ASGITransport(app=service))
    service_client.app.state.run_ai_jobs(provider=adapter)
    current = detail(service_client, id_)
    check = current["ai_review"]["photo_check"]
    assert check == checked(photos)
    assert current["ai_review"]["score"] is None
    assert current["ai_review"]["source_verdict"] == "needs_master_review"
    assert current["ai_review"]["llm_used"] is True and current["ai_review"]["is_stub"] is False
    with service_client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 1
        assert db.scalar(sa.select(AIAssessment.score)) is None
        assert db.scalar(sa.select(sa.func.count()).select_from(MaterialWriteoff)) == 1
    closed = act(service_client, id_, "close", headers=MASTER, score=5)
    assert closed["score"] == 5 and closed["ai_review"]["score"] is None
    assert closed["submission_attempts"][-1]["ai_review"]["photo_check"] == check


@pytest.mark.parametrize("version", [True, 0, 3, "2"])
def test_no_implicit_protocol_version_coercion(version):
    with pytest.raises(ValueError, match="invalid_bridge_version"):
        AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN, version=version)
