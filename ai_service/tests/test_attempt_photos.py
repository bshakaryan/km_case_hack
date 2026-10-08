"""OpenAI photo-review bridge tests use synthetic JPEGs and mocked providers."""
import asyncio
import base64
import copy
import hashlib
import io
import json

import httpx
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.attempt_bridge import create_attempt_app, input_digest
from app.attempt_photos import decode_content, selected_pair
from app.config import Settings
from app.llm_client import VisionAssessment
from app.openai_vision import OpenAIVisionError, OpenAIVisionReviewer
from test_attempt_bridge import HEADERS, TOKEN, signed_packet

ROUTE = "/internal/v2/submission-review"
OPENAI_KEY = "synthetic-openai-key"


def jpeg(color):
    output = io.BytesIO()
    Image.new("RGB", (32, 24), color).save(output, "JPEG", quality=85)
    return output.getvalue()


def packet(rows=None):
    rows = rows if rows is not None else [(20, "before", jpeg("red")), (21, "after", jpeg("blue"))]
    value = signed_packet()
    value["schema_version"] = 2
    value["photos"] = [{"id": id_, "kind": kind, "sha256": hashlib.sha256(data).hexdigest()}
                       for id_, kind, data in rows]
    value["context"]["photos"] = copy.deepcopy(value["photos"])
    value["photo_content"] = [{"id": id_, "data_base64": base64.b64encode(data).decode("ascii")}
                              for id_, _, data in rows]
    value["input_sha256"] = input_digest(value)
    return value


def assessment(**changes):
    return VisionAssessment.model_validate({
        "same_equipment": True,
        "defect_resolved": None,
        "quality": "unknown",
        "confidence": 0.5,
        "issues": [],
        "explanation": "По снимкам нельзя уверенно подтвердить результат.",
        "visual_criteria": {
            name: {"status": "not_assessable", "observation": ""}
            for name in ("cleanliness", "fasteners", "guards", "leakage")
        },
        **changes,
    })


class VisionDouble:
    def __init__(self, result=None, error=None):
        self.result = result or assessment()
        self.error = error
        self.calls = []

    async def review(self, before, after):
        self.calls.append((before, after))
        if self.error:
            raise self.error
        return self.result


def client(vision=None, settings=None):
    settings = settings or Settings(ai_service_token=TOKEN, openai_api_key=OPENAI_KEY)
    return TestClient(create_attempt_app(settings, vision_client=vision))


def test_v2_calls_vision_for_only_latest_attempt_pair_and_keeps_master_decision():
    first_before, first_after = jpeg("red"), jpeg("blue")
    latest_before, latest_after = jpeg("green"), jpeg("yellow")
    value = packet([(10, "before", first_before), (11, "after", first_after),
                    (20, "before", latest_before), (21, "after", latest_after)])
    vision = VisionDouble()
    with client(vision) as service:
        response = service.post(ROUTE, json=value, headers=HEADERS)

    assert response.status_code == 200, response.text
    result = response.json()["result"]
    assert vision.calls == [(latest_before, latest_after)]
    assert result["photo_check"]["method"] == "openai_vision"
    assert result["photo_check"]["before_id"] == 20
    assert result["photo_check"]["after_id"] == 21
    assert result["photo_check"]["vision"]["quality"] == "unknown"
    assert set(result["photo_check"]["vision"]["visual_criteria"]) == {
        "cleanliness", "fasteners", "guards", "leakage"
    }
    assert result["report_checks"]["work_description"] == "present"
    assert result["report_checks"]["materials_vs_norm"] == "unknown"
    assert result["report_checks"]["time_vs_norm"] == "unknown"
    assert result["report_checks"]["deadline"] == "on_time"
    assert result["source_verdict"] == "needs_master_review"
    assert result["verdict"] == "needs_attention" and result["score"] is None
    assert result["master_score"] is None and result["is_recommendation"] is True
    assert result["llm_used"] is True and result["is_stub"] is False
    assert value["report"]["work_done"] not in response.text


def test_after_only_does_not_allow_comparison_claims():
    value = packet([(8, "after", jpeg("blue"))])
    vision = VisionDouble(assessment(same_equipment=True, defect_resolved=False))
    with client(vision) as service:
        response = service.post(ROUTE, json=value, headers=HEADERS)
    assert response.status_code == 502
    assert response.json() == {"detail": "invalid_submission_review_result"}


