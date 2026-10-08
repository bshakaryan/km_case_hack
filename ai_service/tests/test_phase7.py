import asyncio

import httpx

from app.config import Settings
from app.llm_client import LLMClient
from app.schemas import EmployeeRecord
from app.storage import AIStore


def test_backend_source_cannot_send_text_or_images_to_external_llm():
    requests = []

    def handler(request):
        requests.append(request)
        return httpx.Response(200, json={})

    store = AIStore("sqlite:///:memory:")
    store.initialize()
    settings = Settings(data_source="backend", demo_mode=False, llm_provider="openai",
                        llm_model_fast="mock-text", llm_model_vision="mock-vision",
                        openai_api_key="mock-key")
    client = LLMClient(settings, store, httpx.MockTransport(handler))
    assert not client.enabled()
    assert not client.safe_text_enabled()
    assert not client.vision_enabled()
    assert asyncio.run(client.interpret({"problem": "производственный текст"})) is None
    assert asyncio.run(client.inspect_photo({}, None, b"image")) is None
    assert requests == []
    store.close()


def test_optional_prompt_redaction_covers_directory_and_structured_identifiers():
    employee = EmployeeRecord(id=7, name="Ахметов Ержан", role="worker", login="worker_700")
    original = "Ахметов Ержан worker_700, +7 701 123 45 67, a@example.com, таб. №12345"
    redacted = LLMClient.redact(original, [employee])
    for secret in (employee.name, employee.login, "701", "a@example.com", "12345"):
        assert secret not in redacted
