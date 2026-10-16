"""Explicit, repeatable demo provisioning. Never called by import or API startup."""
import json
from dataclasses import asdict
from datetime import date

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import get_settings
from app.database import get_engine
from app.models import Course, CourseAssignment, Employee, KnowledgeDocument, LeaveRequest, RequestHistory
from app.modules.audit import record
from app.modules.integrations import zup_adapter
from app.modules.notifications import notify
from app.security import password_hash
from app.zup_calendar import calculate_days


def seed():
    settings = get_settings()
    if settings.zup_mode != "mock":
        raise SystemExit("Демо-seed отключён при ZUP_MODE=real: реальные профили и роли импортируются отдельной согласованной процедурой.")
    password = settings.demo_password
    if not password:
        raise SystemExit("Задайте DEMO_PASSWORD (минимум 12 символов). Seed не изменяет существующие пароли.")
    with Session(get_engine()) as db:
        # Managers must exist before inserting direct reports (FK enabled).
        snapshots = zup_adapter().employees()
        for snapshot in sorted(snapshots, key=lambda e: e.manager_id is not None):
            if db.get(Employee, snapshot.id) is None:
                db.add(Employee(**asdict(snapshot), password_hash=password_hash.hash(password)))
                db.flush()
        old_course_content = "Добро пожаловать в JanaМен!\n\nПрофиль содержит демонстрационные кадровые данные из mock 1С:ЗУП. Эти поля доступны только для чтения.\n\nЧтобы запросить отпуск, откройте «Заявки», укажите даты и отправьте заявку. В этом прототипе руководитель или HR принимает решение, а вы получаете уведомление. Остаток отпуска в MVP не пересчитывается.\n\nAI Jana ищет ответы только в подготовленной демонстрационной базе и показывает источник. Для реального кадрового вопроса обратитесь в HR. Не отправляйте чужие персональные данные."
        previous_course_content = "Добро пожаловать в JanaМен!\n\nПрофиль содержит демонстрационные кадровые данные из mock 1С:ЗУП. Эти поля доступны только для чтения.\n\nЧтобы запросить отпуск, откройте «Заявки», укажите даты и отправьте заявку. Сначала решение принимает непосредственный руководитель, затем HR выполняет финальную проверку. Отклонение на любом этапе завершает процесс. Остаток отпуска в MVP не пересчитывается.\n\nAI Jana ищет ответы только в подготовленной демонстрационной базе и показывает источник. Для реального кадрового вопроса обратитесь в HR. Не отправляйте чужие персональные данные."
        ledger_course_content = "Добро пожаловать в JanaМен!\n\nПрофиль содержит вымышленные данные из mock 1С:ЗУП и доступен только для чтения.\n\nЧтобы запросить отпуск, откройте «Заявки», укажите даты и отправьте заявку. Период считается в календарных днях, включая обе даты. Сначала решение принимает непосредственный руководитель, затем HR выполняет финальную проверку. Только финальное одобрение списывает дни из доступного остатка; ожидающие и отклонённые заявки его не меняют.\n\nAI Jana ищет ответы только в подготовленной демонстрационной базе и показывает источник. Для реального кадрового вопроса обратитесь в HR. Не отправляйте чужие персональные данные."
        course_content = ledger_course_content.replace("в календарных днях, включая обе даты.", "в календарных днях, включая обе даты, без национальных и государственных праздников Казахстана. Расчёт возвращает отдельный HTTP mock 1С:ЗУП.")
        course = db.get(Course, 1)
        if course is None:
            db.add(Course(id=1, title="Знакомство с JanaМен", description="Ваш первый день в цифровом HR-пространстве", duration_minutes=8,
                content=course_content,
                question="Где посмотреть решение по заявке?", options_json=json.dumps(["В карточке заявки и уведомлениях", "Только позвонить курьеру", "Изменить профиль самостоятельно"], ensure_ascii=False), correct_index=0))
            db.flush()
        elif course.content in (old_course_content, previous_course_content, ledger_course_content):
            course.content = course_content
        for employee in db.scalars(select(Employee)).all():
            if db.scalar(select(CourseAssignment).where(CourseAssignment.employee_id == employee.id, CourseAssignment.course_id == 1)) is None:
                db.add(CourseAssignment(employee_id=employee.id, course_id=1))
                notify(db, employee.id, "course_assigned", "Вам назначен курс", "Начните с курса «Знакомство с JanaМен».")
                record(db, 3, "course.assigned", "employee", employee.id)
        knowledge = [
            (1, "Как подать заявку на отпуск", "Заявки", "В прототипе откройте «Заявки», выберите даты и отправьте заявку. Период рассчитывает HTTP mock 1С:ЗУП: календарные дни включительно без национальных и государственных праздничных дат Казахстана; обычные и перенесённые выходные учитываются. Сначала её согласует непосредственный руководитель, затем финальное решение принимает HR. Только финальное одобрение списывает дни; ожидающие и отклонённые заявки не меняют остаток. Это демонстрационное правило, а не кадровая политика Jana Post.", "отпуск,заявк,статус,соглас,остат,дн", "all"),
            (2, "Обучение в Jana Academy", "Academy", "Назначенные курсы находятся в разделе Academy. Прочитайте материал, отметьте прогресс и ответьте на контрольный вопрос. После правильного ответа курс отмечается завершённым и появляется уведомление.", "курс,обуч,academy,академ,прогресс,тест", "all"),
            (3, "Изменение данных профиля", "Профиль", "Кадровые поля профиля в прототипе доступны только для чтения. Данные вымышленные и загружены из mock 1С:ЗУП. Для исправления реальных данных необходимо обратиться в HR; реальная интеграция пока не подключена.", "профил,должност,подраздел,данны,исправ,руководител", "all"),
            (4, "Обращение в HR", "Помощь", "Если в демонстрационной базе нет ответа, обратитесь к HR-партнёру по принятому в вашей компании каналу. Реальные адреса и контакты компании в прототип не включены.", "контакт,связ,обрат", "all"),
            (5, "Проверка HR-действий", "HR", "В демонстрационном API /api/audit доступен журнал входов, решений по заявкам, назначений и завершений курсов. Доступ ограничен ролью HR. Это техническая функция прототипа.", "аудит,журнал", "hr_admin"),
            (6, "Как работает HR-помощник", "Помощник", "Помощник в первой версии ищет подготовленные фрагменты демонстрационной базы знаний и показывает источник. Генеративная модель не подключена. Он не получает персональные данные, не меняет заявки и не принимает кадровые решения. Если надёжного ответа нет, обратитесь в HR.", "помощник,ассистент,hr", "all"),
        ]
        for did, title, section, content, keywords, scope in knowledge:
            document = db.get(KnowledgeDocument, did)
            if document is None:
                db.add(KnowledgeDocument(id=did, title=title, section=section, content=content, keywords=keywords, access_scope=scope))
            elif did == 1 and document.content in (
                "В прототипе откройте «Заявки», выберите даты и отправьте заявку. Период считается в календарных днях, включая начало и конец. Сначала её согласует непосредственный руководитель, затем финальное решение принимает HR. Только финальное одобрение списывает дни; ожидающие и отклонённые заявки не меняют остаток. Это демонстрационное правило, а не кадровая политика Jana Post.",
                "В прототипе откройте «Заявки», выберите даты и отправьте заявку. Решение принимает руководитель или HR. Статус и история доступны в карточке, результат — в уведомлениях. Это демонстрационный процесс, не кадровая политика Jana Post. Остаток отпуска не пересчитывается.",
                "В прототипе откройте «Заявки», выберите даты и отправьте заявку. Сначала её согласует непосредственный руководитель, затем финальное решение принимает HR. Отклонение на любом этапе завершает процесс. Статус и история доступны в карточке, результат — в уведомлениях. Это демонстрационный процесс, не кадровая политика Jana Post. Остаток отпуска не пересчитывается.",
            ):
                document.content = content
        # Seed several states without overwriting existing user work.
        for key, status, start, end in [
            ("seed-submitted", "submitted", date(2026, 11, 2), date(2026, 11, 6)),
            ("seed-approved", "approved", date(2026, 10, 1), date(2026, 10, 3)),
            ("seed-rejected", "rejected", date(2026, 9, 1), date(2026, 9, 2)),
        ]:
            if db.scalar(select(LeaveRequest).where(LeaveRequest.employee_id == 1, LeaveRequest.idempotency_key == key)) is None:
                # Imported historical approvals are assumed to be reflected in the
                # source snapshot already, so provisioning never backfills deductions.
                request = LeaveRequest(employee_id=1, start_date=start, end_date=end, comment="Демонстрационная заявка", status=status, version=1 if status == "submitted" else 3 if status == "approved" else 2, idempotency_key=key, payload_hash="seed")
                calculation = calculate_days(start, end)
                request.days_count = calculation["days_count"]
                request.excluded_dates_json = json.dumps(calculation["excluded_dates"])
                request.calendar_version = "legacy-unquoted"
                db.add(request)
                db.flush()
                db.add(RequestHistory(request_id=request.id, actor_id=1, status="submitted", comment="Демо-данные"))
                record(db, 1, "request.created", "request", request.id)
                if status == "approved":
                    db.add(RequestHistory(request_id=request.id, actor_id=2, status="manager_approved", comment="Согласовано руководителем"))
                    db.add(RequestHistory(request_id=request.id, actor_id=3, status="approved", comment="Финально согласовано HR"))
                    record(db, 2, "request.manager_approved", "request", request.id)
                    record(db, 3, "request.approved", "request", request.id)
                    notify(db, 1, "request_status", "Демонстрационное решение по заявке", f"Заявка №{request.id}: {status}")
                elif status == "rejected":
                    db.add(RequestHistory(request_id=request.id, actor_id=2, status=status, comment="Отклонено руководителем"))
                    record(db, 2, f"request.{status}", "request", request.id)
                    notify(db, 1, "request_status", "Демонстрационное решение по заявке", f"Заявка №{request.id}: {status}")
        db.commit()
    print("Демо-данные готовы. Существующие записи и пароли сохранены.")


if __name__ == "__main__":
    seed()
