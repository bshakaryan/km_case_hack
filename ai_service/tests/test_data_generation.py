import asyncio
import json
import subprocess
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path

import pytest

from app.synthetic_source import SyntheticDataSource
from data_gen.generate import generate
from data_gen.photos import generate_photo_cases


@pytest.fixture(scope="module")
def generated(tmp_path_factory):
    root = tmp_path_factory.mktemp("synthetic")
    output = root / "data"
    cases = root / "eval" / "cases"
    generate(output, cases, photo_cases=False)
    return output, cases


def test_snapshot_shape_and_datasource(generated):
    output, _ = generated
    material_norms = json.loads((output / "material_norms.json").read_text(encoding="utf-8"))
    snapshot = asyncio.run(SyntheticDataSource(output / "snapshot.json").snapshot())
    assert len(snapshot.areas) == 4
    assert len(snapshot.equipment) == 25
    assert len(snapshot.employees) == 18
    assert len([person for person in snapshot.employees if person.role == "worker"]) == 15
    assert len(snapshot.brigades) == 3
    assert len(snapshot.fault_codes) == 20
    assert len(snapshot.materials) == 40
    assert {row["material_id"] for row in material_norms} == set(range(1, 41))
    assert len(snapshot.time_norms) == 20
    assert len(snapshot.orders) >= 600
    assert len({order.created_at.hour for order in snapshot.orders}) == 2
    assert all(order.events and order.photos and order.completion for order in snapshot.orders)
    assert all(order.events[-1].to_status == order.status for order in snapshot.orders)
    assert all(order.photos[0].path for order in snapshot.orders)
    assert asyncio.run(SyntheticDataSource(output / "snapshot.json").photo_bytes(snapshot.orders[0].photos[0]))
    before = [photo for order in snapshot.orders for photo in order.photos if photo.kind == "before"]
    assert len(before) >= 100
    assert asyncio.run(SyntheticDataSource(output / "snapshot.json").photo_bytes(before[0]))
    assert min(order.created_at for order in snapshot.orders).month == 7
    assert max(order.created_at for order in snapshot.orders).month == 9
    equipment_ids = {equipment.id for equipment in snapshot.equipment}
    worker_ids = {person.id for person in snapshot.employees if person.role == "worker"}
    fault_ids = {fault.id for fault in snapshot.fault_codes}
    material_ids = {material.id for material in snapshot.materials}
    assert all(order.equipment_id in equipment_ids and order.assignee_id in worker_ids
               and order.completion.fault_code_id in fault_ids
               and all(usage.material_id in material_ids for usage in order.completion.materials)
               for order in snapshot.orders)


def test_fixed_seed_is_byte_reproducible(generated, tmp_path):
    output, cases = generated
    second_output = tmp_path / "data"
    second_cases = tmp_path / "cases"
    generate(second_output, second_cases, photo_cases=False)
    assert (output / "snapshot.json").read_bytes() == (second_output / "snapshot.json").read_bytes()
    assert (cases / "verification.json").read_bytes() == (second_cases / "verification.json").read_bytes()
    assert (output / "csv" / "orders.csv").read_bytes() == (second_output / "csv" / "orders.csv").read_bytes()


def test_verification_labels_and_independent_cards(generated):
    _, cases_dir = generated
    cases = json.loads((cases_dir / "verification.json").read_text(encoding="utf-8"))
    assert len(cases) == 120
    assert Counter(case["expected_verdict"] for case in cases) == {
        "accepted": 30, "accepted_with_remarks": 30,
        "needs_rework": 30, "needs_master_review": 30,
    }
    assert len({case["id"] for case in cases}) == 120
    assert all(case["label_source"] == "deterministic_rule" for case in cases)
    for case in cases:
        order = case["order"]
        if case["category"] == "no_after_photo":
            assert not any(photo["kind"] == "after" for photo in order["photos"])
        if case["category"] == "missing_code":
            assert order["completion"]["fault_code_id"] is None
        if case["category"] == "unknown_norm":
            assert order["normal_hours"] is None
        if case["category"] == "correct":
            assert order["photos"] and order["completion"]["fault_code_id"]
            assert datetime.fromisoformat(order["completed_at"]) < datetime.fromisoformat(order["deadline"])


