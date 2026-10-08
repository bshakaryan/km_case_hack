"""Audit the current synthetic seed in a new, isolated SQLite database.

This is evidence collection, not a production repair or a seed acceptance gate.
The output contains aggregates, bounded numeric IDs and hashes only. There is no
application startup, monitor, push transport, AI provider or default database.
Transition checks cover the current seed action subset, not every API command;
unknown actions require review and do not automatically mean an R40 failure.
"""
from __future__ import annotations

import argparse
import ast
import calendar
from collections import Counter, defaultdict
from contextlib import closing
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import types

REPO_ROOT = Path(__file__).resolve().parents[2]
MAX_EXAMPLES = 8


def parse_utc_clock(value: str) -> datetime:
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise argparse.ArgumentTypeError("--now must be an ISO-8601 UTC timestamp") from error
    if result.tzinfo is None or result.utcoffset() != timezone.utc.utcoffset(result):
        raise argparse.ArgumentTypeError("--now must be timezone-aware UTC (+00:00 or Z)")
    return result.astimezone(timezone.utc)


def prepare_output_directory(path: Path, repository: Path = REPO_ROOT) -> Path:
    """Create one new child of an existing parent, outside all Git checkouts."""
    path = Path(path).expanduser().resolve()
    repository = Path(repository).resolve()
    if path.exists():
        raise ValueError("--output-dir must not already exist")
    if path == repository or repository in path.parents:
        raise ValueError("--output-dir must be outside the repository")
    if not path.parent.is_dir():
        raise ValueError("--output-dir parent must already be a directory")
    if any((ancestor / ".git").exists() for ancestor in (path.parent, *path.parent.parents)):
        raise ValueError("--output-dir must be outside all Git checkouts")
    path.mkdir(exist_ok=False)
    return path


def _date(value):
    if value is None:
        return None
    parsed = datetime.fromisoformat(value)
    return parsed.replace(tzinfo=timezone.utc) if parsed.tzinfo is None else parsed


def _json(value):
    return json.loads(value) if value is not None else None


def _table_sql(table: str) -> str:
    return '"' + table.replace('"', '""') + '"'


def _logical_digest(connection, tables) -> str:
    """Read complete rows internally; only the final hash leaves this function."""
    digest = hashlib.sha256()
    for table in tables:
        digest.update(table.encode())
        for row in connection.execute(f"SELECT * FROM {_table_sql(table)} ORDER BY 1"):
            values = [
                {"blob_sha256": hashlib.sha256(value).hexdigest(), "bytes": len(value)}
                if isinstance(value, bytes) else value for value in row
            ]
            digest.update(json.dumps(values, ensure_ascii=False, separators=(",", ":")).encode())
    return digest.hexdigest()


def _three_months_before(value: datetime) -> datetime:
    month_index = value.year * 12 + value.month - 1 - 3
    year, zero_month = divmod(month_index, 12)
    month = zero_month + 1
    return value.replace(year=year, month=month, day=min(value.day, calendar.monthrange(year, month)[1]))


