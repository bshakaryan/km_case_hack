"""FCM push outbox: device token registry and pending push tasks.

Self-contained DDL on purpose: new migrations must not import the current ORM
models (the known defect of 0001_initial). Re-runnable on databases where
startup `create_all` already created the tables.
"""
import sqlalchemy as sa
from alembic import op

revision = "0003_push"
down_revision = "0002_client_commands"
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if not inspector.has_table("device_tokens"):
        op.create_table(
            "device_tokens",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("employee_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=False),
            sa.Column("token", sa.String(length=4096), nullable=False, unique=True),
            sa.Column("platform", sa.String(length=20), nullable=False),
            sa.Column("app_version", sa.String(length=40), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("last_seen_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("revoked_at", sa.DateTime(timezone=True), nullable=True),
        )
        op.create_index("ix_device_tokens_employee_id", "device_tokens", ["employee_id"])
    if not inspector.has_table("push_tasks"):
        op.create_table(
            "push_tasks",
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("notification_id", sa.Integer(), sa.ForeignKey("notifications.id"), nullable=True),
            sa.Column("employee_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=False),
            sa.Column("kind", sa.String(length=40), nullable=False),
            sa.Column("title", sa.String(length=180), nullable=False),
            sa.Column("message", sa.Text(), nullable=False),
            sa.Column("order_id", sa.Integer(), nullable=True),
            sa.Column("priority", sa.String(length=20), nullable=False, server_default="normal"),
            sa.Column("payload", sa.JSON(), nullable=False),
            sa.Column("status", sa.String(length=20), nullable=False, server_default="pending"),
            sa.Column("attempts", sa.Integer(), nullable=False, server_default="0"),
            sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("last_error", sa.Text(), nullable=True),
            sa.Column("provider_message_id", sa.String(length=180), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
            sa.Column("sent_at", sa.DateTime(timezone=True), nullable=True),
        )
        op.create_index("ix_push_tasks_employee_id", "push_tasks", ["employee_id"])
        op.create_index("ix_push_tasks_next_attempt_at", "push_tasks", ["next_attempt_at"])
        op.create_index("ix_push_tasks_status_next", "push_tasks", ["status", "next_attempt_at"])


def downgrade():
    bind = op.get_bind()
    inspector = sa.inspect(bind)
    if inspector.has_table("push_tasks"):
        op.drop_index("ix_push_tasks_status_next", table_name="push_tasks")
        op.drop_index("ix_push_tasks_next_attempt_at", table_name="push_tasks")
        op.drop_index("ix_push_tasks_employee_id", table_name="push_tasks")
        op.drop_table("push_tasks")
    if inspector.has_table("device_tokens"):
        op.drop_index("ix_device_tokens_employee_id", table_name="device_tokens")
        op.drop_table("device_tokens")
