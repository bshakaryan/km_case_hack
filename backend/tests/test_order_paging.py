"""Complete keyset history, literal Unicode search and live authorization."""
from datetime import datetime, timedelta, timezone

import pytest
import sqlalchemy as sa

from app.models import Area, AuthSession, Employee, Equipment, Order, utcnow
from app.security import token_hash
from test_brigade_assignments import body, brigade_client as brigade_fixture, create, headers


@pytest.fixture(params=["sqlite", "postgresql"])
def paging_client(request, tmp_path, monkeypatch):
    yield from brigade_fixture.__wrapped__(request, tmp_path, monkeypatch)


def bulk_orders(client, count, *, old=False, specs=None):
    created = datetime(2021, 1, 1, tzinfo=timezone.utc) if old else utcnow() - timedelta(days=1)
    rows = []
    for index in range(count):
        rows.append({"number": f"SYN-PAGE-{index}", "title": "Synthetic paging work",
            "description": "Synthetic full history", "work_type": "planned", "area_id": 1,
            "equipment_id": 3, "assignee_id": 6, "brigade_id": None, "master_id": 1,
            "priority": "normal", "status": "cancelled" if index % 3 == 0 else "closed",
            "created_at": created, "assigned_at": created, "deadline": utcnow() + timedelta(hours=2),
            "normal_hours": 2, "downtime_minutes": 0, "comment": "Synthetic pagination fixture",
            **(specs[index] if specs else {})})
    with client.app.state.sessions() as db:
        db.execute(sa.insert(Order), rows)
        db.commit()
        return list(db.scalars(sa.select(Order.id).order_by(Order.id)))


def page(client, employee_id=1, **params):
    response = client.get("/api/orders/page", params=params, headers=headers(employee_id))
    assert response.status_code == 200, response.text
    result = response.json()
    assert set(result) == {"items", "next_cursor", "total"}
    return result


def exhaust(client, **params):
    found, cursor, totals = [], None, []
    while True:
        result = page(client, **params, **({"cursor": cursor} if cursor else {}))
        found.extend(result["items"])
        totals.append(result["total"])
        cursor = result["next_cursor"]
        if cursor is None:
            return found, totals
        assert len(totals) < 100, "Cursor did not finish"


def test_more_than_5000_old_tied_closed_and_cancelled_rows_are_complete(paging_client):
    client = paging_client
    ids = bulk_orders(client, 5005, old=True)
    legacy = client.get("/api/orders", params={"limit": 5000}, headers=headers(1))
    assert legacy.status_code == 200 and isinstance(legacy.json(), list)
    assert len(legacy.json()) == 5000
    assert len(page(client)["items"]) == 100
    rows, totals = exhaust(client, equipment_id=3, scope="all", limit=200)
    assert [row["id"] for row in rows] == ids[::-1]
    assert len({row["id"] for row in rows}) == 5005
    assert set(totals) == {5005}
    assert {row["status"] for row in rows} == {"closed", "cancelled"}
    assert all(row["created_at"].startswith("2021-01-01") for row in rows)
    assert all(row["participants_source"] == "legacy_snapshot" for row in rows)


def test_insert_and_delete_do_not_shift_the_existing_cursor_window(paging_client):
    client = paging_client
    ids = bulk_orders(client, 8)
    first = page(client, limit=2)
    assert [row["id"] for row in first["items"]] == ids[-2:][::-1]
    inserted = create(client, assignee_id=6)
    removed = ids[-3]
    with client.app.state.sessions() as db:
        db.execute(sa.delete(Order).where(Order.id == removed))
        db.commit()
    cursor, found = first["next_cursor"], [row["id"] for row in first["items"]]
    while cursor:
        result = page(client, limit=2, cursor=cursor)
        assert result["total"] == 7
        found.extend(row["id"] for row in result["items"])
        cursor = result["next_cursor"]
    assert found == [id_ for id_ in ids[::-1] if id_ != removed]
    assert inserted["id"] not in found
    refreshed = page(client, limit=2)
    assert refreshed["items"][0]["id"] == inserted["id"] and refreshed["total"] == 8


