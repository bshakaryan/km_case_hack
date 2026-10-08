"""0007 preserves filled databases and never reconstructs historical crews."""
from datetime import datetime, timedelta, timezone

import pytest
import sqlalchemy as sa
from alembic import command

from app.db import make_engine, session_factory
from app.migrations import alembic_config, expected_schema, seed_legacy_history, upgrade_database, validate_schema
from app.seed import seed_database
from test_migrations import revision
from test_order_history_migration import dump
from test_order_versions_migration import filled_previous

TABLE = "order_assignment_participants"


def check_upgrade(engine):
    filled_previous(engine)
    revision(engine, "0006_order_versions")
    schema = expected_schema("0006_order_versions")
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        assignments = schema.tables["order_assignments"]
        old_id = connection.scalar(sa.select(assignments.c.id).where(assignments.c.order_id == 1))
        connection.execute(assignments.update().where(assignments.c.id == old_id).values(ended_at=now))
        connection.execute(assignments.insert(), {"order_id": 1, "sequence": 2, "assignee_id": 5,
            "brigade_id": 1, "assigned_at": now, "ended_at": now + timedelta(hours=1),
            "assigned_by_id": 1, "source": "live"})
        connection.execute(schema.tables["orders"].update().where(schema.tables["orders"].c.id == 1)
            .values(assignee_id=5, assigned_at=now, status="closed", closed_at=now + timedelta(hours=1)))
    before = dump(engine)
    upgrade_database(engine)
    after = dump(engine)
    assert {name: rows for name, rows in after.items() if name != TABLE} == before
    assignments = {row["id"]: row for row in before["order_assignments"]}
    names = {row["id"]: row["name"] for row in before["employees"]}
    assert len(after[TABLE]) == len(assignments) == 6
    for participant in after[TABLE]:
        assignment = assignments[participant["assignment_id"]]
        assert participant["employee_id"] == assignment["assignee_id"]
        assert participant["name"] == names[assignment["assignee_id"]]
        assert participant["source"] == "legacy_snapshot"
    with engine.connect() as connection:
        validate_schema(connection)
        assert connection.scalar(sa.text("SELECT version_num FROM alembic_version")) == "0007_assignment_participants"
    upgrade_database(engine)
    with engine.begin() as connection:
        seed_legacy_history(connection)
    assert dump(engine) == after
    with engine.connect() as connection:
        command.downgrade(alembic_config(connection), "0006_order_versions")
    assert dump(engine) == before
    upgrade_database(engine)
    assert dump(engine) == after


def test_sqlite_participants_upgrade_preserves_all_history_and_closed_rosters(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'crew-upgrade.sqlite'}")
    try:
        check_upgrade(engine)
    finally:
        engine.dispose()


def test_postgresql_participants_upgrade_preserves_all_history_and_closed_rosters(pg_database):
    check_upgrade(pg_database.engine)


def test_demonstration_seed_is_conservative_and_idempotent(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'crew-seed.sqlite'}")
    try:
        upgrade_database(engine)
        with session_factory(engine)() as db:
            seed_database(db)
        state = dump(engine)
        assert len(state[TABLE]) == len(state["order_assignments"]) == len(state["orders"]) == 556
        assert all(row["source"] == "legacy_snapshot" for row in state[TABLE])
        assignments = {row["id"]: row for row in state["order_assignments"]}
        assert all(row["employee_id"] == assignments[row["assignment_id"]]["assignee_id"] for row in state[TABLE])
        with session_factory(engine)() as db:
            seed_database(db)
        assert dump(engine) == state
    finally:
        engine.dispose()


def test_participants_have_unique_identity_foreign_keys_and_known_provenance(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'crew-constraints.sqlite'}")
    try:
        filled_previous(engine)
        upgrade_database(engine)
        table = expected_schema("0007_assignment_participants").tables[TABLE]
        with engine.connect() as connection:
            previous = dict(connection.execute(sa.select(table).limit(1)).mappings().one())
        previous.pop("id")
        for overrides in [{}, {"employee_id": 5, "source": "invented"},
            {"employee_id": 999}, {"assignment_id": 999}]:
            with pytest.raises(sa.exc.IntegrityError):
                with engine.begin() as connection:
                    connection.execute(table.insert(), {**previous, **overrides})
        with engine.connect() as connection:
            assert connection.scalar(sa.select(sa.func.count()).select_from(table)) == 5
    finally:
        engine.dispose()
