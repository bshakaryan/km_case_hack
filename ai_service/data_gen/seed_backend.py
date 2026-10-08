"""Explicit, loopback-only API import; historical events cannot be reconstructed."""

import argparse
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlparse

import httpx
from dotenv import load_dotenv


BASE = Path(__file__).resolve().parents[1]


def request(client, method, path, **kwargs):
    response = client.request(method, path, **kwargs)
    response.raise_for_status()
    return response.json()


def import_reference(client, snapshot, pin):
    live = request(client, "GET", "/api/reference")
    mapping = {}
    for collection in ["areas", "brigades", "employees", "equipment", "fault_codes", "materials", "time_norms"]:
        mapping[collection] = {}
        existing = {
            item["login"] if collection == "employees" else
            item["inventory_number"] if collection == "equipment" else
            item["code"] if collection == "fault_codes" else item["name"]: item
            for item in live[collection]
        }
        for item in snapshot[collection]:
            if collection == "equipment":
                key = f"AI-KM-{item['id']:03}"
            elif collection == "employees":
                key = item["login"]
            elif collection == "fault_codes":
                key = item["code"]
            else:
                key = item["name"]
            if key in existing:
                target = existing[key]
            else:
                payload = {field: value for field, value in item.items() if field != "id"}
                if collection == "equipment":
                    payload["inventory_number"] = key
                    payload["area_id"] = mapping["areas"][item["area_id"]]
                elif collection == "employees":
                    payload["pin"] = pin
                    if item["brigade_id"] is not None:
                        payload["brigade_id"] = mapping["brigades"][item["brigade_id"]]
                target = request(client, "POST", f"/api/reference/{collection}", json=payload)
                existing[key] = target
            mapping[collection][item["id"]] = target["id"]
    return mapping


def import_orders(client, snapshot, mapping, limit):
    existing_orders = request(client, "GET", "/api/orders", params={"limit": 5000})
    if len(existing_orders) >= 5000:
        raise RuntimeError("Список API достиг лимита 5000; безопасная дедупликация невозможна")
    existing_titles = {order["title"] for order in existing_orders}
    imported = 0
    for order in snapshot["orders"][:limit]:
        title = f"[AI-DATA-{order['id']:05}] {order['title']}"
        if title in existing_titles:
            continue
        deadline = datetime.now(timezone.utc) + timedelta(days=180, minutes=order["id"])
        payload = {
            "title": title, "description": order["description"], "work_type": order["work_type"],
            "area_id": mapping["areas"][order["area_id"]],
            "equipment_id": mapping["equipment"][order["equipment_id"]],
            "assignee_id": mapping["employees"][order["assignee_id"]],
            "priority": order["priority"], "deadline": deadline.isoformat(),
            "normal_hours": order["normal_hours"],
            "comment": "Синтетический импорт через публичный API; исходная история/оценки/фото не перенесены.",
        }
        request(client, "POST", "/api/orders", json=payload)
        imported += 1
    return imported


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", required=True, help="Только localhost/127.0.0.1")
    parser.add_argument("--confirm", required=True, help="Точная фраза: IMPORT_SYNTHETIC_ORDERS")
    parser.add_argument("--limit", type=int, default=0, help="0 означает весь снимок")
    arguments = parser.parse_args()
    parsed = urlparse(arguments.base_url)
    if arguments.confirm != "IMPORT_SYNTHETIC_ORDERS" or parsed.scheme != "http" or parsed.hostname not in {"localhost", "127.0.0.1"} or parsed.username or parsed.password:
        parser.error("Импорт разрешён только для локального HTTP и с точным подтверждением")
    if arguments.limit < 0:
        parser.error("--limit не может быть отрицательным")
    load_dotenv(BASE / ".env", override=False)
    token = os.getenv("BACKEND_TOKEN")
    pin = os.getenv("SEED_WORKER_PIN")
    if not token or not pin or not pin.isdigit() or not 4 <= len(pin) <= 12:
        parser.error("Нужны BACKEND_TOKEN администратора и SEED_WORKER_PIN (4–12 цифр) в среде")
    snapshot_path = BASE / "data" / "snapshot.json"
    if not snapshot_path.exists():
        parser.error("Сначала запустите make data")
    snapshot = json.loads(snapshot_path.read_text(encoding="utf-8"))
    with httpx.Client(base_url=arguments.base_url.rstrip("/"), timeout=30,
                      headers={"Authorization": f"Bearer {token}"}, trust_env=False) as client:
        identity = request(client, "GET", "/api/auth/me")
        if identity["role"] != "admin":
            parser.error("Для создания справочников нужен токен администратора")
        mapping = import_reference(client, snapshot, pin)
        imported = import_orders(client, snapshot, mapping, arguments.limit or len(snapshot["orders"]))
    print(f"Создано {imported} синтетических нарядов в локальном API. Исторические события/фото не импортированы.")


if __name__ == "__main__":
    main()
