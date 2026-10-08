"""Statistical findings from order history, never autonomous work-order decisions."""

from collections import Counter, defaultdict
from datetime import datetime, timedelta
from statistics import median
from zoneinfo import ZoneInfo

import numpy as np
from scipy.stats import fisher_exact
from sklearn.ensemble import IsolationForest

from .datasource import DataSource
from .deadlines import utc
from .schemas import OrderRecord, Snapshot


def fault_id(order: OrderRecord):
    return order.completion.fault_code_id if order.completion else None


def late(order: OrderRecord):
    return bool(order.completed_at and utc(order.completed_at) > utc(order.deadline))


def finding(kind: str, entity: dict, facts: dict, recommendation: str, orders: list[OrderRecord]):
    if kind == "high_failure_equipment":
        summary = (f"{facts['equipment']}: {facts['unplanned_orders']} внеплановых нарядов, "
                   f"из них {facts['dominant_fault_count']} по шифру {facts['dominant_fault_code']}; "
                   f"медиана по другим единицам — {facts['median_other_equipment']}.")
    elif kind == "repeat_worker":
        summary = (f"Исполнитель #{entity['employee_id']}: {facts['repeats_within_7_days']} повторов "
                   f"из {facts['repairs']} ремонтов в пределах семи дней; "
                   f"у остальных доля {facts['other_worker_rate']}.")
    elif kind == "after_ppr":
        summary = (f"Оборудование #{entity['equipment_id']}: {facts['failures_within_5_days']} внеплановых "
                   f"нарядов в пределах пяти дней после {facts['planned_orders']} плановых.")
    elif kind == "shift_lateness":
        summary = (f"Бригада #{entity['brigade_id']}, смена {entity['shift']}: "
                   f"{facts['late_orders']} просрочек из {facts['orders']} нарядов; "
                   f"доля в сравнении {facts['comparison_late_rate']}.")
    elif kind == "material_overuse":
        summary = (f"Исполнитель #{entity['employee_id']}, материал #{entity['material_id']}: "
                   f"{facts['anomalous_observations']} аномальных списаний из {facts['observations']}; "
                   f"медианный расход {facts['median_ratio_to_norm']} нормы.")
    else:
        summary = (f"Оборудование #{entity['equipment_id']}: за последние тридцать дней "
                   f"{facts['last_30_days']} внеплановых нарядов против {facts['previous_months']} "
                   "в двух предыдущих периодах.")
    return {"kind": kind, "entity": entity, "facts": facts,
            "summary": summary, "recommendation": recommendation,
            "order_ids": sorted({order.id for order in orders}),
            "is_recommendation": True, "requires_master_review": True}


def repeated_repairs(orders: list[OrderRecord]):
    by_fault = defaultdict(list)
    for order in orders:
        if order.work_type == "unplanned" and fault_id(order) is not None:
            by_fault[(order.equipment_id, fault_id(order))].append(order)
    repeated = set()
    for group in by_fault.values():
        group.sort(key=lambda item: utc(item.created_at))
        for earlier, later in zip(group, group[1:]):
            if timedelta(0) < utc(later.created_at) - utc(earlier.created_at) <= timedelta(days=7):
                repeated.add(earlier.id)
    return repeated


def top_problem_entities(orders: list[OrderRecord], snapshot: Snapshot):
    by_equipment = defaultdict(list)
    by_area = defaultdict(list)
    for order in orders:
        if order.work_type == "unplanned":
            by_equipment[order.equipment_id].append(order)
            by_area[order.area_id].append(order)
    equipment_names = {item.id: item.name for item in snapshot.equipment}
    area_names = {item.id: item.name for item in snapshot.areas}

    def rows(groups, names):
        return sorted(({"id": entity_id, "name": names.get(entity_id, f"#{entity_id}"),
                        "unplanned_orders": len(group),
                        "reported_downtime_minutes": round(sum(order.downtime_minutes or 0 for order in group), 2),
                        "downtime_verified": False} for entity_id, group in groups.items()),
                      key=lambda item: (-item["unplanned_orders"], -item["reported_downtime_minutes"], item["id"]))

    return rows(by_equipment, equipment_names), rows(by_area, area_names)


def high_failure_equipment(orders: list[OrderRecord], snapshot: Snapshot):
    groups = defaultdict(list)
    for order in orders:
        if order.work_type == "unplanned":
            groups[order.equipment_id].append(order)
    if len(groups) < 5:
        return []
    names = {item.id: item.name for item in snapshot.equipment}
    codes = {item.id: item.code for item in snapshot.fault_codes}
    result = []
    for equipment_id, group in groups.items():
        others = [len(items) for other_id, items in groups.items() if other_id != equipment_id]
        baseline = median(others) if others else 0
        distribution = Counter(fault_id(order) for order in group if fault_id(order) is not None)
        if not distribution:
            continue
        dominant_id, dominant_count = distribution.most_common(1)[0]
        share = dominant_count / len(group)
        if len(group) < 12 or baseline < 3 or len(group) / baseline < 2.5 or share < 0.6:
            continue
        result.append(finding("high_failure_equipment", {"equipment_id": equipment_id},
                              {"equipment": names.get(equipment_id), "unplanned_orders": len(group),
                               "median_other_equipment": baseline, "dominant_fault_code_id": dominant_id,
                               "dominant_fault_code": codes.get(dominant_id), "dominant_fault_count": dominant_count,
                               "dominant_share": round(share, 3)},
                              "Проверить первопричину повторяющегося дефекта и скорректировать план ППР.", group))
    return result


