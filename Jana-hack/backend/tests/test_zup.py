"""Wire contract, calendar edges, accounting reconciliation, and durable retries."""
from datetime import date
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier
import sqlite3

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from sqlalchemy import select


@pytest.mark.parametrize("start,end,days,excluded", [
    ("2027-03-01", "2027-03-05", 5, []),
    ("2026-10-24", "2026-10-26", 2, ["2026-10-25"]),
    ("2027-03-20", "2027-03-25", 3, ["2027-03-21", "2027-03-22", "2027-03-23"]),
    ("2027-12-31", "2028-01-03", 2, ["2028-01-01", "2028-01-02"]),
    ("2028-02-28", "2028-02-29", 2, []),
    ("2026-01-07", "2026-01-07", 1, []),
    ("2026-05-27", "2026-05-27", 1, []),
    ("2027-03-06", "2027-03-07", 2, []),
])
def test_quote_from_http_counts_calendar_days_excluding_only_statutory_holidays(api, start, end, days, excluded):
    response = api.post("/api/requests/calculate", {"start_date": start, "end_date": end})
    assert response.status_code == 200, response.text
    quote = response.json()
    assert quote["days_count"] == days
    assert quote["excluded_dates"] == excluded
    assert quote["calendar_days"] == (date.fromisoformat(end) - date.fromisoformat(start)).days + 1
    assert quote["balance_after"] == quote["available_balance"] - days
    assert quote["source"] == "mock_zup_http"


@pytest.mark.parametrize("start,end", [("2027-01-01", "2027-01-02"), ("2025-12-31", "2026-01-03"), ("2027-03-05", "2027-03-01")])
def test_unavailable_calendar_or_zero_days_cannot_be_submitted(api, start, end):
    api.headers()
    before = api.db.snapshot()
    assert api.post("/api/requests/calculate", {"start_date": start, "end_date": end}).status_code == 422
    assert api.create(start_date=start, end_date=end).status_code == 422
    assert api.db.snapshot() == before


def test_holiday_calculation_is_saved_and_used_by_approval_and_remote_document(api):
    initial = api.get("/api/me").json()["leave_balance"]
    item = api.leave(start_date="2027-03-20", end_date="2027-03-25")
    assert item["days_count"] == 3
    assert item["excluded_dates"] == ["2027-03-21", "2027-03-22", "2027-03-23"]
    item = api.decide(item).json()
    approved = api.decide(item, "hr").json()
    assert approved["status"] == "approved"
    assert approved["zup_sync_status"] == "synced"
    assert approved["zup_reference"].startswith("ZUP-")
    assert api.get("/api/me").json()["leave_balance"] == initial - 3
    assert api.get("/api/employees/1", "manager").json()["leave_balance"] == initial - 3
    assert api.get("/api/employees", "hr").json()[0]["leave_balance"] == initial - 3
    remote = api.db.adapter.call("GET", "/leave/documents")
    assert len(remote) == 1 and remote[0]["days"] == 3


def test_lost_receipt_reconciles_balance_and_retry_is_exactly_once(api, monkeypatch):
    from app.models import ZupDelivery

    item = api.decide(api.leave()).json()
    register = api.db.adapter.register

    def lose_receipt(body, key):
        register(body, key)
        raise HTTPException(503, "simulated lost response after commit")

    with monkeypatch.context() as patch:
        patch.setattr(api.db.adapter, "register", lose_receipt)
        approved = api.decide(item, "hr").json()
    assert approved["status"] == "approved"
    assert approved["zup_sync_status"] == "error"
    assert api.get("/api/me").json()["leave_balance"] == 13
    api.db.seed()
    assert api.get("/api/me").json()["leave_balance"] == 13
    for _ in range(2):
        synced = api.post(f"/api/requests/{item['id']}/sync", {}, "hr")
        assert synced.status_code == 200
        assert synced.json()["zup_sync_status"] == "synced"
    with api.db.session() as db:
        delivery = db.scalar(select(ZupDelivery).where(ZupDelivery.request_id == item["id"]))
        assert delivery.attempts == 2
        assert delivery.last_error is None
    assert len(api.db.adapter.call("GET", "/leave/documents")) == 1
    assert api.get("/api/me").json()["leave_balance"] == 13
    audit = api.get("/api/audit", "hr").json()
    assert len([event for event in audit if event["action"] == "zup.leave_registered"]) == 1


