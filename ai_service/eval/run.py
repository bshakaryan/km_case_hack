"""Evaluate implemented MVP modules without contacting production services."""

import argparse
import asyncio
import hashlib
import json
import re
from collections import Counter
from datetime import datetime
from pathlib import Path

from app.analytics import AnalyticsService
from app.assistant import MasterAssistant
from app.config import BASE_DIR, DEFAULT_RATING_WEIGHTS, Settings
from app.datasource import DataSource
from app.deadlines import DeadlineController, utc
from app.llm_client import LLMClient
from app.intake import OrderIntake
from app.photos import compare_images
from app.rating import RatingService
from app.schemas import OrderRecord, Snapshot
from app.storage import AIStore
from app.verification import CompletionVerifier


VERDICTS = ("accepted", "accepted_with_remarks", "needs_rework", "needs_master_review")
FLAGS = ("missing_after_photo", "missing_fault_code", "excess_material", "over_norm_time",
         "uncertain_match", "unknown_norm", "works_mismatch")


class MemorySource(DataSource):
    def __init__(self, snapshot: Snapshot):
        self.value = snapshot

    async def snapshot(self):
        return self.value

    async def photo_bytes(self, photo):
        raise RuntimeError("Photo content is not used by Phase 4 evaluations")


class CaptureNotifier:
    async def send(self, recipient, title, message, idempotency_key):
        return True


class MeasuredLLM(LLMClient):
    def __init__(self, settings, store, employees):
        super().__init__(settings, store)
        self.prompts = 0
        self.privacy_leaks = 0
        self.employees = employees

    async def interpret(self, prompt):
        if self.enabled():
            self.prompts += 1
            serialized = json.dumps(prompt, ensure_ascii=False)
            name_leaked = any(person.name and person.name.lower() in serialized.lower()
                              for person in self.employees)
            login_leaked = any(person.login and len(person.login) >= 4 and
                               re.search(r"\b" + re.escape(person.login) + r"\b", serialized, re.IGNORECASE)
                               for person in self.employees)
            self.privacy_leaks += int(name_leaked or login_leaked)
        return await super().interpret(prompt)


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def ratio(numerator: int, denominator: int):
    return round(numerator / denominator, 4) if denominator else None


def scores(expected: list[str], predicted: list[str], labels=VERDICTS):
    matrix = {truth: {prediction: 0 for prediction in labels} for truth in labels}
    for truth, prediction in zip(expected, predicted, strict=True):
        matrix[truth][prediction] += 1
    by_class = {}
    for label in labels:
        true_positive = matrix[label][label]
        expected_total = sum(matrix[label].values())
        predicted_total = sum(row[label] for row in matrix.values())
        precision = true_positive / predicted_total if predicted_total else 0.0
        recall = true_positive / expected_total if expected_total else 0.0
        by_class[label] = {"precision": round(precision, 4), "recall": round(recall, 4),
                           "f1": round(2 * precision * recall / (precision + recall), 4)
                           if precision + recall else 0.0, "support": expected_total}
    return {"accuracy": ratio(sum(truth == prediction for truth, prediction in zip(expected, predicted, strict=True)),
                              len(expected)),
            "macro_f1": round(sum(item["f1"] for item in by_class.values()) / len(labels), 4),
            "confusion_matrix": matrix, "by_class": by_class}


def actual_flag(name: str, result: dict):
    flags = result["flags"]
    return {
        "missing_after_photo": lambda: flags["missing_after_photo"],
        "missing_fault_code": lambda: flags["missing_fault_code"],
        "excess_material": lambda: bool(flags["excess_material_ids"]),
        "over_norm_time": lambda: flags["time_status"] == "over_norm",
        "uncertain_match": lambda: result["works_match_problem"] is None or result["match_confidence"] < 0.5,
        "unknown_norm": lambda: flags["time_status"] == "unknown",
        "works_mismatch": lambda: result["works_match_problem"] is False,
    }[name]()


