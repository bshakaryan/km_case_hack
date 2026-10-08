import asyncio

import pytest

from app.photos import compare_images
from app.llm_client import VisionAssessment
from eval.photo_benchmark import (PHOTO_DIR, category_metrics, duplicate_metrics,
                                  evaluate_pair, gate_decision, predict_from_vision,
                                  read_manifest, select_cases, split_pairs)


def test_photo_manifests_and_pilot_are_stratified():
    pairs = read_manifest(PHOTO_DIR / "labels.csv", "pair")
    duplicates = read_manifest(PHOTO_DIR / "duplicates.csv", "dup")
    assert len(pairs) == 180
    assert len(duplicates) == 200
    pilot_pairs, pilot_duplicates = select_cases(pairs, duplicates, True)
    assert len(pilot_pairs) == 10
    assert len(pilot_duplicates) == 2
    assert {item["kind"] for item in pilot_pairs} == {
        "proxy", "semi_synthetic", "real_same_image", "cross_class"
    }
    assert {item["label"] for item in pilot_pairs if item["kind"] == "proxy"} == {
        "fixed", "not_fixed"
    }


def test_vision_abstains_on_low_confidence_or_unknown_equipment():
    assessment = VisionAssessment(same_equipment=True, defect_resolved=True,
                                  quality="good", confidence=0.69, issues=[], explanation="Ремонт виден")
    assert predict_from_vision(assessment) == "needs_master_review"
    assert predict_from_vision(assessment.model_copy(update={"confidence": 0.8})) == "fixed"
    assert predict_from_vision(assessment.model_copy(update={"same_equipment": False,
                                                      "confidence": 0.8})) == "other_equipment"
    assert predict_from_vision(None) == "needs_master_review"


def test_confusion_excludes_review_from_decided_accuracy_and_duplicates_separately():
    metrics = category_metrics([
        {"pair_id": "pair_0001", "label": "fixed", "prediction": "fixed", "reason": "совпало"},
        {"pair_id": "pair_0002", "label": "not_fixed", "prediction": "needs_master_review",
         "reason": "неясно"},
    ])
    assert metrics["coverage"] == 0.5
    assert metrics["accuracy_decided"] == 1.0
    assert metrics["error_count"] == 0
    assert metrics["needs_master_review_rate"] == 0.5
    assert metrics["confusion"]["not_fixed"]["needs_master_review"] == 1
    duplicates = duplicate_metrics([
        {"pair_id": "dup_0001", "label": "1", "prediction": "0", "variant": "cropped_resized"},
        {"pair_id": "dup_0002", "label": "0", "prediction": "0", "variant": "different_photo"},
    ])
    assert duplicates["accuracy"] == 0.5
    assert duplicates["recall"] == 0
    assert duplicates["confusion"]["1"]["0"] == 1


def test_equipment_split_keeps_same_source_photo_together():
    pairs = read_manifest(PHOTO_DIR / "labels.csv", "pair")
    train, holdout = split_pairs(pairs)
    assert len(train) + len(holdout) == len(pairs)
    train_sources = {(row["source"], row["before_src"]) for row in train}
    holdout_sources = {(row["source"], row["before_src"]) for row in holdout}
    assert not train_sources & holdout_sources


def test_confident_equipment_mismatch_skips_llm():
    class ForbiddenLLM:
        async def inspect_photo(self, *_args):
            raise AssertionError("LLM вызван после кодового несовпадения")

    row = next(row for row in read_manifest(PHOTO_DIR / "labels.csv", "pair")
               if row["kind"] == "cross_class")
    gate = {"embedding_cosine": 0.2, "orb_inliers": 0, "ssim": 0.1}
    assert gate_decision(gate, 0.586)
    if (PHOTO_DIR / "pairs" / row["pair_id"] / "before.jpg").is_file():
        result = asyncio.run(evaluate_pair(row, PHOTO_DIR, ForbiddenLLM(), gate, 0.586))
        assert result["prediction"] == "other_equipment"


def test_duplicate_variants_reach_target_without_false_positives():
    rows = read_manifest(PHOTO_DIR / "duplicates.csv", "dup")
    if not (PHOTO_DIR / "duplicates" / rows[0]["pair_id"] / "original.jpg").is_file():
        pytest.skip("Необязательные изображения фото-бенчмарка не установлены")
    predictions = []
    for row in rows:
        folder = PHOTO_DIR / "duplicates" / row["pair_id"]
        comparison = compare_images((folder / "original.jpg").read_bytes(),
                                    (folder / "candidate.jpg").read_bytes())
        predictions.append({"pair_id": row["pair_id"], "variant": row["variant"],
                            "label": row["is_duplicate"], "prediction": str(int(comparison["duplicate"]))})
    metrics = duplicate_metrics(predictions)
    assert metrics["accuracy"] >= 0.95
    assert metrics["confusion"]["0"]["1"] == 0
    assert all(group["accuracy"] >= 0.95 for group in
               (duplicate_metrics([item for item in predictions if item["variant"] == variant])
                for variant in ("exact_copy", "recompressed", "cropped_resized", "different_photo")))
