import base64
import hashlib
import json
import logging
import os
import re
from bisect import bisect_right
from collections import Counter, defaultdict
from datetime import timedelta
from statistics import median

import httpx
from pydantic import BaseModel, Field, ValidationError
from sqlalchemy import select

from .models import AIAssessment, AIReviewJob, Employee, Equipment, FaultCode, Material, Order, OrderEvent, Photo, utcnow
from .services import aware, notify

log = logging.getLogger(__name__)


class ReviewResult(BaseModel):
    verdict: str
    score: float | None = Field(ge=1, le=5)
    confidence: float = Field(ge=0, le=1)
    explanation: str = Field(min_length=1, max_length=3000)
    photo_summary: str = Field(max_length=1500)
    issues: list[str] = Field(max_length=10)
    service_verdict: str | None = None
    explanation_worker: str | None = None
    flags: dict | None = None
    remarks: list[dict] = Field(default_factory=list)
    needs_master_review: bool = False
    photo_review: dict | None = None
    checked_without_llm: bool = False


REVIEW_SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["passed", "needs_attention", "needs_rework"]},
        "score": {"type": "number", "minimum": 1, "maximum": 5},
        "confidence": {"type": "number", "minimum": 0, "maximum": 1},
        "explanation": {"type": "string"},
        "photo_summary": {"type": "string"},
        "issues": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["verdict", "score", "confidence", "explanation", "photo_summary", "issues"],
    "additionalProperties": False,
}

INSIGHTS_SCHEMA = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "insights": {"type": "array", "items": {"type": "object", "properties": {
            "title": {"type": "string"}, "description": {"type": "string"},
            "recommendation": {"type": "string"}, "fact_ids": {"type": "array", "items": {"type": "string"}},
        }, "required": ["title", "description", "recommendation", "fact_ids"], "additionalProperties": False}},
    },
    "required": ["summary", "insights"],
    "additionalProperties": False,
}

ANSWER_SCHEMA = {
    "type": "object",
    "properties": {
        "answer": {"type": "string"},
        "fact_ids": {"type": "array", "items": {"type": "string"}},
    },
    "required": ["answer", "fact_ids"],
    "additionalProperties": False,
}

HINT_SCHEMA = {
    "type": "object",
    "properties": {
        "fault_code_id": {"type": ["integer", "null"]},
        "time_norm_id": {"type": ["integer", "null"]},
        "explanation": {"type": "string"},
    },
    "required": ["fault_code_id", "time_norm_id", "explanation"],
    "additionalProperties": False,
}


