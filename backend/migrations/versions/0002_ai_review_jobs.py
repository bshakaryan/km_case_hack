"""Persist AI review jobs for submitted orders."""
from alembic import op
import sqlalchemy as sa

revision = "0002_ai_review_jobs"
down_revision = "0001_initial"
branch_labels = None
depends_on = None


def upgrade():
    if sa.inspect(op.get_bind()).has_table("ai_review_jobs"):
        return
    op.create_table(
        "ai_review_jobs",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("order_id", sa.Integer(), sa.ForeignKey("orders.id"), nullable=False),
        sa.Column("completion_event_id", sa.Integer(), sa.ForeignKey("order_events.id"), nullable=False, unique=True),
        sa.Column("snapshot", sa.JSON(), nullable=False),
        sa.Column("photo_ids", sa.JSON(), nullable=False),
        sa.Column("result", sa.JSON(), nullable=True),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("next_run_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("lease_until", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_ai_review_jobs_order_id", "ai_review_jobs", ["order_id"])
    op.create_index("ix_ai_review_jobs_status", "ai_review_jobs", ["status"])


def downgrade():
    op.drop_index("ix_ai_review_jobs_status", table_name="ai_review_jobs")
    op.drop_index("ix_ai_review_jobs_order_id", table_name="ai_review_jobs")
    op.drop_table("ai_review_jobs")
