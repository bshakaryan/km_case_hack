"""Procedural local JPEG acceptance; doubles are explicit and never CV evidence."""
import asyncio
import base64
import copy
import hashlib
import io
import multiprocessing
import random
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

import pytest
import httpx
from PIL import Image, ImageDraw

from app import attempt_bridge, attempt_photos
from app.attempt_bridge import create_attempt_app
from app.attempt_photos import PhotoCheck, PhotoRunner, decode_content
from app.config import Settings
from fastapi.testclient import TestClient
from test_attempt_bridge import HEADERS, TOKEN, resign, signed_packet

ROUTE = "/internal/v2/submission-review"


def jpeg(seed=42, size=(256, 256), format="JPEG"):
    image = Image.new("RGB", size, "white")
    draw = ImageDraw.Draw(image)
    rng = random.Random(seed)
    for _ in range(80):
        x, y = rng.randrange(size[0]), rng.randrange(size[1])
        draw.rectangle((x, y, min(x + 14, size[0]), min(y + 14, size[1])),
                       fill=tuple(rng.randrange(255) for _ in range(3)))
    output = io.BytesIO()
    image.save(output, format=format)
    return output.getvalue()


def packet(rows=None):
    rows = rows if rows is not None else [(20, "before", jpeg()), (21, "after", jpeg())]
    value = signed_packet()
    value["schema_version"] = 2
    value["photos"] = [{"id": id_, "kind": kind, "sha256": hashlib.sha256(data).hexdigest()}
                       for id_, kind, data in rows]
    value["context"]["photos"] = copy.deepcopy(value["photos"])
    value["photo_content"] = [{"id": id_, "data_base64": base64.b64encode(data).decode("ascii")}
                              for id_, _, data in rows]
    return resign(value)


class RunnerDouble:
    """Only a transport/session double: does not prove JPEG/CV validation."""
    def __init__(self, status="checked"):
        self.status = status
        self.calls = []

    async def run(self, metadata, content):
        self.calls.append((metadata, content))
        selected = attempt_photos.selected_ids(metadata)
        return PhotoCheck(status=self.status, before_id=selected["before"],
                          after_id=selected["after"]).model_dump()


def endpoint(runner=None, llm=None):
    return TestClient(create_attempt_app(Settings(ai_service_token=TOKEN), llm=llm, photo_runner=runner))


def local(value, model_path):
    decoded = decode_content(value["photos"], value["photo_content"])
    return attempt_photos._local_check(value["photos"], decoded, str(model_path))


def track_regions(monkeypatch):
    original = attempt_photos.SharedMemory
    names = []

    def observed(*args, **kwargs):
        region = original(*args, **kwargs)
        if kwargs.get("create"):
            names.append(region.name)
        return region

    monkeypatch.setattr(attempt_photos, "SharedMemory", observed)
    return names, original


def assert_regions_released(names, original):
    for name in names:
        with pytest.raises(FileNotFoundError):
            region = original(name=name)
            region.close()


def test_actual_cv_exact_pair_and_missing_model_never_imply_repair_or_score(tmp_path, monkeypatch):
    names, original = track_regions(monkeypatch)
    value = packet()
    check = local(value, tmp_path / "private-not-installed.onnx")
    assert check == PhotoCheck(status="checked", before_id=20, after_id=21,
                               duplicate_before=True, exact_duplicate_groups=[[20, 21]]).model_dump()
    assert "private-not-installed" not in str(check)
    with endpoint(PhotoRunner(model_path=tmp_path / "private-not-installed.onnx")) as client:
        response = client.post(ROUTE, json=value, headers=HEADERS)
    assert response.status_code == 200
    result = response.json()["result"]
    assert result["photo_check"] == check
    assert result["score"] is None and result["master_score"] is None
    assert result["source_verdict"] == "needs_master_review" and result["verdict"] == "needs_attention"
    assert result["llm_used"] is False and result["is_stub"] is True
    assert "устранение дефекта не подтверждено" in result["explanation"]
    assert len(names) == 1
    assert_regions_released(names, original)


