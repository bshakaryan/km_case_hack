"""Remove review modules while retaining their existing records in the archive.

All schema operations use frozen Core definitions. Application models are never
imported by this historical migration.
"""
from datetime import datetime, timezone

import sqlalchemy as sa
from alembic import op
from alembic.operations.ops import CreateIndexOp, CreateTableOp

revision = "0009_remove_ai_modules"
down_revision = "0008_ai_attempt_input"
branch_labels = None
depends_on = None

ARCHIVE_ADAPTER = "module_archive"
ARCHIVE_OPERATION = "0009"


def schema(metadata):
    orders = metadata.tables["orders"]
    attempts = metadata.tables["submission_attempts"]
    for constraint in list(orders.constraints):
        if isinstance(constraint, sa.CheckConstraint) and constraint.name == "ck_order_status":
            orders.constraints.remove(constraint)
    orders._columns.remove(orders.c.ai_review)
    orders.append_constraint(sa.CheckConstraint(
        "status IN ('issued','accepted','queued','rejected','in_progress','paused','completed','rework','closed','cancelled')",
        name="ck_order_status"))
    assessment_column = attempts.c.assessment_id
    for foreign_key in list(assessment_column.foreign_keys):
        assessment_column.foreign_keys.remove(foreign_key)
    for constraint in list(attempts.constraints):
        if isinstance(constraint, sa.ForeignKeyConstraint) and any(
                element.parent.name == "assessment_id" for element in constraint.elements):
            attempts.constraints.remove(constraint)
            for element in constraint.elements:
                attempts.foreign_keys.discard(element)
    for column in ("ai_input", "ai_review", "assessment_id"):
        attempts._columns.remove(attempts.c[column])
    metadata.remove(metadata.tables["ai_review_jobs"])
    metadata.remove(metadata.tables["ai_assessments"])
    return metadata


def _json_value(value):
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, dict):
        return {key: _json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_json_value(item) for item in value]
    return value


def _archive(connection, table_name, predicate=None, fields=None):
    table = sa.Table(table_name, sa.MetaData(), autoload_with=connection)
    statement = sa.select(table)
    if predicate is not None:
        statement = statement.where(predicate(table))
    log = sa.Table("integration_logs", sa.MetaData(), autoload_with=connection)
    for row in connection.execute(statement).mappings():
        values = dict(row)
        if fields is not None:
            values = {key: values[key] for key in fields}
        if table_name == "orders" and values.get("status") != "ai_review" and values.get("ai_review") is None:
            continue
        if table_name == "submission_attempts" and not any(
                values.get(key) is not None for key in ("ai_input", "ai_review", "assessment_id")):
            continue
        connection.execute(log.insert(), {
            "adapter": ARCHIVE_ADAPTER,
            "operation": ARCHIVE_OPERATION,
            "payload": {"source_table": table_name, "row": _json_value(values)},
            "created_at": next((values[name] for name in ("created_at", "submitted_at", "completed_at")
                if isinstance(values.get(name), datetime)), datetime.now(timezone.utc)),
        })


def _strip_retired_receipt_fields(value):
    if isinstance(value, dict):
        result = {}
        for key, item in value.items():
            if key in {"ai_review", "ai_review_job", "ai_job", "assessment_id"}:
                continue
            if key in {"status", "from_status", "to_status"} and item == "ai_review":
                item = "completed"
            elif key == "action" and item == "ai_review":
                item = "awaiting_acceptance"
            elif key == "action" and item == "ai_review_retry":
                item = "manual_acceptance"
            result[key] = _strip_retired_receipt_fields(item)
        return result
    if isinstance(value, list):
        return [_strip_retired_receipt_fields(item) for item in value]
    return value


