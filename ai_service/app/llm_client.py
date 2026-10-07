"""Async structured text interpretation. All numeric decisions remain in Python."""

import hashlib
import json
import logging
import time
import base64
import re
from typing import Literal

import httpx
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from .config import Settings
from .storage import AIStore


LOG = logging.getLogger(__name__)


class Remark(BaseModel):
    model_config = ConfigDict(extra="forbid")

    text: str
    evidence_ref: str


class SemanticAssessment(BaseModel):
    model_config = ConfigDict(extra="forbid")

    works_match_problem: bool | None
    match_confidence: float = Field(ge=0, le=1)
    remarks: list[Remark]
    explanation_worker: str
    explanation_master: str


class VisionAssessment(BaseModel):
    model_config = ConfigDict(extra="forbid")

    same_equipment: bool | None
    defect_resolved: bool | None
    quality: Literal["excellent", "good", "mixed", "poor", "critical", "unknown"]
    confidence: float = Field(ge=0, le=1)
    issues: list[str]
    explanation: str


SEMANTIC_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "works_match_problem": {"type": ["boolean", "null"]},
        "match_confidence": {"type": "number"},
        "remarks": {"type": "array", "items": {"type": "object", "additionalProperties": False,
                                           "properties": {"text": {"type": "string"},
                                                          "evidence_ref": {"type": "string"}},
                                           "required": ["text", "evidence_ref"]}},
        "explanation_worker": {"type": "string"},
        "explanation_master": {"type": "string"},
    },
    "required": ["works_match_problem", "match_confidence", "remarks",
                 "explanation_worker", "explanation_master"],
}


VISION_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "same_equipment": {"type": ["boolean", "null"]},
        "defect_resolved": {"type": ["boolean", "null"]},
        "quality": {"type": "string", "enum": ["excellent", "good", "mixed", "poor", "critical", "unknown"]},
        "confidence": {"type": "number"},
        "issues": {"type": "array", "items": {"type": "string"}},
        "explanation": {"type": "string"},
    },
    "required": ["same_equipment", "defect_resolved", "quality", "confidence", "issues", "explanation"],
}


