"""Persist calculation snapshots and a transactional delivery queue. No ORM imports."""
import json
from datetime import date

from alembic import op
import sqlalchemy as sa

revision = "0004"
down_revision = "0003"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("employees") as batch:
        batch.add_column(sa.Column("zup_id", sa.String(100), nullable=True))
        batch.create_unique_constraint("uq_employees_zup_id", ["zup_id"])
    employees = sa.table("employees", sa.column("id"), sa.column("email"), sa.column("zup_id"))
    for employee_id, email in [(1, "employee@example.com"), (2, "manager@example.com"), (3, "hr@example.com"), (4, "outsider@example.com")]:
        op.execute(employees.update().where(employees.c.id == employee_id, employees.c.email == email).values(zup_id=f"demo-{employee_id}"))
    with op.batch_alter_table("leave_requests") as batch:
        batch.add_column(sa.Column("days_count", sa.Integer(), nullable=False, server_default="0"))
        batch.add_column(sa.Column("excluded_dates_json", sa.Text(), nullable=False, server_default="[]"))
        batch.add_column(sa.Column("calendar_version", sa.String(80), nullable=False, server_default="legacy-unquoted"))
    # Freeze the initial statutory dates here; never import today's calculator.
    holidays = ((1, 1), (1, 2), (3, 8), (3, 21), (3, 22), (3, 23), (5, 1), (5, 7), (5, 9), (7, 6), (8, 30), (10, 25), (12, 16))
    connection = op.get_bind()
    rows = connection.execute(sa.text("SELECT id,start_date,end_date FROM leave_requests")).all()
    for request_id, start, end in rows:
        start = date.fromisoformat(str(start))
        end = date.fromisoformat(str(end))
        excluded = sorted(date(year, month, day).isoformat() for year in range(start.year, end.year + 1) for month, day in holidays if start <= date(year, month, day) <= end)
        deduction = connection.execute(sa.text("SELECT days FROM leave_deductions WHERE request_id=:id"), {"id": request_id}).scalar()
        # Already recorded accounting is immutable. Such approvals are not exported
        # automatically into a freshly provisioned external system.
        count = deduction if deduction is not None else (end - start).days + 1 - len(excluded)
        version = "legacy-deducted" if deduction is not None else "legacy-unquoted"
        connection.execute(sa.text("UPDATE leave_requests SET days_count=:days,excluded_dates_json=:excluded,calendar_version=:version WHERE id=:id"), {"id": request_id, "days": count, "excluded": json.dumps(excluded), "version": version})
    with op.batch_alter_table("leave_requests") as batch:
        batch.alter_column("days_count", server_default=None)
        batch.alter_column("excluded_dates_json", server_default=None)
        batch.alter_column("calendar_version", server_default=None)
    op.create_table("zup_deliveries",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("request_id", sa.Integer(), sa.ForeignKey("leave_requests.id"), nullable=False, unique=True),
        sa.Column("command_key", sa.String(128), nullable=False, unique=True),
        sa.Column("payload_json", sa.Text(), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("reference", sa.String(100), nullable=True),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("last_error", sa.String(500), nullable=True),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("status IN ('pending','synced','error')", name="ck_zup_delivery_status"))


def downgrade():
    op.drop_table("zup_deliveries")
    with op.batch_alter_table("leave_requests") as batch:
        batch.drop_column("calendar_version")
        batch.drop_column("excluded_dates_json")
        batch.drop_column("days_count")
    with op.batch_alter_table("employees") as batch:
        batch.drop_constraint("uq_employees_zup_id", type_="unique")
        batch.drop_column("zup_id")
