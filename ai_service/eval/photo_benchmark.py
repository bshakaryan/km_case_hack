"""Evaluate the existing photo comparison and vision client on labeled public pairs."""

import argparse
import asyncio
import csv
import hashlib
import json
import os
import re
import time
from pathlib import Path

from dotenv import load_dotenv
from pydantic import SecretStr

from app.config import Settings
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
            selected.extend(group[:2])
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
    mistakes = [row for row in rows if row["label"] != row["prediction"]]
    return {
        "count": count,
        "accuracy": round((count - len(mistakes)) / count, 4) if count else None,
        "needs_master_review_rate": round(sum(row["prediction"] == "needs_master_review"
                                              for row in rows) / count, 4) if count else None,
        "confusion": confusion(rows, LABELS),
        "errors": [{"pair_id": row["pair_id"], "expected": row["label"],
                    "predicted": row["prediction"], "reason": row["reason"]}
                   for row in mistakes[:3]],
        "error_count": len(mistakes),
    }


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


async def evaluate_pair(row: dict, root: Path, llm: LLMClient | None):
    before = photo_path(root, "pairs", row["pair_id"], "before.jpg").read_bytes()
    after = photo_path(root, "pairs", row["pair_id"], "after.jpg").read_bytes()
    started = time.perf_counter()
    duplicate = compare_images(before, after)
    assessment = None
    if duplicate["duplicate"]:
        prediction = "not_fixed"
        reason = "Технический дубль фото до и после"
    elif llm is None:
        prediction = "needs_master_review"
        reason = "Vision API не включён"
    else:
        prompt = {"problem": "Проверь видимый дефект на объекте до и после работ",
                  "work_done": "Состояние после устранения дефекта",
                  "photo_labels": ["before", "after"]}
        assessment = await llm.inspect_photo(prompt, sanitized_jpeg(open_image(before)),
                                             sanitized_jpeg(open_image(after)))
        prediction = predict_from_vision(assessment)
        reason = (assessment.explanation[:200] if assessment else "Нет валидного ответа vision API")
    return {"pair_id": row["pair_id"], "kind": row["kind"], "source": row["source"],
            "label": row["label"], "prediction": prediction, "reason": reason,
            "duplicate": duplicate["duplicate"], "confidence": assessment.confidence if assessment else None,
            "elapsed_seconds": round(time.perf_counter() - started, 3)}


def evaluate_duplicate(row: dict, root: Path):
    original = photo_path(root, "duplicates", row["pair_id"], "original.jpg").read_bytes()
    candidate = photo_path(root, "duplicates", row["pair_id"], "candidate.jpg").read_bytes()
    started = time.perf_counter()
    comparison = compare_images(original, candidate)
    return {"pair_id": row["pair_id"], "variant": row["variant"],
            "label": row["is_duplicate"], "prediction": str(int(comparison["duplicate"])),
            "elapsed_seconds": round(time.perf_counter() - started, 3),
            "phash_distance": comparison["phash_distance"], "ssim": comparison["ssim"]}


async def run(mode: str, root: Path, model: str | None, provider: str,
              input_price: float | None, output_price: float | None, rules_only: bool):
    pairs = read_manifest(root / "labels.csv", "pair")
    duplicates = read_manifest(root / "duplicates.csv", "dup")
    if len(pairs) != 180 or len(duplicates) != 200:
        raise ValueError(f"Ожидалось 180 фото-пар и 200 дублей; найдено {len(pairs)} и {len(duplicates)}")
    pairs, duplicates = select_cases(pairs, duplicates, mode == "pilot")
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
            pair_results.append(await evaluate_pair(row, root, llm))
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
        "pairs": {kind: category_metrics([row for row in pair_results if row["kind"] == kind]) for kind in KINDS},
        "duplicates": duplicate_metrics(duplicate_results),
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
    lines = ["| Тип | Пар | Accuracy | Нужна проверка мастером | Ошибок |",
             "| --- | ---: | ---: | ---: | ---: |"]
    for kind in KINDS:
        metric = result["pairs"][kind]
        lines.append(f"| {kind} | {metric['count']} | {metric['accuracy']} | "
                     f"{metric['needs_master_review_rate']} | {metric['error_count']} |")
    metric = result["duplicates"]
    lines.append(f"| дубли | {metric['count']} | {metric['accuracy']} | "
                 f"{metric['needs_master_review_rate']} | {metric['error_count']} |")
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
                         f"`{item['predicted']}`; {item['reason']}")
    else:
        lines.append("- Ошибок в этом наборе нет.")
    lines.append("")
    return lines


