"""Frozen submission context and truthful unknown AI scores.

Existing attempts keep NULL context: mutable current order fields cannot prove
the original task of an old submission. Historical scores and all links stay
unchanged. Frozen Core schema, independent of the current application ORM.
"""
import sqlalchemy as sa
from alembic import op

revision = "0008_ai_attempt_input"
down_revision = "0007_assignment_participants"
branch_labels = None
depends_on = None


def schema(metadata):
    metadata.tables["submission_attempts"].append_column(
        sa.Column("ai_input", sa.JSON(none_as_null=True), nullable=True))
    metadata.tables["ai_assessments"].c.score.nullable = True
    return metadata


def upgrade():
    # The startup migration lane suspends SQLite FK checks before BEGIN,
    # validates every relationship before commit, then restores enforcement.
    # Recreating the referenced assessment table here retains every old ID.
    with op.batch_alter_table("ai_assessments") as batch:
        batch.alter_column("score", existing_type=sa.Float(), nullable=True)
    op.add_column("submission_attempts",
        sa.Column("ai_input", sa.JSON(none_as_null=True), nullable=True))


def downgrade():
    # An older required-score schema cannot represent an unknown result. Do
    # not fabricate a score or delete the assessment to force a downgrade.
    if op.get_bind().execute(sa.text(
        "SELECT id FROM ai_assessments WHERE score IS NULL LIMIT 1")).first():
        raise RuntimeError("Cannot downgrade while unknown AI scores exist")
    if op.get_bind().execute(sa.text(
        "SELECT id FROM submission_attempts WHERE ai_input IS NOT NULL LIMIT 1")).first():
        raise RuntimeError("Cannot downgrade while frozen AI context exists")
    with op.batch_alter_table("submission_attempts") as batch:
        batch.drop_column("ai_input")
    with op.batch_alter_table("ai_assessments") as batch:
        batch.alter_column("score", existing_type=sa.Float(), nullable=False)