def test_outbox_survives_source_write_failure_and_worker_delivers_saved_body(api, monkeypatch):
    from app.models import ZupDelivery, utcnow
    from app.zup_worker import run_once

    item = api.decide(api.leave()).json()
    with monkeypatch.context() as patch:
        patch.setattr(api.db.adapter, "register", lambda *_: (_ for _ in ()).throw(HTTPException(503, "offline")))
        approved = api.decide(item, "hr").json()
    assert approved["zup_sync_status"] == "error"
    assert api.get("/api/me").json()["leave_balance"] == 13
    with api.db.session() as db:
        delivery = db.scalar(select(ZupDelivery).where(ZupDelivery.request_id == item["id"]))
        body_before, key_before = delivery.payload_json, delivery.command_key
        delivery.next_attempt_at = utcnow()
        db.commit()
    run_once()
    run_once()
    assert api.get(f"/api/requests/{item['id']}").json()["zup_sync_status"] == "synced"
    with api.db.session() as db:
        delivery = db.scalar(select(ZupDelivery).where(ZupDelivery.request_id == item["id"]))
        assert (delivery.payload_json, delivery.command_key) == (body_before, key_before)
    assert api.get("/api/me").json()["leave_balance"] == 13


def test_source_outage_fails_closed_without_changing_request(api, monkeypatch):
    item = api.decide(api.leave()).json()
    api.headers("hr")
    before = api.db.snapshot()
    with monkeypatch.context() as patch:
        patch.setattr(api.db.adapter, "call", lambda *_: (_ for _ in ()).throw(HTTPException(503, "offline")))
        assert api.get("/api/me").status_code == 503
        assert api.post("/api/requests/calculate", {"start_date": "2027-02-01", "end_date": "2027-02-05"}).status_code == 503
        assert api.create(key="source-offline", start_date="2027-02-01", end_date="2027-02-05").status_code == 503
        assert api.decide(item, "hr").status_code == 503
    assert api.db.snapshot() == before


def test_calendar_change_requires_new_request(api, monkeypatch):
    item = api.decide(api.leave()).json()
    api.headers("hr")
    before = api.db.snapshot()
    calculate = api.db.adapter.calculate
    with monkeypatch.context() as patch:
        patch.setattr(api.db.adapter, "calculate", lambda *args: calculate(*args).model_copy(update={"calendar_version": "new-version"}))
        response = api.decide(item, "hr")
    assert response.status_code == 409
    assert "Календарь" in response.json()["detail"]
    assert api.db.snapshot() == before


def test_overlapping_requests_rejected_but_rejected_period_can_be_reused(api):
    item = api.leave()
    response = api.create(key="overlapping-request", start_date=item["end_date"], end_date="2027-01-16")
    assert response.status_code == 409
    assert "пересекается" in response.json()["detail"]
    assert api.decide(item, status="rejected").status_code == 200
    assert api.create(key="after-rejection").status_code == 201


def test_concurrent_final_approvals_cannot_overspend_one_employee_balance(api):
    with sqlite3.connect(api.db.zup_path) as db:
        db.execute("UPDATE balances SET initial_days=6 WHERE employee_id='demo-1'")
    first = api.decide(api.leave(key="parallel-final-one")).json()
    second = api.decide(api.leave(key="parallel-final-two", start_date="2027-02-01", end_date="2027-02-05")).json()
    api.headers("hr")
    barrier = Barrier(2)

    def approve(item):
        barrier.wait(timeout=10)
        return api.decide(item, "hr")

    with ThreadPoolExecutor(max_workers=2) as pool:
        futures = [pool.submit(approve, item) for item in (first, second)]
        responses = [future.result(timeout=20) for future in futures]
    assert sorted(response.status_code for response in responses) == [200, 409], [response.text for response in responses]
    assert api.get("/api/me").json()["leave_balance"] == 1
    snapshot = api.db.snapshot()
    assert len(snapshot["leave_deductions"]) == len(snapshot["zup_deliveries"]) == 1
    assert len(api.db.adapter.call("GET", "/leave/documents")) == 1


@pytest.mark.parametrize("actor", ["employee", "manager", "outsider"])
def test_only_hr_can_inspect_integration_or_retry_delivery(api, actor):
    item = api.leave()
    assert api.get("/api/integrations/zup", actor).status_code == 403
    assert api.post(f"/api/requests/{item['id']}/sync", {}, actor).status_code == 403


def test_hr_connection_reports_real_http_and_queue_counts(api):
    status = api.get("/api/integrations/zup", "hr")
    assert status.status_code == 200
    assert status.json() == {"connected": True, "mode": "mock_http", "contract": "jana-zup-v1",
                             "auth_type": "bearer", "tls_verified": False,
                             "mapped_employees": 4, "pending": 0, "error": 0, "synced": 0}


