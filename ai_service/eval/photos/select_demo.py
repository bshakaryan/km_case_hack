"""Prepare a license-checked, non-999-krc03 subset for presentations."""

import csv
import shutil
from pathlib import Path


BASE = Path(__file__).resolve().parent
ALLOWED = {"airsoft/conveyor-belt-defects", "test-yfiry/conveyor-belt-damage-ucjlj"}


def main():
    with (BASE / "labels.csv").open(encoding="utf-8", newline="") as handle:
        rows = list(csv.DictReader(handle))
    destination = BASE / "demo_safe"
    selected = []
    for label in ("fixed", "not_fixed", "other_equipment"):
        match = next((row for row in rows if row["label"] == label and row["source"] in ALLOWED), None)
        if match is None:
            raise ValueError(f"Нет разрешённой демо-пары для {label}")
        selected.append(match)
        target = destination / f"{label}_{match['pair_id']}"
        target.mkdir(parents=True, exist_ok=True)
        for name in ("before.jpg", "after.jpg"):
            shutil.copyfile(BASE / "pairs" / match["pair_id"] / name, target / name)
    destination.mkdir(parents=True, exist_ok=True)
    with (destination / "manifest.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=("pair_id", "label", "source"))
        writer.writeheader()
        writer.writerows({field: row[field] for field in writer.fieldnames} for row in selected)
    print(f"Подготовлено {len(selected)} безопасных демо-пар в {destination}")


if __name__ == "__main__":
    main()
