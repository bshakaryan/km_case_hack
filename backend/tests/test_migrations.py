from datetime import datetime, timedelta, timezone
from pathlib import Path
import subprocess
import sys

import pytest
import sqlalchemy as sa
from alembic import command
from alembic.operations import Operations

from app.db import Base, make_engine
from app.migrations import SchemaCompatibilityError, alembic_config, check_expression, expected_schema, upgrade_database
from app.security import token_hash


def revision(engine, target):
    with engine.connect() as connection:
        command.upgrade(alembic_config(connection), target)


def snapshot(engine):
    metadata = sa.MetaData()
    metadata.reflect(engine)
    with engine.connect() as connection:
        return {name: [{key: value for key, value in row.items() if key != "assigned_at"}
                       for row in connection.execute(sa.select(table).order_by(table.c.id)).mappings()]
                for name, table in metadata.tables.items() if name != "alembic_version"}


def fill_legacy(engine, has_commands):
    schema = expected_schema("0002_client_commands" if has_commands else "0001_initial")
    created = datetime.now(timezone.utc) - timedelta(hours=2)
    with engine.begin() as connection:
        connection.execute(schema.tables["areas"].insert(), {"id": 1, "name": "Synthetic area"})
        connection.execute(schema.tables["brigades"].insert(), [{"id": 1, "name": "Brigade 1"}, {"id": 2, "name": "Brigade 2"}])
        connection.execute(schema.tables["employees"].insert(), [
            {"id": id_, "name": f"Person {id_}", "login": f"person{id_}", "role": "master" if id_ == 1 else "worker",
             "pin_hash": "synthetic-pin-hash", "specialty": "", "grade": 0, "brigade_id": None if id_ == 1 else 1, "on_shift": True}
            for id_ in [1, 5, 6]])
        connection.execute(schema.tables["equipment"].insert(), {"id": 3, "name": "Equipment", "inventory_number": "SYN-3", "area_id": 1, "type": "pump", "criticality": "medium"})
        connection.execute(schema.tables["materials"].insert(), {"id": 1, "name": "Material", "unit": "piece"})
        connection.execute(schema.tables["fault_codes"].insert(), {"id": 1, "code": "F1", "name": "Fault"})
        connection.execute(schema.tables["auth_sessions"].insert(), {"id": 21, "token_hash": token_hash("synthetic-kept-session"), "employee_id": 6, "expires_at": created + timedelta(days=2)})
        for id_ in range(1, 6):
            connection.execute(schema.tables["orders"].insert(), {"id": id_, "number": f"SYN-{id_}", "title": f"Synthetic order {id_}",
                "description": "Keep original report", "work_type": "planned", "area_id": 1, "equipment_id": 3, "assignee_id": 6,
                "brigade_id": 1, "master_id": 1, "priority": "normal", "status": "issued", "deadline": created + timedelta(days=1),
                "created_at": created, "started_at": None, "completed_at": None, "closed_at": None, "comment": "Preserve",
                "normal_hours": 2, "downtime_minutes": 0, "score": None, "completion": {"work_done": "Keep", "materials": []}, "ai_review": None})
        event_specs = [
            (1, 10, "assignee_id=6"), (1, 40, "assignee_id=6; comment=renewed"),
            (1, 50, "comment=not assignment; assignee_id=6"),
            (2, 10, "assignee_id=6"), (2, 40, "assignee_id=5"),
            (3, 30, "comment=spoof; assignee_id=6"),
            (4, 30, "brigade_id=1"), (5, -5, "assignee_id=6"),
        ]
        connection.execute(schema.tables["order_events"].insert(), [{"id": 101 + index, "order_id": order_id,
            "action": "edit", "from_status": "issued", "to_status": "issued", "actor_id": 1,
            "created_at": created + timedelta(minutes=minutes), "comment": comment}
            for index, (order_id, minutes, comment) in enumerate(event_specs)])
        connection.execute(schema.tables["photos"].insert(), {"id": 31, "order_id": 1, "kind": "after", "data": b"preserved-synthetic-photo", "author_id": 6, "created_at": created})
        connection.execute(schema.tables["material_writeoffs"].insert(), {"id": 41, "order_id": 1, "material_id": 1, "quantity": 2, "author_id": 6, "created_at": created})
        connection.execute(schema.tables["notifications"].insert(), {"id": 51, "employee_id": 6, "title": "Keep", "message": "Keep notification", "kind": "assigned", "order_id": 1, "created_at": created, "read": True, "dedupe_key": "keep-notification"})
        connection.execute(schema.tables["integration_logs"].insert(), {"id": 61, "adapter": "synthetic", "operation": "keep", "payload": {"sent": False}, "created_at": created})
        connection.execute(schema.tables["ai_assessments"].insert(), {"id": 81, "order_id": 1, "verdict": "passed", "score": 4,
            "explanation": "Keep assessment", "is_stub": True, "master_score": None, "created_at": created})
        if has_commands:
            connection.execute(schema.tables["client_commands"].insert(), {"id": 71, "employee_id": 6, "client_id": "kept-command-0001",
                "kind": "complete", "request_hash": "b" * 64, "response_status": 200, "response_body": {"id": 1, "status": "ai_review", "nested": {"keep": True}}, "created_at": created})
    return created.replace(tzinfo=None)


