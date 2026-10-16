from fastapi import APIRouter, Depends
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.database import get_db
from app.config import get_settings
from app.models import Employee, ZupDelivery
from app.modules import integrations
from app.security import require_hr

router = APIRouter(prefix="/integrations/zup", tags=["integrations"], dependencies=[Depends(require_hr)])


@router.get("")
def status(db: Session = Depends(get_db)):
    integrations.zup_adapter().employees()
    settings = get_settings()
    counts = dict(db.execute(select(ZupDelivery.status, func.count()).group_by(ZupDelivery.status)).all())
    return {"connected": True, "mode": f"{settings.zup_mode}_http", "contract": "jana-zup-v1",
            "auth_type": settings.zup_auth_type, "tls_verified": settings.zup_tls_verified,
            "mapped_employees": db.scalar(select(func.count()).select_from(Employee).where(Employee.zup_id.is_not(None))),
            "pending": counts.get("pending", 0), "error": counts.get("error", 0), "synced": counts.get("synced", 0)}
