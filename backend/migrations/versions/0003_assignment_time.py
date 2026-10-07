"""Current assignment time, recovered conservatively from legacy audit."""
import re
from datetime import timezone

import sqlalchemy as sa
from alembic import op

revision = "0003_assignment_time"
down_revision = "0002_client_commands"
branch_labels = None
depends_on = None

ASSIGNMENT_PREFIX = re.compile(r"^(assignee_id|brigade_id)=([1-9][0-9]*)(?:;|$)")
ASSIGNABLE = {"issued", "accepted", "queued", "rejected", "rework"}


def utc(value):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value.astimezone(timezone.utc)


def upgrade():
    connection = op.get_bind()
    orders = sa.table("orders", sa.column("id", sa.Integer()), sa.column("assignee_id", sa.Integer()),
        sa.column("brigade_id", sa.Integer()), sa.column("created_at", sa.DateTime(timezone=True)),
        sa.column("assigned_at", sa.DateTime(timezone=True)))
    events = sa.table("order_events", sa.column("id", sa.Integer()), sa.column("order_id", sa.Integer()),
        sa.column("action", sa.String()), sa.column("from_status", sa.String()), sa.column("to_status", sa.String()),
        sa.column("comment", sa.Text()), sa.column("created_at", sa.DateTime(timezone=True)))
    current_orders = list(connection.execute(sa.select(orders.c.id, orders.c.assignee_id, orders.c.brigade_id, orders.c.created_at)).mappings())
    latest = {}
    for event in connection.execute(sa.select(events).where(events.c.action == "edit", events.c.to_status == "issued")).mappings():
        match = ASSIGNMENT_PREFIX.match(event["comment"] or "")
        if match is None or event["from_status"] not in ASSIGNABLE:
            continue
        # Assignment fields precede arbitrary comment text in the old audit.
        # Never interpret a user comment containing '; assignee_id=...' as one.
        candidate = (utc(event["created_at"]), event["id"], match.group(1), int(match.group(2)))
        previous = latest.get(event["order_id"])
        if previous is None or candidate[:2] > previous[:2]:
            latest[event["order_id"]] = candidate
    backfill = []
    for order in current_orders:
        created = utc(order["created_at"])
        candidate = latest.get(order["id"])
        assigned = created
        if candidate and candidate[0] >= created and order[candidate[2]] == candidate[3]:
            assigned = candidate[0]
        backfill.append({"order_id": order["id"], "assignment_time": assigned})
    op.add_column("orders", sa.Column("assigned_at", sa.DateTime(timezone=True), nullable=True))
    if backfill:
        connection.execute(orders.update().where(orders.c.id == sa.bindparam("order_id")).values(assigned_at=sa.bindparam("assignment_time")), backfill)
    with op.batch_alter_table("orders") as batch:
        batch.alter_column("assigned_at", existing_type=sa.DateTime(timezone=True), nullable=False)


def downgrade():
    with op.batch_alter_table("orders") as batch:
        batch.drop_column("assigned_at")
