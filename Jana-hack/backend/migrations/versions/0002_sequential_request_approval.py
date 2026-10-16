"""Add the manager-approved stage without importing current ORM models."""

from alembic import op


revision = "0002"
down_revision = "0001"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("leave_requests") as batch:
        batch.drop_constraint("ck_request_status", type_="check")
        batch.create_check_constraint(
            "ck_request_status",
            "status IN ('submitted','manager_approved','approved','rejected')",
        )


def downgrade():
    # A pending second-stage approval becomes pending manager approval again.
    op.execute("UPDATE leave_requests SET status = 'submitted' WHERE status = 'manager_approved'")
    with op.batch_alter_table("leave_requests") as batch:
        batch.drop_constraint("ck_request_status", type_="check")
        batch.create_check_constraint(
            "ck_request_status",
            "status IN ('submitted','approved','rejected')",
        )