def _archive_legacy_receipts(connection):
    commands = sa.Table("client_commands", sa.MetaData(), autoload_with=connection)
    logs = sa.Table("integration_logs", sa.MetaData(), autoload_with=connection)
    for row in connection.execute(sa.select(commands).where(commands.c.response_body.is_not(None))).mappings():
        sanitized = _strip_retired_receipt_fields(row["response_body"])
        if sanitized == row["response_body"]:
            continue
        values = {key: _json_value(value) for key, value in dict(row).items()}
        connection.execute(logs.insert(), {
            "adapter": ARCHIVE_ADAPTER,
            "operation": ARCHIVE_OPERATION,
            "payload": {"source_table": "client_commands", "row": values},
            "created_at": row["created_at"],
        })
        connection.execute(commands.update().where(commands.c.id == row["id"]).values(response_body=sanitized))


def upgrade():
    connection = op.get_bind()
    _archive(connection, "orders", lambda table: sa.or_(
        table.c.ai_review.is_not(None), table.c.status == "ai_review"), ("id", "status", "ai_review", "created_at"))
    _archive(connection, "submission_attempts", lambda table: sa.or_(
        table.c.ai_input.is_not(None), table.c.ai_review.is_not(None),
        table.c.assessment_id.is_not(None)), ("id", "ai_input", "ai_review", "assessment_id", "submitted_at"))
    _archive(connection, "ai_assessments")
    _archive(connection, "ai_review_jobs")
    _archive(connection, "order_events", lambda table: sa.or_(
        table.c.action.in_(("ai_review", "ai_review_retry")),
        table.c.from_status == "ai_review", table.c.to_status == "ai_review"))
    _archive_legacy_receipts(connection)

    connection.execute(sa.text("UPDATE orders SET status='completed' WHERE status='ai_review'"))
    connection.execute(sa.text("""
        UPDATE order_events
        SET action = CASE action
                WHEN 'ai_review' THEN 'awaiting_acceptance'
                WHEN 'ai_review_retry' THEN 'manual_acceptance'
                ELSE action END,
            from_status = CASE WHEN from_status='ai_review' THEN 'completed' ELSE from_status END,
            to_status = CASE WHEN to_status='ai_review' THEN 'completed' ELSE to_status END
        WHERE action IN ('ai_review', 'ai_review_retry')
           OR from_status='ai_review' OR to_status='ai_review'
    """))
    with op.batch_alter_table("orders", recreate="always") as batch:
        batch.drop_column("ai_review")
        batch.drop_constraint("ck_order_status", type_="check")
        batch.create_check_constraint("ck_order_status",
            "status IN ('issued','accepted','queued','rejected','in_progress','paused','completed','rework','closed','cancelled')")
    with op.batch_alter_table("submission_attempts", recreate="always") as batch:
        batch.drop_column("ai_input")
        batch.drop_column("ai_review")
        batch.drop_column("assessment_id")
    op.drop_table("ai_review_jobs")
    op.drop_table("ai_assessments")


def _restore_datetime_values(table, row):
    restored = dict(row)
    for column in table.columns:
        value = restored.get(column.name)
        if value is not None and isinstance(column.type, sa.DateTime) and isinstance(value, str):
            restored[column.name] = datetime.fromisoformat(value)
    return restored


