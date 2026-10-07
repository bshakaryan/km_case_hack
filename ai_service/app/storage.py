from datetime import datetime, timezone
from pathlib import Path

from sqlalchemy import JSON, DateTime, String, UniqueConstraint, create_engine, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker
from sqlalchemy.pool import StaticPool

from .config import BASE_DIR


class Base(DeclarativeBase):
    pass


class AIResult(Base):
    __tablename__ = "ai_results"
    __table_args__ = (UniqueConstraint("kind", "subject_id", "source_version"),)

    id: Mapped[int] = mapped_column(primary_key=True)
    kind: Mapped[str] = mapped_column(String(40))
    subject_id: Mapped[str] = mapped_column(String(80))
    source_version: Mapped[str] = mapped_column(String(120))
    payload: Mapped[dict] = mapped_column(JSON)
    master_override: Mapped[dict | None] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class AINotification(Base):
    __tablename__ = "ai_notifications"

    id: Mapped[int] = mapped_column(primary_key=True)
    idempotency_key: Mapped[str] = mapped_column(String(180), unique=True)
    recipient: Mapped[str] = mapped_column(String(80))
    channel: Mapped[str] = mapped_column(String(40))
    status: Mapped[str] = mapped_column(String(30))
    payload: Mapped[dict] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class AILLMCache(Base):
    __tablename__ = "ai_llm_cache"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    provider: Mapped[str] = mapped_column(String(30))
    model: Mapped[str] = mapped_column(String(120))
    response: Mapped[dict] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=lambda: datetime.now(timezone.utc))


class AIStore:
    def __init__(self, database_url: str, confirmed_separate: bool = False):
        url = make_url(database_url)
        backend = url.get_backend_name()
        if backend == "sqlite":
            if not url.database:
                raise ValueError("SQLite URL должен указывать на БД ИИ-сервиса")
            if url.database != ":memory:":
                database = Path(url.database).resolve()
                if not database.is_relative_to((BASE_DIR / "state").resolve()):
                    raise ValueError("SQLite БД ИИ-сервиса должна находиться в ai_service/state")
        elif backend == "postgresql":
            if not confirmed_separate or url.database in {"naryad_ai", "naryad"}:
                raise ValueError("PostgreSQL доступен только после подтверждения отдельной БД ИИ")
        else:
            raise ValueError("Поддерживается только отдельная SQLite или PostgreSQL БД ИИ")
        engine_options = {"pool_pre_ping": True}
        if backend == "sqlite" and url.database == ":memory:":
            engine_options.update(connect_args={"check_same_thread": False}, poolclass=StaticPool)
        self.engine = create_engine(database_url, **engine_options)
        self.sessions = sessionmaker(bind=self.engine, expire_on_commit=False)

    def initialize(self):
        database = make_url(str(self.engine.url)).database
        if self.engine.dialect.name == "sqlite" and database != ":memory:":
            Path(database).parent.mkdir(parents=True, exist_ok=True)
        Base.metadata.create_all(self.engine)

    def ping(self):
        with self.engine.connect() as connection:
            connection.execute(text("SELECT 1"))

    def put_result(self, kind: str, subject_id: str, source_version: str, payload: dict):
        lookup = select(AIResult.id).where(AIResult.kind == kind, AIResult.subject_id == subject_id, AIResult.source_version == source_version)
        try:
            with self.sessions.begin() as session:
                existing_id = session.scalar(lookup)
                if existing_id:
                    return existing_id
                result = AIResult(kind=kind, subject_id=subject_id, source_version=source_version, payload=payload)
                session.add(result)
                session.flush()
                return result.id
        except IntegrityError:
            with self.sessions() as session:
                return session.scalar(lookup)

    def get_result(self, kind: str, subject_id: str, source_version: str):
        with self.sessions() as session:
            result = session.scalar(select(AIResult).where(
                AIResult.kind == kind, AIResult.subject_id == subject_id,
                AIResult.source_version == source_version,
            ))
            if result is None:
                return None
            return {"payload": result.payload, "master_override": result.master_override,
                    "source_version": result.source_version}

    def set_master_override(self, kind: str, subject_id: str, source_version: str, override: dict):
        with self.sessions.begin() as session:
            result = session.scalar(select(AIResult).where(
                AIResult.kind == kind, AIResult.subject_id == subject_id,
                AIResult.source_version == source_version,
            ))
            if result is None:
                return False
            result.master_override = override
            return True

    def update_result(self, kind: str, subject_id: str, source_version: str, payload: dict):
        with self.sessions.begin() as session:
            result = session.scalar(select(AIResult).where(
                AIResult.kind == kind, AIResult.subject_id == subject_id,
                AIResult.source_version == source_version,
            ))
            if result is None:
                return False
            result.payload = payload
            return True

    def list_results(self, kind: str):
        with self.sessions() as session:
            results = session.scalars(select(AIResult).where(AIResult.kind == kind)).all()
            return [{"subject_id": item.subject_id, "source_version": item.source_version,
                     "payload": item.payload, "master_override": item.master_override} for item in results]

    def enqueue_notification(self, key: str, recipient: str, payload: dict):
        try:
            with self.sessions.begin() as session:
                session.add(AINotification(idempotency_key=key, recipient=recipient,
                                           channel="pending", status="pending", payload=payload))
                session.flush()
            return True
        except IntegrityError:
            return False

    def mark_notification(self, key: str, channel: str, delivered: bool):
        with self.sessions.begin() as session:
            notification = session.scalar(select(AINotification).where(AINotification.idempotency_key == key))
            if notification is not None:
                notification.channel = channel
                notification.status = "delivered" if delivered else "undelivered"

    def get_cached(self, key: str):
        with self.sessions() as session:
            item = session.get(AILLMCache, key)
            return item.response if item else None

    def put_cached(self, key: str, provider: str, model: str, response: dict):
        try:
            with self.sessions.begin() as session:
                session.add(AILLMCache(key=key, provider=provider, model=model, response=response))
                session.flush()
        except IntegrityError:
            pass

    def close(self):
        self.engine.dispose()
