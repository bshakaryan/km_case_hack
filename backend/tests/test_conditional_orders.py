"""Fresh authorized validators over complete operative representations."""

from datetime import timedelta

from fastapi import HTTPException
import pytest
import sqlalchemy as sa

import app.main as main_module
import app.services as services
from app.models import AuthSession, Employee, Order, utcnow
from app.security import token_hash
from test_brigade_assignments import act, brigade_client as brigade_fixture, create, headers


@pytest.fixture(params=["sqlite", "postgresql"])
def conditional_client(request, tmp_path, monkeypatch):
    monkeypatch.setenv("CORS_ORIGINS", "http://localhost:5173")
    yield from brigade_fixture.__wrapped__(request, tmp_path, monkeypatch)


def orders(client, employee_id=1, etag=None, **params):
    return client.get("/api/orders", params=params,
        headers=headers(employee_id, **({"If-None-Match": etag} if etag is not None else {})))


def assert_validator_headers(response):
    etag = response.headers["etag"]
    assert etag.startswith('"') and etag.endswith('"') and not etag.startswith("W/")
    assert etag.isascii()
    assert response.headers["cache-control"] == "private, no-cache"
    assert "authorization" in response.headers["vary"].lower()
    return etag


def test_unchanged_304_and_unconditional_200_keep_the_original_array(conditional_client):
    client = conditional_client
    created = create(client, assignee_id=6)
    first = orders(client, limit=5000)
    assert first.status_code == 200 and isinstance(first.json(), list)
    assert first.json()[0]["id"] == created["id"]
    etag = assert_validator_headers(first)
    repeated = orders(client, etag=etag, limit=5000)
    assert repeated.status_code == 304 and repeated.content == b""
    assert assert_validator_headers(repeated) == etag
    assert "content-length" not in repeated.headers
    unconditional = orders(client, limit=5000)
    assert unconditional.status_code == 200 and unconditional.content == first.content
    assert unconditional.headers["etag"] == etag
    changed = client.patch(f"/api/orders/{created['id']}", headers=headers(1),
                           json={"description": "Changed report context"})
    assert changed.status_code == 200
    refreshed = orders(client, etag=etag, limit=5000)
    assert refreshed.status_code == 200 and refreshed.headers["etag"] != etag
    assert refreshed.json()[0]["description"] == "Changed report context"


def test_if_none_match_reads_lists_weak_tags_and_wildcard_with_bounded_invalid_fallback(conditional_client):
    client = conditional_client
    create(client, assignee_id=6)
    first = orders(client)
    etag = first.headers["etag"]
    for condition in [etag, f"W/{etag}", f'"opaque,comma", W/{etag}, "other"',
                      f" , , {etag} , , ", "\t* \t"]:
        response = orders(client, etag=condition)
        assert response.status_code == 304 and response.content == b""
        assert response.headers["etag"] == etag
    # Repeated field lines are one logical list, not just the first field.
    repeated_fields = client.get("/api/orders", headers=[
        ("Authorization", headers(1)["Authorization"]),
        ("If-None-Match", '"other"'), ("If-None-Match", f"W/{etag}"),
    ])
    assert repeated_fields.status_code == 304
    for invalid in ["not-quoted", f"w/{etag}", f"W/ {etag}", f"{etag}, garbage",
                    f"{etag}, *", f'{etag}, "unterminated', f'{etag}, "bad space"',
                    f'{etag}, "bad\tcontrol"', f'"prefix-{etag[1:-1]}-suffix"',
                    f'{etag}, "' + "x" * 4096 + '"', "," * 33 + etag]:
        response = orders(client, etag=invalid)
        assert response.status_code == 200, invalid[:80]
        assert response.content == first.content
        assert response.headers["etag"] == etag


