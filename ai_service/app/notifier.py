import logging
from typing import Protocol

import httpx


LOG = logging.getLogger(__name__)


class Notifier(Protocol):
    async def send(self, recipient: str, title: str, message: str, idempotency_key: str) -> bool:
        ...


class LogNotifier:
    async def send(self, recipient: str, title: str, message: str, idempotency_key: str) -> bool:
        LOG.info("Notification not delivered: recipient=%s key=%s title=%s message=%s",
                 recipient, idempotency_key, title, message)
        return False


class TelegramNotifier:
    def __init__(self, token: str, chat_ids: dict[str, str], transport: httpx.AsyncBaseTransport | None = None):
        self.token = token
        self.chat_ids = chat_ids
        self.transport = transport

    async def send(self, recipient: str, title: str, message: str, idempotency_key: str) -> bool:
        chat_id = self.chat_ids.get(recipient)
        if not self.token or not chat_id:
            return False
        try:
            async with httpx.AsyncClient(timeout=10, transport=self.transport) as client:
                response = await client.post(f"https://api.telegram.org/bot{self.token}/sendMessage",
                                             json={"chat_id": chat_id, "text": f"{title}\n{message}"})
                response.raise_for_status()
                return bool(response.json().get("ok"))
        except (httpx.HTTPError, ValueError):
            LOG.exception("Telegram notification failed: recipient=%s key=%s", recipient, idempotency_key)
            return False
