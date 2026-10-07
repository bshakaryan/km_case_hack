"""Evaluate the existing photo comparison and vision client on labeled public pairs."""

import argparse
import asyncio
import csv
import hashlib
import json
import os
import random
import re
import time
from pathlib import Path

from dotenv import load_dotenv
from pydantic import SecretStr

from app.config import Settings
from app.equipment_match import EquipmentMatcher, MODEL_SHA256
from app.llm_client import LLMClient
from app.photos import compare_images, open_image, sanitized_jpeg
from app.storage import AIStore


BASE_DIR = Path(__file__).resolve().parents[1]
PHOTO_DIR = BASE_DIR / "eval" / "photos"
REPORT_DIR = BASE_DIR / "reports"
KINDS = ("proxy", "semi_synthetic", "real_same_image", "cross_class")
LABELS = ("fixed", "not_fixed", "other_equipment", "needs_master_review")


def read_manifest(path: Path, prefix: str):
    with path.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows or any(not re.fullmatch(rf"{prefix}_\d{{4}}", row.get("pair_id", "")) for row in rows):
        raise ValueError(f"Недопустимый манифест {path}")
    if len({row["pair_id"] for row in rows}) != len(rows):
        raise ValueError(f"Повтор pair_id в {path}")
    return rows


def select_cases(pairs: list[dict], duplicates: list[dict], pilot: bool):
    if not pilot:
        return pairs, duplicates
    selected = []
    for kind in KINDS:
        group = [row for row in pairs if row["kind"] == kind]
        if kind == "proxy":
            selected.extend(next(row for row in group if row["label"] == label)
                            for label in ("fixed", "not_fixed"))
        else:
            selected.extend(group[:4 if kind == "cross_class" else 2])
    selected_duplicates = [next(row for row in duplicates if row["variant"] == variant)
                           for variant in ("exact_copy", "different_photo")]
    return selected, selected_duplicates


def photo_path(root: Path, folder: str, pair_id: str, name: str):
    path = root / folder / pair_id / name
    if not path.is_file():
        raise FileNotFoundError(path)
    return path


def predict_from_vision(assessment):
    if assessment is None or assessment.confidence < 0.7:
        return "needs_master_review"
    if re.search(r"\d", " ".join([assessment.explanation, *assessment.issues])):
        return "needs_master_review"
    if assessment.same_equipment is False:
        return "other_equipment"
    if assessment.same_equipment is not True:
        return "needs_master_review"
    if assessment.defect_resolved is True:
        return "fixed"
    if assessment.defect_resolved is False:
        return "not_fixed"
    return "needs_master_review"


def confusion(rows: list[dict], labels: tuple[str, ...]):
    return {expected: {predicted: sum(row["label"] == expected and row["prediction"] == predicted
                                     for row in rows) for predicted in labels} for expected in labels}


def category_metrics(rows: list[dict]):
    count = len(rows)
    decided = [row for row in rows if row["prediction"] != "needs_master_review"]
    mistakes = [row for row in decided if row["label"] != row["prediction"]]
    return {
        "count": count,
        "decided_count": len(decided),
        "coverage": round(len(decided) / count, 4) if count else None,
        "accuracy_decided": round((len(decided) - len(mistakes)) / len(decided), 4) if decided else None,
        "needs_master_review_rate": round(sum(row["prediction"] == "needs_master_review"
                                              for row in rows) / count, 4) if count else None,
        "confusion": confusion(rows, LABELS),
        "errors": [{"pair_id": row["pair_id"], "expected": row["label"],
                    "predicted": row["prediction"], "reason": row["reason"]}
                   for row in mistakes[:3]],
        "error_count": len(mistakes),
    }


def split_pairs(pairs: list[dict]):
    groups = {}
    for row in pairs:
        groups.setdefault((row["source"], row["before_src"]), []).append(row)
    shuffled = list(groups.values())
    random.Random(42).shuffle(shuffled)
    train, holdout = [], []
    for group in shuffled:
        target = train if len(train) <= len(holdout) else holdout
        target.extend(group)
    return train, holdout