def test_mock_requires_service_auth_and_rejects_changed_command_replay(api):
    path = "/hs/jana/v1/leave/documents"
    assert api.db.zup.get("/hs/jana/v1/employees").status_code == 401
    body = {"employee_id": "demo-1", "start_date": "2027-04-01", "end_date": "2027-04-02", "days_count": 2, "calendar_version": "kz-statutory-2026-v1"}
    headers = {"Authorization": f"Bearer {api.db.secret}", "Idempotency-Key": "mock-command-test"}
    created = api.db.zup.post(path, json=body, headers=headers)
    assert created.status_code == 201
    assert api.db.zup.post(path, json=body, headers=headers).json() == created.json()
    assert api.db.zup.post(path, json=body | {"days_count": 1}, headers=headers).status_code == 409
    assert api.db.adapter.balance("demo-1").balance == 16


def test_mock_restart_preserves_documents_and_balance(api):
    from app.mock_zup import create_mock_app

    item = api.decide(api.leave()).json()
    assert api.decide(item, "hr").status_code == 200
    with TestClient(create_mock_app(str(api.db.zup_path), api.db.secret)) as restarted:
        response = restarted.get("/hs/jana/v1/employees/demo-1/leave-balance", headers={"Authorization": f"Bearer {api.db.secret}"})
        assert response.json()["balance"] == 13
        assert len(response.json()["applied_commands"]) == 1


def test_source_overlap_created_outside_application_blocks_quote_and_create(api):
    body = {"employee_id": "demo-1", "start_date": "2027-04-01", "end_date": "2027-04-02", "days_count": 2, "calendar_version": "kz-statutory-2026-v1"}
    api.db.adapter.register(body, "external-source-command")
    response = api.post("/api/requests/calculate", {"start_date": "2027-04-01", "end_date": "2027-04-02"})
    assert response.status_code == 409
    assert api.create(start_date="2027-04-01", end_date="2027-04-02").status_code == 409


def test_adapter_timeout_and_inconsistent_response_are_safe(api):
    from app.modules.integrations import HttpZupAdapter

    def timeout(_):
        raise httpx.ReadTimeout("offline")

    adapter = HttpZupAdapter("http://mock/hs/jana/v1", api.db.secret, httpx.MockTransport(timeout))
    with pytest.raises(HTTPException) as error:
        adapter.balance("demo-1")
    assert error.value.status_code == 503
    payload = {"employee_id": "demo-1", "balance": 18, "applied_commands": [], "days_count": 99, "calendar_days": 2, "excluded_dates": [], "calendar_version": "bad"}
    adapter = HttpZupAdapter("http://mock/hs/jana/v1", api.db.secret, httpx.MockTransport(lambda _: httpx.Response(200, json=payload)))
    with pytest.raises(HTTPException) as error:
        adapter.calculate("demo-1", date(2027, 4, 1), date(2027, 4, 2))
    assert error.value.status_code == 503


def test_real_adapter_supports_basic_auth_and_marks_real_source(api):
    from app.modules.integrations import HttpZupAdapter

    def handler(request):
        assert request.headers["Authorization"].startswith("Basic ")
        if request.url.path.endswith("leave-balance"):
            return httpx.Response(200, json={"employee_id": "real-guid", "balance": 20,
                                             "applied_commands": [], "source": "zup_http"})
        return httpx.Response(200, json={"employee_id": "real-guid", "balance": 20,
                                         "applied_commands": [], "source": "zup_http",
                                         "days_count": 2, "calendar_days": 2,
                                         "excluded_dates": [], "calendar_version": "zup-production-v1"})

    adapter = HttpZupAdapter("https://zup.example/hs/jana/v1", mode="real", auth_type="basic",
                             username="service", password="secret", transport=httpx.MockTransport(handler))
    assert adapter.balance("real-guid").source == "zup_http"
    assert adapter.calculate("real-guid", date(2027, 4, 1), date(2027, 4, 2)).source == "zup_http"


def test_real_settings_require_https_unless_explicitly_allowed(api):
    from app.config import Settings

    with pytest.raises(ValueError, match="HTTPS"):
        Settings(_env_file=None, jwt_secret=api.db.secret, zup_mode="real",
                 zup_base_url="http://zup.example/hs/jana/v1")
    settings = Settings(_env_file=None, jwt_secret=api.db.secret, zup_mode="real",
                        zup_base_url="http://zup.test/hs/jana/v1", zup_allow_insecure_http=True)
    assert settings.zup_mode == "real"
