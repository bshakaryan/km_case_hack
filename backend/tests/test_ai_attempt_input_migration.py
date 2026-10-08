"""0008 preserves filled history and does not invent old submission context."""
from datetime import datetime, timezone

import pytest
import sqlalchemy as sa
from alembic import command
from alembic.operations import Operations

from app.db import make_engine, session_factory
from app.migrations import alembic_config, expected_schema, upgrade_database, validate_schema
from app.models import AIAssessment, SubmissionAttempt
from test_migrations import revision
from test_order_history_migration import dump
from test_order_versions_migration import filled_previous

HEAD = "0008_ai_attempt_input"
PREVIOUS = "0007_assignment_participants"


def filled_previous_head(engine):
    filled_previous(engine)
    revision(engine, PREVIOUS)


def assert_sqlite_integrity(connection):
    if connection.dialect.name == "sqlite":
        assert connection.exec_driver_sql("PRAGMA foreign_keys").scalar_one() == 1
        assert not connection.exec_driver_sql("PRAGMA foreign_key_check").all()


def check_preserved_upgrade(engine):
    filled_previous_head(engine)
    before = dump(engine)
    # The assessment being recreated is referenced by a live attempt, while a
    # separate durable job and linked media/writeoff also already exist.
    assert before["ai_assessments"][0]["id"] == 81
    assert any(row["assessment_id"] == 81 for row in before["submission_attempts"])
    assert before["ai_review_jobs"] and before["submission_photos"] and before["submission_writeoffs"]
    assert {row["source"] for row in before["submission_attempts"]} == {"live", "legacy_snapshot"}
    with engine.connect() as connection:
        assert_sqlite_integrity(connection)
        assert not next(column for column in sa.inspect(connection).get_columns("ai_assessments")
            if column["name"] == "score")["nullable"]
    upgrade_database(engine)
    after = dump(engine)
    assert all(row["ai_input"] is None for row in after["submission_attempts"])
    projected = {name: [{key: value for key, value in row.items()
        if not (name == "submission_attempts" and key == "ai_input")} for row in rows]
        for name, rows in after.items()}
    assert projected == before
    with engine.connect() as connection:
        validate_schema(connection)
        assert connection.scalar(sa.text("SELECT version_num FROM alembic_version")) == HEAD
        assert_sqlite_integrity(connection)
        assert next(column for column in sa.inspect(connection).get_columns("ai_assessments")
            if column["name"] == "score")["nullable"]
        assert next(column for column in sa.inspect(connection).get_columns("submission_attempts")
            if column["name"] == "ai_input")["nullable"]
    upgrade_database(engine)
    assert dump(engine) == after
    # No newly frozen context or unknown score is discarded in this roundtrip.
    with engine.connect() as connection:
        command.downgrade(alembic_config(connection), PREVIOUS)
    assert dump(engine) == before
    upgrade_database(engine)
    assert dump(engine) == after


def test_sqlite_filled_upgrade_keeps_ids_scores_jobs_media_and_null_old_context(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'attempt-input-upgrade.sqlite'}")
    try:
        check_preserved_upgrade(engine)
    finally:
        engine.dispose()


def test_postgresql_filled_upgrade_keeps_ids_scores_jobs_media_and_null_old_context(pg_database):
    check_preserved_upgrade(pg_database.engine)


