"""History migration preserves old records; provenance is never invented."""
from datetime import datetime, timezone

import pytest
import sqlalchemy as sa
from alembic import command

from app.db import make_engine
from app.migrations import alembic_config, expected_schema, seed_legacy_history, upgrade_database
from app.seed import seed_database
from app.db import session_factory
from test_migrations import fill_legacy, revision

HISTORY = {"order_assignments", "submission_attempts", "submission_photos", "submission_writeoffs", "submission_decisions"}


def dump(engine):
    metadata = sa.MetaData()
    metadata.reflect(engine)
    with engine.connect() as connection:
        return {name: [dict(row) for row in connection.execute(sa.select(table).order_by(table.c.id)).mappings()]
                for name, table in metadata.tables.items() if name != "alembic_version"}


def check_preservation(engine):
    revision(engine, "0002_client_commands")
    fill_legacy(engine, True)
    revision(engine, "0003_push")
    schema = expected_schema("0003_push")
    orders = schema.tables["orders"]
    with engine.begin() as connection:
        connection.execute(orders.update().where(orders.c.id == 1).values(status="ai_review", completed_at=datetime(2026, 10, 7, 12, tzinfo=timezone.utc),
            completion={"work_done": "Original final text", "materials": [{"material_id": 1, "quantity": 9}], "unknown_nested": {"keep": [1, 2]}},
            ai_review={"score": 4.5, "explanation": "Preserved verdict"}))
        connection.execute(orders.update().where(orders.c.id == 2).values(status="rework", completed_at=None))
        connection.execute(orders.update().where(orders.c.id == 3).values(completion={}))
        connection.execute(orders.update().where(orders.c.id == 4).values(completion=None))
        connection.execute(orders.update().where(orders.c.id == 5).values(status="closed"))
    before = dump(engine)
    upgrade_database(engine)
    after = dump(engine)
    assert {name: rows for name, rows in after.items() if name not in HISTORY | {"ai_review_jobs"}} == before
    assert not after["ai_review_jobs"]
    assignments = after["order_assignments"]
    assert len(assignments) == 5
    previous_orders = {row["id"]: row for row in before["orders"]}
    for assignment in assignments:
        previous = previous_orders[assignment["order_id"]]
        assert assignment["sequence"] == 1 and assignment["source"] == "legacy_snapshot"
        assert assignment["assignee_id"] == previous["assignee_id"]
        assert assignment["brigade_id"] == previous["brigade_id"]
        assert assignment["assigned_at"] == previous["assigned_at"]
        assert assignment["assigned_by_id"] is None and assignment["ended_at"] is None
    attempts = {row["order_id"]: row for row in after["submission_attempts"]}
    assert set(attempts) == {1, 2, 3, 5}
    for order_id, attempt in attempts.items():
        previous = previous_orders[order_id]
        assert attempt["source"] == "legacy_snapshot" and attempt["sequence"] == 1
        assert attempt["payload"] == previous["completion"]
        assert attempt["ai_review"] == previous["ai_review"]
        assert attempt["submitted_at"] == previous["completed_at"]
        assert attempt["author_id"] is None and attempt["assignment_id"] is None and attempt["assessment_id"] is None
    assert attempts[2]["submitted_at"] is None
    assert not after["submission_photos"] and not after["submission_writeoffs"] and not after["submission_decisions"]
    upgrade_database(engine)
    with engine.begin() as connection:
        seed_legacy_history(connection)
    assert dump(engine) == after
    with engine.connect() as connection:
        command.downgrade(alembic_config(connection), "0003_push")
    assert dump(engine) == before
    upgrade_database(engine)
    assert dump(engine) == after


def test_sqlite_history_upgrade_retains_filled_database(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'history.sqlite'}")
    try:
        check_preservation(engine)
    finally:
        engine.dispose()


def test_postgresql_history_upgrade_retains_filled_database(pg_database):
    check_preservation(pg_database.engine)


def test_seed_adds_conservative_snapshots_once(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'seed-history.sqlite'}")
    try:
        upgrade_database(engine)
        with session_factory(engine)() as db:
            seed_database(db)
        state = dump(engine)
        assert len(state["order_assignments"]) == len(state["orders"]) == 556
        assert len(state["submission_attempts"]) == sum(order["completion"] is not None for order in state["orders"])
        assert all(row["source"] == "legacy_snapshot" for row in state["order_assignments"] + state["submission_attempts"])
        assert not state["submission_photos"] and not state["submission_writeoffs"]
        assert not state["ai_review_jobs"]
        with session_factory(engine)() as db:
            seed_database(db)
        assert dump(engine) == state
    finally:
        engine.dispose()


def test_live_attempt_requires_known_assignment_author_and_timestamp(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'live-check.sqlite'}")
    try:
        revision(engine, "0002_client_commands")
        fill_legacy(engine, True)
        upgrade_database(engine)
        attempts = expected_schema("0004_order_history").tables["submission_attempts"]
        with pytest.raises(sa.exc.IntegrityError):
            with engine.begin() as connection:
                connection.execute(attempts.insert(), {"order_id": 1, "sequence": 2, "source": "live", "payload": {},
                    "assignment_id": None, "submitted_at": None, "author_id": None, "ai_review": None, "assessment_id": None})
        with engine.connect() as connection:
            assert connection.scalar(sa.select(sa.func.count()).select_from(attempts)) == 5
    finally:
        engine.dispose()
