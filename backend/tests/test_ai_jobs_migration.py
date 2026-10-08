"""Job migration appends one table and never queues historical submissions."""
from datetime import datetime, timedelta, timezone

import pytest
import sqlalchemy as sa
from alembic import command

from app.db import make_engine
from app.migrations import alembic_config, expected_schema, upgrade_database
from test_migrations import fill_legacy, revision
from test_order_history_migration import dump


def fill_previous_revision(engine):
    revision(engine, "0002_client_commands")
    fill_legacy(engine, True)
    revision(engine, "0004_order_history")
    schema = expected_schema("0004_order_history")
    now = datetime.now(timezone.utc)
    with engine.begin() as connection:
        assignment_id = connection.scalar(sa.select(schema.tables["order_assignments"].c.id).where(schema.tables["order_assignments"].c.order_id == 1))
        result = connection.execute(schema.tables["submission_attempts"].insert(), {
            "order_id": 1, "sequence": 2, "assignment_id": assignment_id, "submitted_at": now,
            "author_id": 6, "payload": {"work_done": "Keep live report", "materials": [{"material_id": 1, "quantity": 2}]},
            "ai_review": {"score": 4, "is_stub": True, "master_score": None}, "assessment_id": 81, "source": "live"})
        attempt_id = result.inserted_primary_key[0]
        connection.execute(schema.tables["submission_photos"].insert(), {"attempt_id": attempt_id, "photo_id": 31})
        connection.execute(schema.tables["submission_writeoffs"].insert(), {"attempt_id": attempt_id, "writeoff_id": 41})
        connection.execute(schema.tables["submission_decisions"].insert(), {"attempt_id": attempt_id, "actor_id": 1,
            "action": "rework", "score": None, "comment": "Preserve prior decision", "created_at": now + timedelta(minutes=1)})


def check_job_migration(engine):
    fill_previous_revision(engine)
    before = dump(engine)
    assert {row["source"] for row in before["submission_attempts"]} == {"live", "legacy_snapshot"}
    upgrade_database(engine)
    after = dump(engine)
    assert {name: rows for name, rows in after.items() if name != "ai_review_jobs"} == before
    assert after["ai_review_jobs"] == []
    with engine.connect() as connection:
        assert connection.scalar(sa.text("SELECT version_num FROM alembic_version")) == "0005_ai_review_jobs"
    upgrade_database(engine)
    assert dump(engine) == after
    with engine.connect() as connection:
        command.downgrade(alembic_config(connection), "0004_order_history")
    assert dump(engine) == before
    upgrade_database(engine)
    assert dump(engine) == after


def test_sqlite_jobs_migration_preserves_live_and_legacy_reports(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'jobs-upgrade.sqlite'}")
    try:
        check_job_migration(engine)
    finally:
        engine.dispose()


def test_postgresql_jobs_migration_preserves_live_and_legacy_reports(pg_database):
    check_job_migration(pg_database.engine)


def test_jobs_unique_attempt_and_valid_retry_state(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'jobs-constraints.sqlite'}")
    try:
        fill_previous_revision(engine)
        upgrade_database(engine)
        jobs = expected_schema("0005_ai_review_jobs").tables["ai_review_jobs"]
        now = datetime.now(timezone.utc)
        body = {"attempt_id": 1, "status": "pending", "provider": "stub", "attempts": 0,
            "max_attempts": 3, "next_attempt_at": now, "created_at": now, "lease_token": None,
            "lease_expires_at": None, "last_error_code": None, "finished_at": None}
        with engine.begin() as connection:
            connection.execute(jobs.insert(), body)
        for overrides in [{}, {"attempt_id": 2, "status": "unknown"}, {"attempt_id": 2, "attempts": -1}, {"attempt_id": 2, "max_attempts": 0}]:
            with pytest.raises(sa.exc.IntegrityError):
                with engine.begin() as connection:
                    connection.execute(jobs.insert(), {**body, **overrides})
        with engine.connect() as connection:
            assert connection.scalar(sa.select(sa.func.count()).select_from(jobs)) == 1
    finally:
        engine.dispose()
