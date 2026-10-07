"""Append-only assignment/submission history and conservative legacy snapshots.

Existing rows are never updated. A snapshot is not a reconstructed attempt:
its author, assignment, assessment and photo/writeoff provenance are unknown.
This frozen Core schema deliberately never imports application ORM models.
"""
import sqlalchemy as sa
from alembic import op
from alembic.operations.ops import CreateIndexOp, CreateTableOp

revision = "0004_order_history"
down_revision = "0003_push"
branch_labels = None
depends_on = None
HISTORY_TABLES = ("order_assignments", "submission_attempts", "submission_photos", "submission_writeoffs", "submission_decisions")


def schema(metadata=None):
    metadata = metadata if metadata is not None else sa.MetaData()
    # Minimal frozen parents for stand-alone DDL and backfill; the validated
    # full historical metadata is supplied by the startup schema guard.
    if "orders" not in metadata.tables:
        sa.Table("orders", metadata,
            sa.Column("id", sa.Integer(), primary_key=True),
            sa.Column("assignee_id", sa.Integer()), sa.Column("brigade_id", sa.Integer()),
            sa.Column("assigned_at", sa.DateTime(timezone=True)),
            sa.Column("completed_at", sa.DateTime(timezone=True)),
            sa.Column("completion", sa.JSON()), sa.Column("ai_review", sa.JSON()))
    for parent in ("employees", "brigades", "photos", "material_writeoffs", "ai_assessments"):
        if parent not in metadata.tables:
            sa.Table(parent, metadata, sa.Column("id", sa.Integer(), primary_key=True))
    sa.Table("order_assignments", metadata,
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("order_id", sa.Integer(), sa.ForeignKey("orders.id"), nullable=False, index=True),
        sa.Column("sequence", sa.Integer(), nullable=False),
        sa.Column("assignee_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=False),
        sa.Column("brigade_id", sa.Integer(), sa.ForeignKey("brigades.id"), nullable=True),
        sa.Column("assigned_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ended_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("assigned_by_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=True),
        sa.Column("source", sa.String(20), nullable=False),
        sa.UniqueConstraint("order_id", "sequence", name="uq_order_assignment_sequence"),
        sa.CheckConstraint("source IN ('live','legacy_snapshot')", name="ck_assignment_source"))
    sa.Table("submission_attempts", metadata,
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("order_id", sa.Integer(), sa.ForeignKey("orders.id"), nullable=False, index=True),
        sa.Column("sequence", sa.Integer(), nullable=False),
        sa.Column("assignment_id", sa.Integer(), sa.ForeignKey("order_assignments.id"), nullable=True),
        sa.Column("submitted_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("author_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=True),
        sa.Column("payload", sa.JSON(), nullable=False),
        sa.Column("ai_review", sa.JSON(), nullable=True),
        sa.Column("assessment_id", sa.Integer(), sa.ForeignKey("ai_assessments.id"), nullable=True),
        sa.Column("source", sa.String(20), nullable=False),
        sa.UniqueConstraint("order_id", "sequence", name="uq_submission_attempt_sequence"),
        sa.CheckConstraint("source IN ('live','legacy_snapshot')", name="ck_submission_source"),
        sa.CheckConstraint("source != 'live' OR (submitted_at IS NOT NULL AND author_id IS NOT NULL AND assignment_id IS NOT NULL)", name="ck_submission_live_identity"))
    sa.Table("submission_photos", metadata,
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("attempt_id", sa.Integer(), sa.ForeignKey("submission_attempts.id"), nullable=False, index=True),
        sa.Column("photo_id", sa.Integer(), sa.ForeignKey("photos.id"), nullable=False),
        sa.UniqueConstraint("attempt_id", "photo_id", name="uq_submission_photo"))
    sa.Table("submission_writeoffs", metadata,
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("attempt_id", sa.Integer(), sa.ForeignKey("submission_attempts.id"), nullable=False, index=True),
        sa.Column("writeoff_id", sa.Integer(), sa.ForeignKey("material_writeoffs.id"), nullable=False),
        sa.UniqueConstraint("writeoff_id", name="uq_submission_writeoff"))
    sa.Table("submission_decisions", metadata,
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("attempt_id", sa.Integer(), sa.ForeignKey("submission_attempts.id"), nullable=False, index=True),
        sa.Column("actor_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=False),
        sa.Column("action", sa.String(20), nullable=False),
        sa.Column("score", sa.Float(), nullable=True),
        sa.Column("comment", sa.Text(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.CheckConstraint("action IN ('close','rework')", name="ck_submission_decision_action"),
        sa.CheckConstraint("score IS NULL OR (score >= 1 AND score <= 5)", name="ck_submission_decision_score"))
    return metadata


def backfill_legacy(connection):
    """Also used for newly seeded *historical* demo rows; safe to repeat."""
    metadata = schema()
    orders = metadata.tables["orders"]
    assignments = metadata.tables["order_assignments"]
    attempts = metadata.tables["submission_attempts"]
    known_assignments = set(connection.execute(sa.select(assignments.c.order_id)).scalars())
    known_attempts = set(connection.execute(sa.select(attempts.c.order_id)).scalars())
    for row in connection.execute(sa.select(orders)).mappings():
        if row["id"] not in known_assignments:
            connection.execute(assignments.insert(), {
                "order_id": row["id"], "sequence": 1, "assignee_id": row["assignee_id"],
                "brigade_id": row["brigade_id"], "assigned_at": row["assigned_at"],
                "ended_at": None, "assigned_by_id": None, "source": "legacy_snapshot"})
        if row["completion"] is not None and row["id"] not in known_attempts:
            connection.execute(attempts.insert(), {
                "order_id": row["id"], "sequence": 1, "assignment_id": None,
                "submitted_at": row["completed_at"], "author_id": None,
                "payload": row["completion"], "ai_review": row["ai_review"],
                "assessment_id": None, "source": "legacy_snapshot"})


def upgrade():
    metadata = schema()
    for table in metadata.sorted_tables:
        if table.name in HISTORY_TABLES:
            op.invoke(CreateTableOp.from_table(table))
            for index in sorted(table.indexes, key=lambda item: item.name):
                op.invoke(CreateIndexOp.from_index(index))
    backfill_legacy(op.get_bind())


def downgrade():
    for table in ("submission_decisions", "submission_writeoffs", "submission_photos", "submission_attempts", "order_assignments"):
        op.drop_table(table)
