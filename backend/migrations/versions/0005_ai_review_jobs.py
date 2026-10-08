"""Durable review jobs for new submissions only. No historical enqueue.

Frozen Core schema: never imports the current application ORM. Lease tokens
fence a worker result; the worker applies that result and marks success in one
transaction, rechecking the current attempt and lease first.
"""
import sqlalchemy as sa
from alembic import op
from alembic.operations.ops import CreateIndexOp, CreateTableOp

revision = "0005_ai_review_jobs"
down_revision = "0004_order_history"
branch_labels = None
depends_on = None


def schema(metadata=None):
    metadata = metadata if metadata is not None else sa.MetaData()
    if "submission_attempts" not in metadata.tables:
        sa.Table("submission_attempts", metadata, sa.Column("id", sa.Integer(), primary_key=True))
    sa.Table("ai_review_jobs", metadata,
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("attempt_id", sa.Integer(), sa.ForeignKey("submission_attempts.id"), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("provider", sa.String(40), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("max_attempts", sa.Integer(), nullable=False),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("lease_token", sa.String(64), nullable=True),
        sa.Column("lease_expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("last_error_code", sa.String(80), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True), nullable=True),
        sa.UniqueConstraint("attempt_id", name="uq_ai_review_job_attempt"),
        sa.CheckConstraint("status IN ('pending','running','succeeded','failed','superseded')", name="ck_ai_review_job_status"),
        sa.CheckConstraint("attempts >= 0", name="ck_ai_review_job_attempts"),
        sa.CheckConstraint("max_attempts > 0", name="ck_ai_review_job_max_attempts"),
        sa.Index("ix_ai_review_jobs_status_next", "status", "next_attempt_at"),
        sa.Index("ix_ai_review_jobs_status_lease", "status", "lease_expires_at"))
    return metadata


def upgrade():
    table = schema().tables["ai_review_jobs"]
    op.invoke(CreateTableOp.from_table(table))
    for index in sorted(table.indexes, key=lambda item: item.name):
        op.invoke(CreateIndexOp.from_index(index))


def downgrade():
    op.drop_table("ai_review_jobs")