def markdown_report(result: dict, pilot: dict | None):
    usage = result["usage"]
    total_cases = sum(group["count"] for group in result["pairs"].values())
    total_correct = sum(group["count"] - group["error_count"] for group in result["pairs"].values())
    lines = ["## Фото-эталон: открытые данные, не реальные ремонты", "",
             "Этот набор **не** оценивает точность подтверждения реального ремонта. VisA `proxy` — разные экземпляры "
             "одного класса; `semi_synthetic` — inpaint; `real_same_image` — неизменённое фото. "
             "Отсутствие времени съёмки и рабочего контекста в этих парах означает, что в реальном наряде "
             "финальное решение остаётся за мастером. Accuracy ниже считает отказ с пометкой "
             "`needs_master_review` несовпадением с трёхклассовой меткой, а не опасной автоматической приёмкой.", "",
             f"Режим: `{result['mode']}`, модель: `{result['model'] or 'без LLM'}`. "
             f"Время: {result['timing']['elapsed_seconds']} с; среднее на фото-пару: "
             f"{result['timing']['mean_pair_seconds']} с. Попытки API: {usage['api_attempts']}, "
             f"кэш: {usage['cache_hits']}, токены вход/выход: "
             f"{usage['input_tokens']}/{usage['output_tokens']}; расчётная стоимость: "
             f"{usage['estimated_cost_usd']} USD (стандартные цены, не счёт провайдера). "
             f"Общая accuracy фото-пар: {round(total_correct / total_cases, 4)} ({total_correct}/{total_cases}).", ""]
    if pilot:
        first = pilot["usage"]
        lines.append(f"Пилот 10 пар: {pilot['timing']['elapsed_seconds']} с, "
                     f"{first['api_attempts']} попыток API, "
                     f"{first['input_tokens']}/{first['output_tokens']} токенов, "
                     f"{first['estimated_cost_usd']} USD. Полный прогон использовал кэш пилота; "
                     "его стоимость указана отдельно, не включает пилот.")
        if first["estimated_cost_usd"] is not None and usage["estimated_cost_usd"] is not None:
            lines.append(f"Оба запуска вместе: {round(first['estimated_cost_usd'] + usage['estimated_cost_usd'], 6)} USD, "
                         f"{round(pilot['timing']['elapsed_seconds'] + result['timing']['elapsed_seconds'], 3)} с.")
        lines.append("")
    lines.extend(markdown_table(result))
    lines.append("")
    for kind in KINDS:
        lines.extend(markdown_confusion(kind, result["pairs"][kind], LABELS))
    lines.extend(markdown_confusion("дубли", result["duplicates"], ("0", "1")))
    lines.append(f"Дубли: precision {result['duplicates']['precision']}, recall {result['duplicates']['recall']}.")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Оценка фото-модуля на открытом фото-эталоне")
    parser.add_argument("--mode", choices=("pilot", "full"))
    parser.add_argument("--model", help="Модель vision API; для --rules-only не нужна")
    parser.add_argument("--provider", choices=("openai", "anthropic"), default="openai")
    parser.add_argument("--input-price-per-million", type=float)
    parser.add_argument("--output-price-per-million", type=float)
    parser.add_argument("--rules-only", action="store_true")
    parser.add_argument("--render-only", action="store_true", help="Пересобрать Markdown из сохранённого JSON без API")
    parser.add_argument("--photos-dir", type=Path, default=PHOTO_DIR)
    parser.add_argument("--reports-dir", type=Path, default=REPORT_DIR)
    args = parser.parse_args()
    if any(value is not None and value < 0 for value in
           (args.input_price_per_million, args.output_price_per_million)):
        parser.error("Цена токенов не может быть отрицательной")
    args.reports_dir.mkdir(parents=True, exist_ok=True)
    if args.render_only:
        path = args.reports_dir / "photo_eval_full.json"
        result = json.loads(path.read_text(encoding="utf-8"))
    else:
        if args.mode is None:
            parser.error("Укажите --mode pilot|full")
        result = asyncio.run(run(args.mode, args.photos_dir, args.model, args.provider,
                                 args.input_price_per_million, args.output_price_per_million, args.rules_only))
        path = args.reports_dir / f"photo_eval_{args.mode}.json"
        path.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    pilot_path = args.reports_dir / "photo_eval_pilot.json"
    pilot = json.loads(pilot_path.read_text(encoding="utf-8")) if result["mode"] == "full" and pilot_path.exists() else None
    photo_report = markdown_report(result, pilot)
    (args.reports_dir / "photo_eval.md").write_text(photo_report, encoding="utf-8")
    print(json.dumps({"report": str(path), "pairs": sum(group["count"] for group in result["pairs"].values()),
                      "duplicates": result["duplicates"]["count"], "seconds": result["timing"]["elapsed_seconds"],
                      "usage": result["usage"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
