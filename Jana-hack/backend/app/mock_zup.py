"""Independent HTTP simulator of a custom 1C HTTP extension; never a real 1C API."""
import hashlib
import hmac
import json
import os
import sqlite3
from contextlib import asynccontextmanager, contextmanager
from datetime import date
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import Field

from app.modules.integrations import DemoZupFixtures
from app.schemas import RequestCreate
from app.zup_calendar import calculate_days

PREFIX = "/hs/jana/v1"


class QuoteInput(RequestCreate):
    employee_id: str = Field(min_length=1, max_length=100)


class DocumentInput(QuoteInput):
    days_count: int = Field(gt=0)
    calendar_version: str


def create_mock_app(database_path: str, token: str) -> FastAPI:
    if len(token) < 32:
        raise ValueError("ZUP_API_TOKEN должен содержать минимум 32 символа")

    @contextmanager
    def connect():
        db = sqlite3.connect(database_path, timeout=20)
        db.row_factory = sqlite3.Row
        try:
            with db:
                yield db
        finally:
            db.close()

    @asynccontextmanager
    async def lifespan(_):
        Path(database_path).parent.mkdir(parents=True, exist_ok=True)
        with connect() as db:
            db.execute("CREATE TABLE IF NOT EXISTS balances (employee_id TEXT PRIMARY KEY, initial_days INTEGER NOT NULL)")
            db.execute("CREATE TABLE IF NOT EXISTS documents (command_key TEXT PRIMARY KEY, payload_hash TEXT NOT NULL, employee_id TEXT NOT NULL, days INTEGER NOT NULL, reference TEXT NOT NULL, start_date TEXT NOT NULL, end_date TEXT NOT NULL)")
            for employee in DemoZupFixtures().employees():
                db.execute("INSERT OR IGNORE INTO balances VALUES (?, ?)", (employee.zup_id, employee.leave_balance))
        yield

    service = FastAPI(title="Mock 1С:ЗУП · demonstration HTTP extension", lifespan=lifespan)

    def authorize(authorization: Annotated[str | None, Header()] = None):
        if not hmac.compare_digest(authorization or "", f"Bearer {token}"):
            raise HTTPException(401, "Требуется сервисный токен")

    def balance(db, employee_id):
        employee = db.execute("SELECT initial_days FROM balances WHERE employee_id=?", (employee_id,)).fetchone()
        if employee is None:
            raise HTTPException(404, "Сотрудник не найден в mock 1С:ЗУП")
        documents = db.execute("SELECT command_key,days FROM documents WHERE employee_id=?", (employee_id,)).fetchall()
        return {"employee_id": employee_id, "balance": employee["initial_days"] - sum(row["days"] for row in documents),
                "applied_commands": [row["command_key"] for row in documents], "source": "mock_zup_http"}

    @service.get("/health")
    def health():
        with connect() as db:
            db.execute("SELECT 1 FROM balances LIMIT 1")
        return {"status": "ok", "mode": "mock_zup_http"}

    @service.get(PREFIX + "/employees", dependencies=[Depends(authorize)])
    def employees():
        from dataclasses import asdict
        return [asdict(employee) for employee in DemoZupFixtures().employees()]

    @service.get(PREFIX + "/employees/{employee_id}/leave-balance", dependencies=[Depends(authorize)])
    def employee_balance(employee_id: str):
        with connect() as db:
            return balance(db, employee_id)

    @service.post(PREFIX + "/leave/calculate", dependencies=[Depends(authorize)])
    def calculate(data: QuoteInput):
        with connect() as db:
            current = balance(db, data.employee_id)
            if db.execute("SELECT 1 FROM documents WHERE employee_id=? AND start_date<=? AND end_date>=?", (data.employee_id, data.end_date.isoformat(), data.start_date.isoformat())).fetchone():
                raise HTTPException(409, "Период пересекается с отпуском в mock 1С:ЗУП")
        try:
            result = calculate_days(data.start_date, data.end_date)
        except ValueError as error:
            raise HTTPException(422, str(error))
        return {**result, **current}

    @service.post(PREFIX + "/leave/documents", dependencies=[Depends(authorize)], status_code=201)
    def register(data: DocumentInput, idempotency_key: Annotated[str, Header(min_length=8, max_length=128)]):
        digest = hashlib.sha256(data.model_dump_json().encode()).hexdigest()
        with connect() as db:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT * FROM documents WHERE command_key=?", (idempotency_key,)).fetchone()
            if previous:
                if previous["payload_hash"] != digest:
                    raise HTTPException(409, "Ключ команды уже использован с другим телом")
                return {"reference": previous["reference"], "command_key": idempotency_key, "status": "registered"}
            try:
                calculation = calculate_days(data.start_date, data.end_date)
            except ValueError as error:
                raise HTTPException(422, str(error))
            if data.days_count != calculation["days_count"] or data.calendar_version != calculation["calendar_version"]:
                raise HTTPException(409, "Расчёт не совпадает с календарём mock 1С:ЗУП")
            if balance(db, data.employee_id)["balance"] < data.days_count:
                raise HTTPException(409, "В mock 1С:ЗУП недостаточно дней")
            overlap = db.execute("SELECT 1 FROM documents WHERE employee_id=? AND start_date<=? AND end_date>=?", (data.employee_id, data.end_date.isoformat(), data.start_date.isoformat())).fetchone()
            if overlap:
                raise HTTPException(409, "Период пересекается с зарегистрированным отпуском")
            reference = "ZUP-" + hashlib.sha256(idempotency_key.encode()).hexdigest()[:16]
            db.execute("INSERT INTO documents VALUES (?,?,?,?,?,?,?)", (idempotency_key, digest, data.employee_id, data.days_count, reference, data.start_date.isoformat(), data.end_date.isoformat()))
            return {"reference": reference, "command_key": idempotency_key, "status": "registered"}

    @service.get(PREFIX + "/leave/documents", dependencies=[Depends(authorize)])
    def documents():
        with connect() as db:
            return [dict(row) for row in db.execute("SELECT command_key,employee_id,days,reference,start_date,end_date FROM documents ORDER BY rowid")]

    return service


def app_factory():
    return create_mock_app(os.environ.get("ZUP_MOCK_DATABASE", "/data/zup.sqlite3"), os.environ["ZUP_API_TOKEN"])
