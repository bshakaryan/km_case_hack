"""Validated Alembic startup and frozen revision schema expectations."""
import ast
import re
from pathlib import Path

import sqlalchemy as sa
from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory

BACKEND = Path(__file__).resolve().parents[1]
REVISIONS = ("0001_initial", "0002_client_commands", "0003_assignment_time")


class SchemaCompatibilityError(RuntimeError):
    pass


def alembic_config(connection=None):
    config = Config(str(BACKEND / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND / "migrations"))
    config.attributes["configure_logging"] = False
    if connection is not None:
        config.attributes["connection"] = connection
    return config


def expected_schema(revision):
    """Historical snapshots, deliberately independent of the current ORM."""
    initial = ScriptDirectory.from_config(alembic_config()).get_revision(REVISIONS[0]).module
    metadata = initial.schema()
    if revision in REVISIONS[1:]:
        # Exact DDL of immutable 0002_client_commands.
        sa.Table("client_commands", metadata,
            sa.Column("id", sa.Integer(), primary_key=True, nullable=False),
            sa.Column("employee_id", sa.Integer(), sa.ForeignKey("employees.id"), nullable=False, index=True),
            sa.Column("client_id", sa.String(64), nullable=False),
            sa.Column("kind", sa.String(40), nullable=False),
            sa.Column("request_hash", sa.String(64), nullable=False),
            sa.Column("response_status", sa.Integer(), nullable=True),
            sa.Column("response_body", sa.JSON(), nullable=True),
            sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
            sa.UniqueConstraint("employee_id", "client_id", name="uq_client_command_employee_client"),
        )
    if revision == REVISIONS[2]:
        metadata.tables["orders"].append_column(sa.Column("assigned_at", sa.DateTime(timezone=True), nullable=False))
    return metadata


def check_expression(expression):
    """Canonicalize our checks, including PostgreSQL's IN -> ANY rewrite.

    Parse the boolean structure rather than removing parentheses: different
    grouping of AND/OR must not be accepted as an equivalent constraint.
    """
    expression = re.sub(r"::(?:character varying|double precision|text|integer|numeric)(?:\[\])?", "", expression, flags=re.I)
    expression = re.sub(r"\bARRAY\s*\[", "[", expression, flags=re.I)
    expression = re.sub(r"=\s*ANY\s*\(", " in (", expression, flags=re.I)
    for sql, python in [("AND", "and"), ("OR", "or"), ("IS", "is"), ("NULL", "None"), ("IN", "in")]:
        expression = re.sub(rf"\b{sql}\b", python, expression, flags=re.I)
    expression = re.sub(r'"([a-z_]+)"', r"\1", expression)
    try:
        tree = ast.parse(expression.strip(), mode="eval").body
    except SyntaxError as error:
        raise SchemaCompatibilityError("Unsupported database check expression") from error

    def canonical(node):
        if isinstance(node, ast.Name):
            return ("column", node.id)
        if isinstance(node, ast.Constant):
            return ("value", node.value)
        if isinstance(node, (ast.Tuple, ast.List)):
            return ("values", tuple(canonical(item) for item in node.elts))
        if isinstance(node, ast.Compare) and len(node.ops) == 1:
            return (type(node.ops[0]).__name__, canonical(node.left), canonical(node.comparators[0]))
        if isinstance(node, ast.BoolOp):
            values = []
            for item in node.values:
                parsed = canonical(item)
                if isinstance(item, ast.BoolOp) and type(item.op) is type(node.op):
                    values.extend(parsed[1])
                else:
                    values.append(parsed)
            return (type(node.op).__name__, tuple(values))
        raise SchemaCompatibilityError("Unsupported database check expression")

    return canonical(tree)


