"""Read-only master assistant; all quantities come from the current snapshot."""

import asyncio
from collections import Counter
from datetime import datetime, timedelta

from pydantic import BaseModel, ConfigDict

from .datasource import DataSource
from .deadlines import ACTIVE_STATUSES, utc
from .llm_client import LLMClient
from .schemas import Snapshot


class ToolChoice(BaseModel):
    model_config = ConfigDict(extra="forbid")

    tool: str
    area_id: int | None
    specialty: str | None


TOOL_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {"tool": {"type": "string", "enum": ["available_workers", "overdue_orders",
                                                     "area_report", "area_problems", "unknown"]},
                   "area_id": {"type": ["integer", "null"]},
                   "specialty": {"type": ["string", "null"]}},
    "required": ["tool", "area_id", "specialty"],
}


def mentioned_area(question: str, snapshot: Snapshot):
    lower = question.casefold()
    area = next((item for item in snapshot.areas if item.name.casefold() in lower), None)
    if area is None:
        aliases = {"дроблен": "дробильн", "обогащен": "обогатительн",
                   "транспортн": "транспортн", "энергетическ": "энергетическ"}
        matching = [item for item in snapshot.areas if any(
            alias in lower and canonical in item.name.casefold() for alias, canonical in aliases.items())]
        area = matching[0] if len(matching) == 1 else None
    return area


def choose_by_rules(question: str, snapshot: Snapshot):
    lower = question.casefold()
    area = mentioned_area(question, snapshot)
    if "просроч" in lower:
        return ToolChoice(tool="overdue_orders", area_id=None, specialty=None)
    if "свобод" in lower or "доступн" in lower:
        specialty = "слесарь" if "слесар" in lower else "электромонтёр" if "электромонт" in lower else None
        return ToolChoice(tool="available_workers", area_id=None, specialty=specialty)
    if area and ("проблем" in lower or "полом" in lower):
        return ToolChoice(tool="area_problems", area_id=area.id, specialty=None)
    if area and ("отчёт" in lower or "отчет" in lower or "сколько наряд" in lower):
        return ToolChoice(tool="area_report", area_id=area.id, specialty=None)
    return ToolChoice(tool="unknown", area_id=None, specialty=None)


def period_for(question: str, now: datetime):
    days = 30 if "месяц" in question.casefold() else 7 if "недел" in question.casefold() else None
    return (now - timedelta(days=days), now) if days else (None, None)


class MasterAssistant:
    def __init__(self, source: DataSource, llm: LLMClient):
        self.source = source
        self.llm = llm

    async def ask(self, question: str, now: datetime):
        if not question.strip() or len(question) > 1000:
            raise ValueError("Вопрос должен содержать от 1 до 1000 символов")
        try:
            return await asyncio.wait_for(self._answer(question, utc(now)), timeout=40)
        except asyncio.TimeoutError:
            return {"status": "timeout", "tool": None, "tool_calls": 0, "answer": "Превышено время ожидания; попробуйте уточнить вопрос.",
                    "facts": {}, "final_decision_by_master": True}

    async def _answer(self, question: str, now: datetime):
        snapshot = await self.source.snapshot()
        choice = choose_by_rules(question, snapshot)
        if choice.tool == "unknown" and self.llm.safe_text_enabled():
            selected = await self.llm.structured_response(
                "master_tool", {"question": self.llm.redact(question, snapshot.employees),
                                "areas": [{"id": area.id, "name": area.name} for area in snapshot.areas],
                                "tools": ["available_workers", "overdue_orders", "area_report", "area_problems"]},
                TOOL_SCHEMA, ToolChoice, smart=True)
            if selected and selected.tool in {"available_workers", "overdue_orders", "area_report", "area_problems"}:
                area = mentioned_area(question, snapshot)
                if (selected.tool.startswith("area_") and area and selected.area_id == area.id) or (
                        not selected.tool.startswith("area_") and selected.area_id is None):
                    choice = selected
        if choice.tool == "unknown" or (choice.tool.startswith("area_") and choice.area_id is None):
            return {"status": "needs_clarification", "tool": None, "tool_calls": 0,
                    "answer": "Уточните вопрос и участок.", "facts": {}, "final_decision_by_master": True}
        start, end = period_for(question, now)
        if choice.tool == "available_workers":
            busy = {order.assignee_id for order in snapshot.orders if order.status in ACTIVE_STATUSES and
                    utc(order.created_at) <= now and (not order.completed_at or utc(order.completed_at) > now)}
            people = [person for person in snapshot.employees if person.role == "worker" and person.on_shift and
                      person.id not in busy and (not choice.specialty or choice.specialty in person.specialty.casefold())]
            aliases = [f"E-{person.id:02}" for person in people]
            facts = {"free_workers": len(people), "worker_ids": aliases,
                     "availability_basis": "on_shift_flag_minus_active_orders_not_live_presence"}
            answer = f"Свободных исполнителей: {len(people)}. " + ", ".join(aliases)
        elif choice.tool == "overdue_orders":
            orders = [order for order in snapshot.orders if order.status in ACTIVE_STATUSES and
                      utc(order.deadline) < now and utc(order.created_at) <= now]
            facts = {"overdue": len(orders), "order_ids": [order.id for order in orders]}
            answer = f"Просроченных нарядов: {len(orders)}."
        else:
            orders = [order for order in snapshot.orders if order.area_id == choice.area_id and
                      (start <= utc(order.created_at) < end if start else utc(order.created_at) <= now)]
            if choice.tool == "area_report":
                facts = {"area_id": choice.area_id, "area_count": len(orders),
                         "from": start.isoformat() if start else None, "to": end.isoformat() if end else None}
                answer = f"Нарядов на участке: {len(orders)}."
            else:
                unplanned = [order for order in orders if order.work_type == "unplanned"]
                fault_counts = Counter(order.completion.fault_code_id for order in unplanned
                                       if order.completion and order.completion.fault_code_id is not None)
                facts = {"area_id": choice.area_id, "unplanned_count": len(unplanned),
                         "top_fault_codes": [{"fault_code_id": fault_id, "orders": count}
                                             for fault_id, count in fault_counts.most_common(3)],
                         "order_ids": [order.id for order in unplanned[:20]],
                         "order_ids_truncated": len(unplanned) > 20}
                answer = f"Внеплановых нарядов на участке: {len(unplanned)}."
        return {"status": "answered", "tool": choice.tool, "tool_calls": 1, "answer": answer,
                "facts": facts, "as_of": now.isoformat(), "final_decision_by_master": True}
