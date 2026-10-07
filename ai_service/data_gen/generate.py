"""Deterministic, wholly synthetic НарядAI snapshot and rule-labelled cases."""

import csv
import json
import random
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

from PIL import Image, ImageDraw

from app.schemas import Snapshot


BASE = Path(__file__).resolve().parents[1]
SEED = 20261007
START = datetime(2026, 7, 1, 3, tzinfo=timezone.utc)
FAULTS = [
    ("М-01", "Износ ролика", 3), ("М-02", "Износ подшипника", 1),
    ("М-03", "Обрыв ремня", 4), ("М-04", "Вибрация привода", 2),
    ("Э-01", "Повреждение кабеля", 11), ("Э-02", "Отказ контактора", 15),
    ("Э-03", "Перегрев двигателя", 34), ("Э-04", "Сбой датчика", 12),
    ("Г-01", "Утечка масла", 5), ("Г-02", "Износ уплотнения", 7),
    ("Г-03", "Падение давления", 21), ("Г-04", "Засорение фильтра", 13),
    ("П-01", "Плановый осмотр", 8), ("П-02", "Смазка узла", 6),
    ("П-03", "Проверка центровки", 18), ("П-04", "Замена фильтра", 14),
    ("С-01", "Трещина кожуха", 17), ("С-02", "Ослабление крепежа", 8),
    ("С-03", "Загрязнение зоны", 40), ("С-04", "Нарушение ограждения", 31),
]
MATERIAL_NAMES = [
    "Подшипник 6205", "Подшипник 6308", "Ролик конвейерный", "Ремень А-1250",
    "Масло И-40А", "Смазка Литол-24", "Уплотнение 40×60", "Болт М12×50",
    "Гайка М12", "Шайба М12", "Кабель ВВГ", "Датчик индуктивный",
    "Фильтр масляный", "Фильтр воздушный", "Контактор КМЭ", "Предохранитель 32А",
    "Электрод 3 мм", "Муфта соединительная", "Цепь приводная", "Шланг гидравлический",
    "Манжета 50×70", "Колодка тормозная", "Лента конвейерная", "Очиститель контактов",
    "Хомут 25 мм", "Клемма 6 мм²", "Изолента ПВХ", "Термопаста",
    "Сальник 30×52", "Анкер М16", "Шпилька М10", "Редукторное масло",
    "Щетка двигателя", "Реле перегрузки", "Вентиль 25 мм", "Труба стальная",
    "Фланец 50 мм", "Рукав напорный", "Герметик", "Ветошь",
]
EQUIPMENT_NAMES = [
    "Дробилка КМД-1750", "Дробилка ККД-1500", "Конвейер К-3", "Грохот ГИ-01",
    "Дробилка КСД-2200", "Конвейер К-1", "Конвейер К-2", "Питатель ПЛ-01",
    "Мельница МШЦ-3600", "Насос НС-01", "Насос НС-02", "Сепаратор СМ-01",
    "Мельница МШЦ-2700", "Фильтр ФР-01", "Насос НС-03", "Сепаратор СМ-02",
    "Конвейер К-4", "Грохот ГИ-02", "Тельфер ТЭ-01", "Кран КМ-01",
    "Компрессор КВ-01", "Трансформатор ТМ-01", "Насос НС-04",
    "Сепаратор СМ-03", "Дробилка КМД-1200",
]
DESCRIPTION_VARIANTS = [
    "Обнаружен {fault}; проверить {equipment} и устранить причину.",
    "{equipment}: {fault}. Нужна диагностика и контрольный пуск.",
    "На смене замечен {fault}, по возможности устранить без простоя.",
    "{fault}; проверьте узел и запишите выполненные работы.",
    "Замечен {fault}, проверить оборуд. {equipment} и устранить.",
]
WORK_VARIANTS = [
    "Устранён {fault}; выполнен контрольный пуск.",
    "Проверили узел, устранили {fault}; под нагрузкой работает нормально.",
    "Устранение: {fault}. Проверка на холостом ходу и под нагрузкой.",
]


