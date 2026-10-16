from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import Employee
from app.modules.audit import record
from app.modules.leave_balance import present_profile
from app.schemas import Login, Profile, Token
from app.security import current_user, issue_token, password_hash

router = APIRouter(tags=["auth"])
# Equal-cost verification also for unknown accounts.
dummy_hash = password_hash.hash("unknown-account-dummy-value")


@router.post("/auth/login", response_model=Token)
def login(data: Login, db: Session = Depends(get_db)):
    user = db.scalar(select(Employee).where(Employee.email == data.email.strip().lower()))
    valid = password_hash.verify(data.password, user.password_hash if user else dummy_hash)
    if not user or not valid:
        raise HTTPException(401, "Неверная почта или пароль")
    record(db, user.id, "auth.login", "employee", user.id)
    db.commit()
    return Token(access_token=issue_token(user.id))


@router.get("/me", response_model=Profile)
def me(user: Employee = Depends(current_user), db: Session = Depends(get_db)):
    return present_profile(db, user)