def test_deadline_and_priority_keysets_include_ties_exactly_once(paging_client):
    client = paging_client
    deadline = utcnow() + timedelta(hours=2)
    specs = [{"priority": priority, "deadline": deadline + timedelta(minutes=minutes)}
        for priority, minutes in [("normal", 5), ("emergency", 10), ("high", 5),
            ("emergency", 5), ("planned", 0), ("emergency", 5)]]
    ids = bulk_orders(client, len(specs), specs=specs)
    deadline_rows, _ = exhaust(client, sort="deadline", limit=2)
    expected = sorted(zip(ids, specs), key=lambda item: (item[1]["deadline"], item[0]))
    assert [row["id"] for row in deadline_rows] == [id_ for id_, _ in expected]
    priority_rows, _ = exhaust(client, sort="priority", limit=2)
    ranks = {"emergency": 0, "high": 1, "normal": 2, "planned": 3}
    expected = sorted(zip(ids, specs), key=lambda item: (ranks[item[1]["priority"]], item[1]["deadline"], item[0]))
    assert [row["id"] for row in priority_rows] == [id_ for id_, _ in expected]


def test_scopes_focus_dates_and_effective_legacy_queue_filters(paging_client):
    client = paging_client
    future, past = utcnow() + timedelta(hours=2), utcnow() - timedelta(hours=2)
    specs = [
        {"status": "accepted", "priority": "emergency", "deadline": future},
        {"status": "accepted", "priority": "normal", "deadline": future},
        {"status": "queued", "priority": "planned", "deadline": future},
        {"status": "closed", "priority": "high", "deadline": past},
        {"status": "cancelled", "assignee_id": 5, "deadline": past},
        {"status": "issued", "priority": "emergency", "deadline": past}]
    ids = bulk_orders(client, len(specs), specs=specs)
    assert page(client, scope="active")["total"] == 4
    assert page(client, scope="closed")["total"] == 2
    queued = page(client, status="queued")
    assert {row["id"] for row in queued["items"]} == {ids[1], ids[2]}
    assert all(row["status"] == "queued" for row in queued["items"])
    assert [row["id"] for row in page(client, status="accepted")["items"]] == [ids[0]]
    assert [row["id"] for row in page(client, focus="overdue")["items"]] == [ids[5]]
    assert page(client, focus="emergency")["total"] == 2
    assert page(client, scope="closed", focus="overdue")["total"] == 0
    assert page(client, focus="issued", assignee_id=6, equipment_id=3, area_id=1)["total"] == 1
    assert page(client, focus="issued", assignee_id=5)["total"] == 0
    assert page(client, from_date=utcnow().isoformat())["total"] == 0
    assert page(client, to_date=(utcnow() - timedelta(days=2)).date().isoformat())["total"] == 0
    assert client.get("/api/orders/page", params={"from_date": "2026-10-08", "to_date": "2026-10-07"}, headers=headers(1)).status_code == 422


def test_unicode_literal_search_matches_metadata_and_current_frozen_participants(paging_client):
    client = paging_client
    with client.app.state.sessions() as db:
        db.get(Area, 1).name = "ЦЕХ №1"
        db.get(Equipment, 3).name = "НАСОС%_\\ТЕСТ"
        db.get(Employee, 5).name = "УЧАСТНИК_%\\СНИМОК"
        db.get(Employee, 6).name = "Ответственный"
        db.add(Area(id=2, name="Other area"))
        db.flush()
        db.add(Equipment(id=4, name="НасосXXТест", inventory_number="SYN-4", area_id=2, type="pump", criticality="medium"))
        db.commit()
    payload = body(brigade_id=1, responsible_id=6)
    payload.update(title="Смена клапана", description="Выполнить РЕМОНТНУЮ операцию")
    response = client.post("/api/orders", json=payload, headers=headers(1))
    assert response.status_code == 201, response.text
    order = response.json()
    other = body(assignee_id=6)
    other.update(area_id=2, equipment_id=4)
    assert client.post("/api/orders", json=other, headers=headers(1)).status_code == 201
    assert client.patch("/api/reference/employees/5", json={"name": "Новое имя"}, headers=headers(2)).status_code == 200
    for search in ["  насос%_\\тест  ", "цех №1", "УЧАСТНИК_%\\снимок", "КЛАПАНА", "ремонтную", "%", "_", "\\"]:
        assert [row["id"] for row in page(client, search=search)["items"]] == [order["id"]]
    assert page(client, search="оТВЕТственНЫЙ")["total"] == 2
    assert page(client, search=order["number"].lower())["total"] == 1
    # No accidental broadening of the legacy array endpoint's search contract.
    assert client.get("/api/orders", params={"search": "насос"}, headers=headers(1)).json() == []
    assert client.patch(f"/api/orders/{order['id']}", json={"assignee_id": 6}, headers=headers(1)).status_code == 200
    assert page(client, search="участник_%\\снимок")["total"] == 0


