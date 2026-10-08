"""Immutable assignment roster; existing crews cannot be reconstructed.

Only the known assignee is retained for each old assignment. Frozen Core DDL
and backfill never import current ORM models or derive old crews from brigades.
"""
import sqlalchemy as sa
from alembic import op
from alembic.operations.ops import CreateIndexOp, CreateTableOp

revision = "0007_assignment_participants"
down_revision = "0006_order_versions"
branch_labels = None
depends_on = None


def schema(metadata=None):
    metadata = metadata if metadata is not None else sa.MetaData()
    if "order_assignments" not in metadata.tables:
        sa.Table("order_assignments", metadata,
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("assignee_id", sa.Integer(), nullable=False))
    if "employees" not in metadata.tables:
        sa.Table("employees", metadata, sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("name", sa.String(120), nullable=False))
    sa.Table("order_assignment_participants", metadata,
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("assignment_id", sa.Integer(), sa.ForeignKey("order_assignments.id"), nullable=False, index=True),
        sa.Column("employee_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=False, index=True),
        sa.Column("name", sa.String(120), nullable=False),
        sa.Column("source", sa.String(20), nullable=False),
        sa.UniqueConstraint("assignment_id", "employee_id", name="uq_assignment_participant"),
        sa.CheckConstraint("source IN ('live','legacy_snapshot')", name="ck_assignment_participant_source"))
    return metadata


def backfill_legacy(connection):
    """Idempotent and also suitable for historical demonstration seed rows."""
    metadata = schema()
    assignments = metadata.tables["order_assignments"]
    employees = metadata.tables["employees"]
    participants = metadata.tables["order_assignment_participants"]
    known = set(connection.execute(sa.select(participants.c.assignment_id)).scalars())
    rows = connection.execute(sa.select(assignments.c.id, assignments.c.assignee_id, employees.c.name)
        .join(employees, employees.c.id == assignments.c.assignee_id)).mappings()
    for row in rows:
        if row["id"] not in known:
            connection.execute(participants.insert(), {
                "assignment_id": row["id"], "employee_id": row["assignee_id"],
                "name": row["name"], "source": "legacy_snapshot"})


def upgrade():
    table = schema().tables["order_assignment_participants"]
    op.invoke(CreateTableOp.from_table(table))
    for index in sorted(table.indexes, key=lambda item: item.name):
        op.invoke(CreateIndexOp.from_index(index))
    backfill_legacy(op.get_bind())


def downgrade():
    op.drop_table("order_assignment_participants")
