"""Durable, fenced review jobs. The only configured provider is a local stub."""
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


class ReviewResult(BaseModel):
    model_config = ConfigDict(extra="ignore", strict=False, str_strip_whitespace=True)
    verdict: Literal["passed", "needs_attention", "needs_rework"]
    score: float = Field(ge=1, le=5, allow_inf_nan=False)
    explanation: str = Field(min_length=1, max_length=2000)
    is_stub: bool
    master_score: None = None


class FormalStub:
    def review(self, snapshot):
        paired = {photo["kind"] for photo in snapshot["photos"]} == {"before", "after"}
        return {"verdict": "passed" if paired else "needs_attention", "score": 4.5 if paired else 4.0,
            "explanation": "Заглушка ИИ: проверена только полнота отчёта и наличие фотографий. Содержимое изображений не анализируется. Решение о приёмке принимает мастер.", "is_stub": True, "master_score": None}


class OpenAIProvider:
    def review(self, snapshot):
        import os
        import httpx
        import json
        import base64
        
        api_key = os.getenv("OPENAI_API_KEY")
        if not api_key:
            return FormalStub().review(snapshot)

        report = snapshot.get("report", {})
        work_done = report.get("work_done", "")
        comment = report.get("comment", "")
        materials = report.get("materials", [])
        
        order = snapshot.get("order", {})
        title = order.get("title", "")
        desc = order.get("description", "")
        
        mat_text = ", ".join([f"{m.get('name', '???')} ({m.get('quantity', 0)} {m.get('unit', '')})" for m in materials])
        
        prompt = (
            "ИИ-проверка закрытого наряда.\n\n"
            f"ОПИСАНИЕ ПРОБЛЕМЫ ПРИ ВЫДАЧЕ:\nНазвание: {title}\nДетали: {desc}\n\n"
            f"ОТЧЁТ ИСПОЛНИТЕЛЯ:\nВыполненные работы: {work_done}\nКомментарий: {comment}\nМатериалы: {mat_text}\n"
            f"Сроки: назначен {order.get('assigned_at')}, дедлайн {order.get('deadline')}, сдан {order.get('submitted_at')}.\n\n"
            "ЗАДАЧА: Проверьте отчёт и фото.\n"
            "1. Полнота: указаны ли работы, материалы. Есть ли фото 'after' (после).\n"
            "2. Соответствие: решают ли выполненные работы изначальную проблему?\n"
            "3. Логичность материалов: нет ли завышения расхода для таких работ?\n"
            "4. Время: уложился ли исполнитель в срок?\n"
            "5. Качество по фото: если есть 'before' и 'after', устранена ли видимая проблема? Нет ли оставленного мусора, незакреплённых деталей, отсутствующих кожухов?\n"
            "6. Метаданные: проверьте время создания фото, если они переданы.\n\n"
            "Если есть сомнения, признаки брака, завышения материалов или мусор на фото — ставьте 'needs_attention' (проверит мастер).\n"
            "Верните строго JSON:\n"
            '{"verdict": "passed", "needs_attention" или "needs_rework", '
            '"score": оценка качества от 1 до 5, '
            '"explanation": "Структурированный отчёт (используйте переносы строк \\n и маркеры списка -, чтобы было удобно читать. НЕ ИСПОЛЬЗУЙТЕ звездочки ** для выделения текста) по всем 6 пунктам (строка до 2000 символов)", '
            '"is_stub": false, "master_score": null}'
        )

        user_content = [{"type": "text", "text": prompt}]
        for photo in snapshot.get("photos", []):
            kind = photo.get("kind", "unknown")
            meta = photo.get("meta", {})
            b64_data = base64.b64encode(photo["data"]).decode("utf-8")
            user_content.append({
                "type": "image_url",
                "image_url": {
                    "url": f"data:image/jpeg;base64,{b64_data}",
                    "detail": "low"
                }
            })
            user_content[0]["text"] += f"\n[Приложено фото: {kind}, EXIF: {meta}]"

        try:
            resp = httpx.post(
                "https://api.openai.com/v1/chat/completions",
                headers={"Authorization": f"Bearer {api_key}"},
                json={
                    "model": "gpt-4o-mini",
                    "messages": [
                        {"role": "system", "content": "You are a helpful assistant that reviews work orders and outputs only valid JSON."},
                        {"role": "user", "content": user_content}
                    ],
                    "response_format": {"type": "json_object"}
                },
                timeout=20.0
            )
            resp.raise_for_status()
            data = resp.json()
            content = data["choices"][0]["message"]["content"]
            result = json.loads(content)
            result["is_stub"] = False
            result["master_score"] = None
            return result
        except Exception as e:
            return FormalStub().review(snapshot)


def job_dict(job, retry_allowed=False):
    if job is None:
        return None
    return {"id": job.id, "attempt_id": job.attempt_id, "status": job.status, "provider": job.provider,
        "attempts": job.attempts, "max_attempts": job.max_attempts, "next_attempt_at": iso(job.next_attempt_at),
        "lease_expires_at": iso(job.lease_expires_at), "last_error_code": job.last_error_code,
        "created_at": iso(job.created_at), "finished_at": iso(job.finished_at), "retry_allowed": retry_allowed}