def test_all_exact_groups_but_perceptual_only_latest_id_pair(tmp_path, monkeypatch):
    from app import photos

    original = photos.compare_images
    calls = []

    def observed(before, after):
        calls.append((before, after))
        return original(before, after)

    monkeypatch.setattr(photos, "compare_images", observed)
    first, second, latest = jpeg(1), jpeg(2), jpeg(3)
    value = packet([(12, "after", first), (9, "before", first),
                    (30, "after", latest), (24, "before", second), (18, "before", first)])
    check = local(value, tmp_path / "missing.onnx")
    assert (check["before_id"], check["after_id"]) == (24, 30)
    assert check["exact_duplicate_groups"] == [[9, 12, 18]]
    assert calls == [(second, latest)]
    assert check["capture_time_status"] == "unknown" and check["history_status"] == "not_checked"
    assert check["repair_status"] == "unknown"


def test_rework_reuses_frozen_photos_without_freshness_filter(tmp_path):
    value = packet()
    value["context"]["sequence"] = 2
    value["attempt_id"] = 12
    resign(value)
    check = local(value, tmp_path / "missing.onnx")
    assert check["before_id"] == 20 and check["after_id"] == 21
    assert check["duplicate_before"] is True
    assert check["capture_time_status"] == "unknown"


@pytest.mark.parametrize("rows,status,before,after", [
    ([], "no_after", None, None),
    ([(3, "before", jpeg())], "no_after", 3, None),
    ([(4, "after", jpeg())], "checked", None, 4),
], ids=["no-photos", "before-only", "after-only"])
def test_missing_pair_members_preserve_unknown_scope(tmp_path, rows, status, before, after):
    check = local(packet(rows), tmp_path / "missing.onnx")
    assert check == PhotoCheck(status=status, before_id=before, after_id=after).model_dump()


@pytest.mark.parametrize("change", [
    lambda value: value["photo_content"].reverse(),
    lambda value: value["photo_content"][0].update(id=True),
    lambda value: value["photo_content"][0].update(url="http://private.invalid/photo"),
    lambda value: value["photo_content"][0].update(data_base64="!!!"),
    lambda value: value["photo_content"][0].update(data_base64=value["photo_content"][0]["data_base64"] + "\n"),
    lambda value: value["photo_content"][0].update(data_base64=base64.b64encode(b"tampered bytes").decode()),
])
def test_transport_identity_base64_and_hash_are_checked_before_runner(change):
    value = packet()
    change(value)
    resign(value)
    double = RunnerDouble()
    with endpoint(double) as client:
        response = client.post(ROUTE, json=value, headers=HEADERS)
    assert response.status_code == 422
    assert response.json() == {"detail": "invalid_submission_review_input"}
    assert not double.calls
    assert "private" not in response.text


def test_digest_binds_original_base64_and_content_bytes_reach_only_declared_runner_double():
    value = packet([(2, "after", jpeg())])
    double = RunnerDouble()
    with endpoint(double) as client:
        assert client.post(ROUTE, json=value, headers=HEADERS).status_code == 200
        tampered = copy.deepcopy(value)
        tampered["photo_content"][0]["data_base64"] = base64.b64encode(jpeg(9)).decode()
        assert client.post(ROUTE, json=tampered, headers=HEADERS).status_code == 422
    assert len(double.calls) == 1
    assert double.calls[0][1] == [{"id": 2, "data": jpeg()}]


def test_v2_never_calls_injected_llm_and_never_assigns_hard_flag_score():
    class ForbiddenLLM:
        async def interpret(self, _):
            pytest.fail("v2 invoked the v1 semantic seam")

    value = packet([])
    value["report"]["work_done"] = ""
    resign(value)
    with endpoint(llm=ForbiddenLLM()) as client:
        result = client.post(ROUTE, json=value, headers=HEADERS).json()["result"]
    assert result["score"] is None and result["source_verdict"] == "needs_master_review"
    assert result["photo_check"]["status"] == "no_after"
    assert result["llm_used"] is False


def test_runner_error_is_unknown_and_never_echoes_media_or_local_paths():
    class FailingRunnerDouble:
        async def run(self, *_):
            raise RuntimeError("private-path private-media private-model-error")

    with endpoint(FailingRunnerDouble()) as client:
        response = client.post(ROUTE, json=packet(), headers=HEADERS)
    assert response.status_code == 200
    result = response.json()["result"]
    assert result["photo_check"] == PhotoCheck(status="unavailable", before_id=20, after_id=21).model_dump()
    assert result["score"] is None and "private" not in response.text


