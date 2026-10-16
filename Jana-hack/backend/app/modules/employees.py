from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import Employee
from app.modules.leave_balance import present_profile
from app.schemas import Profile
from app.security import current_user, visible_employee_ids

router = APIRouter(prefix="/employees", tags=["employees"])


@router.get("", response_model=list[Profile])
def employees(user: Employee = Depends(current_user), db: Session = Depends(get_db)):
    found = db.scalars(select(Employee).where(Employee.id.in_(visible_employee_ids(db, user))).order_by(Employee.id)).all()
    return [present_profile(db, employee) for employee in found]


@router.get("/{employee_id}", response_model=Profile)
def employee(employee_id: int, user: Employee = Depends(current_user), db: Session = Depends(get_db)):
    found = db.scalar(select(Employee).where(Employee.id == employee_id, Employee.id.in_(visible_employee_ids(db, user))))
    if found is None:
        raise HTTPException(404, "Профиль не найден")
    return present_profile(db, found)
