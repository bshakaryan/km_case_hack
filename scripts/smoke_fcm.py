"""Server-side FCM connectivity smoke test with a fake registration token.

Usage: .venv/bin/python scripts/smoke_fcm.py
Starts a throwaway local API instance (temporary SQLite database, seeded demo
data), registers a deliberately fake device token, assigns an order to that
worker and checks that the push dispatcher really reaches Firebase: OAuth
exchange, egress to fcm.googleapis.com and invalid-token handling — the push
task must end failed and the fake device must be revoked.
Skips with a clear message when no service-account credentials are configured.
Uses only the Python standard library.
"""
import importlib.util
import json
import os
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BACKEND = os.path.join(ROOT, "backend")
SECRETS = os.path.join(BACKEND, "secrets")
CLOCK_HOSTS = ("https://fcm.googleapis.com/", "https://oauth2.googleapis.com/")
FAKE_TOKEN = "fake-invalid-token-smoke"
# Substrings that prove a real FCM answer (not a local/network failure).
FCM_MARKERS = ("was not found", "registration token", "not a valid", "UNREGISTERED", "NOT_FOUND", "INVALID_ARGUMENT")
# Errors that mean the send never reached FCM or stopped before FCM replied.
BANNED_MARKERS = ("invalid_grant", "no_active_device", "transient")


def request(base, path, token=None, data=None, expected=200, method=None):
    headers = {}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base + path, data=body, headers=headers, method=method)
    try:
        response = urllib.request.urlopen(req, timeout=30)
    except urllib.error.HTTPError as error:
        response = error
    payload = response.read()
    allowed = expected if isinstance(expected, tuple) else (expected,)
    assert response.status in allowed, f"{req.get_method()} {path}: {response.status}, expected {expected}: {payload[:500]!r}"
    return json.loads(payload)


def resolve_credentials():
    inline = (os.getenv("FIREBASE_CREDENTIALS_JSON") or "").strip()
    if inline:
        try:
            json.loads(inline)
            return "json", inline
        except ValueError:
            print("Внимание: FIREBASE_CREDENTIALS_JSON — не валидный JSON; пробуем путь.")
    path = os.getenv("FIREBASE_CREDENTIALS") or ""
    if path and os.path.isfile(path):
        return "file", path
    if os.path.isdir(SECRETS):
        keys = sorted(name for name in os.listdir(SECRETS) if name.endswith(".json"))
        if keys:
            return "file", os.path.join(SECRETS, keys[0])
    return None, None


def probe_clock():
    """Return (skew_seconds, reachable_hosts). skew = local_clock - real_clock."""
    reachable, dates = [], {}
    for host in CLOCK_HOSTS:
        try:
            with urllib.request.urlopen(urllib.request.Request(host, method="HEAD"), timeout=10) as resp:
                date = resp.headers.get("Date")
        except urllib.error.HTTPError as error:
            date = error.headers.get("Date")
        except Exception as error:
            print(f"  {host}: недоступен ({error})")
            continue
        reachable.append(host.rstrip("/"))
        dates[host] = date or ""
        print(f"  {host}: доступен, Date: {date}")
    if not any(dates.values()):
        return None, reachable
    local = datetime.now(timezone.utc)
    skews = []
    for date in dates.values():
        if not date:
            continue
        remote = datetime.strptime(date, "%a, %d %b %Y %H:%M:%S GMT").replace(tzinfo=timezone.utc)
        skews.append((local - remote).total_seconds())
    return sum(skews) / len(skews), reachable


def free_port():
    for port in range(8123, 8160):
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", port))
            except OSError:
                continue
            return port
    raise RuntimeError("нет свободного порта в диапазоне 8123-8159")


def start_server(port, db_path, cred_kind, cred_value, skew):
    env = dict(os.environ)
    env.pop("FIREBASE_CREDENTIALS", None)
    env.pop("FIREBASE_CREDENTIALS_JSON", None)
    env.update(
        DATABASE_URL=f"sqlite:///{db_path}",
        SEED_DEMO="true",
        FIREBASE_PROJECT_ID=os.getenv("FIREBASE_PROJECT_ID", "km-case-hack"),
        PUSH_ENABLED="true",
        PUSH_DISPATCH_SECONDS="2",
        PYTHONUNBUFFERED="1",
    )
    env["FIREBASE_CREDENTIALS_JSON" if cred_kind == "json" else "FIREBASE_CREDENTIALS"] = cred_value
    patch = ""
    if skew is not None and abs(skew) > 60:
        patch = (
            "import datetime as _dt\n"
            "import google.auth._helpers as _h\n"
            "_orig = _h.utcnow\n"
            f"_h.utcnow = lambda: _orig() - _dt.timedelta(seconds={int(skew)})\n"
        )
    code = (
        f"import sys; sys.path.insert(0, {BACKEND!r})\n"
        + patch
        + "import uvicorn\n"
        f"uvicorn.run('app.main:app', host='127.0.0.1', port={port}, log_level='info')\n"
    )
    log = open(os.path.join(tempfile.mkdtemp(prefix="fcm_smoke_"), "server.log"), "w")
    proc = subprocess.Popen([sys.executable, "-c", code], cwd=BACKEND, env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    return proc, log


def stop_server(proc, log):
    if proc.poll() is None:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
            proc.wait(timeout=10)
        except Exception:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait(timeout=5)
            except Exception:
                pass
    path = log.name
    try:
        log.close()
    except Exception:
        pass
    try:
        with open(path) as handle:
            tail = handle.read().splitlines()[-15:]
        print("--- server log tail ---")
        print("\n".join(tail))
    except Exception:
        pass


def rows(db_path, sql, args=()):
    con = sqlite3.connect(db_path, timeout=10)
    con.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in con.execute(sql, args)]
    finally:
        con.close()