def test_clock_computed_overdue_invalidates_without_changing_order_version(conditional_client, monkeypatch):
    client = conditional_client
    now = utcnow()
    created = create(client, assignee_id=6, deadline=(now + timedelta(minutes=10)).isoformat())
    monkeypatch.setattr(services, "utcnow", lambda: now)
    first = orders(client)
    assert first.json()[0]["is_overdue"] is False
    monkeypatch.setattr(services, "utcnow", lambda: now + timedelta(minutes=11))
    advanced = orders(client, etag=first.headers["etag"])
    assert advanced.status_code == 200 and advanced.json()[0]["is_overdue"] is True
    assert advanced.json()[0]["version"] == created["version"]
    assert advanced.headers["etag"] != first.headers["etag"]
    assert orders(client, etag=advanced.headers["etag"]).status_code == 304


def test_queue_position_changes_due_to_an_order_outside_the_query(conditional_client):
    client = conditional_client
    target = create(client, assignee_id=6, title="Conditional queue target")
    queued = act(client, target["id"], "queue")
    first = orders(client, search=target["title"])
    assert first.json()[0]["queue_position"] == 1
    urgent = create(client, assignee_id=6, title="Another urgent queue entry", priority="emergency")
    act(client, urgent["id"], "queue")
    updated = orders(client, etag=first.headers["etag"], search=target["title"])
    assert updated.status_code == 200 and len(updated.json()) == 1
    assert updated.json()[0]["queue_position"] == 2
    assert updated.json()[0]["version"] == queued["version"]
    assert updated.headers["etag"] != first.headers["etag"]


def test_live_reference_name_changes_and_frozen_crew_access_are_fresh(conditional_client):
    client = conditional_client
    created = create(client, brigade_id=1, responsible_id=6)
    first = orders(client, employee_id=5)
    original_participants = first.json()[0]["participants"]
    with client.app.state.sessions() as db:
        person = db.get(Employee, 5)
        person.name, person.brigade_id, person.on_shift = "Changed worker name", 2, False
        db.commit()
    # Directory movement does not revoke the frozen crew or change its names.
    assert orders(client, employee_id=5, etag=first.headers["etag"]).status_code == 304
    with client.app.state.sessions() as db:
        db.get(Employee, 6).name = "Changed responsible name"
        db.commit()
    renamed = orders(client, employee_id=5, etag=first.headers["etag"])
    assert renamed.status_code == 200
    assert renamed.json()[0]["assignee_name"] == "Changed responsible name"
    assert renamed.json()[0]["participants"] == original_participants
    assert renamed.json()[0]["version"] == created["version"]
    reassigned = client.patch(f"/api/orders/{created['id']}", headers=headers(1),
                             json={"brigade_id": 1, "responsible_id": 6})
    assert reassigned.status_code == 200
    revoked = orders(client, employee_id=5, etag=renamed.headers["etag"])
    assert revoked.status_code == 200 and revoked.json() == []
    assert revoked.headers["etag"] != renamed.headers["etag"]
    assert orders(client, employee_id=5, etag=revoked.headers["etag"]).status_code == 304
    denied_detail = client.get(f"/api/orders/{created['id']}",
                              headers=headers(5, **{"If-None-Match": renamed.headers["etag"]}))
    assert denied_detail.status_code == 403 and "etag" not in denied_detail.headers


def test_equal_body_is_scoped_to_full_normalized_query_user_role_and_session(conditional_client):
    client = conditional_client
    create(client, assignee_id=6)
    first = orders(client, limit=5000, equipment_id=3)
    etag = first.headers["etag"]
    equivalent_query = client.get("/api/orders?equipment_id=03&limit=05000",
        headers=headers(1, **{"If-None-Match": etag}))
    assert equivalent_query.status_code == 304
    for params in [{"limit": 4999, "equipment_id": 3},
                   {"limit": 5000, "equipment_id": 3, "priority": "normal"}]:
        other_query = orders(client, etag=etag, **params)
        assert other_query.status_code == 200 and other_query.content == first.content
        assert other_query.headers["etag"] != etag
    other_user = orders(client, employee_id=2, etag=etag, limit=5000, equipment_id=3)
    assert other_user.status_code == 200 and other_user.content == first.content
    assert other_user.headers["etag"] != etag
    rotated_token = "synthetic-conditional-second-session"
    with client.app.state.sessions() as db:
        db.add(AuthSession(token_hash=token_hash(rotated_token), employee_id=1,
                           expires_at=utcnow() + timedelta(hours=1)))
        db.commit()
    new_session = client.get("/api/orders?limit=5000&equipment_id=3",
        headers={"Authorization": f"Bearer {rotated_token}", "If-None-Match": etag})
    assert new_session.status_code == 200 and new_session.content == first.content
    assert new_session.headers["etag"] != etag
    with client.app.state.sessions() as db:
        db.get(Employee, 1).role = "manager"
        db.commit()
    changed_role = orders(client, etag=etag, limit=5000, equipment_id=3)
    assert changed_role.status_code == 200 and changed_role.content == first.content
    assert changed_role.headers["etag"] != etag
    with client.app.state.sessions() as db:
        db.get(Employee, 1).role = "worker"
        db.commit()
    narrowed_role = orders(client, etag=changed_role.headers["etag"], limit=5000, equipment_id=3)
    assert narrowed_role.status_code == 200 and narrowed_role.json() == []
    with client.app.state.sessions() as db:
        db.get(Employee, 1).role = "disabled"
        db.commit()
    denied_role = orders(client, etag="*")
    assert denied_role.status_code == 403 and "etag" not in denied_role.headers


