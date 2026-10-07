import json
import os
from pathlib import Path
from typing import Literal

from dotenv import load_dotenv
from pydantic import BaseModel, Field, SecretStr
from sqlalchemy.engine import URL


BASE_DIR = Path(__file__).resolve().parents[1]
DEFAULT_RATING_WEIGHTS = {"quality": 0.30, "on_time": 0.25, "no_rework": 0.15,
                          "no_repeat": 0.15, "volume": 0.10, "no_unjustified_refusal": 0.05}


def positive_env(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
        return value if value > 0 else default
    except ValueError:
        return default


class Settings(BaseModel):
    data_source: Literal["backend", "synthetic"] = "synthetic"
    synthetic_data_path: Path = BASE_DIR / "data" / "snapshot.json"
    backend_url: str = "http://127.0.0.1:8000"
    backend_token: SecretStr = SecretStr("")
    ai_service_token: SecretStr = SecretStr("")
    ai_database_url: str = str(URL.create("sqlite", database=str(BASE_DIR / "state" / "ai.db")))
    ai_db_confirmed_separate: bool = False
    demo_mode: bool = True
    llm_provider: str = ""
    llm_model_fast: str = ""
    llm_model_smart: str = ""
    llm_model_vision: str = ""
    stt_model: str = ""
    openai_api_key: SecretStr = SecretStr("")
    anthropic_api_key: SecretStr = SecretStr("")
    telegram_bot_token: SecretStr = SecretStr("")
    telegram_chats: dict[str, str] = Field(default_factory=dict)
    deadline_scheduler_enabled: bool = False
    deadline_poll_seconds: int = 60
    due_soon_minutes: int = 30
    accept_minutes: int = 10
    emergency_accept_minutes: int = 3
    reminder_repeat_minutes: int = 30
    manager_escalation_minutes: int = 90
    rating_weights: dict[str, float] = Field(default_factory=lambda: DEFAULT_RATING_WEIGHTS.copy())

    @classmethod
    def from_env(cls):
        load_dotenv(BASE_DIR / ".env", override=False)
        path = Path(os.getenv("SYNTHETIC_DATA_PATH", "data/snapshot.json"))
        if not path.is_absolute():
            path = BASE_DIR / path
        try:
            telegram_chats = json.loads(os.getenv("TELEGRAM_CHATS", "{}"))
        except json.JSONDecodeError:
            telegram_chats = {}
        if not isinstance(telegram_chats, dict):
            telegram_chats = {}
        try:
            rating_weights = json.loads(os.getenv("RATING_WEIGHTS", json.dumps(DEFAULT_RATING_WEIGHTS)))
            if set(rating_weights) != set(DEFAULT_RATING_WEIGHTS) or any(
                not isinstance(value, (float, int)) or value < 0 for value in rating_weights.values()
            ) or abs(sum(rating_weights.values()) - 1) > 0.001:
                rating_weights = DEFAULT_RATING_WEIGHTS.copy()
        except (json.JSONDecodeError, AttributeError, TypeError):
            rating_weights = DEFAULT_RATING_WEIGHTS.copy()
        return cls(
            data_source=os.getenv("DATA_SOURCE", "synthetic"),
            synthetic_data_path=path,
            backend_url=os.getenv("BACKEND_URL", "http://127.0.0.1:8000"),
            backend_token=os.getenv("BACKEND_TOKEN", ""),
            ai_service_token=os.getenv("AI_SERVICE_TOKEN", ""),
            ai_database_url=os.getenv("AI_DATABASE_URL") or cls.model_fields["ai_database_url"].default,
            ai_db_confirmed_separate=os.getenv("AI_DB_CONFIRMED_SEPARATE", "false").lower() == "true",
            demo_mode=os.getenv("DEMO_MODE", "true").lower() == "true",
            llm_provider=os.getenv("LLM_PROVIDER", ""),
            llm_model_fast=os.getenv("LLM_MODEL_FAST", ""),
            llm_model_smart=os.getenv("LLM_MODEL_SMART", ""),
            llm_model_vision=os.getenv("LLM_MODEL_VISION", ""),
            stt_model=os.getenv("STT_MODEL", ""),
            openai_api_key=os.getenv("OPENAI_API_KEY", ""),
            anthropic_api_key=os.getenv("ANTHROPIC_API_KEY", ""),
            telegram_bot_token=os.getenv("TELEGRAM_BOT_TOKEN", ""),
            telegram_chats=telegram_chats,
            deadline_scheduler_enabled=os.getenv("DEADLINE_SCHEDULER_ENABLED", "false").lower() == "true",
            deadline_poll_seconds=max(10, positive_env("DEADLINE_POLL_SECONDS", 60)),
            due_soon_minutes=positive_env("DUE_SOON_MINUTES", 30),
            accept_minutes=positive_env("ACCEPT_MINUTES", 10),
            emergency_accept_minutes=positive_env("EMERGENCY_ACCEPT_MINUTES", 3),
            reminder_repeat_minutes=positive_env("REMINDER_REPEAT_MINUTES", 30),
            manager_escalation_minutes=positive_env("MANAGER_ESCALATION_MINUTES", 90),
            rating_weights=rating_weights,
        )