async def evaluate_verification(snapshot: Snapshot, cases: list[dict], settings: Settings):
    source = MemorySource(snapshot)
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    llm = MeasuredLLM(settings, store, snapshot.employees)
    verifier = CompletionVerifier(source, store, llm)
    expected, predicted, errors = [], [], []
    flag_counts = {name: {"true_positive": 0, "expected_positive": 0, "predicted_positive": 0}
                   for name in FLAGS}
    llm_used = 0
    try:
        for case in cases:
            order = OrderRecord.model_validate(case["order"])
            source.value = snapshot.model_copy(update={"orders": [order]})
            result = await verifier.verify(order.id)
            expected.append(case["expected_verdict"])
            predicted.append(result["verdict"])
            llm_used += int(result["llm_used"])
            missed_flags = []
            for name in FLAGS:
                truth = case["expected_flags"].get(name, False) is True
                found = actual_flag(name, result)
                totals = flag_counts[name]
                totals["expected_positive"] += int(truth)
                totals["predicted_positive"] += int(found)
                totals["true_positive"] += int(truth and found)
                if truth and not found:
                    missed_flags.append(name)
            if result["verdict"] != case["expected_verdict"] or missed_flags:
                errors.append({"case_id": case["id"], "category": case["category"],
                               "expected": case["expected_verdict"], "actual": result["verdict"],
                               "missed_flags": missed_flags})
    finally:
        store.close()
    flag_metrics = {name: {**counts,
                           "recall": ratio(counts["true_positive"], counts["expected_positive"]),
                           "precision": None, "label_scope": "positive_only"}
                    for name, counts in flag_counts.items()}
    return {"cases": len(cases), **scores(expected, predicted), "flags": flag_metrics,
            "needs_master_review_rate": ratio(predicted.count("needs_master_review"), len(predicted)),
            "llm_used_results": llm_used, "error_count": len(errors), "error_examples": errors[:3],
            "llm": {"prompts": llm.prompts, "privacy_leaks": llm.privacy_leaks,
                    "enabled": llm.enabled(), "request_count": llm.request_count,
                    "cache_hits": llm.cache_hits, "input_tokens": llm.input_tokens,
                    "output_tokens": llm.output_tokens,
                    "request_latencies_ms": llm.request_latencies_ms}}


def deadline_snapshot(case: dict, now: datetime):
    item = case["order"]
    issued_at = datetime.fromisoformat(item["issued_at"])
    accepted_at = datetime.fromisoformat(item["accepted_at"]) if item["accepted_at"] else None
    status = "in_progress" if accepted_at and now >= accepted_at else "issued"
    events = [{"id": 1, "action": "issue", "to_status": "issued", "created_at": issued_at}]
    if status == "in_progress":
        events.append({"id": 2, "action": "accept", "to_status": "accepted", "created_at": accepted_at})
        events.append({"id": 3, "action": "start", "to_status": "in_progress", "created_at": accepted_at})
    return Snapshot.model_validate({
        "areas": [{"id": 1, "name": "Учебный участок"}],
        "equipment": [{"id": 1, "name": "Учебный конвейер", "inventory_number": "AI-01", "area_id": 1}],
        "employees": [{"id": 1, "name": "Мастер", "role": "master"},
                      {"id": 2, "name": "Исполнитель", "role": "worker", "specialty": "слесарь"},
                      {"id": 3, "name": "Сменщик", "role": "worker", "specialty": "слесарь"},
                      {"id": 4, "name": "Руководитель", "role": "manager"}],
        "orders": [{"id": 1, "number": item["number"], "title": "Учебный наряд",
                    "description": "Проверить оборудование", "work_type": "unplanned", "area_id": 1,
                    "equipment_id": 1, "assignee_id": 2, "master_id": 1,
                    "priority": item["priority"], "status": status, "deadline": item["deadline"],
                    "created_at": issued_at, "started_at": accepted_at if status == "in_progress" else None,
                    "events": events}],
    })


def recipient_role(recipient: str):
    return {"E-02": "worker", "M-01": "master", "G-04": "manager"}.get(recipient, "unknown")