def gate_features(pairs: list[dict], root: Path, matcher: EquipmentMatcher):
    cache_path = BASE_DIR / "state" / "photo_gate_features.json"
    identity = hashlib.sha256((root / "labels.csv").read_bytes()).hexdigest() + (
        MODEL_SHA256 if matcher.net is not None else "missing")
    if cache_path.exists():
        saved = json.loads(cache_path.read_text(encoding="utf-8"))
        if saved.get("identity") == identity:
            return saved["features"]
    features = {}
    for index, row in enumerate(pairs, 1):
        before = photo_path(root, "pairs", row["pair_id"], "before.jpg").read_bytes()
        after = photo_path(root, "pairs", row["pair_id"], "after.jpg").read_bytes()
        features[row["pair_id"]] = matcher.compare(before, after)
        if index % 20 == 0:
            print(json.dumps({"equipment_features": index, "total": len(pairs)}), flush=True)
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps({"identity": identity, "features": features}, indent=2), encoding="utf-8")
    return features


def gate_decision(feature: dict, threshold: float):
    cosine = feature["embedding_cosine"]
    return (cosine is not None and cosine < threshold and
            feature["orb_inliers"] < 12 and feature["ssim"] < 0.45)


def calibrate_gate(train: list[dict], holdout: list[dict], features: dict):
    eligible_train = [row for row in train if row["kind"] in
                      ("semi_synthetic", "real_same_image", "cross_class")]
    candidates = sorted({features[row["pair_id"]]["embedding_cosine"] for row in eligible_train
                         if features[row["pair_id"]]["embedding_cosine"] is not None})
    candidates = [0.0, *candidates, 1.01]
    options = []
    for threshold in candidates:
        wrong = sum(gate_decision(features[row["pair_id"]], threshold)
                    for row in eligible_train if row["kind"] != "cross_class")
        found = sum(gate_decision(features[row["pair_id"]], threshold)
                    for row in eligible_train if row["kind"] == "cross_class")
        if wrong == 0:
            options.append((found, -threshold, threshold))
    threshold = max(options)[2]

    def summary(rows):
        eligible = [row for row in rows if row["kind"] in
                    ("semi_synthetic", "real_same_image", "cross_class")]
        negative = [row for row in eligible if row["kind"] == "cross_class"]
        positive = [row for row in eligible if row["kind"] != "cross_class"]
        return {"cross_class_detected": sum(gate_decision(features[row["pair_id"]], threshold)
                                            for row in negative),
                "cross_class_total": len(negative),
                "same_image_false_rejections": sum(gate_decision(features[row["pair_id"]], threshold)
                                                   for row in positive),
                "same_image_total": len(positive)}

    return {"threshold": threshold, "train": summary(train), "holdout": summary(holdout),
            "positive_definition": "semi_synthetic и real_same_image; proxy исключён из калибровки"}


def duplicate_metrics(rows: list[dict]):
    count = len(rows)
    correct = sum(row["label"] == row["prediction"] for row in rows)
    true_positive = sum(row["label"] == "1" and row["prediction"] == "1" for row in rows)
    predicted_positive = sum(row["prediction"] == "1" for row in rows)
    positive = sum(row["label"] == "1" for row in rows)
    mistakes = [row for row in rows if row["label"] != row["prediction"]]
    return {
        "count": count,
        "accuracy": round(correct / count, 4) if count else None,
        "precision": round(true_positive / predicted_positive, 4) if predicted_positive else None,
        "recall": round(true_positive / positive, 4) if positive else None,
        "needs_master_review_rate": 0.0,
        "confusion": confusion(rows, ("0", "1")),
        "errors": [{"pair_id": row["pair_id"], "expected": row["label"],
                    "predicted": row["prediction"], "reason": row["variant"]}
                   for row in mistakes[:3]],
        "error_count": len(mistakes),
    }


