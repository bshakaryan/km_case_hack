from datetime import datetime, timedelta, timezone

import jwt
import pytest


def test_login_issues_usable_token_without_exposing_password_hash(api):
    from app.models import Employee

    response = api.client.post(
        "/api/auth/login",
        json={"email": "  EMPLOYEE@EXAMPLE.COM  ", "password": api.db.password},
    )
    assert response.status_code == 200
    token = response.json()
    assert set(token) == {"access_token", "token_type"}
    assert token["token_type"] == "bearer"
    profile = api.client.get("/api/me", headers={"Authorization": f"Bearer {token['access_token']}"})
    assert profile.status_code == 200
    assert profile.json()["email"] == "employee@example.com"
    with api.db.session() as db:
        stored_hash = db.get(Employee, profile.json()["id"]).password_hash
        assert stored_hash.startswith("$argon2")
        assert stored_hash != api.db.password
    for response in (profile, api.get("/api/employees"), api.get("/api/employees/1")):
        assert response.status_code == 200
        assert "password" not in response.text.lower()
        assert stored_hash not in response.text
        assert api.db.password not in response.text


def test_bad_password_and_unknown_account_are_indistinguishable_and_do_not_write(api):
    before = api.db.snapshot()
    responses = [
        api.client.post("/api/auth/login", json={"email": email, "password": "wrong-password"})
        for email in ("employee@example.com", "missing@example.com")
    ]
    assert [response.status_code for response in responses] == [401, 401]
    assert responses[0].json() == responses[1].json()
    assert api.db.snapshot() == before


@pytest.mark.parametrize(
    "method,path,body",
    [
        ("GET", "/api/me", None),
        ("GET", "/api/employees", None),
        ("GET", "/api/employees/1", None),
        ("GET", "/api/requests", None),
        ("POST", "/api/requests/calculate", {"start_date": "2027-01-11", "end_date": "2027-01-12"}),
        ("POST", "/api/requests/1/sync", {}),
        ("GET", "/api/integrations/zup", None),
        ("GET", "/api/requests/1", None),
        ("POST", "/api/requests", {"start_date": "2027-01-01", "end_date": "2027-01-02"}),
        ("PATCH", "/api/requests/1/status", {"status": "approved", "version": 1}),
        ("GET", "/api/notifications", None),
        ("PATCH", "/api/notifications/1/read", None),
        ("GET", "/api/courses", None),
        ("GET", "/api/courses/1", None),
        ("POST", "/api/courses/1/progress", {"progress": 100}),
        ("POST", "/api/courses/1/complete", {"answer_index": 0}),
        ("POST", "/api/assistant/query", {"question": "Как подать заявку?"}),
        ("GET", "/api/knowledge/1", None),
        ("GET", "/api/audit", None),
    ],
)
def test_domain_endpoints_require_authentication(api, method, path, body):
    before = api.db.snapshot()
    response = api.client.request(method, path, json=body, headers={"Idempotency-Key": "unauthorized-test"})
    assert response.status_code == 401, response.text
    assert response.headers["www-authenticate"] == "Bearer"
    assert api.db.snapshot() == before


@pytest.mark.parametrize("kind", ["garbage", "expired", "wrong-secret", "unknown-user", "missing-exp"])
def test_invalid_tokens_are_rejected(api, kind):
    now = datetime.now(timezone.utc)
    payload = {"sub": "1", "iat": now, "exp": now + timedelta(minutes=10)}
    secret = api.db.secret
    if kind == "expired":
        payload.update(iat=now - timedelta(hours=2), exp=now - timedelta(hours=1))
    elif kind == "wrong-secret":
        secret = "another-test-secret-with-more-than-32-characters"
    elif kind == "unknown-user":
        payload["sub"] = "999999"
    elif kind == "missing-exp":
        payload.pop("exp")
    token = "not.a.jwt" if kind == "garbage" else jwt.encode(payload, secret, algorithm="HS256")
    response = api.client.get("/api/me", headers={"Authorization": f"Bearer {token}"})
    assert response.status_code == 401


