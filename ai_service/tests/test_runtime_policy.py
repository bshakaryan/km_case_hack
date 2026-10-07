import sys
from types import ModuleType

import pytest

from app.backend_source import BackendDataSource
from app.config import Settings
from app.factory import create_app, telegram_enabled
from app.synthetic_source import SyntheticDataSource


@pytest.mark.parametrize("demo_mode", [True, False])
def test_backend_mode_fails_before_runtime_construction(monkeypatch, demo_mode):
    runtime = ModuleType("app.main")
    runtime._create_app = lambda *args: pytest.fail("Backend runtime was constructed")
    monkeypatch.setitem(sys.modules, "app.main", runtime)
    with pytest.raises(RuntimeError, match="gateway"):
        create_app(Settings(data_source="backend", demo_mode=demo_mode))


def test_backend_source_cannot_be_injected_as_synthetic(monkeypatch):
    runtime = ModuleType("app.main")
    runtime._create_app = lambda *args: pytest.fail("Backend runtime was constructed")
    monkeypatch.setitem(sys.modules, "app.main", runtime)
    with pytest.raises(RuntimeError, match="BackendDataSource"):
        create_app(Settings(), BackendDataSource("http://backend:8000", "test-token"))


def test_synthetic_source_does_not_bypass_backend_mode(tmp_path):
    with pytest.raises(RuntimeError, match="gateway"):
        create_app(Settings(data_source="backend"), SyntheticDataSource(tmp_path / "snapshot.json"))


def test_synthetic_runtime_delegates_to_application(monkeypatch, tmp_path):
    settings = Settings()
    source = SyntheticDataSource(tmp_path / "snapshot.json")
    store = object()
    application = object()
    runtime = ModuleType("app.main")

    def build(actual_settings, actual_source, actual_store):
        assert (actual_settings, actual_source, actual_store) == (settings, source, store)
        return application

    runtime._create_app = build
    monkeypatch.setitem(sys.modules, "app.main", runtime)
    assert create_app(settings, source, store) is application


@pytest.mark.parametrize("data_source,demo_mode,enabled", [
    ("synthetic", True, False),
    ("synthetic", False, True),
    ("backend", True, False),
    ("backend", False, False),
])
def test_telegram_credentials_do_not_override_runtime_policy(data_source, demo_mode, enabled):
    settings = Settings(data_source=data_source, demo_mode=demo_mode,
                        telegram_bot_token="test-token", telegram_chats={"E-02": "test-chat"})
    assert telegram_enabled(settings) is enabled


def test_telegram_opt_in_also_requires_credentials():
    assert not telegram_enabled(Settings(demo_mode=False))