def _audit(connection, control: datetime) -> dict:
    tables = sorted(row[0] for row in connection.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'"))
    all_rows = {
        table: [dict(row) for row in connection.execute(f"SELECT * FROM {_table_sql(table)} ORDER BY id")]
        for table in tables if table != "alembic_version"
    }
    orders = all_rows["orders"]
    events = all_rows["order_events"]
    attempts = all_rows["submission_attempts"]
    assignments = all_rows["order_assignments"]
    participants = all_rows["order_assignment_participants"]
    writeoffs = all_rows["material_writeoffs"]
    by_events, by_attempts, by_assignments, by_participants, by_writeoffs = (
        defaultdict(list) for _ in range(5))
    for row in events:
        by_events[row["order_id"]].append(row)
    for row in attempts:
        by_attempts[row["order_id"]].append(row)
    for row in assignments:
        by_assignments[row["order_id"]].append(row)
    for row in participants:
        by_participants[row["assignment_id"]].append(row)
    for row in writeoffs:
        by_writeoffs[row["order_id"]].append(row)

    # Current seed action subset of server constraints. This does not model all
    # legitimate edit/reassign/cancel commands or become an R40 acceptance gate.
    rules = {
        "issue": (None, "issued"), "accept": ({"issued", "rework"}, "accepted"),
        "queue": ({"issued", "rework", "accepted"}, "queued"),
        "reject": ({"issued", "accepted", "queued"}, "rejected"),
        "start": ({"accepted", "queued"}, "in_progress"),
        "pause": ({"in_progress"}, "paused"), "resume": ({"paused"}, "in_progress"),
        "complete": ({"in_progress"}, "completed"), "ai_review": ({"completed"}, "ai_review"),
        "rework": ({"ai_review"}, "rework"), "close": ({"ai_review"}, "closed"),
    }
    issues = defaultdict(list)
    completion_mismatch_shapes = Counter()
    for order in orders:
        oid = order["id"]
        sequence = by_events[oid]
        chronological = sorted(sequence, key=lambda event: (_date(event["created_at"]), event["id"]))
        if [event["id"] for event in sequence] != [event["id"] for event in chronological]:
            issues["insert_order_not_chronological"].append(oid)
        state = None
        for event in chronological:
            if event["from_status"] != state:
                issues["event_chain_break"].append(event["id"])
            rule = rules.get(event["action"])
            if rule is None:
                issues["non_domain_event_action"].append(event["id"])
            else:
                allowed, target = rule
                valid = event["from_status"] is None if allowed is None else event["from_status"] in allowed
                if not valid or event["to_status"] != target:
                    issues["invalid_domain_transition"].append(event["id"])
            if not (_date(order["created_at"]) <= _date(event["created_at"]) <= control):
                issues["event_outside_created_control"].append(event["id"])
            state = event["to_status"]
        if state != order["status"]:
            issues["latest_event_summary_status_mismatch"].append(oid)
        completions = [event for event in chronological if event["action"] == "complete"]
        if completions and _date(completions[-1]["created_at"]) != _date(order["completed_at"]):
            issues["latest_complete_summary_time_mismatch"].append(oid)
        if len(completions) != len(by_attempts[oid]):
            issues["completion_count_attempt_count_mismatch"].append(oid)
            shape = f"{len(completions)}_complete_events_{len(by_attempts[oid])}_attempts_{order['status']}"
            completion_mismatch_shapes[shape] += 1
        latest = max(by_attempts[oid], key=lambda row: row["sequence"]) if by_attempts[oid] else None
        if latest and (_json(latest["payload"]) != _json(order["completion"])
                       or _date(latest["submitted_at"]) != _date(order["completed_at"])):
            issues["latest_attempt_summary_mismatch"].append(oid)
        assignment = max(by_assignments[oid], key=lambda row: row["sequence"]) if by_assignments[oid] else None
        if assignment is None:
            issues["missing_current_assignment"].append(oid)
        elif (assignment["assignee_id"] != order["assignee_id"]
              or assignment["brigade_id"] != order["brigade_id"]
              or _date(assignment["assigned_at"]) != _date(order["assigned_at"])):
            issues["current_assignment_summary_mismatch"].append(oid)
        if assignment and not any(row["employee_id"] == order["assignee_id"]
                                  for row in by_participants[assignment["id"]]):
            issues["responsible_absent_from_frozen_roster"].append(oid)
        if assignment and order["status"] in ("closed", "cancelled") and assignment["ended_at"] is None:
            issues["terminal_assignment_not_ended"].append(oid)
        totals, actual = defaultdict(float), defaultdict(float)
        for item in (_json(order["completion"]) or {}).get("materials", []):
            totals[item["material_id"]] += float(item["quantity"])
        for row in by_writeoffs[oid]:
            actual[row["material_id"]] += float(row["quantity"])
        if dict(totals) != dict(actual):
            issues["summary_material_writeoff_total_mismatch"].append(oid)
        times = [_date(order[key]) for key in
                 ("created_at", "assigned_at", "started_at", "completed_at", "closed_at")
                 if order[key] is not None]
        if times != sorted(times):
            issues["summary_time_order_mismatch"].append(oid)

    active, intervals = defaultdict(list), defaultdict(list)
    for order in orders:
        if order["status"] in ("accepted", "in_progress", "paused"):
            active[order["assignee_id"]].append(order)
        accepted = [event for event in by_events[order["id"]] if event["action"] == "accept"]
        completed = [event for event in by_events[order["id"]] if event["action"] == "complete"]
        if accepted and completed:
            intervals[order["assignee_id"]].append((
                _date(accepted[0]["created_at"]), _date(completed[-1]["created_at"]), order["id"]))
    overlaps = []
    for group in intervals.values():
        ordered = sorted(group)
        for index, first in enumerate(ordered):
            for second in ordered[index + 1:]:
                if second[0] >= first[1]:
                    break
                overlaps.append([first[2], second[2]])

    created = [_date(order["created_at"]) for order in orders]
    historical = [_date(order["created_at"]) for order in orders if order["status"] == "closed"]
    rolling_start = _three_months_before(control)
    counts = {table: connection.execute(f"SELECT COUNT(*) FROM {_table_sql(table)}").fetchone()[0]
              for table in tables}
    # Empty seed still yields a reviewable manifest rather than a min() error.
    earliest, latest = (min(created), max(created)) if created else (None, None)
    return {
        "schema_revision": connection.execute("SELECT version_num FROM alembic_version").fetchone()[0],
        "table_counts": counts,
        "roles": dict(Counter(row["role"] for row in all_rows["employees"])),
        "workers_per_brigade": dict(Counter(str(row["brigade_id"]) for row in all_rows["employees"]
                                            if row["role"] == "worker")),
        "status_counts": dict(Counter(row["status"] for row in orders)),
        "calendar": {
            "min_created_utc": earliest.isoformat() if earliest else None,
            "max_created_utc": latest.isoformat() if latest else None,
            "created_span_seconds": (latest - earliest).total_seconds() if earliest else None,
            "oldest_age_days_at_control": (control - earliest).total_seconds() / 86400 if earliest else None,
            "historical_min_created_utc": min(historical).isoformat() if historical else None,
            "historical_max_created_utc": max(historical).isoformat() if historical else None,
            "historical_counts_per_month": dict(sorted(Counter(value.strftime("%Y-%m")
                                                                for value in historical).items())),
            "rolling_three_calendar_months_start_utc": rolling_start.isoformat(),
            "rolling_three_calendar_months_oldest_gap_seconds": (earliest - rolling_start).total_seconds()
            if earliest else None,
            "note": "PDF does not specify rolling versus completed calendar months; this is an explicit calendar comparison, not adoption of enterprise policy.",
        },
        "history": {
            "event_actions": dict(Counter(row["action"] for row in events)),
            "assignment_sources": dict(Counter(row["source"] for row in assignments)),
            "participant_sources": dict(Counter(row["source"] for row in participants)),
            "attempt_sources": dict(Counter(row["source"] for row in attempts)),
            "attempts_with_known_author_assignment": sum(row["author_id"] is not None
                                                         and row["assignment_id"] is not None for row in attempts),
            "attempts_with_assessment_link": sum(row["assessment_id"] is not None for row in attempts),
            "frozen_roster_size_distribution": dict(Counter(str(len(by_participants[row["id"]]))
                                                            for row in assignments)),
            "completion_count_mismatch_shapes": dict(completion_mismatch_shapes),
            "legacy_note": "Legacy provenance/ended_at absence is conservative migration behavior, not database corruption. Newly generated known history can provide native provenance.",
        },
        "material_photo": {
            "positive_writeoffs": sum(row["quantity"] > 0 for row in writeoffs),
            "linked_writeoffs": counts["submission_writeoffs"],
            "photos": counts["photos"], "submission_photo_links": counts["submission_photos"],
        },
        "d19": {
            "current_active_conflicts_count": sum(len(group) > 1 for group in active.values()),
            "current_active_conflict_order_examples": [
                [order["id"] for order in group] for group in active.values() if len(group) > 1
            ][:MAX_EXAMPLES],
            "current_waiting_count": sum(order["status"] in ("accepted", "queued") for order in orders),
            "historical_known_execution_overlap_pairs_count": len(overlaps),
            "historical_overlap_examples": overlaps[:MAX_EXAMPLES],
            "historical_overlap_definition": "Same assignee first accept to last complete; constructed history intervals, not measured work, shifts or Q04 downtime.",
        },
        "findings": {key: {"count": len(values), "examples": values[:MAX_EXAMPLES]}
                     for key, values in sorted(issues.items())},
        "foreign_key_check_count": len(connection.execute("PRAGMA foreign_key_check").fetchall()),
        "logical_snapshot_before_second_seed_sha256": _logical_digest(connection, tables),
    }


def run_audit(output_dir: Path, now: datetime) -> dict:
    """Create exactly one fresh fixture, inspect it, then seed the same DB again."""
    if not isinstance(now, datetime) or now.tzinfo is None or now.utcoffset() != timezone.utc.utcoffset(now):
        raise ValueError("Control clock must be an aware UTC datetime")
    # Check Gregorian calendar comparison before creating any output directory.
    _three_months_before(now)
    root = prepare_output_directory(output_dir)
    db_path = root / "synthetic-baseline.sqlite"
    backend = REPO_ROOT / "backend"
    source_path = backend / "app" / "seed.py"
    source = source_path.read_bytes()
    source_hash = hashlib.sha256(source).hexdigest()
    rng_literals = [node.args[0].value for node in ast.walk(ast.parse(source))
                    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                    and isinstance(node.func.value, ast.Name) and node.func.value.id == "random"
                    and node.func.attr == "Random" and len(node.args) == 1
                    and isinstance(node.args[0], ast.Constant)
                    and type(node.args[0].value) is int]
    migration_hashes = {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                        for path in sorted((backend / "migrations" / "versions").glob("*.py"))}
    sys.path.insert(0, str(backend))
    from sqlalchemy import create_engine, event
    from sqlalchemy.orm import sessionmaker
    from app.migrations import upgrade_database

    seed = types.ModuleType("app.seed")
    seed.__package__ = "app"
    seed.__file__ = str(source_path)
    exec(compile(source, str(source_path), "exec"), seed.__dict__)
    seed.utcnow = lambda: now
    engine = create_engine("sqlite:///" + db_path.as_posix())

    @event.listens_for(engine, "connect")
    def foreign_keys(connection, _):
        connection.execute("PRAGMA foreign_keys=ON")

    Session = sessionmaker(bind=engine, expire_on_commit=False)
    try:
        upgrade_database(engine)
        with Session() as db:
            seed.seed_database(db)
        engine.dispose()
        with closing(sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
            connection.row_factory = sqlite3.Row
            report = _audit(connection, now)
        with Session() as db:
            seed.seed_database(db)
        engine.dispose()
        with closing(sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True)) as connection:
            connection.row_factory = sqlite3.Row
            after_hash = _logical_digest(connection, sorted(report["table_counts"]))
            report["second_seed"] = {
                "logical_snapshot_after_sha256": after_hash,
                "unchanged": after_hash == report["logical_snapshot_before_second_seed_sha256"],
                "same_counts": all(count == connection.execute(
                    f"SELECT COUNT(*) FROM {_table_sql(table)}").fetchone()[0]
                    for table, count in report["table_counts"].items()),
            }
    finally:
        engine.dispose()
    if source_hash != hashlib.sha256(source_path.read_bytes()).hexdigest():
        raise RuntimeError("Seed source changed during the audit")
    if migration_hashes != {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                            for path in sorted((backend / "migrations" / "versions").glob("*.py"))}:
        raise RuntimeError("Migration source changed during the audit")
    report.update({
        "manifest_version": 1, "synthetic": True,
        "scope": "Actual fresh SQLite seed audit; no server, working DB, push or real AI. Findings are evidence, not an acceptance pass.",
        "fixture_file": db_path.name, "control_utc": now.isoformat(),
        "rng_seed": rng_literals[0] if len(rng_literals) == 1 else None,
        "rng_seed_source": "Unique literal random.Random(int) constructor in app/seed.py, bound by source_seed_sha256; null if not uniquely identifiable.",
        "source_seed_sha256": source_hash, "source_unchanged_during_run": True,
        "immutable_migration_sha256": migration_hashes,
        "limits": [
            "SQLite does not prove PostgreSQL locking or concurrency.",
            "Transition checks cover the current seed action subset, not all API commands; unknown actions require review, not automatic R40 failure.",
            "Seeded people, photos and patterns are synthetic; patterns do not prove real AI accuracy.",
            "No Q01-Q06 policy/provider/photo verdict is inferred.",
            "PIN salts are random; repeat hash stability is within this fixture, not byte-identical independent databases.",
            "No Android, crash, fsync, power-loss, real push or media acceptance.",
        ],
    })
    (root / "baseline-audit.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    return report


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True,
                        help="New child of an existing directory outside all Git checkouts")
    parser.add_argument("--now", type=parse_utc_clock, required=True,
                        help="Fixed aware UTC clock, e.g. 2026-10-08T12:00:00Z")
    args = parser.parse_args(argv)
    try:
        report = run_audit(args.output_dir, args.now)
    except ValueError:
        # A seed/data ValueError can contain raw values, just like a SQL error.
        parser.error("Invalid audit configuration or fixture data; details are not emitted")
    except Exception as error:
        # Never print a SQLAlchemy exception with embedded payload/credentials.
        print(f"audit_failed:{type(error).__name__}; inspect the owned fixture privately", file=sys.stderr)
        return 1
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