async def evaluate_deadlines(cases: list[dict]):
    expected_total = predicted_total = true_positive = duplicates = 0
    timing_errors = []
    errors = []
    for case in cases:
        first_tick = datetime.fromisoformat(case["tick_times"][0])
        source = MemorySource(deadline_snapshot(case, first_tick))
        store = AIStore("sqlite:///:memory:")
        store.initialize()
        controller = DeadlineController(source, store, CaptureNotifier(), Settings())
        observed = []
        try:
            for value in case["tick_times"]:
                now = datetime.fromisoformat(value)
                source.value = deadline_snapshot(case, now)
                observed.extend(await controller.tick(now))
            repeated_at = datetime.fromisoformat(case["repeat_tick_at"])
            source.value = deadline_snapshot(case, repeated_at)
            observed.extend(await controller.tick(repeated_at))
        finally:
            store.close()
        predicted = Counter((recipient_role(event["recipient"]), event["type"],
                             utc(datetime.fromisoformat(event["at"])).isoformat()) for event in observed)
        expected = Counter((event["recipient"], event["type"],
                            utc(datetime.fromisoformat(event["at"])).isoformat())
                           for event in case["expected_notifications"])
        matches = sum((predicted & expected).values())
        true_positive += matches
        expected_total += sum(expected.values())
        predicted_total += sum(predicted.values())
        key_counts = Counter(event["idempotency_key"] for event in observed)
        duplicates += sum(count - 1 for count in key_counts.values() if count > 1)
        expected_by_kind = {}
        for recipient, kind, when in expected:
            expected_by_kind.setdefault((recipient, kind), []).append(datetime.fromisoformat(when))
        for recipient, kind, when in predicted:
            choices = expected_by_kind.get((recipient, kind), [])
            if choices:
                timing_errors.append(min(abs((datetime.fromisoformat(when) - target).total_seconds())
                                         for target in choices) / 60)
        if predicted != expected:
            missing = list((expected - predicted).elements())
            extra = list((predicted - expected).elements())
            errors.append({"case_id": case["id"], "missing": missing[:3], "extra": extra[:3]})
    precision = ratio(true_positive, predicted_total)
    recall = ratio(true_positive, expected_total)
    return {"cases": len(cases), "expected_notifications": expected_total,
            "predicted_notifications": predicted_total, "true_positive": true_positive,
            "precision": precision, "recall": recall, "duplicates": duplicates,
            "mean_timing_error_minutes": round(sum(timing_errors) / len(timing_errors), 4) if timing_errors else None,
            "max_timing_error_minutes": round(max(timing_errors), 4) if timing_errors else None,
            "error_count": len(errors), "error_examples": errors[:3],
            "scope": "schedule_only_capture_notifier_not_real_delivery"}


def pairwise_agreement(original: dict, changed: dict):
    identities = sorted(set(original) & set(changed))
    agrees = compared = 0
    for index, left in enumerate(identities):
        for right in identities[index + 1:]:
            first = original[left] - original[right]
            second = changed[left] - changed[right]
            if first == 0 or second == 0:
                continue
            compared += 1
            agrees += int((first < 0) == (second < 0))
    return ratio(agrees, compared)


async def evaluate_rating(snapshot: Snapshot):
    source = MemorySource(snapshot)
    start = min(utc(order.created_at) for order in snapshot.orders)
    end = max(utc(order.created_at) for order in snapshot.orders)
    from datetime import timedelta
    end += timedelta(seconds=1)
    baseline = await RatingService(source, Settings()).calculate(start, end)
    baseline_ranks = {item["employee_alias"]: item["rank"] for item in baseline["ratings"]}
    bottom_start = len(baseline_ranks) - len(baseline_ranks) // 3 + 1
    targets = {alias: {"rank": baseline_ranks.get(alias), "bottom_third": baseline_ranks.get(alias, 0) >= bottom_start}
               for alias in ("E-04", "E-11")}
    variants = []
    for component in DEFAULT_RATING_WEIGHTS:
        for factor in (0.8, 1.2):
            weights = DEFAULT_RATING_WEIGHTS.copy()
            weights[component] *= factor
            total = sum(weights.values())
            weights = {key: value / total for key, value in weights.items()}
            result = await RatingService(source, Settings(rating_weights=weights)).calculate(start, end)
            changed = {item["employee_alias"]: item["rank"] for item in result["ratings"]}
            variants.append({"component": component, "factor": factor,
                             "pairwise_order_agreement": pairwise_agreement(baseline_ranks, changed),
                             "max_rank_shift": max(abs(baseline_ranks[alias] - changed[alias])
                                                   for alias in baseline_ranks),
                             "target_bottom_third": all(changed.get(alias, 0) >= bottom_start
                                                        for alias in targets)})
    failures = [{"alias": alias, **value} for alias, value in targets.items() if not value["bottom_third"]]
    return {"workers": len(baseline_ranks), "bottom_third_starts_at_rank": bottom_start,
            "targets": targets, "both_targets_bottom_third": not failures,
            "stability": {"variants": len(variants),
                          "min_pairwise_order_agreement": min(item["pairwise_order_agreement"] for item in variants),
                          "mean_pairwise_order_agreement": round(sum(item["pairwise_order_agreement"] for item in variants)
                                                                 / len(variants), 4),
                          "max_rank_shift": max(item["max_rank_shift"] for item in variants),
                          "targets_bottom_third_all_variants": all(item["target_bottom_third"] for item in variants)},
            "variant_details": variants, "error_examples": failures[:3],
            "scope": "synthetic_provisional_weights_not_independent_expert_rating"}


