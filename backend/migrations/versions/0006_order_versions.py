"""Order optimistic versions and immutable command receipts.

Existing orders start at version 1. Historical command receipts stay unknown:
an old response cannot safely prove a version of the newly versioned order.
Frozen Core schema, independent of the current application ORM.
"""
import sqlalchemy as sa
from alembic import op

revision = "0006_order_versions"
down_revision = "0005_ai_review_jobs"
branch_labels = None
depends_on = None

RECEIPT_CHECK = "(order_id IS NULL AND order_version IS NULL) OR (order_id IS NOT NULL AND order_version IS NOT NULL AND order_version > 0)"


def schema(metadata):
    orders = metadata.tables["orders"]
    orders.append_column(sa.Column("version", sa.Integer(), nullable=False))
    orders.append_constraint(sa.CheckConstraint("version > 0", name="ck_order_version"))
    commands = metadata.tables["client_commands"]
    commands.append_column(sa.Column("order_id", sa.Integer(), sa.ForeignKey("orders.id"), nullable=True))
    commands.append_column(sa.Column("order_version", sa.Integer(), nullable=True))
    commands.append_constraint(sa.CheckConstraint(RECEIPT_CHECK, name="ck_client_command_order_receipt"))
    return metadata


def upgrade():
    op.add_column("orders", sa.Column("version", sa.Integer(), nullable=True))
    op.execute(sa.text("UPDATE orders SET version = 1"))
    with op.batch_alter_table("orders") as batch:
        batch.alter_column("version", existing_type=sa.Integer(), nullable=False)
        batch.create_check_constraint("ck_order_version", "version > 0")
    with op.batch_alter_table("client_commands") as batch:
        batch.add_column(sa.Column("order_id", sa.Integer(), nullable=True))
        batch.add_column(sa.Column("order_version", sa.Integer(), nullable=True))
        batch.create_foreign_key("fk_client_command_order_receipt", "orders", ["order_id"], ["id"])
        batch.create_check_constraint("ck_client_command_order_receipt", RECEIPT_CHECK)


def downgrade():
    with op.batch_alter_table("client_commands") as batch:
        batch.drop_constraint("ck_client_command_order_receipt", type_="check")
        batch.drop_constraint("fk_client_command_order_receipt", type_="foreignkey")
        batch.drop_column("order_version")
        batch.drop_column("order_id")
    with op.batch_alter_table("orders") as batch:
        batch.drop_constraint("ck_order_version", type_="check")
        batch.drop_column("version")
