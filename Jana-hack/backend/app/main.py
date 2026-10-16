from fastapi import FastAPI, Depends
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text
from sqlalchemy.orm import Session

from app.config import get_settings
from app.database import get_db
from app.modules import academy, assistant, audit, auth, employees, notifications, requests, zup

app = FastAPI(title="JanaМен Digital HR", version="0.2.0", description="Демонстрационный HR-прототип. Кадровые данные и база знаний вымышленные.")
app.add_middleware(CORSMiddleware, allow_origins=get_settings().cors_origins.split(","), allow_credentials=False, allow_methods=["GET", "POST", "PATCH"], allow_headers=["Authorization", "Content-Type", "Idempotency-Key"])
for module in (auth, employees, requests, academy, notifications, assistant, audit, zup):
    app.include_router(module.router, prefix="/api")


@app.get("/api/health", tags=["health"])
def health(db: Session = Depends(get_db)):
    db.execute(text("SELECT 1"))
    return {"status": "ok"}
