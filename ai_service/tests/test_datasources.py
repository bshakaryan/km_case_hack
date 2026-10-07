import asyncio
import json
from datetime import datetime, timezone

import httpx
import pytest

from app.backend_source import BackendDataSource
from app.datasource import DataSourceError, IncompleteHistory
from app.schemas import PhotoRecord
from app.synthetic_source import SyntheticDataSource


NOW = datetime(2026, 10, 7, 10, 0, tzinfo=timezone.utc).isoformat()


def snapshot_payload():
    return {
        "areas": [{"id": 1, "name": "Дробление"}],
        "brigades": [],
        "employees": [
            {"id": 1, "name": "Мастер", "role": "master"},
            {"id": 2, "name": "Работник", "role": "worker"},
        ],
        "equipment": [{"id": 1, "name": "Насос", "inventory_number": "N-1", "area_id": 1}],
        "fault_codes": [{"id": 1, "code": "F01", "name": "Утечка"}],
        "materials": [],
        "time_norms": [],
        "orders": [{
            "id": 7,
            "number": "Н-7",
            "title": "Проверить насос",
            "work_type": "unplanned",
            "area_id": 1,
            "equipment_id": 1,
            "assignee_id": 2,
            "master_id": 1,
            "priority": "normal",
            "status": "issued",
            "deadline": NOW,
            "created_at": NOW,
            "events": [],
            "photos": [{"id": 4, "kind": "before", "path": "photos/before.jpg", "created_at": NOW}],
        }],
    }


def test_synthetic_source_reads_snapshot_and_confines_photos(tmp_path):
    path = tmp_path / "snapshot.json"
    path.write_text(json.dumps(snapshot_payload()), encoding="utf-8")
    photos = tmp_path / "photos"
    photos.mkdir()
    (photos / "before.jpg").write_bytes(b"photo")
    source = SyntheticDataSource(path)
    snapshot = asyncio.run(source.snapshot())
    assert snapshot.orders[0].number == "Н-7"
    assert asyncio.run(source.photo_bytes(snapshot.orders[0].photos[0])) == b"photo"
    with pytest.raises(DataSourceError, match="выходит"):
        asyncio.run(source.photo_bytes(PhotoRecord(id=5, kind="after", path="../secret.txt")))


def test_backend_source_uses_get_only_and_rejects_incomplete_history():
    payload = snapshot_payload()
    calls = []

    def handler(request: httpx.Request):
        calls.append((request.method, request.url.path))
        assert request.headers["Authorization"] == "Bearer test-token"
        if request.url.path == "/api/reference":
            return httpx.Response(200, json={key: value for key, value in payload.items() if key != "orders"})
        if request.url.path == "/api/orders":
            return httpx.Response(200, json=[{"id": 7}])
        if request.url.path == "/api/orders/7":
            return httpx.Response(200, json=payload["orders"][0])
        if request.url.path == "/api/photos/4":
            return httpx.Response(200, content=b"protected")
        return httpx.Response(404)

    source = BackendDataSource("http://backend:8000", "test-token", httpx.MockTransport(handler))
    snapshot = asyncio.run(source.snapshot())
    assert snapshot.orders[0].id == 7
    assert asyncio.run(source.photo_bytes(PhotoRecord(id=4, kind="before", url="/api/photos/4"))) == b"protected"
    assert {method for method, _ in calls} == {"GET"}
    with pytest.raises(DataSourceError, match="Недопустимая"):
        asyncio.run(source.photo_bytes(PhotoRecord(id=4, kind="before", url="https://example.com/photo")))

    def limited(request: httpx.Request):
        if request.url.path == "/api/reference":
            return httpx.Response(200, json={key: value for key, value in payload.items() if key != "orders"})
        return httpx.Response(200, json=[{"id": 7}] * 5000)

    limited_source = BackendDataSource("http://backend:8000", "test-token", httpx.MockTransport(limited))
    with pytest.raises(IncompleteHistory, match="5000"):
        asyncio.run(limited_source.snapshot())


def test_backend_source_requires_token():
    with pytest.raises(DataSourceError, match="BACKEND_TOKEN"):
        asyncio.run(BackendDataSource("http://backend:8000", "").snapshot())

