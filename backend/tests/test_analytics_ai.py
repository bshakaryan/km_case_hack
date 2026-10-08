import json

import httpx

from app import analytics_ai
from conftest import auth_headers


def report():
    return {
        "summary": {"total": 3, "closed": 2, "on_time_percent": 50, "avg_score": 4},
        "trend": [{"planned": 1, "unplanned": 2}],
        "by_area": [{"name": "Участок 1", "count": 3}],
        "equipment": [{"name": "Конвейер", "orders": 2}],
        "ai_summary": "Демонстрационная аналитика",
        "is_stub": True,
    }


def test_analytics_narrative_uses_only_aggregate_facts_and_cache(monkeypatch):
    calls = []

    def fake_post(url, headers, json, timeout):
        calls.append((url, headers, json, timeout))
        return httpx.Response(
            200,
            json={"choices": [{"finish_reason": "stop", "message": {"content":
                '{"summary":"Три наряда за выбранный период, два закрыты. Проверьте причины внеплановых работ."}'}}]},
            request=httpx.Request("POST", url),
        )

    monkeypatch.setenv("OPENAI_API_KEY", "test-only")
    monkeypatch.setattr(analytics_ai.httpx, "post", fake_post)
    analytics_ai.request_narrative.cache_clear()
    first = analytics_ai.add_narrative(report())
    second = analytics_ai.add_narrative(report())
    assert not first["ai_summary_is_stub"] and first["is_stub"]
    assert second["ai_summary"] == first["ai_summary"]
    assert len(calls) == 1
    url, headers, body, timeout = calls[0]
    assert url.endswith("/chat/completions") and headers["Authorization"] == "Bearer test-only"
    assert body["store"] is False and body["response_format"]["json_schema"]["strict"] is True
    facts = json.loads(body["messages"][1]["content"])
    assert facts["orders"] == 3 and facts["unplanned"] == 2
    assert "rankings" not in facts and "downtime_hours" not in facts
    analytics_ai.request_narrative.cache_clear()


def test_analytics_narrative_failure_remains_marked_unavailable(monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-only")

    def fail(*args, **kwargs):
        raise httpx.ConnectError("test failure")

    monkeypatch.setattr(analytics_ai.httpx, "post", fail)
    analytics_ai.request_narrative.cache_clear()
    result = analytics_ai.add_narrative(report())
    assert result["ai_summary_is_stub"] is True
    assert "недоступен" in result["ai_summary"]
    assert result["is_stub"] is True


def test_analytics_http_keeps_worker_personal_without_provider(client, master, monkeypatch):
    monkeypatch.setenv("OPENAI_API_KEY", "test-only")
    calls = []

    def fake_request(facts, key):
        calls.append(json.loads(facts))
        return "За выбранный период часть нарядов закрыта. Проверьте внеплановые работы."

    monkeypatch.setattr(analytics_ai, "request_narrative", fake_request)
    response = client.get("/api/analytics?area_id=4", headers=master)
    assert response.status_code == 200
    assert response.json()["ai_summary_is_stub"] is False
    assert response.json()["is_stub"] is True
    assert calls and calls[0]["orders"] == response.json()["summary"]["total"]

    worker = auth_headers(client, "worker2")
    worker_response = client.get("/api/analytics", headers=worker)
    assert worker_response.status_code == 200
    assert worker_response.json()["is_stub"] is True
    assert len(calls) == 1