def test_invalid_injected_output_has_only_fixed_internal_error():
    class MalformedRunnerDouble:
        async def run(self, *_):
            return {"status": "checked", "private_path": "private-model-path"}

    with endpoint(MalformedRunnerDouble()) as client:
        response = client.post(ROUTE, json=packet(), headers=HEADERS)
    assert response.status_code == 502
    assert response.json() == {"detail": "invalid_submission_review_result"}


def test_cancelled_parse_keeps_its_slot_and_consumes_late_input_error(monkeypatch):
    original = attempt_bridge._owned_photo_input
    started, release = threading.Event(), threading.Event()

    def delayed(raw):
        started.set()
        release.wait(2)
        return original(raw)

    monkeypatch.setattr(attempt_bridge, "_owned_photo_input", delayed)
    value = packet([])
    value["report"]["unexpected_field"] = "private-input"
    resign(value)

    async def exercise():
        loop = asyncio.get_running_loop()
        errors = []
        previous = loop.get_exception_handler()
        loop.set_exception_handler(lambda _, context: errors.append(context))
        try:
            app = create_attempt_app(Settings(ai_service_token=TOKEN))
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app), base_url="http://test") as client:
                task = asyncio.create_task(client.post(ROUTE, json=value, headers=HEADERS))
                for _ in range(100):
                    if started.is_set():
                        break
                    await asyncio.sleep(0.01)
                assert started.is_set()
                task.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await task
                assert attempt_bridge._PHOTO_PARSE_GATE.acquire(False)
                try:
                    assert not attempt_bridge._PHOTO_PARSE_GATE.acquire(False)
                finally:
                    attempt_bridge._PHOTO_PARSE_GATE.release()
                release.set()
                for _ in range(100):
                    if attempt_bridge._PHOTO_PARSE_GATE.acquire(False):
                        second = attempt_bridge._PHOTO_PARSE_GATE.acquire(False)
                        attempt_bridge._PHOTO_PARSE_GATE.release()
                        if second:
                            attempt_bridge._PHOTO_PARSE_GATE.release()
                            break
                    await asyncio.sleep(0.01)
                else:
                    pytest.fail("Cancelled parse did not release its owned slot")
                await asyncio.sleep(0.02)
                assert not errors
        finally:
            release.set()
            loop.set_exception_handler(previous)

    asyncio.run(exercise())


def test_v2_auth_capacity_and_stream_limit_precede_decoding(monkeypatch):
    monkeypatch.setattr(attempt_bridge, "MAX_PHOTO_REQUEST_BYTES", 512)
    double = RunnerDouble()
    with endpoint(double) as client:
        assert client.post(ROUTE, content=b"invalid JSON").status_code == 401
        assert client.post(ROUTE, content=(b"x" * 256 for _ in range(3)), headers=HEADERS).status_code == 413
        assert client.post(ROUTE, content=b"{}", headers={**HEADERS, "Content-Length": "513"}).status_code == 413
        assert attempt_bridge._PHOTO_PARSE_GATE.acquire(False)
        assert attempt_bridge._PHOTO_PARSE_GATE.acquire(False)
        try:
            assert client.post(ROUTE, content=b"invalid JSON").status_code == 401
            assert client.post(ROUTE, content=b"invalid JSON", headers=HEADERS).status_code == 503
        finally:
            attempt_bridge._PHOTO_PARSE_GATE.release()
            attempt_bridge._PHOTO_PARSE_GATE.release()
    assert not double.calls


def test_decoded_four_mib_limit_is_enforced_before_runner():
    value = packet([(2, "after", b"x" * (attempt_photos.MAX_IMAGE_BYTES + 1))])
    double = RunnerDouble()
    with endpoint(double) as client:
        assert client.post(ROUTE, json=value, headers=HEADERS).status_code == 422
    assert not double.calls


@pytest.mark.parametrize("raw", [b"not JPEG", jpeg(format="PNG"), jpeg(size=(2001, 2000)), jpeg()[:100]],
                         ids=["not-jpeg", "png", "too-many-pixels", "truncated-jpeg"])
