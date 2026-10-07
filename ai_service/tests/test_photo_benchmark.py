from app.llm_client import VisionAssessment
from eval.photo_benchmark import (PHOTO_DIR, category_metrics, duplicate_metrics,
                                  predict_from_vision, read_manifest, select_cases)


def test_photo_manifests_and_pilot_are_stratified():
    pairs = read_manifest(PHOTO_DIR / "labels.csv", "pair")
    duplicates = read_manifest(PHOTO_DIR / "duplicates.csv", "dup")
    assert len(pairs) == 180
    assert len(duplicates) == 200
    pilot_pairs, pilot_duplicates = select_cases(pairs, duplicates, True)
    assert len(pilot_pairs) == 8
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


def test_confusion_counts_review_as_error_and_duplicates_separately():
    metrics = category_metrics([
        {"pair_id": "pair_0001", "label": "fixed", "prediction": "fixed", "reason": "совпало"},
        {"pair_id": "pair_0002", "label": "not_fixed", "prediction": "needs_master_review",
         "reason": "неясно"},
    ])
    assert metrics["accuracy"] == 0.5
    assert metrics["needs_master_review_rate"] == 0.5
    assert metrics["confusion"]["not_fixed"]["needs_master_review"] == 1
    duplicates = duplicate_metrics([
        {"pair_id": "dup_0001", "label": "1", "prediction": "0", "variant": "cropped_resized"},
        {"pair_id": "dup_0002", "label": "0", "prediction": "0", "variant": "different_photo"},
    ])
    assert duplicates["accuracy"] == 0.5
    assert duplicates["recall"] == 0
    assert duplicates["confusion"]["1"]["0"] == 1
