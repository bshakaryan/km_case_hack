import os

import httpx
from fastapi import HTTPException
from fastapi.responses import JSONResponse


async def call_ai(method: str, path: str, *, params: dict | None = None, payload: dict | None = None):
    token = os.getenv("AI_SERVICE_TOKEN", "")
    if not token:
        raise HTTPException(503, "ИИ-сервис не настроен")
    base_url = os.getenv("AI_SERVICE_URL", "http://ai:8090").rstrip("/")
    try:
        async with httpx.AsyncClient(base_url=base_url, timeout=45) as client:
            response = await client.request(method, path,
                                            params={key: value for key, value in (params or {}).items() if value is not None},
                                            json=payload,
                                            headers={"Authorization": f"Bearer {token}"})
    except httpx.TimeoutException as error:
        raise HTTPException(504, "ИИ-сервис не ответил вовремя") from error
    except httpx.RequestError as error:
        raise HTTPException(503, "ИИ-сервис недоступен") from error
    if response.status_code >= 400:
        try:
            detail = response.json().get("detail", "ИИ-сервис вернул ошибку")
        except (ValueError, AttributeError):
            detail = "ИИ-сервис вернул ошибку"
        raise HTTPException(response.status_code, detail)
    return JSONResponse(response.json(), status_code=response.status_code,
                        headers={"Cache-Control": "private, no-store"})
