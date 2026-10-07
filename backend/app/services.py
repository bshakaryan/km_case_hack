import logging
import os
from collections import defaultdict
from copy import deepcopy
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from sqlalchemy import select
from .models import Area, Brigade, Employee, Equipment, IntegrationLog, Material, MaterialWriteoff, Notification, Order, OrderAssignment, OrderEvent, Photo, SubmissionAttempt, SubmissionDecision, SubmissionPhoto, SubmissionWriteoff, utcnow
from .push import enqueue_push

LOG = logging.getLogger(__name__)
TERMINAL = {"closed", "cancelled"}
EXECUTION_FINISHED = TERMINAL | {"completed", "ai_review"}
QUEUE_PRIORITIES = {"emergency": 0, "high": 1, "normal": 2, "planned": 3}


def aware(value):
    return value.replace(tzinfo=timezone.utc) if value and value.tzinfo is None else value


def iso(value):
    return aware(value).isoformat() if value else None


def employee_dict(person):
    return {key: getattr(person, key) for key in ["id", "name", "login", "role", "specialty", "grade", "brigade_id", "on_shift"]}


def downtime_minutes(order, now=None):
    if order.work_type == "unplanned" and order.status not in EXECUTION_FINISHED:
        elapsed = ((now or utcnow()) - aware(order.created_at)).total_seconds() / 60
        return round(max(order.downtime_minutes or 0, elapsed), 1)
    return order.downtime_minutes


def waiting_orders(db, assignee_id=None):
    query = select(Order).where(Order.status.in_(["accepted", "queued"]))
    if assignee_id is not None:
        query = query.where(Order.assignee_id == assignee_id)
    orders = list(db.scalars(query))
    return sorted(
        orders,
        key=lambda item: (
            QUEUE_PRIORITIES.get(item.priority, len(QUEUE_PRIORITIES)),
            aware(item.assigned_at),
            item.id,
        ),
    )


def queue_positions(db):
    grouped = defaultdict(list)
    for order in waiting_orders(db):
        grouped[order.assignee_id].append(order)
    return {
        order.id: position
        for assigned in grouped.values()
        for position, order in enumerate(assigned, start=1)
    }


def effective_queue_statuses(db):
    grouped = defaultdict(list)
    for order in waiting_orders(db):
        grouped[order.assignee_id].append(order)
    busy_assignees = set(
        db.scalars(
            select(Order.assignee_id).where(
                Order.status.in_(["in_progress", "paused"])
            )
        )
    )
    overrides = {}
    for assignee_id, orders in grouped.items():
        keep_accepted = (
            orders[0].id
            if assignee_id not in busy_assignees
            and orders
            and orders[0].status == "accepted"
            else None
        )
        for order in orders:
            if order.status == "accepted" and order.id != keep_accepted:
                overrides[order.id] = "queued"
    return overrides


def order_dict(db, order, detail=False, refs=None, positions=None, statuses=None):
    refs = refs or {}
    area = refs.get("areas", {}).get(order.area_id) or db.get(Area, order.area_id)
    equipment = refs.get("equipment", {}).get(order.equipment_id) or db.get(Equipment, order.equipment_id)
    employee = refs.get("employees", {}).get(order.assignee_id) or db.get(Employee, order.assignee_id)
    result = {key: getattr(order, key) for key in ["id", "number", "title", "description", "work_type", "area_id", "equipment_id", "assignee_id", "brigade_id", "master_id", "priority", "status", "comment", "normal_hours", "downtime_minutes", "score"]}
    if order.status == "accepted":
        statuses = statuses if statuses is not None else effective_queue_statuses(db)
        if order.id in statuses:
            result["status"] = "queued"
    result.update({key: iso(getattr(order, key)) for key in ["deadline", "created_at", "assigned_at", "started_at", "completed_at", "closed_at"]})
    result["downtime_minutes"] = downtime_minutes(order)
    if order.status in {"accepted", "queued"}:
        positions = positions if positions is not None else queue_positions(db)
        result["queue_position"] = positions.get(order.id)
    else:
        result["queue_position"] = None
    result.update(area_name=area.name, equipment_name=equipment.name, assignee_name=employee.name, is_overdue=order.status not in EXECUTION_FINISHED and aware(order.deadline) < utcnow())
    if detail:
        result["events"] = [{"id": event.id, "action": event.action, "from_status": event.from_status, "to_status": event.to_status, "actor_name": db.get(Employee, event.actor_id).name, "created_at": iso(event.created_at), "comment": event.comment} for event in db.scalars(select(OrderEvent).where(OrderEvent.order_id == order.id).order_by(OrderEvent.created_at, OrderEvent.id))]
        result["photos"] = [photo_dict(db, p) for p in db.scalars(select(Photo).where(Photo.order_id == order.id).order_by(Photo.id))]
        result["completion"] = order.completion
        result["ai_review"] = order.ai_review
        result["assignment_history"], result["submission_attempts"] = order_history(db, order.id)
    return result


