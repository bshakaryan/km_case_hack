import os
import re
import uuid

import pytest
import sqlalchemy as sa
from fastapi.testclient import TestClient
from app.db import make_engine
from app.main import create_app


@pytest.fixture(scope="session", autouse=True)
def existing_api_inline_stub():
    # Existing lifecycle tests deliberately retain their synchronous contract.
    # New queued-job tests override this explicitly before create_app().
    with pytest.MonkeyPatch.context() as patch:
        if "AI_REVIEW_MODE" not in os.environ:
            patch.setenv("AI_REVIEW_MODE", "inline_stub")
        yield


@pytest.fixture(scope="module")
def client(tmp_path_factory):
    database = tmp_path_factory.mktemp("api") / "test.db"
    app = create_app(f"sqlite:///{database}", monitor=False)
    with TestClient(app) as test_client:
        yield test_client


def auth_headers(client, login="master"):
    response = client.post("/api/auth/login", json={"login": login, "pin": "1234"})
    assert response.status_code == 200, response.text
    return {"Authorization": "Bearer " + response.json()["token"]}


@pytest.fixture
def master(client):
    return auth_headers(client, "master")


@pytest.fixture
def worker(client):
    return auth_headers(client, "worker2")


class PostgreSQLTestDatabase:
    """A fresh schema; every application connection uses only that schema."""

    def __init__(self, url, schema):
        self.url = url
        self.schema = schema
        self._engines = []
        self.engine = self.make_engine()

    def __repr__(self):
        # Fixture diagnostics must not include the connection password.
        return f"PostgreSQLTestDatabase(schema={self.schema!r})"

    def make_engine(self):
        engine = make_engine(self.url)
        self._engines.append(engine)
        return engine

    def dispose(self):
        for engine in self._engines:
            engine.dispose()


@pytest.fixture
def pg_database():
    """Opt in with TEST_POSTGRESQL_URL; never clear an existing public schema."""
    configured = os.getenv("TEST_POSTGRESQL_URL", "").strip()
    required = os.getenv("REQUIRE_POSTGRESQL_TESTS", "").strip().lower() in {"1", "true", "yes", "on"}
    if not configured:
        if required:
            pytest.fail("REQUIRE_POSTGRESQL_TESTS needs TEST_POSTGRESQL_URL", pytrace=False)
        pytest.skip("Set TEST_POSTGRESQL_URL to run tests against real PostgreSQL")
    try:
        url = sa.engine.make_url(configured)
    except sa.exc.ArgumentError:
        pytest.fail("TEST_POSTGRESQL_URL must be a valid PostgreSQL URL", pytrace=False)
    if url.get_backend_name() != "postgresql" or not url.database:
        pytest.fail("TEST_POSTGRESQL_URL must name a PostgreSQL database", pytrace=False)
    url = url.set(drivername="postgresql+psycopg", query={**url.query, "connect_timeout": "5"})
    admin = sa.create_engine(url, pool_pre_ping=True)
    schema = "codex_pgtest_" + uuid.uuid4().hex
    created = False
    database = None
    try:
        try:
            with admin.begin() as connection:
                connection.execute(sa.schema.CreateSchema(schema))
            created = True
        except sa.exc.SQLAlchemyError:
            pytest.fail("Cannot connect to PostgreSQL or create an isolated test schema", pytrace=False)
        isolated = url.set(query={**url.query, "options": f"-c search_path={schema} -c statement_timeout=15000 -c lock_timeout=10000"})
        database = PostgreSQLTestDatabase(isolated.render_as_string(hide_password=False), schema)
        with database.engine.connect() as connection:
            assert connection.scalar(sa.text("SELECT current_schema()")) == schema
            assert connection.scalar(sa.text("SHOW search_path")) == schema
        yield database
    finally:
        if database is not None:
            database.dispose()
        if created:
            # The only destructive operation targets the schema this fixture
            # successfully created. Generated identifiers cannot name public.
            assert re.fullmatch(r"codex_pgtest_[0-9a-f]{32}", schema)
            with admin.begin() as connection:
                connection.execute(sa.schema.DropSchema(schema, cascade=True))
        admin.dispose()