@pytest.mark.parametrize("legacy", ["unversioned1", "unversioned2", "versioned1", "versioned1-with-commands", "versioned2"])
def test_filled_legacy_upgrade_preserves_data_and_backfills_current_assignment(tmp_path, legacy):
    engine = make_engine(f"sqlite:///{tmp_path / 'legacy.sqlite'}")
    has_commands = legacy in {"unversioned2", "versioned1-with-commands", "versioned2"}
    revision(engine, "0002_client_commands" if has_commands else "0001_initial")
    created = fill_legacy(engine, has_commands)
    with engine.begin() as connection:
        if legacy.startswith("unversioned"):
            connection.exec_driver_sql("DROP TABLE alembic_version")
        elif legacy == "versioned1-with-commands":
            connection.exec_driver_sql("UPDATE alembic_version SET version_num='0001_initial'")
    before = snapshot(engine)
    upgrade_database(engine)
    after = snapshot(engine)
    assert {name: rows for name, rows in after.items() if name in before} == before
    schema = expected_schema("0003_push")
    with engine.connect() as connection:
        assigned = dict(connection.execute(sa.select(schema.tables["orders"].c.id, schema.tables["orders"].c.assigned_at)).all())
        assert assigned == {1: created + timedelta(minutes=40), 2: created, 3: created, 4: created + timedelta(minutes=30), 5: created}
        assert connection.exec_driver_sql("SELECT version_num FROM alembic_version").scalar_one() == "0003_push"
        assert connection.exec_driver_sql("PRAGMA foreign_keys").scalar_one() == 1
        assert not connection.exec_driver_sql("PRAGMA foreign_key_check").all()
    upgrade_database(engine)
    assert snapshot(engine) == after
    engine.dispose()


def test_initial_migration_is_independent_of_current_orm(tmp_path, monkeypatch):
    engine = make_engine(f"sqlite:///{tmp_path / 'initial.sqlite'}")
    future = sa.Table("future_table_not_in_initial_schema", Base.metadata, sa.Column("id", sa.Integer(), primary_key=True))
    def forbidden(*args, **kwargs):
        raise AssertionError("Historical migration used current ORM create_all")
    monkeypatch.setattr(Base.metadata, "create_all", forbidden)
    try:
        revision(engine, "0001_initial")
        assert set(sa.inspect(engine).get_table_names()) == set(expected_schema("0001_initial").tables) | {"alembic_version"}
        assert "assigned_at" not in {column["name"] for column in sa.inspect(engine).get_columns("orders")}
    finally:
        Base.metadata.remove(future)
        engine.dispose()


