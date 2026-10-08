"""Durable review jobs with attempt, assignment, provider and lease fences."""
from copy import deepcopy
from datetime import timedelta, timezone
from typing import Literal
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field, ValidationError
from sqlalchemy import and_, or_, select, update

from .models import AIAssessment, AIReviewJob, IntegrationLog, Order, OrderAssignment, Photo, SubmissionAttempt, SubmissionPhoto, utcnow

LEASE_SECONDS = 30


def aware(value):
    return value.replace(tzinfo=timezone.utc) if value and value.tzinfo is None else value


def iso(value):
    return aware(value).isoformat() if value else None


def begin_sqlite_write(db):
    if db.bind.dialect.name == "sqlite":
        connection = db.connection()
        if not connection.connection.driver_connection.in_transaction:
            connection.exec_driver_sql("BEGIN IMMEDIATE")


class VisualCriterion(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    status: Literal["no_visible_issue", "issue_visible", "not_assessable"]
    observation: str = Field(max_length=240)


class VisualCriteria(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    cleanliness: VisualCriterion
    fasteners: VisualCriterion
    guards: VisualCriterion
    leakage: VisualCriterion


class VisionCheck(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    same_equipment: bool | None
    defect_resolved: bool | None
    quality: Literal["excellent", "good", "mixed", "poor", "critical", "unknown"]
    confidence: float = Field(ge=0, le=1, allow_inf_nan=False)
    issues: list[str] = Field(max_length=8)
    explanation: str = Field(max_length=1000)
    visual_criteria: VisualCriteria | None = None


class PhotoCheck(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    status: Literal["checked", "no_after"]
    method: Literal["openai_vision"]
    scope: Literal["submission_selected_pair"]
    before_id: int | None = Field(gt=0)
    after_id: int | None = Field(gt=0)
    vision: VisionCheck | None
    capture_time_status: Literal["unknown"]
    history_status: Literal["not_checked"]


class ReportChecks(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    work_description: Literal["present", "missing"]
    fault_code: Literal["present", "missing"]
    fault_code_vs_problem: Literal["match", "mismatch", "unknown"]
    work_vs_fault_code: Literal["match", "mismatch", "unknown"]
    materials_vs_norm: Literal["within_norm", "issue", "missing", "unknown"]
    time_vs_norm: Literal["within_norm", "over_norm", "unknown"]
    deadline: Literal["on_time", "late", "unknown"]
    after_photo: Literal["present", "missing"]
    after_photo_required: bool


class ReviewResult(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, str_strip_whitespace=True)
    verdict: Literal["passed", "needs_attention", "needs_rework"]
    score: float | None = Field(ge=1, le=5, allow_inf_nan=False)
    explanation: str = Field(min_length=1, max_length=2000)
    is_stub: bool
    master_score: None = None
    source_verdict: Literal["accepted", "accepted_with_remarks", "needs_rework", "needs_master_review"] | None = None
    llm_used: bool | None = None
    is_recommendation: Literal[True] | None = None
    input_sha256: str | None = Field(default=None, pattern=r"^[0-9a-f]{64}$")
    bridge_version: Literal[1, 2] | None = None
    photo_check: PhotoCheck | None = None
    report_checks: ReportChecks | None = None


class FormalStub:
    def review(self, snapshot):
        paired = {photo["kind"] for photo in snapshot["photos"]} == {"before", "after"}
        return {"verdict": "passed" if paired else "needs_attention", "score": 4.5 if paired else 4.0,
            "explanation": "Заглушка ИИ: проверена только полнота отчёта и наличие фотографий. Содержимое изображений не анализируется. Решение о приёмке принимает мастер.", "is_stub": True, "master_score": None}


def job_dict(job, retry_allowed=False):
    if job is None:
        return None
    return {"id": job.id, "attempt_id": job.attempt_id, "status": job.status, "provider": job.provider,
        "attempts": job.attempts, "max_attempts": job.max_attempts, "next_attempt_at": iso(job.next_attempt_at),
        "lease_expires_at": iso(job.lease_expires_at), "last_error_code": job.last_error_code,
        "created_at": iso(job.created_at), "finished_at": iso(job.finished_at), "retry_allowed": retry_allowed}


def enqueue_job(db, attempt, provider="stub"):
    if provider not in {"stub", "ai_service"}:
        raise ValueError("unknown_review_provider")
    job = AIReviewJob(attempt_id=attempt.id, status="pending", provider=provider, attempts=0,
        max_attempts=3, next_attempt_at=utcnow(), created_at=utcnow())
    db.add(job)
    db.flush()
    return job


def review_snapshot(db, attempt):
    # Names and quantities come from the frozen report, and photos exclusively
    # from its links. Current order reports/media never enter the provider.
    return {"attempt_id": attempt.id, "order_id": attempt.order_id, "ai_input": deepcopy(attempt.ai_input), "report": deepcopy(attempt.payload),
        "photos": [{"id": photo.id, "kind": photo.kind, "data": bytes(photo.data)}
            for photo in db.scalars(select(Photo).join(SubmissionPhoto, SubmissionPhoto.photo_id == Photo.id).where(SubmissionPhoto.attempt_id == attempt.id).order_by(Photo.id))]}


def validate_result(result, provider="stub"):
    if not isinstance(result, dict) or type(result.get("is_stub")) is not bool:
        raise ValueError("invalid_result")
    value = ReviewResult.model_validate(result).model_dump(exclude_unset=True)
    if provider == "stub":
        if value["is_stub"] is not True or value["score"] is None or set(value) - {"verdict", "score", "explanation", "is_stub", "master_score"}:
            raise ValueError("invalid_result")
    elif provider == "ai_service":
        mapping = {"accepted": "passed", "accepted_with_remarks": "needs_attention", "needs_rework": "needs_rework", "needs_master_review": "needs_attention"}
        if (value.get("source_verdict") not in mapping or value["verdict"] != mapping[value["source_verdict"]]
                or type(value.get("llm_used")) is not bool or value["is_stub"] == value["llm_used"]
                or type(result.get("is_recommendation")) is not bool
                or value.get("is_recommendation") is not True or not value.get("input_sha256")
                or type(result.get("bridge_version")) is not int or value.get("bridge_version") not in {1, 2}
                or (value["source_verdict"] == "needs_master_review") != (value["score"] is None)):
            raise ValueError("invalid_result")
        if value["bridge_version"] == 1:
            if "photo_check" in value:
                raise ValueError("invalid_result")
        else:
            check = value.get("photo_check")
            if check is None or check["method"] != "openai_vision":
                raise ValueError("invalid_result")
            used_vision = check["status"] == "checked"
            if (value["source_verdict"] != "needs_master_review" or value["score"] is not None
                    or value["llm_used"] is not used_vision or value["is_stub"] is used_vision):
                raise ValueError("invalid_result")
    else:
        raise ValueError("invalid_result")
    return value


def validate_photo_check(check, snapshot):
    """Bind OpenAI Vision results to the selected pair in this immutable attempt."""
    photos = snapshot["photos"]
    selected = {kind: max((photo["id"] for photo in photos if photo["kind"] == kind), default=None)
        for kind in ("before", "after")}
    if check["before_id"] != selected["before"] or check["after_id"] != selected["after"]:
        raise ValueError("invalid_result")
    if check["method"] != "openai_vision":
        raise ValueError("invalid_result")
    status = check["status"]
    if status == "no_after" and selected["after"] is not None:
        raise ValueError("invalid_result")
    if status == "no_after":
        if check["vision"] is not None:
            raise ValueError("invalid_result")
        return
    if status != "checked" or selected["after"] is None or not isinstance(check["vision"], dict):
        raise ValueError("invalid_result")
    if selected["before"] is None:
        if (check["vision"].get("same_equipment") is not None
                or check["vision"].get("defect_resolved") is not None):
            raise ValueError("invalid_result")


def apply_success(db, order, attempt, job, result):
    from .services import audit, notify, participant_ids
    assessment = AIAssessment(order_id=order.id, **{key: result[key] for key in ("verdict", "score", "explanation", "is_stub", "master_score") if key in result})
    db.add(assessment)
    db.flush()
    attempt.ai_review = deepcopy(result)
    attempt.assessment_id = assessment.id
    order.ai_review = deepcopy(result)
    order.status = "ai_review"
    order.version += 1
    audit(db, order, "ai_review", attempt.author_id, "completed", "Автоматическая рекомендация по сдаче. Ожидается решение мастера.")
    notify(db, [order.master_id], "Наряд ожидает приёмки", order.number, "review", order.id)
    notify(db, participant_ids(db, order), "Статус наряда изменён", f"{order.number}: completed → ai_review", "status", order.id)
    db.add(IntegrationLog(adapter="ai_stub" if job.provider == "stub" else "ai_service", operation="review", payload={"order_id": order.id, "attempt_id": attempt.id, "is_stub": result["is_stub"]}))
    job.status = "succeeded"
    job.finished_at = utcnow()
    job.last_error_code = None
    job.lease_token = None
    job.lease_expires_at = None


def run_inline(db, order, attempt, job):
    """Explicit compatibility mode: formal stub inside the original command."""
    job.attempts = 1
    apply_success(db, order, attempt, job, validate_result(FormalStub().review(review_snapshot(db, attempt))))


def applicable(db, order, attempt):
    latest = db.scalar(select(SubmissionAttempt.id).where(SubmissionAttempt.order_id == order.id).order_by(SubmissionAttempt.sequence.desc()).limit(1))
    assignment = db.get(OrderAssignment, attempt.assignment_id) if attempt.assignment_id else None
    current = db.scalar(select(OrderAssignment.id).where(OrderAssignment.order_id == order.id).order_by(OrderAssignment.sequence.desc()).limit(1))
    return (latest == attempt.id and order.status == "completed" and assignment is not None
        and current == assignment.id and assignment.ended_at is None
        and assignment.assignee_id == order.assignee_id == attempt.author_id
        and assignment.brigade_id == order.brigade_id and aware(assignment.assigned_at) == aware(order.assigned_at)
        and attempt.assessment_id is None and attempt.ai_review is None)


def retire_exhausted(sessions):
    changed = []
    now = utcnow()
    due = or_(and_(AIReviewJob.status == "pending", AIReviewJob.next_attempt_at <= now),
        and_(AIReviewJob.status == "running", or_(AIReviewJob.lease_expires_at.is_(None), AIReviewJob.lease_expires_at <= now)))
    with sessions() as db:
        begin_sqlite_write(db)
        candidates = list(db.execute(select(AIReviewJob.id, SubmissionAttempt.order_id).join(SubmissionAttempt, SubmissionAttempt.id == AIReviewJob.attempt_id).where(due, AIReviewJob.attempts >= AIReviewJob.max_attempts).order_by(SubmissionAttempt.order_id, AIReviewJob.id).limit(20)))
        for job_id, order_id in candidates:
            order = db.scalar(select(Order).where(Order.id == order_id).with_for_update())
            job = db.scalar(select(AIReviewJob).where(AIReviewJob.id == job_id).with_for_update())
            if job.status not in {"pending", "running"} or job.attempts < job.max_attempts or (job.status == "running" and job.lease_expires_at and aware(job.lease_expires_at) > utcnow()):
                continue
            attempt = db.get(SubmissionAttempt, job.attempt_id)
            valid = applicable(db, order, attempt)
            job.status = "failed" if valid else "superseded"
            job.last_error_code = "attempt_limit" if valid else None
            job.finished_at = utcnow()
            job.lease_token = None
            job.lease_expires_at = None
            order.version += 1
            changed.append(order_id)
        db.commit()
    return changed


def claim_job(sessions, job_id=None, retired=None):
    exhausted = retire_exhausted(sessions)
    if retired is not None:
        retired.extend(exhausted)
    now = utcnow()
    eligible = or_(and_(AIReviewJob.status == "pending", AIReviewJob.next_attempt_at <= now),
        and_(AIReviewJob.status == "running", or_(AIReviewJob.lease_expires_at.is_(None), AIReviewJob.lease_expires_at <= now)))
    with sessions() as db:
        begin_sqlite_write(db)
        query = select(AIReviewJob.id, SubmissionAttempt.order_id).join(SubmissionAttempt, SubmissionAttempt.id == AIReviewJob.attempt_id).where(eligible, AIReviewJob.attempts < AIReviewJob.max_attempts).order_by(SubmissionAttempt.order_id, AIReviewJob.id)
        if job_id is not None:
            query = query.where(AIReviewJob.id == job_id)
        candidates = list(db.execute(query.limit(20)))
        for candidate, order_id in candidates:
            # Match finish/retry lock order before mutating the public job
            # snapshot and its parent optimistic version in one transaction.
            order = db.scalar(select(Order).where(Order.id == order_id).with_for_update())
            token = uuid4().hex
            changed = db.execute(update(AIReviewJob).where(AIReviewJob.id == candidate, eligible, AIReviewJob.attempts < AIReviewJob.max_attempts).values(
                status="running", attempts=AIReviewJob.attempts + 1, lease_token=token,
                lease_expires_at=now + timedelta(seconds=LEASE_SECONDS), finished_at=None).returning(AIReviewJob.attempt_id)).scalar_one_or_none()
            if changed is not None:
                order.version += 1
                attempt = db.get(SubmissionAttempt, changed)
                claim = {"job_id": candidate, "token": token, "attempt_id": changed, "order_id": attempt.order_id, "provider": db.get(AIReviewJob, candidate).provider,
                    "snapshot": review_snapshot(db, attempt)}
                db.commit()
                return claim
        db.commit()
    return None


def finish_job(sessions, claim, result=None, error_code=None):
    if error_code is None:
        try:
            result = validate_result(result, claim.get("provider", "stub"))
            if claim.get("provider") == "ai_service":
                from .ai_adapter import envelope
                if result["input_sha256"] != envelope(claim["snapshot"], result["bridge_version"])["input_sha256"]:
                    raise ValueError("invalid_result")
                if result["bridge_version"] == 2:
                    validate_photo_check(result["photo_check"], claim["snapshot"])
        except (ValidationError, ValueError, TypeError):
            error_code = "invalid_result"
    with sessions() as db:
        begin_sqlite_write(db)
        # All paths which mutate both order/job take the order lock first.
        order = db.scalar(select(Order).where(Order.id == claim["order_id"]).with_for_update())
        job = db.scalar(select(AIReviewJob).where(AIReviewJob.id == claim["job_id"]).with_for_update())
        if job is None or job.status != "running" or job.provider != claim.get("provider", "stub") or job.lease_token != claim["token"] or not job.lease_expires_at or aware(job.lease_expires_at) <= utcnow():
            return False
        attempt = db.get(SubmissionAttempt, job.attempt_id)
        if not applicable(db, order, attempt):
            job.status = "superseded"
            job.finished_at = utcnow()
            job.last_error_code = None
            job.lease_token = None
            job.lease_expires_at = None
            order.version += 1
        elif error_code:
            # Only fixed internal codes enter the database; never exception text.
            job.last_error_code = error_code if error_code in {"invalid_result", "provider_error"} else "provider_error"
            job.status = "failed" if job.attempts >= job.max_attempts else "pending"
            job.next_attempt_at = utcnow() + timedelta(seconds=min(2 ** job.attempts, 60))
            job.finished_at = utcnow() if job.status == "failed" else None
            job.lease_token = None
            job.lease_expires_at = None
            order.version += 1
        else:
            apply_success(db, order, attempt, job, result)
        db.commit()
        return True


def dispatch_ai_jobs(sessions, provider=None, limit=10, publish=None, providers=None):
    providers = providers if providers is not None else {"stub": FormalStub()}
    changed = []
    for _ in range(limit):
        claim = claim_job(sessions, retired=changed)
        if claim is None:
            break
        try:
            bound_provider = provider if provider is not None else providers.get(claim["provider"])
            if bound_provider is None:
                raise RuntimeError("provider_unavailable")
            result = validate_result(bound_provider.review(claim["snapshot"]), claim["provider"])
        except (ValidationError, ValueError, TypeError):
            result, error = None, "invalid_result"
        except Exception:
            result, error = None, "provider_error"
        else:
            error = None
        if finish_job(sessions, claim, result, error):
            changed.append(claim["order_id"])
    if publish:
        for order_id in changed:
            publish(order_id)
    return changed