def wait_health(base, proc, timeout=90):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if proc.poll() is not None:
            raise RuntimeError(f"сервер завершился при старте (код {proc.returncode}); см. server log")
        try:
            request(base, "/api/health")
            return
        except Exception:
            time.sleep(0.25)
    raise AssertionError("сервер не ответил на /api/health за 90 с")


def main():
    kind, value = resolve_credentials()
    if kind is None:
        print("SKIP: FIREBASE_CREDENTIALS / FIREBASE_CREDENTIALS_JSON не заданы и backend/secrets/*.json не найден; смоук FCM пропущен.")
        return 0
    if importlib.util.find_spec("google.auth") is None:
        print("SKIP: google-auth не установлен; выполните .venv/bin/python -m pip install -r backend/requirements.txt")
        return 0
    print(f"Учётные данные: {'inline JSON' if kind == 'json' else value}")
    print("Проверка времени и хостов Google:")
    skew, reachable = probe_clock()
    if skew is None:
        print("Внимание: Date-заголовок не получен; попытка отправки покажет точную ошибку.")
    elif abs(skew) > 60:
        print(f"Внимание: часы хоста отстают/опережают реальное время на {int(skew)} с; для смоука применяется внутрипроцессная коррекция (не исправляет системные часы).")
    else:
        print(f"Часы в норме (расхождение {int(skew)} с).")

    workdir = tempfile.mkdtemp(prefix="fcm_smoke_")
    db_path = os.path.join(workdir, "fcm_smoke.db")
    port = free_port()
    base = f"http://127.0.0.1:{port}"
    proc, log = start_server(port, db_path, kind, value, skew if skew is not None else 0.0)
    try:
        wait_health(base, proc)
        users = {role: request(base, "/api/auth/login", data={"login": role, "pin": "1234"}) for role in ("master", "worker2")}
        master, worker = users["master"]["token"], users["worker2"]["token"]
        integrations = request(base, "/api/integrations", master)
        assert integrations["native"]["mode"] == "fcm", f"ожидался режим fcm, получен {integrations['native']}"
        print(f"integrations.native.mode = {integrations['native']['mode']}")
        # Let startup deadline notifications fail with no_active_device before the device exists.
        time.sleep(4)
        device = request(base, "/api/devices", token=worker, data={"token": FAKE_TOKEN, "platform": "android"}, expected=201)
        print(f"зарегистрирован фейковый токен: id={device['id']}")
        order = request(base, "/api/orders", token=master, data={
            "title": "SMOKE FCM: проверка доставки",
            "description": "Смоук-проверка серверной отправки push без реального устройства.",
            "work_type": "planned",
            "area_id": 1,
            "equipment_id": 1,
            "assignee_id": users["worker2"]["user"]["id"],
            "priority": "normal",
            "deadline": (datetime.now(timezone.utc) + timedelta(hours=2)).isoformat(),
        }, expected=(200, 201))
        print(f"наряд создан: id={order['id']} number={order.get('number')}")
        task = None
        deadline = time.time() + 30
        while time.time() < deadline:
            if proc.poll() is not None:
                raise RuntimeError(f"сервер завершился (код {proc.returncode}); см. server log")
            found = rows(db_path, "SELECT id, employee_id, kind, status, attempts, last_error, provider_message_id FROM push_tasks WHERE order_id=? ORDER BY id", (order["id"],))
            if found and found[0]["status"] != "pending":
                task = found[0]
                break
            time.sleep(0.5)
        assert task, "push_task для созданного наряда не завершился за 30 с"
        device_row = rows(db_path, "SELECT id, token, revoked_at FROM device_tokens WHERE token=?", (FAKE_TOKEN,))[0]
        logs = rows(db_path, "SELECT id, operation, payload FROM integration_logs WHERE adapter='fcm' AND operation='push_failed' ORDER BY id DESC")
        error = None
        fcm_log = None
        for entry in logs:
            payload = json.loads(entry["payload"]) if isinstance(entry["payload"], str) else entry["payload"]
            text = str(payload.get("error") or "")
            if text and not any(marker in text for marker in BANNED_MARKERS):
                fcm_log, error = entry, text
                break
        print("--- доказательства ---")
        print(f"final push_tasks: {task}")
        print(f"integration_logs: id={fcm_log['id'] if fcm_log else None} payload={fcm_log['payload'] if fcm_log else None}")
        print(f"device_tokens: id={device_row['id']} revoked_at={device_row['revoked_at']}")
        print(f"hosty dostupny: {', '.join(reachable) or 'нет'}")
        assert task["status"] == "failed", f"push_task должен быть failed, получен {task['status']}"
        assert device_row["revoked_at"], "фейковый токен не был отозван (revoked_at пуст)"
        assert error, "нет записи integration_logs с ошибкой, отличной от no_active_device/invalid_grant"
        assert not any(marker in error for marker in BANNED_MARKERS), f"отправка не дошла до FCM: {error}"
        assert any(marker in error for marker in FCM_MARKERS), f"неожиданная ошибка FCM: {error}"
        print("PASS: OAuth, egress и ответ FCM подтверждены; push_task failed, токен отозван.")
        return 0
    finally:
        stop_server(proc, log)
        shutil.rmtree(workdir, ignore_errors=True)
        shutil.rmtree(os.path.dirname(log.name), ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
