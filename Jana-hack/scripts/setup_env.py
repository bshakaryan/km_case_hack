"""Generate local secrets once. Deliberately refuses to overwrite existing .env."""
import secrets
from pathlib import Path

path = Path(__file__).resolve().parents[1] / ".env"
with path.open("x", encoding="utf-8") as file:
    file.write(
        f"POSTGRES_PASSWORD={secrets.token_hex(24)}\n"
        f"JWT_SECRET={secrets.token_hex(32)}\n"
        f"DEMO_PASSWORD={secrets.token_urlsafe(18)}\n"
        f"ZUP_API_TOKEN={secrets.token_hex(32)}\n"
        "ZUP_MODE=mock\n"
        "ZUP_AUTH_TYPE=bearer\n"
        "DATABASE_URL=sqlite:///./jana.db\n"
    )
path.chmod(0o600)
print("Создан .env. Демо-пароль смотрите локально в DEMO_PASSWORD; не отправляйте его в Git.")
