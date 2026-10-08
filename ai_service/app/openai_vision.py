"""Small, stateless OpenAI Responses API adapter for submission photo pairs."""
from __future__ import annotations

import base64
import json
import re

import httpx
from pydantic import SecretStr, ValidationError

from .llm_client import VISION_SCHEMA, VisionAssessment

OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses"
REQUEST_TIMEOUT_SECONDS = 20


class OpenAIVisionError(RuntimeError):
    pass


class OpenAIVisionReviewer:
    def __init__(self, api_key: SecretStr | str, model: str, transport=None):
        self._api_key = api_key.get_secret_value() if isinstance(api_key, SecretStr) else str(api_key or "")
        self.model = model.strip()
        self.transport = transport

    @property
    def configured(self):
        return bool(self._api_key and self.model)

    async def review(self, before_jpeg: bytes | None, after_jpeg: bytes):
        if not self.configured:
            raise OpenAIVisionError("openai_vision_not_configured")
        if not after_jpeg:
            raise OpenAIVisionError("openai_vision_invalid_input")

        instruction = (
            "Сравни только наблюдаемые признаки на переданных фотографиях. Фото до используй только для "
            "визуального сравнения оборудования и заявленного видимого дефекта; чек-лист качества заполняй "
            "только по фото после. Не устанавливай факт ремонта, скрытое техническое состояние, безопасность "
            "или время съёмки. same_equipment=true означает лишь визуальное сходство. defect_resolved=true "
            "только если один и тот же хорошо различимый дефект виден до и не виден после; false — если "
            "он явно остаётся; иначе null. Для каждого visual_criteria пункта выбери issue_visible, "
            "no_visible_issue или not_assessable. no_visible_issue значит только «не видно на этом снимке», "
            "а не доказанное отсутствие проблемы. cleanliness — чистота/мусор/пятна; fasteners — только "
            "видимое наличие и положение креплений (не затяжка); guards — видимые кожухи/ограждения; "
            "leakage — видимые следы жидкости, не их источник. Если критерий не виден или ракурс недостаточен, "
            "выставь not_assessable. observation для каждого пункта — короткий факт либо пустая строка. "
            "issues используй только для дополнительных замечаний, не дублируй чек-лист. explanation — "
            "одно короткое нейтральное резюме. quality — только общее визуальное впечатление о фото после, "
            "не балл и не оценка безопасности. Не придумывай детали, имена или числа, не описывай людей; "
            "пиши по-русски. Если фото до отсутствует, same_equipment и defect_resolved должны быть null."
        )
        content = []
        if before_jpeg is not None:
            content.extend([
                {"type": "input_text", "text": "Фото до ремонта:"},
                {"type": "input_image", "detail": "high",
                 "image_url": self._data_url(before_jpeg)},
            ])
        content.extend([
            {"type": "input_text", "text": "Фото после выполнения:"},
            {"type": "input_image", "detail": "high",
             "image_url": self._data_url(after_jpeg)},
        ])
        request = {
            "model": self.model,
            "store": False,
            "input": [
                {"role": "system", "content": instruction},
                {"role": "user", "content": content},
            ],
            "text": {"format": {"type": "json_schema", "name": "maintenance_photo_review",
                                 "strict": True, "schema": VISION_SCHEMA}},
        }
        try:
            async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS, transport=self.transport,
                                         follow_redirects=False, trust_env=False) as client:
                response = await client.post(
                    OPENAI_RESPONSES_URL,
                    headers={"Authorization": f"Bearer {self._api_key}"},
                    json=request,
                )
                response.raise_for_status()
                payload = response.json()
            output = [part["text"] for item in payload.get("output", [])
                      for part in item.get("content", []) if part.get("type") == "output_text"]
            if len(output) != 1:
                raise ValueError("invalid_vision_output")
            assessment = VisionAssessment.model_validate(json.loads(output[0]), strict=True)
            prose = " ".join([assessment.explanation, *assessment.issues])
            if re.search(r"\d", prose) or len(assessment.issues) > 8:
                raise ValueError("invalid_vision_output")
            return assessment
        except (httpx.HTTPError, ValueError, TypeError, KeyError, ValidationError):
            # Do not expose request, image bytes, provider response or key in errors/logs.
            raise OpenAIVisionError("openai_vision_request_failed") from None

    @staticmethod
    def _data_url(image: bytes):
        return "data:image/jpeg;base64," + base64.b64encode(image).decode("ascii")
