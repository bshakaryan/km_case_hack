"""Bounded server-only transport of an immutable attempt to the AI module."""
import asyncio
import base64
from copy import deepcopy
import hashlib
import json
import os
from urllib.parse import urlsplit

import httpx

DEADLINE_SECONDS = 8
MAX_REQUEST_BYTES = 1024 * 1024
MAX_V2_REQUEST_BYTES = 56 * 1024 * 1024
MAX_PHOTO_BYTES = 4 * 1024 * 1024
MAX_PHOTOS = 10
MAX_RESPONSE_BYTES = 64 * 1024


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False).encode("utf-8")


def unique_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("invalid_result")
        value[key] = item
    return value


def reject_constant(value):
    raise ValueError("invalid_result")


def envelope(snapshot, version=1):
    if type(version) is not int or version not in {1, 2}:
        raise ValueError("invalid_bridge_version")
    context = snapshot.get("ai_input")
    if not isinstance(context, dict):
        raise ValueError("missing_attempt_context")
    source_photos = snapshot["photos"]
    if len(source_photos) > MAX_PHOTOS:
        raise ValueError("attempt_input_too_large")
    ids = [photo["id"] for photo in source_photos]
    if any(type(id_) is not int or id_ <= 0 for id_ in ids) or ids != sorted(set(ids)):
        raise ValueError("changed_attempt_photo")
    if any(photo["kind"] not in {"before", "after"} or not isinstance(photo["data"], bytes) for photo in source_photos):
        raise ValueError("changed_attempt_photo")
    photos = [{"id": photo["id"], "kind": photo["kind"], "sha256": hashlib.sha256(photo["data"]).hexdigest()} for photo in source_photos]
    if context.get("photos") != photos:
        raise ValueError("changed_attempt_photo")
    value = {"schema_version": version, "attempt_id": snapshot["attempt_id"], "order_id": snapshot["order_id"],
             "context": deepcopy(context), "report": deepcopy(snapshot["report"]), "photos": photos}
    if version == 2:
        if any(not photo["data"] or len(photo["data"]) > MAX_PHOTO_BYTES for photo in source_photos):
            raise ValueError("attempt_input_too_large")
        value["photo_content"] = [{"id": photo["id"], "data_base64": base64.b64encode(photo["data"]).decode("ascii")} for photo in source_photos]
    value["input_sha256"] = hashlib.sha256(canonical(value)).hexdigest()
    if len(canonical(value)) > (MAX_REQUEST_BYTES if version == 1 else MAX_V2_REQUEST_BYTES):
        raise ValueError("attempt_input_too_large")
    return value


class AttemptServiceAdapter:
    def __init__(self, url, token, transport=None, version=2):
        if type(version) is not int or version not in {1, 2}:
            raise ValueError("invalid_bridge_version")
        try:
            parsed = urlsplit(url)
            parsed.port
        except ValueError:
            raise ValueError("AI_SERVICE_URL/TOKEN are invalid") from None
        if (parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password
                or parsed.query or parsed.fragment or parsed.path not in {"", "/"} or len(token) < 16
                or any(character.isspace() for character in token)):
            raise ValueError("AI_SERVICE_URL/TOKEN are invalid")
        self.version = version
        self.url = url.rstrip("/") + f"/internal/v{version}/submission-review"
        self._token = token
        self.transport = transport

    @classmethod
    def from_env(cls):
        return cls(os.getenv("AI_SERVICE_URL", ""), os.getenv("AI_SERVICE_TOKEN", ""))

    def review(self, snapshot):
        request = envelope(snapshot, self.version)
        return asyncio.run(asyncio.wait_for(self._review(request), timeout=DEADLINE_SECONDS))

    async def _review(self, request):
        async with httpx.AsyncClient(transport=self.transport, timeout=DEADLINE_SECONDS,
                                    follow_redirects=False, trust_env=False) as client:
            async with client.stream("POST", self.url, content=canonical(request),
                                     headers={"Authorization": "Bearer " + self._token, "Content-Type": "application/json"}) as response:
                if response.status_code != 200:
                    raise httpx.HTTPStatusError("ai_service_unavailable", request=response.request, response=response)
                if response.headers.get("content-type", "").split(";", 1)[0].strip().lower() != "application/json":
                    raise ValueError("invalid_result")
                data = bytearray()
                async for chunk in response.aiter_bytes():
                    if len(data) + len(chunk) > MAX_RESPONSE_BYTES:
                        raise ValueError("invalid_result")
                    data.extend(chunk)
        result = json.loads(data.decode("utf-8"), object_pairs_hook=unique_keys, parse_constant=reject_constant)
        if (not isinstance(result, dict) or set(result) != {"schema_version", "attempt_id", "input_sha256", "result"}
                or type(result["schema_version"]) is not int or result["schema_version"] != request["schema_version"]
                or type(result["attempt_id"]) is not int or result["attempt_id"] != request["attempt_id"]
                or result["input_sha256"] != request["input_sha256"] or not isinstance(result["result"], dict)):
            raise ValueError("invalid_result")
        return {**result["result"], "input_sha256": request["input_sha256"], "bridge_version": request["schema_version"]}
