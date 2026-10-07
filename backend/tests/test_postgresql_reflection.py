"""Guard regressions using installed PostgreSQL reflection, without a server.

Synthetic catalog rows enter the real SQLAlchemy dialect decoders. This checks
reflection compatibility only; it does not exercise PostgreSQL transactions.
"""
import inspect
from types import SimpleNamespace

import pytest
import sqlalchemy as sa
from sqlalchemy.dialects.postgresql import dialect
from sqlalchemy.engine.reflection import ObjectKind, ObjectScope

from app.migrations import SchemaCompatibilityError, _validate_table, expected_schema


class CatalogInspector:
    default_schema_name = "public"

    def __init__(self, table, foreign_suffix="NOT DEFERRABLE", check_flag="plain"):
        self.table = table
        self.foreign_suffix = foreign_suffix
        self.check_flag = check_flag
        self.dialect = dialect()
        self.dialect.server_version_info = (17, 0)
        self.dialect.default_schema_name = self.default_schema_name
        self.arguments = {"schema": None, "filter_names": [table.name], "scope": ObjectScope.ANY, "kind": ObjectKind.ANY}

    def get_columns(self, name):
        rows = []
        for column in self.table.columns:
            if isinstance(column.type, sa.DateTime):
                format_type = "timestamp with time zone"
            elif isinstance(column.type, sa.Float):
                format_type = "double precision"
            elif isinstance(column.type, sa.String) and not isinstance(column.type, sa.Text):
                format_type = f"character varying({column.type.length})"
            else:
                format_type = str(column.type.compile(dialect=self.dialect)).lower()
            rows.append({"table_name": name, "name": column.name, "format_type": format_type,
                "collation": None,
                "default": f"nextval('{name}_id_seq'::regclass)" if column.primary_key else None,
                "generated": None, "not_null": not column.nullable, "identity_options": None, "comment": None})
        if "named_type_loader" in inspect.signature(self.dialect._get_columns_info).parameters:
            # SQLAlchemy 2.1 supplies domains/enums through a named-type loader and
            # expects a `collation` entry in every synthetic catalog row.
            loader = SimpleNamespace(enums={}, domains={})
            return self.dialect._get_columns_info(rows, loader, None)[(None, name)]
        # SQLAlchemy 2.0 signature: (rows, domains, enums, schema).
        return self.dialect._get_columns_info(rows, {}, {}, None)[(None, name)]

    def get_pk_constraint(self, name):
        return {"constrained_columns": [column.name for column in self.table.primary_key.columns]}

    def get_unique_constraints(self, name):
        rows = [(name, [column.name for column in item.columns], item.name or "synthetic_unique", None, {"nullsnotdistinct": False})
                for item in self.table.constraints if isinstance(item, sa.UniqueConstraint)]
        self.dialect._reflect_constraint = lambda *args, **kwargs: iter(rows)
        return dict(self.dialect.get_multi_unique_constraints(None, **self.arguments)).get((None, name), [])

    def get_indexes(self, name):
        rows = [{"indrelid": 100, "relname": item.name, "elements": [column.name for column in item.columns],
                 "elements_is_expr": [False for _ in item.columns], "elements_opclass": [0 for _ in item.columns],
                 "indnkeyatts": len(item.columns), "indisunique": item.unique, "indisvalid": True,
                 "indoption": [0 for _ in item.columns], "has_constraint": False, "reloptions": None,
                 "relam": 403, "filter_definition": None, "indnullsnotdistinct": False}
                for item in self.table.indexes]
        self.dialect._get_table_oids = lambda *args, **kwargs: [(100, name)]
        connection = SimpleNamespace(
            execute=lambda *args, **kwargs: SimpleNamespace(mappings=lambda: iter(rows), all=lambda: iter(())),
            scalar=lambda *args, **kwargs: 403,  # btree access-method oid for SQLAlchemy 2.1
        )
        return dict(self.dialect.get_multi_indexes(connection, **self.arguments)).get((None, name), [])

    def get_foreign_keys(self, name):
        rows = [(name, "synthetic_fk", "FOREIGN KEY (" + ", ".join(column.name for column in item.columns) + ") REFERENCES "
                 + item.referred_table.name + "(" + ", ".join(element.column.name for element in item.elements) + ") " + self.foreign_suffix,
                 "public", None) for item in self.table.foreign_key_constraints]
        connection = SimpleNamespace(execute=lambda *args, **kwargs: iter(rows))
        return dict(self.dialect.get_multi_foreign_keys(connection, **self.arguments)).get((None, name), [])

    def get_check_constraints(self, name):
        suffix = {"not_valid": " NOT VALID", "no_inherit": " NO INHERIT"}.get(self.check_flag, "")
        rows = [(name, item.name, f"CHECK ({item.sqltext}){suffix}", None)
                for item in self.table.constraints if isinstance(item, sa.CheckConstraint)]
        connection = SimpleNamespace(execute=lambda *args, **kwargs: iter(rows))
        checks = dict(self.dialect.get_multi_check_constraints(connection, **self.arguments)).get((None, name), [])
        for item in checks:
            if self.check_flag == "explicit_false":
                item["dialect_options"] = {"not_valid": False, "no_inherit": False}
            elif self.check_flag == "unknown":
                item["dialect_options"] = {"unknown_check_option": False}
        return checks


def test_postgresql_default_reflection_accepts_nondeferrable_and_rejects_deferrable_fk():
    table = expected_schema("0003_assignment_time").tables["orders"]
    default = CatalogInspector(table)
    assert all(item["options"] == {"deferrable": False} for item in default.get_foreign_keys(table.name))
    _validate_table(default, table, default.dialect)
    deferred = CatalogInspector(table, foreign_suffix="DEFERRABLE")
    with pytest.raises(SchemaCompatibilityError, match="foreign keys"):
        _validate_table(deferred, table, deferred.dialect)


@pytest.mark.parametrize("flag", ["plain", "explicit_false", "not_valid", "no_inherit", "unknown"])
def test_postgresql_check_flags_accept_defaults_and_refuse_weaker_or_unknown_checks(flag):
    table = expected_schema("0003_assignment_time").tables["orders"]
    inspector = CatalogInspector(table, check_flag=flag)
    if flag in {"plain", "explicit_false"}:
        _validate_table(inspector, table, inspector.dialect)
    else:
        with pytest.raises(SchemaCompatibilityError, match="check options"):
            _validate_table(inspector, table, inspector.dialect)
