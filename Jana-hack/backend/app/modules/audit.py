from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import AuditEvent, Employee
from app.schemas import AuditOut
from app.security import require_hr

router = APIRouter(prefix="/audit", tags=["audit"])


def record(db: Session, actor_id: int, action: str, entity_type: str, entity_id: int):
    db.add(AuditEvent(actor_id=actor_id, action=action, entity_type=entity_type, entity_id=entity_id))


@router.get("", response_model=list[AuditOut])
def events(user: Employee = Depends(require_hr), db: Session = Depends(get_db)):
    return db.scalars(select(AuditEvent).order_by(AuditEvent.id.desc()).limit(200)).all()