def test_actual_decoder_rejects_nonjpeg_truncated_and_pixel_limit(tmp_path, raw):
    with pytest.raises(attempt_photos.InvalidPhoto, match="invalid_photo_content"):
        local(packet([(2, "after", raw)]), tmp_path / "missing.onnx")


def test_single_frame_constraint_with_explicit_header_double(tmp_path, monkeypatch):
    class MultipleFrames:
        format = "JPEG"
        n_frames = 2
        width = height = 100

        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

    monkeypatch.setattr(Image, "open", lambda _: MultipleFrames())
    with pytest.raises(attempt_photos.InvalidPhoto):
        local(packet([(2, "after", b"header-double")]), tmp_path / "missing.onnx")


def _hung_worker(send, *_):
    """Spawned process-control double, not a CV acceptance fixture."""
    time.sleep(30)


def test_spawn_timeout_terminates_child_and_preserves_unknown_without_payload(tmp_path, monkeypatch):
    names, original = track_regions(monkeypatch)
    monkeypatch.setattr(attempt_photos, "_worker", _hung_worker)
    monkeypatch.setattr(attempt_photos, "WORKER_TIMEOUT_SECONDS", 0.25)
    value = packet([(2, "after", jpeg())])
    start = time.monotonic()
    check = asyncio.run(PhotoRunner(tmp_path / "private-path.onnx").run(
        value["photos"], decode_content(value["photos"], value["photo_content"])))
    assert time.monotonic() - start < 4
    assert check == PhotoCheck(status="unavailable", after_id=2).model_dump()
    assert not [child for child in multiprocessing.active_children() if child.name == "attempt-photo-cv"]
    assert "private-path" not in str(check)
    assert_regions_released(names, original)


def test_cancellation_keeps_gate_until_child_cleanup_and_never_queues_second_child(tmp_path, monkeypatch):
    names, original = track_regions(monkeypatch)
    monkeypatch.setattr(attempt_photos, "_worker", _hung_worker)
    value = packet([(2, "after", jpeg())])
    decoded = decode_content(value["photos"], value["photo_content"])
    runner = PhotoRunner(tmp_path / "missing.onnx")

    async def exercise():
        task = asyncio.create_task(runner.run(value["photos"], decoded))
        await asyncio.sleep(0.03)
        assert not attempt_photos._GATE.acquire(False)
        task.cancel()
        second = await runner.run(value["photos"], decoded)
        assert second["status"] == "unavailable"
        cancelled_at = time.monotonic()
        with pytest.raises(asyncio.CancelledError):
            await task
        assert time.monotonic() - cancelled_at < 0.5
        for _ in range(150):
            if attempt_photos._GATE.acquire(False):
                attempt_photos._GATE.release()
                break
            await asyncio.sleep(0.02)
        else:
            pytest.fail("The cancelled child retained the gate after cleanup")

    asyncio.run(exercise())
    assert not [child for child in multiprocessing.active_children() if child.name == "attempt-photo-cv"]
    assert_regions_released(names, original)


def test_real_orb_knn_with_one_target_descriptor_is_safe(monkeypatch):
    import numpy as np
    from app import photos

    class OneFeatureDetector:
        def detectAndCompute(self, *_):
            return [SimpleNamespace(pt=(10, 10))], np.zeros((1, 32), dtype=np.uint8)

    monkeypatch.setattr(photos.cv2, "ORB_create", lambda **_: OneFeatureDetector())
    image = Image.new("RGB", (32, 32))
    # Actual BFMatcher knn row has one element; only the detector is a double.
    assert photos.orb_overlap(image, image) == {"matches": 0, "inliers": 0, "overlap": 0.0}


def test_v1_factory_does_not_import_cv_or_spawn_process():
    code = ("import sys; from app.attempt_bridge import create_attempt_app; "
            "create_attempt_app(); assert 'cv2' not in sys.modules; "
            "assert 'numpy' not in sys.modules; assert 'app.photos' not in sys.modules")
    result = subprocess.run([sys.executable, "-c", code], capture_output=True, timeout=10)
    assert result.returncode == 0, "The default factory imported CV dependencies"