def timestamp(value):
    return value.isoformat().replace("+00:00", "Z")


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def references():
    areas = [
        {"id": index, "name": name}
        for index, name in enumerate([
            "Дробильно-сортировочный комплекс", "Обогатительная фабрика",
            "Транспортный участок", "Энергетический участок",
        ], 1)
    ]
    brigades = [{"id": index, "name": f"Бригада №{index}"} for index in range(1, 4)]
    employees = [
        {"id": index, "name": f"Мастер {index}", "role": "master", "login": f"ai_master{index}",
         "specialty": "Мастер смены", "grade": 0, "brigade_id": None, "on_shift": True}
        for index in range(1, 3)
    ]
    specialties = ["Слесарь-ремонтник", "Электромонтёр", "Механик"]
    for index in range(1, 16):
        employees.append({
            "id": index + 2, "name": f"Сотрудник E-{index:02}", "role": "worker",
            "login": f"ai_worker{index:02}", "specialty": specialties[(index - 1) % 3],
            "grade": 4 + index % 3, "brigade_id": (index - 1) // 5 + 1, "on_shift": True,
        })
    employees.append({"id": 18, "name": "Руководитель", "role": "manager", "login": "ai_manager",
                      "specialty": "Руководитель смены", "grade": 0, "brigade_id": None, "on_shift": True})
    equipment = []
    for index, name in enumerate(EQUIPMENT_NAMES, 1):
        area_id = 1 if index <= 8 or index == 25 else 2 if index <= 16 or index == 24 else 3 if index <= 20 else 4
        equipment.append({
            "id": index, "name": name, "inventory_number": f"КМ-{1000 + index}",
            "area_id": area_id, "type": name.split()[0],
            "criticality": "high" if index in {1, 2, 3, 9, 10} else "medium",
        })
    fault_codes = [{"id": index, "code": code, "name": name} for index, (code, name, _) in enumerate(FAULTS, 1)]
    materials = [{
        "id": index, "name": name,
        "unit": "л" if index in {5, 32} else "кг" if index in {6, 17} else "м" if index in {11, 23, 36, 38} else "шт",
    } for index, name in enumerate(MATERIAL_NAMES, 1)]
    norms = [{"id": index, "name": f"{code}: {name}", "hours": round(0.75 + index % 6 * 0.5, 2)}
             for index, (code, name, _) in enumerate(FAULTS, 1)]
    material_norms = [
        {"fault_code_id": index, "material_id": material_id, "quantity": 1.0}
        for index, (_, _, material_id) in enumerate(FAULTS, 1)
    ]
    material_norms.extend([
        {"fault_code_id": 2, "material_id": 6, "quantity": 0.4},
        {"fault_code_id": 4, "material_id": 6, "quantity": 0.4},
        {"fault_code_id": 9, "material_id": 39, "quantity": 0.3},
    ])
    extra_materials = {
        18: [9, 10, 30], 6: [16], 3: [19], 11: [20, 35, 36, 37, 38],
        4: [22], 1: [23], 8: [24], 9: [25, 32], 5: [26, 27],
        7: [28, 33], 10: [29],
    }
    for fault_id, material_ids in extra_materials.items():
        for material_id in material_ids:
            material_norms.append({"fault_code_id": fault_id, "material_id": material_id,
                                   "quantity": 0.5 if material_id in {32} else 1.0})
    return {
        "areas": areas, "brigades": brigades, "employees": employees, "equipment": equipment,
        "fault_codes": fault_codes, "materials": materials, "time_norms": norms,
    }, material_norms


