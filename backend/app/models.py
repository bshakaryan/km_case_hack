from datetime import datetime, timezone
from sqlalchemy import Boolean, CheckConstraint, DateTime, Float, ForeignKey, Integer, JSON, LargeBinary, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column
from .db import Base


def utcnow():
    return datetime.now(timezone.utc)


class Area(Base):
    __tablename__ = "areas"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(120), unique=True)


class Brigade(Base):
    __tablename__ = "brigades"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(120), unique=True)


class Employee(Base):
    __tablename__ = "employees"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    login: Mapped[str] = mapped_column(String(80), unique=True)
    role: Mapped[str] = mapped_column(String(20))
    pin_hash: Mapped[str] = mapped_column(String(250))
    specialty: Mapped[str] = mapped_column(String(120), default="")
    grade: Mapped[int] = mapped_column(Integer, default=0)
    brigade_id: Mapped[int | None] = mapped_column(ForeignKey("brigades.id"))
    on_shift: Mapped[bool] = mapped_column(Boolean, default=True)


class AuthSession(Base):
    __tablename__ = "auth_sessions"
    id: Mapped[int] = mapped_column(primary_key=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, index=True)
    employee_id: Mapped[int] = mapped_column(ForeignKey("employees.id"))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class Equipment(Base):
    __tablename__ = "equipment"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    inventory_number: Mapped[str] = mapped_column(String(80), unique=True)
    area_id: Mapped[int] = mapped_column(ForeignKey("areas.id"), index=True)
    type: Mapped[str] = mapped_column(String(80))
    criticality: Mapped[str] = mapped_column(String(40), default="medium")


class FaultCode(Base):
    __tablename__ = "fault_codes"
    id: Mapped[int] = mapped_column(primary_key=True)
    code: Mapped[str] = mapped_column(String(30), unique=True)
    name: Mapped[str] = mapped_column(String(180))


class Material(Base):
    __tablename__ = "materials"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(180))
    unit: Mapped[str] = mapped_column(String(30))


class TimeNorm(Base):
    __tablename__ = "time_norms"
    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(180))
    hours: Mapped[float] = mapped_column(Float)


class Order(Base):
    __tablename__ = "orders"
    __table_args__ = (
        CheckConstraint("status IN ('issued','accepted','queued','rejected','in_progress','paused','completed','ai_review','rework','closed','cancelled')", name="ck_order_status"),
        CheckConstraint("priority IN ('emergency','high','normal','planned')", name="ck_order_priority"),
        CheckConstraint("work_type IN ('planned','unplanned')", name="ck_order_work_type"),
        CheckConstraint("normal_hours > 0", name="ck_order_hours"),
        CheckConstraint("score IS NULL OR (score >= 1 AND score <= 5)", name="ck_order_score"),
    )
    id: Mapped[int] = mapped_column(primary_key=True)
    number: Mapped[str] = mapped_column(String(40), unique=True, index=True)
    title: Mapped[str] = mapped_column(String(200))
    description: Mapped[str] = mapped_column(Text, default="")
    work_type: Mapped[str] = mapped_column(String(20))
    area_id: Mapped[int] = mapped_column(ForeignKey("areas.id"), index=True)
    equipment_id: Mapped[int] = mapped_column(ForeignKey("equipment.id"), index=True)
    assignee_id: Mapped[int] = mapped_column(ForeignKey("employees.id"), index=True)
    brigade_id: Mapped[int | None] = mapped_column(ForeignKey("brigades.id"))
    master_id: Mapped[int] = mapped_column(ForeignKey("employees.id"), index=True)
    priority: Mapped[str] = mapped_column(String(20))
    status: Mapped[str] = mapped_column(String(30), index=True)
    deadline: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, index=True)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    closed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    comment: Mapped[str] = mapped_column(Text, default="")
    normal_hours: Mapped[float] = mapped_column(Float, default=2)
    downtime_minutes: Mapped[float] = mapped_column(Float, default=0)
    score: Mapped[float | None] = mapped_column(Float)
    completion: Mapped[dict | None] = mapped_column(JSON)
    ai_review: Mapped[dict | None] = mapped_column(JSON)


class OrderEvent(Base):
    __tablename__ = "order_events"
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    action: Mapped[str] = mapped_column(String(40))
    from_status: Mapped[str | None] = mapped_column(String(30))
    to_status: Mapped[str] = mapped_column(String(30))
    actor_id: Mapped[int] = mapped_column(ForeignKey("employees.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    comment: Mapped[str] = mapped_column(Text, default="")


class Photo(Base):
    __tablename__ = "photos"
    __table_args__ = (CheckConstraint("kind IN ('before','after')", name="ck_photo_kind"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    kind: Mapped[str] = mapped_column(String(10))
    data: Mapped[bytes] = mapped_column(LargeBinary)
    author_id: Mapped[int] = mapped_column(ForeignKey("employees.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Notification(Base):
    __tablename__ = "notifications"
    __table_args__ = (UniqueConstraint("dedupe_key"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    employee_id: Mapped[int] = mapped_column(ForeignKey("employees.id"), index=True)
    title: Mapped[str] = mapped_column(String(180))
    message: Mapped[str] = mapped_column(Text)
    kind: Mapped[str] = mapped_column(String(40))
    order_id: Mapped[int | None] = mapped_column(ForeignKey("orders.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    read: Mapped[bool] = mapped_column(Boolean, default=False)
    dedupe_key: Mapped[str | None] = mapped_column(String(180))


class ClientCommand(Base):
    __tablename__ = "client_commands"
    __table_args__ = (UniqueConstraint("employee_id", "client_id", name="uq_client_command_employee_client"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    employee_id: Mapped[int] = mapped_column(ForeignKey("employees.id"), index=True)
    client_id: Mapped[str] = mapped_column(String(64))
    kind: Mapped[str] = mapped_column(String(40))
    request_hash: Mapped[str] = mapped_column(String(64))
    response_status: Mapped[int | None] = mapped_column(Integer)
    response_body: Mapped[dict | None] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class IntegrationLog(Base):
    __tablename__ = "integration_logs"
    id: Mapped[int] = mapped_column(primary_key=True)
    adapter: Mapped[str] = mapped_column(String(40))
    operation: Mapped[str] = mapped_column(String(80))
    payload: Mapped[dict] = mapped_column(JSON)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class MaterialWriteoff(Base):
    __tablename__ = "material_writeoffs"
    __table_args__ = (CheckConstraint("quantity > 0", name="ck_writeoff_quantity"),)
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    material_id: Mapped[int] = mapped_column(ForeignKey("materials.id"))
    quantity: Mapped[float] = mapped_column(Float)
    author_id: Mapped[int] = mapped_column(ForeignKey("employees.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class AIAssessment(Base):
    __tablename__ = "ai_assessments"
    id: Mapped[int] = mapped_column(primary_key=True)
    order_id: Mapped[int] = mapped_column(ForeignKey("orders.id"), index=True)
    verdict: Mapped[str] = mapped_column(String(40))
    score: Mapped[float] = mapped_column(Float)
    explanation: Mapped[str] = mapped_column(Text)
    is_stub: Mapped[bool] = mapped_column(Boolean, default=True)
    master_score: Mapped[float | None] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