def evaluate_photo_duplicates(cases: list[dict]):
    if not cases:
        return {"status": "not_available", "precision": None, "recall": None,
                "reason": "Нет photos_dup.json; создайте `make data` с фото"}
    true_positive = false_positive = false_negative = 0
    errors = []
    by_variant = {}
    for case in cases:
        first = BASE_DIR / case["source"]
        second = BASE_DIR / case["candidate"]
        if not first.is_file() or not second.is_file():
            return {"status": "not_available", "precision": None, "recall": None,
                    "reason": "Исходники фото-дублей отсутствуют; выполните `make data`"}
        comparison = compare_images(first.read_bytes(), second.read_bytes())
        expected = case["expected_duplicate"]
        predicted = comparison["duplicate"]
        true_positive += int(expected and predicted)
        false_positive += int(not expected and predicted)
        false_negative += int(expected and not predicted)
        variant = by_variant.setdefault(case["variant"], {"cases": 0, "correct": 0})
        variant["cases"] += 1
        variant["correct"] += int(expected == predicted)
        if expected != predicted:
            errors.append({"case_id": case["id"], "variant": case["variant"],
                           "expected_duplicate": expected, "actual_duplicate": predicted,
                           "phash_distance": comparison["phash_distance"], "ssim": comparison["ssim"]})
    return {"status": "measured_synthetic", "cases": len(cases),
            "precision": ratio(true_positive, true_positive + false_positive),
            "recall": ratio(true_positive, true_positive + false_negative),
            "true_positive": true_positive, "false_positive": false_positive, "false_negative": false_negative,
            "by_variant": by_variant, "error_count": len(errors), "error_examples": errors[:3],
            "scope": "technical_duplicates_only_not_visible_repair_quality"}


async def evaluate_analytics(snapshot: Snapshot, truth: dict):
    if not isinstance(truth, dict) or not truth.get("patterns"):
        return {"status": "not_available", "found_of_six": None, "false_positive_decoys": None}
    from datetime import timedelta
    start = datetime.fromisoformat(truth["period"]["from"])
    end = datetime.fromisoformat(truth["period"]["to"]) + timedelta(seconds=1)
    report = await AnalyticsService(MemorySource(snapshot)).analyze(start, end)
    signatures = {
        "k3_recurrence": ("high_failure_equipment", "equipment_id", 3),
        "e11_repeat_7d": ("repeat_worker", "employee_id", 13),
        "pump_after_ppr": ("after_ppr", "equipment_id", 10),
        "night_brigade2_late": ("shift_lateness", "brigade_id", 2),
        "e04_material_overuse": ("material_overuse", "employee_id", 6),
        "mill_last_month_growth": ("unplanned_growth", "equipment_id", 9),
    }
    decoy_signatures = {
        "isolated_crusher_spike": ("high_failure_equipment", "equipment_id", 2),
        "single_shift_delay": ("shift_lateness", "brigade_id", 1),
        "one_large_writeoff": ("material_overuse", "employee_id", 8),
    }

    def matches(signature):
        kind, key, value = signature
        return [item for item in report["findings"] if item["kind"] == kind and item["entity"].get(key) == value]

    detected = {item["id"]: bool(matches(signatures[item["id"]])) for item in truth["patterns"]}
    decoys = {item["id"]: bool(matches(decoy_signatures[item["id"]])) for item in truth["decoys"]}
    expected_items = {id(item) for signature in signatures.values() for item in matches(signature)}
    additional = [item for item in report["findings"] if id(item) not in expected_items]
    return {"status": "measured_synthetic", "found_of_six": sum(detected.values()),
            "detected_patterns": detected, "false_positive_decoys": sum(decoys.values()),
            "decoy_detections": decoys, "additional_unlabeled_findings": len(additional),
            "additional_examples": [{"kind": item["kind"], "entity": item["entity"], "facts": item["facts"]}
                                    for item in additional[:3]],
            "total_findings": len(report["findings"]),
            "scope": "seeded_patterns_not_independent_ground_truth_causality_unproven"}


