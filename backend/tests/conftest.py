import pytest
from fastapi.testclient import TestClient
from app.main import create_app


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
