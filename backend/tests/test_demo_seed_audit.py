"""An isolated audit proves current seed facts; it does not pass R40 or alter seed."""
import argparse
import hashlib
import json
import re
import sqlite3
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from tools import demo_seed_audit as audit


CLOCK = datetime(2026, 10, 8, 12, tzinfo=timezone.utc)
REPO = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("value", ["2026-10-08T12:00:00Z", "2026-10-08T12:00:00+00:00"])
def test_clock_parser_requires_explicit_utc_and_keeps_the_control_instant(value):
    parsed = audit.parse_utc_clock(value)
    assert parsed == CLOCK and parsed.tzinfo is not None


@pytest.mark.parametrize("value", ["2026-10-08T12:00:00", "2026-10-08",
    "2026-10-08T12:00:00+05:00", "not-a-clock"])
def test_ambiguous_or_non_utc_clock_is_rejected(value):
    with pytest.raises(argparse.ArgumentTypeError):
        audit.parse_utc_clock(value)


@pytest.mark.parametrize("kind", ["directory", "file"])
def test_existing_output_is_refused_without_changing_its_contents(tmp_path, kind):
    target = tmp_path / "existing"
    if kind == "directory":
        target.mkdir()
        marker = target / "keep.txt"
    else:
        marker = target
    marker.write_bytes(b"owned-by-someone-else")
    with pytest.raises(ValueError):
        audit.prepare_output_directory(target)
    assert marker.read_bytes() == b"owned-by-someone-else"
    assert not target.is_dir() or list(target.iterdir()) == [marker]


@pytest.mark.parametrize("git_marker_is_file", [False, True])
def test_output_cannot_be_placed_inside_another_checkout(tmp_path, git_marker_is_file):
    checkout = tmp_path / "other-checkout"
    checkout.mkdir()
    marker = checkout / ".git"
    if git_marker_is_file:
        marker.write_text("gitdir: ../managed-git", encoding="utf-8")
    else:
        marker.mkdir()
    target = checkout / "generated-fixture"
    with pytest.raises(ValueError):
        audit.prepare_output_directory(target)
    assert not target.exists()
    assert marker.exists()


def test_checkout_guard_resolves_an_actual_in_checkout_destination():
    target = REPO / "backend" / ".audit-test-must-not-create"
    assert not target.exists()
    with pytest.raises(ValueError):
        audit.prepare_output_directory(target)
    assert not target.exists()


def test_output_requires_an_existing_parent_and_only_creates_the_requested_child(tmp_path):
    missing_parent = tmp_path / "not-existing" / "fixture"
    with pytest.raises(ValueError):
        audit.prepare_output_directory(missing_parent)
    assert not missing_parent.parent.exists()
    target = tmp_path / "fresh-fixture"
    created = audit.prepare_output_directory(target)
    assert created.resolve() == target.resolve()
    assert created.is_dir() and list(created.iterdir()) == []


@pytest.mark.parametrize("invalid_clock", [CLOCK.replace(tzinfo=None),
    CLOCK.replace(tzinfo=timezone(timedelta(hours=5))), "2026-10-08T12:00:00Z"])
def test_runner_rejects_invalid_clock_before_creating_output(tmp_path, invalid_clock):
    target = tmp_path / "never-created"
    with pytest.raises(ValueError):
        audit.run_audit(target, invalid_clock)
    assert not target.exists()


def test_cli_never_exposes_an_internal_value_error_payload(tmp_path, monkeypatch, capsys):
    sentinel = "PRIVATE_SENTINEL_PIN_payload"

    def refuse(*_args, **_kwargs):
        raise ValueError(sentinel)

    monkeypatch.setattr(audit, "run_audit", refuse)
    target = tmp_path / "never-created"
    with pytest.raises(SystemExit) as caught:
        audit.main(["--now", CLOCK.isoformat(), "--output-dir", str(target)])
    assert caught.value.code == 2
    captured = capsys.readouterr()
    assert sentinel not in captured.err and sentinel not in captured.out
    assert not target.exists()


@pytest.fixture(scope="module")
def baseline(tmp_path_factory):
    target = tmp_path_factory.mktemp("seed-audit-owner") / "fresh-fixture-with-#-hash"
    report = audit.run_audit(target, CLOCK)
    database = target / report["fixture_file"]
    assert database.resolve().parent == target.resolve()
    assert database.is_file()
    return report, database