def repeat_worker_findings(orders: list[OrderRecord]):
    unplanned = [order for order in orders if order.work_type == "unplanned" and fault_id(order) is not None]
    repeated = repeated_repairs(orders)
    groups = defaultdict(list)
    for order in unplanned:
        groups[order.assignee_id].append(order)
    result = []
    for employee_id, group in groups.items():
        others = [order for order in unplanned if order.assignee_id != employee_id]
        rate = sum(order.id in repeated for order in group) / len(group)
        other_rate = sum(order.id in repeated for order in others) / len(others) if others else 0
        if len(group) < 20 or rate < 0.25 or other_rate <= 0 or rate / other_rate < 2:
            continue
        result.append(finding("repeat_worker", {"employee_id": employee_id},
                              {"repairs": len(group), "repeats_within_7_days": sum(order.id in repeated for order in group),
                               "repeat_rate": round(rate, 3), "other_worker_rate": round(other_rate, 3)},
                              "Проверить повторные дефекты с мастером; статистика не доказывает вину исполнителя.", group))
    return result


def after_ppr_findings(orders: list[OrderRecord]):
    planned = defaultdict(list)
    unplanned = defaultdict(list)
    for order in orders:
        (planned if order.work_type == "planned" else unplanned)[order.equipment_id].append(order)
    result = []
    for equipment_id, scheduled in planned.items():
        followups = []
        for repair in unplanned.get(equipment_id, []):
            if any(timedelta(0) < utc(repair.created_at) - utc(ppr.completed_at or ppr.created_at)
                   <= timedelta(days=5) for ppr in scheduled):
                followups.append(repair)
        if len(followups) < 6 or len(scheduled) < 6:
            continue
        result.append(finding("after_ppr", {"equipment_id": equipment_id},
                              {"planned_orders": len(scheduled), "failures_within_5_days": len(followups)},
                              "Проверить качество ППР и причины последующих остановок; временная связь не доказывает причину.",
                              scheduled + followups))
    return result


def shift_findings(orders: list[OrderRecord]):
    completed = [order for order in orders if order.completed_at and order.brigade_id is not None]
    groups = defaultdict(list)
    for order in completed:
        hour = utc(order.created_at).astimezone(ZoneInfo("Asia/Almaty")).hour
        shift = "night" if hour >= 20 or hour < 8 else "day"
        groups[(order.brigade_id, shift)].append(order)
    result = []
    for (brigade_id, shift), group in groups.items():
        group_ids = {order.id for order in group}
        others = [order for order in completed if order.id not in group_ids]
        if len(group) < 20 or len(others) < 20:
            continue
        late_count = sum(late(order) for order in group)
        other_late = sum(late(order) for order in others)
        rate = late_count / len(group)
        comparison_rate = other_late / len(others)
        odds_ratio, p_value = fisher_exact([[late_count, len(group) - late_count],
                                            [other_late, len(others) - other_late]], alternative="greater")
        adjusted_alpha = 0.05 / len(groups)
        if comparison_rate <= 0 or rate / comparison_rate < 1.5 or p_value >= adjusted_alpha:
            continue
        result.append(finding("shift_lateness", {"brigade_id": brigade_id, "shift": shift},
                              {"orders": len(group), "late_orders": late_count, "late_rate": round(rate, 3),
                               "comparison_orders": len(others), "comparison_late_rate": round(comparison_rate, 3),
                               "fisher_p_value": float(f"{p_value:.3g}"), "tested_groups": len(groups),
                               "bonferroni_alpha": round(adjusted_alpha, 6)},
                              "Проверить загрузку и обеспечение смены; связь не является доказательством причины.", group))
    return result


def association_breakdown(orders: list[OrderRecord]):
    groups = defaultdict(list)
    for order in orders:
        hour = utc(order.created_at).astimezone(ZoneInfo("Asia/Almaty")).hour
        shift = "night" if hour >= 20 or hour < 8 else "day"
        keys = [("shift", shift), ("hour", hour), ("employee_id", order.assignee_id)]
        if order.brigade_id is not None:
            keys.append(("brigade_id", order.brigade_id))
        for key in keys:
            groups[key].append(order)
    eligible = [(key, group) for key, group in groups.items() if len(group) >= 10]
    alpha = 0.05 / len(eligible) if eligible else None
    rows = []
    for (dimension, value), group in eligible:
        group_ids = {order.id for order in group}
        others = [order for order in orders if order.id not in group_ids]
        unplanned = sum(order.work_type == "unplanned" for order in group)
        comparison_unplanned = sum(order.work_type == "unplanned" for order in others)
        p_value = (fisher_exact([[unplanned, len(group) - unplanned],
                                 [comparison_unplanned, len(others) - comparison_unplanned]],
                                alternative="two-sided").pvalue if len(others) >= 10 else None)
        rows.append({"dimension": dimension, "value": value, "orders": len(group),
                     "unplanned_orders": unplanned, "unplanned_rate": round(unplanned / len(group), 3),
                     "late_orders": sum(late(order) for order in group),
                     "comparison_unplanned_rate": round(comparison_unplanned / len(others), 3) if others else None,
                     "fisher_p_value": float(f"{p_value:.3g}") if p_value is not None else None,
                     "bonferroni_alpha": round(alpha, 6) if alpha is not None else None,
                     "statistically_significant": bool(p_value is not None and alpha is not None and p_value < alpha)})
    return sorted(rows, key=lambda item: (item["dimension"], str(item["value"])))