async def evaluate_pair(row: dict, root: Path, llm: LLMClient | None, gate: dict, gate_threshold: float):
    before = photo_path(root, "pairs", row["pair_id"], "before.jpg").read_bytes()
    after = photo_path(root, "pairs", row["pair_id"], "after.jpg").read_bytes()
    started = time.perf_counter()
    duplicate = compare_images(before, after)
    assessment = None
    if duplicate["exact"]:
        prediction = "not_fixed"
        reason = "Побайтово одинаковое фото до и после"
    elif gate_decision(gate, gate_threshold):
        prediction = "other_equipment"
        reason = "Код: низкое сходство CPU-эмбеддингов, ORB и SSIM"
    elif llm is None:
        prediction = "needs_master_review"
        reason = "Vision API не включён"
    else:
        prompt = {"problem": "Сравни состояние объекта до и после. Исход работ неизвестен.",
                  "work_done": "Определи по изображениям, исчез ли видимый дефект; не предполагай результат.",
                  "photo_labels": ["before", "after"]}
        assessment = await llm.inspect_photo(prompt, sanitized_jpeg(open_image(before)),
                                             sanitized_jpeg(open_image(after)))
        prediction = predict_from_vision(assessment)
        reason = (assessment.explanation[:200] if assessment else "Нет валидного ответа vision API")
    return {"pair_id": row["pair_id"], "kind": row["kind"], "source": row["source"],
            "label": row["label"], "prediction": prediction, "reason": reason,
            "duplicate": duplicate["duplicate"], "gate": gate,
            "gate_prediction": "other_equipment" if gate_decision(gate, gate_threshold) else "unknown",
            "confidence": assessment.confidence if assessment else None,
            "elapsed_seconds": round(time.perf_counter() - started, 3)}


def evaluate_duplicate(row: dict, root: Path):
    original = photo_path(root, "duplicates", row["pair_id"], "original.jpg").read_bytes()
    candidate = photo_path(root, "duplicates", row["pair_id"], "candidate.jpg").read_bytes()
    started = time.perf_counter()
    comparison = compare_images(original, candidate)
    return {"pair_id": row["pair_id"], "variant": row["variant"],
            "label": row["is_duplicate"], "prediction": str(int(comparison["duplicate"])),
            "elapsed_seconds": round(time.perf_counter() - started, 3),
            "phash_distance": comparison["phash_distance"], "ssim": comparison["ssim"],
            "orb_inliers": comparison["inliers"], "orb_overlap": comparison["overlap"]}


async def run(mode: str, root: Path, model: str | None, provider: str,
              input_price: float | None, output_price: float | None, rules_only: bool,
              embedding_model: Path | None = None):
    pairs = read_manifest(root / "labels.csv", "pair")
    duplicates = read_manifest(root / "duplicates.csv", "dup")
    if len(pairs) != 180 or len(duplicates) != 200:
        raise ValueError(f"Ожидалось 180 фото-пар и 200 дублей; найдено {len(pairs)} и {len(duplicates)}")
    train, holdout = split_pairs(pairs)
    matcher = EquipmentMatcher(embedding_model)
    if not rules_only and matcher.net is None:
        raise ValueError("Для vision API сначала установите проверенную CPU-модель через eval.fetch_equipment_model")
    features = gate_features(pairs, root, matcher)
    calibration = calibrate_gate(train, holdout, features)
    pairs, duplicates = select_cases(holdout if mode == "pilot" else pairs, duplicates, mode == "pilot")
    llm = None
    store = None
    if not rules_only:
        load_dotenv(BASE_DIR / ".env", override=False)
        load_dotenv(BASE_DIR.parent / ".env", override=False)
        key = ((os.getenv("OPENAI_API_KEY") or os.getenv("OPEN_AI_API_KEY"))
               if provider == "openai" else os.getenv("ANTHROPIC_API_KEY"))
        if not key or not model:
            raise ValueError("Для vision-прогона нужны API-ключ и --model; без ключа доступен только --rules-only")
        store = AIStore(f"sqlite:///{(BASE_DIR / 'state' / 'photo_benchmark_cache.db').as_posix()}")
        store.initialize()
        settings = Settings(demo_mode=False, data_source="synthetic", llm_provider=provider,
                            llm_model_fast=model, llm_model_vision=model,
                            openai_api_key=SecretStr(key if provider == "openai" else ""),
                            anthropic_api_key=SecretStr(key if provider == "anthropic" else ""))
        llm = LLMClient(settings, store)
    started = time.perf_counter()
    try:
        pair_results = []
        for index, row in enumerate(pairs, 1):
            pair_results.append(await evaluate_pair(row, root, llm, features[row["pair_id"]],
                                                    calibration["threshold"]))
            if index % 10 == 0:
                print(json.dumps({"processed_pairs": index, "total_pairs": len(pairs)}, ensure_ascii=False), flush=True)
        duplicate_results = [evaluate_duplicate(row, root) for row in duplicates]
    finally:
        if store is not None:
            store.close()
    elapsed = round(time.perf_counter() - started, 3)
    token_input = llm.input_tokens if llm else 0
    token_output = llm.output_tokens if llm else 0
    calls = llm.request_count if llm else 0
    cost = (round((token_input * input_price + token_output * output_price) / 1_000_000, 6)
            if input_price is not None and output_price is not None and (token_input or token_output or not calls)
            else None)
    result = {
        "mode": mode, "model": model if llm else None, "provider": provider if llm else None,
        "scope": "public_proxy_and_semi_synthetic_not_real_repair_accuracy",
        "manifest_sha256": hashlib.sha256((root / "labels.csv").read_bytes()).hexdigest(),
        "equipment_gate": {**calibration, "model_available": matcher.net is not None,
                           "model_sha256": MODEL_SHA256 if matcher.net is not None else None},
        "split": {"train_ids": [row["pair_id"] for row in train],
                  "holdout_ids": [row["pair_id"] for row in holdout]},
        "pairs": {kind: category_metrics([row for row in pair_results if row["kind"] == kind]) for kind in KINDS},
        "duplicates": {**duplicate_metrics(duplicate_results),
                       "by_variant": {variant: duplicate_metrics([row for row in duplicate_results
                                                                  if row["variant"] == variant])
                                      for variant in ("exact_copy", "recompressed", "cropped_resized",
                                                      "different_photo")}},
        "timing": {"elapsed_seconds": elapsed,
                   "mean_pair_seconds": round(sum(row["elapsed_seconds"] for row in pair_results) / len(pair_results), 3)},
        "usage": {"api_attempts": calls, "cache_hits": llm.cache_hits if llm else 0,
                  "input_tokens": token_input, "output_tokens": token_output,
                  "estimated_cost_usd": cost, "input_price_per_million": input_price,
                  "output_price_per_million": output_price,
                  "cost_note": "Неизвестна: вызовы завершились без сведений о токенах" if calls and cost is None
                  else "Оценка по возвращённым токенам и стандартной цене, не счёт провайдера"},
        "cases": pair_results,
        "duplicate_cases": duplicate_results,
    }
    return result


