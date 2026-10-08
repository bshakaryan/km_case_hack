import asyncio
import csv
import hashlib
import io
import json
import logging
import os
import re
import secrets
import warnings
from collections import defaultdict, deque
from contextlib import asynccontextmanager, suppress
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

from anyio import from_thread
from fastapi import Depends, FastAPI, File, Form, HTTPException, Query, Request, Response, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from PIL import Image, ImageOps, UnidentifiedImageError
from sqlalchemy import delete, func, or_, select, text as sql_text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from .db import make_engine, session_factory
from .conditional_response import conditional_json_response
from .ai_jobs import FormalStub, begin_sqlite_write, dispatch_ai_jobs, enqueue_job, job_dict, run_inline
from .ai_adapter import AttemptServiceAdapter
from .migrations import upgrade_database
from .models import AIAssessment, AIReviewJob, Area, AuthSession, Brigade, ClientCommand, DeviceToken, Employee, Equipment, FaultCode, Material, MaterialWriteoff, Notification, Order, OrderEvent, Photo, SubmissionAttempt, TimeNorm, utcnow
from .push import StubSender, dispatch_push, env_int, get_sender
from .schemas import Completion, DeviceRegistration, DeviceUnregister, Login, OrderCreate, OrderPage, OrderPatch, Transition
from .order_paging import after_cursor, apply_scope, broad_search, decode_cursor, encode_cursor, fingerprint, order_tuple, sort_columns
from .security import check_pin, hash_pin, token_hash
from .seed import seed_database
from .services import AIReviewStub, EXECUTION_FINISHED, TERMINAL, analytics, append_assignment, append_submission, append_submission_decision, audit, aware, current_participants, downtime_minutes, effective_queue_statuses, employee_dict, end_current_assignment, iso, monitor_deadlines, notify, order_dict, participant_ids, photo_dict, queue_positions, shift_start, waiting_orders, worker_order_access

log = logging.getLogger(__name__)
STATUS = {"issued", "accepted", "queued", "rejected", "in_progress", "paused", "completed", "ai_review", "rework", "closed", "cancelled"}
PRIORITY = {"emergency", "high", "normal", "planned"}
WS_AUTH_RECHECK_SECONDS = 30
ORDER_NUMBER_ATTEMPTS = 5


def order_number(assigned):
    return f"Н-{assigned.year}-{secrets.token_hex(3).upper()}"


def number_collision(error):
    """Retry only the unique constraint on our generated order number."""
    original = error.orig
    if getattr(original, "sqlstate", None) == "23505":
        return getattr(getattr(original, "diag", None), "constraint_name", None) == "ix_orders_number"
    return str(original) == "UNIQUE constraint failed: orders.number"


def prepare_photo(data):
    """Decode and compress outside the transaction holding the order lock."""
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            with Image.open(io.BytesIO(data)) as original:
                original.verify()
            with Image.open(io.BytesIO(data)) as original:
                photo_image = ImageOps.exif_transpose(original).convert("RGB")
                photo_image.thumbnail((1920, 1920))
                output = io.BytesIO()
                photo_image.save(output, format="JPEG", quality=82, optimize=True)
    except (UnidentifiedImageError, OSError, ValueError, SyntaxError, Image.DecompressionBombError, Image.DecompressionBombWarning):
        raise HTTPException(422, "Файл не является допустимым изображением")
    return output.getvalue()


class Realtime:
    def __init__(self):
        self.clients = set()

    async def publish(self, type_, order_id=None):
        message = {"type": type_}
        if order_id:
            message["order_id"] = order_id
        for ws in list(self.clients):
            try:
                await asyncio.wait_for(ws.send_json(message), timeout=2)
            except Exception:
                self.clients.discard(ws)


