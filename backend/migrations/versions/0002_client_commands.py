"""Idempotency keys for offline client commands (X-Client-Command-Id).

Self-contained DDL on purpose: new migrations must not import the current ORM
models (the known defect of 0001_initial). Re-runnable on databases where
startup `create_all` already created the table.
"""
import sqlalchemy as sa
from alembic import op

revision = "0002_client_commands"
down_revision = "0001_initial"
branch_labels = None
depends_on = None


def upgrade():
    bind = op.get_bind()
    if sa.inspect(bind).has_table("client_commands"):
        return
    op.create_table(
        "client_commands",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("employee_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=False),
        sa.Column("client_id", sa.String(length=64), nullable=False),
        sa.Column("kind", sa.String(length=40), nullable=False),
        sa.Column("request_hash", sa.String(length=64), nullable=False),
        sa.Column("response_status", sa.Integer(), nullable=True),
        sa.Column("response_body", sa.JSON(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("employee_id", "client_id", name="uq_client_command_employee_client"),
    )
    op.create_index("ix_client_commands_employee_id", "client_commands", ["employee_id"])


def downgrade():
    bind = op.get_bind()
    if not sa.inspect(bind).has_table("client_commands"):
        return
    op.drop_index("ix_client_commands_employee_id", table_name="client_commands")
    op.drop_table("client_commands")
