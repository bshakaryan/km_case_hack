"""Photo provenance checks and cautious, optional visual recommendations."""

import hashlib
import io
import re
from datetime import datetime

import cv2
import imagehash
import numpy as np
from PIL import Image, UnidentifiedImageError

from .config import Settings
from .datasource import DataSource, DataSourceError
from .deadlines import utc
from .llm_client import LLMClient, VisionAssessment
from .schemas import PhotoRecord, Snapshot
from .storage import AIStore
from .verification import scrub, source_version


MAX_IMAGE_BYTES = 12 * 1024 * 1024
MAX_IMAGE_PIXELS = 20_000_000
MAX_HISTORY_PHOTOS = 1000


def open_image(raw: bytes):
    if not raw or len(raw) > MAX_IMAGE_BYTES:
        raise ValueError("Фото пустое или превышает допустимый размер")
    try:
        with Image.open(io.BytesIO(raw)) as source:
            if source.width * source.height > MAX_IMAGE_PIXELS:
                raise ValueError("Слишком большое разрешение фото")
            return source.convert("RGB")
    except (UnidentifiedImageError, OSError) as error:
        raise ValueError("Файл не является читаемым изображением") from error


def sanitized_jpeg(image: Image.Image):
    sanitized = image.copy()
    sanitized.thumbnail((1024, 1024))
    output = io.BytesIO()
    sanitized.save(output, format="JPEG", quality=85)
    return output.getvalue()


def fingerprint(raw: bytes):
    image = open_image(raw)
    return {"sha256": hashlib.sha256(raw).hexdigest(), "phash": str(imagehash.phash(image))}, image


def ssim(first: Image.Image, second: Image.Image):
    left = cv2.cvtColor(np.asarray(first.resize((256, 256))), cv2.COLOR_RGB2GRAY).astype(np.float64)
    right = cv2.cvtColor(np.asarray(second.resize((256, 256))), cv2.COLOR_RGB2GRAY).astype(np.float64)
    left_mean = cv2.GaussianBlur(left, (11, 11), 1.5)
    right_mean = cv2.GaussianBlur(right, (11, 11), 1.5)
    left_variance = cv2.GaussianBlur(left * left, (11, 11), 1.5) - left_mean * left_mean
    right_variance = cv2.GaussianBlur(right * right, (11, 11), 1.5) - right_mean * right_mean
    covariance = cv2.GaussianBlur(left * right, (11, 11), 1.5) - left_mean * right_mean
    numerator = (2 * left_mean * right_mean + 6.5025) * (2 * covariance + 58.5225)
    denominator = (left_mean * left_mean + right_mean * right_mean + 6.5025) * (
        left_variance + right_variance + 58.5225)
    return float(np.clip(np.mean(numerator / np.maximum(denominator, 1e-9)), -1, 1))


def compare_images(first_raw: bytes, second_raw: bytes):
    first_hash, first_image = fingerprint(first_raw)
    second_hash, second_image = fingerprint(second_raw)
    distance = int(imagehash.hex_to_hash(first_hash["phash"]) - imagehash.hex_to_hash(second_hash["phash"]))
    similarity = ssim(first_image, second_image)
    duplicate = first_hash["sha256"] == second_hash["sha256"] or (distance <= 10 and similarity >= 0.45)
    return {"duplicate": bool(duplicate), "exact": first_hash["sha256"] == second_hash["sha256"],
            "phash_distance": distance, "ssim": round(similarity, 4)}


def uploaded_in_work_window(photo: PhotoRecord, started_at: datetime | None, completed_at: datetime | None):
    if photo.created_at is None or started_at is None or completed_at is None:
        return None
    return utc(started_at) <= utc(photo.created_at) <= utc(completed_at)


def vision_valid(assessment: VisionAssessment, snapshot: Snapshot):
    prose = " ".join([assessment.explanation, *assessment.issues])
    if re.search(r"\d", prose):
        return False
    return not any(person.name and person.name.lower() in prose.lower() for person in snapshot.employees)


def photo_version(photo: PhotoRecord):
    return f"{utc(photo.created_at).isoformat() if photo.created_at else 'unknown'}:{photo.path or photo.url or ''}"