class LLMClient:
    def __init__(self, settings: Settings, store: AIStore, transport: httpx.AsyncBaseTransport | None = None):
        self.settings = settings
        self.store = store
        self.transport = transport
        self.request_count = 0
        self.cache_hits = 0
        self.input_tokens = 0
        self.output_tokens = 0
        self.request_latencies_ms = []

    def enabled(self):
        if self.settings.demo_mode or not self.settings.llm_model_fast:
            return False
        if self.settings.llm_provider == "openai":
            return bool(self.settings.openai_api_key.get_secret_value())
        if self.settings.llm_provider == "anthropic":
            return bool(self.settings.anthropic_api_key.get_secret_value())
        return False

    def safe_text_enabled(self):
        return self.settings.data_source == "synthetic" and self.enabled()

    @staticmethod
    def redact(value: str, employees: list):
        redacted = value
        for person in employees:
            for secret in (person.name, person.login):
                if secret and len(secret) >= 4:
                    redacted = re.sub(re.escape(secret), "[сотрудник]", redacted, flags=re.IGNORECASE)
        return re.sub(r"(?<!\w)\+?\d[\d\s()\-]{8,}\d(?!\w)", "[телефон]", redacted)

    async def structured_response(self, purpose: str, prompt: dict, schema: dict, response_model: type[BaseModel],
                                  smart: bool = False):
        if not self.safe_text_enabled():
            return None
        serialized = json.dumps(prompt, ensure_ascii=False, sort_keys=True)
        provider = self.settings.llm_provider
        model = self.settings.llm_model_smart if smart and self.settings.llm_model_smart else self.settings.llm_model_fast
        cache_key = hashlib.sha256(f"structured:{purpose}:{provider}:{model}:{serialized}".encode()).hexdigest()
        cached = self.store.get_cached(cache_key)
        if cached is not None:
            try:
                result = response_model.model_validate(cached)
                self.cache_hits += 1
                return result
            except ValidationError:
                pass
        for attempt in range(2):
            started = time.perf_counter()
            self.request_count += 1
            try:
                payload = await self._request_structured(purpose, serialized, schema, model)
                result = response_model.model_validate(payload)
                self.store.put_cached(cache_key, provider, model, result.model_dump(mode="json"))
                return result
            except (httpx.HTTPError, KeyError, ValueError, ValidationError, TypeError) as error:
                LOG.warning("Structured %s failed on attempt %s: %s", purpose, attempt + 1, type(error).__name__)
            finally:
                self.request_latencies_ms.append(round((time.perf_counter() - started) * 1000, 2))
        return None

    async def _request_structured(self, purpose: str, serialized: str, schema: dict, model: str):
        instruction = "Выбирай только переданные ID и инструменты. Не придумывай сотрудников, факты, числа и сроки."
        async with httpx.AsyncClient(timeout=20, transport=self.transport) as client:
            if self.settings.llm_provider == "openai":
                response = await client.post(
                    "https://api.openai.com/v1/responses",
                    headers={"Authorization": f"Bearer {self.settings.openai_api_key.get_secret_value()}"},
                    json={"model": model, "store": False,
                          "input": [{"role": "system", "content": instruction},
                                    {"role": "user", "content": serialized}],
                          "text": {"format": {"type": "json_schema", "name": purpose,
                                              "strict": True, "schema": schema}}},
                )
                response.raise_for_status()
                payload = response.json()
                self.record_usage(payload)
                for item in payload["output"]:
                    for part in item.get("content", []):
                        if part.get("type") == "output_text":
                            return json.loads(part["text"])
                raise ValueError("No structured output")
            response = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={"x-api-key": self.settings.anthropic_api_key.get_secret_value(),
                         "anthropic-version": "2023-06-01"},
                json={"model": model, "max_tokens": 600, "system": instruction,
                      "messages": [{"role": "user", "content": serialized}],
                      "tools": [{"name": purpose, "description": "Выбор из разрешённого списка",
                                 "input_schema": schema}],
                      "tool_choice": {"type": "tool", "name": purpose}},
            )
            response.raise_for_status()
            payload = response.json()
            self.record_usage(payload)
            for item in payload["content"]:
                if item.get("type") == "tool_use" and item.get("name") == purpose:
                    return item["input"]
            raise ValueError("No structured tool result")

    def vision_enabled(self):
        if self.settings.demo_mode or self.settings.data_source != "synthetic" or not self.settings.llm_model_vision:
            return False
        return bool(self.settings.openai_api_key.get_secret_value()) if self.settings.llm_provider == "openai" else (
            bool(self.settings.anthropic_api_key.get_secret_value()) if self.settings.llm_provider == "anthropic" else False)

    async def inspect_photo(self, prompt: dict, before_jpeg: bytes | None, after_jpeg: bytes):
        if not self.vision_enabled():
            return None
        serialized = json.dumps(prompt, ensure_ascii=False, sort_keys=True)
        identity = hashlib.sha256(serialized.encode() + (before_jpeg or b"") + after_jpeg).hexdigest()
        provider = self.settings.llm_provider
        model = self.settings.llm_model_vision
        cache_key = hashlib.sha256(f"vision:{provider}:{model}:{identity}".encode()).hexdigest()
        cached = self.store.get_cached(cache_key)
        if cached is not None:
            try:
                result = VisionAssessment.model_validate(cached)
                self.cache_hits += 1
                return result
            except ValidationError:
                pass
        for attempt in range(2):
            started = time.perf_counter()
            self.request_count += 1
            try:
                payload = await self._request_vision(serialized, before_jpeg, after_jpeg)
                result = VisionAssessment.model_validate(payload)
                self.store.put_cached(cache_key, provider, model, result.model_dump(mode="json"))
                return result
            except (httpx.HTTPError, KeyError, ValueError, ValidationError, TypeError) as error:
                LOG.warning("Vision interpretation failed on attempt %s: %s", attempt + 1, type(error).__name__)
            finally:
                self.request_latencies_ms.append(round((time.perf_counter() - started) * 1000, 2))
        return None

    async def _request_vision(self, serialized: str, before_jpeg: bytes | None, after_jpeg: bytes):
        after_base64 = base64.b64encode(after_jpeg).decode("ascii")
        before_base64 = base64.b64encode(before_jpeg).decode("ascii") if before_jpeg else None
        instruction = ("Оцени только видимое на фото: аккуратность, мусор, незакреплённые элементы, кожухи. "
                       "Не делай выводов о невидимых дефектах, не пиши цифры или имена в пояснении. "
                       "Если фото до нет или сравнение неубедительно, верни null для неподтверждённого вывода.")
        async with httpx.AsyncClient(timeout=20, transport=self.transport) as client:
            if self.settings.llm_provider == "openai":
                content = [{"type": "input_text", "text": serialized}]
                if before_base64:
                    content.append({"type": "input_text", "text": "Фото до"})
                    content.append({"type": "input_image", "image_url": f"data:image/jpeg;base64,{before_base64}"})
                content.append({"type": "input_text", "text": "Фото после"})
                content.append({"type": "input_image", "image_url": f"data:image/jpeg;base64,{after_base64}"})
                response = await client.post(
                    "https://api.openai.com/v1/responses",
                    headers={"Authorization": f"Bearer {self.settings.openai_api_key.get_secret_value()}"},
                    json={"model": self.settings.llm_model_vision, "store": False,
                          "input": [{"role": "system", "content": instruction},
                                    {"role": "user", "content": content}],
                          "text": {"format": {"type": "json_schema", "name": "maintenance_photo_review",
                                              "strict": True, "schema": VISION_SCHEMA}}},
                )
                response.raise_for_status()
                payload = response.json()
                self.record_usage(payload)
                for item in payload["output"]:
                    for part in item.get("content", []):
                        if part.get("type") == "output_text":
                            return json.loads(part["text"])
                raise ValueError("No structured vision output")
            content = [{"type": "text", "text": serialized}]
            if before_base64:
                content.append({"type": "text", "text": "Фото до"})
                content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                               "data": before_base64}})
            content.append({"type": "text", "text": "Фото после"})
            content.append({"type": "image", "source": {"type": "base64", "media_type": "image/jpeg",
                                                           "data": after_base64}})
            response = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={"x-api-key": self.settings.anthropic_api_key.get_secret_value(),
                         "anthropic-version": "2023-06-01"},
                json={"model": self.settings.llm_model_vision, "max_tokens": 700, "system": instruction,
                      "messages": [{"role": "user", "content": content}],
                      "tools": [{"name": "maintenance_photo_review", "description": "Структурированная оценка фото",
                                 "input_schema": VISION_SCHEMA}],
                      "tool_choice": {"type": "tool", "name": "maintenance_photo_review"}},
            )
            response.raise_for_status()
            payload = response.json()
            self.record_usage(payload)
            for item in payload["content"]:
                if item.get("type") == "tool_use" and item.get("name") == "maintenance_photo_review":
                    return item["input"]
            raise ValueError("No vision tool result")

    async def interpret(self, prompt: dict) -> SemanticAssessment | None:
        if not self.enabled():
            return None
        serialized = json.dumps(prompt, ensure_ascii=False, sort_keys=True)
        provider = self.settings.llm_provider
        model = self.settings.llm_model_fast
        key = hashlib.sha256(f"{provider}:{model}:{serialized}".encode()).hexdigest()
        cached = self.store.get_cached(key)
        if cached is not None:
            try:
                result = SemanticAssessment.model_validate(cached)
                self.cache_hits += 1
                return result
            except ValidationError:
                pass
        for attempt in range(2):
            started = time.perf_counter()
            self.request_count += 1
            try:
                payload = await self._request(serialized)
                result = SemanticAssessment.model_validate(payload)
                self.store.put_cached(key, provider, model, result.model_dump(mode="json"))
                return result
            except (httpx.HTTPError, KeyError, ValueError, ValidationError, TypeError) as error:
                LOG.warning("LLM interpretation failed on attempt %s: %s", attempt + 1, type(error).__name__)
            finally:
                self.request_latencies_ms.append(round((time.perf_counter() - started) * 1000, 2))
        return None

    def record_usage(self, payload):
        usage = payload.get("usage") or {}
        self.input_tokens += usage.get("input_tokens", 0) or 0
        self.output_tokens += usage.get("output_tokens", 0) or 0

    async def _request(self, serialized: str):
        async with httpx.AsyncClient(timeout=20, transport=self.transport) as client:
            if self.settings.llm_provider == "openai":
                response = await client.post(
                    "https://api.openai.com/v1/responses",
                    headers={"Authorization": f"Bearer {self.settings.openai_api_key.get_secret_value()}"},
                    json={"model": self.settings.llm_model_fast, "store": False,
                          "input": [{"role": "system", "content": "Сравни смысл проблемы и выполненной работы. Не придумывай факты, ID и числа. Не пиши цифры в пояснениях. Ссылайся только на предоставленные evidence_ref."},
                                    {"role": "user", "content": serialized}],
                          "text": {"format": {"type": "json_schema", "name": "maintenance_review",
                                              "strict": True, "schema": SEMANTIC_SCHEMA}}},
                )
                response.raise_for_status()
                payload = response.json()
                self.record_usage(payload)
                output = payload["output"]
                for item in output:
                    for content in item.get("content", []):
                        if content.get("type") == "output_text":
                            return json.loads(content["text"])
                raise ValueError("No structured output text")
            response = await client.post(
                "https://api.anthropic.com/v1/messages",
                headers={"x-api-key": self.settings.anthropic_api_key.get_secret_value(),
                         "anthropic-version": "2023-06-01"},
                json={"model": self.settings.llm_model_fast, "max_tokens": 700,
                      "system": "Сравни смысл проблемы и работы. Не придумывай факты, ID и числа. Не пиши цифры в пояснениях.",
                      "messages": [{"role": "user", "content": serialized}],
                      "tools": [{"name": "maintenance_review", "description": "Вернуть структурированную оценку смысла",
                                 "input_schema": SEMANTIC_SCHEMA}],
                      "tool_choice": {"type": "tool", "name": "maintenance_review"}},
            )
            response.raise_for_status()
            payload = response.json()
            self.record_usage(payload)
            for item in payload["content"]:
                if item.get("type") == "tool_use" and item.get("name") == "maintenance_review":
                    return item["input"]
            raise ValueError("No tool result")