def test_historical_migration_can_run_when_application_orm_import_is_forbidden(tmp_path):
    backend = Path(alembic_config().get_main_option("script_location")).parent
    code = """
import builtins
import sqlalchemy as sa
from alembic import command
original_import = builtins.__import__
def guarded_import(name, globals=None, locals=None, fromlist=(), level=0):
    if name == 'app.models' or (name == 'app' and 'models' in fromlist):
        raise AssertionError('Historical migration imported current app.models')
    return original_import(name, globals, locals, fromlist, level)
builtins.__import__ = guarded_import
from app.migrations import alembic_config
engine = sa.create_engine(DATABASE_URL)
with engine.connect() as connection:
    command.upgrade(alembic_config(connection), '0001_initial')
assert 'client_commands' not in sa.inspect(engine).get_table_names()
engine.dispose()
"""
    code = code.replace("DATABASE_URL", repr(f"sqlite:///{tmp_path / 'no-orm.sqlite'}"))
    result = subprocess.run([sys.executable, "-c", code], cwd=str(backend), capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("defect", ["partial", "nullable", "unique", "check", "extra_index", "partial_index", "client_unique", "unknown_revision"])
def test_unknown_or_incompatible_schema_is_refused_without_changes(tmp_path, defect):
    engine = make_engine(f"sqlite:///{tmp_path / 'invalid.sqlite'}")
    schema = expected_schema("0002_client_commands" if defect == "client_unique" else "0001_initial")
    if defect == "nullable":
        schema.tables["orders"].c.description.nullable = True
    if defect in {"unique", "client_unique"}:
        table = schema.tables["employees" if defect == "unique" else "client_commands"]
        unique = next(item for item in table.constraints if isinstance(item, sa.UniqueConstraint))
        table.constraints.remove(unique)
    if defect == "check":
        table = schema.tables["orders"]
        table.constraints.remove(next(item for item in table.constraints if isinstance(item, sa.CheckConstraint) and item.name == "ck_order_status"))
        table.append_constraint(sa.CheckConstraint("status IN ('issued')", name="ck_order_status"))
    if defect == "extra_index":
        sa.Index("unrecognized_index", schema.tables["orders"].c.title)
    if defect == "partial_index":
        index = next(item for item in schema.tables["orders"].indexes if item.name == "ix_orders_number")
        index.dialect_options["sqlite"]["where"] = sa.text("status = 'closed'")
    with engine.begin() as connection:
        for table in schema.sorted_tables:
            if defect != "partial" or table.name == "areas":
                table.create(connection)
        if defect == "unknown_revision":
            connection.exec_driver_sql("CREATE TABLE alembic_version (version_num VARCHAR(32) NOT NULL PRIMARY KEY)")
            connection.exec_driver_sql("INSERT INTO alembic_version VALUES ('unknown_revision')")
    before_tables = sa.inspect(engine).get_table_names()
    before = snapshot(engine)
    with pytest.raises(SchemaCompatibilityError):
        upgrade_database(engine)
    assert sa.inspect(engine).get_table_names() == before_tables
    assert snapshot(engine) == before
    engine.dispose()


def test_sqlite_failed_migration_rolls_back_ddl_and_keeps_foreign_keys(tmp_path, monkeypatch):
    engine = make_engine(f"sqlite:///{tmp_path / 'rollback.sqlite'}")
    revision(engine, "0002_client_commands")
    fill_legacy(engine, True)
    before = snapshot(engine)
    def fail_batch(*args, **kwargs):
        raise RuntimeError("Injected batch migration failure")
    with monkeypatch.context() as scoped:
        scoped.setattr(Operations, "batch_alter_table", fail_batch)
        with pytest.raises(RuntimeError, match="Injected batch"):
            upgrade_database(engine)
    assert snapshot(engine) == before
    assert "assigned_at" not in {column["name"] for column in sa.inspect(engine).get_columns("orders")}
    with engine.connect() as connection:
        assert connection.exec_driver_sql("SELECT version_num FROM alembic_version").scalar_one() == "0002_client_commands"
        assert connection.exec_driver_sql("PRAGMA foreign_keys").scalar_one() == 1
    upgrade_database(engine)
    engine.dispose()


def test_assignment_migration_downgrade_and_upgrade_preserve_filled_database(tmp_path):
    engine = make_engine(f"sqlite:///{tmp_path / 'roundtrip.sqlite'}")
    revision(engine, "0002_client_commands")
    fill_legacy(engine, True)
    upgrade_database(engine)
    before = snapshot(engine)
    with engine.connect() as connection:
        command.downgrade(alembic_config(connection), "0002_client_commands")
    assert snapshot(engine) == {name: rows for name, rows in before.items() if name not in {"device_tokens", "push_tasks"}}
    assert "assigned_at" not in {column["name"] for column in sa.inspect(engine).get_columns("orders")}
    upgrade_database(engine)
    assert snapshot(engine) == before
    engine.dispose()


def test_postgresql_check_normalization_keeps_boolean_meaning():
    assert check_expression("status IN ('issued','closed')") == check_expression("((status)::text = ANY ((ARRAY['issued'::character varying, 'closed'::character varying])::text[]))")
    assert check_expression("score IS NULL OR (score >= 1 AND score <= 5)") == check_expression("((score IS NULL) OR ((score >= (1)::double precision) AND (score <= (5)::double precision)))")
    assert check_expression("score IS NULL OR (score >= 1 AND score <= 5)") != check_expression("(score IS NULL OR score >= 1) AND score <= 5")
