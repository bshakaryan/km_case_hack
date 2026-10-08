"""Bounded local photo checks; CV imports exist only in a spawned child.

No source lookup, media path from a request, model download, external model or
repair verdict is allowed here. One fixed executor and a non-waiting gate keep
cancelled requests from admitting another child before the first has exited.
"""
from __future__ import annotations

import asyncio
import base64
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
import multiprocessing
from multiprocessing.shared_memory import SharedMemory
import os
from pathlib import Path
import threading
import time
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_IMAGE_PIXELS = 4_000_000
MAX_BASE64_CHARS = ((MAX_IMAGE_BYTES + 2) // 3) * 4
WORKER_TIMEOUT_SECONDS = 5.0
MAX_WORKER_RESPONSE_BYTES = 64 * 1024
_GATE = threading.BoundedSemaphore(1)
_EXECUTOR = ThreadPoolExecutor(max_workers=1, thread_name_prefix="attempt-photo-supervisor")


class PhotoCheck(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    status: Literal["checked", "unavailable", "no_after"]
    method: Literal["local_cv"] = "local_cv"
    scope: Literal["submission_selected_pair"] = "submission_selected_pair"
    before_id: int | None = Field(default=None, gt=0)
    after_id: int | None = Field(default=None, gt=0)
    duplicate_before: bool | None = None
    exact_duplicate_groups: list[list[int]] = Field(default_factory=list)
    equipment_status: Literal["different", "unknown"] = "unknown"
    model_available: bool = False
    capture_time_status: Literal["unknown"] = "unknown"
    repair_status: Literal["unknown"] = "unknown"
    history_status: Literal["not_checked"] = "not_checked"


def selected_ids(metadata):
    return {kind: max((photo["id"] for photo in metadata if photo["kind"] == kind), default=None)
            for kind in ("before", "after")}


def unavailable(metadata):
    selected = selected_ids(metadata)
    return PhotoCheck(status="unavailable", before_id=selected["before"],
                      after_id=selected["after"]).model_dump()


def decode_content(metadata, content):
    """Off-loop transport validation before any injected or real photo runner."""
    decoded = []
    try:
        for photo, media in zip(metadata, content, strict=True):
            raw = base64.b64decode(media["data_base64"], validate=True)
            if (media["id"] != photo["id"] or not raw or len(raw) > MAX_IMAGE_BYTES
                    or hashlib.sha256(raw).hexdigest() != photo["sha256"]):
                raise ValueError("invalid_photo_content")
            decoded.append({"id": photo["id"], "data": raw})
    except (ValueError, TypeError, UnicodeError):
        raise ValueError("invalid_photo_content") from None
    return decoded


class InvalidPhoto(ValueError):
    pass


def _local_check(metadata, content, model_path):
    """Child-only decode/validation and deterministic, limited pair selection."""
    from PIL import Image

    decoded = {}
    groups = defaultdict(list)
    for photo, media in zip(metadata, content, strict=True):
        raw = media["data"]
        if media["id"] != photo["id"] or not raw or len(raw) > MAX_IMAGE_BYTES:
            raise InvalidPhoto("invalid_photo_content")
        digest = hashlib.sha256(raw).hexdigest()
        if digest != photo["sha256"]:
            raise InvalidPhoto("invalid_photo_content")
        try:
            with Image.open(io.BytesIO(raw)) as image:
                if (image.format != "JPEG" or getattr(image, "n_frames", 1) != 1
                        or image.width * image.height > MAX_IMAGE_PIXELS):
                    raise InvalidPhoto("invalid_photo_content")
                image.load()  # Check the complete decoder input, not only the header.
        except (ValueError, OSError, Image.DecompressionBombError):
            raise InvalidPhoto("invalid_photo_content") from None
        decoded[photo["id"]] = raw
        groups[digest].append(photo["id"])
    selected = selected_ids(metadata)
    result = PhotoCheck(status="no_after" if selected["after"] is None else "checked",
                        before_id=selected["before"], after_id=selected["after"]).model_dump()
    if selected["after"] is None:
        return result
    result["exact_duplicate_groups"] = sorted(sorted(ids) for ids in groups.values() if len(ids) > 1)
    if selected["before"] is not None:
        import cv2
        from .photos import compare_images
        from .equipment_match import EquipmentMatcher

        cv2.setNumThreads(1)
        before, after = decoded[selected["before"]], decoded[selected["after"]]
        result["duplicate_before"] = compare_images(before, after)["duplicate"]
        equipment = EquipmentMatcher(model_path=Path(model_path)).compare(before, after)
        result["equipment_status"] = equipment["status"]
        result["model_available"] = equipment["model_available"]
    return result


def _worker(send, metadata, segments, model_path, shared_name):
    # Native libraries occasionally print paths/errors. Never forward child
    # stdout/stderr, exceptions, input or media through this protocol.
    with open(os.devnull, "w") as sink:
        try:
            os.dup2(sink.fileno(), 1)
            os.dup2(sink.fileno(), 2)
        except OSError:
            pass
        region = None
        try:
            region = SharedMemory(name=shared_name)
            content = []
            for segment in segments:
                start, length = segment["offset"], segment["length"]
                if start < 0 or length <= 0 or length > MAX_IMAGE_BYTES or start + length > region.size:
                    raise InvalidPhoto("invalid_photo_content")
                content.append({"id": segment["id"], "data": bytes(region.buf[start:start + length])})
            result = {"photo_check": _local_check(metadata, content, model_path)}
        except InvalidPhoto:
            result = {"invalid_input": True}
        except Exception:
            result = {"photo_check": unavailable(metadata)}
        finally:
            if region is not None:
                region.close()  # Child never unlinks its parent's owned region.
        try:
            send.send_bytes(json.dumps(result, separators=(",", ":")).encode("utf-8"))
        finally:
            send.close()


def _stop(process):
    if process.is_alive():
        process.terminate()
        process.join(0.2)
    if process.is_alive():
        process.kill()
        process.join(0.3)
    else:
        process.join(0)
    if not process.is_alive():
        process.close()
        return True
    return False


def _release_region(region):
    if region is not None:
        try:
            region.close()
        finally:
            try:
                region.unlink()
            except FileNotFoundError:
                pass


def _reap(process, region):
    """Keep ownership/gate if an OS kill has not reached terminal state yet."""
    while process.is_alive():
        try:
            try:
                process.kill()
            except OSError:
                pass
            process.join(0.5)
        except OSError:
            time.sleep(0.1)
    try:
        process.close()
    finally:
        try:
            _release_region(region)
        finally:
            _GATE.release()


class PhotoRunner:
    def __init__(self, model_path=None):
        self.model_path = str(Path(model_path or os.getenv("AI_IMAGE_EMBEDDING_MODEL")
                                  or Path(__file__).resolve().parents[1] / "models" / "mobilenetv2.onnx"))

    def _owned_run(self, metadata, content, cancelled):
        deadline = time.monotonic() + WORKER_TIMEOUT_SECONDS
        receiver, sender, process, region = None, None, None, None
        started = False
        try:
            spawn = multiprocessing.get_context("spawn")
            receiver, sender = spawn.Pipe(duplex=False)
            total = sum(len(row["data"]) for row in content)
            if not 0 < total <= 10 * MAX_IMAGE_BYTES:
                raise ValueError("invalid_photo_content")
            # Generated private shared memory avoids copying up to 40 MiB in
            # synchronous Windows spawn arguments before a child handle exists.
            region = SharedMemory(create=True, size=total)
            segments, offset = [], 0
            for row in content:
                size = len(row["data"])
                region.buf[offset:offset + size] = row["data"]
                segments.append({"id": row["id"], "offset": offset, "length": size})
                offset += size
            process = spawn.Process(target=_worker, args=(sender, metadata, segments, self.model_path, region.name),
                                    daemon=True, name="attempt-photo-cv")
            if cancelled.is_set():
                return unavailable(metadata)
            process.start()
            started = True
            sender.close()
            cutoff = deadline
            while time.monotonic() < cutoff and not cancelled.is_set():
                if receiver.poll(min(0.05, max(0, cutoff - time.monotonic()))):
                    result = json.loads(receiver.recv_bytes(MAX_WORKER_RESPONSE_BYTES))
                    if result == {"invalid_input": True}:
                        raise ValueError("invalid_photo_content")
                    if not isinstance(result, dict) or set(result) != {"photo_check"}:
                        return unavailable(metadata)
                    return PhotoCheck.model_validate(result["photo_check"]).model_dump()
                if not process.is_alive():
                    break
            return unavailable(metadata)
        except ValueError as error:
            if str(error) == "invalid_photo_content":
                raise
            return unavailable(metadata)
        except Exception:
            return unavailable(metadata)
        finally:
            terminal = not started
            try:
                if started:
                    terminal = _stop(process)
            finally:
                try:
                    if receiver is not None:
                        receiver.close()
                    if sender is not None:
                        sender.close()
                finally:
                    if terminal:
                        try:
                            _release_region(region)
                        finally:
                            _GATE.release()
                    else:
                        # Never admit a new child while the previous is alive.
                        threading.Thread(target=_reap, args=(process, region), daemon=True,
                                         name="attempt-photo-reaper").start()

    async def run(self, metadata, content):
        if not metadata:
            return PhotoCheck(status="no_after").model_dump()
        if not _GATE.acquire(blocking=False):
            return unavailable(metadata)
        cancelled = threading.Event()
        try:
            future = _EXECUTOR.submit(self._owned_run, metadata, content, cancelled)
        except Exception:
            _GATE.release()
            return unavailable(metadata)
        task = asyncio.wrap_future(future)
        task.add_done_callback(lambda done: None if done.cancelled() else done.exception())
        try:
            return await asyncio.shield(task)
        except asyncio.CancelledError:
            cancelled.set()
            # Return cancellation immediately; the supervisor retains the gate
            # and process ownership through its independent terminal cleanup.
            raise
