import dataclasses
import hashlib
import json
import logging
import os
from datetime import timedelta
from typing import Protocol

import httpx
from sqlalchemy import select

from .models import DeviceToken, IntegrationLog, Notification, Order, PushTask, utcnow

LOG = logging.getLogger(__name__)
FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
FCM_SEND_URL = "https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
FCM_ERROR_TYPE = "type.googleapis.com/google.firebase.fcm.v1.FcmError"


def env_flag(name, default="false"):
    return os.getenv(name, default).strip().lower() in {"true", "1", "yes", "on"}


def env_int(name, default):
    try:
        return int(os.getenv(name, str(default)))
    except (TypeError, ValueError):
        return default


def token_fingerprint(token):
    """Correlate delivery attempts without persisting device credentials."""
    return hashlib.sha256(token.encode("utf-8")).hexdigest()[:16]


@dataclasses.dataclass
class SendResult:
    ok: bool
    invalid_token: bool = False
    provider_message_id: str | None = None
    error: str | None = None


class PushSender(Protocol):
    def send(self, token: str, message: dict) -> SendResult: ...


class StubSender:
    """Never contacts a network provider; records an integration trace instead."""

    is_stub = True

    def __init__(self, db=None):
        self.db = db

    def bind(self, db):
        self.db = db

    def send(self, token: str, message: dict) -> SendResult:
        if self.db is not None:
            self.db.add(IntegrationLog(adapter="fcm", operation="push_not_sent", payload={"token_fingerprint": token_fingerprint(token), "kind": (message.get("data") or {}).get("kind"), "is_stub": True}))
        return SendResult(ok=True, invalid_token=False, provider_message_id=None, error=None)


class FcmSender:
    """Firebase Cloud Messaging HTTP v1 sender with a cached OAuth2 access token."""

    def __init__(self, project_id, credentials_path=None, credentials_info=None):
        self.project_id = project_id
        self.credentials_path = credentials_path
        self.credentials_info = credentials_info
        self._credentials = None
        self._google_request = None

    def _access_token(self):
        if self._credentials is None:
            from google.auth.transport.requests import Request as GoogleRequest
            from google.oauth2 import service_account

            if self.credentials_info:
                self._credentials = service_account.Credentials.from_service_account_info(self.credentials_info, scopes=[FCM_SCOPE])
            else:
                self._credentials = service_account.Credentials.from_service_account_file(self.credentials_path, scopes=[FCM_SCOPE])
            self._google_request = GoogleRequest
        if not self._credentials.token or not self._credentials.valid:
            self._credentials.refresh(self._google_request())
        return self._credentials.token

    def send(self, token: str, message: dict) -> SendResult:
        message = {**message, "token": token}
        try:
            access_token = self._access_token()
            response = httpx.post(FCM_SEND_URL.format(project_id=self.project_id), headers={"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"}, json={"message": message}, timeout=10.0)
        except Exception as exc:
            LOG.warning("FCM request failed: %s", exc)
            return SendResult(ok=False, invalid_token=False, provider_message_id=None, error=str(exc)[:500])
        if response.status_code == 200:
            try:
                name = response.json().get("name")
            except ValueError:
                name = None
            return SendResult(ok=True, invalid_token=False, provider_message_id=name, error=None)
        fcm_codes = set()
        try:
            body = response.json()
            error = body.get("error") or {}
            for detail in error.get("details") or []:
                if detail.get("@type") == FCM_ERROR_TYPE and detail.get("errorCode"):
                    fcm_codes.add(detail["errorCode"])
            message_text = error.get("message") or response.text
        except ValueError:
            message_text = response.text
        # HTTP 404/NOT_FOUND can be a project/configuration error. A generic
        # INVALID_ARGUMENT can be a malformed or oversized payload. Revoke
        # only when FCM explicitly identifies an unregistered/invalid token.
        token_error = str(message_text).lower()
        invalid_token = "UNREGISTERED" in fcm_codes or (
            "INVALID_ARGUMENT" in fcm_codes
            and "registration token" in token_error
            and ("not a valid" in token_error or "invalid" in token_error)
        )
        safe_error = str(message_text).replace(token, "[device_token]") if token else str(message_text)
        return SendResult(ok=False, invalid_token=invalid_token, provider_message_id=None, error=safe_error[:500])


def get_sender():
    if not env_flag("PUSH_ENABLED"):
        return StubSender()
    project_id = os.getenv("FIREBASE_PROJECT_ID", "km-case-hack")
    inline = (os.getenv("FIREBASE_CREDENTIALS_JSON") or "").strip()
    if inline:
        try:
            info = json.loads(inline)
        except json.JSONDecodeError:
            LOG.warning("FIREBASE_CREDENTIALS_JSON is not valid JSON; falling back to FIREBASE_CREDENTIALS")
        else:
            return FcmSender(project_id, credentials_info=info)
    credentials_path = os.getenv("FIREBASE_CREDENTIALS") or ""
    if credentials_path and os.path.isfile(credentials_path):
        return FcmSender(project_id, credentials_path=credentials_path)
    return StubSender()


