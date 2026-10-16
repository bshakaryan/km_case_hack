from datetime import datetime, timedelta, timezone

import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pwdlib import PasswordHash
from sqlalchemy.orm import Session

from app.config import get_settings
from app.database import get_db
from app.models import Employee

password_hash = PasswordHash.recommended()
bearer = HTTPBearer(auto_error=False)


def issue_token(employee_id: int) -> str:
    settings = get_settings()
    now = datetime.now(timezone.utc)
    return jwt.encode({"sub": str(employee_id), "iat": now, "exp": now + timedelta(minutes=settings.token_minutes)}, settings.jwt_secret, algorithm="HS256")


def current_user(credentials: HTTPAuthorizationCredentials | None = Depends(bearer), db: Session = Depends(get_db)) -> Employee:
    unauthorized = HTTPException(401, "Войдите в систему", headers={"WWW-Authenticate": "Bearer"})
    if credentials is None:
        raise unauthorized
    try:
        payload = jwt.decode(credentials.credentials, get_settings().jwt_secret, algorithms=["HS256"], options={"require": ["sub", "iat", "exp"]})
        employee_id = int(payload["sub"])
    except (jwt.PyJWTError, ValueError, TypeError):
        raise unauthorized
    employee = db.get(Employee, employee_id)
    if employee is None:
        raise unauthorized
    return employee


def visible_employee_ids(db: Session, user: Employee):
    from sqlalchemy import or_, select
    query = select(Employee.id)
    if user.role == "employee":
        query = query.where(Employee.id == user.id)
    elif user.role == "manager":
        query = query.where(or_(Employee.id == user.id, Employee.manager_id == user.id))
    return query


def require_hr(user: Employee = Depends(current_user)):
    if user.role != "hr_admin":
        raise HTTPException(403, "Доступ только для HR")
    return user
