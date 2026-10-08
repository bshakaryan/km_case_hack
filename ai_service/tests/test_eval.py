import asyncio
import json
from datetime import datetime, timedelta

import pytest

from data_gen.generate import generate
from eval.run import evaluate, markdown, pairwise_agreement, scores


@pytest.fixture(scope="module")
def generated(tmp_path_factory):
    root = tmp_path_factory.mktemp("phase4-eval")
    data_dir = root / "data"
    cases_dir = root / "cases"
    generate(data_dir, cases_dir, photo_cases=False)
    return data_dir, cases_dir


def test_metric_arithmetic_and_rank_ties():
    result = scores(["accepted", "needs_rework"], ["accepted", "accepted"])
    assert result["accuracy"] == 0.5
    assert result["confusion_matrix"]["needs_rework"]["accepted"] == 1
    assert pairwise_agreement({"A": 1, "B": 2}, {"A": 2, "B": 1}) == 0


def test_generator_oracles_cover_all_ticks_and_respect_material_norms(generated):
    data_dir, cases_dir = generated
    cases = json.loads((cases_dir / "deadlines.json").read_text(encoding="utf-8"))
    for case in cases:
        final_tick = datetime.fromisoformat(case["tick_times"][-1])
        deadline = datetime.fromisoformat(case["order"]["deadline"])
        expected = {(item["recipient"], item["type"], item["at"])
                    for item in case["expected_notifications"]}
        for offset in range(0, 181, 30):
            trigger = deadline + timedelta(minutes=offset)
            if trigger <= final_tick:
                name = "overdue" if offset == 0 else "overdue_repeat"
                for recipient in ("worker", "master"):
                    assert (recipient, name, trigger.isoformat().replace("+00:00", "Z")) in expected
    norms = json.loads((data_dir / "material_norms.json").read_text(encoding="utf-8"))
    by_pair = {(item["fault_code_id"], item["material_id"]): item["quantity"] for item in norms}
    verification = json.loads((cases_dir / "verification.json").read_text(encoding="utf-8"))
    for case in verification:
        if case["category"] != "correct":
            continue
        completion = case["order"]["completion"]
        assert all(item["quantity"] <= 1.5 * by_pair[completion["fault_code_id"], item["material_id"]]
                   for item in completion["materials"])


def test_offline_eval_reports_only_implemented_metrics(generated):
    data_dir, cases_dir = generated
    result = asyncio.run(evaluate(data_dir, cases_dir))
    assert result["deadlines"]["cases"] == 40
    assert result["deadlines"]["duplicates"] == 0
    assert result["deadlines"]["precision"] == result["deadlines"]["recall"] == 1
    assert result["verification"]["rules_only"]["cases"] == 120
    assert result["verification"]["rules_only"]["accuracy"] == 1
    assert result["verification"]["rules_only"]["flags"]["uncertain_match"]["precision"] is None
    assert result["verification"]["rules_plus_llm"]["status"] == "not_run"
    assert result["llm"]["request_count"] == 0
    assert result["rating"]["both_targets_bottom_third"]
    assert result["photo_duplicates"]["precision"] is None
    assert result["anomalies"]["found_of_six"] == 6
    assert result["anomalies"]["false_positive_decoys"] == 0
    assert "синтетике" in markdown(result)