def build_message(notification, order=None, token=""):
    emergency = (order is not None and order.priority == "emergency") or notification.kind == "unassigned"
    return {
        "token": token,
        "data": {
            "order_id": str(order.id) if order is not None else "",
            "notification_id": str(notification.id),
            "kind": notification.kind,
            "emergency": "true" if emergency else "false",
            "route": "order",
        },
        "android": {
            "priority": "high" if emergency else "normal",
            "notification": {"channel_id": "naryad_emergency" if emergency else "naryad_default", "sound": "default", "title": notification.title, "body": notification.message, "click_action": "FLUTTER_NOTIFICATION_CLICK"},
        },
        "notification": {"title": notification.title, "body": notification.message},
    }


def enqueue_push(db, notification, order=None):
    if order is None and notification.order_id:
        order = db.get(Order, notification.order_id)
    emergency = (order is not None and order.priority == "emergency") or notification.kind == "unassigned"
    task = PushTask(
        notification_id=notification.id,
        employee_id=notification.employee_id,
        kind=notification.kind,
        title=notification.title,
        message=notification.message,
        order_id=notification.order_id,
        priority="high" if emergency else "normal",
        payload=build_message(notification, order),
        status="pending",
        attempts=0,
        next_attempt_at=utcnow(),
    )
    db.add(task)
    return task


def dispatch_push(db, sender=None) -> int:
    sender = sender if sender is not None else get_sender()
    if isinstance(sender, StubSender):
        sender.bind(db)
    is_stub = bool(getattr(sender, "is_stub", False))
    max_attempts = env_int("PUSH_MAX_ATTEMPTS", 8)
    tasks = list(db.scalars(select(PushTask).where(PushTask.status == "pending", PushTask.next_attempt_at <= utcnow()).order_by(PushTask.id)))
    sent = 0
    for task in tasks:
        devices = list(db.scalars(select(DeviceToken).where(DeviceToken.employee_id == task.employee_id, DeviceToken.revoked_at.is_(None)).order_by(DeviceToken.id)))
        if not devices:
            task.status = "failed"
            task.last_error = "no_active_device"
            db.add(IntegrationLog(adapter="fcm", operation="push_failed", payload={"task_id": task.id, "employee_id": task.employee_id, "kind": task.kind, "order_id": task.order_id, "error": "no_active_device"}))
            continue
        notification = (db.get(Notification, task.notification_id) if task.notification_id else None) or task
        order = db.get(Order, task.order_id) if task.order_id else None
        finished = None
        for device in devices:
            message = build_message(notification, order, device.token)
            try:
                result = sender.send(device.token, message)
            except Exception as exc:
                result = SendResult(ok=False, invalid_token=False, error=str(exc)[:500])
            if result.error:
                result.error = result.error.replace(device.token, "[device_token]")
            if result.ok:
                task.status = "sent"
                task.sent_at = utcnow()
                task.provider_message_id = result.provider_message_id
                task.last_error = None
                if not is_stub:
                    db.add(IntegrationLog(adapter="fcm", operation="push_sent", payload={"task_id": task.id, "employee_id": task.employee_id, "kind": task.kind, "order_id": task.order_id, "token_fingerprint": token_fingerprint(device.token), "attempts": task.attempts, "provider_message_id": result.provider_message_id}))
                sent += 1
                finished = "sent"
                break
            if result.invalid_token:
                device.revoked_at = utcnow()
                if not is_stub:
                    db.add(IntegrationLog(adapter="fcm", operation="push_failed", payload={"task_id": task.id, "employee_id": task.employee_id, "kind": task.kind, "order_id": task.order_id, "token_fingerprint": token_fingerprint(device.token), "attempts": task.attempts, "error": result.error or "invalid_token"}))
                continue
            task.attempts += 1
            task.last_error = result.error or "transient_error"
            if not is_stub:
                db.add(IntegrationLog(adapter="fcm", operation="push_failed", payload={"task_id": task.id, "employee_id": task.employee_id, "kind": task.kind, "order_id": task.order_id, "token_fingerprint": token_fingerprint(device.token), "attempts": task.attempts, "error": task.last_error}))
            if task.attempts < max_attempts:
                task.next_attempt_at = utcnow() + timedelta(seconds=min(2 ** task.attempts, 3600))
            else:
                task.status = "failed"
            finished = "transient"
            break
        if finished is None:
            task.status = "failed"
            task.last_error = "all_tokens_invalid"
    db.commit()
    return sent


def run_push_dispatch(sessions):
    with sessions() as db:
        return dispatch_push(db)
