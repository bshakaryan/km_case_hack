"""Duplicate-pair fixtures, not evidence of repair quality."""

import argparse
import json
import random
from pathlib import Path

from PIL import Image, ImageDraw


BASE = Path(__file__).resolve().parents[1]


def synthetic_photo(index):
    randomizer = random.Random(9100 + index)
    image = Image.new("RGB", (256, 256), (215, 210, 194))
    drawer = ImageDraw.Draw(image)
    for _ in range(90):
        left = randomizer.randrange(240)
        top = randomizer.randrange(240)
        color = tuple(randomizer.randrange(40, 220) for _ in range(3))
        drawer.rectangle((left, top, left + randomizer.randrange(4, 16), top + randomizer.randrange(4, 16)),
                         fill=color)
    drawer.ellipse((45, 45, 210, 210), outline=(35, 50, 60), width=14)
    drawer.line((20, 180, 220, 65), fill=(110 + index * 7, 35, 45), width=11)
    return image


def generate_photo_cases(cases_dir: Path, source_dir: Path | None = None):
    output = BASE / "data_gen" / "photos" / "duplicates"
    output.mkdir(parents=True, exist_ok=True)
    source_paths = [] if source_dir is None else sorted(
        path for path in source_dir.iterdir() if path.suffix.lower() in {".jpg", ".jpeg", ".png"}
    )
    cases = []
    for index in range(12):
        if source_paths:
            with Image.open(source_paths[index % len(source_paths)]) as source:
                original = source.convert("RGB").resize((256, 256))
        else:
            original = synthetic_photo(index)
        original_path = output / f"source-{index:02}.png"
        original.save(original_path)
        exact_path = output / f"exact-{index:02}.png"
        exact_path.write_bytes(original_path.read_bytes())
        compressed_path = output / f"compressed-{index:02}.jpg"
        original.save(compressed_path, quality=68)
        crop_path = output / f"crop-{index:02}.jpg"
        original.crop((8, 8, 248, 248)).resize((256, 256)).save(crop_path, quality=80)
        other_path = output / f"other-{index:02}.png"
        if len(source_paths) > 1:
            with Image.open(source_paths[(index + 1) % len(source_paths)]) as other_source:
                other_source.convert("RGB").resize((256, 256)).save(other_path)
        else:
            synthetic_photo(index + 30).save(other_path)
        for variant, candidate_path, duplicate in [
            ("exact", exact_path, True), ("recompressed", compressed_path, True),
            ("cropped", crop_path, True), ("different", other_path, False),
        ]:
            cases.append({
                "id": f"P-{len(cases) + 1:03}", "source": str(original_path.relative_to(BASE)).replace("\\", "/"),
                "candidate": str(candidate_path.relative_to(BASE)).replace("\\", "/"),
                "variant": variant, "expected_duplicate": duplicate,
                "label_source": "deterministic_transformation",
                "synthetic_source": not bool(source_paths),
            })
    cases_dir.mkdir(parents=True, exist_ok=True)
    (cases_dir / "photos_dup.json").write_text(json.dumps(cases, ensure_ascii=False, indent=2) + "\n",
                                                encoding="utf-8")
    return cases


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, help="Каталог локальных исходных фото оборудования")
    options = parser.parse_args()
    print(len(generate_photo_cases(BASE / "eval" / "cases", options.source_dir)))
