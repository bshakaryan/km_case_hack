"""Order versions and retired data remain safe across filled upgrades."""
import pytest
import sqlalchemy as sa
from alembic import command

from app.db import make_engine
from app.migrations import alembic_config, expected_schema, upgrade_database, validate_schema
from test_migrations import fill_legacy, revision, snapshot


def filled_previous(engine):
    revision(engine, "0002_client_commands")
    fill_legacy(engine, True)
    revision(engine, "0005_ai_review_jobs")


def comparable(state):
    result = {name: [dict(row) for row in rows] for name, rows in state.items()}
    result["integration_logs"] = [
        {key: value for key, value in row.items()
            if not (row["adapter"] == "module_archive" and key == "id")}
        for row in result["integration_logs"]
    ]
    return result


def check_upgrade(engine):
    filled_previous(engine)
    before = snapshot(engine)
    upgrade_database(engine)
    after = snapshot(engine)
    with engine.connect() as connection:
        assert connection.scalar(sa.text("SELECT version FROM orders WHERE id=1")) == 1
    with engine.connect() as connection:
        assert connection.scalar(sa.text(
            "SELECT COUNT(*) FROM client_commands WHERE order_id IS NOT NULL OR order_version IS NOT NULL"
        )) == 0
    assert after["orders"][0]["status"] == "completed"
    assert "ai_review" not in after["orders"][0]
    assert {"ai_assessments", "ai_review_jobs"}.isdisjoint(after)
    assert {"orders", "submission_attempts", "ai_assessments", "client_commands"} <= {
        row["payload"]["source_table"] for row in after["integration_logs"]
        if row["adapter"] == "module_archive"
    }
    assert after["orders"][0]["completion"] == before["orders"][0]["completion"]
    with engine.connect() as connection:
        validate_schema(connection)
        assert connection.scalar(sa.text("SELECT version_num FROM alembic_version")) == "0009_remove_ai_modules"
    upgrade_database(engine)
    assert snapshot(engine) == after
    with engine.connect() as connection:
        command.downgrade(alembic_config(connection), "0005_ai_review_jobs")
    restored = snapshot(engine)
    assert restored == before
    assert restored["orders"][0]["status"] == "ai_review"
    upgrade_database(engine)
    assert comparable(snapshot(engine)) == comparable(after)


def test_sqlite_versions_upgrade_archives_retired_records_and_preserves_receipts(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'versions-upgrade.sqlite'}")
    try:
        check_upgrade(engine)
    finally:
        engine.dispose()


def test_postgresql_versions_upgrade_archives_retired_records_and_preserves_receipts(pg_database):
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
