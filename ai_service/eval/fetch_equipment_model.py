"""Explicitly fetch the optional CPU embedding model into ignored local state."""

import hashlib
import urllib.request

from app.equipment_match import DEFAULT_MODEL, MODEL_SHA256


MODEL_URL = ("https://huggingface.co/opencv/opencv_zoo/resolve/main/models/"
             "image_classification_mobilenet/image_classification_mobilenetv2_2022apr.onnx")


def main():
    DEFAULT_MODEL.parent.mkdir(parents=True, exist_ok=True)
    if DEFAULT_MODEL.is_file() and hashlib.sha256(DEFAULT_MODEL.read_bytes()).hexdigest() == MODEL_SHA256:
        print(f"Модель уже проверена: {DEFAULT_MODEL}")
        return
    temporary = DEFAULT_MODEL.with_suffix(".download")
    urllib.request.urlretrieve(MODEL_URL, temporary)
    if hashlib.sha256(temporary.read_bytes()).hexdigest() != MODEL_SHA256:
        temporary.unlink(missing_ok=True)
        raise ValueError("SHA-256 модели не совпадает с проверенным файлом")
    temporary.replace(DEFAULT_MODEL)
    print(f"Модель проверена: {DEFAULT_MODEL}")


if __name__ == "__main__":
    main()
