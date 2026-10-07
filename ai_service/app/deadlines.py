"""Deterministic deadline monitoring; no LLM participates in scheduling."""

from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from .config import Settings
from .datasource import DataSource
from .notifier import Notifier
from .schemas import OrderRecord, Snapshot
from .storage import AIStore


ACTIVE_STATUSES = {"issued", "accepted", "queued", "in_progress", "paused", "rework"}


def utc(value: datetime) -> datetime:
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def local_time(value: datetime) -> str:
    try:
        return utc(value).astimezone(ZoneInfo("Asia/Almaty")).strftime("%H:%M")
    except ZoneInfoNotFoundError:
        return utc(value).strftime("%H:%M UTC")


def assigned_at(order: OrderRecord):
    events = [event for event in order.events if event.to_status == "issued" and event.action in {"issue", "edit", "reassign"}]
    if events:
        last = max(events, key=lambda event: utc(event.created_at))
        return utc(last.created_at), str(last.id)
    return utc(order.created_at), "created"


def message_details(order: OrderRecord, snapshot: Snapshot):
    equipment = next((item.name for item in snapshot.equipment if item.id == order.equipment_id), f"#{order.equipment_id}")
    area = next((item.name for item in snapshot.areas if item.id == order.area_id), f"#{order.area_id}")
    worker = next((item.name for item in snapshot.employees if item.id == order.assignee_id), f"E-{order.assignee_id:02}")
    recent = max((event for event in order.events if event.to_status == order.status),
                 key=lambda event: utc(event.created_at), default=None)
    status_since = utc(recent.created_at) if recent else utc(order.started_at or order.created_at)
    comments = [event for event in order.events if event.comment and event.comment != "Синтетическое событие"]
    comment_event = max(comments, key=lambda event: utc(event.created_at), default=None)
    comment = comment_event.comment if comment_event else order.comment or "нет"
    return (f"{equipment}, участок {area}. Исполнитель: {worker}. "
            f"Статус: {order.status} с {local_time(status_since)}. Последний комментарий: {comment}")


def replacement(order: OrderRecord, snapshot: Snapshot):
    current = next((person for person in snapshot.employees if person.id == order.assignee_id), None)
    if current is None:
        return None
    busy = {item.assignee_id for item in snapshot.orders if item.status in ACTIVE_STATUSES}
    candidates = [person for person in snapshot.employees if person.role == "worker" and person.on_shift
                  and person.id not in busy and person.specialty == current.specialty]
    return min(candidates, key=lambda person: person.id, default=None)


class DeadlineController:
    def __init__(self, source: DataSource, store: AIStore, notifier: Notifier, settings: Settings):
        self.source = source
        self.store = store
        self.notifier = notifier
        self.settings = settings

    async def tick(self, now: datetime):
        now = utc(now)
        snapshot = await self.source.snapshot()
        emitted = []
        managers = [person for person in snapshot.employees if person.role == "manager"]
        for order in snapshot.orders:
            if order.status not in ACTIVE_STATUSES:
                continue
            assignment_time, assignment_version = assigned_at(order)
            details = message_details(order, snapshot)
            prefix = f"deadline:{order.id}:{assignment_version}:{utc(order.deadline).isoformat()}"
            planned = []
            acceptance_minutes = (self.settings.emergency_accept_minutes if order.priority == "emergency"
                                  else self.settings.accept_minutes)
            if order.status == "issued" and now >= assignment_time + timedelta(minutes=acceptance_minutes):
                candidate = replacement(order, snapshot)
                proposal = f" Предлагаем замену: {candidate.name}." if candidate else " Свободная замена не найдена."
                planned.append(("acceptance_escalation", f"M-{order.master_id:02}", "Наряд не принят",
                                f"Наряд №{order.number} не принят за {acceptance_minutes} мин. {details}{proposal}",
                                "accept"))
            deadline = utc(order.deadline)
            if deadline - timedelta(minutes=self.settings.due_soon_minutes) <= now < deadline:
                minutes_left = max(0, int((deadline - now).total_seconds() // 60))
                planned.append(("deadline_warning", f"E-{order.assignee_id:02}", "Срок наряда",
                                f"До срока наряда №{order.number} осталось {minutes_left} мин. {details}", "warning"))
            if now >= deadline:
                overdue_minutes = int((now - deadline).total_seconds() // 60)
                bucket = overdue_minutes // self.settings.reminder_repeat_minutes
                kind = "overdue" if bucket == 0 else "overdue_repeat"
                message = f"Наряд №{order.number} просрочен на {overdue_minutes} мин. {details}"
                for recipient in [f"E-{order.assignee_id:02}", f"M-{order.master_id:02}"]:
                    planned.append((kind, recipient, "Просрочен наряд", message, f"overdue:{bucket}"))
                if overdue_minutes >= self.settings.manager_escalation_minutes:
                    for manager in managers:
                        planned.append(("long_overdue", f"G-{manager.id:02}", "Длительная просрочка",
                                        message, "manager"))
            for kind, recipient, title, message, event_key in planned:
                key = f"{prefix}:{event_key}:{recipient}"
                payload = {"type": kind, "order_id": order.id, "recipient": recipient,
                           "title": title, "message": message, "at": now.isoformat()}
                if not self.store.enqueue_notification(key, recipient, payload):
                    continue
                delivered = await self.notifier.send(recipient, title, message, key)
                self.store.mark_notification(key, "telegram" if delivered else "log", delivered)
                emitted.append({**payload, "delivered": delivered, "idempotency_key": key})
        return emitted
