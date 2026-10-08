"""Validate frozen JPEGs and bind an OpenAI vision result to one attempt."""
from __future__ import annotations

import base64
import hashlib
import io
from typing import Literal

from PIL import Image, UnidentifiedImageError
from pydantic import BaseModel, ConfigDict, Field

from .llm_client import VisionAssessment

MAX_IMAGE_BYTES = 4 * 1024 * 1024
MAX_IMAGE_PIXELS = 4_000_000

class PhotoCheck(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)
    status: Literal["checked", "no_after"]
    method: Literal["openai_vision"] = "openai_vision"
    scope: Literal["submission_selected_pair"] = "submission_selected_pair"
    before_id: int | None = Field(default=None, gt=0)
    after_id: int | None = Field(default=None, gt=0)
    vision: VisionAssessment | None = None
    capture_time_status: Literal["unknown"] = "unknown"
    history_status: Literal["not_checked"] = "not_checked"


def selected_ids(metadata):
    return {
        kind: max((photo["id"] for photo in metadata if photo["kind"] == kind), default=None)
        for kind in ("before", "after")
    }


def decode_content(metadata, content):
    """Validate exact frozen image bytes and JPEG bounds before any API request."""
    decoded = []
    try:
        for photo, media in zip(metadata, content, strict=True):
            raw = base64.b64decode(media["data_base64"], validate=True)
            if (media["id"] != photo["id"] or not raw or len(raw) > MAX_IMAGE_BYTES
                    or hashlib.sha256(raw).hexdigest() != photo["sha256"]):
                raise ValueError("invalid_photo_content")
            try:
                with Image.open(io.BytesIO(raw)) as image:
                    if (image.format != "JPEG" or getattr(image, "n_frames", 1) != 1
                            or image.width * image.height > MAX_IMAGE_PIXELS):
                        raise ValueError("invalid_photo_content")
                    image.load()
            except (UnidentifiedImageError, OSError, Image.DecompressionBombError):
                raise ValueError("invalid_photo_content") from None
            decoded.append({"id": photo["id"], "data": raw})
    except (ValueError, TypeError, UnicodeError):
        raise ValueError("invalid_photo_content") from None
    return decoded


def selected_pair(metadata, decoded):
    selected = selected_ids(metadata)
    content = {row["id"]: row["data"] for row in decoded}
    before = content.get(selected["before"])
    after = content.get(selected["after"])
    return selected, before, after
