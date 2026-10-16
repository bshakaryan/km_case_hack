from functools import lru_cache
from typing import Literal
from urllib.parse import urlparse

from pydantic import Field, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    database_url: str = "sqlite:///./jana.db"
    jwt_secret: str = Field(min_length=32)
    token_minutes: int = Field(default=60, ge=1, le=1440)
    demo_password: str | None = Field(default=None, min_length=12)
    cors_origins: str = "http://localhost:3000,http://127.0.0.1:3000"
    zup_mode: Literal["mock", "real"] = "mock"
    zup_base_url: str = "http://127.0.0.1:8300/hs/jana/v1"
    zup_auth_type: Literal["bearer", "basic"] = "bearer"
    zup_api_token: str | None = Field(default=None, min_length=32)
    zup_username: str | None = None
    zup_password: str | None = None
    zup_timeout_seconds: float = Field(default=5, ge=1, le=30)
    zup_verify_tls: bool = True
    zup_ca_bundle: str | None = None
    zup_client_cert: str | None = None
    zup_client_key: str | None = None
    zup_allow_insecure_http: bool = False

    @model_validator(mode="after")
    def validate_zup_connection(self):
        parsed = urlparse(self.zup_base_url)
        if parsed.scheme not in ("http", "https") or not parsed.netloc:
            raise ValueError("ZUP_BASE_URL должен быть абсолютным HTTP(S) URL")
        if self.zup_mode == "real" and parsed.scheme != "https" and not self.zup_allow_insecure_http:
            raise ValueError("Реальная 1С:ЗУП требует HTTPS; для изолированного тестового контура явно задайте ZUP_ALLOW_INSECURE_HTTP=true")
        if self.zup_mode == "real" and not self.zup_verify_tls and not self.zup_allow_insecure_http:
            raise ValueError("Для реальной 1С:ЗУП проверка TLS обязательна; исключение допускается только явной настройкой тестового контура")
        if bool(self.zup_client_cert) != bool(self.zup_client_key):
            raise ValueError("ZUP_CLIENT_CERT и ZUP_CLIENT_KEY задаются вместе")
        return self

    @property
    def zup_tls_verified(self) -> bool:
        return urlparse(self.zup_base_url).scheme == "https" and bool(self.zup_ca_bundle or self.zup_verify_tls)


@lru_cache
def get_settings() -> Settings:
    return Settings()