def check_unknown_score_and_native_context(engine):
    filled_previous_head(engine)
    upgrade_database(engine)
    before = dump(engine)
    source_attempt = next(row for row in before["submission_attempts"] if row["source"] == "live")
    context = {"schema_version": 1, "task": {"description": "Synthetic frozen task"},
        "equipment": {"id": 3, "name": "Synthetic equipment"}, "submitted_version": 4}
    sessions = session_factory(engine)
    with sessions() as db:
        assessment = AIAssessment(order_id=1, verdict="needs_attention", score=None,
            explanation="Synthetic unknown result", is_stub=False, master_score=None)
        db.add(assessment)
        db.flush()
        attempt = SubmissionAttempt(order_id=1, sequence=3,
            assignment_id=source_attempt["assignment_id"], submitted_at=datetime.now(timezone.utc),
            author_id=source_attempt["author_id"], payload={"work_done": "Synthetic report"},
            ai_input=context, ai_review=None, assessment_id=assessment.id, source="live")
        db.add(attempt)
        db.commit()
        assessment_id, attempt_id = assessment.id, attempt.id
    with sessions() as db:
        assert db.get(AIAssessment, assessment_id).score is None
        assert db.get(SubmissionAttempt, attempt_id).ai_input == context
        assert db.get(SubmissionAttempt, source_attempt["id"]).ai_input is None
    with engine.connect() as connection:
        assert connection.scalar(sa.text("SELECT score IS NULL FROM ai_assessments WHERE id=:id"),
            {"id": assessment_id})
        validate_schema(connection)
        assert_sqlite_integrity(connection)
    after = dump(engine)
    assert [row for row in after["ai_assessments"] if row["id"] != assessment_id] == before["ai_assessments"]
    assert [row for row in after["submission_attempts"] if row["id"] != attempt_id] == before["submission_attempts"]
    assert after["ai_review_jobs"] == before["ai_review_jobs"]
    # Returning to a required score must refuse instead of inventing a grade.
    with pytest.raises(RuntimeError, match="unknown AI scores"):
        with engine.connect() as connection:
            command.downgrade(alembic_config(connection), PREVIOUS)
    assert dump(engine) == after
    with engine.connect() as connection:
        assert connection.scalar(sa.text("SELECT version_num FROM alembic_version")) == HEAD
        assert_sqlite_integrity(connection)
    upgrade_database(engine)
    assert dump(engine) == after
    # A known score still cannot justify deleting captured immutable context.
    with sessions() as db:
        db.get(AIAssessment, assessment_id).score = 4
        db.commit()
    known_score_state = dump(engine)
    with pytest.raises(RuntimeError, match="frozen AI context"):
        with engine.connect() as connection:
            command.downgrade(alembic_config(connection), PREVIOUS)
    assert dump(engine) == known_score_state
    with engine.connect() as connection:
        validate_schema(connection)
        assert connection.scalar(sa.text("SELECT version_num FROM alembic_version")) == HEAD
        assert_sqlite_integrity(connection)


def test_sqlite_unknown_score_and_frozen_native_context_roundtrip(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'attempt-input-null.sqlite'}")
    try:
        check_unknown_score_and_native_context(engine)
    finally:
        engine.dispose()


def test_postgresql_unknown_score_and_frozen_native_context_roundtrip(pg_database):
    check_unknown_score_and_native_context(pg_database.engine)


def test_sqlite_failure_after_assessment_rebuild_rolls_back_schema_data_and_fk(tmp_path, monkeypatch):
    engine = make_engine(f"sqlite:///{tmp_path / 'attempt-input-rollback.sqlite'}")
    try:
        filled_previous_head(engine)
        before = dump(engine)
        tables = sa.inspect(engine).get_table_names()
        original = Operations.add_column
        def fail_context(self, table_name, column, **kwargs):
            if table_name == "submission_attempts" and column.name == "ai_input":
                raise RuntimeError("Injected frozen context migration failure")
            return original(self, table_name, column, **kwargs)
        with monkeypatch.context() as scoped:
            scoped.setattr(Operations, "add_column", fail_context)
            with pytest.raises(RuntimeError, match="Injected frozen context"):
                upgrade_database(engine)
        assert dump(engine) == before
        assert sa.inspect(engine).get_table_names() == tables
        with engine.connect() as connection:
            validate_schema(connection)
            assert connection.scalar(sa.text("SELECT version_num FROM alembic_version")) == PREVIOUS
            assert_sqlite_integrity(connection)
            assert not next(column for column in sa.inspect(connection).get_columns("ai_assessments")
                if column["name"] == "score")["nullable"]
        upgrade_database(engine)
    finally:
        engine.dispose()


def test_frozen_previous_schema_retains_required_score_and_no_attempt_context():
    old = expected_schema(PREVIOUS)
    current = expected_schema(HEAD)
    assert not old.tables["ai_assessments"].c.score.nullable
    assert "ai_input" not in old.tables["submission_attempts"].c
    assert current.tables["ai_assessments"].c.score.nullable
    assert current.tables["submission_attempts"].c.ai_input.nullable