def make_order(index, equipment, employee, fault_id, created, planned, rng, norms, material_norms,
               decoy_late=False):
    fault_code = FAULTS[fault_id - 1]
    normal_hours = norms[fault_id - 1]["hours"]
    brigade_id = employee["brigade_id"]
    night = index % 2 == 1
    late_rate = 0.45 if night and brigade_id == 2 else 0.17
    late = rng.random() < late_rate or decoy_late
    elapsed_hours = normal_hours * (1.45 if late else rng.uniform(0.55, 0.92))
    started = created + timedelta(minutes=12)
    completed = started + timedelta(hours=elapsed_hours)
    deadline = created + timedelta(hours=normal_hours + 0.4)
    closed = completed + timedelta(minutes=20)
    usages = []
    for material_norm in material_norms:
        if material_norm["fault_code_id"] == fault_id:
            material_id = material_norm["material_id"]
            if employee["id"] == 6 and material_id in {1, 6}:
                quantity_here = round(material_norm["quantity"] * 2.5, 2)
            else:
                quantity_here = material_norm["quantity"]
            usages.append({"material_id": material_id, "quantity": quantity_here,
                           "name": MATERIAL_NAMES[material_id - 1], "unit": "шт" if material_id == 1 else "кг" if material_id == 6 else None})
    fault_text = fault_code[1].lower()
    description = rng.choice(DESCRIPTION_VARIANTS).format(fault=fault_text, equipment=equipment["name"])
    work_done = rng.choice(WORK_VARIANTS).format(fault=fault_text)
    if index % 19 == 0:
        description = description.replace("подшипника", "подшипнка").replace("оборудование", "оборудовние")
    events = []
    for action, previous, status, when, actor in [
        ("issue", None, "issued", created, 1 + index % 2),
        ("accept", "issued", "accepted", created + timedelta(minutes=5), employee["id"]),
        ("start", "accepted", "in_progress", started, employee["id"]),
        ("complete", "in_progress", "completed", completed, employee["id"]),
        ("ai_review", "completed", "ai_review", completed + timedelta(minutes=1), 1 + index % 2),
        ("close", "ai_review", "closed", closed, 1 + index % 2),
    ]:
        events.append({"id": index * 10 + len(events) + 1, "action": action, "from_status": previous,
                       "to_status": status, "created_at": timestamp(when), "actor_name": f"Сотрудник {actor}",
                       "comment": "Синтетическое событие"})
    photos = [{"id": index, "kind": "after", "created_at": timestamp(completed - timedelta(minutes=2)),
               "path": f"photos/orders/{index:05}.png", "author_name": employee["name"]}]
    if not planned and index % 3 == 0:
        photos.insert(0, {"id": 10000 + index, "kind": "before",
                          "created_at": timestamp(created + timedelta(minutes=1)),
                          "path": f"photos/orders/{index:05}-before.png", "author_name": employee["name"]})
    return {
        "id": index, "number": f"Н-2026-{index:05}", "title": fault_code[1], "description": description,
        "work_type": "planned" if planned else "unplanned", "area_id": equipment["area_id"],
        "equipment_id": equipment["id"], "assignee_id": employee["id"], "brigade_id": brigade_id,
        "master_id": 1 + index % 2, "priority": "planned" if planned else "emergency" if index % 31 == 0 else "normal",
        "status": "closed", "deadline": timestamp(deadline), "created_at": timestamp(created),
        "started_at": timestamp(started), "completed_at": timestamp(completed), "closed_at": timestamp(closed),
        "comment": "Синтетический наряд", "normal_hours": normal_hours,
        "downtime_minutes": 0 if planned else round(elapsed_hours * 60),
        "score": 2.8 if employee["id"] == 13 else 3.0 if employee["id"] == 6 else 3.0 if late else 4.5,
        "completion": {
            "work_done": work_done, "fault_code_id": fault_id, "comment": "Контрольный запуск выполнен",
            "materials": usages,
        }, "ai_review": None, "events": events,
        "photos": photos,
    }


