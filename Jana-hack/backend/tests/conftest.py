"""HTTP scenarios on migrated SQLite, or isolated PostgreSQL schemas.

No create_all, production secrets, or mutation of persistent application tables.
App imports happen only after the test environment has been installed.
"""
from pathlib import Path
from types import SimpleNamespace
import os
from uuid import uuid4

import pytest
import httpx
from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, select, text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import sessionmaker


BACKEND = Path(__file__).resolve().parents[1]
TEST_PASSWORD = "test-only-demo-password-2026"
TEST_SECRET = "test-only-jwt-secret-never-use-outside-pytest-2026"


@pytest.fixture
def database(monkeypatch, tmp_path):
    postgres_admin = None
    schema = None
    if os.environ.get("POSTGRES_TEST") == "1":
        source_url = make_url(os.environ["DATABASE_URL"])
        if source_url.get_backend_name() != "postgresql":
            raise ValueError("POSTGRES_TEST requires a PostgreSQL DATABASE_URL")
        schema = "jana_test_" + uuid4().hex
        postgres_admin = create_engine(source_url)
        with postgres_admin.begin() as connection:
            connection.execute(text(f'CREATE SCHEMA "{schema}"'))
        scenario_url = source_url.update_query_dict({"options": f"-csearch_path={schema}"}).render_as_string(hide_password=False)
    else:
        scenario_url = f"sqlite:///{tmp_path / 'scenario.sqlite3'}"
    monkeypatch.setenv("DATABASE_URL", scenario_url)
    monkeypatch.setenv("JWT_SECRET", TEST_SECRET)
    monkeypatch.setenv("DEMO_PASSWORD", TEST_PASSWORD)
    monkeypatch.setenv("ZUP_API_TOKEN", TEST_SECRET)

    from app.config import get_settings
    from app.database import Base, get_engine
    from app.seed import seed
    from app.mock_zup import create_mock_app
    from app.modules import integrations

    zup_app = create_mock_app(str(tmp_path / "zup.sqlite3"), TEST_SECRET)
    zup_client = TestClient(zup_app)
    zup_client.__enter__()

    def transport(request):
        return zup_client.request(request.method, request.url.path, headers=dict(request.headers), content=request.content)

    adapter = integrations.HttpZupAdapter("http://zup.test/hs/jana/v1", TEST_SECRET, httpx.MockTransport(transport))
    monkeypatch.setattr(integrations, "zup_adapter", lambda: adapter)
    # Seed imports this factory directly; all scenario calls still cross HTTP.
    monkeypatch.setattr("app.seed.zup_adapter", lambda: adapter)

    if get_engine.cache_info().currsize:
        get_engine().dispose()
    get_engine.cache_clear()
    get_settings.cache_clear()
    config = Config(str(BACKEND / "alembic.ini"))
    try:
        command.upgrade(config, "head")
        seed()
        engine = get_engine()

        def snapshot(*names):
            tables = [table for table in Base.metadata.sorted_tables if not names or table.name in names]
            with engine.connect() as connection:
                return {
                    table.name: connection.execute(select(table).order_by(*table.primary_key.columns)).all()
                    for table in tables
                }

        yield SimpleNamespace(
            engine=engine,
            session=sessionmaker(engine, expire_on_commit=False),
            snapshot=snapshot,
            config=config,
            seed=seed,
            password=TEST_PASSWORD,
            secret=TEST_SECRET,
            zup=zup_client,
            adapter=adapter,
            zup_path=tmp_path / "zup.sqlite3",
        )
    finally:
        zup_client.__exit__(None, None, None)
        if get_engine.cache_info().currsize:
            get_engine().dispose()
        get_engine.cache_clear()
        get_settings.cache_clear()

        if postgres_admin is not None:
            with postgres_admin.begin() as connection:
                connection.execute(text(f'DROP SCHEMA "{schema}" CASCADE'))
            postgres_admin.dispose()


class Scenario:
    def __init__(self, client, database):
        self.client = client
        self.db = database
        self._headers = {}

    def headers(self, actor="employee"):
        if actor not in self._headers:
            response = self.client.post(
                "/api/auth/login",
                json={"email": f"{actor}@example.com", "password": self.db.password},
            )
            assert response.status_code == 200, response.text
            self._headers[actor] = {"Authorization": f"Bearer {response.json()['access_token']}"}
        return self._headers[actor].copy()

    def get(self, path, actor="employee"):
        return self.client.get(path, headers=self.headers(actor))

    def post(self, path, body, actor="employee", **kwargs):
        return self.client.post(path, headers=self.headers(actor), json=body, **kwargs)

    def patch(self, path, body=None, actor="employee"):
        return self.client.patch(path, headers=self.headers(actor), json=body)

    def create(self, actor="employee", key="test-leave-command", **changes):
        body = {"start_date": "2027-01-11", "end_date": "2027-01-15", "comment": "Test leave"}
        body.update(changes)
        return self.client.post(
            "/api/requests", headers={**self.headers(actor), "Idempotency-Key": key}, json=body
        )

    def leave(self, actor="employee", key="test-leave-command", **changes):
        response = self.create(actor, key, **changes)
        assert response.status_code == 201, response.text
        return response.json()

    def decide(self, item, actor="manager", status="approved", version=None):
        return self.patch(
            f"/api/requests/{item['id']}/status",
            {"status": status, "version": item["version"] if version is None else version, "comment": "Human decision"},
            actor,
        )


@pytest.fixture
def api(database):
    from app.main import app

    with TestClient(app) as client:
        yield Scenario(client, database)