def downgrade():
    connection = op.get_bind()
    assessment = op.create_table(
        "ai_assessments",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("order_id", sa.Integer(), sa.ForeignKey("orders.id"), nullable=False),
        sa.Column("verdict", sa.String(40), nullable=False),
        sa.Column("score", sa.Float(), nullable=True),
        sa.Column("explanation", sa.Text(), nullable=False),
        sa.Column("is_stub", sa.Boolean(), nullable=False),
        sa.Column("master_score", sa.Float(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_ai_assessments_order_id", "ai_assessments", ["order_id"])
    with op.batch_alter_table("orders", recreate="always") as batch:
        batch.add_column(sa.Column("ai_review", sa.JSON(), nullable=True))
        batch.drop_constraint("ck_order_status", type_="check")
        batch.create_check_constraint("ck_order_status",
            "status IN ('issued','accepted','queued','rejected','in_progress','paused','completed','ai_review','rework','closed','cancelled')")
    with op.batch_alter_table("submission_attempts", recreate="always") as batch:
        batch.add_column(sa.Column("ai_input", sa.JSON(none_as_null=True), nullable=True))
        batch.add_column(sa.Column("ai_review", sa.JSON(), nullable=True))
        batch.add_column(sa.Column("assessment_id", sa.Integer(), nullable=True))
        batch.create_foreign_key("fk_submission_attempts_assessment", "ai_assessments", ["assessment_id"], ["id"])

    metadata = sa.MetaData()
    sa.Table("submission_attempts", metadata, sa.Column("id", sa.Integer(), primary_key=True))
    jobs = sa.Table("ai_review_jobs", metadata,
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("attempt_id", sa.Integer(), sa.ForeignKey("submission_attempts.id"), nullable=False),
        sa.Column("status", sa.String(20), nullable=False),
        sa.Column("provider", sa.String(40), nullable=False),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("max_attempts", sa.Integer(), nullable=False),
        sa.Column("next_attempt_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("lease_token", sa.String(64)),
        sa.Column("lease_expires_at", sa.DateTime(timezone=True)),
        sa.Column("last_error_code", sa.String(80)),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("finished_at", sa.DateTime(timezone=True)),
        sa.UniqueConstraint("attempt_id", name="uq_ai_review_job_attempt"),
        sa.CheckConstraint("status IN ('pending','running','succeeded','failed','superseded')", name="ck_ai_review_job_status"),
        sa.CheckConstraint("attempts >= 0", name="ck_ai_review_job_attempts"),
        sa.CheckConstraint("max_attempts > 0", name="ck_ai_review_job_max_attempts"),
        sa.Index("ix_ai_review_jobs_status_next", "status", "next_attempt_at"),
        sa.Index("ix_ai_review_jobs_status_lease", "status", "lease_expires_at"))
    op.invoke(CreateTableOp.from_table(jobs))
    for index in sorted(jobs.indexes, key=lambda item: item.name):
        op.invoke(CreateIndexOp.from_index(index))

    logs = sa.Table("integration_logs", sa.MetaData(), autoload_with=connection)
    attempts = sa.Table("submission_attempts", sa.MetaData(), autoload_with=connection)
    orders = sa.Table("orders", sa.MetaData(), autoload_with=connection)
    events = sa.Table("order_events", sa.MetaData(), autoload_with=connection)
    commands = sa.Table("client_commands", sa.MetaData(), autoload_with=connection)
    for log_row in connection.execute(sa.select(logs).where(
            logs.c.adapter == ARCHIVE_ADAPTER, logs.c.operation == ARCHIVE_OPERATION)).mappings():
        payload = log_row["payload"]
        table_name, row = payload["source_table"], payload["row"]
        if table_name == "orders":
            connection.execute(orders.update().where(orders.c.id == row["id"]).values(ai_review=row["ai_review"]))
            if row["status"] == "ai_review":
                connection.execute(orders.update().where(orders.c.id == row["id"], orders.c.status == "completed").values(status="ai_review"))
        elif table_name == "submission_attempts":
            connection.execute(attempts.update().where(attempts.c.id == row["id"]).values(
                ai_input=sa.null() if row["ai_input"] is None else row["ai_input"],
                ai_review=sa.null() if row["ai_review"] is None else row["ai_review"],
                assessment_id=row["assessment_id"]))
        elif table_name in {"ai_assessments", "ai_review_jobs"}:
            table = sa.Table(table_name, sa.MetaData(), autoload_with=connection)
            connection.execute(table.insert().values(**_restore_datetime_values(table, row)))
        elif table_name == "order_events":
            connection.execute(events.update().where(events.c.id == row["id"]).values(
                action=row["action"], from_status=row["from_status"], to_status=row["to_status"]))
        elif table_name == "client_commands":
            connection.execute(commands.update().where(commands.c.id == row["id"]).values(
                response_body=_restore_datetime_values(commands, row).get("response_body")))
    connection.execute(logs.delete().where(
        logs.c.adapter == ARCHIVE_ADAPTER, logs.c.operation == ARCHIVE_OPERATION))
