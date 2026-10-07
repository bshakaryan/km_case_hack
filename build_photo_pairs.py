# #!/usr/bin/env python3
# """
# Сборка эталона фото-пар «до/после» для НарядAI из открытых датасетов.

# Источники (лицензии перепроверьте перед распространением):
#   - VisA (Amazon), CC BY 4.0 — https://github.com/amazon-science/spot-diff
#   - Roboflow Universe, CC BY 4.0 (нужен бесплатный API-ключ Roboflow):
#       test-yfiry/conveyor-belt-damage-ucjlj
#       sample-wy2mp/conveyor-belt-damage-detection
#       airsoft/conveyor-belt-defects
#       project-7mbdj/999-krc03
#       student-xx3fc/oilness-detection
#       project-unz0o/ooil

# Что получается (в naryad_photo_pairs.zip):
#   pairs/<pair_id>/before.jpg, after.jpg
#   labels.csv          — эталон: pair_id, source, kind, label, ...
#   duplicates/         — пары для проверки дублей (копия, пережатие, кроп, другое фото)
#   duplicates.csv
#   demo/               — 4 пары для показа на телефоне
#   DATA_SOURCES.md     — источники и лицензии (обязательно указать авторство CC BY 4.0)

# Метки label:
#   fixed               — проблема устранена
#   not_fixed           — проблема осталась
#   other_equipment     — на фото «после» другой объект
# Поле kind:
#   proxy               — VisA: дефектный и исправный объект ОДНОГО класса (не один и тот же экземпляр)
#   semi_synthetic      — Roboflow: «после» получено закрашиванием размеченной области дефекта
#   real_same_image     — Roboflow: «после» = то же фото без изменений (проблема не устранена)
#   cross_class         — фото разных объектов

# Запуск:
#   pip install pillow opencv-python-headless numpy roboflow
#   # VisA (~несколько ГБ):
#   #   aws s3 cp --no-sign-request s3://amazon-visual-anomaly/VisA_20220922.tar .
#   #   tar -xf VisA_20220922.tar -C visa
#   python build_photo_pairs.py --visa visa --roboflow-key <KEY> --out naryad_photo_pairs.zip
#   # Можно без одного из источников: --visa или --roboflow-key необязательны.
# """
import argparse
import csv
import io
import json
import random
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path

import numpy as np
from PIL import Image

try:
    import cv2
except ImportError:
    cv2 = None

IMG_EXT = {".jpg", ".jpeg", ".png", ".bmp"}
MAX_SIDE = 1024

ROBOFLOW_SETS = [
    ("test-yfiry", "conveyor-belt-damage-ucjlj", "conveyor"),
    ("sample-wy2mp", "conveyor-belt-damage-detection", "conveyor"),
    ("airsoft", "conveyor-belt-defects", "conveyor"),
    ("project-7mbdj", "999-krc03", "oil_dirt"),
    ("student-xx3fc", "oilness-detection", "oil"),
    ("project-unz0o", "ooil", "oil"),
]


def load_resized(path):
    im = Image.open(path).convert("RGB")
    im.thumbnail((MAX_SIDE, MAX_SIDE))
    return im


def save_jpg(im, path, quality=92):
    path.parent.mkdir(parents=True, exist_ok=True)
    im.save(path, "JPEG", quality=quality)


# ---------------- VisA ----------------

def scan_visa(root):
    # """Возвращает {class: {"normal": [...], "anomaly": [...]}} по структуре VisA/<class>/Data/Images/{Normal,Anomaly}."""
    out = {}
    for p in Path(root).rglob("*"):
        if p.suffix.lower() not in IMG_EXT:
            continue
        parts = [x.lower() for x in p.parts]
        if "normal" in parts:
            kind = "normal"
        elif "anomaly" in parts:
            kind = "anomaly"
        else:
            continue
        # класс — папка над "Data" (или над "Images", если Data нет)
        cls = None
        for i, x in enumerate(parts):
            if x in ("data", "images") and i > 0:
                cls = p.parts[i - 1]
                break
        if cls is None:
            continue
        out.setdefault(cls, {"normal": [], "anomaly": []})[kind].append(p)
    return {c: v for c, v in out.items() if v["normal"] and v["anomaly"]}


