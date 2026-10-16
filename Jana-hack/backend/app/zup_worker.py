"""Persistent outbox polling; multiple workers are safe through row locks."""
import logging
import time

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.database import get_engine
from app.models import ZupDelivery, utcnow
from app.modules.zup_sync import deliver


def run_once():
    with Session(get_engine(), expire_on_commit=False) as db:
        ids = db.scalars(select(ZupDelivery.request_id).where(
            ZupDelivery.status != "synced", ZupDelivery.next_attempt_at <= utcnow()
        ).order_by(ZupDelivery.id).limit(50)).all()
    for request_id in ids:
        with Session(get_engine(), expire_on_commit=False) as db:
            deliver(db, request_id)


if __name__ == "__main__":
    while True:
        try:
            run_once()
        except Exception:
            logging.error("ZUP delivery iteration failed; will retry")
        time.sleep(5)
