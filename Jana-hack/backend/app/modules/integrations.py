from dataclasses import dataclass
from datetime import date
import ssl
from typing import Protocol
from urllib.parse import quote

import httpx
from fastapi import HTTPException
from pydantic import BaseModel, Field, TypeAdapter, ValidationError

from app.config import get_settings


@dataclass(frozen=True)
class EmployeeSnapshot:
    id: int
    email: str
    full_name: str
    role: str
    position: str
    department: str
    manager_id: int | None
    hire_date: date
    leave_balance: int
    zup_id: str = ""
    company: str = "Jana Post · демо"


class HRISAdapter(Protocol):
    def employees(self) -> list[EmployeeSnapshot]: ...


class DemoZupFixtures:
    def employees(self):
        return [
            EmployeeSnapshot(1, "employee@example.com", "Айдана Демо", "employee", "Координатор логистики", "Операционный отдел", 2, date(2024, 3, 15), 18, "demo-1"),
            EmployeeSnapshot(2, "manager@example.com", "Арман Демо", "manager", "Руководитель отдела", "Операционный отдел", None, date(2022, 6, 1), 22, "demo-2"),
            EmployeeSnapshot(3, "hr@example.com", "Алия Демо", "hr_admin", "HR-партнёр", "HR", None, date(2023, 1, 10), 24, "demo-3"),
            EmployeeSnapshot(4, "outsider@example.com", "Данияр Демо", "employee", "Специалист поддержки", "Клиентский сервис", None, date(2025, 2, 1), 12, "demo-4"),
        ]


class ZupBalance(BaseModel):
    employee_id: str
    balance: int
    applied_commands: list[str]
    source: str = "mock_zup_http"


class ZupCalculation(ZupBalance):
    days_count: int = Field(ge=0)
    calendar_days: int = Field(gt=0)
    excluded_dates: list[date]
    calendar_version: str = Field(min_length=1, max_length=80)


class ZupReceipt(BaseModel):
    reference: str = Field(min_length=1, max_length=100)
    command_key: str
    status: str


class HttpZupAdapter:
    def __init__(self, base_url: str, token: str | None = None, transport=None, *, mode="mock",
                 auth_type="bearer", username=None, password=None, timeout=5,
                 verify_tls=True, ca_bundle=None, client_cert=None, client_key=None):
        self.base_url, self.token, self.transport = base_url.rstrip("/"), token, transport
        self.mode, self.auth_type = mode, auth_type
        self.username, self.password, self.timeout = username, password, timeout
        try:
            self.verify = ssl.create_default_context(cafile=ca_bundle) if ca_bundle else verify_tls
        except OSError as error:
            raise HTTPException(503, "Не удалось загрузить сертификат центра сертификации 1С:ЗУП") from error
        self.cert = (client_cert, client_key) if client_cert and client_key else None

    @property
    def source_title(self):
        return "реальная 1С:ЗУП" if self.mode == "real" else "mock 1С:ЗУП"

    def call(self, method: str, path: str, body=None, key=None):
        headers = {"User-Agent": "JanaMen-ZUP/1.0"}
        auth = None
        if self.auth_type == "bearer":
            headers["Authorization"] = f"Bearer {self.token}"
        else:
            auth = httpx.BasicAuth(self.username, self.password)
        if key:
            headers["Idempotency-Key"] = key
        try:
            with httpx.Client(timeout=self.timeout, transport=self.transport, follow_redirects=False,
                              trust_env=False, verify=self.verify, cert=self.cert, auth=auth) as client:
                response = client.request(method, self.base_url + path, headers=headers, json=body)
            if response.status_code in (409, 422):
                error_body = response.json()
                detail = error_body.get("detail") if isinstance(error_body, dict) else None
                raise HTTPException(response.status_code, detail if isinstance(detail, str) else f"Конфликт данных: {self.source_title}")
            if response.status_code in (401, 403):
                raise HTTPException(503, f"{self.source_title.capitalize()} отклонила сервисные учётные данные")
            response.raise_for_status()
            return response.json()
        except (httpx.HTTPError, ValueError, OSError) as error:
            raise HTTPException(503, f"{self.source_title.capitalize()} недоступна или вернула некорректный ответ") from error

    def employees(self):
        try:
            return TypeAdapter(list[EmployeeSnapshot]).validate_python(self.call("GET", "/employees"))
        except (ValidationError, ValueError) as error:
            raise HTTPException(503, f"Некорректные профили: {self.source_title}") from error

    def balance(self, employee_id: str) -> ZupBalance:
        try:
            value = ZupBalance.model_validate(self.call("GET", f"/employees/{quote(employee_id, safe='')}/leave-balance"))
            if value.employee_id != employee_id:
                raise ValueError("Unexpected employee")
            return value.model_copy(update={"source": "zup_http" if self.mode == "real" else "mock_zup_http"})
        except (ValidationError, ValueError) as error:
            raise HTTPException(503, f"Некорректный ответ баланса: {self.source_title}") from error

    def calculate(self, employee_id: str, start: date, end: date) -> ZupCalculation:
        try:
            value = ZupCalculation.model_validate(self.call("POST", "/leave/calculate", {"employee_id": employee_id, "start_date": start.isoformat(), "end_date": end.isoformat()}))
            if value.employee_id != employee_id or value.calendar_days != (end - start).days + 1 or len(set(value.excluded_dates)) != len(value.excluded_dates) or any(day < start or day > end for day in value.excluded_dates) or value.days_count != value.calendar_days - len(value.excluded_dates):
                raise ValueError("Inconsistent calculation")
            return value.model_copy(update={"source": "zup_http" if self.mode == "real" else "mock_zup_http"})
        except (ValidationError, ValueError) as error:
            raise HTTPException(503, f"Некорректный расчёт: {self.source_title}") from error

    def register(self, body: dict, key: str) -> ZupReceipt:
        try:
            receipt = ZupReceipt.model_validate(self.call("POST", "/leave/documents", body, key))
            if receipt.command_key != key or receipt.status != "registered":
                raise ValueError("Unexpected receipt")
            return receipt
        except (ValidationError, ValueError) as error:
            raise HTTPException(503, f"Некорректная квитанция: {self.source_title}") from error


def zup_adapter() -> HttpZupAdapter:
    settings = get_settings()
    if settings.zup_auth_type == "bearer" and not settings.zup_api_token:
        raise HTTPException(503, "Для подключения 1С:ЗУП настройте ZUP_API_TOKEN")
    if settings.zup_auth_type == "basic" and (not settings.zup_username or not settings.zup_password):
        raise HTTPException(503, "Для подключения 1С:ЗУП настройте ZUP_USERNAME и ZUP_PASSWORD")
    return HttpZupAdapter(
        settings.zup_base_url, settings.zup_api_token, mode=settings.zup_mode,
        auth_type=settings.zup_auth_type, username=settings.zup_username,
        password=settings.zup_password, timeout=settings.zup_timeout_seconds,
        verify_tls=settings.zup_verify_tls, ca_bundle=settings.zup_ca_bundle,
        client_cert=settings.zup_client_cert, client_key=settings.zup_client_key,
    )


class DocumentWorkflowAdapter(Protocol):
    """Future boundary. Delivery must use a stable idempotency key + outbox."""
    def submit_leave(self, request_id: int, idempotency_key: str) -> str: ...


class UnconfiguredDocumentologAdapter:
    def submit_leave(self, request_id: int, idempotency_key: str) -> str:
        raise NotImplementedError("Documentolog не подключён; заявки обрабатываются только внутри MVP")
