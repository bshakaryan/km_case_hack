from datetime import datetime
from typing import Literal
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

Priority = Literal["emergency", "high", "normal", "planned"]


class Payload(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class Login(Payload):
    login: str = Field(min_length=1, max_length=80)
    pin: str = Field(min_length=4, max_length=32)


class OrderCreate(Payload):
    title: str = Field(min_length=3, max_length=200)
    description: str = Field(min_length=1, max_length=5000)
    work_type: Literal["planned", "unplanned"]
    area_id: int = Field(gt=0)
    equipment_id: int = Field(gt=0)
    assignee_id: int | None = Field(default=None, gt=0)
    brigade_id: int | None = Field(default=None, gt=0)
    priority: Priority = "normal"
    deadline: datetime
    normal_hours: float = Field(default=2, gt=0, le=1000)
    comment: str = Field(default="", max_length=3000)

    @field_validator("deadline")
    @classmethod
    def aware_deadline(cls, value):
        if value.tzinfo is None:
            raise ValueError("Укажите часовой пояс срока выполнения")
        return value

    @model_validator(mode="after")
    def assignment(self):
        if bool(self.assignee_id) == bool(self.brigade_id):
            raise ValueError("Укажите одного исполнителя или одну бригаду")
        return self


class OrderPatch(Payload):
    description: str | None = Field(default=None, min_length=1, max_length=5000)
    assignee_id: int | None = Field(default=None, gt=0)
    brigade_id: int | None = Field(default=None, gt=0)
    priority: Priority | None = None
    deadline: datetime | None = None
    comment: str | None = Field(default=None, max_length=3000)

    @field_validator("deadline")
    @classmethod
    def aware_deadline(cls, value):
        if value is not None and value.tzinfo is None:
            raise ValueError("Укажите часовой пояс срока выполнения")
        return value

    @model_validator(mode="after")
    def assignment(self):
        if self.assignee_id and self.brigade_id:
            raise ValueError("Укажите исполнителя или бригаду")
        if not self.model_fields_set:
            raise ValueError("Нет изменений")
        if any(getattr(self, key) is None for key in self.model_fields_set):
            raise ValueError("Значение изменения не может быть null")
        return self


class Transition(Payload):
    action: Literal["accept", "queue", "reject", "start", "pause", "resume", "close", "rework", "cancel"]
    reason: str = Field(default="", max_length=3000)
    comment: str = Field(default="", max_length=3000)
    score: float | None = Field(default=None, ge=1, le=5)


class MaterialUsage(Payload):
    material_id: int = Field(gt=0)
    quantity: float = Field(gt=0, le=1_000_000, allow_inf_nan=False)


class Completion(Payload):
    work_done: str = Field(min_length=10, max_length=5000)
    fault_code_id: int = Field(gt=0)
    materials: list[MaterialUsage] = Field(default_factory=list, max_length=100)
    comment: str = Field(default="", max_length=3000)

    @model_validator(mode="after")
    def unique_materials(self):
        ids = [m.material_id for m in self.materials]
        if len(ids) != len(set(ids)):
            raise ValueError("Материал можно указать только один раз")
        return self


class DeviceRegistration(Payload):
    token: str = Field(min_length=8, max_length=4096)
    platform: Literal["android"]
    app_version: str | None = Field(default=None, max_length=40)


class DeviceUnregister(Payload):
    token: str = Field(min_length=1, max_length=4096)
