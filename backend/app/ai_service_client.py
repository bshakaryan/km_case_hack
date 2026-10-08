import os

import httpx
from pydantic import BaseModel, Field


class ServiceReview(BaseModel):
    source_version: str
    verdict: str
    suggested_score: float | None = Field(default=None, ge=1, le=5)
    match_confidence: float = Field(ge=0, le=1)
    flags: dict
    remarks: list[dict]
    concerns: list[str]
    explanation_worker: str
    explanation_master: str
    llm_used: bool
    needs_master_review: bool


class ServicePhotoReview(BaseModel):
    source_version: str
    needs_master_review: bool
    reasons: list[str]
    duplicate_before: dict | None = None
    duplicate_history: dict | None = None
    after_photo_id: int | None = None
    before_photo_id: int | None = None


class ServiceResponse(BaseModel):
    review: ServiceReview
    photo_review: ServicePhotoReview


class AIServiceProvider:
    model = "ai_service"
    mode = "service"

    def __init__(self, url=None, token=None, client=None):
        self.url = (url or os.getenv("AI_SERVICE_URL", "http://ai:8090")).rstrip("/")
        self.token = token or os.getenv("AI_SERVICE_TOKEN", "")
        if not self.token:
            raise ValueError("AI_SERVICE_TOKEN не задан")
        self.client = client or httpx.Client(timeout=120)

    def review(self, snapshot, images):
        order_id = snapshot["order_id"]
        version = snapshot["source_version"]
        response = self.client.post(
            f"{self.url}/ai/reviews/{order_id}/evaluate",
            headers={"Authorization": f"Bearer {self.token}"},
            json={"source_version": version},
        )
        response.raise_for_status()
        result = ServiceResponse.model_validate(response.json())
        review = result.review
        photo = result.photo_review
        if review.source_version != version or photo.source_version != version:
            raise ValueError("ИИ-сервис вернул результат другой сдачи")
        duplicate = bool((photo.duplicate_before or {}).get("duplicate") or photo.duplicate_history)
        verdict = {
            "accepted": "passed",
            "accepted_with_remarks": "needs_attention",
            "needs_rework": "needs_rework",
            "needs_master_review": "needs_attention",
        }.get(review.verdict)
        if verdict is None:
            raise ValueError("ИИ-сервис вернул неизвестный вердикт")
        needs_master_review = review.needs_master_review or photo.needs_master_review
        service_verdict = review.verdict
        score = review.suggested_score
        if needs_master_review and service_verdict != "needs_rework":
            service_verdict = "needs_master_review"
            verdict = "needs_attention"
            score = None
        if duplicate and verdict == "passed":
            verdict = "needs_attention"
        issues = list(dict.fromkeys([*review.concerns, *photo.reasons]))[:10]
        return {
            "verdict": verdict,
            "service_verdict": service_verdict,
            "score": score,
            "confidence": review.match_confidence,
            "explanation": review.explanation_master,
            "explanation_worker": review.explanation_worker,
            "photo_summary": "; ".join(photo.reasons)[:1500],
            "issues": issues,
            "flags": review.flags,
            "remarks": review.remarks,
            "needs_master_review": needs_master_review,
            "photo_review": photo.model_dump(),
            "checked_without_llm": not review.llm_used,
        }

    async def get(self, path: str, params: dict | None = None):
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.get(f"{self.url}{path}",
                                        headers={"Authorization": f"Bearer {self.token}"},
                                        params={key: value for key, value in (params or {}).items() if value is not None})
        response.raise_for_status()
        return response.json()

    async def post(self, path: str, payload: dict):
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.post(f"{self.url}{path}",
                                         headers={"Authorization": f"Bearer {self.token}"}, json=payload)
        response.raise_for_status()
        return response.json()

    async def download(self, path: str, params: dict):
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.get(f"{self.url}{path}",
                                        headers={"Authorization": f"Bearer {self.token}"}, params=params)
        response.raise_for_status()
        return response.content