def end_current_assignment(db, order, ended_at):
    latest = db.scalar(select(OrderAssignment).where(OrderAssignment.order_id == order.id).order_by(OrderAssignment.sequence.desc()).limit(1))
    if latest is not None and latest.ended_at is None:
        latest.ended_at = ended_at


def append_assignment(db, order, actor_id):
    """Caller holds the order lock, or has just inserted the new order."""
    latest = db.scalar(select(OrderAssignment).where(OrderAssignment.order_id == order.id).order_by(OrderAssignment.sequence.desc()).limit(1))
    if latest is not None and latest.ended_at is None:
        latest.ended_at = order.assigned_at
    assignment = OrderAssignment(order_id=order.id, sequence=latest.sequence + 1 if latest else 1,
        assignee_id=order.assignee_id, brigade_id=order.brigade_id, assigned_at=order.assigned_at,
        assigned_by_id=actor_id, source="live")
    db.add(assignment)
    db.flush()
    return assignment


def append_submission(db, order, author_id, payload, writeoffs, assessment):
    """Freeze this report before aggregate materials or master scores change."""
    latest = db.scalar(select(SubmissionAttempt).where(SubmissionAttempt.order_id == order.id).order_by(SubmissionAttempt.sequence.desc()).limit(1))
    assignment = db.scalar(select(OrderAssignment).where(OrderAssignment.order_id == order.id).order_by(OrderAssignment.sequence.desc()).limit(1))
    attempt = SubmissionAttempt(order_id=order.id, sequence=latest.sequence + 1 if latest else 1,
        assignment_id=assignment.id, submitted_at=order.completed_at, author_id=author_id,
        payload=deepcopy(payload), ai_review=deepcopy(order.ai_review), assessment_id=assessment.id, source="live")
    db.add(attempt)
    db.flush()
    db.add_all([SubmissionPhoto(attempt_id=attempt.id, photo_id=id_) for id_ in db.scalars(select(Photo.id).where(Photo.order_id == order.id).order_by(Photo.id))])
    db.add_all([SubmissionWriteoff(attempt_id=attempt.id, writeoff_id=row.id) for row in writeoffs])
    return attempt


def append_submission_decision(db, order, actor_id, action, score, comment):
    latest = db.scalar(select(SubmissionAttempt).where(SubmissionAttempt.order_id == order.id).order_by(SubmissionAttempt.sequence.desc()).limit(1))
    if latest is not None:
        db.add(SubmissionDecision(attempt_id=latest.id, actor_id=actor_id, action=action, score=score,
            comment=comment, created_at=order.closed_at if action == "close" else utcnow()))