async def evaluate_intake(snapshot: Snapshot, cases: list[dict]):
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    service = OrderIntake(MemorySource(snapshot), LLMClient(Settings(demo_mode=True), store))
    fields = ("equipment_id", "area_id", "fault_code_id", "time_norm_id", "deadline")
    correct = {name: 0 for name in fields}
    valid = total = 0
    errors = []
    valid_ids = {"equipment_id": {item.id for item in snapshot.equipment},
                 "area_id": {item.id for item in snapshot.areas},
                 "fault_code_id": {item.id for item in snapshot.fault_codes},
                 "time_norm_id": {item.id for item in snapshot.time_norms}}
    try:
        for case in cases:
            result = await service.from_text(case["phrase"], datetime.fromisoformat(case["reference_time"]))
            draft = result["draft"]
            differences = {}
            for name in fields:
                predicted = draft[name]
                expected = case["expected"][name]
                if name == "deadline" and predicted:
                    predicted = utc(datetime.fromisoformat(predicted)).isoformat().replace("+00:00", "Z")
                correct[name] += int(predicted == expected)
                if predicted != expected:
                    differences[name] = {"expected": expected, "actual": predicted}
            for name, allowed in valid_ids.items():
                if draft[name] is not None:
                    total += 1
                    valid += int(draft[name] in allowed)
            if differences:
                errors.append({"case_id": case["id"], "fields": differences})
    finally:
        store.close()
    return {"status": "measured_synthetic", "cases": len(cases),
            "field_accuracy": {name: ratio(count, len(cases)) for name, count in correct.items()},
            "valid_id_rate": ratio(valid, total), "error_count": len(errors), "error_examples": errors[:3],
            "scope": "template_cases_not_independent_real_speech"}


async def evaluate_assistant(snapshot: Snapshot, cases: list[dict]):
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    service = MasterAssistant(MemorySource(snapshot), LLMClient(Settings(demo_mode=True), store))
    tools_correct = numbers_correct = 0
    errors = []
    try:
        for case in cases:
            result = await service.ask(case["question"], datetime.fromisoformat(case["reference_time"]))
            tool_ok = result["tool"] == case["expected_tool"]
            number_ok = result["facts"].get(case["expected_metric"]) == case["expected_value"]
            tools_correct += int(tool_ok)
            numbers_correct += int(number_ok)
            if not tool_ok or not number_ok:
                errors.append({"case_id": case["id"], "expected_tool": case["expected_tool"],
                               "actual_tool": result["tool"], "expected_number": case["expected_value"],
                               "actual_number": result["facts"].get(case["expected_metric"])})
    finally:
        store.close()
    return {"status": "measured_synthetic", "cases": len(cases),
            "tool_accuracy": ratio(tools_correct, len(cases)),
            "numeric_answer_accuracy": ratio(numbers_correct, len(cases)),
            "error_count": len(errors), "error_examples": errors[:3],
            "scope": "four_read_only_tools_template_questions_not_real_query_distribution"}