@pytest.mark.parametrize(
    "actor,visible,hidden",
    [
        ("employee", {1}, {2, 3, 4}),
        ("manager", {1, 2}, {3, 4}),
        ("hr", {1, 2, 3, 4}, set()),
        ("outsider", {4}, {1, 2, 3}),
    ],
)
def test_profile_object_boundaries_include_outside_team(api, actor, visible, hidden):
    response = api.get("/api/employees", actor)
    assert response.status_code == 200
    assert {item["id"] for item in response.json()} == visible
    for employee_id in visible:
        detail = api.get(f"/api/employees/{employee_id}", actor)
        assert detail.status_code == 200
        assert detail.json()["id"] == employee_id
        assert detail.json()["data_source"] == "mock_zup"
    for employee_id in hidden | {999999}:
        assert api.get(f"/api/employees/{employee_id}", actor).status_code == 404


def test_manager_name_does_not_grant_employee_access_to_manager_profile(api):
    profile = api.get("/api/me").json()
    manager = api.get("/api/me", "manager").json()
    assert profile["manager_id"] == manager["id"]
    assert profile["manager_name"] == manager["full_name"]
    assert manager["manager_name"] is None
    assert api.get(f"/api/employees/{manager['id']}").status_code == 404


@pytest.mark.parametrize("actor", ["employee", "manager", "hr"])
def test_profiles_remain_readonly_for_every_role(api, actor):
    headers = api.headers(actor)
    before = api.db.snapshot()
    for path in ("/api/me", "/api/employees/1"):
        for method in ("PATCH", "PUT", "POST", "DELETE"):
            response = api.client.request(
                method, path, headers=headers,
                json={"role": "hr_admin", "manager_id": 3, "leave_balance": 999},
            )
            assert response.status_code == 405
    assert api.db.snapshot() == before


def test_existing_token_uses_current_database_role(api):
    from app.models import Employee

    headers = api.headers("hr")
    assert api.client.get("/api/audit", headers=headers).status_code == 200
    with api.db.session() as db:
        db.get(Employee, 3).role = "employee"
        db.commit()
    assert api.client.get("/api/audit", headers=headers).status_code == 403
    response = api.client.get("/api/employees", headers=headers)
    assert {item["id"] for item in response.json()} == {3}


def test_notifications_are_private_and_mark_read_is_idempotent(api):
    owner = api.get("/api/notifications", "employee").json()
    manager = api.get("/api/notifications", "manager").json()
    assert owner and manager
    assert {item["id"] for item in owner}.isdisjoint(item["id"] for item in manager)
    notification_id = owner[0]["id"]
    for actor in ("manager", "hr", "outsider"):
        api.headers(actor)
    # Authentication is audited; take the write baseline after all logins.
    before = api.db.snapshot()
    for actor in ("manager", "hr", "outsider"):
        assert api.patch(f"/api/notifications/{notification_id}/read", actor=actor).status_code == 404
    assert api.db.snapshot() == before
    first = api.patch(f"/api/notifications/{notification_id}/read")
    assert first.status_code == 200
    assert first.json()["read"] is True
    after = api.db.snapshot()
    second = api.patch(f"/api/notifications/{notification_id}/read")
    assert second.json() == first.json()
    assert api.db.snapshot() == after


def test_audit_is_hr_only_and_omits_credentials_and_question_text(api):
    for actor in ("employee", "manager", "outsider"):
        assert api.get("/api/audit", actor).status_code == 403
    question = "UNIQUE-PRIVATE-QUESTION-58214"
    assert api.post("/api/assistant/query", {"question": question}).status_code == 200
    headers = api.headers("hr")
    response = api.client.get("/api/audit", headers=headers)
    assert response.status_code == 200
    assert any(event["action"] == "auth.login" for event in response.json())
    for event in response.json():
        assert set(event) == {"id", "actor_id", "action", "entity_type", "entity_id", "created_at"}
    assert question not in response.text
    assert api.db.password not in response.text
    assert headers["Authorization"].split()[1] not in response.text
    assert "$argon2" not in response.text
