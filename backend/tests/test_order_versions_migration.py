"""Filled upgrades retain all prior data and do not invent old receipts."""
from datetime import datetime, timezone

import pytest
import sqlalchemy as sa
from alembic import command

from app.db import make_engine
from app.migrations import alembic_config, expected_schema, upgrade_database, validate_schema
from test_ai_jobs_migration import fill_previous_revision
from test_migrations import revision
from test_order_history_migration import dump, without_versions


def filled_previous(engine):
    fill_previous_revision(engine)
    revision(engine, "0005_ai_review_jobs")
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        connection.execute(expected_schema("0005_ai_review_jobs").tables["ai_review_jobs"].insert(), {
            "attempt_id": 1, "status": "failed", "provider": "stub", "attempts": 3, "max_attempts": 3,
            "next_attempt_at": now, "created_at": now, "finished_at": now, "last_error_code": "provider_error"})


def check_upgrade(engine):
    filled_previous(engine)
    before = dump(engine)
    upgrade_database(engine)
    after = dump(engine)
    assert without_versions(after) == before
    assert all(row["version"] == 1 for row in after["orders"])
    assert all(row["order_id"] is None and row["order_version"] is None for row in after["client_commands"])
    with engine.connect() as connection:
        validate_schema(connection)
        assert connection.scalar(sa.text("SELECT version_num FROM alembic_version")) == "0006_order_versions"
    upgrade_database(engine)
    assert dump(engine) == after
    with engine.connect() as connection:
        command.downgrade(alembic_config(connection), "0005_ai_review_jobs")
    assert dump(engine) == before
    upgrade_database(engine)
    assert dump(engine) == after


def test_sqlite_versions_upgrade_preserves_reports_jobs_and_unknown_receipts(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'versions-upgrade.sqlite'}")
    try:
        check_upgrade(engine)
    finally:
        engine.dispose()


def test_postgresql_versions_upgrade_preserves_reports_jobs_and_unknown_receipts(pg_database):
    check_upgrade(pg_database.engine)


def test_positive_versions_and_paired_receipt_constraints(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'versions-constraints.sqlite'}")
    try:
        filled_previous(engine)
        upgrade_database(engine)
        schema = expected_schema("0006_order_versions")
        orders, commands = schema.tables["orders"], schema.tables["client_commands"]
        for value in [0, -1, None]:
            with pytest.raises(sa.exc.IntegrityError):
                with engine.begin() as connection:
                    connection.execute(orders.update().where(orders.c.id == 1).values(version=value))
        for values in [{"order_id": 1, "order_version": None}, {"order_id": None, "order_version": 1}, {"order_id": 1, "order_version": 0}]:
            with pytest.raises(sa.exc.IntegrityError):
                with engine.begin() as connection:
                    connection.execute(commands.update().values(**values))
        with engine.connect() as connection:
            assert connection.scalar(sa.select(orders.c.version).where(orders.c.id == 1)) == 1
            assert connection.scalar(sa.select(commands.c.order_version)) is None
    finally:
        engine.dispose()
