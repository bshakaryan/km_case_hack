"""Exercise the running API with real persistence. Creates one clearly named test order.

Usage: python3 scripts/smoke_api.py [http://localhost:8000]
Uses only the Python standard library. Requires the seeded demo accounts.
"""
import base64
import io
import json
import sys
import urllib.error
import urllib.request
import zipfile
from datetime import datetime, timedelta, timezone

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:8000").rstrip("/")


def request(path, token=None, data=None, expected=200, raw=False, method=None, content_type=None, expected_version=None):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if expected_version is not None:
        headers["X-Expected-Order-Version"] = str(expected_version)
    if data is not None:
        if not isinstance(data, bytes):
            data = json.dumps(data).encode()
            headers["Content-Type"] = "application/json"
        else:
            headers["Content-Type"] = content_type or "application/octet-stream"
    req = urllib.request.Request(BASE + path, data=data, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    payload = response.read()
    allowed = expected if isinstance(expected, tuple) else (expected,)
    assert response.status in allowed, f"{req.get_method()} {path}: {response.status}, expected {expected}: {payload[:500]!r}"
    return payload if raw else json.loads(payload)


def main():
    request("/api/health")
    request("/api/orders", expected=401)
    users = {
        role: request("/api/auth/login", data={"login": role, "pin": "1234"})
        for role in ("master", "worker2", "worker3", "manager", "admin")
    }
    master, worker = users["master"]["token"], users["worker2"]["token"]
    refs = request("/api/reference", master)
    assert len(refs["areas"]) >= 4 and len(refs["equipment"]) >= 25
    assert len(refs["materials"]) >= 40 and len(refs["fault_codes"]) >= 20
    # Explicit seed IDs must not leave PostgreSQL sequences pointing at occupied IDs.
    area = request("/api/reference/areas", users["admin"]["token"],
                   {"name": "Проверка API " + datetime.now(timezone.utc).isoformat()}, expected=(200, 201))
    assert area["id"] > 4
    request(f"/api/reference/areas/{area['id']}", users["manager"]["token"],
            {"name": "Недопустимое изменение"}, method="PATCH", expected=403)
    all_orders = request("/api/orders?limit=1000", master)
    assert len(all_orders) >= 500
    equipment = refs["equipment"][0]
    payload = {
        "title": "Проверка API: ремонт насоса",
        "description": "Тест полного цикла: устранить течь масла и проверить соединения.",
        "work_type": "unplanned", "area_id": equipment["area_id"],
        "equipment_id": equipment["id"], "assignee_id": users["worker2"]["user"]["id"],
        "priority": "high", "deadline": (datetime.now(timezone.utc) + timedelta(hours=3)).isoformat(),
        "normal_hours": 2,
    }
    request("/api/orders", users["manager"]["token"], payload, expected=403)
    order = request("/api/orders", master, payload, expected=(200, 201))
    path = f"/api/orders/{order['id']}"
    assert order["status"] == "issued"
    request(path, users["worker3"]["token"], expected=403)
    order = request(path + "/transition", worker, {"action": "accept"}, expected_version=order["version"])
    order = request(path + "/transition", worker, {"action": "start"}, expected_version=order["version"])
    completion = {
        "work_done": "Заменили уплотнение, очистили корпус и проверили соединения под нагрузкой. Течь устранена.",
        "fault_code_id": refs["fault_codes"][0]["id"],
        "materials": [{"material_id": refs["materials"][0]["id"], "quantity": 1}],
        "comment": "Автоматическая проверка HTTP API",
    }
    request(path + "/complete", worker, completion, expected=422, expected_version=order["version"])
    boundary = "naryad-smoke-photo-boundary"
    png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAIAAAAC64paAAAAK0lEQVR4nGPUDXVkIBcwka2TYVQzyYCJdC0IMKqZRMBEqgZkMKqZRECRZgAEAgDrVmwbbAAAAABJRU5ErkJggg==")
    body = (f"--{boundary}\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\nafter\r\n"
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"test.png\"\r\n"
            "Content-Type: image/png\r\n\r\n").encode() + png + f"\r\n--{boundary}--\r\n".encode()
    photo = request(path + "/photos", worker, body, expected=(200, 201), content_type=f"multipart/form-data; boundary={boundary}", expected_version=order["version"])
    order["version"] = photo["order_version"]
    request(f"/api/photos/{photo['id']}", expected=401)
    assert request(f"/api/photos/{photo['id']}", worker, raw=True).startswith(b"\xff\xd8")
    order = request(path + "/complete", worker, completion, expected_version=order["version"])
    assert order["status"] == "completed"
    assert "ai_review" not in order
    request(path + "/transition", worker, {"action": "close", "score": 5}, expected=403, expected_version=order["version"])
    order = request(path + "/transition", master, {"action": "close", "score": 5}, expected_version=order["version"])
    assert order["status"] == "closed" and len(order["events"]) >= 6
    report = request("/api/reports/export?format=xlsx", master, raw=True)
    assert zipfile.is_zipfile(io.BytesIO(report)), "Excel export must be a real XLSX archive"
    analytics = request("/api/analytics?days=90", master)
    assert analytics["summary"]["total"] >= 500 and analytics["insight_method"] == "deterministic_rules"
    request("/api/notifications", worker)
    integrations = request("/api/integrations", master)
    assert set(integrations) == {"native", "realtime"}
    assert integrations["native"]["mode"] in ("disabled", "fcm")
    print(f"PASS: auth, RBAC, seed, full lifecycle, mandatory photo, protected media, audit, Excel, analytics. Order {order['number']}.")


if __name__ == "__main__":
    main()
