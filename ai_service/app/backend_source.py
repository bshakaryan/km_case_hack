import asyncio
import re

import httpx

from .datasource import DataSource, DataSourceError, IncompleteHistory
from .schemas import PhotoRecord, Snapshot


class BackendDataSource(DataSource):
    def __init__(self, base_url: str, token: str, transport: httpx.AsyncBaseTransport | None = None):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.transport = transport

    def _client(self):
        if not self.token:
            raise DataSourceError("BACKEND_TOKEN не задан; доступ к API НарядAI закрыт")
        return httpx.AsyncClient(
            base_url=self.base_url,
            headers={"Authorization": f"Bearer {self.token}"},
            timeout=20,
            transport=self.transport,
        )

    @staticmethod
    async def _get(client: httpx.AsyncClient, path: str, params: dict | None = None):
        try:
            response = await client.get(path, params=params)
            response.raise_for_status()
            return response
        except httpx.HTTPStatusError as error:
            raise DataSourceError(f"API НарядAI вернул HTTP {error.response.status_code} для {path}") from error
        except httpx.RequestError as error:
            raise DataSourceError(f"API НарядAI недоступен для {path}") from error

    async def snapshot(self) -> Snapshot:
        async with self._client() as client:
            reference = (await self._get(client, "/api/reference")).json()
            orders = (await self._get(client, "/api/orders", {"limit": 5000})).json()
            if len(orders) >= 5000:
                raise IncompleteHistory("API ограничил список 5000 нарядами; полная история не подтверждена")
            semaphore = asyncio.Semaphore(8)

            async def detail(order):
                async with semaphore:
                    return (await self._get(client, f"/api/orders/{order['id']}")).json()

            detailed_orders = await asyncio.gather(*(detail(order) for order in orders))
        return Snapshot.model_validate({**reference, "orders": detailed_orders})

    async def photo_bytes(self, photo: PhotoRecord) -> bytes:
        if not photo.url or not re.fullmatch(r"/api/photos/\d+", photo.url):
            raise DataSourceError("Недопустимая ссылка на фото НарядAI")
        async with self._client() as client:
            return (await self._get(client, photo.url)).content
