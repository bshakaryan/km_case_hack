"""Transparent demo rating; weights are provisional until Q05 is decided."""

from collections import defaultdict
from datetime import datetime, timedelta

from .config import Settings
from .datasource import DataSource
from .deadlines import utc
from .schemas import OrderRecord
from .storage import AIStore
from .verification import source_version


def repeated_repairs(orders: list[OrderRecord]):
    groups = defaultdict(list)
    for order in orders:
        if order.work_type == "unplanned" and order.completion and order.completion.fault_code_id:
            groups[(order.equipment_id, order.completion.fault_code_id)].append(order)
    repeated = set()
    for repairs in groups.values():
        repairs.sort(key=lambda item: utc(item.created_at))
        for earlier, later in zip(repairs, repairs[1:]):
            difference = utc(later.created_at) - utc(earlier.created_at)
            if timedelta(0) < difference <= timedelta(days=7):
                repeated.add(earlier.id)
    return repeated


class RatingService:
    def __init__(self, source: DataSource, settings: Settings, store: AIStore | None = None):
        self.source = source
        self.settings = settings
        self.store = store

    async def calculate(self, start: datetime, end: datetime):
        start, end = utc(start), utc(end)
        if end <= start:
            raise ValueError("Конец периода должен быть позже начала")
        snapshot = await self.source.snapshot()
        repeats = repeated_repairs(snapshot.orders)
        selected = [order for order in snapshot.orders if start <= utc(order.created_at) < end]
        saved_reviews = ({(item["subject_id"], item["source_version"]): item
                          for item in self.store.list_results("review")} if self.store else {})
        target_hours = max(8.0, (end - start).total_seconds() / 86400 * 4)
        results = []
        for person in snapshot.employees:
            if person.role != "worker":
                continue
            orders = [order for order in selected if order.assignee_id == person.id]
            if not orders:
                continue
            scores = []
            score_sources = {"master": 0, "ai": 0}
            for order in orders:
                saved = saved_reviews.get((str(order.id), source_version(order)))
                override = saved["master_override"] if saved else None
                if override and override.get("score") is not None:
                    scores.append(float(override["score"]))
                    score_sources["master"] += 1
                elif order.score is not None:
                    scores.append(float(order.score))
                    score_sources["master"] += 1
                elif order.ai_review and isinstance(order.ai_review.get("score"), (int, float)):
                    scores.append(float(order.ai_review["score"]))
                    score_sources["ai"] += 1
                elif saved and isinstance(saved["payload"].get("suggested_score"), (int, float)):
                    scores.append(float(saved["payload"]["suggested_score"]))
                    score_sources["ai"] += 1
            finished = [order for order in orders if order.completed_at]
            reworks = sum(any(event.action == "rework" for event in order.events) for order in orders)
            unplanned = [order for order in orders if order.work_type == "unplanned" and order.completion]
            known_complexity = [order.normal_hours for order in orders if order.normal_hours and order.normal_hours > 0]
            refusals = [event for order in orders for event in order.events if event.action == "reject"]
            unjustified = [event for event in refusals if not event.comment.strip()]
            components = {
                "quality": round(sum(scores) / len(scores) / 5 * 100, 2) if scores else None,
                "on_time": round(sum(utc(order.completed_at) <= utc(order.deadline) for order in finished)
                                 / len(finished) * 100, 2) if finished else None,
                "no_rework": round((1 - reworks / len(orders)) * 100, 2),
                "no_repeat": round((1 - sum(order.id in repeats for order in unplanned) / len(unplanned)) * 100, 2)
                if unplanned else None,
                "volume": round(min(100, sum(known_complexity) / target_hours * 100), 2)
                if known_complexity else None,
                "no_unjustified_refusal": round((1 - len(unjustified) / len(refusals)) * 100, 2)
                if refusals else None,
            }
            known_weight = sum(self.settings.rating_weights[key] for key, value in components.items()
                               if value is not None)
            score = (round(sum(components[key] * self.settings.rating_weights[key]
                               for key in components if components[key] is not None) / known_weight, 2)
                     if known_weight else None)
            results.append({
                "employee_id": person.id, "employee_alias": f"E-{person.id - 2:02}" if person.login.startswith("ai_worker") else f"E-{person.id:02}",
                "score": score, "components": components, "weights": self.settings.rating_weights,
                "known_weight": round(known_weight, 3), "orders": len(orders),
                "quality_sources": score_sources, "repeat_repairs": sum(order.id in repeats for order in unplanned),
                "reworks": reworks, "unjustified_refusals": len(unjustified),
                "complexity_hours_known": round(sum(known_complexity), 2) if known_complexity else None,
                "explanation": (f"Рейтинг {score if score is not None else 'неизвестен'}: качество {components['quality'] if components['quality'] is not None else 'неизвестно'}, "
                                f"сроки {components['on_time'] if components['on_time'] is not None else 'неизвестно'}, "
                                f"повторы {components['no_repeat'] if components['no_repeat'] is not None else 'неизвестно'}. "
                                "Отсутствующие данные исключены из весов."),
            })
        results.sort(key=lambda item: (item["score"] is None, -(item["score"] or 0), item["employee_id"]))
        for position, result in enumerate(results, 1):
            result["rank"] = position
        return {"from": start.isoformat(), "to": end.isoformat(), "ratings": results,
                "policy": "demo_provisional", "final_master_priority": True}
