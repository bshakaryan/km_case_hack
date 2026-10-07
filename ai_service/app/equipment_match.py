"""Conservative visual mismatch gate; never asserts that equipment is identical."""

import hashlib
import os
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from .photos import open_image, orb_overlap, ssim


MODEL_SHA256 = "c0c3f76d93fa3fd6580652a45618618a220fced18babf65774ed169de0432ad5"
DEFAULT_MODEL = Path(__file__).resolve().parents[1] / "models" / "mobilenetv2.onnx"
FEATURE_LAYER = "onnx_node!GlobalAveragePool_97"
DEFAULT_THRESHOLD = 0.586


class EquipmentMatcher:
    def __init__(self, model_path: Path | None = None, threshold: float = DEFAULT_THRESHOLD):
        self.model_path = Path(model_path or os.getenv("AI_IMAGE_EMBEDDING_MODEL") or DEFAULT_MODEL)
        self.threshold = threshold
        self.net = None
        self.model_error = None
        if not self.model_path.is_file():
            self.model_error = f"Нет весов MobileNetV2: {self.model_path}. Запустите make setup."
        elif hashlib.sha256(self.model_path.read_bytes()).hexdigest() != MODEL_SHA256:
            self.model_error = f"Некорректный SHA-256 весов MobileNetV2: {self.model_path}. Запустите make setup."
        else:
            try:
                self.net = cv2.dnn.readNetFromONNX(str(self.model_path))
                self.net.setPreferableBackend(cv2.dnn.DNN_BACKEND_OPENCV)
                self.net.setPreferableTarget(cv2.dnn.DNN_TARGET_CPU)
            except cv2.error as error:
                self.model_error = f"Не удалось загрузить веса MobileNetV2: {self.model_path}: {error}"

    def require_ready(self):
        if self.model_error:
            raise RuntimeError(self.model_error)

    def embedding(self, image: Image.Image):
        resized = np.asarray(image.resize((224, 224)), dtype=np.float32) / 255.0
        normalized = (resized - np.array([0.485, 0.456, 0.406], dtype=np.float32)) / np.array(
            [0.229, 0.224, 0.225], dtype=np.float32)
        self.net.setInput(np.ascontiguousarray(normalized.transpose(2, 0, 1)[None]))
        vector = self.net.forward(FEATURE_LAYER).reshape(-1)
        return vector / max(float(np.linalg.norm(vector)), 1e-9)

    def compare(self, before_raw: bytes, after_raw: bytes):
        if self.net is None:
            return {"status": "unknown", "model_available": False, "embedding_cosine": None, "orb_inliers": None,
                    "orb_overlap": None, "ssim": None}
        before = open_image(before_raw)
        after = open_image(after_raw)
        cosine = float(np.dot(self.embedding(before), self.embedding(after)))
        local = orb_overlap(before, after)
        similarity = ssim(before, after)
        different = cosine < self.threshold and local["inliers"] < 12 and similarity < 0.45
        return {"status": "different" if different else "unknown", "model_available": True,
                "embedding_cosine": round(cosine, 4),
                "orb_inliers": local["inliers"], "orb_overlap": local["overlap"],
                "ssim": round(similarity, 4)}