def test_missing_after_skips_provider_and_returns_unknown_without_stub_claim():
    value = packet([(7, "before", jpeg("red"))])
    vision = VisionDouble()
    with client(vision) as service:
        response = service.post(ROUTE, json=value, headers=HEADERS)
    result = response.json()["result"]
    assert response.status_code == 200 and not vision.calls
    assert result["photo_check"]["status"] == "no_after"
    assert result["photo_check"]["before_id"] == 7
    assert result["photo_check"]["after_id"] is None
    assert result["source_verdict"] == "needs_master_review" and result["score"] is None
    assert result["llm_used"] is False and result["is_stub"] is True


def test_missing_api_key_is_explicit_and_health_does_not_expose_secrets():
    value = packet()
    settings = Settings(ai_service_token=TOKEN)
    with client(settings=settings) as service:
        health = service.get("/healthz")
        response = service.post(ROUTE, json=value, headers=HEADERS)
    assert health.status_code == 200
    assert health.json() == {"status": "ok", "vision": "not_configured"}
    assert OPENAI_KEY not in health.text
    assert response.status_code == 503
    assert response.json() == {"detail": "openai_vision_not_configured"}


def test_invalid_jpeg_or_hash_is_rejected_before_provider_call():
    value = packet()
    value["photo_content"][0]["data_base64"] = base64.b64encode(b"not a jpeg").decode()
    value["input_sha256"] = input_digest(value)
    vision = VisionDouble()
    with client(vision) as service:
        response = service.post(ROUTE, json=value, headers=HEADERS)
    assert response.status_code == 422
    assert response.json() == {"detail": "invalid_submission_review_input"}
    assert not vision.calls


def test_selected_pair_binds_only_latest_photo_ids():
    rows = [(2, "after", jpeg("red")), (3, "before", jpeg("blue")),
            (4, "after", jpeg("green")), (5, "before", jpeg("yellow"))]
    value = packet(rows)
    decoded = decode_content(value["photos"], value["photo_content"])
    selected, before, after = selected_pair(value["photos"], decoded)
    assert selected == {"before": 5, "after": 4}
    assert before == rows[-1][2] and after == rows[-2][2]


def test_openai_responses_request_contains_only_two_selected_images_and_no_report_data():
    before, after = jpeg("red"), jpeg("blue")
    seen = []

    def handler(request):
        body = json.loads(request.content)
        seen.append((request, body))
        return httpx.Response(200, json={"output": [{"type": "message", "content": [{
            "type": "output_text", "text": json.dumps(assessment().model_dump()),
        }]}]})

    reviewer = OpenAIVisionReviewer(OPENAI_KEY, "gpt-6-astra", httpx.MockTransport(handler))
    result = asyncio.run(reviewer.review(before, after))

    request, body = seen[0]
    assert request.url == "https://api.openai.com/v1/responses"
    assert request.headers["authorization"] == f"Bearer {OPENAI_KEY}"
    assert body["model"] == "gpt-6-astra" and body["store"] is False
    assert len(body["input"]) == 2 and body["input"][1]["role"] == "user"
    images = [part["image_url"] for part in body["input"][1]["content"] if part["type"] == "input_image"]
    assert images == [reviewer._data_url(before), reviewer._data_url(after)]
    serialized = json.dumps(body, ensure_ascii=False)
    for forbidden in ("work_done", "Подшипник", "assignee_id", "employee", "attempt_id", "order_id"):
        assert forbidden not in serialized
    assert result.quality == "unknown"


def test_openai_provider_errors_are_redacted():
    reviewer = OpenAIVisionReviewer(
        OPENAI_KEY, "gpt-6-astra",
        httpx.MockTransport(lambda _: httpx.Response(401, text=f"invalid key {OPENAI_KEY}")),
    )
    with pytest.raises(OpenAIVisionError, match="openai_vision_request_failed") as captured:
        asyncio.run(reviewer.review(jpeg("red"), jpeg("blue")))
    assert OPENAI_KEY not in str(captured.value)