def enqueue_job(db, attempt):
    import os
    provider_name = "openai" if os.getenv("OPENAI_API_KEY") else "stub"
    job = AIReviewJob(attempt_id=attempt.id, status="pending", provider=provider_name, attempts=0,
        max_attempts=3, next_attempt_at=utcnow(), created_at=utcnow())
    db.add(job)
    db.flush()
    return job


def review_snapshot(db, attempt):
    import io
    try:
        from PIL import Image
        from PIL.ExifTags import TAGS
    except ImportError:
        Image, TAGS = None, None

    order = db.get(Order, attempt.order_id)
    photos_data = []
    
    for photo in db.scalars(select(Photo).join(SubmissionPhoto, SubmissionPhoto.photo_id == Photo.id).where(SubmissionPhoto.attempt_id == attempt.id).order_by(Photo.id)):
        meta = {}
        if Image:
            try:
                img = Image.open(io.BytesIO(photo.data))
                exif = img.getexif()
                if exif:
                    for tag_id in exif:
                        tag = TAGS.get(tag_id, tag_id)
                        if tag == "DateTime":
                            meta["datetime"] = str(exif.get(tag_id))
            except Exception:
                pass
                
        photos_data.append({
            "id": photo.id, 
            "kind": photo.kind, 
            "data": bytes(photo.data),
            "meta": meta
        })

    return {
        "attempt_id": attempt.id, 
        "order": {
            "title": order.title,
            "description": order.description,
            "priority": order.priority,
            "assigned_at": iso(order.assigned_at),
            "deadline": iso(order.deadline),
            "submitted_at": iso(attempt.submitted_at)
        },
        "report": deepcopy(attempt.payload),
        "photos": photos_data
    }


def validate_result(result):
    if not isinstance(result, dict) or type(result.get("is_stub")) is not bool:
        raise ValueError("invalid_result")
    try:
        return ReviewResult.model_validate(result).model_dump()
    except Exception as e:
        import logging
        logging.getLogger(__name__).exception(f"AI result validation failed: {result}")
        raise ValueError("invalid_result")


def apply_success(db, order, attempt, job, result):
    from .services import audit, notify, participant_ids
    assessment = AIAssessment(order_id=order.id, **result)
    db.add(assessment)
    db.flush()
    attempt.ai_review = deepcopy(result)
    attempt.assessment_id = assessment.id
    order.ai_review = deepcopy(result)
    order.status = "ai_review"
    order.version += 1
    audit(db, order, "ai_review", attempt.author_id, "completed", "Автоматическая проверка заглушкой ИИ. Ожидается решение мастера.")
    notify(db, [order.master_id], "Наряд ожидает приёмки", order.number, "review", order.id)
    notify(db, participant_ids(db, order), "Статус наряда изменён", f"{order.number}: completed → ai_review", "status", order.id)
    db.add(IntegrationLog(adapter="ai_stub", operation="review", payload={"order_id": order.id, "attempt_id": attempt.id, "is_stub": True}))
    job.status = "succeeded"
    job.finished_at = utcnow()
    job.last_error_code = None
    job.lease_token = None
    job.lease_expires_at = None


def run_inline(db, order, attempt, job):
    """Explicit compatibility mode: formal stub inside the original command."""
    import os
    provider = OpenAIProvider() if os.getenv("OPENAI_API_KEY") else FormalStub()
    job.attempts = 1
    apply_success(db, order, attempt, job, validate_result(provider.review(review_snapshot(db, attempt))))


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
                claim = {"job_id": candidate, "token": token, "attempt_id": changed, "order_id": attempt.order_id,
                    "snapshot": review_snapshot(db, attempt)}
                db.commit()
                return claim
        db.commit()
    return None


def finish_job(sessions, claim, result=None, error_code=None):
    if error_code is None:
        try:
            result = validate_result(result)
        except (ValidationError, ValueError, TypeError):
            error_code = "invalid_result"
    with sessions() as db:
        begin_sqlite_write(db)
        # All paths which mutate both order/job take the order lock first.
        order = db.scalar(select(Order).where(Order.id == claim["order_id"]).with_for_update())
        job = db.scalar(select(AIReviewJob).where(AIReviewJob.id == claim["job_id"]).with_for_update())
        if job is None or job.status != "running" or job.lease_token != claim["token"] or not job.lease_expires_at or aware(job.lease_expires_at) <= utcnow():
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


def dispatch_ai_jobs(sessions, provider=None, limit=10, publish=None):
    import os
    if provider is None:
        provider = OpenAIProvider() if os.getenv("OPENAI_API_KEY") else FormalStub()
    changed = []
    for _ in range(limit):
        claim = claim_job(sessions, retired=changed)
        if claim is None:
            break
        try:
            result = validate_result(provider.review(claim["snapshot"]))
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
