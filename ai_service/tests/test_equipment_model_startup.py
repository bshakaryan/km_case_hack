import pytest
from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.storage import AIStore
from app.synthetic_source import SyntheticDataSource


@pytest.mark.parametrize("corrupt", [False, True])
def test_missing_or_corrupt_weights_fail_startup_and_health(tmp_path, monkeypatch, corrupt):
    model_path = tmp_path / "mobilenetv2.onnx"
    if corrupt:
        model_path.write_bytes(b"not an ONNX model")
    monkeypatch.setenv("AI_IMAGE_EMBEDDING_MODEL", str(model_path))
    app = create_app(Settings(ai_database_url="sqlite:///:memory:"),
                     SyntheticDataSource(tmp_path / "snapshot.json"), AIStore("sqlite:///:memory:"))
    response = TestClient(app).get("/ai/health")
    assert response.status_code == 503
    assert "MobileNetV2" in response.json()["detail"]
    with pytest.raises(RuntimeError, match="MobileNetV2"):
        with TestClient(app):
            pass
