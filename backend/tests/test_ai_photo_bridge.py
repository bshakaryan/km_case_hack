"""Pixel transport/result binding for one immutable submission, never a grade."""
import base64
from collections import defaultdict
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
    # The test double claims only exact comparisons, not actual CV recognition.
    selected = {kind: max((row["id"] for row in photos if row["kind"] == kind), default=None)
        for kind in ("before", "after")}
    grouped = defaultdict(list)
    for row in photos:
        grouped[hashlib.sha256(row["data"]).hexdigest()].append(row["id"])
    data = {row["id"]: row["data"] for row in photos}
    return {"status": "checked", "method": "local_cv", "scope": "submission_selected_pair",
        "before_id": selected["before"], "after_id": selected["after"],
        "duplicate_before": None if selected["before"] is None else data[selected["before"]] == data[selected["after"]],
        "exact_duplicate_groups": sorted(sorted(ids) for ids in grouped.values() if len(ids) > 1),
        "equipment_status": "unknown", "model_available": False, "capture_time_status": "unknown",
        "repair_status": "unknown", "history_status": "not_checked"}


def photo_reply(request, photos, changes=None):
    result = {**unknown(), "photo_check": {**checked(photos), **(changes or {})}}
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
    {"after_id": 999}, {"before_id": 1}, {"after_id": 2}, {"before_id": True}, {"duplicate_before": "true"},
    {"duplicate_before": False}, {"exact_duplicate_groups": []},
    {"exact_duplicate_groups": [[1, 999]]}, {"exact_duplicate_groups": [[1, 4, 3]]},
    {"equipment_status": "different", "model_available": False},
    {"capture_time_status": "recent"}, {"repair_status": "repaired"},
    {"history_status": "checked"}, {"unexpected": "not_allowed"},
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
        result = {**unknown(), "is_stub": False, "llm_used": True, "photo_check": checked(photos)}
        return reply(request, result)
    service_client.app.state.run_ai_jobs(provider=AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN,
        httpx.MockTransport(handler)))
    current = detail(service_client, id_)
    assert current["ai_review"] is None and current["score"] is None
    assert current["ai_review_job"]["last_error_code"] == "invalid_result"


@pytest.mark.parametrize("status", ["checked", "unavailable"])
def test_after_only_or_unavailable_pixels_are_unknown_not_a_grade(service_client, status):
    id_ = new_order(service_client)
    start(service_client, id_)
    after_id = upload(service_client, id_, "after", "green")
    complete(service_client, id_)
    with service_client.app.state.sessions() as db:
        after = db.get(Photo, after_id)
        photos = [{"id": after.id, "kind": after.kind, "data": bytes(after.data)}]
    def handler(request):
        return photo_reply(request, photos, {"status": status})
    service_client.app.state.run_ai_jobs(provider=AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN,
        httpx.MockTransport(handler)))
    result = detail(service_client, id_)["ai_review"]
    assert result["score"] is None and result["source_verdict"] == "needs_master_review"
    assert result["photo_check"]["before_id"] is None and result["photo_check"]["after_id"] == after_id
    assert result["photo_check"]["duplicate_before"] is None
    assert result["photo_check"]["equipment_status"] == "unknown" and result["photo_check"]["model_available"] is False


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


def test_actual_v2_asgi_handlers_validate_pixels_before_the_cv_double(service_client, monkeypatch):
    # Actual HTTP encoding/handlers and SQL, with an explicit CV response double.
    # This proves composition/input binding, not image recognition or a socket.
    monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[2]))
    from ai_service.app.attempt_bridge import create_attempt_app
    from ai_service.app.config import Settings
    id_, _, _, _, photos = photo_submission(service_client)
    calls = []
    class RecordingRunner:
        async def run(self, metadata, decoded):
            assert metadata == [{"id": row["id"], "kind": row["kind"],
                "sha256": hashlib.sha256(row["data"]).hexdigest()} for row in photos]
            assert decoded == [{"id": row["id"], "data": row["data"]} for row in photos]
            calls.append(metadata)
            return checked(photos)
    service = create_attempt_app(Settings(ai_service_token=TOKEN), photo_runner=RecordingRunner())
    adapter = AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN, httpx.ASGITransport(app=service))
    service_client.app.state.run_ai_jobs(provider=adapter)
    current = detail(service_client, id_)
    assert current["status"] == "ai_review" and current["ai_review_job"]["status"] == "succeeded"
    assert current["ai_review"]["photo_check"] == checked(photos) and current["ai_review"]["score"] is None
    assert len(calls) == 1


def test_optional_actual_cv_v2_asgi_primary_sql_and_manual_close(service_client, monkeypatch, tmp_path):
    # Minimal backend CI intentionally omits CV dependencies; the AI CI job
    # exercises the real spawned CV endpoint separately. Local opt-in presence
    # allows this composition test without a network socket or external model.
    pytest.importorskip("cv2", reason="Actual CV composition needs optional OpenCV; AI CI runs real CV separately")
    pytest.importorskip("imagehash", reason="Actual CV composition needs optional ImageHash; AI CI runs real CV separately")
    monkeypatch.syspath_prepend(str(Path(__file__).resolve().parents[2]))
    monkeypatch.setenv("AI_IMAGE_EMBEDDING_MODEL", str(tmp_path / "absent-synthetic-model.onnx"))
    from ai_service.app.attempt_bridge import create_attempt_app
    from ai_service.app.config import Settings
    id_, _, _, _, photos = photo_submission(service_client)
    service = create_attempt_app(Settings(ai_service_token=TOKEN))
    adapter = AttemptServiceAdapter("http://127.0.0.1:8010", TOKEN, httpx.ASGITransport(app=service))
    service_client.app.state.run_ai_jobs(provider=adapter)
    current = detail(service_client, id_)
    assert current["status"] == "ai_review" and current["ai_review_job"]["status"] == "succeeded"
    check = current["ai_review"]["photo_check"]
    assert check == checked(photos)
    assert check["duplicate_before"] is True and check["model_available"] is False
    assert current["ai_review"]["score"] is None and current["ai_review"]["source_verdict"] == "needs_master_review"
    assert current["ai_review"]["llm_used"] is False and current["ai_review"]["is_stub"] is True
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
