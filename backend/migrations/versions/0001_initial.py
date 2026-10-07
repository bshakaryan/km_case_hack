"""Frozen schema from 322c3d4, repaired to remove mutable ORM imports.

Existing complete legacy schemas are validated before this migration adopts
them. The schema() snapshot must not change when application models evolve.
"""
import sqlalchemy as sa
from alembic import op
from alembic.operations.ops import CreateIndexOp, CreateTableOp

revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None


def schema():
    metadata = sa.MetaData()
    sa.Table("areas", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("name", sa.String(120), unique=True, nullable=False),
    )
    sa.Table("brigades", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("name", sa.String(120), unique=True, nullable=False),
    )
    sa.Table("employees", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("login", sa.String(80), unique=True, nullable=False),
        sa.Column("role", sa.String(20), nullable=False),
        sa.Column("pin_hash", sa.String(250), nullable=False),
        sa.Column("specialty", sa.String(120), nullable=False),
        sa.Column("grade", sa.Integer, nullable=False),
        sa.Column("brigade_id", sa.Integer(), sa.ForeignKey('brigades.id'), nullable=True),
        sa.Column("on_shift", sa.Boolean, nullable=False),
    )
    sa.Table("auth_sessions", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("token_hash", sa.String(64), unique=True, index=True, nullable=False),
        sa.Column("employee_id", sa.Integer(), sa.ForeignKey('employees.id'), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
    )
    sa.Table("equipment", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("inventory_number", sa.String(80), unique=True, nullable=False),
        sa.Column("area_id", sa.Integer(), sa.ForeignKey('areas.id'), index=True, nullable=False),
        sa.Column("type", sa.String(80), nullable=False),
        sa.Column("criticality", sa.String(40), nullable=False),
    )
    sa.Table("fault_codes", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("code", sa.String(30), unique=True, nullable=False),
        sa.Column("name", sa.String(180), nullable=False),
    )
    sa.Table("materials", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("name", sa.String(180), nullable=False),
        sa.Column("unit", sa.String(30), nullable=False),
    )
    sa.Table("time_norms", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("name", sa.String(180), nullable=False),
        sa.Column("hours", sa.Float, nullable=False),
    )
    sa.Table("orders", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("number", sa.String(40), unique=True, index=True, nullable=False),
        sa.Column("title", sa.String(200), nullable=False),
        sa.Column("description", sa.Text, nullable=False),
        sa.Column("work_type", sa.String(20), nullable=False),
        sa.Column("area_id", sa.Integer(), sa.ForeignKey('areas.id'), index=True, nullable=False),
        sa.Column("equipment_id", sa.Integer(), sa.ForeignKey('equipment.id'), index=True, nullable=False),
        sa.Column("assignee_id", sa.Integer(), sa.ForeignKey('employees.id'), index=True, nullable=False),
        sa.Column("brigade_id", sa.Integer(), sa.ForeignKey('brigades.id'), nullable=True),
        sa.Column("master_id", sa.Integer(), sa.ForeignKey('employees.id'), index=True, nullable=False),
        sa.Column("priority", sa.String(20), nullable=False),
        sa.Column("status", sa.String(30), index=True, nullable=False),
        sa.Column("deadline", sa.DateTime(timezone=True), index=True, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), index=True, nullable=False),
        sa.Column("started_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("completed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("closed_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("comment", sa.Text, nullable=False),
        sa.Column("normal_hours", sa.Float, nullable=False),
        sa.Column("downtime_minutes", sa.Float, nullable=False),
        sa.Column("score", sa.Float, nullable=True),
        sa.Column("completion", sa.JSON, nullable=True),
        sa.Column("ai_review", sa.JSON, nullable=True),
        sa.CheckConstraint("status IN ('issued','accepted','queued','rejected','in_progress','paused','completed','ai_review','rework','closed','cancelled')", name='ck_order_status'),
        sa.CheckConstraint("priority IN ('emergency','high','normal','planned')", name='ck_order_priority'),
        sa.CheckConstraint("work_type IN ('planned','unplanned')", name='ck_order_work_type'),
        sa.CheckConstraint('normal_hours > 0', name='ck_order_hours'),
        sa.CheckConstraint('score IS NULL OR (score >= 1 AND score <= 5)', name='ck_order_score'),
    )
    sa.Table("order_events", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("order_id", sa.Integer(), sa.ForeignKey('orders.id'), index=True, nullable=False),
        sa.Column("action", sa.String(40), nullable=False),
        sa.Column("from_status", sa.String(30), nullable=True),
        sa.Column("to_status", sa.String(30), nullable=False),
        sa.Column("actor_id", sa.Integer(), sa.ForeignKey('employees.id'), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("comment", sa.Text, nullable=False),
    )
    sa.Table("photos", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("order_id", sa.Integer(), sa.ForeignKey('orders.id'), index=True, nullable=False),
        sa.Column("kind", sa.String(10), nullable=False),
        sa.Column("data", sa.LargeBinary, nullable=False),
        sa.Column("author_id", sa.Integer(), sa.ForeignKey('employees.id'), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("kind IN ('before','after')", name='ck_photo_kind'),
    )
    sa.Table("notifications", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("employee_id", sa.Integer(), sa.ForeignKey('employees.id'), index=True, nullable=False),
        sa.Column("title", sa.String(180), nullable=False),
        sa.Column("message", sa.Text, nullable=False),
        sa.Column("kind", sa.String(40), nullable=False),
        sa.Column("order_id", sa.Integer(), sa.ForeignKey('orders.id'), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("read", sa.Boolean, nullable=False),
        sa.Column("dedupe_key", sa.String(180), nullable=True),
        sa.UniqueConstraint('dedupe_key'),
    )
    sa.Table("integration_logs", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("adapter", sa.String(40), nullable=False),
        sa.Column("operation", sa.String(80), nullable=False),
        sa.Column("payload", sa.JSON, nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    sa.Table("material_writeoffs", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("order_id", sa.Integer(), sa.ForeignKey('orders.id'), index=True, nullable=False),
        sa.Column("material_id", sa.Integer(), sa.ForeignKey('materials.id'), nullable=False),
        sa.Column("quantity", sa.Float, nullable=False),
        sa.Column("author_id", sa.Integer(), sa.ForeignKey('employees.id'), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint('quantity > 0', name='ck_writeoff_quantity'),
    )
    sa.Table("ai_assessments", metadata,
        sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
        sa.Column("order_id", sa.Integer(), sa.ForeignKey('orders.id'), index=True, nullable=False),
        sa.Column("verdict", sa.String(40), nullable=False),
        sa.Column("score", sa.Float, nullable=False),
        sa.Column("explanation", sa.Text, nullable=False),
        sa.Column("is_stub", sa.Boolean, nullable=False),
        sa.Column("master_score", sa.Float, nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    return metadata


def upgrade():
    # Startup and env.py have already validated any pre-existing legacy schema.
    existing = set(sa.inspect(op.get_bind()).get_table_names())
    for table in schema().sorted_tables:
        if table.name in existing:
            continue
        op.invoke(CreateTableOp.from_table(table))
        for index in sorted(table.indexes, key=lambda item: item.name):
            op.invoke(CreateIndexOp.from_index(index))


def downgrade():
    for table in reversed(schema().sorted_tables):
        op.drop_table(table.name)