class OpenAIProvider:
    def __init__(self, api_key=None, model=None, client=None):
        self.api_key = api_key or os.getenv("OPEN_AI_API_KEY") or os.getenv("OPENAI_API_KEY")
        if not self.api_key:
            raise ValueError("OPEN_AI_API_KEY или OPENAI_API_KEY не задан")
        self.model = model or os.getenv("AI_MODEL", "gpt-4.1-mini")
        self.client = client or httpx.Client(timeout=60)

    def _json_response(self, instructions, content, schema, name):
        response = self.client.post(
            "https://api.openai.com/v1/responses",
            headers={"Authorization": f"Bearer {self.api_key}"},
            json={
                "model": self.model,
                "instructions": instructions,
                "input": [{"role": "user", "content": content}],
                "text": {"format": {"type": "json_schema", "name": name, "strict": True, "schema": schema}},
                "store": False,
            },
        )
        response.raise_for_status()
        payload = response.json()
        if payload.get("status") != "completed":
            raise ValueError("Ответ модели не завершён")
        parts = [part.get("text", "") for item in payload.get("output", []) if item.get("type") == "message" for part in item.get("content", []) if part.get("type") == "output_text"]
        if not parts:
            raise ValueError("Модель не вернула структурированный ответ")
        return json.loads("".join(parts))

    def review(self, snapshot, images):
        content = [{"type": "input_text", "text": json.dumps(snapshot, ensure_ascii=False)}]
        for kind, data in images:
            content.append({"type": "input_text", "text": f"Фото {kind}. Видимые признаки оценивай осторожно; время съёмки по изображению не подтверждается."})
            content.append({"type": "input_image", "image_url": "data:image/jpeg;base64," + base64.b64encode(data).decode("ascii"), "detail": "low"})
        result = self._json_response(
            "Ты помощник мастера ремонтного участка. Сравни описание неисправности, выполненные работы, шифр, материалы, время и фотографии. Оценка score строго от 1 до 5, confidence от 0 до 1. Не утверждай невидимые дефекты устранёнными. Без норм расхода не объявляй количество завышенным как факт. При недостатке данных укажи needs_attention. Вердикт и балл только рекомендация; закрывает наряд мастер. Отвечай на русском.",
            content,
            REVIEW_SCHEMA,
            "order_review",
        )
        review = ReviewResult.model_validate(result)
        if review.verdict not in {"passed", "needs_attention", "needs_rework"}:
            raise ValueError("Неизвестный вердикт модели")
        if review.confidence < 0.6 and review.verdict == "passed":
            review.verdict = "needs_attention"
            review.issues.append("Низкая уверенность модели; требуется осмотр мастера")
        return review.model_dump()

    def explain(self, facts, question, schema, name):
        return self._json_response(
            "Ты аналитический помощник ремонтной службы. Отвечай по-русски только по переданным фактам. Не придумывай причинность, имена, события, нормативы или числа. Каждый вывод должен ссылаться на идентификаторы фактов. При недостатке данных честно скажи об этом. Ты не выполняешь действий с нарядами.",
            [{"type": "input_text", "text": json.dumps({"question": question, "facts": facts}, ensure_ascii=False)}],
            schema,
            name,
        )


def redact_personnel(text, people):
    clean = text or ""
    clean = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "[email]", clean)
    clean = re.sub(r"\+?\d[\d\s()\-]{9,}\d", "[телефон]", clean)
    for person in people:
        for value in (person.name, person.login):
            if value:
                clean = re.sub(re.escape(value), f"[сотрудник {person.id}]", clean, flags=re.IGNORECASE)
    return clean