def _validate_table(inspector, table, dialect):
    actual = {column["name"]: column for column in inspector.get_columns(table.name)}
    expected = {column.name: column for column in table.columns}
    if actual.keys() != expected.keys():
        raise SchemaCompatibilityError(f"Incompatible columns in {table.name}: expected {sorted(expected)}, found {sorted(actual)}")
    for name, column in expected.items():
        found = actual[name]
        expected_type = str(column.type.compile(dialect=dialect)).upper()
        actual_type = str(found["type"].compile(dialect=dialect)).upper()
        same_type = expected_type == actual_type
        # PostgreSQL reflects generic FLOAT as DOUBLE PRECISION.
        if isinstance(column.type, sa.Float) and column.type.precision is None and actual_type == "DOUBLE PRECISION":
            same_type = True
        if not same_type or bool(found["nullable"]) != column.nullable:
            raise SchemaCompatibilityError(f"Incompatible type/nullability in {table.name}.{name}")
        serial = dialect.name == "postgresql" and column.primary_key and isinstance(column.type, sa.Integer)
        if serial and (not found.get("default") or not found["default"].startswith("nextval(")):
            raise SchemaCompatibilityError(f"Missing or incompatible serial default in {table.name}.{name}")
        if found.get("default") is not None and not serial:
            raise SchemaCompatibilityError(f"Unexpected server default in {table.name}.{name}")
    if tuple(inspector.get_pk_constraint(table.name).get("constrained_columns") or ()) != tuple(column.name for column in table.primary_key.columns):
        raise SchemaCompatibilityError(f"Incompatible primary key in {table.name}")
    expected_unique = {tuple(column.name for column in constraint.columns) for constraint in table.constraints if isinstance(constraint, sa.UniqueConstraint)}
    actual_unique = {tuple(constraint["column_names"]) for constraint in inspector.get_unique_constraints(table.name)}
    if expected_unique != actual_unique or any(constraint.get("dialect_options") for constraint in inspector.get_unique_constraints(table.name)):
        raise SchemaCompatibilityError(f"Incompatible uniqueness constraints in {table.name}")
    expected_indexes = {(index.name, tuple(column.name for column in index.columns), bool(index.unique)) for index in table.indexes}
    indexes = [index for index in inspector.get_indexes(table.name) if not index.get("duplicates_constraint")]
    actual_indexes = {(index["name"], tuple(index["column_names"]), bool(index["unique"])) for index in indexes}
    if expected_indexes != actual_indexes:
        raise SchemaCompatibilityError(f"Incompatible indexes in {table.name}")
    for index in indexes:
        options = {key: value for key, value in index.get("dialect_options", {}).items() if not (key == "postgresql_include" and value == [])}
        if options:
            raise SchemaCompatibilityError(f"Incompatible index options in {table.name}")
    expected_fk = {(tuple(column.name for column in constraint.columns), constraint.referred_table.name, tuple(element.column.name for element in constraint.elements)) for constraint in table.foreign_key_constraints}
    actual_fk = {(tuple(constraint["constrained_columns"]), constraint["referred_table"], tuple(constraint["referred_columns"])) for constraint in inspector.get_foreign_keys(table.name)}
    foreign_keys = inspector.get_foreign_keys(table.name)
    if expected_fk != actual_fk:
        raise SchemaCompatibilityError(f"Incompatible foreign keys in {table.name}")
    for constraint in foreign_keys:
        options = {key: value for key, value in constraint.get("options", {}).items() if not (key == "deferrable" and value is False)}
        if options or constraint.get("referred_schema") not in {None, inspector.default_schema_name}:
            raise SchemaCompatibilityError(f"Incompatible foreign keys in {table.name}")
    expected_checks = {constraint.name: check_expression(str(constraint.sqltext)) for constraint in table.constraints if isinstance(constraint, sa.CheckConstraint)}
    actual_checks = {constraint["name"]: check_expression(constraint["sqltext"]) for constraint in inspector.get_check_constraints(table.name)}
    if expected_checks != actual_checks:
        raise SchemaCompatibilityError(f"Incompatible check constraints in {table.name}")
    for constraint in inspector.get_check_constraints(table.name):
        options = {key: value for key, value in constraint.get("dialect_options", {}).items() if not (key in {"not_valid", "no_inherit"} and value is False)}
        if options:
            raise SchemaCompatibilityError(f"Incompatible check options in {table.name}")


def validate_schema(connection):
    """Accept a complete known schema; never stamp an unverified database."""
    inspector = sa.inspect(connection)
    tables = set(inspector.get_table_names())
    revision = None
    if "alembic_version" in tables:
        columns = inspector.get_columns("alembic_version")
        if len(columns) != 1 or columns[0]["name"] != "version_num" or columns[0]["nullable"] or getattr(columns[0]["type"], "length", None) != 32:
            raise SchemaCompatibilityError("Incompatible alembic_version table")
        if tuple(inspector.get_pk_constraint("alembic_version").get("constrained_columns") or ()) != ("version_num",):
            raise SchemaCompatibilityError("Incompatible Alembic revision primary key")
        rows = list(connection.execute(sa.text("SELECT version_num FROM alembic_version")).scalars())
        if len(rows) > 1 or (rows and rows[0] not in REVISIONS):
            raise SchemaCompatibilityError("Unknown or multiple Alembic revisions")
        revision = rows[0] if rows else None
    tables.discard("alembic_version")
    if not tables:
        if revision is not None:
            raise SchemaCompatibilityError("Alembic revision exists without application tables")
        return
    # Old 0001 imported mutable ORM metadata, so a recorded 0001 can already
    # contain the complete 0002 table. Validate that exact recognized shape.
    shape_revision = revision or REVISIONS[0]
    if shape_revision == REVISIONS[0] and "client_commands" in tables:
        shape_revision = REVISIONS[1]
    expected = expected_schema(shape_revision)
    if tables != set(expected.tables):
        raise SchemaCompatibilityError(f"Incompatible tables: expected {sorted(expected.tables)}, found {sorted(tables)}")
    for table in expected.sorted_tables:
        _validate_table(inspector, table, connection.dialect)
    if connection.dialect.name == "sqlite" and connection.exec_driver_sql("PRAGMA foreign_key_check").first():
        raise SchemaCompatibilityError("Existing database has broken foreign-key relationships")


def migrate_connection(connection, config):
    """Run env.py migrations under one transaction/lock, including SQLite DDL."""
    sqlite = connection.dialect.name == "sqlite"
    if sqlite:
        # SQLite batch changes recreate orders; FK checks must be suspended on
        # this connection outside the transaction, then verified before commit.
        connection.exec_driver_sql("PRAGMA foreign_keys=OFF")
        connection.commit()
        connection.exec_driver_sql("BEGIN IMMEDIATE")
    else:
        connection.begin()
    try:
        if connection.dialect.name == "postgresql":
            connection.execute(sa.text("SELECT pg_advisory_xact_lock(1095648841, 1)"))
        validate_schema(connection)
        from alembic import context
        context.configure(connection=connection, target_metadata=None, transaction_per_migration=False)
        context.run_migrations()
        validate_schema(connection)
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        if sqlite:
            connection.exec_driver_sql("PRAGMA foreign_keys=ON")
            connection.commit()


def upgrade_database(engine):
    with engine.connect() as connection:
        command.upgrade(alembic_config(connection), "head")
