"""Draft orders from text or an explicit speech-to-text adapter; never create orders."""

import asyncio
import mimetypes
import re
from datetime import datetime, timedelta
from difflib import SequenceMatcher
from typing import Protocol

import httpx
from pydantic import BaseModel, ConfigDict

from .datasource import DataSource
from .deadlines import utc
from .llm_client import LLMClient
from .schemas import Snapshot


class IntakeSelection(BaseModel):
    model_config = ConfigDict(extra="forbid")

    equipment_id: int | None
    area_id: int | None
    fault_code_id: int | None


INTAKE_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {"equipment_id": {"type": ["integer", "null"]},
                   "area_id": {"type": ["integer", "null"]},
                   "fault_code_id": {"type": ["integer", "null"]}},
    "required": ["equipment_id", "area_id", "fault_code_id"],
}


def quoted_name_present(name: str, text: str):
    return bool(re.search(r"(?<!\w)" + re.escape(name.casefold()) + r"(?!\w)", text.casefold()))


def fault_match(text: str, snapshot: Snapshot):
    lower = text.casefold()
    exact = [fault for fault in snapshot.fault_codes if fault.name.casefold() in lower or
             quoted_name_present(fault.code, lower)]
    if len(exact) == 1:
        return exact[0].id
    if len(exact) > 1:
        return None
    tokens = re.findall(r"[\w-]+", lower)
    ranked = []
    for fault in snapshot.fault_codes:
        fault_tokens = re.findall(r"[\w-]+", fault.name.casefold())
        windows = [" ".join(tokens[index:index + len(fault_tokens)])
                   for index in range(max(0, len(tokens) - len(fault_tokens) + 1))]
        score = max((SequenceMatcher(None, fault.name.casefold(), window).ratio() for window in windows), default=0)
        ranked.append((score, fault.id))
    ranked.sort(reverse=True)
    if ranked and ranked[0][0] >= 0.83 and (len(ranked) == 1 or ranked[0][0] - ranked[1][0] >= 0.08):
        return ranked[0][1]
    return None


def resolve_deadline(text: str, now: datetime):
    lower = text.casefold()
    match = re.search(r"(?:за|через|в течение|срок через)\s+(\d{1,3})\s*(ч\b|час|мин)", lower)
    if match:
        amount = int(match.group(1))
        if not 0 < amount <= 168:
            return None
        return now + (timedelta(minutes=amount) if match.group(2).startswith("мин") else timedelta(hours=amount))
    match = re.search(r"\bдо\s+(\d{1,2}):(\d{2})\b", lower)
    if match:
        hour, minute = map(int, match.groups())
        if hour > 23 or minute > 59:
            return None
        target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
        return target if target > now else None
    return None


class Transcriber(Protocol):
    async def transcribe(self, audio: bytes, filename: str) -> str | None: ...


class OpenAITranscriber:
    def __init__(self, api_key: str, model: str, transport: httpx.AsyncBaseTransport | None = None):
        self.api_key = api_key
        self.model = model
        self.transport = transport

    async def transcribe(self, audio: bytes, filename: str):
        if not self.api_key or not self.model:
            return None
        async with httpx.AsyncClient(timeout=35, transport=self.transport) as client:
            media_type = mimetypes.guess_type(filename)[0] or "audio/wav"
            response = await client.post("https://api.openai.com/v1/audio/transcriptions",
                                         headers={"Authorization": f"Bearer {self.api_key}"},
                                         data={"model": self.model},
                                         files={"file": (filename, audio, media_type)})
            response.raise_for_status()
            return response.json().get("text")


class OrderIntake:
    def __init__(self, source: DataSource, llm: LLMClient, transcriber: Transcriber | None = None):
        self.source = source
        self.llm = llm
        self.transcriber = transcriber

    async def from_voice(self, audio: bytes, filename: str, now: datetime):
        if not audio or len(audio) > 10_000_000:
            raise ValueError("Аудио должно содержать от 1 байта до 10 МБ")
        if not self.transcriber:
            return {"status": "needs_transcript", "draft": None, "original_phrase": None,
                    "needs_master_review": True}
        try:
            phrase = await asyncio.wait_for(self.transcriber.transcribe(audio, filename), timeout=36)
        except (httpx.HTTPError, asyncio.TimeoutError, ValueError):
            phrase = None
        if not phrase:
            return {"status": "needs_transcript", "draft": None, "original_phrase": None,
                    "needs_master_review": True}
        return await self.from_text(phrase, now)

    async def from_text(self, phrase: str, now: datetime):
        if not phrase.strip() or len(phrase) > 2000:
            raise ValueError("Описание должно содержать от 1 до 2000 символов")
        now = utc(now)
        snapshot = await self.source.snapshot()
        equipment = [item for item in snapshot.equipment if quoted_name_present(item.name, phrase)]
        equipment_id = equipment[0].id if len(equipment) == 1 else None
        area = next((item for item in snapshot.areas if quoted_name_present(item.name, phrase)), None)
        area_id = area.id if area else None
        fault_id = fault_match(phrase, snapshot)
        if equipment_id is None or fault_id is None:
            if self.llm.safe_text_enabled():
                selected = await self.llm.structured_response(
                    "order_intake", {"phrase": self.llm.redact(phrase, snapshot.employees),
                                     "equipment": [{"id": item.id, "name": item.name, "area_id": item.area_id}
                                                   for item in snapshot.equipment],
                                     "areas": [{"id": item.id, "name": item.name} for item in snapshot.areas],
                                     "faults": [{"id": item.id, "code": item.code, "name": item.name}
                                                for item in snapshot.fault_codes]},
                    INTAKE_SCHEMA, IntakeSelection)
                if selected:
                    if equipment_id is None and selected.equipment_id in {item.id for item in snapshot.equipment}:
                        equipment_id = selected.equipment_id
                    if fault_id is None and selected.fault_code_id in {item.id for item in snapshot.fault_codes}:
                        fault_id = selected.fault_code_id
                    if area_id is None and selected.area_id in {item.id for item in snapshot.areas}:
                        area_id = selected.area_id
        selected_equipment = next((item for item in snapshot.equipment if item.id == equipment_id), None)
        conflict = selected_equipment is not None and area_id is not None and selected_equipment.area_id != area_id
        if selected_equipment and area_id is None:
            area_id = selected_equipment.area_id
        fault = next((item for item in snapshot.fault_codes if item.id == fault_id), None)
        norm = next((item for item in snapshot.time_norms if fault and item.name.casefold().startswith(
            fault.code.casefold() + ":")), None)
        deadline = resolve_deadline(phrase, now)
        missing = [name for name, value in (("equipment_id", equipment_id), ("area_id", area_id),
                                             ("fault_code_id", fault_id), ("deadline", deadline)) if value is None]
        if conflict:
            missing.append("area_conflict")
        return {"status": "needs_master_review" if missing else "draft", "original_phrase": phrase,
                "draft": {"equipment_id": equipment_id, "area_id": area_id, "fault_code_id": fault_id,
                          "time_norm_id": norm.id if norm else None, "normal_hours": norm.hours if norm else None,
                          "deadline": deadline.isoformat() if deadline else None},
                "missing_or_conflicting": missing, "needs_master_review": True,
                "creates_order": False}
