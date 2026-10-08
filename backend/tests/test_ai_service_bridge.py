import asyncio
from datetime import datetime, timezone
from urllib.parse import urlencode

import httpx
from fastapi.responses import JSONResponse

from app.ai_service_client import call_ai
def test_snapshot_requires_private_service_token(client, master, monkeypatch):
    monkeypatch.setenv("AI_SERVICE_TOKEN", "test-ai-token")
    assert client.get("/api/ai-service/snapshot").status_code == 401
    assert client.get("/api/ai-service/snapshot", headers=master).status_code == 401
    response = client.get("/api/ai-service/snapshot",
                          headers={"Authorization": "Bearer test-ai-token"})
    assert response.status_code == 200
    snapshot = response.json()
    assert snapshot["orders"] and snapshot["employees"]
    assert snapshot["material_norms"] == []
    assert "pin_hash" not in response.text


def test_ai_gateway_preserves_roles_and_manual_acceptance(client, master, worker, monkeypatch):
    calls = []

    async def fake_call(method, path, **kwargs):
        calls.append((method, path, kwargs))
        return JSONResponse({"ok": True}, status_code=202 if method == "POST" else 200)

    monkeypatch.setattr("app.main.call_ai", fake_call)
    now = datetime.now(timezone.utc).isoformat()
    period = "?" + urlencode({"start": now, "end": now})
    assert client.get("/api/ai/analytics" + period, headers=worker).status_code == 403
    assert client.post("/api/ai/assistant", json={"question": "Кто свободен?"}, headers=worker).status_code == 403
    assert client.post("/api/ai/assistant", json={"question": "Кто свободен?"}, headers=master).status_code == 202
    assert calls[-1][1] == "/ai/assistant/ask"

    closed = client.get("/api/orders?status=closed&limit=1", headers=master).json()[0]
    response = client.post(f"/api/ai/orders/{closed['id']}/review", headers=master)
    assert response.status_code == 202
    assert calls[-1][1] == f"/ai/reviews/{closed['id']}"
    current = client.get(f"/api/orders/{closed['id']}", headers=master).json()
    assert current["status"] == "closed" and "ai_review" not in current
    assert client.post(f"/api/ai/orders/{closed['id']}/review", headers=worker).status_code == 403


def test_ai_gateway_reports_missing_configuration(client, master, monkeypatch):
    monkeypatch.delenv("AI_SERVICE_TOKEN", raising=False)
    response = client.get("/api/ai/source", headers=master)
    assert response.status_code == 503


def test_ai_client_omits_optional_none_query_and_keeps_token_private(monkeypatch):
    monkeypatch.setenv("AI_SERVICE_TOKEN", "private-token")
    original_client = httpx.AsyncClient

    def handler(request):
        assert request.url.path == "/ai/analytics"
        assert "area_id" not in request.url.params
        assert request.headers["Authorization"] == "Bearer private-token"
        return httpx.Response(200, json={"findings": []})

    monkeypatch.setattr("app.ai_service_client.httpx.AsyncClient",
                        lambda **kwargs: original_client(transport=httpx.MockTransport(handler), **kwargs))
    response = asyncio.run(call_ai("GET", "/ai/analytics", params={"area_id": None}))
    assert response.status_code == 200