def order_history(db, order_id):
    def name(model, id_):
        row = db.get(model, id_) if id_ is not None else None
        return row.name if row else None

    assignments = [{"id": row.id, "number": row.sequence, "source": row.source,
        "assignee_id": row.assignee_id, "assignee_name": name(Employee, row.assignee_id),
        "brigade_id": row.brigade_id, "brigade_name": name(Brigade, row.brigade_id),
        "assigned_by_id": row.assigned_by_id, "assigned_by_name": name(Employee, row.assigned_by_id),
        "assigned_at": iso(row.assigned_at), "ended_at": iso(row.ended_at)}
        for row in db.scalars(select(OrderAssignment).where(OrderAssignment.order_id == order_id).order_by(OrderAssignment.sequence))]
    attempts = []
    for row in db.scalars(select(SubmissionAttempt).where(SubmissionAttempt.order_id == order_id).order_by(SubmissionAttempt.sequence)):
        material_snapshots = {m["material_id"]: m for m in (row.payload or {}).get("materials", [])}
        materials = []
        for writeoff in db.scalars(select(MaterialWriteoff).join(SubmissionWriteoff, SubmissionWriteoff.writeoff_id == MaterialWriteoff.id).where(SubmissionWriteoff.attempt_id == row.id).order_by(MaterialWriteoff.id)):
            material = material_snapshots.get(writeoff.material_id, {})
            current = db.get(Material, writeoff.material_id)
            materials.append({"id": writeoff.id, "material_id": writeoff.material_id,
                "name": material.get("name", current.name), "unit": material.get("unit", current.unit),
                "quantity": writeoff.quantity, "author_id": writeoff.author_id,
                "author_name": name(Employee, writeoff.author_id), "created_at": iso(writeoff.created_at)})
        decisions = [{"id": decision.id, "actor_id": decision.actor_id, "actor_name": name(Employee, decision.actor_id),
            "action": decision.action, "score": decision.score, "comment": decision.comment, "created_at": iso(decision.created_at)}
            for decision in db.scalars(select(SubmissionDecision).where(SubmissionDecision.attempt_id == row.id).order_by(SubmissionDecision.created_at, SubmissionDecision.id))]
        attempts.append({"id": row.id, "number": row.sequence, "source": row.source,
            "assignment_id": row.assignment_id, "submitted_at": iso(row.submitted_at),
            "author_id": row.author_id, "author_name": name(Employee, row.author_id),
            "assessment_id": row.assessment_id, "completion": row.payload, "ai_review": row.ai_review,
            "photos": [photo_dict(db, photo) for photo in db.scalars(select(Photo).join(SubmissionPhoto, SubmissionPhoto.photo_id == Photo.id).where(SubmissionPhoto.attempt_id == row.id).order_by(Photo.id))],
            "materials": materials, "decisions": decisions})
    return assignments, attempts


def photo_dict(db, photo):
    return {"id": photo.id, "kind": photo.kind, "url": f"/api/photos/{photo.id}", "created_at": iso(photo.created_at), "author_name": db.get(Employee, photo.author_id).name}


def audit(db, order, action, actor_id, old_status=None, comment=""):
    db.add(OrderEvent(order_id=order.id, action=action, from_status=old_status, to_status=order.status, actor_id=actor_id, comment=comment))


def notify(db, employee_ids, title, message, kind, order_id, dedupe_prefix=None):
    added = 0
    for employee_id in set(employee_ids):
        key = f"{dedupe_prefix}:{employee_id}" if dedupe_prefix else None
        if key and db.scalar(select(Notification.id).where(Notification.dedupe_key == key)):
            continue
        notification = Notification(employee_id=employee_id, title=title, message=message, kind=kind, order_id=order_id, dedupe_key=key)
        db.add(notification)
        db.flush()
        enqueue_push(db, notification)
        added += 1
    return added