def build_visa_pairs(root, n_per_label, rng):
    data = scan_visa(root)
    if len(data) < 2:
        print(f"[VisA] найдено классов: {len(data)} — нужно минимум 2, пропускаю", file=sys.stderr)
        return []
    classes = sorted(data)
    pairs = []
    for label in ("fixed", "not_fixed", "other_equipment"):
        for _ in range(n_per_label):
            c = rng.choice(classes)
            before = rng.choice(data[c]["anomaly"])
            if label == "fixed":
                after, kind = rng.choice(data[c]["normal"]), "proxy"
            elif label == "not_fixed":
                pool = [x for x in data[c]["anomaly"] if x != before] or data[c]["anomaly"]
                after, kind = rng.choice(pool), "proxy"
            else:
                c2 = rng.choice([x for x in classes if x != c])
                after, kind = rng.choice(data[c2]["normal"] + data[c2]["anomaly"]), "cross_class"
            pairs.append(dict(source="VisA", kind=kind, label=label,
                              defect_class=c, before=before, after=after, after_img=None))
    return pairs


# ---------------- Roboflow ----------------

def download_roboflow(key, dest):
    from roboflow import Roboflow
    rf = Roboflow(api_key=key)
    got = []
    for ws, proj, topic in ROBOFLOW_SETS:
        try:
            project = rf.workspace(ws).project(proj)
            versions = project.versions()
            if not versions:
                raise RuntimeError("нет версий")
            ver = max(versions, key=lambda v: int(str(getattr(v, "version", "0")).split("/")[-1] or 0))
            loc = dest / f"{ws}__{proj}"
            ver.download("coco", location=str(loc), overwrite=True)
            got.append((loc, f"{ws}/{proj}", topic))
            print(f"[Roboflow] скачан {ws}/{proj}")
        except Exception as e:  # noqa: BLE001
            print(f"[Roboflow] пропуск {ws}/{proj}: {e}", file=sys.stderr)
    return got


def read_coco(folder):
    # """Список (image_path, [bbox x,y,w,h]) из всех _annotations.coco.json в папке."""
    items = []
    for ann in Path(folder).rglob("_annotations.coco.json"):
        js = json.loads(ann.read_text(encoding="utf-8"))
        boxes = {}
        for a in js.get("annotations", []):
            if a.get("bbox") and a["bbox"][2] > 2 and a["bbox"][3] > 2:
                boxes.setdefault(a["image_id"], []).append(a["bbox"])
        for im in js.get("images", []):
            p = ann.parent / im["file_name"]
            if im["id"] in boxes and p.exists():
                items.append((p, boxes[im["id"]]))
    return items


def inpaint_boxes(path, boxes, pad=0.15):
    # """«Убирает» дефект: закрашивает размеченные рамки по окружению (cv2.inpaint). Полусинтетика."""
    if cv2 is None:
        raise RuntimeError("нужен opencv-python-headless")
    img = cv2.imread(str(path))
    h, w = img.shape[:2]
    mask = np.zeros((h, w), np.uint8)
    for x, y, bw, bh in boxes:
        px, py = bw * pad, bh * pad
        x0, y0 = max(0, int(x - px)), max(0, int(y - py))
        x1, y1 = min(w, int(x + bw + px)), min(h, int(y + bh + py))
        mask[y0:y1, x0:x1] = 255
    if mask.mean() / 255 > 0.5:  # дефект занимает больше половины кадра — «устранение» неправдоподобно
        return None
    out = cv2.inpaint(img, mask, 7, cv2.INPAINT_TELEA)
    im = Image.fromarray(cv2.cvtColor(out, cv2.COLOR_BGR2RGB))
    im.thumbnail((MAX_SIDE, MAX_SIDE))
    return im


