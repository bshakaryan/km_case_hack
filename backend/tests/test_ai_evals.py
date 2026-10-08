from fastapi.testclient import TestClient

from app.main import create_app
from evals.run import auth, load_cases, metrics, run_case


class AlwaysPassed:
    model = "fake-eval"

    def review(self, snapshot, images):
        return {"verdict": "passed", "score": 4, "confidence": 0.9, "explanation": "Синтетический ответ", "photo_summary": "Снимки получены", "issues": []}


def test_synthetic_eval_fixtures_are_valid():
    cases = load_cases()
    assert len(cases) == 7
    assert {case["expected_verdict"] for case in cases} == {"passed", "needs_attention", "needs_rework"}
    duplicate = next(case for case in cases if case["id"] == "exact_duplicate")
    assert duplicate["before"] == duplicate["after"]


def test_eval_metrics_count_unsafe_passes():
    result = metrics([
        {"expected_verdict": "passed", "observed_verdict": "passed"},
        {"expected_verdict": "needs_attention", "observed_verdict": "passed"},
        {"expected_verdict": "needs_rework", "observed_verdict": "needs_rework"},
    ])
    assert result["count"] == 3
    assert result["exact_match"] == 0.667
    assert result["unsafe_passed"] == 1
    assert result["by_verdict"]["passed"]["precision"] == 0.5


def test_exact_duplicate_is_caught_by_real_review_flow(tmp_path):
    provider = AlwaysPassed()
    app = create_app(f"sqlite:///{tmp_path / 'eval.db'}", monitor=False, ai_provider=provider, ai_worker=False)
    duplicate = next(case for case in load_cases() if case["id"] == "exact_duplicate")
    with TestClient(app) as client:
        result = run_case(client, app, provider, duplicate, auth(client, "master"), auth(client, "worker2"))
    assert result["verdict"] == "needs_attention"
    assert "Фото до и после совпадают побайтово" in result["issues"]
