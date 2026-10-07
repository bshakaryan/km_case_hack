"""Gate the optional demo service before constructing its runtime dependencies."""

from __future__ import annotations

from typing import TYPE_CHECKING

from .backend_source import BackendDataSource
from .config import Settings
from .datasource import DataSource

if TYPE_CHECKING:
    from .storage import AIStore


def require_synthetic_runtime(settings: Settings, source: DataSource | None = None):
    if settings.data_source != "synthetic" or isinstance(source, BackendDataSource):
        raise RuntimeError(
            "ИИ-сервис пока доступен только на синтетических данных. "
            "BackendDataSource запрещён до интеграции gateway и проверки прав пользователя."
        )


def create_app(settings: Settings | None = None, source: DataSource | None = None,
               store: AIStore | None = None):
    settings = settings or Settings.from_env()
    require_synthetic_runtime(settings, source)
    from .main import _create_app

    return _create_app(settings, source, store)


def telegram_enabled(settings: Settings) -> bool:
    """External demo notifications require an explicit opt-in and synthetic data."""
    return bool(settings.data_source == "synthetic" and not settings.demo_mode
                and settings.telegram_bot_token.get_secret_value() and settings.telegram_chats)