def build_roboflow_pairs(datasets, n_per_label, rng):
    pool = []
    for folder, name, topic in datasets:
        pool += [(p, b, name, topic) for p, b in read_coco(folder)]
    if not pool:
        return []
    rng.shuffle(pool)
    pairs, used = [], 0
    for label in ("fixed", "not_fixed", "other_equipment"):
        made = 0
        while made < n_per_label and used < len(pool):
            p, boxes, name, topic = pool[used]
            used += 1
            if label == "fixed":
                after_img = inpaint_boxes(p, boxes)
                if after_img is None:
                    continue
                pairs.append(dict(source=name, kind="semi_synthetic", label=label,
                                  defect_class=topic, before=p, after=None, after_img=after_img))
            elif label == "not_fixed":
                pairs.append(dict(source=name, kind="real_same_image", label=label,
                                  defect_class=topic, before=p, after=p, after_img=None))
            else:
                others = [x for x in pool if x[3] != topic] or [x for x in pool if x[0] != p]
                q = rng.choice(others)
                pairs.append(dict(source=name, kind="cross_class", label=label,
                                  defect_class=topic, before=p, after=q[0], after_img=None))
            made += 1
    return pairs


# ---------------- Дубли ----------------

def build_duplicates(images, n, rng, out_dir):
    rows = []
    variants = ["exact_copy", "recompressed", "cropped_resized", "different_photo"]
    for i in range(n):
        src = rng.choice(images)
        kind = variants[i % len(variants)]
        a = load_resized(src)
        if kind == "exact_copy":
            b = a.copy()
        elif kind == "recompressed":
            buf = io.BytesIO()
            a.save(buf, "JPEG", quality=rng.randint(35, 60))
            b = Image.open(io.BytesIO(buf.getvalue())).convert("RGB")
        elif kind == "cropped_resized":
            w, h = a.size
            dx, dy = int(w * rng.uniform(0.03, 0.10)), int(h * rng.uniform(0.03, 0.10))
            b = a.crop((dx, dy, w - dx, h - dy)).resize((int(w * 0.8), int(h * 0.8)))
        else:
            other = rng.choice([x for x in images if x != src] or images)
            b = load_resized(other)
        pid = f"dup_{i:04d}"
        save_jpg(a, out_dir / pid / "original.jpg")
        save_jpg(b, out_dir / pid / "candidate.jpg")
        rows.append(dict(pair_id=pid, variant=kind, is_duplicate=int(kind != "different_photo")))
    return rows