def test_timeline_and_analytics_truth(generated):
    _, cases_dir = generated
    deadlines = json.loads((cases_dir / "deadlines.json").read_text(encoding="utf-8"))
    assert len(deadlines) == 40
    assert all(case["expected_duplicate_count"] == 0 for case in deadlines)
    assert all(len({(event["recipient"], event["type"], event["at"])
                    for event in case["expected_notifications"]}) == len(case["expected_notifications"])
               for case in deadlines)
    emergency = [case for case in deadlines if case["order"]["priority"] == "emergency"]
    assert emergency and all(case["thresholds_minutes"]["acceptance"] == 3 for case in emergency)
    truth = json.loads((cases_dir / "analytics.json").read_text(encoding="utf-8"))
    assert len(truth["patterns"]) == 6
    assert len(truth["decoys"]) == 3
    k3 = truth["patterns"][0]
    assert 2.5 <= k3["count"] / k3["median_other_count"] <= 3.5
    assert 0.65 <= k3["bearing_share"] <= 0.75
    assert truth["patterns"][1]["injected_repeat_rate"] == 0.28
    assert truth["patterns"][1]["observed_rate"] == 0.4
    assert 0.07 <= truth["patterns"][1]["other_worker_rate"] <= 0.11


def test_rating_truth_places_target_workers_in_lower_third(generated):
    output, _ = generated
    snapshot = asyncio.run(SyntheticDataSource(output / "snapshot.json").snapshot())
    scores = {}
    for worker in [person for person in snapshot.employees if person.role == "worker"]:
        values = [order.score for order in snapshot.orders if order.assignee_id == worker.id]
        scores[worker.id] = sum(values) / len(values)
    lower_third = set(sorted(scores, key=scores.get)[:5])
    assert {6, 13} <= lower_third


def test_intake_and_assistant_cases(generated):
    _, cases_dir = generated
    intake = json.loads((cases_dir / "intake.json").read_text(encoding="utf-8"))
    assistant = json.loads((cases_dir / "assistant.json").read_text(encoding="utf-8"))
    assert len(intake) == 40 and len(assistant) == 25
    assert all(1 <= case["expected"]["equipment_id"] <= 25 for case in intake)
    assert all(1 <= case["expected"]["fault_code_id"] <= 20 for case in intake)
    assert {case["expected_tool"] for case in assistant} == {
        "overdue_orders", "available_workers", "area_report", "area_problems",
    }
    assert all(case["expected_value"] is not None for case in assistant)


def test_seed_backend_requires_explicit_local_confirmation():
    root = Path(__file__).resolve().parents[1]
    result = subprocess.run(
        [sys.executable, "-m", "data_gen.seed_backend", "--base-url", "http://example.com",
         "--confirm", "IMPORT_SYNTHETIC_ORDERS"],
        cwd=root, capture_output=True, text=True, check=False,
    )
    assert result.returncode != 0
    assert "локального HTTP" in result.stderr


def test_photo_duplicate_labels_are_transformations(tmp_path):
    cases = generate_photo_cases(tmp_path / "cases")
    assert len(cases) == 48
    assert Counter(case["variant"] for case in cases) == {
        "exact": 12, "recompressed": 12, "cropped": 12, "different": 12,
    }
    assert sum(case["expected_duplicate"] for case in cases) == 36
    root = Path(__file__).resolve().parents[1]
    for case in cases:
        source = root / case["source"]
        candidate = root / case["candidate"]
        assert source.is_file() and candidate.is_file()
        if case["variant"] == "exact":
            assert source.read_bytes() == candidate.read_bytes()