def llm_summary(verification: dict, input_price: float | None, output_price: float | None):
    stats = verification["llm"]
    latencies = sorted(stats.pop("request_latencies_ms"))
    stats["mean_latency_ms"] = round(sum(latencies) / len(latencies), 2) if latencies else None
    stats["p95_latency_ms"] = latencies[max(0, (95 * len(latencies) + 99) // 100 - 1)] if latencies else None
    if input_price is not None and output_price is not None and stats["request_count"] and (
            stats["input_tokens"] or stats["output_tokens"]):
        stats["estimated_cost_usd"] = round((stats["input_tokens"] * input_price +
                                             stats["output_tokens"] * output_price) / 1_000_000, 6)
    else:
        stats["estimated_cost_usd"] = None
    stats["cost_note"] = "Provide both per-million-token prices; API usage is read from provider responses."
    return stats


def markdown(metrics: dict):
    deadlines = metrics["deadlines"]
    rules = metrics["verification"]["rules_only"]
    rating = metrics["rating"]
    llm = metrics["llm"]
    photos = metrics["photo_duplicates"]
    anomalies = metrics["anomalies"]
    lines = ["# Метрики ИИ-сервиса — фаза 6", "",
             "Офлайн-оценка на фиксированной синтетике. Эталоны размечены генератором, а не независимыми экспертами; это проверка реализации относительно учебных сценариев, **не accuracy на производстве**. Числа и вердикты считает код. Основная БД и API не изменены.", "",
             "## Контроль сроков 6.1", "",
             f"- Случаи: {deadlines['cases']}; событий: {deadlines['expected_notifications']} ожидается, {deadlines['predicted_notifications']} предсказано.",
             f"- Precision/recall: {deadlines['precision']} / {deadlines['recall']}; дубли: {deadlines['duplicates']}.",
             f"- Ошибка времени, минуты: средняя {deadlines['mean_timing_error_minutes']}, максимум {deadlines['max_timing_error_minutes']}. Проверялся план отправки с CaptureNotifier, **не фактическая доставка Telegram/FCM**.", "",
             "## Проверка сдачи 6.2", "",
             f"- Правила: {rules['cases']} случаев, accuracy {rules['accuracy']}, macro-F1 {rules['macro_f1']}, ручная проверка {rules['needs_master_review_rate']}.",
             "- Матрица ошибок: строки — эталон, столбцы — прогноз.", "",
             "| Эталон \\ прогноз | " + " | ".join(VERDICTS) + " |", "| --- | " + " | ".join("---:" for _ in VERDICTS) + " |"]
    for label in VERDICTS:
        lines.append("| " + label + " | " + " | ".join(str(rules["confusion_matrix"][label][column])
                                                   for column in VERDICTS) + " |")
    lines.extend(["", "Recall флагов; отрицательные метки отсутствуют, поэтому precision флагов не измеряется:", ""])
    for name, value in rules["flags"].items():
        lines.append(f"- `{name}`: {value['recall']} ({value['true_positive']}/{value['expected_positive']}).")
    llm_mode = metrics["verification"]["rules_plus_llm"]
    lines.extend(["", "## Правила + LLM", "",
                  f"{('Accuracy ' + str(llm_mode['accuracy']) + ', macro-F1 ' + str(llm_mode['macro_f1']) + ', ручная проверка ' + str(llm_mode['needs_master_review_rate']) + '.') if llm_mode['status'] == 'measured' else 'Не измерено: ' + llm_mode['reason']}",
                  f"Вызовы API: {llm['request_count']}; кэш-попадания: {llm['cache_hits']}; токены вход/выход: {llm['input_tokens']}/{llm['output_tokens']}; средняя/p95 задержка, мс: {llm['mean_latency_ms']}/{llm['p95_latency_ms']}; примерная стоимость USD: {llm['estimated_cost_usd']}. Без настроенной цены стоимость неизвестна, а не ноль.",
                  f"Промпты с ФИО/логином из справочника: {llm['privacy_leaks']} из {llm['prompts']}; если вызовов не было, это не доказательство безопасности продуктивных данных.", "",
                  "## Рейтинг 6.6", "",
                  f"- Работников: {rating['workers']}; нижняя треть начинается с места {rating['bottom_third_starts_at_rank']}; E-04: {rating['targets']['E-04']['rank']}, E-11: {rating['targets']['E-11']['rank']}. Оба в нижней трети: {rating['both_targets_bottom_third']}.",
                  f"- При изменении каждого веса на ±20% с нормализацией: {rating['stability']['variants']} вариантов, минимальное/среднее попарное совпадение порядка {rating['stability']['min_pairwise_order_agreement']}/{rating['stability']['mean_pairwise_order_agreement']}, максимальный сдвиг {rating['stability']['max_rank_shift']} мест. Это чувствительность формулы, не справедливость рейтинга.", "",
                  "## Фото-дубли 6.3", "",
                  f"- {photos['cases'] if photos['status'] == 'measured_synthetic' else 'Не измерено'} синтетических пар; precision {photos['precision']}, recall {photos['recall']}. Это технические дубли, не качество ремонта и не проверка свежести съёмки.", "",
                  "## Аналитика 6.5", "",
                  f"- Найдено заложенных сигналов: {anomalies['found_of_six']}/6; срабатываний на трёх приманках: {anomalies['false_positive_decoys']}; дополнительных неразмеченных гипотез: {anomalies.get('additional_unlabeled_findings')}. Они требуют проверки, а не считаются автоматически ошибками или доказанной причинностью.",
                  f"- Примеры неразмеченных гипотез: {json.dumps(anomalies.get('additional_examples', []), ensure_ascii=False)}.", "",
                  "## Ввод наряда 6.8", "",
                  f"- {metrics['intake']['cases']} шаблонных фраз; точность полей: {json.dumps(metrics['intake']['field_accuracy'], ensure_ascii=False)}; доля существующих ID: {metrics['intake']['valid_id_rate']}.",
                  "- Это текстовый ввод на синтетике; распознавание реального аудио отдельно не проверено.", "",
                  "## Ассистент мастера 6.7", "",
                  f"- {metrics['assistant']['cases']} шаблонных вопросов; выбор инструмента: {metrics['assistant']['tool_accuracy']}; совпадение чисел с эталоном: {metrics['assistant']['numeric_answer_accuracy']}.",
                  "- Ответы и числа формируются кодом из снимка, не моделью; внешние tool-call API не проверялись.", "",
                  "## Ещё не измерено", "",
                  "- Vision-оценка устранения дефекта и качества: нужны 15–20 реальных пар с независимой экспертной разметкой; процедурные рисунки непригодны.",
                  "- STT-accuracy на реальных аудиозаписях и качество LLM-выбора инструментов/полей не измерены.", "",
                  "## Ошибки и ограничения", ""])
    for title, item in (("Сроки", deadlines), ("Проверка", rules), ("Рейтинг", rating),
                        ("Фото-дубли", photos), ("Ввод", metrics["intake"]),
                        ("Ассистент", metrics["assistant"])):
        examples = item.get("error_examples", [])
        lines.append(f"- {title}: {item.get('error_count', len(examples))} ошибок; примеры: " +
                     ("; ".join(json.dumps(example, ensure_ascii=False) for example in examples[:3])
                      if examples else "ошибок в наборе нет, три примера не выдумываем") + ".")
    lines.extend(["- Эталоны проверки используют ту же учебную политику, поэтому совпадение с ней не подтверждает качество работы на реальных нарядах.",
                  "- Флаги размечены только положительно по целевой категории; ложные срабатывания отдельных флагов нельзя честно оценить на этом наборе.",
                  "- Пороги pHash/SSIM и эвристики аналитики проверены на тех же синтетических преобразованиях и закономерностях; независимого holdout-набора нет.",
                  "- Времена отправки тестируются поминутно; задержка фонового планировщика, сеть, перезапуск и доставка не измерены.",
                  "- Рейтинг опирается на синтетические оценки и временные веса Q05; причинность повторного дефекта не доказана.",
                  "- Финальное решение по сдаче и оценке остаётся за мастером.", "",
                  "Запуск: `make data && make eval` из `ai_service/`; Windows без make: `python -m data_gen.generate`, затем `python -m eval.run`. Платный LLM-прогон — только явный `python -m eval.run --with-llm` на синтетике."])
    return "\n".join(lines) + "\n"


async def evaluate(data_dir: Path, cases_dir: Path, with_llm=False,
                   input_price: float | None = None, output_price: float | None = None):
    snapshot_path = data_dir / "snapshot.json"
    if not snapshot_path.exists():
        raise FileNotFoundError("Сначала выполните `python -m data_gen.generate` из ai_service/")
    snapshot = Snapshot.model_validate_json(snapshot_path.read_text(encoding="utf-8"))
    case_names = ("verification", "deadlines", "photos_dup", "intake", "assistant", "analytics")
    cases = {name: read_json(cases_dir / f"{name}.json") if (cases_dir / f"{name}.json").exists() else []
             for name in case_names}
    if not cases["verification"] or not cases["deadlines"]:
        raise ValueError("Нет эталонов verification/deadlines: сначала перегенерируйте данные")
    rules = await evaluate_verification(snapshot, cases["verification"], Settings(demo_mode=True))
    llm_mode = {"status": "not_run", "reason": "Платный LLM-прогон требует явного --with-llm"}
    llm_stats = rules["llm"]
    if with_llm:
        settings = Settings.from_env().model_copy(update={"demo_mode": False})
        if not LLMClient(settings, AIStore("sqlite:///:memory:")).enabled():
            raise ValueError("Для --with-llm задайте LLM_PROVIDER, LLM_MODEL_FAST и ключ в ai_service/.env")
        llm_result = await evaluate_verification(snapshot, cases["verification"], settings)
        llm_stats = llm_result.pop("llm")
        llm_mode = {"status": "measured", **llm_result}
    rules.pop("llm")
    result = {
        "phase": 6, "dataset": "synthetic", "label_source": "generator_code_not_expert",
        "snapshot_sha256": hashlib.sha256(snapshot_path.read_bytes()).hexdigest(),
        "case_counts": {name: len(cases[name]) if isinstance(cases[name], list) else len(cases[name].get("patterns", []))
                        for name in case_names},
        "deadlines": await evaluate_deadlines(cases["deadlines"]),
        "verification": {"rules_only": rules, "rules_plus_llm": llm_mode},
        "rating": await evaluate_rating(snapshot),
        "photo_duplicates": evaluate_photo_duplicates(cases["photos_dup"]),
        "vision": {"status": "real_labeled_pairs_required", "score": None},
        "anomalies": await evaluate_analytics(snapshot, cases["analytics"]),
        "intake": await evaluate_intake(snapshot, cases["intake"]),
        "assistant": await evaluate_assistant(snapshot, cases["assistant"]),
    }
    result["case_counts"]["analytics_decoys"] = len(cases["analytics"].get("decoys", [])) if isinstance(
        cases["analytics"], dict) else 0
    result["llm"] = llm_summary({"llm": llm_stats}, input_price, output_price)
    return result


def main():
    parser = argparse.ArgumentParser(description="Синтетическая оценка реализованных модулей ИИ-сервиса")
    parser.add_argument("--data-dir", type=Path, default=BASE_DIR / "data")
    parser.add_argument("--cases-dir", type=Path, default=BASE_DIR / "eval" / "cases")
    parser.add_argument("--reports-dir", type=Path, default=BASE_DIR / "reports")
    parser.add_argument("--with-llm", action="store_true", help="Явно разрешить платные вызовы LLM на синтетике")
    parser.add_argument("--input-price-per-million", type=float)
    parser.add_argument("--output-price-per-million", type=float)
    args = parser.parse_args()
    if any(price is not None and price < 0 for price in
           (args.input_price_per_million, args.output_price_per_million)):
        parser.error("Цены токенов не могут быть отрицательными")
    metrics = asyncio.run(evaluate(args.data_dir, args.cases_dir, args.with_llm,
                                   args.input_price_per_million, args.output_price_per_million))
    args.reports_dir.mkdir(parents=True, exist_ok=True)
    (args.reports_dir / "metrics.json").write_text(json.dumps(metrics, ensure_ascii=False, indent=2) + "\n",
                                                    encoding="utf-8")
    (args.reports_dir / "metrics.md").write_text(markdown(metrics), encoding="utf-8")
    print(json.dumps({"reports": str(args.reports_dir), "deadline_precision": metrics["deadlines"]["precision"],
                      "verification_accuracy": metrics["verification"]["rules_only"]["accuracy"],
                      "rating_targets_bottom_third": metrics["rating"]["both_targets_bottom_third"]},
                     ensure_ascii=False))


if __name__ == "__main__":
    main()