def evidence_facts(db, orders):
    equipment = {item.id: item for item in db.scalars(select(Equipment))}
    fault_codes = {item.id: item for item in db.scalars(select(FaultCode))}
    materials = {item.id: item for item in db.scalars(select(Material))}
    unplanned = Counter(order.equipment_id for order in orders if order.work_type == "unplanned")
    failures = Counter((order.equipment_id, (order.completion or {}).get("fault_code_id")) for order in orders if order.work_type == "unplanned" and (order.completion or {}).get("fault_code_id"))
    consumption = defaultdict(float)
    material_quantities = defaultdict(list)
    equipment_orders = defaultdict(list)
    for order in orders:
        equipment_orders[order.equipment_id].append(order)
        for item in (order.completion or {}).get("materials", []):
            consumption[item["material_id"]] += item["quantity"]
            material_quantities[item["material_id"]].append(item["quantity"])
    facts = [{"id": "total", "text": f"В выборке {len(orders)} нарядов, из них {sum(order.status == 'closed' for order in orders)} закрыто и {sum(order.work_type == 'unplanned' for order in orders)} внеплановых."}]
    if equipment:
        facts.append({"id": "equipment_baseline", "text": f"Среднее число внеплановых нарядов на единицу оборудования в этой выборке: {sum(unplanned.values()) / len(equipment):.1f}. Сравнение не учитывает различия в режиме работы оборудования."})
    for equipment_id, count in unplanned.most_common(8):
        facts.append({"id": f"equipment:{equipment_id}", "text": f"{equipment[equipment_id].name}: {count} внеплановых нарядов в выборке."})
    for (equipment_id, fault_id), count in failures.most_common(8):
        facts.append({"id": f"fault:{equipment_id}:{fault_id}", "text": f"{equipment[equipment_id].name}, шифр {fault_codes[fault_id].code}: {count} внеплановых нарядов."})
    maintenance_counts = []
    for equipment_id, history in equipment_orders.items():
        chronological = sorted(history, key=lambda order: order.created_at)
        failure_times = [aware(order.created_at) for order in chronological if order.work_type == "unplanned"]
        post_maintenance = 0
        for order in chronological:
            if order.work_type != "planned":
                continue
            created_at = aware(order.created_at)
            next_failure = bisect_right(failure_times, created_at)
            if next_failure < len(failure_times) and failure_times[next_failure] - created_at <= timedelta(days=7):
                post_maintenance += 1
        if post_maintenance:
            maintenance_counts.append((equipment_id, post_maintenance))
    for equipment_id, count in sorted(maintenance_counts, key=lambda item: item[1], reverse=True)[:8]:
        facts.append({"id": f"maintenance:{equipment_id}", "text": f"{equipment[equipment_id].name}: после {count} плановых нарядов в течение 7 дней возник внеплановый; причинная связь не установлена."})
    for material_id, quantity in sorted(consumption.items(), key=lambda item: item[1], reverse=True)[:8]:
        material = materials[material_id]
        facts.append({"id": f"material:{material_id}", "text": f"{material.name}: {quantity:g} {material.unit} списано в выборке; нормы расхода неизвестны."})
    spikes = []
    for material_id, quantities in material_quantities.items():
        baseline = median(quantities)
        if len(quantities) >= 5 and baseline > 0 and max(quantities) >= baseline * 2:
            spikes.append((material_id, max(quantities), baseline, len(quantities)))
    for material_id, maximum, baseline, count in sorted(spikes, key=lambda item: item[1] / item[2], reverse=True)[:5]:
        material = materials[material_id]
        facts.append({"id": f"material_spike:{material_id}", "text": f"{material.name}: максимальное разовое списание {maximum:g} {material.unit}, медиана {baseline:g} {material.unit} по {count} нарядам; это сравнение с историей, не с нормативом."})
    return facts


def assistant_facts(db, orders):
    workers = list(db.scalars(select(Employee).where(Employee.role == "worker")))
    facts = []
    for worker in workers:
        assigned = [order for order in orders if order.assignee_id == worker.id and order.status not in {"closed", "cancelled", "rejected", "completed", "ai_review"}]
        current = next((order for order in assigned if order.status in {"in_progress", "paused"}), None)
        status = "вне смены" if not worker.on_shift else "занят" if current else "очередь" if assigned else "свободен"
        facts.append({"id": f"worker:{worker.id}", "text": f"Сотрудник #{worker.id}; специальность {worker.specialty}; статус {status}; активных назначений {len(assigned)}."})
    active_orders = [order for order in orders if order.status not in {"closed", "cancelled"}]
    for order in sorted(active_orders, key=lambda item: item.deadline)[:40]:
        facts.append({"id": f"order:{order.id}", "text": f"Наряд {order.number}; статус {order.status}; приоритет {order.priority}; срок {order.deadline.isoformat()}; исполнитель #{order.assignee_id}."})
    return facts


def supported_evidence(result, facts):
    known = {fact["id"] for fact in facts}
    referenced = result.get("fact_ids", [])
    if not isinstance(referenced, list) or any(item not in known for item in referenced):
        raise ValueError("Модель сослалась на неизвестные факты")
    return result