def markdown_table(result: dict):
    lines = ["| Категория | Пар | Покрытие | Точность среди решённых | Проверка мастером | Ошибок среди решённых |",
             "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for kind in KINDS:
        metric = result["pairs"][kind]
        lines.append(f"| {kind} | {metric['count']} | {metric['coverage']} | "
                     f"{metric['accuracy_decided']} | {metric['needs_master_review_rate']} | "
                     f"{metric['error_count']} |")
    metric = result["duplicates"]
    lines.append(f"| дубли | {metric['count']} | 1.0 | {metric['accuracy']} | 0.0 | "
                 f"{metric['error_count']} |")
    return lines


def markdown_confusion(title: str, metric: dict, labels: tuple[str, ...]):
    lines = [f"### {title}", "", "Строки — эталон, столбцы — предсказание.", "",
             "| Эталон / прогноз | " + " | ".join(labels) + " |",
             "| --- | " + " | ".join("---:" for _ in labels) + " |"]
    for expected in labels:
        lines.append("| " + expected + " | " + " | ".join(str(metric["confusion"][expected][predicted])
                                                        for predicted in labels) + " |")
    lines.extend(["", "Ошибки (не более трёх, без выдуманных случаев):"])
    if metric["errors"]:
        for item in metric["errors"]:
            lines.append(f"- `{item['pair_id']}`: ожидалось `{item['expected']}`, получено "
                         f"`{item['predicted']}`; {' '.join(item['reason'].split())}")
    else:
        lines.append("- Ошибок в этом наборе нет.")
    lines.append("")
    return lines


def markdown_report(result: dict, pilot: dict | None):
    usage = result["usage"]
    total_cases = sum(group["count"] for group in result["pairs"].values())
    decided = sum(group["decided_count"] for group in result["pairs"].values())
    total_correct = decided - sum(group["error_count"] for group in result["pairs"].values())
    conveyor = category_metrics([row for row in result["cases"] if
                                 row["source"] in ("airsoft/conveyor-belt-defects",
                                                   "test-yfiry/conveyor-belt-damage-ucjlj")])
    lines = ["## Фото-эталон: открытые данные, не реальные ремонты", "",
             "Этот набор **не** оценивает точность подтверждения реального ремонта. VisA `proxy` — разные экземпляры "
             "одного класса; `semi_synthetic` — inpaint; `real_same_image` — неизменённое фото. "
             "Отсутствие времени съёмки и рабочего контекста в этих парах означает, что в реальном наряде "
             "финальное решение остаётся за мастером. Покрытие = решённые / все; точность = верные / решённые. "
             "`needs_master_review` не ошибка и исключается из знаменателя точности.", "",
             f"Режим: `{result['mode']}`, модель: `{result['model'] or 'без LLM'}`. "
             f"Время: {result['timing']['elapsed_seconds']} с; среднее на фото-пару: "
             f"{result['timing']['mean_pair_seconds']} с. Попытки API: {usage['api_attempts']}, "
             f"кэш: {usage['cache_hits']}, токены вход/выход: "
             f"{usage['input_tokens']}/{usage['output_tokens']}; расчётная стоимость: "
             f"{usage['estimated_cost_usd']} USD (стандартные цены, не счёт провайдера). "
             f"Общее покрытие: {round(decided / total_cases, 4)} ({decided}/{total_cases}); "
             f"точность среди решённых: {round(total_correct / decided, 4) if decided else None} "
             f"({total_correct}/{decided}).", ""]
    if pilot:
        first = pilot["usage"]
        lines.append(f"Пилот {sum(group['count'] for group in pilot['pairs'].values())} vision-пар: "
                     f"{pilot['timing']['elapsed_seconds']} с, "
                     f"{first['api_attempts']} попыток API, "
                     f"{first['input_tokens']}/{first['output_tokens']} токенов, "
                     f"{first['estimated_cost_usd']} USD. Полный прогон использовал кэш пилота; "
                     "его стоимость указана отдельно, не включает пилот.")
        if first["estimated_cost_usd"] is not None and usage["estimated_cost_usd"] is not None:
            lines.append(f"Оба запуска вместе: {round(first['estimated_cost_usd'] + usage['estimated_cost_usd'], 6)} USD, "
                         f"{round(pilot['timing']['elapsed_seconds'] + result['timing']['elapsed_seconds'], 3)} с.")
        lines.append("")
    lines.extend(["### Главные метрики", "",
                  "Конвейерные пары — только два набора с подтверждённой лицензией; "
                  "`999-krc03` в демонстрации и презентации не использовать.", "",
                  "| Набор | Пар | Покрытие | Точность среди решённых |",
                  "| --- | ---: | ---: | ---: |",
                  f"| cross_class | {result['pairs']['cross_class']['count']} | "
                  f"{result['pairs']['cross_class']['coverage']} | "
                  f"{result['pairs']['cross_class']['accuracy_decided']} |",
                  f"| конвейерные пары | {conveyor['count']} | {conveyor['coverage']} | "
                  f"{conveyor['accuracy_decided']} |",
                  f"| дубли | {result['duplicates']['count']} | 1.0 | "
                  f"{result['duplicates']['accuracy']} |", "",
                  "### Покрытие и точность по категориям", ""])
    lines.extend(markdown_table(result))
    gate = result["equipment_gate"]
    lines.extend(["", "### Проверка другого оборудования до LLM", "",
                  f"CPU MobileNetV2 + ORB + SSIM: модель доступна — {gate['model_available']}; "
                  f"порог cosine < {round(gate['threshold'], 4)}. Калибровка на "
                  f"{len(result['split']['train_ids'])} парах; отложенная проверка на "
                  f"{len(result['split']['holdout_ids'])} парах. "
                  "VisA proxy не является эталоном одного физического экземпляра и исключён из калибровки.", "",
                  "| Часть | Найдено cross_class | Ошибочно отвергнуто same-image |",
                  "| --- | ---: | ---: |",
                  f"| train | {gate['train']['cross_class_detected']}/{gate['train']['cross_class_total']} | "
                  f"{gate['train']['same_image_false_rejections']}/{gate['train']['same_image_total']} |",
                  f"| holdout | {gate['holdout']['cross_class_detected']}/{gate['holdout']['cross_class_total']} | "
                  f"{gate['holdout']['same_image_false_rejections']}/{gate['holdout']['same_image_total']} |", ""])
    lines.extend(["### Дубли по варианту", "",
                  "| Вариант | Пар | Верно | Ложноположительных |",
                  "| --- | ---: | ---: | ---: |"])
    for variant, metric in result["duplicates"]["by_variant"].items():
        false_positive = metric["confusion"]["0"]["1"]
        lines.append(f"| {variant} | {metric['count']} | {metric['count'] - metric['error_count']} | "
                     f"{false_positive} |")
    lines.extend(["", "### VisA proxy — отдельный стресс-тест", "",
                  "В `proxy` фото одного класса, но разных экземпляров: метка «исправлено» описывает "
                  "состояние двух разных предметов, а не реальный ремонт одной машины. Поэтому "
                  "модель вправе отказаться от ответа; высокая точность ремонта здесь не ожидается.", ""])
    lines.append("")
    for kind in KINDS:
        lines.extend(markdown_confusion(kind, result["pairs"][kind], LABELS))
    lines.extend(markdown_confusion("дубли", result["duplicates"], ("0", "1")))
    lines.append(f"Дубли: precision {result['duplicates']['precision']}, recall {result['duplicates']['recall']}.")
    lines.extend(["", "Промпт бенчмарка нейтрален: исход ремонта неизвестен. Прежний текст "
                  "«после устранения дефекта» подсказывал ответ «исправлено», а не «не устранено». "
                  "Прежние предсказания `not_fixed` на inpaint чаще создавались техническим "
                  "дубль-фильтром без вызова LLM; теперь только побайтовый дубль даёт такой вывод. "
                  "Порог дубликатов разрабатывался на этих же 200 парах; нужна внешняя проверка.", "",
                  "Официальные тарифы на дату прогона: "
                  "[GPT-4.1 Mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini) и "
                  "[GPT-4.1](https://developers.openai.com/api/docs/models/gpt-4.1). "
                  "Расчёт не учитывает возможные скидки кэшированных входных токенов.", ""])
    return "\n".join(lines)


def comparison_report(mini: dict, strong: dict, mini_pilot: dict | None, strong_pilot: dict | None):
    def summary(result):
        cases = result["cases"]
        holdout = set(result["split"]["holdout_ids"])
        return category_metrics([row for row in cases if row["pair_id"] in holdout])

    lines = ["### Сравнение vision-моделей на отложенной половине", "",
             "Обе модели получают одинаковый нейтральный промпт и один кодовый фильтр. "
             "Время полного запуска включает проверку дублей, а стоимость — только возвращённые API-токены.", "",
             "| Модель | Holdout покрытие | Holdout точность решённых | API-вызовы | Время, с | Стоимость, USD |",
             "| --- | ---: | ---: | ---: | ---: | ---: |"]
    for result in (mini, strong):
        metric = summary(result)
        lines.append(f"| {result['model']} | {metric['coverage']} | {metric['accuracy_decided']} | "
                     f"{result['usage']['api_attempts']} | {result['timing']['elapsed_seconds']} | "
                     f"{result['usage']['estimated_cost_usd']} |")
    if mini_pilot and strong_pilot:
        lines.extend(["", "Пилот — 10 vision-пар из holdout плюс 2 контрольных дубля:", "",
                      "| Модель | Покрытие | Точность решённых | Время, с | Стоимость, USD |",
                      "| --- | ---: | ---: | ---: | ---: |"])
        for pilot in (mini_pilot, strong_pilot):
            metric = category_metrics(pilot["cases"])
            lines.append(f"| {pilot['model']} | {metric['coverage']} | {metric['accuracy_decided']} | "
                         f"{pilot['timing']['elapsed_seconds']} | {pilot['usage']['estimated_cost_usd']} |")
    lines.extend(["", "Категории для сильной модели:", ""])
    lines.extend(markdown_table(strong))
    strong_conveyor = category_metrics([row for row in strong["cases"] if
                                        row["source"] in ("airsoft/conveyor-belt-defects",
                                                          "test-yfiry/conveyor-belt-damage-ucjlj")])
    lines.extend(["", f"Конвейерные пары `{strong['model']}`: покрытие {strong_conveyor['coverage']}, "
                  f"точность решённых {strong_conveyor['accuracy_decided']} "
                  f"({strong_conveyor['decided_count']}/{strong_conveyor['count']} решено).", ""])
    for kind in ("semi_synthetic", "proxy"):
        lines.extend(markdown_confusion(f"{kind} — {strong['model']}", strong["pairs"][kind], LABELS))
    lines.append("")
    return "\n".join(lines)


def main():
    load_dotenv(BASE_DIR / ".env", override=False)
    load_dotenv(BASE_DIR.parent / ".env", override=False)
    parser = argparse.ArgumentParser(description="Оценка фото-модуля на открытом фото-эталоне")
    parser.add_argument("--mode", choices=("pilot", "full"))
    parser.add_argument("--model", default=os.getenv("LLM_MODEL_VISION"),
                        help="Модель vision API (по умолчанию LLM_MODEL_VISION); для --rules-only не нужна")
    parser.add_argument("--provider", choices=("openai", "anthropic"), default="openai")
    parser.add_argument("--input-price-per-million", type=float)
    parser.add_argument("--output-price-per-million", type=float)
    parser.add_argument("--rules-only", action="store_true")
    parser.add_argument("--render-only", action="store_true", help="Пересобрать Markdown из сохранённого JSON без API")
    parser.add_argument("--tag", choices=("mini", "strong"), default="mini")
    parser.add_argument("--embedding-model", type=Path)
    parser.add_argument("--photos-dir", type=Path, default=PHOTO_DIR)
    parser.add_argument("--reports-dir", type=Path, default=REPORT_DIR)
    args = parser.parse_args()
    if any(value is not None and value < 0 for value in
           (args.input_price_per_million, args.output_price_per_million)):
        parser.error("Цена токенов не может быть отрицательной")
    args.reports_dir.mkdir(parents=True, exist_ok=True)
    prefix = "photo_eval" if args.tag == "mini" else "photo_eval_strong"
    if args.render_only:
        path = args.reports_dir / f"{prefix}_full.json"
        result = json.loads(path.read_text(encoding="utf-8"))
    else:
        if args.mode is None:
            parser.error("Укажите --mode pilot|full")
        result = asyncio.run(run(args.mode, args.photos_dir, args.model, args.provider,
                                 args.input_price_per_million, args.output_price_per_million, args.rules_only,
                                 args.embedding_model))
        path = args.reports_dir / f"{prefix}_{args.mode}.json"
        path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    pilot_path = args.reports_dir / f"{prefix}_pilot.json"
    pilot = json.loads(pilot_path.read_text(encoding="utf-8")) if result["mode"] == "full" and pilot_path.exists() else None
    photo_report = markdown_report(result, pilot)
    (args.reports_dir / f"{prefix}.md").write_text(photo_report, encoding="utf-8")
    mini_path = args.reports_dir / "photo_eval_full.json"
    strong_path = args.reports_dir / "photo_eval_strong_full.json"
    if mini_path.exists() and strong_path.exists():
        mini = json.loads(mini_path.read_text(encoding="utf-8"))
        strong = json.loads(strong_path.read_text(encoding="utf-8"))
        if "split" in mini and "split" in strong and mini["split"] == strong["split"]:
            mini_pilot_path = args.reports_dir / "photo_eval_pilot.json"
            strong_pilot_path = args.reports_dir / "photo_eval_strong_pilot.json"
            mini_pilot = json.loads(mini_pilot_path.read_text(encoding="utf-8")) if mini_pilot_path.exists() else None
            strong_pilot = (json.loads(strong_pilot_path.read_text(encoding="utf-8"))
                            if strong_pilot_path.exists() else None)
            base = markdown_report(mini, mini_pilot)
            (args.reports_dir / "photo_eval.md").write_text(
                base + "\n" + comparison_report(mini, strong, mini_pilot, strong_pilot),
                                                             encoding="utf-8")
    print(json.dumps({"report": str(path), "pairs": sum(group["count"] for group in result["pairs"].values()),
                      "duplicates": result["duplicates"]["count"], "seconds": result["timing"]["elapsed_seconds"],
                      "usage": result["usage"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
