from datetime import date

from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models import Employee, LeaveDeduction, ZupDelivery
from app.config import get_settings
from app.modules import integrations
from app.schemas import Profile


def require_zup_id(employee: Employee) -> str:
    if not employee.zup_id:
        raise HTTPException(409, "Профиль не сопоставлен с сотрудником 1С:ЗУП; обратитесь в HR")
    return employee.zup_id


def available_leave_balance(db: Session, employee: Employee, snapshot=None) -> int:
    snapshot = snapshot or integrations.zup_adapter().balance(require_zup_id(employee))
    # A response lost after registration may leave local status pending although
    # the remote balance is already reduced. Reconcile by applied command keys.
    deductions = db.execute(select(LeaveDeduction.days, ZupDelivery.command_key).outerjoin(
        ZupDelivery, ZupDelivery.request_id == LeaveDeduction.request_id
    ).where(LeaveDeduction.employee_id == employee.id)).all()
    outstanding = sum(days for days, key in deductions if key not in snapshot.applied_commands)
    return snapshot.balance - outstanding


def quote_leave(db: Session, employee: Employee, start: date, end: date):
    quote = integrations.zup_adapter().calculate(require_zup_id(employee), start, end)
    if quote.days_count == 0:
        raise HTTPException(422, "В выбранном периоде нет списываемых дней отпуска")
    return quote, available_leave_balance(db, employee, quote)


def present_profile(db: Session, employee: Employee) -> Profile:
    return Profile.model_validate(employee).model_copy(
        update={"leave_balance": available_leave_balance(db, employee),
                "data_source": "zup" if get_settings().zup_mode == "real" else "mock_zup"}
    )
