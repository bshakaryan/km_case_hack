"""Add an immutable journal of leave deductions without changing source balances."""

from alembic import op
import sqlalchemy as sa


revision = "0003"
down_revision = "0002"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "leave_deductions",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("request_id", sa.Integer(), sa.ForeignKey("leave_requests.id"), nullable=False),
        sa.Column("employee_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=False),
        sa.Column("actor_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=False),
        sa.Column("days", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("request_id", name="uq_leave_deduction_request"),
        sa.CheckConstraint("days > 0", name="ck_leave_deduction_days"),
    )
    op.create_index("ix_leave_deductions_employee_id", "leave_deductions", ["employee_id"])


def downgrade():
    op.drop_index("ix_leave_deductions_employee_id", table_name="leave_deductions")
    op.drop_table("leave_deductions")
