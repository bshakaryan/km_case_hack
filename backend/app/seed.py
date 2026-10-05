"""Idempotent synthetic 90-day demonstration dataset. Never real personnel data."""
import random
from datetime import timedelta
from sqlalchemy import select, text
from .models import AIAssessment, Area, Brigade, Employee, Equipment, FaultCode, Material, MaterialWriteoff, Order, OrderEvent, TimeNorm, utcnow
from .security import hash_pin


def seed_database(db):
    if db.scalar(select(Employee.id).limit(1)):
        repair_sequences(db)
        return
    rng = random.Random(42)
    now = utcnow()
    areas = ["Дробильно-сортировочный комплекс", "Обогатительная фабрика", "Транспортный участок", "Энергетический участок"]
    db.add_all([Area(id=i + 1, name=name) for i, name in enumerate(areas)])
    db.add_all([Brigade(id=i + 1, name=f"Бригада №{i + 1}") for i in range(3)])
    db.flush()
    people = [
        (1, "Арман Сериков", "master", "master", "Мастер смены", None),
        (2, "Олег Белов", "master2", "master", "Мастер смены", None),
        (3, "Мария Иванова", "manager", "manager", "Начальник производства", None),
        (4, "Администратор демо", "admin", "admin", "Администратор", None),
    ]
    worker_names = ["Данияр Садыков", "Алексей Ким", "Нурлан Омаров", "Сергей Волков", "Азамат Ермеков", "Иван Соколов", "Тимур Алиев", "Максим Орлов", "Руслан Жуков", "Дмитрий Смирнов", "Ерлан Муратов", "Павел Фролов", "Андрей Попов", "Бауыржан Исаев", "Виктор Кузнецов"]
    specialties = ["Слесарь-ремонтник", "Электромонтёр", "Механик"]
    for i, name in enumerate(worker_names):
        people.append((i + 5, name, "worker" if i == 0 else f"worker{i + 1}", "worker", specialties[i % 3], i // 5 + 1))
    for id_, name, login, role, specialty, brigade_id in people:
        db.add(Employee(id=id_, name=name, login=login, role=role, specialty=specialty, brigade_id=brigade_id, grade=4 + id_ % 3 if role == "worker" else 0, on_shift=id_ != 19, pin_hash=hash_pin("1234")))
    equipment_names = ["Конвейер КЛ-01", "Конвейер КЛ-02", "Дробилка ЩД-01", "Грохот ГИ-01", "Питатель ПЛ-01", "Дробилка КСД-02", "Сепаратор СМ-01", "Насос НС-01", "Насос НС-02", "Сушильный барабан СБ-01", "Вентилятор ВЦ-01", "Циклон ЦН-01", "Фильтр ФР-01", "Конвейер КЛ-03", "Погрузчик ПК-01", "Электровоз ЭЛ-01", "Тельфер ТЭ-01", "Кран КМ-01", "Компрессор КВ-01", "Трансформатор ТМ-01", "Щит ЩР-01", "Двигатель ДВ-01", "Подстанция ПС-01", "Насос НС-03", "Генератор ГД-01"]
    for i, name in enumerate(equipment_names):
        db.add(Equipment(id=i + 1, name=name, inventory_number=f"КМ-{1001 + i}", area_id=min(i // 7 + 1, 4), type=name.split()[0], criticality="high" if i % 3 == 0 else "medium"))
    faults = ["Износ подшипника", "Обрыв приводного ремня", "Перегрев двигателя", "Вибрация узла", "Утечка масла", "Повреждение кабеля", "Сбой датчика", "Износ ролика", "Засорение фильтра", "Ослабление крепежа", "Нарушение центровки", "Износ уплотнения", "Обрыв цепи", "Повреждение футеровки", "Отказ контактора", "Засорение трубопровода", "Износ тормозной колодки", "Коррозия корпуса", "Сбой автоматики", "Плановое обслуживание"]
    db.add_all([FaultCode(id=i + 1, code=f"F{i + 1:02}", name=name) for i, name in enumerate(faults)])
    material_names = ["Подшипник 6205", "Подшипник 6308", "Ремень клиновой А-1250", "Ролик конвейерный", "Масло И-40А", "Смазка Литол-24", "Уплотнение 40×60", "Болт М12×50", "Гайка М12", "Шайба М12", "Кабель ВВГ 3×2,5", "Датчик индуктивный", "Фильтр масляный", "Фильтр воздушный", "Контактор КМЭ", "Предохранитель 32А", "Электрод 3 мм", "Прокладка паронитовая", "Муфта соединительная", "Цепь приводная", "Шланг гидравлический", "Манжета 50×70", "Колодка тормозная", "Лента конвейерная", "Очиститель контактов", "Хомут 25 мм", "Клемма 6 мм²", "Изолента ПВХ", "Термопаста", "Сальник 30×52", "Анкер М16", "Шпилька М10", "Редукторное масло", "Щетка двигателя", "Реле перегрузки", "Вентиль 25 мм", "Труба стальная", "Фланец 50 мм", "Рукав напорный", "Герметик"]
    db.add_all([Material(id=i + 1, name=name, unit="л" if i in [4, 32] else "м" if i in [10, 23, 36, 38] else "кг" if i in [5, 16] else "шт") for i, name in enumerate(material_names)])
    db.add_all([TimeNorm(id=i + 1, name=name, hours=hours) for i, (name, hours) in enumerate([("Замена подшипника", 2), ("Плановое обслуживание", 3), ("Замена ролика", 1.5), ("Диагностика электродвигателя", 2.5), ("Устранение утечки", 1), ("Капитальный ремонт", 8)])])
    db.flush()
    tasks = ["Замена подшипника привода", "Плановый осмотр оборудования", "Устранение вибрации узла", "Замена конвейерного ролика", "Проверка электрических соединений", "Техническое обслуживание", "Устранение утечки масла", "Восстановление защитного ограждения"]
    for i in range(540):
        age_hours = (i / 540) * 89 * 24 + 6
        created = now - timedelta(hours=age_hours)
        equipment_id = 1 if i % 7 == 0 else (7 if i % 11 == 0 else rng.randint(1, 25))
        planned = i % 5 in (0, 1, 2)
        normal = rng.choice([1.5, 2, 3, 4, 6])
        assignee = rng.randint(5, 19)
        elapsed = normal * rng.uniform(0.6, 1.7)
        deadline = created + timedelta(hours=normal + 1)
        completed = created + timedelta(hours=elapsed)
        title = tasks[i % len(tasks)]
        if equipment_id == 1 and not planned:
            title = "Повторный износ роликов конвейера"
        if equipment_id == 7 and not planned:
            title = "Вибрация после обслуживания сепаратора"
        score = round(rng.uniform(3.5, 5), 1)
        material_id = 4 if equipment_id == 1 else rng.randint(1, 40)
        material = db.get(Material, material_id)
        order = Order(number=f"Н-{created.year}-{i + 1:05}", title=title, description="Демонстрационный наряд. Выполнить работы с соблюдением технологической карты и правил безопасности.", work_type="planned" if planned else "unplanned", area_id=min((equipment_id - 1) // 7 + 1, 4), equipment_id=equipment_id, assignee_id=assignee, brigade_id=(assignee - 5) // 5 + 1, master_id=1 + i % 2, priority="planned" if planned else rng.choice(["normal", "high", "emergency"]), status="closed", deadline=deadline, created_at=created, started_at=created + timedelta(minutes=10), completed_at=completed, closed_at=completed + timedelta(minutes=12), normal_hours=normal, downtime_minutes=round(elapsed * 60) if not planned else 0, score=score, comment="Синтетические данные для демонстрации", completion={"work_done": "Работы выполнены, оборудование проверено под нагрузкой.", "fault_code_id": 20 if planned else 8 if equipment_id == 1 else rng.randint(1, 19), "comment": "Контрольный запуск выполнен", "materials": [{"material_id": material_id, "name": material.name, "unit": material.unit, "quantity": float(8 if equipment_id == 1 else rng.randint(1, 3))}]}, ai_review={"verdict": "passed", "score": 4.5, "explanation": "Демонстрационная проверка по формальным признакам. Изображения не анализировались.", "is_stub": True, "master_score": score})
        db.add(order)
        db.flush()
        events = [("issue", None, "issued", created, order.master_id), ("accept", "issued", "accepted", created + timedelta(minutes=5), assignee), ("start", "accepted", "in_progress", order.started_at, assignee), ("complete", "in_progress", "completed", completed, assignee), ("ai_review", "completed", "ai_review", completed, order.master_id), ("close", "ai_review", "closed", order.closed_at, order.master_id)]
        if i % 13 == 0:
            events.insert(-1, ("rework", "ai_review", "rework", completed, order.master_id))
            events.insert(-1, ("start", "rework", "in_progress", completed, assignee))
            events.insert(-1, ("complete", "in_progress", "completed", completed + timedelta(minutes=5), assignee))
            events.insert(-1, ("ai_review", "completed", "ai_review", completed + timedelta(minutes=5), order.master_id))
        db.add_all([OrderEvent(order_id=order.id, action=a, from_status=f, to_status=t, created_at=when, actor_id=actor, comment="Демонстрационное событие") for a, f, t, when, actor in events])
    active_statuses = ["in_progress", "issued", "paused", "accepted", "queued", "ai_review", "rework", "issued", "in_progress", "issued", "queued", "accepted", "issued", "rejected", "issued", "issued"]
    for i, status in enumerate(active_statuses):
        equipment_id = [1, 3, 8, 14, 20, 7, 2, 17, 23, 9, 4, 21, 15, 11, 25, 6][i]
        created = now - timedelta(minutes=30 + i * 9)
        order = Order(number=f"Н-{now.year}-{541 + i:05}", title=tasks[i % len(tasks)], description="Проверить состояние оборудования, устранить выявленные неисправности. Перед началом работ оформить допуск.", work_type="planned" if i % 3 == 0 else "unplanned", area_id=min((equipment_id - 1) // 7 + 1, 4), equipment_id=equipment_id, assignee_id=5 + i % 14, brigade_id=(i % 14) // 5 + 1, master_id=1 + i % 2, priority=["emergency", "high", "normal", "planned"][i % 4], status=status, deadline=now + timedelta(minutes=[-40, 20, -15, 180, 90, 45, 60, 210][i % 8]), created_at=created, started_at=created + timedelta(minutes=10) if status in ["in_progress", "paused", "ai_review", "rework"] else None, normal_hours=[2, 3, 1.5, 4][i % 4], downtime_minutes=90 if i == 0 else 45 if i == 2 else 0, comment="Демонстрационный наряд текущей смены")
        if status == "ai_review":
            order.completed_at = now - timedelta(minutes=5)
            order.completion = {"work_done": "Заменен изношенный узел, выполнен контрольный запуск", "fault_code_id": 1, "comment": "Оборудование исправно", "materials": []}
            order.ai_review = {"verdict": "needs_attention", "score": 4, "explanation": "Заглушка ИИ: требуется осмотр мастером; реального анализа фотографий нет.", "is_stub": True, "master_score": None}
        db.add(order)
        db.flush()
        db.add(OrderEvent(order_id=order.id, action="issue", from_status=None, to_status="issued", actor_id=order.master_id, created_at=created, comment="Наряд выдан"))
        if status != "issued":
            db.add(OrderEvent(order_id=order.id, action="seed_state", from_status="issued", to_status=status, actor_id=order.assignee_id, created_at=created + timedelta(minutes=10), comment="Начальное демонстрационное состояние"))
    db.flush()
    for order in db.scalars(select(Order)):
        for usage in (order.completion or {}).get("materials", []):
            db.add(MaterialWriteoff(order_id=order.id, material_id=usage["material_id"], quantity=usage["quantity"], author_id=order.assignee_id, created_at=order.completed_at))
        if order.ai_review:
            db.add(AIAssessment(order_id=order.id, created_at=order.completed_at, **order.ai_review))
    db.commit()
    repair_sequences(db)


def repair_sequences(db):
    """Explicit demo IDs must not leave PostgreSQL serial sequences behind."""
    if db.bind.dialect.name == "postgresql":
        for model in [Area, Brigade, Employee, Equipment, FaultCode, Material, TimeNorm]:
            table = model.__tablename__
            db.execute(text(f"SELECT setval(pg_get_serial_sequence('{table}', 'id'), GREATEST(COALESCE((SELECT MAX(id) FROM {table}), 1), COALESCE(pg_sequence_last_value(pg_get_serial_sequence('{table}', 'id')::regclass), 1)), true)"))
        db.commit()
