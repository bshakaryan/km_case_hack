"""Code-owned completion flags and verdict; LLM only compares text meaning."""

import re

from .datasource import DataSource
from .deadlines import utc
from .llm_client import LLMClient, SemanticAssessment
from .schemas import OrderRecord, Snapshot
from .storage import AIStore


def source_version(order: OrderRecord):
    completions = [event for event in order.events if event.action == "complete"]
    if completions:
        return f"event:{max(completions, key=lambda event: utc(event.created_at)).id}"
    return f"completed:{utc(order.completed_at).isoformat()}" if order.completed_at else "no-completion"


def scrub(text: str, snapshot: Snapshot):
    result = text
    for person in sorted(snapshot.employees, key=lambda item: len(item.name), reverse=True):
        if person.name:
            result = re.sub(re.escape(person.name), f"E-{person.id:02}", result, flags=re.IGNORECASE)
        if person.login and len(person.login) >= 4:
            result = re.sub(r"\b" + re.escape(person.login) + r"\b", f"E-{person.id:02}",
                            result, flags=re.IGNORECASE)
    result = re.sub(r"\+?\d[\d\s()\-]{8,}\d", "[телефон удалён]", result)
    result = re.sub(r"[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}", "[email удалён]", result)
    result = re.sub(r"\bтаб(?:ельный)?\.?\s*(?:№|номер)?\s*\d{3,}\b", "[табельный номер удалён]",
                    result, flags=re.IGNORECASE)
    return result


def fault_terms(name: str):
    words = re.findall(r"[а-яёa-z]+", name.lower())
    return {word[:5] for word in words if len(word) >= 5 and word not in {"износ", "отказ", "повреждение", "проверка"}}


def rule_semantics(order: OrderRecord, snapshot: Snapshot):
    fault_id = order.completion.fault_code_id if order.completion else None
    fault = next((item for item in snapshot.fault_codes if item.id == fault_id), None)
    if fault is None or order.completion is None:
        return None, 0.0
    work = order.completion.work_done.lower()
    own_terms = fault_terms(fault.name)
    if any(term in work for term in own_terms):
        return True, 0.7
    other_terms = set().union(*(fault_terms(item.name) for item in snapshot.fault_codes if item.id != fault_id))
    if any(term in work for term in other_terms) and not any(term in work for term in own_terms):
        return False, 0.65
    return None, 0.2


def calculate_flags(order: OrderRecord, snapshot: Snapshot):
    completion = order.completion
    fault_id = completion.fault_code_id if completion else None
    code_exists = any(item.id == fault_id for item in snapshot.fault_codes)
    norms = {item.material_id: item.quantity for item in snapshot.material_norms
             if item.fault_code_id == fault_id}
    materials = completion.materials if completion else []
    excess = []
    unusual = []
    for usage in materials:
        if norms and usage.material_id not in norms:
            unusual.append(usage.material_id)
        elif usage.material_id in norms and usage.quantity > 1.5 * norms[usage.material_id]:
            excess.append(usage.material_id)
    actual_hours = None
    if order.started_at and order.completed_at:
        actual_hours = round((utc(order.completed_at) - utc(order.started_at)).total_seconds() / 3600, 2)
    normal_hours = order.normal_hours if order.normal_hours and order.normal_hours > 0 else None
    fault = next((item for item in snapshot.fault_codes if item.id == fault_id), None)
    problem = (order.description or order.title).lower()
    own_terms = fault_terms(fault.name) if fault else set()
    other_terms = set().union(*(fault_terms(item.name) for item in snapshot.fault_codes if item.id != fault_id))
    code_description_status = ("match" if own_terms and any(term in problem for term in own_terms) else
                               "mismatch" if any(term in problem for term in other_terms) else "unknown")
    return {
        "missing_work": not bool(completion and completion.work_done.strip()),
        "missing_fault_code": not code_exists,
        "missing_materials": bool(norms and not materials),
        "missing_after_photo": order.work_type == "unplanned" and not any(photo.kind == "after" for photo in order.photos),
        "code_description_status": code_description_status,
        "material_norm_status": "known" if norms else "unknown",
        "excess_material_ids": excess,
        "unusual_material_ids": unusual,
        "time_status": "unknown" if actual_hours is None or normal_hours is None else
        "over_norm" if actual_hours > normal_hours else "within_norm",
        "deadline_status": "unknown" if not order.completed_at else
        "late" if utc(order.completed_at) > utc(order.deadline) else "on_time",
        "actual_hours": actual_hours,
        "normal_hours": normal_hours,
    }


def semantic_valid(semantic: SemanticAssessment, order: OrderRecord, snapshot: Snapshot, flags: dict):
    references = {"problem", "work_done", "time", "deadline", "fault_code", "after_photo", "materials"}
    references.update(f"material:{item.material_id}" for item in (order.completion.materials if order.completion else []))
    references.update(f"event:{event.id}" for event in order.events)
    if any(remark.evidence_ref not in references for remark in semantic.remarks):
        return False
    explanations = " ".join([semantic.explanation_worker, semantic.explanation_master,
                             *(remark.text for remark in semantic.remarks)])
    if re.search(r"\d", explanations):
        return False
    return not any(person.name and person.name.lower() in explanations.lower() for person in snapshot.employees)