# ---------------- Сборка ----------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--visa", help="папка с распакованным VisA")
    ap.add_argument("--roboflow-key", help="API-ключ Roboflow (бесплатный аккаунт)")
    ap.add_argument("--roboflow-dir", help="уже скачанные Roboflow-наборы в COCO (вместо ключа)")
    ap.add_argument("--visa-per-label", type=int, default=30, help="пар VisA на каждую метку")
    ap.add_argument("--rf-per-label", type=int, default=30, help="пар Roboflow на каждую метку")
    ap.add_argument("--dups", type=int, default=200)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--out", default="naryad_photo_pairs.zip")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    work = Path(tempfile.mkdtemp(prefix="naryad_pairs_"))
    build = work / "build"
    pairs = []

    if args.visa:
        pairs += build_visa_pairs(args.visa, args.visa_per_label, rng)
        print(f"[VisA] пар: {sum(p['source'] == 'VisA' for p in pairs)}")

    rf_sets = []
    if args.roboflow_dir:
        rf_sets = [(d, d.name.replace("__", "/"), "conveyor" if "belt" in d.name else "oil")
                   for d in Path(args.roboflow_dir).iterdir() if d.is_dir()]
    elif args.roboflow_key:
        rf_sets = download_roboflow(args.roboflow_key, work / "roboflow")
    if rf_sets:
        rf_pairs = build_roboflow_pairs(rf_sets, args.rf_per_label, rng)
        print(f"[Roboflow] пар: {len(rf_pairs)}")
        pairs += rf_pairs

    if not pairs:
        sys.exit("Нет ни одного источника: укажите --visa и/или --roboflow-key")

    rng.shuffle(pairs)
    rows, all_images = [], []
    for i, p in enumerate(pairs):
        pid = f"pair_{i:04d}"
        d = build / "pairs" / pid
        save_jpg(load_resized(p["before"]), d / "before.jpg")
        after = p["after_img"] if p["after_img"] is not None else load_resized(p["after"])
        save_jpg(after, d / "after.jpg")
        all_images.append(p["before"])
        rows.append(dict(pair_id=pid, source=p["source"], kind=p["kind"], label=p["label"],
                         defect_class=p["defect_class"],
                         before_src=Path(p["before"]).name,
                         after_src="inpainted" if p["after_img"] is not None else Path(p["after"]).name))

    with open(build / "labels.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)

    dup_rows = build_duplicates(all_images, args.dups, rng, build / "duplicates")
    with open(build / "duplicates.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(dup_rows[0]))
        w.writeheader()
        w.writerows(dup_rows)

    # Демо: по одной паре каждого типа, предпочтительно конвейеры/масло
    demo = []
    for want in ("fixed", "not_fixed", "other_equipment"):
        cand = [r for r in rows if r["label"] == want and r["source"] != "VisA" and
                r["source"] != "project-7mbdj/999-krc03"] or \
               [r for r in rows if r["label"] == want and r["source"] == "VisA"]
        if cand:
            demo.append(cand[0])
    for r in demo:
        shutil.copytree(build / "pairs" / r["pair_id"], build / "demo" / f"{r['label']}_{r['pair_id']}")
    if dup_rows:
        shutil.copytree(build / "duplicates" / dup_rows[0]["pair_id"], build / "demo" / "duplicate_old_photo")

    stats = {}
    for r in rows:
        stats.setdefault(f"{r['kind']}/{r['label']}", 0)
        stats[f"{r['kind']}/{r['label']}"] += 1
    sources = sorted({r["source"] for r in rows})
    (build / "DATA_SOURCES.md").write_text(
        "# Источники фото-эталона НарядAI\n\n"
        "Набор собран из открытых источников. Страницы VisA, airsoft и test-yfiry "
        "указывают CC BY 4.0. Для остальных источников подтвердите лицензию у автора "
        "перед распространением производных изображений; всегда указывайте авторство.\n\n"
        + "\n".join(f"- {s}" + (" — https://github.com/amazon-science/spot-diff (Zou et al., ECCV 2022)"
                                if s == "VisA" else f" — https://universe.roboflow.com/{s}")
                    for s in sources)
        + "\n\n## Важно для метрик\n\n"
        "- `proxy` (VisA): дефектный и исправный объект одного класса, НЕ один и тот же экземпляр.\n"
        "- `semi_synthetic`: «после» получено закрашиванием размеченной области дефекта (cv2.inpaint), "
        "а не реальным ремонтом. Показывать отдельной строкой.\n"
        "- `real_same_image`: «после» = то же фото, проблема не устранена.\n"
        "- Для демо и презентации `project-7mbdj/999-krc03` не использовать; "
        "создайте `demo_safe/` отдельной командой.\n"
        "- Ни одна метрика здесь не является точностью на реальном ремонте.\n\n"
        f"## Состав (seed={args.seed})\n\n"
        + "\n".join(f"- {k}: {v}" for k, v in sorted(stats.items()))
        + f"\n- дубли: {len(dup_rows)}\n",
        encoding="utf-8")

    out = Path(args.out).resolve()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(build.rglob("*")):
            if f.is_file():
                z.write(f, f.relative_to(build))
    shutil.rmtree(work, ignore_errors=True)
    print(f"Готово: {out}  пар: {len(rows)}  дублей: {len(dup_rows)}")
    for k, v in sorted(stats.items()):
        print(f"  {k}: {v}")


if __name__ == "__main__":
    main()