def monitor_deadlines(db, now=None):
    now = aware(now or utcnow())
    added = 0
    due_soon_minutes = int(os.getenv("DUE_SOON_MINUTES", "30"))
    for order in db.scalars(select(Order).where(Order.status.notin_(EXECUTION_FINISHED))):
        minutes = (aware(order.deadline) - now).total_seconds() / 60
        key = f"{order.id}:{iso(order.deadline)}"
        equipment = db.get(Equipment, order.equipment_id)
        area = db.get(Area, order.area_id)
        worker = db.get(Employee, order.assignee_id)
        latest = db.scalar(select(OrderEvent).where(OrderEvent.order_id == order.id, OrderEvent.comment != "").order_by(OrderEvent.created_at.desc(), OrderEvent.id.desc()).limit(1))
        detail = f"{order.number}: {order.title}. {equipment.name}; {area.name}; исполнитель: {worker.name}. Срок: {aware(order.deadline).astimezone(ZoneInfo('Asia/Almaty')).strftime('%d.%m %H:%M')}. Просрочка: {max(0, round(-minutes))} мин. Комментарий: {latest.comment if latest else order.comment or 'нет'}."
        if minutes < 0:
            added += notify(db, [order.assignee_id, order.master_id], "Срок наряда истёк", detail, "overdue", order.id, f"overdue:{key}")
        elif minutes <= due_soon_minutes:
            added += notify(db, [order.assignee_id, order.master_id], f"До срока менее {due_soon_minutes} минут", detail, "due_soon", order.id, f"due_soon:{key}")
        acceptance_minutes = int(os.getenv("EMERGENCY_ACCEPT_MINUTES", "3")) if order.priority == "emergency" else int(os.getenv("ACCEPT_MINUTES", "10"))
        if order.status == "issued" and (now - aware(order.assigned_at)).total_seconds() >= acceptance_minutes * 60:
            added += notify(db, [order.assignee_id, order.master_id], f"Наряд не принят {acceptance_minutes} минут", detail, "unaccepted", order.id, f"unaccepted:{order.id}:{order.assignee_id}:{iso(order.assigned_at)}")
    db.commit()
    return added


class AIReviewStub:
    @staticmethod
    def review(db, order):
        photos = list(db.scalars(select(Photo).where(Photo.order_id == order.id)))
        has_pair = {p.kind for p in photos} == {"before", "after"}
        score = 4.5 if has_pair else 4.0
        result = {"verdict": "passed" if has_pair else "needs_attention", "score": score, "explanation": "Заглушка ИИ: проверена только полнота отчёта и наличие фотографий. Содержимое изображений не анализируется. Решение о приёмке принимает мастер.", "is_stub": True, "master_score": None}
        db.add(IntegrationLog(adapter="ai_stub", operation="review", payload={"order_id": order.id, "is_stub": True, "photo_count": len(photos)}))
        return result


def shift_start(now=None):
    local = (now or utcnow()).astimezone(ZoneInfo("Asia/Almaty"))
    hour = 8 if 8 <= local.hour < 20 else 20
    start = local.replace(hour=hour, minute=0, second=0, microsecond=0)
    if local.hour < 8:
        start -= timedelta(days=1)
    return start.astimezone(timezone.utc), "Дневная смена · 08:00–20:00" if hour == 8 else "Ночная смена · 20:00–08:00"