def decide_verdict(flags: dict, match: bool | None, confidence: float, llm_invalid=False):
    if flags["missing_work"] or flags["missing_fault_code"] or flags["missing_after_photo"]:
        return "needs_rework"
    if llm_invalid:
        return "needs_master_review"
    if flags["code_description_status"] == "mismatch":
        return "needs_rework"
    if match is False and confidence >= 0.6:
        return "needs_rework"
    if match is None or confidence < 0.5 or flags["time_status"] == "unknown":
        return "needs_master_review"
    if (flags["excess_material_ids"] or flags["unusual_material_ids"] or flags["missing_materials"]
            or flags["time_status"] == "over_norm" or flags["deadline_status"] == "late"):
        return "accepted_with_remarks"
    return "accepted"


def suggested_score(verdict: str, flags: dict, match: bool | None):
    if verdict == "needs_master_review":
        return None
    if verdict == "accepted":
        return 5
    if verdict == "needs_rework":
        hard = sum([flags["missing_work"], flags["missing_fault_code"], flags["missing_after_photo"],
                    flags["code_description_status"] == "mismatch", match is False])
        return 1 if hard > 1 else 2
    remarks = sum([bool(flags["excess_material_ids"]), bool(flags["unusual_material_ids"]),
                   flags["missing_materials"], flags["time_status"] == "over_norm",
                   flags["deadline_status"] == "late"])
    return 3 if remarks > 1 else 4


class CompletionVerifier:
    def __init__(self, source: DataSource, store: AIStore, llm: LLMClient):
        self.source = source
        self.store = store
        self.llm = llm

    async def verify(self, order_id: int, expected_version: str | None = None):
        snapshot = await self.source.snapshot()
        order = next((item for item in snapshot.orders if item.id == order_id), None)
        if order is None:
            raise LookupError("Наряд не найден")
        if order.completion is None:
            raise ValueError("Наряд ещё не сдан")
        version = source_version(order)
        if expected_version is not None and expected_version != version:
            raise ValueError("Сдача изменилась до завершения проверки")
        existing = self.store.get_result("review", str(order.id), version)
        if existing:
            return existing["payload"]
        flags = calculate_flags(order, snapshot)
        rule_match, rule_confidence = rule_semantics(order, snapshot)
        prompt = {
            "equipment_id": order.equipment_id, "fault_code_id": order.completion.fault_code_id,
            "worker": f"E-{order.assignee_id:02}",
            "problem": scrub(order.description or order.title, snapshot),
            "work_done": scrub(order.completion.work_done, snapshot),
            "flags": {key: value for key, value in flags.items() if key not in {"actual_hours", "normal_hours"}},
            "evidence_refs": ["problem", "work_done", "time", "deadline", "fault_code", "after_photo", "materials"]
                             + [f"material:{usage.material_id}" for usage in order.completion.materials]
                             + [f"event:{event.id}" for event in order.events],
        }
        semantic = await self.llm.interpret(prompt)
        invalid = bool(semantic and not semantic_valid(semantic, order, snapshot, flags))
        match = semantic.works_match_problem if semantic and not invalid else rule_match
        confidence = semantic.match_confidence if semantic and not invalid else rule_confidence
        verdict = decide_verdict(flags, match, confidence, invalid)
        concerns = []
        if flags["missing_after_photo"]:
            concerns.append("Нет обязательного фото после ремонта")
        if flags["missing_fault_code"]:
            concerns.append("Шифр неисправности отсутствует или неизвестен")
        if flags["missing_work"]:
            concerns.append("Не описаны выполненные работы")
        if flags["code_description_status"] == "mismatch":
            concerns.append("Шифр не соответствует описанию проблемы")
        if flags["excess_material_ids"]:
            concerns.append("Расход материалов выше полутора норм")
        if flags["unusual_material_ids"]:
            concerns.append("Материалы нетипичны для шифра")
        if flags["time_status"] == "over_norm":
            concerns.append("Время выполнения выше норматива")
        if match is False:
            concerns.append("Работы не соответствуют описанной проблеме")
        if invalid:
            concerns.append("Ответ модели не прошёл проверку доказательств")
        result = {
            "order_id": order.id, "source_version": version, "verdict": verdict, "flags": flags,
            "suggested_score": suggested_score(verdict, flags, match),
            "works_match_problem": match, "match_confidence": confidence,
            "remarks": [remark.model_dump() for remark in semantic.remarks] if semantic and not invalid else [],
            "explanation_worker": semantic.explanation_worker if semantic and not invalid else
            ("Проверка завершена; требуется решение мастера." if verdict == "needs_master_review" else
             "Проверьте замечания по наряду." if concerns else "Формальные признаки выполнения подтверждены."),
            "explanation_master": semantic.explanation_master if semantic and not invalid else
            "Рекомендация по детерминированным правилам; финальное решение за мастером.",
            "concerns": concerns, "llm_used": bool(semantic and not invalid), "needs_master_review": verdict == "needs_master_review",
            "is_recommendation": True,
        }
        self.store.put_result("review", str(order.id), version, result)
        return result