def make_orders(reference, material_norms, rng):
    employees = {index: person for index, person in enumerate(reference["employees"][2:], 1)}
    orders = []
    for equipment in reference["equipment"]:
        count = 72 if equipment["id"] == 3 else 48 if equipment["id"] == 10 else 36 if equipment["id"] == 9 else 24
        for sequence in range(count):
            index = len(orders) + 1
            day = (sequence * 83 // count + equipment["id"] * 7) % 90
            if equipment["id"] == 9 and sequence >= 24:
                day = 60 + (sequence - 24) * 2
            created = START + timedelta(days=day, hours=12 if index % 2 else 0, minutes=(index * 13) % 50)
            if equipment["id"] == 2 and sequence < 3:
                created = START + timedelta(days=10, hours=12 if index % 2 else 0,
                                             minutes=sequence * 10)
            planned = sequence % 5 == 0
            if equipment["id"] == 10 and sequence >= 24:
                planned = sequence % 2 == 0
                created = START + timedelta(days=(sequence - 24) // 2 * 7 + (2 if sequence % 2 else 0),
                                             hours=12 if index % 2 else 0)
            if equipment["id"] == 3 and not planned:
                fault_id = 2 if (sequence - sequence // 5) % 10 < 7 else rng.choice([1, 3, 4])
            else:
                fault_id = 13 if planned else (sequence + equipment["id"] * 3) % 12 + 1
            employee_number = rng.choice([number for number in range(1, 16) if number != 11])
            if equipment["id"] == 3 and fault_id == 2 and sequence % 10 == 1:
                employee_number = 4
            if equipment["id"] == 4 and sequence == 4:
                employee_number = 1
            if equipment["id"] == 5 and sequence == 5:
                employee_number = 6
            order = make_order(index, equipment, employees[employee_number], fault_id, created,
                               planned, rng, reference["time_norms"], material_norms,
                               decoy_late=equipment["id"] == 4 and sequence == 4)
            if equipment["id"] == 5 and sequence == 5:
                order["completion"]["materials"][0]["quantity"] *= 4
            orders.append(order)
    repeat_equipment = [item for item in reference["equipment"] if item["id"] != 3]
    for sequence in range(25):
        equipment = repeat_equipment[sequence % 20]
        fault_id = 2 if sequence % 2 else 9
        created = START + timedelta(days=5 + sequence * 3, hours=12 if sequence % 2 else 0)
        index = len(orders) + 1
        base = make_order(index, equipment, employees[11], fault_id, created, False, rng,
                          reference["time_norms"], material_norms)
        orders.append(base)
        if sequence < 10:
            index = len(orders) + 1
            repeat = make_order(index, equipment, employees[sequence % 10 + 1], fault_id,
                                created + timedelta(days=2 if sequence < 7 else 9), False, rng,
                                reference["time_norms"], material_norms)
            repeat["description"] = "Повтор: " + repeat["description"]
            orders.append(repeat)
    return orders


def order_image(index, before=False):
    canvas = Image.new("RGB", (96, 96), (238, 238, 230))
    drawer = ImageDraw.Draw(canvas)
    color = ((index * 31) % 190 + 30, (index * 47) % 160 + 35, (index * 17) % 120 + 50)
    drawer.rectangle((12, 20, 82, 75), outline=color, width=4)
    drawer.ellipse((26, 30, 68, 69), outline=color, width=5)
    drawer.line((0, index % 92, 95, (index * 7) % 92), fill=(90, 90, 90), width=2)
    if before:
        drawer.line((43, 25, 52, 58, 62, 89), fill=(170, 25, 20), width=5)
    return canvas


def write_order_images(orders, output):
    folder = output / "photos" / "orders"
    folder.mkdir(parents=True, exist_ok=True)
    for order in orders:
        order_image(order["id"]).save(folder / f"{order['id']:05}.png")
        if any(photo["kind"] == "before" for photo in order["photos"]):
            order_image(order["id"], before=True).save(folder / f"{order['id']:05}-before.png")


def verification_cases(orders, material_norms):
    cases = []
    categories = [
        ("correct", "accepted", {}),
        ("no_after_photo", "needs_rework", {"missing_after_photo": True}),
        ("excess_material", "accepted_with_remarks", {"excess_material": True}),
        ("wrong_work", "needs_rework", {"works_mismatch": True}),
        ("overtime", "accepted_with_remarks", {"over_norm_time": True}),
        ("missing_code", "needs_rework", {"missing_fault_code": True}),
        ("borderline", "needs_master_review", {"uncertain_match": True}),
        ("unknown_norm", "needs_master_review", {"unknown_norm": True}),
    ]
    schedule = [0] * 30 + [1] * 10 + [3] * 10 + [5] * 10 + [2] * 15 + [4] * 15 + [6] * 15 + [7] * 15
    closed = [order for order in orders if order["work_type"] == "unplanned"]
    norm_by_pair = {(norm["fault_code_id"], norm["material_id"]): norm["quantity"]
                    for norm in material_norms}
    for position, category_index in enumerate(schedule):
        category, verdict, flags = categories[category_index]
        card = json.loads(json.dumps(closed[position]))
        actual_hours = (datetime.fromisoformat(card["completed_at"].replace("Z", "+00:00")) -
                        datetime.fromisoformat(card["started_at"].replace("Z", "+00:00"))).total_seconds() / 3600
        card["normal_hours"] = round(actual_hours * 2, 2)
        card["deadline"] = timestamp(datetime.fromisoformat(card["completed_at"].replace("Z", "+00:00")) + timedelta(hours=1))
        for usage in card["completion"]["materials"]:
            usage["quantity"] = norm_by_pair[(card["completion"]["fault_code_id"], usage["material_id"])]
        if category == "no_after_photo":
            card["photos"] = [photo for photo in card["photos"] if photo["kind"] == "before"]
        elif category == "excess_material":
            card["completion"]["materials"][0]["quantity"] *= 2
        elif category == "wrong_work":
            card["completion"]["work_done"] = "Заменили кабель на соседнем участке; проблему не проверяли."
        elif category == "overtime":
            card["normal_hours"] = 0.25
        elif category == "missing_code":
            card["completion"]["fault_code_id"] = None
        elif category == "borderline":
            card["completion"]["work_done"] = "Провели ремонт узла, проверили работу."
        elif category == "unknown_norm":
            card["normal_hours"] = None
        cases.append({"id": f"V-{position + 1:03}", "category": category, "order": card,
                      "expected_verdict": verdict, "expected_flags": flags,
                      "label_source": "deterministic_rule", "evidence": category})
    return cases


def deadline_cases():
    cases = []
    for index in range(40):
        emergency = index % 5 == 0
        issued = START + timedelta(days=index)
        deadline = issued + timedelta(minutes=45 + index % 3 * 15)
        accept_after = None if index % 4 == 0 else 2 if emergency else 6 if index % 3 else 12
        ticks = [issued + timedelta(minutes=offset) for offset in range(0, 181)]
        notifications = []
        acceptance_limit = 3 if emergency else 10
        if accept_after is None or accept_after > acceptance_limit:
            notifications.append({"recipient": "master", "type": "acceptance_escalation",
                                  "at": timestamp(issued + timedelta(minutes=acceptance_limit))})
        warning_at = deadline - timedelta(minutes=30)
        if issued <= warning_at <= ticks[-1]:
            notifications.append({"recipient": "worker", "type": "deadline_warning", "at": timestamp(warning_at)})
        for overdue_offset in range(0, 181, 30):
            event_at = deadline + timedelta(minutes=overdue_offset)
            if event_at > ticks[-1]:
                continue
            kind = "overdue" if overdue_offset == 0 else "overdue_repeat"
            for recipient in ["worker", "master"]:
                notifications.append({"recipient": recipient, "type": kind, "at": timestamp(event_at)})
            if overdue_offset == 90:
                notifications.append({"recipient": "manager", "type": "long_overdue", "at": timestamp(event_at)})
        cases.append({
            "id": f"D-{index + 1:02}", "order": {
                "number": f"Н-ТЕСТ-{index + 1:02}", "priority": "emergency" if emergency else "normal",
                "issued_at": timestamp(issued), "deadline": timestamp(deadline),
                "accepted_at": timestamp(issued + timedelta(minutes=accept_after)) if accept_after is not None else None,
                "status": "issued" if accept_after is None else "in_progress",
            }, "tick_times": [timestamp(value) for value in ticks],
            "repeat_tick_at": timestamp(ticks[45]), "expected_notifications": notifications,
            "expected_duplicate_count": 0, "thresholds_minutes": {"warning": 30, "acceptance": acceptance_limit,
                                                                 "repeat": 30, "manager": 90},
        })
    return cases


def intake_cases(reference):
    cases = []
    for index in range(40):
        equipment = reference["equipment"][index % 25]
        fault_id = index % 20 + 1
        equipment_name = equipment["name"]
        area_name = reference["areas"][equipment["area_id"] - 1]["name"]
        fault_name = FAULTS[fault_id - 1][1].lower()
        hours = index % 4 + 1
        variants = [
            f"{equipment_name}: {fault_name}, участок {area_name}. Сделать за {hours} ч.",
            f"На {equipment_name} {fault_name}; {area_name}, устранить в течение {hours} ч.",
            f"Оборуд. {equipment_name}: {fault_name}. Участок {area_name}, срок через {hours} ч.",
            f"{area_name}, {equipment_name}: замечен {fault_name}, нужен ремонт за {hours} ч.",
        ]
        phrase = variants[index % len(variants)]
        if index % 7 == 0:
            phrase = phrase.replace("подшипника", "подшипнка")
        if index % 9 == 0:
            phrase = phrase.replace("Участок", "Уч-к").replace("участок", "уч-к")
        cases.append({"id": f"I-{index + 1:02}", "phrase": phrase,
                      "reference_time": timestamp(START + timedelta(days=index)),
                      "expected": {"equipment_id": equipment["id"], "area_id": equipment["area_id"],
                                   "fault_code_id": fault_id, "time_norm_id": fault_id,
                                   "deadline": timestamp(START + timedelta(days=index, hours=index % 4 + 1))},
                      "label_source": "template_parameters"})
    return cases


def assistant_cases(reference, orders):
    templates = [
        ("Какие работы просрочены?", "overdue_orders", "overdue"),
        ("Кто свободен из слесарей?", "available_workers", "free_workers"),
        ("Покажи отчёт по участку {area} за месяц", "area_report", "area_count"),
        ("Какие проблемы на участке {area}?", "area_problems", "unplanned_count"),
        ("Сколько нарядов на участке {area}?", "area_report", "area_count"),
    ]
    cases = []
    for index in range(25):
        area = reference["areas"][index % 4]
        question, tool, metric = templates[index % len(templates)]
        area_orders = [order for order in orders if order["area_id"] == area["id"]]
        arguments = {"area_id": area["id"]} if tool in {"area_report", "area_problems"} else {}
        if "за месяц" in question:
            area_orders = [order for order in area_orders if order["created_at"] >= timestamp(START + timedelta(days=60))]
            arguments.update({"from": timestamp(START + timedelta(days=60)),
                              "to": timestamp(START + timedelta(days=90))})
        value = (len(area_orders) if metric == "area_count" else
                 sum(order["work_type"] == "unplanned" for order in area_orders) if metric == "unplanned_count" else
                 0 if metric == "overdue" else 5 if metric == "free_workers" else None)
        cases.append({"id": f"A-{index + 1:02}", "question": question.format(area=area["name"]),
                      "reference_time": timestamp(START + timedelta(days=90)),
                      "expected_tool": tool, "arguments": arguments,
                      "expected_metric": metric, "expected_value": value,
                      "label_source": "computed_from_snapshot"})
    return cases


def patterns(orders):
    grouped_repairs = defaultdict(list)
    for order in orders:
        if order["work_type"] == "unplanned":
            grouped_repairs[(order["equipment_id"], order["completion"]["fault_code_id"])].append(order)
    repeated_repair_ids = set()
    for repairs in grouped_repairs.values():
        repairs.sort(key=lambda order: order["created_at"])
        for earlier, later in zip(repairs, repairs[1:]):
            earlier_time = datetime.fromisoformat(earlier["created_at"].replace("Z", "+00:00"))
            later_time = datetime.fromisoformat(later["created_at"].replace("Z", "+00:00"))
            if timedelta(0) < later_time - earlier_time <= timedelta(days=7):
                repeated_repair_ids.add(earlier["id"])
    equipment_counts = Counter(order["equipment_id"] for order in orders if order["work_type"] == "unplanned")
    all_counts = sorted(equipment_counts.values())
    k3 = [order for order in orders if order["equipment_id"] == 3 and order["work_type"] == "unplanned"]
    k3_bearing = sum(order["completion"]["fault_code_id"] == 2 for order in k3)
    e11 = [order for order in orders if order["assignee_id"] == 13]
    other_repairs = [order for order in orders if order["work_type"] == "unplanned" and order["assignee_id"] != 13]
    e04 = [order for order in orders if order["assignee_id"] == 6]
    night_b2 = [order for order in orders if order["brigade_id"] == 2 and order["id"] % 2 == 1]
    other = [order for order in orders if not (order["brigade_id"] == 2 and order["id"] % 2 == 1)]
    late = lambda sample: round(sum(order["completed_at"] > order["deadline"] for order in sample) / len(sample), 3)
    anomalies = [
        {"id": "k3_recurrence", "equipment_id": 3, "count": len(k3),
         "median_other_count": all_counts[len(all_counts) // 2], "bearing_share": round(k3_bearing / len(k3), 3)},
        {"id": "e11_repeat_7d", "employee_id": 13, "base_repairs": len(e11),
         "injected_followups": 7, "injected_repeat_rate": round(7 / len(e11), 3),
         "observed_repeats": sum(order["id"] in repeated_repair_ids for order in e11),
         "observed_rate": round(sum(order["id"] in repeated_repair_ids for order in e11) / len(e11), 3),
         "other_worker_rate": round(sum(order["id"] in repeated_repair_ids for order in other_repairs)
                                    / len(other_repairs), 3)},
        {"id": "pump_after_ppr", "equipment_id": 10, "injected_ppr_followups": 12},
        {"id": "night_brigade2_late", "brigade_id": 2, "night_late_rate": late(night_b2),
         "comparison_late_rate": late(other)},
        {"id": "e04_material_overuse", "employee_id": 6, "orders": len(e04),
         "target_material_ids": [1, 6], "injected_multiplier": 2.5},
        {"id": "mill_last_month_growth", "equipment_id": 9,
         "last_month_unplanned": sum(order["work_type"] == "unplanned" and order["created_at"] >= timestamp(START + timedelta(days=60)) for order in orders if order["equipment_id"] == 9),
         "injected_extra_orders": 12},
    ]
    return {"seed": SEED, "period": {"from": timestamp(START), "to": timestamp(START + timedelta(days=90))},
            "patterns": anomalies, "decoys": [
                {"id": "isolated_crusher_spike", "equipment_id": 2, "injected_orders": 3,
                 "expected_detection": False},
                {"id": "single_shift_delay", "brigade_id": 1, "injected_late_orders": 1,
                 "expected_detection": False},
                {"id": "one_large_writeoff", "employee_id": 8, "injected_writeoffs": 1,
                 "expected_detection": False},
            ], "label_source": "generator_code", "limitations": [
                "Доли зависят от всех фоновых заказов; injected_* — точное число внесённых случаев.",
                "Синтетические изображения не являются эталоном качества ремонта.",
            ]}


def write_csv(path, records):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]), extrasaction="ignore")
        writer.writeheader()
        for record in records:
            writer.writerow({key: json.dumps(value, ensure_ascii=False) if isinstance(value, (dict, list)) else value
                             for key, value in record.items()})


def generate(output=BASE / "data", cases_dir=BASE / "eval" / "cases", photo_cases=True):
    rng = random.Random(SEED)
    reference, material_norms = references()
    orders = make_orders(reference, material_norms, rng)
    snapshot = Snapshot.model_validate({**reference, "material_norms": material_norms, "orders": orders})
    output.mkdir(parents=True, exist_ok=True)
    write_json(output / "snapshot.json", snapshot.model_dump(mode="json"))
    write_json(output / "material_norms.json", material_norms)
    for collection, records in {**reference, "material_norms": material_norms, "orders": orders}.items():
        write_csv(output / "csv" / f"{collection}.csv", records)
    write_order_images(orders, output)
    write_json(cases_dir / "verification.json", verification_cases(orders, material_norms))
    write_json(cases_dir / "deadlines.json", deadline_cases())
    write_json(cases_dir / "intake.json", intake_cases(reference))
    write_json(cases_dir / "assistant.json", assistant_cases(reference, orders))
    truth = patterns(orders)
    write_json(BASE / "data_gen" / "ground_truth" / "patterns.json", truth)
    write_json(cases_dir / "analytics.json", truth)
    if photo_cases:
        from .photos import generate_photo_cases
        generate_photo_cases(cases_dir)
    return {"orders": len(orders), "verification": 120, "deadlines": 40,
            "intake": 40, "assistant": 25}


if __name__ == "__main__":
    print(json.dumps(generate(), ensure_ascii=False))