def test_cursor_validation_normalization_session_user_role_and_filter_binding(paging_client):
    client = paging_client
    bulk_orders(client, 4)
    result = page(client, limit=1, search=" SYNTHETIC ")
    cursor = result["next_cursor"]
    assert page(client, limit=2, search="synthetic", cursor=cursor)["total"] == 4
    for params in [{"cursor": "garbage"}, {"cursor": "x.y"}, {"cursor": cursor + "x"},
        {"cursor": cursor, "search": "different"}, {"cursor": cursor, "search": "synthetic", "sort": "deadline"},
        {"cursor": cursor, "search": "synthetic", "equipment_id": 3}, {"limit": 0}, {"limit": 201},
        {"scope": "unknown"}, {"focus": "unknown"}, {"sort": "unknown"}, {"status": "unknown"},
        {"priority": "unknown"}, {"cursor": "x" * 4097}]:
        assert client.get("/api/orders/page", params=params, headers=headers(1)).status_code == 422, params
    assert client.get("/api/orders/page", params={"cursor": cursor, "search": "synthetic"}, headers=headers(2)).status_code == 422
    assert client.get("/api/orders/page", params={"cursor": "bad"}).status_code == 401
    with client.app.state.sessions() as db:
        db.add(AuthSession(token_hash=token_hash("synthetic-new-master-session"), employee_id=1, expires_at=utcnow() + timedelta(hours=1)))
        db.commit()
    assert client.get("/api/orders/page", params={"cursor": cursor, "search": "synthetic"},
        headers={"Authorization": "Bearer synthetic-new-master-session"}).status_code == 422
    with client.app.state.sessions() as db:
        db.get(Employee, 1).role = "manager"
        db.commit()
    assert client.get("/api/orders/page", params={"cursor": cursor, "search": "synthetic"}, headers=headers(1)).status_code == 422
    with client.app.state.sessions() as db:
        session = db.scalar(sa.select(AuthSession).where(AuthSession.employee_id == 1, AuthSession.token_hash == token_hash("synthetic-brigade-1")))
        session.expires_at = utcnow() - timedelta(seconds=1)
        db.commit()
    assert client.get("/api/orders/page", params={"cursor": cursor, "search": "synthetic"}, headers=headers(1)).status_code == 401


def test_participant_access_is_rechecked_between_pages(paging_client):
    client = paging_client
    orders = [create(client, brigade_id=1, responsible_id=6) for _ in range(3)]
    first = page(client, employee_id=5, limit=1)
    assert first["total"] == 3 and first["items"][0]["id"] == orders[-1]["id"]
    removed = orders[1]["id"]
    assert client.patch(f"/api/orders/{removed}", json={"assignee_id": 9}, headers=headers(1)).status_code == 200
    remaining = page(client, employee_id=5, limit=1, cursor=first["next_cursor"])
    assert remaining["total"] == 2 and [row["id"] for row in remaining["items"]] == [orders[0]["id"]]
    assert remaining["next_cursor"] is None
    assert client.get(f"/api/orders/{removed}", headers=headers(5)).status_code == 403


def test_equipment_metadata_is_staff_only_and_missing_equipment_is_404(paging_client):
    client = paging_client
    for employee_id in [1, 2, 8]:
        response = client.get("/api/equipment/3", headers=headers(employee_id))
        assert response.status_code == 200, response.text
        assert response.json() == {"id": 3, "name": "Pump", "inventory_number": "SYN-3", "area_id": 1,
            "area_name": "Synthetic area", "type": "pump", "criticality": "medium"}
    assert client.get("/api/equipment/999", headers=headers(1)).status_code == 404
    assert client.get("/api/equipment/3", headers=headers(5)).status_code == 403
    assert client.get("/api/equipment/999", headers=headers(5)).status_code == 403
    assert client.get("/api/equipment/3").status_code == 401