def create_app(database_url=None, seed=True, monitor=True):
    ai_mode = os.getenv("AI_REVIEW_MODE", "queued_stub").strip()
    if ai_mode not in {"queued_stub", "inline_stub", "queued_service"}:
        raise ValueError("AI_REVIEW_MODE must be queued_stub, inline_stub or queued_service")
    ai_providers = {"stub": FormalStub()}
    if ai_mode == "queued_service":
        ai_providers["ai_service"] = AttemptServiceAdapter.from_env()
    engine = make_engine(database_url)
    sessions = session_factory(engine)
    realtime = Realtime()
    attempts = defaultdict(deque)
    # One sender instance keeps the OAuth2 access token cached across dispatches.
    push_sender = get_sender()

    async def ai_loop():
        while True:
            try:
                changed_orders = await asyncio.to_thread(dispatch_ai_jobs, sessions, providers=ai_providers)
                for order_id in changed_orders:
                    await realtime.publish("orders.updated", order_id)
                    await realtime.publish("notifications.updated")
            except asyncio.CancelledError:
                raise
            except Exception:
                # No provider exception text or submitted data enters logs.
                log.warning("AI job dispatch unavailable; retrying")
            await asyncio.sleep(1)

    def run_monitor():
        with sessions() as db:
            return monitor_deadlines(db)

    async def deadline_loop():
        while True:
            try:
                added = await asyncio.to_thread(run_monitor)
                if added:
                    await realtime.publish("notifications.updated")
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("Deadline monitor failed; retrying in five seconds")
            await asyncio.sleep(5)

    def run_push():
        with sessions() as db:
            return dispatch_push(db, push_sender)

    async def push_loop():
        while True:
            try:
                await asyncio.to_thread(run_push)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("Push dispatch failed; retrying")
            await asyncio.sleep(max(1, env_int("PUSH_DISPATCH_SECONDS", 3)))

    @asynccontextmanager
    async def lifespan(app):
        upgrade_database(engine)
        if seed and os.getenv("SEED_DEMO", "true").lower() == "true":
            with sessions() as db:
                seed_database(db)
        task = asyncio.create_task(deadline_loop()) if monitor else None
        push_task = asyncio.create_task(push_loop()) if monitor and not isinstance(push_sender, StubSender) else None
        ai_task = asyncio.create_task(ai_loop()) if monitor and ai_mode != "inline_stub" else None
        yield
        if ai_task:
            ai_task.cancel()
            with suppress(asyncio.CancelledError):
                await ai_task
        if push_task:
            push_task.cancel()
            with suppress(asyncio.CancelledError):
                await push_task
        if task:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task
        for ws in list(realtime.clients):
            with suppress(Exception):
                await ws.close(code=1001)
        engine.dispose()

    app = FastAPI(title="НарядAI API", version="1.0.0", lifespan=lifespan)
    app.state.engine = engine
    app.state.sessions = sessions
    app.state.realtime = realtime
    app.state.ai_review_mode = ai_mode
    app.state.run_ai_jobs = lambda provider=None, limit=10: dispatch_ai_jobs(sessions, provider=provider, limit=limit, providers=ai_providers)
    app.add_middleware(CORSMiddleware, allow_origins=os.getenv("CORS_ORIGINS", "http://localhost:5173,http://127.0.0.1:5173,http://localhost:8080,http://127.0.0.1:8080").split(","), allow_credentials=False, allow_methods=["GET", "POST", "PATCH", "OPTIONS"], allow_headers=["Authorization", "Content-Type", "X-Client-Command-Id", "X-Expected-Order-Version", "X-Previous-Client-Command-Id", "If-None-Match"], expose_headers=["ETag"])

    def get_db():
        with sessions() as db:
            try:
                yield db
            except Exception:
                db.rollback()
                raise

    DB = Annotated[Session, Depends(get_db)]

    def lookup_user(db, token):
        session = db.scalar(select(AuthSession).where(AuthSession.token_hash == token_hash(token)))
        if not session or aware(session.expires_at) <= utcnow():
            raise HTTPException(401, "Сессия истекла. Войдите снова.", headers={"WWW-Authenticate": "Bearer"})
        user = db.get(Employee, session.employee_id)
        if not user:
            raise HTTPException(401, "Пользователь не найден")
        return user

    def current_user(request: Request, db: DB):
        auth = request.headers.get("Authorization", "")
        if not auth.startswith("Bearer "):
            raise HTTPException(401, "Необходима авторизация", headers={"WWW-Authenticate": "Bearer"})
        return lookup_user(db, auth[7:])

    User = Annotated[Employee, Depends(current_user)]

    def require_role(user, *roles):
        if user.role not in roles:
            raise HTTPException(403, "Недостаточно прав для этого действия")

    def get_order(db, id_, user, lock=False):
        if lock:
            begin_sqlite_write(db)
        query = select(Order).where(Order.id == id_)
        if lock:
            query = query.with_for_update()
        order = db.scalar(query)
        if not order:
            raise HTTPException(404, "Наряд не найден")
        if user.role == "worker" and not db.scalar(select(Order.id).where(Order.id == order.id, worker_order_access(user.id))):
            raise HTTPException(403, "Доступны только наряды вашего текущего назначения")
        return order

    def require_responsible(user, order):
        if user.role == "worker" and order.assignee_id != user.id:
            raise HTTPException(403, "Действие доступно только ответственному за наряд")

    def lock_roster(db):
        # Employee inserts/moves/shift changes and assignment snapshots share
        # this lock: locking existing members alone misses new brigade members.
        begin_sqlite_write(db)
        if db.bind.dialect.name == "postgresql":
            db.execute(sql_text("SELECT pg_advisory_xact_lock(1095648841, 2)"))

    def resolve_assignment(db, assignee_id, brigade_id, responsible_id=None):
        lock_roster(db)
        if brigade_id:
            if not db.scalar(select(Brigade).where(Brigade.id == brigade_id).with_for_update()):
                raise HTTPException(422, "Бригада не найдена")
            workers = list(db.scalars(select(Employee).where(Employee.role == "worker", Employee.brigade_id == brigade_id, Employee.on_shift.is_(True)).order_by(Employee.id).with_for_update()))
            if not workers:
                raise HTTPException(422, "В бригаде нет работников на смене")
            if responsible_id is not None:
                if responsible_id not in {worker.id for worker in workers}:
                    raise HTTPException(422, "Ответственный должен быть работником выбранной бригады на смене")
                return responsible_id, workers
            counts = {w.id: db.scalar(select(func.count()).select_from(Order).where(Order.assignee_id == w.id, Order.status.notin_(TERMINAL))) for w in workers}
            return min(workers, key=lambda w: (counts[w.id], w.id)).id, workers
        person = db.scalar(select(Employee).where(Employee.id == assignee_id).with_for_update())
        if not person or person.role != "worker":
            raise HTTPException(422, "Исполнителем должен быть рабочий")
        if not person.on_shift:
            raise HTTPException(422, "Работник вне смены")
        return person.id, [person]

    CLIENT_COMMAND_ID = re.compile(r"[A-Za-z0-9._:-]{8,64}")

    def request_hash(*parts):
        return hashlib.sha256("\x1f".join(parts).encode("utf-8")).hexdigest()

    def json_hash(payload):
        return request_hash(json.dumps(payload, sort_keys=True, ensure_ascii=False, default=str))

    def command_basis(request):
        expected = request.headers.get("X-Expected-Order-Version")
        previous = request.headers.get("X-Previous-Client-Command-Id")
        if expected is not None and previous is not None:
            raise HTTPException(422, "Укажите только одну основу версии наряда")
        if expected is not None:
            expected = expected.strip()
            if not re.fullmatch(r"[1-9][0-9]{0,9}", expected) or int(expected) > 2_147_483_647:
                raise HTTPException(422, "Некорректный X-Expected-Order-Version")
            return "version", int(expected)
        if previous is not None:
            previous = previous.strip()
            client_id = (request.headers.get("X-Client-Command-Id") or "").strip()
            if not CLIENT_COMMAND_ID.fullmatch(previous) or not CLIENT_COMMAND_ID.fullmatch(client_id):
                raise HTTPException(422, "X-Previous-Client-Command-Id требует корректный текущий X-Client-Command-Id")
            return "previous", previous
        return None, None

    def check_order_version(db, user, request, order):
        basis, value = command_basis(request)
        expected = value
        if basis == "previous":
            receipt = db.scalar(select(ClientCommand).where(ClientCommand.employee_id == user.id, ClientCommand.client_id == value))
            if receipt is None or receipt.response_status is None or not 200 <= receipt.response_status < 300 or receipt.order_id != order.id or receipt.order_version is None:
                raise HTTPException(409, {"code": "order_precondition_unavailable", "message": "Нет подтверждённой предыдущей команды для этого наряда"})
            expected = receipt.order_version
        if basis is not None and order.version != expected:
            raise HTTPException(409, {"code": "order_version_conflict", "message": "Наряд изменён. Сохранённое действие требует проверки.", "expected_version": expected, "current_version": order.version})

    def run_idempotent(db, user, request, kind, command_hash, status, perform, order_id=None):
        scoped_hash = request_hash("client-command-v2", kind, "" if order_id is None else str(order_id), command_hash)
        basis, value = command_basis(request)
        if basis is not None:
            if order_id is None:
                raise HTTPException(422, "Основа версии доступна только для существующего наряда")
            scoped_hash = request_hash("client-command-v3", kind, str(order_id), command_hash, basis, str(value))
        client_id = (request.headers.get("X-Client-Command-Id") or "").strip()
        if client_id:
            if not CLIENT_COMMAND_ID.fullmatch(client_id):
                raise HTTPException(422, "Некорректный X-Client-Command-Id")
            existing = db.scalar(select(ClientCommand).where(ClientCommand.employee_id == user.id, ClientCommand.client_id == client_id))
            if existing:
                matches_request = existing.request_hash == scoped_hash
                if basis is None and existing.request_hash == command_hash:
                    # Legacy transition/completion hashes omitted the URL target.
                    # Replay only when the stored order response proves that target;
                    # an ambiguous record must never execute the command again.
                    matches_request = kind not in {"transition", "complete", "order_update"} or (
                        isinstance(existing.response_body, dict)
                        and type(existing.response_body.get("id")) is int
                        and existing.response_body["id"] == order_id
                    )
                if existing.kind != kind or not matches_request:
                    raise HTTPException(409, "Команда с таким идентификатором уже выполнена с другим содержанием, действием или нарядом")
                if existing.response_status is None:
                    raise HTTPException(409, "Предыдущая отправка этой команды не завершена. Повторите запрос позже.")
                return JSONResponse(status_code=existing.response_status, content=existing.response_body)
        claim = None
        if client_id:
            claim = ClientCommand(employee_id=user.id, client_id=client_id, kind=kind, request_hash=scoped_hash)
            db.add(claim)
            try:
                db.flush()
            except IntegrityError:
                db.rollback()
                raise HTTPException(409, "Команда с таким идентификатором уже выполняется")
        body, events = perform()
        if claim is not None:
            claim.response_status = status
            claim.response_body = body
            receipt_order_id = order_id if order_id is not None else body.get("id")
            receipt_order = db.get(Order, receipt_order_id)
            claim.order_id = receipt_order.id
            claim.order_version = receipt_order.version
        db.commit()
        for type_, order_id in events:
            from_thread.run(realtime.publish, type_, order_id)
        return JSONResponse(status_code=status, content=body)

    def filtered(db, user, area_id=None, equipment_id=None, assignee_id=None, brigade_id=None, priority=None, status=None, search=None, from_date=None, to_date=None, participant_access=False):
        query = select(Order)
        if user.role == "worker":
            query = query.where(worker_order_access(user.id) if participant_access else Order.assignee_id == user.id)
        for key, value in [("area_id", area_id), ("equipment_id", equipment_id), ("assignee_id", assignee_id), ("brigade_id", brigade_id), ("priority", priority), ("status", status)]:
            if value is not None and value != "":
                if key == "status":
                    if value not in STATUS:
                        raise HTTPException(422, "Неизвестный статус")
                    legacy_queued = effective_queue_statuses(db)
                    if value == "queued":
                        query = query.where(or_(Order.status == "queued", Order.id.in_(legacy_queued)))
                        continue
                    if value == "accepted":
                        query = query.where(Order.status == "accepted", Order.id.not_in(legacy_queued))
                        continue
                if key == "priority" and value not in PRIORITY:
                    raise HTTPException(422, "Неизвестный приоритет")
                query = query.where(getattr(Order, key) == value)
        if search:
            safe_search = search.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            needle = f"%{safe_search}%"
            query = query.where(Order.title.ilike(needle, escape="\\") | Order.number.ilike(needle, escape="\\") | Order.description.ilike(needle, escape="\\"))
        if from_date:
            query = query.where(Order.created_at >= parse_date(from_date))
        if to_date:
            query = query.where(Order.created_at <= parse_date(to_date, end=True))
        if from_date and to_date and parse_date(from_date) > parse_date(to_date, end=True):
            raise HTTPException(422, "Начало периода должно быть раньше окончания")
        return query

    @app.get("/api/health")
    @app.get("/health")
    def health(db: DB):
        db.execute(sql_text("SELECT 1"))
        return {"status": "ok", "database": "connected", "ai": "stub", "native": "stub"}

    @app.post("/api/auth/login")
    def login(payload: Login, request: Request, db: DB):
        key = (request.client.host if request.client else "unknown", payload.login)
        now = utcnow().timestamp()
        queue = attempts[key]
        while queue and queue[0] < now - 60:
            queue.popleft()
        if len(queue) >= 10:
            raise HTTPException(429, "Слишком много попыток. Повторите через минуту.", headers={"Retry-After": "60"})
        queue.append(now)
        person = db.scalar(select(Employee).where(Employee.login == payload.login))
        if not person or not check_pin(payload.pin, person.pin_hash):
            raise HTTPException(401, "Неверный логин или PIN")
        queue.clear()
        token = secrets.token_urlsafe(40)
        db.add(AuthSession(token_hash=token_hash(token), employee_id=person.id, expires_at=utcnow() + timedelta(hours=12)))
        db.execute(delete(AuthSession).where(AuthSession.expires_at < utcnow()))
        db.commit()
        return {"token": token, "user": employee_dict(person)}

    @app.get("/api/auth/me")
    def me(user: User):
        return employee_dict(user)

    @app.post("/api/auth/logout")
    def logout(request: Request, db: DB, user: User):
        db.execute(delete(AuthSession).where(AuthSession.token_hash == token_hash(request.headers["Authorization"][7:])))
        db.commit()
        return {"ok": True}

    @app.get("/api/reference")
    def reference(db: DB, user: User):
        if user.role == "worker":
            return {"areas": [], "equipment": [], "employees": [], "brigades": [], "fault_codes": rows(db, FaultCode, ["id", "code", "name"]), "materials": rows(db, Material, ["id", "name", "unit"]), "time_norms": []}
        result = {"areas": rows(db, Area, ["id", "name"]), "equipment": rows(db, Equipment, ["id", "name", "inventory_number", "area_id", "type", "criticality"]), "employees": [employee_dict(p) for p in db.scalars(select(Employee).order_by(Employee.id))], "brigades": rows(db, Brigade, ["id", "name"]), "fault_codes": rows(db, FaultCode, ["id", "code", "name"]), "materials": rows(db, Material, ["id", "name", "unit"]), "time_norms": rows(db, TimeNorm, ["id", "name", "hours"])}
        return result

    reference_models = {"areas": Area, "equipment": Equipment, "employees": Employee, "brigades": Brigade, "fault_codes": FaultCode, "materials": Material, "time_norms": TimeNorm}

    def save_reference(collection, payload, id_, db, user):
        require_role(user, "admin")
        model = reference_models.get(collection)
        if not model:
            raise HTTPException(404, "Справочник не найден")
        allowed = {c.name for c in model.__table__.columns} - {"id", "pin_hash"}
        if model is Employee:
            allowed.add("pin")
        if not payload or set(payload) - allowed:
            raise HTTPException(422, "Неизвестные поля или пустое изменение")
        if model is Employee:
            lock_roster(db)
        existing = db.scalar(select(model).where(model.id == id_).with_for_update().execution_options(populate_existing=True)) if id_ else None
        if id_ and existing is None:
            raise HTTPException(404, "Запись не найдена")
        clean = {}
        for key, value in payload.items():
            if key in ["name", "login", "code", "unit", "type", "inventory_number", "specialty", "criticality"]:
                max_length = model.__table__.columns[key].type.length
                if not isinstance(value, str) or not value.strip() or len(value) > max_length:
                    raise HTTPException(422, f"Некорректное поле: {key}")
                clean[key] = value.strip()
            elif key in ["area_id", "brigade_id"]:
                if value is None and key == "brigade_id":
                    clean[key] = None
                elif isinstance(value, bool) or not isinstance(value, int) or not db.get(Area if key == "area_id" else Brigade, value):
                    raise HTTPException(422, f"Не найдена связь: {key}")
                else:
                    clean[key] = value
            elif key == "grade":
                if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 8:
                    raise HTTPException(422, "Разряд должен быть от 0 до 8")
                clean[key] = value
            elif key == "on_shift":
                if not isinstance(value, bool):
                    raise HTTPException(422, "on_shift должен быть boolean")
                clean[key] = value
            elif key == "role":
                if value not in ["worker", "master", "manager", "admin"]:
                    raise HTTPException(422, "Неизвестная роль")
                clean[key] = value
            elif key == "pin":
                if not isinstance(value, str) or not value.isdigit() or not 4 <= len(value) <= 12:
                    raise HTTPException(422, "PIN должен содержать от 4 до 12 цифр")
                clean["pin_hash"] = hash_pin(value)
            elif key == "hours":
                if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 < value <= 1000:
                    raise HTTPException(422, "Норматив должен быть больше 0 и не более 1000 часов")
                clean[key] = value
        required = {Area: {"name"}, Brigade: {"name"}, Equipment: {"name", "inventory_number", "area_id", "type"}, Employee: {"name", "login", "role", "pin_hash"}, FaultCode: {"code", "name"}, Material: {"name", "unit"}, TimeNorm: {"name", "hours"}}[model]
        if existing is None and not required.issubset(clean):
            raise HTTPException(422, "Заполните обязательные поля: " + ", ".join(sorted(required - set(clean))))
        if model is Employee and existing and existing.id == user.id and clean.get("role", existing.role) != "admin":
            raise HTTPException(422, "Нельзя изменить собственную роль администратора")
        obj = existing or model()
        for key, value in clean.items():
            setattr(obj, key, value)
        db.add(obj)
        try:
            db.commit()
        except IntegrityError:
            db.rollback()
            raise HTTPException(409, "Запись с таким значением уже существует")
        return employee_dict(obj) if model is Employee else {c.name: getattr(obj, c.name) for c in model.__table__.columns}

    @app.post("/api/reference/{collection}", status_code=201)
    def reference_create(collection: str, payload: dict, db: DB, user: User):
        return save_reference(collection, payload, None, db, user)

    @app.patch("/api/reference/{collection}/{id_}")
    def reference_update(collection: str, id_: int, payload: dict, db: DB, user: User):
        return save_reference(collection, payload, id_, db, user)

    @app.get("/api/employees")
    def employees(db: DB, user: User):
        require_role(user, "master", "manager", "admin")
        all_orders = list(db.scalars(select(Order)))
        ratings = analytics(db, all_orders, utcnow() - timedelta(days=90), utcnow())["rankings"]
        rating_map = {r["id"]: r for r in ratings}
        result = []
        for person in db.scalars(select(Employee).where(Employee.role == "worker").order_by(Employee.id)):
            assigned = [o for o in all_orders if o.assignee_id == person.id and o.status not in EXECUTION_FINISHED and o.status != "rejected"]
            current = next((o for o in assigned if o.status == "in_progress"), None) or next((o for o in assigned if o.status == "paused"), None)
            queue_count = sum(o.status in {"accepted", "queued"} for o in assigned)
            rating = rating_map.get(person.id, {})
            result.append({**employee_dict(person), "status": "off_shift" if not person.on_shift else "busy" if current else "queued" if queue_count else "free", "current_order": current.number if current else None, "queue_count": queue_count, "rating": rating.get("score", 0), "completed_count": rating.get("closed_count", 0)})
        return result

    @app.get("/api/orders")
    def orders(request: Request, db: DB, user: User, area_id: int | None = None, equipment_id: int | None = None, assignee_id: int | None = None, brigade_id: int | None = None, priority: str | None = None, status: str | None = None, search: str | None = Query(None, max_length=200), from_date: str | None = None, to_date: str | None = None, limit: int = Query(1000, ge=1, le=5000)):
        require_role(user, "worker", "master", "manager", "admin")
        query = filtered(db, user, area_id, equipment_id, assignee_id, brigade_id, priority, status, search, from_date, to_date, participant_access=True)
        refs = {"areas": {a.id: a for a in db.scalars(select(Area))}, "equipment": {e.id: e for e in db.scalars(select(Equipment))}, "employees": {p.id: p for p in db.scalars(select(Employee))}}
        positions = queue_positions(db)
        statuses = effective_queue_statuses(db)
        selected = list(db.scalars(query.order_by(Order.created_at.desc()).limit(limit)))
        participants = current_participants(db, selected)
        body = [order_dict(db, o, refs=refs, positions=positions, statuses=statuses, participants=participants[o.id]) for o in selected]
        scope = {"user_id": user.id, "role": user.role,
            "session": token_hash(request.headers["Authorization"][7:]),
            "query": {"area_id": area_id, "equipment_id": equipment_id,
                "assignee_id": assignee_id, "brigade_id": brigade_id,
                "priority": priority or None, "status": status or None,
                "search": search or None, "limit": limit,
                "from_date": iso(parse_date(from_date)) if from_date else None,
                "to_date": iso(parse_date(to_date, end=True)) if to_date else None}}
        return conditional_json_response(body, scope=scope,
            if_none_match=request.headers.getlist("If-None-Match"))

    @app.get("/api/orders/page", response_model=OrderPage)
    def orders_page(request: Request, db: DB, user: User,
        area_id: int | None = None, equipment_id: int | None = None,
        assignee_id: int | None = None, brigade_id: int | None = None,
        priority: str | None = None, status: str | None = None,
        search: str | None = Query(None, max_length=200),
        from_date: str | None = None, to_date: str | None = None,
        scope: Literal["all", "active", "closed"] = "all",
        focus: Literal["all", "overdue", "emergency", "issued", "ai_review", "rejected"] = "all",
        sort: Literal["newest", "deadline", "priority"] = "newest",
        limit: int = Query(100, ge=1, le=200), cursor: str | None = Query(None, max_length=4096)):
        require_role(user, "master", "worker", "manager", "admin")
        canonical = {"area_id": area_id, "equipment_id": equipment_id,
            "assignee_id": assignee_id, "brigade_id": brigade_id,
            "priority": priority or None, "status": status or None,
            "search": search.strip().lower() or None if search is not None else None,
            "from_date": iso(parse_date(from_date).astimezone(timezone.utc)) if from_date else None,
            "to_date": iso(parse_date(to_date, end=True).astimezone(timezone.utc)) if to_date else None,
            "scope": scope, "focus": focus, "sort": sort}
        query = filtered(db, user, area_id, equipment_id, assignee_id, brigade_id,
            canonical["priority"], canonical["status"], from_date=canonical["from_date"],
            to_date=canonical["to_date"], participant_access=True)
        query = broad_search(db, query, canonical["search"])
        query = apply_scope(query, scope, focus, utcnow())
        query_fingerprint = fingerprint(user, canonical)
        # Derive the signing key from the current persisted session identity.
        # No bearer/hash is included in payloads, logs or error diagnostics.
        session_hash = token_hash(request.headers["Authorization"][7:])
        last = None
        if cursor is not None:
            ceiling, last = decode_cursor(cursor, query_fingerprint, sort, session_hash)
        else:
            ceiling = db.scalar(query.with_only_columns(func.max(Order.id), maintain_column_froms=True)) or 0
        window = query.where(Order.id <= ceiling)
        total = db.scalar(select(func.count()).select_from(window.subquery()))
        columns, descending = sort_columns(sort)
        selected_query = after_cursor(window, columns, descending, last) if last is not None else window
        selected = list(db.scalars(selected_query.order_by(*[
            column.desc() if descending else column.asc() for column in columns]).limit(limit + 1)))
        more = len(selected) > limit
        selected = selected[:limit]
        refs = {"areas": {a.id: a for a in db.scalars(select(Area))},
            "equipment": {e.id: e for e in db.scalars(select(Equipment))},
            "employees": {p.id: p for p in db.scalars(select(Employee))}}
        participants = current_participants(db, selected)
        positions, statuses = queue_positions(db), effective_queue_statuses(db)
        return {"items": [order_dict(db, order, refs=refs, positions=positions,
                statuses=statuses, participants=participants[order.id]) for order in selected],
            "next_cursor": encode_cursor(query_fingerprint, ceiling, order_tuple(selected[-1], sort), session_hash) if more else None,
            "total": total}

    @app.get("/api/equipment/{id_}")
    def equipment_detail(id_: int, db: DB, user: User):
        require_role(user, "master", "manager", "admin")
        equipment = db.get(Equipment, id_)
        if equipment is None:
            raise HTTPException(404, "Оборудование не найдено")
        area = db.get(Area, equipment.area_id)
        return {key: getattr(equipment, key) for key in
            ["id", "name", "inventory_number", "area_id", "type", "criticality"]} | {"area_name": area.name}

    @app.get("/api/orders/{id_}")
    def order_detail(id_: int, db: DB, user: User):
        return order_dict(db, get_order(db, id_, user), detail=True, user=user)

    def submission_for_order(db, order, attempt_id):
        attempt = db.get(SubmissionAttempt, attempt_id)
        if attempt is None or attempt.order_id != order.id:
            raise HTTPException(404, "Попытка сдачи не найдена")
        return attempt

    @app.get("/api/orders/{id_}/submissions/{attempt_id}/ai-review")
    def get_ai_review(id_: int, attempt_id: int, db: DB, user: User):
        order = get_order(db, id_, user)
        attempt = submission_for_order(db, order, attempt_id)
        job = db.scalar(select(AIReviewJob).where(AIReviewJob.attempt_id == attempt.id))
        latest = db.scalar(select(SubmissionAttempt.id).where(SubmissionAttempt.order_id == order.id).order_by(SubmissionAttempt.sequence.desc()).limit(1))
        retry_allowed = bool(user.role in {"master", "admin"} and job and job.status == "failed" and latest == attempt.id and order.status == "completed" and attempt.ai_review is None and attempt.assessment_id is None)
        return {"attempt_id": attempt.id, "order_version": order.version, "ai_review": attempt.ai_review, "job": job_dict(job, retry_allowed)}

    @app.post("/api/orders/{id_}/submissions/{attempt_id}/ai-review/retry")
    def retry_ai_review(id_: int, attempt_id: int, db: DB, user: User, request: Request):
        require_role(user, "master", "admin")
        begin_sqlite_write(db)
        order = get_order(db, id_, user, lock=True)
        attempt = submission_for_order(db, order, attempt_id)
        job = db.scalar(select(AIReviewJob).where(AIReviewJob.attempt_id == attempt.id).with_for_update())
        def perform():
            check_order_version(db, user, request, order)
            latest = db.scalar(select(SubmissionAttempt.id).where(SubmissionAttempt.order_id == order.id).order_by(SubmissionAttempt.sequence.desc()).limit(1))
            if job is None or job.status != "failed" or order.status != "completed" or latest != attempt.id or attempt.ai_review is not None or attempt.assessment_id is not None:
                raise HTTPException(409, "Повтор доступен только для последней неудачной проверки завершённой работы")
            job.status = "pending"
            job.attempts = 0
            job.next_attempt_at = utcnow()
            job.finished_at = None
            job.last_error_code = None
            job.lease_token = None
            job.lease_expires_at = None
            order.version += 1
            audit(db, order, "ai_review_retry", user.id, order.status, "Повтор проверки конкретной сдачи")
            db.flush()
            return {"attempt_id": attempt.id, "order_version": order.version, "ai_review": None, "job": job_dict(job)}, [("orders.updated", order.id)]
        return run_idempotent(db, user, request, "ai_review_retry", request_hash(str(attempt_id)), 200, perform, order_id=id_)

    @app.post("/api/orders", status_code=201)
    def order_create(payload: OrderCreate, db: DB, user: User, request: Request):
        require_role(user, "master", "admin")
        command_payload = payload.model_dump()
        if payload.responsible_id is None:
            # New optional selection must not invalidate receipts produced
            # before this field existed for otherwise identical old requests.
            command_payload.pop("responsible_id")
        command_hash = json_hash(command_payload)

        def perform():
            equipment = db.get(Equipment, payload.equipment_id)
            if not equipment or equipment.area_id != payload.area_id:
                raise HTTPException(422, "Оборудование не принадлежит выбранному участку")
            if payload.deadline <= utcnow():
                raise HTTPException(422, "Срок нового наряда должен быть в будущем")
            data = payload.model_dump()
            data.pop("responsible_id")
            data["assignee_id"], participants = resolve_assignment(db, payload.assignee_id, payload.brigade_id, payload.responsible_id)
            assigned = utcnow()
            if db.bind.dialect.name == "sqlite" and not db.connection().connection.driver_connection.in_transaction:
                # sqlite3's legacy transaction mode does not BEGIN for SELECT.
                # A first SAVEPOINT must not become an independently committed
                # transaction when it is released before audit/notifications.
                db.connection().exec_driver_sql("BEGIN")
            for attempt in range(ORDER_NUMBER_ATTEMPTS):
                order = Order(**data, number=order_number(assigned), status="issued", master_id=user.id, created_at=assigned, assigned_at=assigned)
                try:
                    # Preserve the command claim and any assignment locks while
                    # rolling back only a collided candidate, on either backend.
                    with db.begin_nested():
                        db.add(order)
                        db.flush()
                except IntegrityError as error:
                    if not number_collision(error):
                        raise
                    if attempt == ORDER_NUMBER_ATTEMPTS - 1:
                        raise HTTPException(503, "Не удалось выделить номер наряда. Повторите запрос позже.", headers={"Retry-After": "1"})
                else:
                    break
            append_assignment(db, order, user.id, participants)
            audit(db, order, "issue", user.id, comment=payload.comment)
            notify(db, [person.id for person in participants], "Вам назначен наряд", f"{order.number}: {order.title}", "assigned", order.id)
            return order_dict(db, order, detail=True, user=user), [("orders.updated", order.id), ("notifications.updated", None)]

        return run_idempotent(db, user, request, "order_create", command_hash, 201, perform)

    @app.patch("/api/orders/{id_}")
    def order_update(id_: int, payload: OrderPatch, db: DB, user: User, request: Request):
        require_role(user, "master", "admin")
        order = get_order(db, id_, user, lock=True)
        def perform():
            check_order_version(db, user, request, order)
            if order.status in TERMINAL:
                raise HTTPException(409, "Закрытый или отменённый наряд нельзя изменить")
            changes = payload.model_dump(exclude_unset=True)
            old_status = order.status
            audit_fields = []
            if "assignee_id" in changes or "brigade_id" in changes:
                if order.status in ["in_progress", "paused", "completed", "ai_review"]:
                    raise HTTPException(409, "Переназначение доступно до начала работы или после возврата")
                order.assignee_id, participants = resolve_assignment(db, payload.assignee_id, payload.brigade_id, payload.responsible_id)
                order.brigade_id = payload.brigade_id
                order.status = "issued"
                assigned = utcnow()
                order.assigned_at = max(assigned, aware(order.assigned_at) + timedelta(microseconds=1))
                append_assignment(db, order, user.id, participants)
                notify(db, [person.id for person in participants], "Наряд переназначен вам", order.number, "assigned", order.id)
            if payload.deadline is not None and payload.deadline <= utcnow():
                raise HTTPException(422, "Новый срок должен быть в будущем")
            for key, value in changes.items():
                if key not in ["assignee_id", "brigade_id", "responsible_id"]:
                    setattr(order, key, value)
                audit_fields.append(f"{key}={iso(value) if isinstance(value, datetime) else value}")
            order.version += 1
            audit(db, order, "edit", user.id, old_status, "; ".join(audit_fields))
            return order_dict(db, order, detail=True, user=user), [("orders.updated", order.id), ("notifications.updated", None)]
        return run_idempotent(db, user, request, "order_update", json_hash(payload.model_dump(exclude_unset=True)), 200, perform, order_id=id_)

    @app.post("/api/orders/{id_}/transition")
    def transition(id_: int, payload: Transition, db: DB, user: User, request: Request):
        require_role(user, "worker", "master", "admin")
        action = payload.action
        if action in ["accept", "start", "pause", "resume", "reject"]:
            require_role(user, "worker")
        elif action == "queue":
            require_role(user, "worker")
        elif action in ["close", "rework", "cancel"]:
            require_role(user, "master", "admin")
        else:
            raise HTTPException(422, "Неизвестное действие с нарядом")
        order = get_order(db, id_, user, lock=True)
        require_responsible(user, order)
        command_hash = json_hash(payload.model_dump())

        def perform():
            check_order_version(db, user, request, order)
            if action == "queue" and order.status == "queued":
                return order_dict(db, order, detail=True, user=user), [("orders.updated", order.id)]
            if action in ["reject", "pause", "rework", "cancel"] and not payload.reason:
                raise HTTPException(422, "Укажите причину действия")
            transitions = {"accept": ({"issued", "rework"}, "accepted"), "queue": ({"issued", "rework", "accepted"}, "queued"), "reject": ({"issued", "accepted", "queued"}, "rejected"), "start": ({"accepted", "queued"}, "in_progress"), "pause": ({"in_progress"}, "paused"), "resume": ({"paused"}, "in_progress"), "close": ({"ai_review"}, "closed"), "rework": ({"ai_review"}, "rework"), "cancel": (STATUS - TERMINAL, "cancelled")}
            allowed, target = transitions[action]
            if order.status not in allowed:
                raise HTTPException(409, f"Действие {action} недоступно для статуса {order.status}")
            if action == "accept":
                person = db.scalar(select(Employee).where(Employee.id == order.assignee_id).with_for_update())
                active = db.scalar(select(Order).where(Order.assignee_id == person.id, Order.status.in_(["accepted", "in_progress", "paused"])).order_by(Order.id).limit(1))
                if active:
                    raise HTTPException(409, f"У вас уже есть незавершённый наряд {active.number}. Это назначение можно добавить в очередь.")
                waiting = [item for item in waiting_orders(db, person.id) if item.id != order.id]
                if waiting:
                    raise HTTPException(409, f"Сначала разберите очередь с наряда {waiting[0].number}. Новое назначение можно добавить в очередь.")
            if action == "queue":
                db.scalar(select(Employee.id).where(Employee.id == order.assignee_id).with_for_update())
            if action in ["start", "resume"]:
                person = db.scalar(select(Employee).where(Employee.id == order.assignee_id).with_for_update())
                if not person.on_shift:
                    raise HTTPException(409, "Исполнитель вне смены")
                conflicting_statuses = ["in_progress"] if action == "resume" else ["in_progress", "paused"]
                busy = db.scalar(select(Order).where(Order.assignee_id == order.assignee_id, Order.id != order.id, Order.status.in_(conflicting_statuses)).order_by(Order.id).limit(1))
                if busy:
                    raise HTTPException(409, f"Сначала завершите текущий наряд {busy.number}.")
                queue = waiting_orders(db, person.id)
                if action == "start" and queue and queue[0].id != order.id:
                    raise HTTPException(409, f"Сначала начните {queue[0].number} — этот наряд следующий в очереди.")
                order.started_at = order.started_at or utcnow()
            old_status = order.status
            if action == "cancel" and order.work_type == "unplanned":
                order.downtime_minutes = downtime_minutes(order)
            order.status = target
            order.version += 1
            if action == "close":
                if payload.score is None:
                    raise HTTPException(422, "Мастер должен поставить итоговую оценку от 1 до 5")
                order.score = payload.score
                order.closed_at = utcnow()
                order.ai_review = {**(order.ai_review or {}), "master_score": payload.score}
                assessment = db.scalar(select(AIAssessment).where(AIAssessment.order_id == order.id).order_by(AIAssessment.id.desc()).limit(1))
                if assessment:
                    assessment.master_score = payload.score
            if action == "rework":
                order.completed_at = None
                order.score = None
            if action == "cancel":
                order.closed_at = utcnow()
            if action in {"close", "cancel"}:
                end_current_assignment(db, order, order.closed_at)
            if action in {"close", "rework"}:
                append_submission_decision(db, order, user.id, action, payload.score if action == "close" else None, payload.reason or payload.comment)
            audit(db, order, action, user.id, old_status, payload.reason or payload.comment)
            notice = "Наряд добавлен в очередь" if action == "queue" else "Статус наряда изменён"
            notify(db, participant_ids(db, order) + [order.master_id], notice, f"{order.number}: {old_status} → {target}", "status", order.id)
            return order_dict(db, order, detail=True, user=user), [("orders.updated", order.id), ("notifications.updated", None)]

        return run_idempotent(db, user, request, "transition", command_hash, 200, perform, order_id=id_)

    @app.post("/api/orders/{id_}/complete")
    def complete(id_: int, payload: Completion, db: DB, user: User, request: Request):
        require_role(user, "worker")
        order = get_order(db, id_, user, lock=True)
        require_responsible(user, order)
        command_hash = json_hash(payload.model_dump())

        def perform():
            check_order_version(db, user, request, order)
            if order.status != "in_progress":
                raise HTTPException(409, "Завершить можно только наряд в работе")
            if not db.get(FaultCode, payload.fault_code_id):
                raise HTTPException(422, "Код неисправности не найден")
            if order.work_type == "unplanned" and not db.scalar(select(Photo.id).where(Photo.order_id == order.id, Photo.kind == "after")):
                raise HTTPException(422, "Для внеплановой работы добавьте фото после выполнения")
            materials = []
            writeoffs = []
            for usage in payload.materials:
                material = db.get(Material, usage.material_id)
                if not material:
                    raise HTTPException(422, f"Материал {usage.material_id} не найден")
                materials.append({"material_id": material.id, "name": material.name, "unit": material.unit, "quantity": usage.quantity})
                writeoff = MaterialWriteoff(order_id=order.id, material_id=material.id, quantity=usage.quantity, author_id=user.id)
                db.add(writeoff)
                writeoffs.append(writeoff)
            submission_payload = {**payload.model_dump(exclude={"materials"}), "materials": [dict(material) for material in materials]}
            previous_materials = (order.completion or {}).get("materials", [])
            accumulated = {m["material_id"]: dict(m) for m in previous_materials}
            for material in materials:
                if material["material_id"] in accumulated:
                    accumulated[material["material_id"]]["quantity"] += material["quantity"]
                else:
                    accumulated[material["material_id"]] = material
            order.completion = {**payload.model_dump(exclude={"materials"}), "materials": list(accumulated.values())}
            order.completed_at = utcnow()
            if order.work_type == "unplanned":
                order.downtime_minutes = round((order.completed_at - aware(order.created_at)).total_seconds() / 60, 1)
            order.status = "completed"
            order.version += 1
            audit(db, order, "complete", user.id, "in_progress", payload.work_done)
            notify(db, participant_ids(db, order) + [order.master_id], "Статус наряда изменён", f"{order.number}: in_progress → completed", "status", order.id)
            order.ai_review = None
            attempt = append_submission(db, order, user.id, submission_payload, writeoffs)
            job = enqueue_job(db, attempt, "ai_service" if ai_mode == "queued_service" else "stub")
            if ai_mode == "inline_stub":
                run_inline(db, order, attempt, job)
            return order_dict(db, order, detail=True, user=user), [("orders.updated", order.id), ("notifications.updated", None)]

        return run_idempotent(db, user, request, "complete", command_hash, 200, perform, order_id=id_)

    @app.post("/api/orders/{id_}/photos", status_code=201)
    def upload_photo(id_: int, db: DB, user: User, request: Request, file: UploadFile = File(...), kind: str = Form(...)):
        require_role(user, "worker", "master", "admin")
        get_order(db, id_, user)
        # Release the read transaction/connection before potentially slow file
        # IO and decoding. No row lock is held during either operation.
        db.rollback()
        if kind not in ["before", "after"]:
            raise HTTPException(422, "Тип фото: before или after")
        try:
            data = file.file.read(10 * 1024 * 1024 + 1)
        finally:
            file.file.close()
        if len(data) > 10 * 1024 * 1024:
            raise HTTPException(413, "Размер фото не должен превышать 10 МБ")
        command_hash = request_hash(str(id_), kind, hashlib.sha256(data).hexdigest())
        prepared = prepare_photo(data)
        # A logout, reassignment or completion may have happened while the file
        # was processed. Authenticate and authorize again against current data.
        user = lookup_user(db, request.headers.get("Authorization", "")[7:])
        require_role(user, "worker", "master", "admin")
        order = get_order(db, id_, user, lock=True)

        def perform():
            check_order_version(db, user, request, order)
            if order.status in TERMINAL or order.status == "ai_review":
                raise HTTPException(409, "Фотографии нельзя менять после сдачи или закрытия наряда")
            count = db.scalar(select(func.count()).select_from(Photo).where(Photo.order_id == id_, Photo.kind == kind))
            if count >= 5:
                raise HTTPException(422, "Можно загрузить не более 5 фотографий каждого типа")
            photo = Photo(order_id=id_, kind=kind, data=prepared, author_id=user.id)
            db.add(photo)
            order.version += 1
            audit(db, order, "photo", user.id, order.status, f"Добавлена фотография: {kind}")
            db.flush()
            return {**photo_dict(db, photo), "order_version": order.version}, [("orders.updated", id_)]

        return run_idempotent(db, user, request, "photo_upload", command_hash, 201, perform, order_id=id_)

    @app.get("/api/photos/{id_}")
    def get_photo(id_: int, db: DB, user: User):
        photo = db.get(Photo, id_)
        if not photo:
            raise HTTPException(404, "Фото не найдено")
        get_order(db, photo.order_id, user)
        return Response(photo.data, media_type="image/jpeg", headers={"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"})

    @app.get("/api/dashboard")
    def dashboard(db: DB, user: User):
        orders = list(db.scalars(filtered(db, user)))
        start, label = shift_start()
        now = utcnow()
        active = [o for o in orders if o.status not in TERMINAL]
        completed = [o for o in orders if o.completed_at and aware(o.completed_at) >= start]
        scores = [o.score for o in orders if o.score is not None]
        return {"issued": sum(aware(o.created_at) >= start for o in orders), "completed": len(completed), "overdue": sum(aware(o.deadline) < now for o in active if o.status not in EXECUTION_FINISHED), "downtime_count": len({o.equipment_id for o in active if o.work_type == "unplanned" and o.status in ["in_progress", "paused", "rework"]}), "active": len(active), "total": len(orders), "avg_rating": round(sum(scores) / len(scores), 2) if scores else 0, "shift_label": label}

    @app.get("/api/notifications")
    def notifications(db: DB, user: User):
        return [{"id": n.id, "title": n.title, "message": n.message, "kind": n.kind, "order_id": n.order_id, "created_at": iso(n.created_at), "read": n.read} for n in db.scalars(select(Notification).where(Notification.employee_id == user.id).order_by(Notification.created_at.desc(), Notification.id.desc()).limit(200))]

    @app.post("/api/notifications/{id_}/read")
    def mark_read(id_: int, db: DB, user: User):
        notification = db.get(Notification, id_)
        if not notification or notification.employee_id != user.id:
            raise HTTPException(404, "Уведомление не найдено")
        notification.read = True
        db.commit()
        from_thread.run(realtime.publish, "notifications.updated")
        return {"ok": True}

    @app.post("/api/devices", status_code=201)
    def register_device(payload: DeviceRegistration, db: DB, user: User):
        now = utcnow()
        device = db.scalar(select(DeviceToken).where(DeviceToken.token == payload.token))
        if device is None:
            device = DeviceToken(token=payload.token, employee_id=user.id, platform=payload.platform, app_version=payload.app_version, created_at=now, last_seen_at=now)
            db.add(device)
        else:
            device.employee_id = user.id
            device.platform = payload.platform
            device.app_version = payload.app_version
            device.last_seen_at = now
            device.revoked_at = None
        db.commit()
        return {"id": device.id, "token": device.token, "platform": device.platform, "app_version": device.app_version, "created_at": iso(device.created_at), "last_seen_at": iso(device.last_seen_at)}

    @app.post("/api/devices/unregister")
    def unregister_device(payload: DeviceUnregister, db: DB, user: User):
        device = db.scalar(select(DeviceToken).where(DeviceToken.token == payload.token, DeviceToken.employee_id == user.id))
        if device is not None and device.revoked_at is None:
            device.revoked_at = utcnow()
            db.commit()
        return {"ok": True}

    def analytics_data(db, user, days, from_date, to_date, area_id, equipment_id, assignee_id, brigade_id):
        start = parse_date(from_date) if from_date else utcnow() - timedelta(days=days)
        end = parse_date(to_date, end=True) if to_date else utcnow()
        if start > end:
            raise HTTPException(422, "Начало периода должно быть раньше окончания")
        if (end - start).days > 731:
            raise HTTPException(422, "Период не должен превышать 2 года")
        query = filtered(db, user, area_id, equipment_id, assignee_id, brigade_id).where(Order.created_at >= start, Order.created_at <= end)
        orders = list(db.scalars(query.order_by(Order.created_at.desc())))
        return orders, analytics(db, orders, start, end)

    @app.get("/api/analytics")
    def get_analytics(db: DB, user: User, days: int = Query(90, ge=1, le=731), from_date: str | None = None, to_date: str | None = None, area_id: int | None = None, equipment_id: int | None = None, assignee_id: int | None = None, brigade_id: int | None = None):
        return analytics_data(db, user, days, from_date, to_date, area_id, equipment_id, assignee_id, brigade_id)[1]

    @app.get("/api/reports/export")
    def export_report(db: DB, user: User, days: int = Query(90, ge=1, le=731), from_date: str | None = None, to_date: str | None = None, area_id: int | None = None, equipment_id: int | None = None, assignee_id: int | None = None, brigade_id: int | None = None, format: str = Query("csv", pattern="^(csv|xlsx)$")):
        orders, report = analytics_data(db, user, days, from_date, to_date, area_id, equipment_id, assignee_id, brigade_id)
        headings = ["Номер", "Работа", "Участок", "Оборудование", "Исполнитель", "Тип", "Приоритет", "Статус", "Создан", "Срок", "Завершён", "Простой, мин", "Оценка"]
        output_rows = []
        for order in orders:
            o = order_dict(db, order)
            output_rows.append([safe_cell(o[k]) for k in ["number", "title", "area_name", "equipment_name", "assignee_name", "work_type", "priority", "status", "created_at", "deadline", "completed_at", "downtime_minutes", "score"]])
        if format == "xlsx":
            from openpyxl import Workbook
            from openpyxl.styles import Font, PatternFill
            workbook = Workbook()
            sheet = workbook.active
            sheet.title = "Наряды"
            sheet.append(headings)
            for row in output_rows:
                sheet.append(row)
            sheet.freeze_panes = "A2"
            sheet.auto_filter.ref = sheet.dimensions
            for cell in sheet[1]:
                cell.font = Font(bold=True, color="FFFFFF")
                cell.fill = PatternFill("solid", fgColor="1D4B42")
            from openpyxl.utils import get_column_letter
            for column in range(1, len(headings) + 1):
                sheet.column_dimensions[get_column_letter(column)].width = 25 if column != 2 else 45
            summary_sheet = workbook.create_sheet("Сводка")
            for key, value in report["summary"].items():
                summary_sheet.append([key, value])
            summary_sheet.column_dimensions["A"].width = 30
            result = io.BytesIO()
            workbook.save(result)
            return Response(result.getvalue(), media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", headers={"Content-Disposition": 'attachment; filename="naryad-report.xlsx"'})
        result = io.StringIO()
        writer = csv.writer(result, delimiter=";")
        writer.writerow(headings)
        writer.writerows(output_rows)
        return Response(result.getvalue().encode("utf-8-sig"), media_type="text/csv; charset=utf-8", headers={"Content-Disposition": 'attachment; filename="naryad-report.csv"'})

    @app.get("/api/integrations")
    def integrations(user: User):
        require_role(user, "master", "manager", "admin")
        if isinstance(get_sender(), StubSender):
            native = {"mode": "stub", "status": "demo", "description": "Push отключён или не настроен. События сохраняются в БД; отправки на устройства нет."}
        else:
            native = {"mode": "fcm", "status": "active", "description": "Firebase Cloud Messaging (HTTP v1), Android. Доставка на устройства включена."}
        return {"ai": {"mode": "stub", "status": "demo", "description": "Детерминированная заглушка. Реальные LLM и компьютерное зрение не подключены. Итоговое решение принимает мастер."}, "native": native, "realtime": {"mode": "websocket", "status": "active", "description": "Авторизованный WebSocket и резервный опрос каждые 5 секунд."}}

    @app.websocket("/api/ws")
    @app.websocket("/ws")
    async def websocket(ws: WebSocket, token: str = ""):
        with sessions() as db:
            try:
                lookup_user(db, token)
            except HTTPException:
                await ws.close(code=1008)
                return
        await ws.accept()
        realtime.clients.add(ws)
        await ws.send_json({"type": "connected"})
        try:
            while True:
                # An idle connection must neither expire merely for being idle nor
                # retain access indefinitely after its authentication is revoked.
                try:
                    await asyncio.wait_for(ws.receive_text(), timeout=WS_AUTH_RECHECK_SECONDS)
                except asyncio.TimeoutError:
                    pass
                with sessions() as db:
                    lookup_user(db, token)
        except (WebSocketDisconnect, HTTPException):
            with suppress(Exception):
                await ws.close(code=1008)
        finally:
            realtime.clients.discard(ws)

    return app


def rows(db, model, fields):
    return [{key: getattr(obj, key) for key in fields} for obj in db.scalars(select(model).order_by(model.id))]


def parse_date(value, end=False):
    try:
        if len(value) == 10:
            day = date.fromisoformat(value)
            result = datetime.combine(day, datetime.min.time(), ZoneInfo("Asia/Almaty"))
            if end:
                result += timedelta(days=1, microseconds=-1)
            return result.astimezone(timezone.utc)
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return aware(parsed).astimezone(timezone.utc)
    except (ValueError, TypeError):
        raise HTTPException(422, "Дата должна быть в формате YYYY-MM-DD или ISO 8601")


def safe_cell(value):
    if isinstance(value, str) and value.lstrip().startswith(("=", "+", "-", "@", "\t", "\r")):
        return "'" + value
    return "" if value is None else value


app = create_app()