def analytics(db, orders, start, end):
    closed = [o for o in orders if o.status == "closed"]
    ontime = [o for o in closed if o.completed_at and aware(o.completed_at) <= aware(o.deadline)]
    scored = [o.score for o in closed if o.score is not None]
    areas = {a.id: a.name for a in db.scalars(select(Area))}
    equipment = {e.id: e for e in db.scalars(select(Equipment))}
    brigades = {b.id: b.name for b in db.scalars(select(Brigade))}
    employees = list(db.scalars(select(Employee).where(Employee.role == "worker")))
    reworked_ids = set(db.scalars(select(OrderEvent.order_id).where(OrderEvent.action == "rework")))
    trend = {}
    day = start.astimezone(ZoneInfo("Asia/Almaty")).date()
    end_day = end.astimezone(ZoneInfo("Asia/Almaty")).date()
    while day <= end_day:
        trend[day.isoformat()] = {"date": day.isoformat(), "planned": 0, "unplanned": 0}
        day += timedelta(days=1)
    area_counts = defaultdict(lambda: {"count": 0, "minutes": 0})
    equipment_counts = defaultdict(lambda: {"count": 0, "minutes": 0})
    material_counts = {}
    for order in orders:
        day = aware(order.created_at).astimezone(ZoneInfo("Asia/Almaty")).date().isoformat()
        if day in trend:
            trend[day][order.work_type] += 1
        area_counts[order.area_id]["count"] += 1
        area_counts[order.area_id]["minutes"] += downtime_minutes(order)
        equipment_counts[order.equipment_id]["count"] += 1
        equipment_counts[order.equipment_id]["minutes"] += downtime_minutes(order)
        for material in (order.completion or {}).get("materials", []):
            key = material["material_id"]
            row = material_counts.setdefault(key, {"name": material["name"], "unit": material["unit"], "quantity": 0})
            row["quantity"] += material["quantity"]
    rankings = []
    for employee in employees:
        person_orders = [o for o in closed if o.assignee_id == employee.id]
        if not person_orders:
            continue
        n = len(person_orders)
        quality = sum(o.score or 0 for o in person_orders) / n
        on_time = 100 * sum(bool(o.completed_at and aware(o.completed_at) <= aware(o.deadline)) for o in person_orders) / n
        rework_rate = 100 * sum(o.id in reworked_ids for o in person_orders) / n
        # 60% manual quality (1..5), 30% punctuality, 10% absence of rework.
        score = quality / 5 * 60 + on_time * .3 + (100 - rework_rate) * .1
        rankings.append({"id": employee.id, "name": employee.name, "specialty": employee.specialty, "brigade": brigades.get(employee.brigade_id, "—"), "score": round(score, 1), "quality": round(quality, 2), "on_time": round(on_time, 1), "closed_count": n, "rework_rate": round(rework_rate, 1)})
    rankings.sort(key=lambda p: p["score"], reverse=True)
    equipment_rows = [{"id": id_, "name": equipment[id_].name, "area_name": areas[equipment[id_].area_id], "orders": v["count"], "downtime_hours": round(v["minutes"] / 60, 1)} for id_, v in equipment_counts.items()]
    equipment_rows.sort(key=lambda r: r["downtime_hours"], reverse=True)
    insights = []
    if equipment_rows:
        top = equipment_rows[0]
        insights.append({"title": "Оборудование с максимальным простоем", "description": f"{top['name']}: {top['downtime_hours']} ч простоя, {top['orders']} нарядов. Детерминированная сводка заглушки; требует проверки инженером.", "severity": "high", "is_stub": True})
    repeated = [o for o in orders if o.equipment_id == 1 and o.work_type == "unplanned"]
    if repeated:
        insights.append({"title": "Повторные неисправности конвейера", "description": f"За выбранный период зарегистрировано {len(repeated)} внеплановых работ на КЛ-01. Заглушка предлагает проверить ролики и центровку.", "severity": "warning", "is_stub": True})
    post_maintenance = [o for o in orders if o.work_type == "unplanned" and "после обслуживания" in o.title.lower()]
    if post_maintenance:
        insights.append({"title": "Повторные обращения после обслуживания", "description": f"В описаниях {len(post_maintenance)} внеплановых нарядов отмечена неисправность после обслуживания. Заглушка использует ключевые слова; причинную связь должен проверить инженер.", "severity": "warning", "is_stub": True})
    if material_counts:
        top_material = max(material_counts.values(), key=lambda v: v["quantity"])
        insights.append({"title": "Контроль расхода материалов", "description": f"Наибольший численный расход: {top_material['name']} — {top_material['quantity']:g} {top_material['unit']}. Сравнение разных единиц условно; это демонстрационное правило, не ИИ-вывод.", "severity": "info", "is_stub": True})
    return {"summary": {"total": len(orders), "closed": len(closed), "on_time_percent": round(100 * len(ontime) / len(closed), 1) if closed else 0, "avg_score": round(sum(scored) / len(scored), 2) if scored else 0, "downtime_hours": round(sum(downtime_minutes(o) for o in orders) / 60, 1)}, "trend": list(trend.values()), "by_area": [{"name": areas[id_], "count": values["count"], "downtime_hours": round(values["minutes"] / 60, 1)} for id_, values in area_counts.items()], "rankings": rankings, "equipment": equipment_rows, "materials": sorted(material_counts.values(), key=lambda v: v["quantity"], reverse=True), "insights": insights, "ai_summary": f"Демонстрационная аналитика: {len(orders)} нарядов, {len(closed)} закрыто. Показатели рассчитаны сервером; рекомендации формируются правилами заглушки ИИ и требуют проверки специалистом.", "is_stub": True}
