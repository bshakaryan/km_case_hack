"""Local launcher loads the same .env as backend without exposing its JWT key."""
import os

import uvicorn

from app.config import get_settings
from app.mock_zup import create_mock_app


if __name__ == "__main__":
    token = get_settings().zup_api_token
    if not token:
        raise SystemExit("Задайте ZUP_API_TOKEN в .env (минимум 32 символа)")
    app = create_mock_app(os.environ.get("ZUP_MOCK_DATABASE", "./zup-mock.sqlite3"), token)
    uvicorn.run(app, host="127.0.0.1", port=8300)
