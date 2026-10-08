"""Stateless, authenticated review of one immutable submission.

Text checks remain deterministic. v2 sends only the selected linked JPEG pair
to OpenAI Vision; it never constructs a local image model or reads a database.
"""
from __future__ import annotations

import asyncio
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import hashlib
import hmac
import json
import os
import threading
from typing import Literal

from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator

from .config import Settings
from .llm_client import SemanticAssessment, VisionAssessment
from .openai_vision import OpenAIVisionError, OpenAIVisionReviewer
from .schemas import CompletionRecord, OrderRecord, PhotoRecord, Snapshot
from .verification import (
    calculate_flags, decide_verdict, rule_semantics, scrub, semantic_valid,
    suggested_score,
)

MAX_REQUEST_BYTES = 1024 * 1024
MAX_PHOTO_REQUEST_BYTES = 56 * 1024 * 1024
LLM_TIMEOUT_SECONDS = 6
MAX_RESPONSE_BYTES = 64 * 1024
_PHOTO_PARSE_GATE = threading.BoundedSemaphore(2)
_PHOTO_PARSE_EXECUTOR = ThreadPoolExecutor(max_workers=2, thread_name_prefix="attempt-photo-input")


class StrictRecord(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


class PhotoMetadata(StrictRecord):
    id: int = Field(gt=0)
    kind: Literal["before", "after"]
    sha256: str = Field(pattern=r"^[0-9a-f]{64}$")


class ReviewEnvelope(StrictRecord):
    schema_version: int = Field(ge=1, le=1)
    attempt_id: int = Field(gt=0)
    order_id: int = Field(gt=0)
    input_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    context: dict
    report: dict
    photos: list[PhotoMetadata] = Field(max_length=10)


class PhotoContent(StrictRecord):
    id: int = Field(gt=0)
    data_base64: str = Field(min_length=1, max_length=((4 * 1024 * 1024 + 2) // 3) * 4)


class PhotoReviewEnvelope(ReviewEnvelope):
    schema_version: int = Field(ge=2, le=2)
    photo_content: list[PhotoContent] = Field(max_length=10)


class ReportChecks(StrictRecord):
    work_description: Literal["present", "missing"]
    fault_code: Literal["present", "missing"]
    fault_code_vs_problem: Literal["match", "mismatch", "unknown"]
    work_vs_fault_code: Literal["match", "mismatch", "unknown"]
    materials_vs_norm: Literal["within_norm", "issue", "missing", "unknown"]
    time_vs_norm: Literal["within_norm", "over_norm", "unknown"]
    deadline: Literal["on_time", "late", "unknown"]
    after_photo: Literal["present", "missing"]
    after_photo_required: bool


class FrozenOrder(StrictRecord):
    id: int = Field(gt=0)
    number: str = Field(max_length=40)
    title: str = Field(max_length=200)
    description: str = Field(max_length=5000)
    work_type: Literal["planned", "unplanned"]
    area_id: int = Field(gt=0)
    equipment_id: int = Field(gt=0)
    assignee_id: int = Field(gt=0)
    brigade_id: int | None = Field(default=None, gt=0)
    master_id: int = Field(gt=0)
    priority: Literal["emergency", "high", "normal", "planned"]
    status: Literal["completed"]
    deadline: datetime
    created_at: datetime
    started_at: datetime | None = None
    completed_at: datetime
    normal_hours: float | None = Field(default=None, gt=0, allow_inf_nan=False)

    @field_validator("deadline", "created_at", "started_at", "completed_at")
    @classmethod
    def aware_times(cls, value):
        if value is not None and value.tzinfo is None:
            raise ValueError("Explicit timezone required")
        return value


class FrozenFault(StrictRecord):
    id: int = Field(gt=0)
    code: str = Field(min_length=1, max_length=30)
    name: str = Field(min_length=1, max_length=180)


class FrozenContext(StrictRecord):
    order: FrozenOrder
    fault_codes: list[FrozenFault]
    submission_order_version: int = Field(gt=0)
    assignment_id: int = Field(gt=0)
    sequence: int = Field(gt=0)
    photos: list[PhotoMetadata] = Field(max_length=10)


class FrozenMaterial(StrictRecord):
    material_id: int = Field(gt=0)
    name: str = Field(max_length=180)
    unit: str = Field(max_length=30)
    quantity: float = Field(gt=0, le=1_000_000, allow_inf_nan=False)


class FrozenReport(StrictRecord):
    work_done: str = Field(max_length=5000)
    fault_code_id: int | None = Field(default=None, gt=0)
    comment: str = Field(default="", max_length=3000)
    materials: list[FrozenMaterial] = Field(default_factory=list, max_length=100)


def input_digest(envelope: dict) -> str:
    """Hash original JSON values, before parsing dates or adding defaults."""
    value = {key: item for key, item in envelope.items() if key != "input_sha256"}
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"),
                         ensure_ascii=False, allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _unique_objects(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(_):
    raise ValueError("Non-finite JSON value")


def _parse(raw: bytes, version=1):
    try:
        payload = json.loads(raw.decode("utf-8"), object_pairs_hook=_unique_objects,
                             parse_constant=_reject_constant)
        envelope = (ReviewEnvelope if version == 1 else PhotoReviewEnvelope).model_validate(payload)
        if not hmac.compare_digest(envelope.input_sha256, input_digest(payload)):
            raise ValueError("Input hash mismatch")
        # JSON mode allows ISO timestamps without weakening strict scalar types.
        context = FrozenContext.model_validate_json(json.dumps(envelope.context))
        report = FrozenReport.model_validate(envelope.report)
        if context.order.id != envelope.order_id or context.photos != envelope.photos:
            raise ValueError("Inconsistent submission identity or photo metadata")
        for rows, key in ((context.fault_codes, "id"), (report.materials, "material_id"),
                          (envelope.photos, "id")):
            values = [getattr(row, key) for row in rows]
            if len(values) != len(set(values)):
                raise ValueError("Duplicate identity")
        if any(count > 5 for count in Counter(photo.kind for photo in envelope.photos).values()):
            raise ValueError("Too many photos of one kind")
        if version == 2 and [row.id for row in envelope.photo_content] != [row.id for row in envelope.photos]:
            raise ValueError("Inconsistent content identities")
    except (ValidationError, ValueError, TypeError, UnicodeError, RecursionError):
        # Pydantic errors may contain raw input; never echo them to callers/logs.
        raise HTTPException(422, "invalid_submission_review_input") from None
    return envelope, context, report


async def _review(envelope, context, report, llm, image_note=None, vision_used=False):
    order_values = context.order.model_dump()
    # Calendar elapsed time and demo material norms are not approved Q04/Q05 facts.
    order_values.update(started_at=None, normal_hours=None,
                        completion=CompletionRecord.model_validate(report.model_dump()),
                        photos=[PhotoRecord(id=photo.id, kind=photo.kind) for photo in envelope.photos])
    order = OrderRecord.model_validate(order_values)
    snapshot = Snapshot(orders=[order], fault_codes=[fault.model_dump() for fault in context.fault_codes])
    flags = calculate_flags(order, snapshot)
    match, confidence = rule_semantics(order, snapshot)
    semantic, invalid, unavailable = None, False, False
    if llm is not None:
        prompt = {
            "equipment_id": order.equipment_id,
            "fault_code_id": report.fault_code_id,
            "problem": scrub(order.description or order.title, snapshot),
            "work_done": scrub(report.work_done, snapshot),
            "flags": dict(flags),
            "evidence_refs": ["problem", "work_done", "time", "deadline", "fault_code",
                              "after_photo", "materials"]
                             + [f"material:{item.material_id}" for item in report.materials],
        }
        try:
            value = await asyncio.wait_for(llm.interpret(prompt), timeout=LLM_TIMEOUT_SECONDS)
            if value is None:
                unavailable = True
            else:
                candidate = SemanticAssessment.model_validate(value, strict=True)
                invalid = not semantic_valid(candidate, order, snapshot, flags)
                if not invalid:
                    semantic = candidate
                    match, confidence = semantic.works_match_problem, semantic.match_confidence
        except ValidationError:
            invalid = True
        except Exception:
            # Fixed explanation only: provider exceptions may include secrets/input.
            unavailable = True
    source_verdict = decide_verdict(flags, match, confidence, llm_invalid=invalid)
    score = suggested_score(source_verdict, flags, match)
    verdict = {"accepted": "passed", "accepted_with_remarks": "needs_attention",
               "needs_rework": "needs_rework", "needs_master_review": "needs_attention"}[source_verdict]
    notes = ["Текстовая рекомендация; финальное решение принимает мастер.",
             image_note or "Изображения не анализировались; давность съёмки, активное время и нормы материалов неизвестны."]
    if flags["missing_work"]:
        notes.append("Описание выполненных работ отсутствует.")
    if flags["missing_fault_code"]:
        notes.append("Шифр неисправности отсутствует в сохранённом справочнике.")
    if flags["missing_after_photo"]:
        notes.append("В сохранённой попытке нет метаданных обязательного фото после.")
    if flags["code_description_status"] == "mismatch":
        notes.append("Формальная проверка обнаружила несоответствие шифра описанию задачи.")
    if match is False:
        notes.append("Описание выполненных работ не соответствует указанной неисправности.")
    if invalid:
        notes.append("Семантический ответ не прошёл проверку доказательств; требуется мастер.")
    elif unavailable:
        notes.append("Семантическая проверка недоступна; использованы только локальные правила.")
    elif vision_used:
        notes.append("Текст отчёта проверен правилами; для фото использована модель OpenAI Vision.")
    elif semantic is None:
        notes.append("Использованы только локальные правила; внешний ИИ отключён.")
    else:
        notes.append(semantic.explanation_master)
    if source_verdict == "needs_master_review":
        notes.append("Оценка неизвестна: требуется проверка мастером.")
    materials_status = "unknown"
    if flags["material_norm_status"] == "known":
        materials_status = (
            "missing" if flags["missing_materials"] else
            "issue" if flags["excess_material_ids"] or flags["unusual_material_ids"] else
            "within_norm"
        )
    report_checks = ReportChecks(
        work_description="present" if not flags["missing_work"] else "missing",
        fault_code="present" if not flags["missing_fault_code"] else "missing",
        fault_code_vs_problem=flags["code_description_status"],
        work_vs_fault_code="unknown" if match is None else "match" if match else "mismatch",
        materials_vs_norm=materials_status,
        time_vs_norm=flags["time_status"],
        deadline=flags["deadline_status"],
        after_photo=("present" if any(photo.kind == "after" for photo in order.photos) else "missing"),
        after_photo_required=order.work_type == "unplanned",
    ).model_dump()
    explanation = (
        "Визуальная рекомендация сформирована по выбранным фото. Текст отчёта, нормы материалов "
        "и рабочее время моделью не анализировались; доступные формальные проверки приведены отдельно."
        if vision_used else " ".join(notes)[:2000]
    )
    return {"schema_version": 1, "attempt_id": envelope.attempt_id,
            "input_sha256": envelope.input_sha256,
            "result": {"verdict": verdict, "score": score,
            "explanation": explanation, "is_stub": semantic is None and not vision_used,
            "master_score": None, "source_verdict": source_verdict,
            "llm_used": semantic is not None or vision_used, "is_recommendation": True,
            "report_checks": report_checks}}


def _owned_photo_input(raw):
    from .attempt_photos import decode_content

    try:
        envelope, context, report = _parse(raw, 2)
        metadata = [row.model_dump() for row in envelope.photos]
        decoded = decode_content(metadata, [row.model_dump() for row in envelope.photo_content])
        return envelope, context, report, metadata, decoded
    except ValueError:
        raise HTTPException(422, "invalid_submission_review_input") from None
    finally:
        _PHOTO_PARSE_GATE.release()


def create_attempt_app(settings: Settings | None = None, llm=None, vision_client=None) -> FastAPI:
    """Build the internal bridge; OpenAI Vision is used only by v2 when configured."""
    settings = settings if settings is not None else Settings.from_env()
    expected = settings.ai_service_token.get_secret_value().encode("utf-8")
    app = FastAPI(title="Submission review bridge", docs_url=None, redoc_url=None, openapi_url=None)

    @app.get("/healthz")
    async def healthz():
        configured = bool(settings.openai_api_key.get_secret_value() and settings.openai_vision_model.strip())
        return {"status": "ok", "vision": "configured" if configured else "not_configured"}

    def authorize(request):
        # Parse no body before server-to-server authority is established.
        if not expected:
            raise HTTPException(503, "submission_review_not_configured")
        headers = request.headers.getlist("authorization")
        supplied = headers[0] if len(headers) == 1 else ""
        supplied = supplied[7:] if supplied.startswith("Bearer ") else ""
        if not hmac.compare_digest(supplied.encode("utf-8"), expected):
            raise HTTPException(401, "unauthorized_submission_review")

    async def read_body(request, limit):
        length = request.headers.get("content-length")
        if length is not None:
            try:
                declared = int(length)
                if declared < 0:
                    raise ValueError("Negative content length")
                if declared > limit:
                    raise HTTPException(413, "submission_review_too_large")
            except ValueError:
                raise HTTPException(400, "invalid_content_length") from None
        raw = bytearray()
        async for chunk in request.stream():
            if len(raw) + len(chunk) > limit:
                raise HTTPException(413, "submission_review_too_large")
            raw.extend(chunk)
        return bytes(raw)

    def bounded_result(result):
        if len(json.dumps(result, ensure_ascii=False).encode("utf-8")) > MAX_RESPONSE_BYTES:
            raise HTTPException(502, "invalid_submission_review_result")
        return result

    @app.post("/internal/v1/submission-review")
    async def review(request: Request):
        authorize(request)
        envelope, context, report = _parse(await read_body(request, MAX_REQUEST_BYTES))
        result = await _review(envelope, context, report, llm)
        return bounded_result(result)

    @app.post("/internal/v2/submission-review")
    async def photo_review(request: Request):
        authorize(request)
        if not _PHOTO_PARSE_GATE.acquire(blocking=False):
            raise HTTPException(503, "submission_review_busy")
        submitted = False
        try:
            raw = await read_body(request, MAX_PHOTO_REQUEST_BYTES)
            future = _PHOTO_PARSE_EXECUTOR.submit(_owned_photo_input, raw)
            submitted = True
            task = asyncio.wrap_future(future)
            task.add_done_callback(lambda done: None if done.cancelled() else done.exception())
            envelope, context, report, metadata, decoded = await asyncio.shield(task)
        finally:
            if not submitted:
                _PHOTO_PARSE_GATE.release()
        from .attempt_photos import PhotoCheck, selected_pair

        selected, before_jpeg, after_jpeg = selected_pair(metadata, decoded)
        if after_jpeg is None:
            check = PhotoCheck(status="no_after", before_id=selected["before"],
                               after_id=None).model_dump()
            vision_used = False
            note = "Фото после выполнения в сохранённой попытке отсутствует."
        else:
            reviewer = vision_client or OpenAIVisionReviewer(
                settings.openai_api_key, settings.openai_vision_model
            )
            try:
                candidate = await reviewer.review(before_jpeg, after_jpeg)
                vision = (candidate if isinstance(candidate, VisionAssessment)
                          else VisionAssessment.model_validate(candidate, strict=True))
                if before_jpeg is None and (vision.same_equipment is not None or vision.defect_resolved is not None):
                    raise ValueError("invalid_vision_output")
                check = PhotoCheck(status="checked", before_id=selected["before"],
                                   after_id=selected["after"], vision=vision).model_dump()
                vision_used = True
            except OpenAIVisionError as error:
                code = str(error)
                status = 503 if code == "openai_vision_not_configured" else 502
                raise HTTPException(status, code) from None
            except (ValidationError, TypeError, ValueError):
                raise HTTPException(502, "invalid_submission_review_result") from None
            note = ("OpenAI Vision обработал только выбранные фото этой попытки; это визуальная "
                    "рекомендация, не подтверждение ремонта. Время съёмки и фото других нарядов не проверялись.")
        result = await _review(envelope, context, report, None, note, vision_used=vision_used)
        result["schema_version"] = 2
        result["result"].update(verdict="needs_attention", source_verdict="needs_master_review",
                                 score=None, photo_check=check)
        return bounded_result(result)

    return app
