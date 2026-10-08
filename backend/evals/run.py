import argparse
import io
import json
import tempfile
from collections import Counter
from datetime import timedelta
from pathlib import Path

from dotenv import load_dotenv
from fastapi.testclient import TestClient
from PIL import Image

from app.ai import OpenAIProvider, process_one_review
from app.main import create_app
from app.models import Order, utcnow


ROOT = Path(__file__).resolve().parent
VERDICTS = ("passed", "needs_attention", "needs_rework")


def load_cases():
    cases = json.loads((ROOT / "cases.json").read_text(encoding="utf-8"))
    identifiers = set()
    for case in cases:
        if case["id"] in identifiers or case["expected_verdict"] not in VERDICTS:
            raise ValueError(f"Некорректный кейс: {case['id']}")
        identifiers.add(case["id"])
        if len(case["work_done"]) < 10:
            raise ValueError(f"Слишком короткий отчёт: {case['id']}")
        for kind in ("before", "after"):
            name = case[kind]
            if Path(name).name != name:
                raise ValueError(f"Некорректное имя фото: {name}")
            path = ROOT / "photos" / name
            with Image.open(path) as photo:
                photo.verify()
    return cases


def jpeg_bytes(name):
    output = io.BytesIO()
    with Image.open(ROOT / "photos" / name) as photo:
        photo.convert("RGB").save(output, format="JPEG", quality=85)
    return output.getvalue()


def require(response, expected_status):
    if response.status_code != expected_status:
        raise RuntimeError(f"HTTP {response.status_code}: {response.text[:500]}")
    return response.json()


def auth(client, login):
    result = require(client.post("/api/auth/login", json={"login": login, "pin": "1234"}), 200)
    return {"Authorization": "Bearer " + result["token"]}


def run_case(client, app, provider, case, master, worker):
    order = require(client.post("/api/orders", headers=master, json={
        "title": "Устранить течь фланца насоса НС-01",
        "description": "Насос НС-01: видимая течь воды из фланцевого соединения напорной трубы при работе.",
        "work_type": "unplanned",
        "area_id": 2,
        "equipment_id": 8,
        "assignee_id": 6,
        "deadline": (utcnow() + timedelta(hours=4)).isoformat(),
        "normal_hours": 1,
    }), 201)
    path = f"/api/orders/{order['id']}"
    for kind in ("before", "after"):
        name = case[kind]
        require(client.post(path + "/photos", headers=worker, data={"kind": kind}, files={
            "file": (name.removesuffix(".png") + ".jpg", jpeg_bytes(name), "image/jpeg")
        }), 201)
    for action in ("accept", "start"):
        require(client.post(path + "/transition", headers=worker, json={"action": action}), 200)
    with app.state.sessions() as db:
        evaluation_order = db.get(Order, order["id"])
        evaluation_order.created_at = utcnow() - timedelta(minutes=90)
        evaluation_order.started_at = utcnow() - timedelta(minutes=65)
        db.commit()
    require(client.post(path + "/complete", headers=worker, json={
        "work_done": case["work_done"],
        "fault_code_id": 12,
        "materials": case["materials"],
    }), 200)
    if not process_one_review(app.state.sessions, provider):
        raise RuntimeError("ИИ-задание не найдено")
    result = require(client.get(path, headers=master), 200)
    review = result.get("ai_review")
    if result["status"] != "ai_review" or not review or review["is_stub"]:
        raise RuntimeError(f"ИИ-проверка не завершилась: {result['status']}")
    return review


def metrics(results):
    evaluated = [item for item in results if item.get("observed_verdict") in VERDICTS]
    scores = {}
    for verdict in VERDICTS:
        true_positive = sum(item["expected_verdict"] == verdict and item["observed_verdict"] == verdict for item in evaluated)
        predicted = sum(item["observed_verdict"] == verdict for item in evaluated)
        expected = sum(item["expected_verdict"] == verdict for item in evaluated)
        precision = true_positive / predicted if predicted else 0
        recall = true_positive / expected if expected else 0
        scores[verdict] = {"support": expected, "precision": round(precision, 3), "recall": round(recall, 3), "f1": round(2 * precision * recall / (precision + recall), 3) if precision + recall else 0}
    return {
        "count": len(evaluated),
        "exact_match": round(sum(item["expected_verdict"] == item["observed_verdict"] for item in evaluated) / len(evaluated), 3) if evaluated else 0,
        "unsafe_passed": sum(item["expected_verdict"] != "passed" and item["observed_verdict"] == "passed" for item in evaluated),
        "by_verdict": scores,
    }


def main():
    parser = argparse.ArgumentParser(description="Синтетическая проверка рекомендательных ИИ-вердиктов")
    parser.add_argument("--live", action="store_true", help="Вызвать OpenAI на всех кейсах через реальный сервисный сценарий")
    parser.add_argument("--output", type=Path, default=ROOT / "results" / "latest.json")
    args = parser.parse_args()
    cases = load_cases()
    print(f"Проверено {len(cases)} кейсов, классы: {dict(Counter(case['expected_verdict'] for case in cases))}")
    if not args.live:
        print("Фото и разметка валидны. Для запросов к OpenAI добавьте --live.")
        return
    load_dotenv(ROOT.parents[1] / ".env")
    provider = OpenAIProvider()
    results = []
    with tempfile.TemporaryDirectory(prefix="naryad-ai-eval-") as temporary_directory:
        database = Path(temporary_directory) / "eval.db"
        app = create_app(f"sqlite:///{database.as_posix()}", monitor=False, ai_provider=provider, ai_worker=False)
        with TestClient(app) as client:
            master = auth(client, "master")
            worker = auth(client, "worker2")
            for case in cases:
                row = {"id": case["id"], "expected_verdict": case["expected_verdict"]}
                try:
                    review = run_case(client, app, provider, case, master, worker)
                    row.update(observed_verdict=review["verdict"], score=review["score"], confidence=review.get("confidence"), explanation=review.get("explanation"), photo_summary=review.get("photo_summary"), issues=review.get("issues", []))
                    print(f"{case['id']}: {row['observed_verdict']} (ожидалось {row['expected_verdict']})")
                except (RuntimeError, ValueError, KeyError) as error:
                    row["error"] = str(error)
                    print(f"{case['id']}: ошибка — {error}")
                results.append(row)
    report = {"dataset": "synthetic-provisional", "model": provider.model, "metrics": metrics(results), "results": results}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Результат: {args.output}")
    print(json.dumps(report["metrics"], ensure_ascii=False, indent=2))
    if report["metrics"]["count"] != len(cases):
        raise SystemExit("Не все кейсы получили результат ИИ")


if __name__ == "__main__":
    main()