def material_findings(orders: list[OrderRecord], snapshot: Snapshot):
    norms = {(item.fault_code_id, item.material_id): item.quantity for item in snapshot.material_norms}
    observations = []
    for order in orders:
        if not order.completion or fault_id(order) is None:
            continue
        for usage in order.completion.materials:
            normal = norms.get((fault_id(order), usage.material_id))
            if normal and normal > 0:
                observations.append((order, usage.material_id, usage.quantity / normal))
    if len(observations) < 30:
        return [], "unknown_insufficient_normed_materials"
    values = np.array([item[2] for item in observations], dtype=float)
    centre = float(np.median(values))
    mad = float(np.median(np.abs(values - centre)))
    robust_z = (values - centre) / max(1.4826 * mad, 0.1)
    isolated = IsolationForest(n_estimators=100, random_state=42, contamination="auto").fit_predict(
        np.log1p(values).reshape(-1, 1))
    groups = defaultdict(list)
    for index, (order, material_id, ratio) in enumerate(observations):
        groups[(order.assignee_id, material_id)].append((order, ratio, robust_z[index], isolated[index]))
    result = []
    for (employee_id, material_id), group in groups.items():
        anomalous = [entry for entry in group if entry[1] > 1.5 and entry[2] > 3 and entry[3] == -1]
        if len(group) < 5 or len(anomalous) < 5 or len(anomalous) / len(group) < 0.5:
            continue
        result.append(finding("material_overuse", {"employee_id": employee_id, "material_id": material_id},
                              {"observations": len(group), "anomalous_observations": len(anomalous),
                               "median_ratio_to_norm": round(float(median(entry[1] for entry in group)), 3),
                               "method": "IsolationForest_and_robust_MAD"},
                              "Проверить списания и норматив с мастером; единичный выброс не является обвинением.",
                              [entry[0] for entry in group]))
    return result, "measured"


def growth_findings(orders: list[OrderRecord], end: datetime):
    groups = defaultdict(list)
    for order in orders:
        if order.work_type == "unplanned":
            groups[order.equipment_id].append(order)
    result = []
    for equipment_id, group in groups.items():
        monthly = [sum(end - timedelta(days=30 * (index + 1)) <= utc(order.created_at) <
                       end - timedelta(days=30 * index) for order in group) for index in (2, 1, 0)]
        previous_average = (monthly[0] + monthly[1]) / 2
        if monthly[2] < 8 or previous_average < 2 or monthly[2] / previous_average < 2:
            continue
        result.append(finding("unplanned_growth", {"equipment_id": equipment_id},
                              {"previous_months": monthly[:2], "last_30_days": monthly[2],
                               "ratio_to_previous_average": round(monthly[2] / previous_average, 3)},
                              "Проверить рост внеплановых работ и включить оборудование в план диагностики.", group))
    return result


class AnalyticsService:
    def __init__(self, source: DataSource):
        self.source = source

    async def analyze(self, start: datetime, end: datetime, area_id: int | None = None):
        start, end = utc(start), utc(end)
        if end <= start:
            raise ValueError("Конец периода должен быть позже начала")
        snapshot = await self.source.snapshot()
        if area_id is not None and not any(area.id == area_id for area in snapshot.areas):
            raise LookupError("Участок не найден")
        orders = [order for order in snapshot.orders if start <= utc(order.created_at) < end and
                  (area_id is None or order.area_id == area_id)]
        equipment, areas = top_problem_entities(orders, snapshot)
        materials, material_status = material_findings(orders, snapshot)
        findings = (high_failure_equipment(orders, snapshot) + repeat_worker_findings(orders) +
                    after_ppr_findings(orders) + shift_findings(orders) + materials + growth_findings(orders, end))
        findings.sort(key=lambda item: (item["kind"], tuple(item["entity"].values())))
        valid_order_ids = {order.id for order in orders}
        if any(not set(item["order_ids"]) <= valid_order_ids for item in findings):
            raise ValueError("Вывод содержит ссылку на отсутствующий наряд")
        return {"from": start.isoformat(), "to": end.isoformat(), "area_id": area_id,
                "orders_analyzed": len(orders), "top_equipment": equipment[:10], "top_areas": areas,
                "findings": findings, "associations": association_breakdown(orders),
                "material_analysis_status": material_status,
                "reported_downtime_verified": False, "causality_proven": False,
                "final_decision_by_master": True}