def process_one_review(sessions, provider):
    service_mode = getattr(provider, "mode", None) == "service"
    with sessions() as db:
        now = utcnow()
        query = select(AIReviewJob).where(
            (AIReviewJob.status == "pending") | ((AIReviewJob.status == "running") & (AIReviewJob.lease_until < now)),
            AIReviewJob.next_run_at <= now,
        ).order_by(AIReviewJob.id).limit(1)
        if db.bind.dialect.name == "postgresql":
            query = query.with_for_update(skip_locked=True)
        job = db.scalar(query)
        if not job:
            return False
        job.status = "running"
        job.attempts += 1
        claimed_attempt = job.attempts
        job.lease_until = now + timedelta(minutes=5 if service_mode else 3)
        job_id = job.id
        snapshot = job.snapshot
        photo_ids = job.photo_ids
        db.commit()

    try:
        with sessions() as db:
            order_status = db.scalar(select(Order.status).where(Order.id == job.order_id))
            latest_completion = db.scalar(select(OrderEvent.id).where(
                OrderEvent.order_id == job.order_id, OrderEvent.action == "complete"
            ).order_by(OrderEvent.id.desc()).limit(1))
            photos = list(db.scalars(select(Photo).where(Photo.id.in_(photo_ids)).order_by(Photo.id))) if photo_ids and not service_mode else []
        expected_status = "ai_review" if service_mode else "completed"
        if order_status != expected_status or latest_completion != job.completion_event_id:
            with sessions() as db:
                current = db.scalar(select(AIReviewJob).where(AIReviewJob.id == job_id).with_for_update())
                if current.status == "running" and current.attempts == claimed_attempt:
                    current.status = "stale"
                    db.commit()
            return True
        images = [(photo.kind, photo.data) for photo in photos]
        before_hashes = {hashlib.sha256(photo.data).digest() for photo in photos if photo.kind == "before"}
        after_hashes = {hashlib.sha256(photo.data).digest() for photo in photos if photo.kind == "after"}
        duplicate = bool(before_hashes & after_hashes)
        review = provider.review({**{key: value for key, value in snapshot.items() if key != "submitted_by"},
                                  "order_id": job.order_id, "source_version": f"event:{job.completion_event_id}"}, images)
        review = ReviewResult.model_validate(review).model_dump()
        if review["verdict"] not in {"passed", "needs_attention", "needs_rework"}:
            raise ValueError("Неизвестный вердикт модели")
        if duplicate:
            review["verdict"] = "needs_attention"
            review["issues"].append("Фото до и после совпадают побайтово")
        if review["confidence"] < 0.6 and review["verdict"] == "passed":
            review["verdict"] = "needs_attention"
        review.update(is_stub=review["checked_without_llm"] if service_mode else False,
                      master_score=None, model=provider.model)
    except (httpx.HTTPError, ValueError, ValidationError, KeyError, TypeError) as error:
        log.warning("AI review job %s failed: %s", job_id, type(error).__name__)
        with sessions() as db:
            job = db.scalar(select(AIReviewJob).where(AIReviewJob.id == job_id).with_for_update())
            if job and job.status == "running" and job.attempts == claimed_attempt:
                if job.attempts >= 3:
                    job.status = "failed"
                    order = db.get(Order, job.order_id)
                    latest_completion = db.scalar(select(OrderEvent.id).where(
                        OrderEvent.order_id == job.order_id, OrderEvent.action == "complete"
                    ).order_by(OrderEvent.id.desc()).limit(1))
                    if order and order.status == expected_status and order.ai_review is None and latest_completion == job.completion_event_id:
                        if expected_status == "completed":
                            order.ai_review = {"verdict": "needs_attention", "score": 1, "confidence": 0,
                                               "explanation": "Автоматическая проверка недоступна. Нужна ручная проверка мастера.",
                                               "photo_summary": "", "issues": ["ИИ недоступен"],
                                               "is_stub": True, "source": "unavailable", "master_score": None}
                            db.add(AIAssessment(order_id=order.id, verdict="needs_attention", score=1,
                                                explanation=order.ai_review["explanation"], is_stub=True))
                        else:
                            issues = ["ИИ-сервис недоступен; необходим осмотр мастера"]
                            actual_hours = snapshot.get("actual_hours")
                            normal_hours = snapshot.get("normal_hours")
                            time_status = ("unknown" if actual_hours is None or not normal_hours else
                                           "over_norm" if actual_hours > normal_hours else "within_norm")
                            deadline_status = ("unknown" if snapshot.get("deadline_met") is None else
                                               "on_time" if snapshot["deadline_met"] else "late")
                            has_after_photo = db.scalar(select(Photo.id).where(
                                Photo.order_id == order.id, Photo.kind == "after").limit(1)) is not None
                            flags = {"missing_work": not bool(snapshot.get("work_done", "").strip()),
                                     "missing_fault_code": not bool(snapshot.get("fault_code")),
                                     "missing_materials": False, "missing_after_photo": order.work_type == "unplanned" and not has_after_photo,
                                     "code_description_status": "unknown", "material_norm_status": "unknown",
                                     "excess_material_ids": [], "unusual_material_ids": [],
                                     "time_status": time_status, "deadline_status": deadline_status,
                                     "actual_hours": actual_hours, "normal_hours": normal_hours}
                            if time_status == "over_norm":
                                issues.append("Время работы превышает норматив")
                            if deadline_status == "late":
                                issues.append("Работа сдана после срока")
                            order.ai_review = {"verdict": "needs_attention", "service_verdict": "needs_master_review",
                                               "score": None, "confidence": 0, "explanation": "Проверено по доступным правилам без LLM. Финальная проверка — за мастером.",
                                               "explanation_worker": "Проверка ИИ недоступна; мастер оценит работу вручную.",
                                               "photo_summary": "Качество по фото неизвестно", "issues": issues,
                                               "flags": flags,
                                               "remarks": [], "needs_master_review": True, "checked_without_llm": True,
                                               "is_stub": True, "source": "rules_fallback", "master_score": None}
                        order.status = "ai_review"
                        job.result = order.ai_review
                        db.add(OrderEvent(order_id=order.id, action="ai_review", from_status=expected_status,
                                          to_status="ai_review", actor_id=job.snapshot["submitted_by"],
                                          comment="ИИ недоступен; требуется ручная проверка мастера"))
                        notify(db, [order.master_id], "Нужна ручная проверка", order.number, "review", order.id, f"ai-review:{job.id}")
                else:
                    job.status = "pending"
                    job.next_run_at = utcnow() + timedelta(seconds=10 * 3 ** (job.attempts - 1))
                db.commit()
        return True

    with sessions() as db:
        job = db.scalar(select(AIReviewJob).where(AIReviewJob.id == job_id).with_for_update())
        order = db.scalar(select(Order).where(Order.id == job.order_id).with_for_update())
        latest_completion = db.scalar(select(OrderEvent.id).where(
            OrderEvent.order_id == job.order_id, OrderEvent.action == "complete"
        ).order_by(OrderEvent.id.desc()).limit(1))
        if job.status == "running" and job.attempts == claimed_attempt and order and order.status == expected_status and order.ai_review is None and latest_completion == job.completion_event_id:
            order.ai_review = review
            order.status = "ai_review"
            db.add(OrderEvent(order_id=order.id, action="ai_review", from_status=expected_status, to_status="ai_review", actor_id=job.snapshot["submitted_by"], comment="Автоматическая проверка ИИ; итог утверждает мастер"))
            if review["score"] is not None:
                db.add(AIAssessment(order_id=order.id, verdict=review["verdict"], score=review["score"],
                                    explanation=review["explanation"], is_stub=review["is_stub"]))
            notify(db, [order.master_id], "ИИ завершил проверку", order.number, "review", order.id, f"ai-review:{job.id}")
            job.result = review
            job.status = "completed"
        elif job.status == "running" and job.attempts == claimed_attempt:
            job.status = "stale"
        db.commit()
    return True