def test_audit_uses_actual_isolated_sqlite_rows_and_preserves_known_gaps(baseline):
    report, database = baseline
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as db:
        actual_orders = db.execute("SELECT count(*) FROM orders").fetchone()[0]
        actual_closed = db.execute("SELECT count(*) FROM orders WHERE status='closed'").fetchone()[0]
        actual_photos = db.execute("SELECT count(*) FROM photos").fetchone()[0]
        actual_linked_writeoffs = db.execute("SELECT count(*) FROM submission_writeoffs").fetchone()[0]
        actual_attempts = db.execute("SELECT count(*) FROM submission_attempts").fetchone()[0]
        actual_foreign_keys = list(db.execute("PRAGMA foreign_key_check"))
        oldest = datetime.fromisoformat(db.execute("SELECT min(created_at) FROM orders").fetchone()[0])
        revision = db.execute("SELECT version_num FROM alembic_version").fetchone()[0]
    assert report["synthetic"] is True
    assert report["control_utc"] == CLOCK.isoformat()
    assert actual_orders == report["table_counts"]["orders"] == 556
    assert actual_closed == report["status_counts"]["closed"] == 540
    assert actual_photos == report["material_photo"]["photos"] == 0
    assert actual_linked_writeoffs == report["material_photo"]["linked_writeoffs"] == 0
    assert actual_attempts == report["table_counts"]["submission_attempts"] == 541
    assert len(actual_foreign_keys) == report["foreign_key_check_count"] == 0
    assert revision == report["schema_revision"] == "0009_remove_ai_modules"
    assert oldest.replace(tzinfo=timezone.utc).isoformat() == report["calendar"]["min_created_utc"]
    assert report["calendar"]["rolling_three_calendar_months_oldest_gap_seconds"] > 0
    # Missing history remains visible in a baseline; successful tool execution
    # must never turn it into an all-clear or a native-generator acceptance.
    assert "invalid_domain_transition" not in report["findings"]
    assert "latest_complete_summary_time_mismatch" not in report["findings"]
    assert report["findings"]["terminal_assignment_not_ended"]["count"] == 540
    assert report["findings"]["completion_count_attempt_count_mismatch"]["count"] == 43
    assert report["history"]["completion_count_mismatch_shapes"] == {
        "2_complete_events_1_attempts_closed": 42, "0_complete_events_1_attempts_completed": 1}
    assert report["history"]["attempts_with_known_author_assignment"] == 0
    assert report["history"]["assignment_sources"] == {"legacy_snapshot": 556}
    assert report["second_seed"]["unchanged"] is True
    assert report["second_seed"]["same_counts"] is True
    assert report["logical_snapshot_before_second_seed_sha256"] == report["second_seed"]["logical_snapshot_after_sha256"]
    assert report["d19"]["current_active_conflicts_count"] == 0
    assert json.loads((database.parent / "baseline-audit.json").read_text(encoding="utf-8")) == report


def test_audit_binds_aggregate_evidence_to_seed_and_immutable_migration_sources(baseline):
    report, _ = baseline
    source = REPO / "backend" / "app" / "seed.py"
    assert report["source_seed_sha256"] == hashlib.sha256(source.read_bytes()).hexdigest()
    files = sorted((REPO / "backend" / "migrations" / "versions").glob("[0-9]*.py"))
    assert set(report["immutable_migration_sha256"]) == {path.name for path in files}
    for path in files:
        assert report["immutable_migration_sha256"][path.name] == hashlib.sha256(path.read_bytes()).hexdigest()
    assert re.fullmatch(r"[0-9a-f]{64}", report["logical_snapshot_before_second_seed_sha256"])


def test_audit_exports_bounded_aggregates_and_never_raw_people_or_auth_payloads(baseline):
    report, database = baseline
    serialized = json.dumps(report, ensure_ascii=False)
    forbidden_keys = {"pin_hash", "token", "token_hash", "payload", "completion", "data",
        "author_name", "assignee_name", "login", "title", "message", "headers"}

    def inspect(value):
        if isinstance(value, dict):
            assert not forbidden_keys.intersection(value)
            for key, child in value.items():
                if key.endswith("examples"):
                    assert isinstance(child, list) and len(child) <= 8
                inspect(child)
        elif isinstance(value, list):
            for child in value:
                inspect(child)

    inspect(report)
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True) as db:
        private_values = [value for row in db.execute("SELECT name, pin_hash FROM employees") for value in row]
    # Only the integer may enter a failure diagnostic, never the secret value.
    leakage_count = sum(value in serialized for value in private_values)
    assert leakage_count == 0
    assert report["table_counts"]["auth_sessions"] == report["table_counts"]["device_tokens"] == 0
    assert report["limits"]