class PhotoReviewService:
    def __init__(self, source: DataSource, store: AIStore, llm: LLMClient, settings: Settings):
        self.source = source
        self.store = store
        self.llm = llm
        self.settings = settings

    async def cached_fingerprint(self, photo: PhotoRecord):
        version = photo_version(photo)
        saved = self.store.get_result("photo_fingerprint", str(photo.id), version)
        if saved:
            return saved["payload"]
        raw = await self.source.photo_bytes(photo)
        details, _ = fingerprint(raw)
        self.store.put_result("photo_fingerprint", str(photo.id), version, details)
        return details

    async def review(self, order_id: int, expected_version: str | None = None):
        snapshot = await self.source.snapshot()
        order = next((item for item in snapshot.orders if item.id == order_id), None)
        if order is None:
            raise LookupError("Наряд не найден")
        if order.completion is None:
            raise ValueError("Наряд ещё не сдан")
        version = source_version(order)
        if expected_version is not None and version != expected_version:
            raise ValueError("Сдача изменилась до фотоанализа")
        saved = self.store.get_result("photo_review", str(order_id), version)
        if saved:
            return saved["payload"]
        latest_rework = max((utc(event.created_at) for event in order.events if event.action == "rework"),
                            default=None)
        after_photos = sorted((photo for photo in order.photos if photo.kind == "after" and
                               (latest_rework is None or photo.created_at and
                                utc(photo.created_at) >= latest_rework)),
                              key=lambda item: utc(item.created_at) if item.created_at else datetime.min.replace(
                                  tzinfo=utc(order.created_at).tzinfo))
        before_photos = sorted((photo for photo in order.photos if photo.kind == "before"),
                               key=lambda item: utc(item.created_at) if item.created_at else datetime.min.replace(
                                   tzinfo=utc(order.created_at).tzinfo))
        after = after_photos[-1] if after_photos else None
        before = before_photos[-1] if before_photos else None
        result = {"order_id": order_id, "source_version": version, "after_photo_id": after.id if after else None,
                  "before_photo_id": before.id if before else None, "capture_time_status": "unknown",
                  "upload_in_work_window": uploaded_in_work_window(after, order.started_at, order.completed_at)
                  if after else None, "duplicate_before": None, "duplicate_history": None,
                  "history_photos_scanned": 0, "history_scan_complete": True,
                  "vision": None, "score": None, "status": "needs_master_review", "needs_master_review": True,
                  "is_recommendation": True, "reasons": ["Время съёмки не подтверждено"]}
        if after is None:
            result["reasons"].append("Нет фото после; качество ремонта по изображению неизвестно")
        else:
            try:
                after_raw = await self.source.photo_bytes(after)
                after_details, after_image = fingerprint(after_raw)
                if before:
                    before_raw = await self.source.photo_bytes(before)
                    result["duplicate_before"] = compare_images(before_raw, after_raw)
                else:
                    before_raw = None
                    result["reasons"].append("Нет фото до для сравнения видимого дефекта")
                current_photo_ids = {after.id} | ({before.id} if before else set())
                previous = [(other_order, photo) for other_order in snapshot.orders
                            for photo in other_order.photos if photo.id not in current_photo_ids and photo.created_at and
                            (not after.created_at or utc(photo.created_at) <= utc(after.created_at))]
                previous.sort(key=lambda entry: utc(entry[1].created_at), reverse=True)
                result["history_scan_complete"] = len(previous) <= MAX_HISTORY_PHOTOS
                for other_order, photo in previous[:MAX_HISTORY_PHOTOS]:
                    try:
                        older = await self.cached_fingerprint(photo)
                        result["history_photos_scanned"] += 1
                        distance = imagehash.hex_to_hash(after_details["phash"]) - imagehash.hex_to_hash(older["phash"])
                        if older["sha256"] == after_details["sha256"] or distance <= 10:
                            older_raw = await self.source.photo_bytes(photo)
                            comparison = compare_images(older_raw, after_raw)
                            if comparison["duplicate"]:
                                result["duplicate_history"] = {"photo_id": photo.id, "order_id": other_order.id,
                                                               **comparison}
                                break
                    except (DataSourceError, ValueError):
                        result["history_scan_complete"] = False
                if result["upload_in_work_window"] is False:
                    result["reasons"].append("Время загрузки фото вне окна выполнения")
                elif result["upload_in_work_window"] is None:
                    result["reasons"].append("Время загрузки нельзя сверить с выполнением")
                if result["duplicate_before"] and result["duplicate_before"]["duplicate"]:
                    result["reasons"].append("Фото после технически повторяет фото до")
                if result["duplicate_history"]:
                    result["reasons"].append("Фото после повторяет ранее загруженное фото")
                if not result["history_scan_complete"]:
                    result["reasons"].append("История фото проверена не полностью")
                if self.settings.data_source == "synthetic" and self.llm.vision_enabled():
                    prompt = {"equipment_id": order.equipment_id,
                              "problem": scrub(order.description or order.title, snapshot),
                              "work_done": scrub(order.completion.work_done, snapshot),
                              "photo_labels": ["before", "after"] if before else ["after"]}
                    assessment = await self.llm.inspect_photo(prompt, sanitized_jpeg(open_image(before_raw))
                                                              if before_raw else None, sanitized_jpeg(after_image))
                    if assessment and vision_valid(assessment, snapshot):
                        result["vision"] = assessment.model_dump()
                    elif assessment:
                        result["reasons"].append("Ответ vision-модели не прошёл проверку")
                if result["vision"] is None:
                    result["reasons"].append("Видимое устранение дефекта не подтверждено моделью")
                else:
                    assessment = VisionAssessment.model_validate(result["vision"])
                    if assessment.confidence < 0.7:
                        result["reasons"].append("Низкая уверенность визуальной оценки")
                    if assessment.same_equipment is not True:
                        result["reasons"].append("То же оборудование по фото не подтверждено")
                    if assessment.defect_resolved is not True:
                        result["reasons"].append("Устранение видимого дефекта не подтверждено")
                    if assessment.quality == "unknown":
                        result["reasons"].append("Видимое качество неизвестно")
                    if result["reasons"] == ["Время съёмки не подтверждено"]:
                        result["score"] = {"excellent": 5, "good": 4, "mixed": 3,
                                           "poor": 2, "critical": 1}[assessment.quality]
                        result["status"] = "visual_assessment_available"
            except (DataSourceError, ValueError) as error:
                result["reasons"].append(f"Фото недоступно для проверки: {type(error).__name__}")
        latest = await self.source.snapshot()
        latest_order = next((item for item in latest.orders if item.id == order_id), None)
        if latest_order is None or source_version(latest_order) != version:
            raise ValueError("Сдача изменилась до сохранения фотоанализа")
        self.store.put_result("photo_review", str(order_id), version, result)
        return result