def test_expired_revoked_or_missing_authority_and_bad_filters_never_become_304(conditional_client):
    client = conditional_client
    create(client, assignee_id=6)
    etag = orders(client).headers["etag"]
    for params in [{"status": "unknown"}, {"priority": "unknown"}, {"limit": 5001},
                   {"from_date": "not-a-date"}, {"from_date": "2026-02-02", "to_date": "2026-01-01"}]:
        invalid = orders(client, etag="*", **params)
        assert invalid.status_code == 422 and "etag" not in invalid.headers
    with client.app.state.sessions() as db:
        session = db.scalar(sa.select(AuthSession).where(AuthSession.token_hash == token_hash("synthetic-brigade-1")))
        session.expires_at = utcnow() - timedelta(seconds=1)
        db.commit()
    expired = orders(client, etag=etag)
    assert expired.status_code == 401 and "etag" not in expired.headers
    assert expired.headers["www-authenticate"] == "Bearer"
    with client.app.state.sessions() as db:
        db.execute(sa.delete(AuthSession).where(AuthSession.token_hash == token_hash("synthetic-brigade-1")))
        db.commit()
    revoked = orders(client, etag="*")
    assert revoked.status_code == 401 and "etag" not in revoked.headers
    missing = client.get("/api/orders", headers={"If-None-Match": "*"})
    assert missing.status_code == 401 and "etag" not in missing.headers


def test_read_failure_is_not_hidden_by_a_matching_validator(conditional_client, monkeypatch):
    client = conditional_client
    create(client, assignee_id=6)
    first = orders(client)

    def unavailable(*args, **kwargs):
        raise HTTPException(503, "Synthetic serialization unavailable")

    monkeypatch.setattr(main_module, "order_dict", unavailable)
    failed = orders(client, etag=first.headers["etag"])
    assert failed.status_code == 503 and "etag" not in failed.headers


def test_cors_accepts_condition_and_exposes_validator_on_200_and_304(conditional_client):
    client = conditional_client
    origin = "http://localhost:5173"
    preflight = client.options("/api/orders", headers={"Origin": origin,
        "Access-Control-Request-Method": "GET", "Access-Control-Request-Headers": "authorization,if-none-match"})
    assert preflight.status_code == 200
    assert "if-none-match" in preflight.headers["access-control-allow-headers"].lower()
    first = client.get("/api/orders", headers=headers(1, Origin=origin))
    assert first.status_code == 200 and first.json() == []
    assert "etag" in first.headers["access-control-expose-headers"].lower()
    repeated = client.get("/api/orders", headers=headers(1, Origin=origin,
                          **{"If-None-Match": first.headers["etag"]}))
    assert repeated.status_code == 304 and repeated.content == b""
    assert "etag" in repeated.headers["access-control-expose-headers"].lower()
    assert "origin" in repeated.headers["vary"].lower()
    assert "authorization" in repeated.headers["vary"].lower()
    assert repeated.headers["etag"] == first.headers["etag"]
