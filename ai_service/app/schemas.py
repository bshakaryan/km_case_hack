from datetime import datetime

from pydantic import BaseModel, Field


class AreaRecord(BaseModel):
    id: int
    name: str


class BrigadeRecord(BaseModel):
    id: int
    name: str


class EmployeeRecord(BaseModel):
    id: int
    name: str
    role: str
    login: str = ""
    specialty: str = ""
    grade: int = 0
    brigade_id: int | None = None
    on_shift: bool = True


class EquipmentRecord(BaseModel):
    id: int
    name: str
    inventory_number: str
    area_id: int
    type: str = ""
    criticality: str = "medium"


class FaultCodeRecord(BaseModel):
    id: int
    code: str
    name: str


class MaterialRecord(BaseModel):
    id: int
    name: str
    unit: str


class MaterialNormRecord(BaseModel):
    fault_code_id: int
    material_id: int
    quantity: float


class TimeNormRecord(BaseModel):
    id: int
    name: str
    hours: float


class EventRecord(BaseModel):
    id: int
    action: str
    from_status: str | None = None
    to_status: str
    actor_name: str | None = None
    created_at: datetime
    comment: str = ""


class PhotoRecord(BaseModel):
    id: int
    kind: str
    created_at: datetime | None = None
    url: str | None = None
    path: str | None = None
    author_name: str | None = None


class MaterialUsageRecord(BaseModel):
    material_id: int
    quantity: float
    name: str | None = None
    unit: str | None = None


class CompletionRecord(BaseModel):
    work_done: str
    fault_code_id: int | None = None
    comment: str = ""
    materials: list[MaterialUsageRecord] = Field(default_factory=list)


class OrderRecord(BaseModel):
    id: int
    number: str
    title: str
    description: str = ""
    work_type: str
    area_id: int
    equipment_id: int
    assignee_id: int
    brigade_id: int | None = None
    master_id: int
    priority: str
    status: str
    deadline: datetime
    created_at: datetime
    started_at: datetime | None = None
    completed_at: datetime | None = None
    closed_at: datetime | None = None
    comment: str = ""
    normal_hours: float | None = None
    downtime_minutes: float | None = None
    score: float | None = None
    completion: CompletionRecord | None = None
    ai_review: dict | None = None
    events: list[EventRecord] = Field(default_factory=list)
    photos: list[PhotoRecord] = Field(default_factory=list)


class Snapshot(BaseModel):
    areas: list[AreaRecord] = Field(default_factory=list)
    brigades: list[BrigadeRecord] = Field(default_factory=list)
    employees: list[EmployeeRecord] = Field(default_factory=list)
    equipment: list[EquipmentRecord] = Field(default_factory=list)
    fault_codes: list[FaultCodeRecord] = Field(default_factory=list)
    materials: list[MaterialRecord] = Field(default_factory=list)
    material_norms: list[MaterialNormRecord] = Field(default_factory=list)
    time_norms: list[TimeNormRecord] = Field(default_factory=list)
    orders: list[OrderRecord] = Field(default_factory=list)
