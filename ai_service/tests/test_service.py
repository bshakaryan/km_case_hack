import json

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import inspect

from app.config import Settings
from app.main import create_app
from app.notifier import LogNotifier
from app.storage import AIStore
from app.synthetic_source import SyntheticDataSource
from test_datasources import snapshot_payload


def test_store_creates_only_ai_tables_and_deduplicates_results():
    store = AIStore("sqlite:///:memory:")
    store.initialize()
    assert set(inspect(store.engine).get_table_names()) == {"ai_results", "ai_notifications", "ai_llm_cache"}
    first = store.put_result("review", "7", "event:1", {"verdict": "needs_master_review"})
    second = store.put_result("review", "7", "event:1", {"verdict": "accepted"})
    assert first == second
    with pytest.raises(ValueError, match="подтверждения"):
        AIStore("postgresql+psycopg://user:password@localhost/naryad_ai")
    store.close()


def test_service_protects_snapshot_endpoint_and_serves_swagger(tmp_path):
    path = tmp_path / "snapshot.json"
    path.write_text(json.dumps(snapshot_payload()), encoding="utf-8")
    settings = Settings(ai_service_token="test-secret", ai_database_url="sqlite:///:memory:")
    app = create_app(settings, SyntheticDataSource(path))
    with TestClient(app) as client:
        assert client.get("/ai/health").json()["status"] == "ok"
        assert client.get("/docs").status_code == 200
        assert client.get("/ai/source/summary").status_code == 401
        response = client.get("/ai/source/summary", headers={"Authorization": "Bearer test-secret"})
        assert response.status_code == 200
        assert response.json() == {"source": "synthetic", "orders": 1, "employees": 2, "equipment": 1, "areas": 1}


def test_log_notifier_never_claims_delivery():
    import asyncio

    assert asyncio.run(LogNotifier().send("E-07", "Срок", "Проверьте наряд", "deadline:7")) is False
