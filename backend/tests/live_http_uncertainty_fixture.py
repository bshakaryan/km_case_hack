"""Synthetic fixture and independent SQL oracle for a real lost-response replay.

This is an explicitly invoked CLI, not a pytest test or an application route.
Prepare BEFORE starting create_app(database_url=..., seed=False, monitor=False)
with PUSH_ENABLED=false. The Flutter test creates,
accepts, starts and photographs the order through HTTP, then loses the first
completion response and replays the persisted command with its original basis.

All commands require an absolute SQLite URL ending in
http-uncertainty-<run-marker>/fixture.sqlite. Prepare refuses any existing DB,
manifest or result; verify opens the DB in SQLite read-only mode. Files contain
only synthetic credentials/report data and belong outside the Git checkout.

Example (replace the absolute path, marker and loopback port):
  python backend/tests/live_http_uncertainty_fixture.py prepare \
    --database-url sqlite:///C:/.../http-uncertainty-run-000001/fixture.sqlite \
    --run-marker run-000001 --api-url http://127.0.0.1:8765/api
  python backend/tests/live_http_uncertainty_fixture.py serve \
    --database-url sqlite:///C:/.../http-uncertainty-run-000001/fixture.sqlite \
    --run-marker run-000001
  python backend/tests/live_http_uncertainty_fixture.py verify \
    --database-url sqlite:///C:/.../http-uncertainty-run-000001/fixture.sqlite \
    --run-marker run-000001

Pass fixture.json to Flutter with LIVE_HTTP_FIXTURE_FILE. Flutter writes
result.json containing run_marker, order_id, command_id, photo_id, completion,
body_sha256 and exactly one of expected_version or previous_command_id.
The proxy/test proves identical wire bytes; SQL independently checks the server
canonical request hash, immutable report, original receipt and single effects.
An intermediate post-loss result is deliberately rejected: verified requires
the reconstructed controller, acknowledged replay and empty durable queue.
No authentication token or authorization header is read, printed or exported.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import sys
from urllib.parse import urlsplit

from sqlalchemy import create_engine, event, func, select
from sqlalchemy.engine import URL, make_url
from sqlalchemy.orm import Session
from sqlalchemy.pool import NullPool

# Allow invocation from either the repository root or backend/ without PYTHONPATH.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.migrations import upgrade_database
from app.models import (
    Area, ClientCommand, Employee, Equipment, FaultCode, Material,
    MaterialWriteoff, Order, OrderAssignment, OrderAssignmentParticipant,
    OrderEvent, Photo, SubmissionAttempt, SubmissionPhoto, SubmissionWriteoff,
    TimeNorm,
)
from app.schemas import Completion
from app.security import hash_pin


KIND = "naryad-live-http-uncertainty-fixture"
MARKER = re.compile(r"[A-Za-z0-9_-]{8,64}")
COMMAND_ID = re.compile(r"[A-Za-z0-9._:-]{8,64}")
SHA256 = re.compile(r"[a-f0-9]{64}")
BASELINE = {
    "orders": 0,
    "submission_attempts": 0,
    "material_writeoffs": 0,
    "complete_events": 0,
    "complete_receipts": 0,
}


class FixtureError(Exception):
    """Fixed diagnostic code; never include SQL parameters or credentials."""


def require(condition, code):
    if not condition:
        raise FixtureError(code)


def positive_int(value, code):
    require(type(value) is int and 0 < value <= 2_147_483_647, code)
    return value


def fixture_paths(database_url, marker):
    require(MARKER.fullmatch(marker) is not None, "invalid_run_marker")
    url = make_url(database_url)
    require(
        url.drivername == "sqlite" and url.database and not url.query
        and url.host is None and url.username is None and url.password is None,
        "explicit_sqlite_url_required",
    )
    path = Path(url.database)
    require(path.is_absolute(), "absolute_database_path_required")
    require(path.name == "fixture.sqlite", "owned_database_filename_required")
    require(
        path.parent.name == f"http-uncertainty-{marker}",
        "owned_run_directory_required",
    )
    # Refuse a junction/symlink which could redirect this explicit owned path.
    require(path.absolute() == path.resolve(), "redirected_database_path")
    directory = path.parent
    require(
        not directory.is_relative_to(Path(__file__).resolve().parents[2]),
        "fixture_must_be_outside_git_checkout",
    )
    return path, directory / "fixture.json", directory / "result.json"


def loopback_api(value):
    parsed = urlsplit(value)
    require(
        parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost", "::1"}
        and parsed.username is None and parsed.password is None
        and parsed.path == "/api" and not parsed.query and not parsed.fragment
        and parsed.port is not None,
        "explicit_loopback_api_required",
    )
    return value


def read_json(path):
    require(path.is_file() and not path.is_symlink(), "fixture_json_missing")
    require(path.stat().st_size <= 1_000_000, "fixture_json_too_large")
    with path.open("r", encoding="utf-8") as source:
        result = json.load(source)
    require(isinstance(result, dict), "fixture_json_object_required")
    return result


def prepare(args):
    database, manifest_path, result_path = fixture_paths(args.database_url, args.run_marker)
    api_url = loopback_api(args.api_url)
    require(
        not database.exists() and not manifest_path.exists() and not result_path.exists(),
        "prepare_refuses_existing_fixture",
    )
    database.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation prevents accidentally opening another process's DB.
    with database.open("xb"):
        pass
    engine = create_engine(URL.create("sqlite", database=str(database)))

    @event.listens_for(engine, "connect")
    def foreign_keys(connection, _):
        connection.execute("PRAGMA foreign_keys=ON")

    try:
        upgrade_database(engine)
        with Session(engine) as db, db.begin():
            db.add(Area(id=1, name=f"Synthetic area {args.run_marker}"))
            db.flush()
            db.add_all([
                Employee(id=1, name="Synthetic master", login="master", role="master",
                         pin_hash=hash_pin("1234"), specialty="", grade=0, on_shift=True),
                Employee(id=6, name="Synthetic worker 2", login="worker2", role="worker",
                         pin_hash=hash_pin("1234"), specialty="", grade=0, on_shift=True),
                Equipment(id=1, name="Synthetic repair fixture", area_id=1,
                          inventory_number=f"SYN-{args.run_marker}", type="synthetic",
                          criticality="medium"),
                FaultCode(id=1, code="SYN-FAULT", name="Synthetic fixture fault"),
                Material(id=1, name="Synthetic replacement part", unit="шт"),
                TimeNorm(id=1, name="Synthetic reference norm", hours=1.5),
            ])
            db.flush()
            baseline = {
                "orders": count(db, Order),
                "submission_attempts": count(db, SubmissionAttempt),
                "material_writeoffs": count(db, MaterialWriteoff),
                "complete_events": count(db, OrderEvent, OrderEvent.action == "complete"),
                "complete_receipts": count(db, ClientCommand, ClientCommand.kind == "complete"),
            }
            require(baseline == BASELINE, "prepared_baseline_not_empty")
        manifest = {
            "schema": 1, "kind": KIND, "fresh": True, "run_marker": args.run_marker,
            "api_url": api_url,
            "master": {"login": "master", "pin": "1234"},
            "worker": {"login": "worker2", "pin": "1234", "id": 6},
            "area_id": 1, "equipment_id": 1, "fault_code_id": 1,
            "material_id": 1, "material_quantity": 2,
            "equipment_fixture_marker": f"SYN-{args.run_marker}",
            "baseline": baseline, "result_file": str(result_path),
        }
        with manifest_path.open("x", encoding="utf-8") as output:
            json.dump(manifest, output, ensure_ascii=False, indent=2)
            output.write("\n")
    finally:
        engine.dispose()
    return {"status": "prepared", "run_marker": args.run_marker,
            "manifest_file": str(manifest_path), "database_file": str(database)}


def request_hash(*parts):
    return hashlib.sha256("\x1f".join(parts).encode("utf-8")).hexdigest()


def one(db, model, code, *conditions):
    rows = list(db.scalars(select(model).where(*conditions)))
    require(len(rows) == 1, code)
    return rows[0]


def count(db, model, *conditions):
    return db.scalar(select(func.count()).select_from(model).where(*conditions))


def verify_snapshot(db, manifest, result):
    marker = manifest["run_marker"]
    require(result.get("run_marker") == marker, "result_marker_mismatch")
    require(
        all(result.get(field) is True for field in (
            "acknowledged", "controller_reconstructed", "local_outbox_empty_after_ack",
        )),
        "final_replay_acknowledgement_required",
    )
    for field, expected in (
        ("forwarded_complete_posts", 2), ("held_mutations", 0),
        ("lost_reply_upstream_status", 200), ("lost_reply_local_status", 0),
    ):
        require(type(result.get(field)) is int and result[field] == expected,
                "final_transport_witness_mismatch")
    order_id = positive_int(result.get("order_id"), "invalid_result_order_id")
    photo_id = positive_int(result.get("photo_id"), "invalid_result_photo_id")
    client_id = result.get("command_id")
    require(isinstance(client_id, str) and COMMAND_ID.fullmatch(client_id), "invalid_result_command_id")
    wire_hash = result.get("body_sha256")
    require(isinstance(wire_hash, str) and SHA256.fullmatch(wire_hash), "invalid_wire_body_hash")
    replay_wire_hash = result.get("replay_body_sha256")
    require(isinstance(replay_wire_hash, str) and SHA256.fullmatch(replay_wire_hash)
            and replay_wire_hash == wire_hash, "replay_wire_body_hash_mismatch")
    for field in ("original_response_sha256", "replay_response_sha256"):
        value = result.get(field)
        require(isinstance(value, str) and SHA256.fullmatch(value), "invalid_response_body_hash")
    report = Completion.model_validate(result.get("completion")).model_dump()
    require(marker in report["work_done"], "report_marker_missing")
    require(report["fault_code_id"] == 1, "report_fault_mismatch")
    require(report["materials"] == [{"material_id": 1, "quantity": 2.0}], "report_material_mismatch")

    require(count(db, Order) == 1, "exactly_one_synthetic_order_required")
    order = one(db, Order, "order_not_found", Order.id == order_id)
    require(order.title == marker, "order_marker_mismatch")
    require(
        (order.area_id, order.equipment_id, order.master_id, order.assignee_id, order.brigade_id)
        == (1, 1, 1, 6, None), "order_identity_mismatch",
    )
    require(order.work_type == "unplanned", "unplanned_order_required")
    require(order.started_at is not None and order.completed_at is not None, "completion_timestamps_missing")
    equipment = one(db, Equipment, "fixture_equipment_missing", Equipment.id == 1)
    require(equipment.inventory_number == f"SYN-{marker}" and equipment.area_id == 1, "equipment_marker_mismatch")
    worker = one(db, Employee, "fixture_worker_missing", Employee.id == 6)
    require(worker.login == "worker2" and worker.role == "worker", "fixture_worker_identity_mismatch")
    material = one(db, Material, "fixture_material_missing", Material.id == 1)
    frozen_report = {**report, "materials": [
        {**report["materials"][0], "name": material.name, "unit": material.unit},
    ]}
    require(order.completion == frozen_report, "aggregate_completion_mismatch")

    require(count(db, OrderAssignment) == 1, "duplicate_or_missing_assignment")
    assignment = one(db, OrderAssignment, "order_assignment_missing", OrderAssignment.order_id == order_id)
    require(
        assignment.sequence == 1 and assignment.source == "live"
        and assignment.assignee_id == 6 and assignment.brigade_id is None
        and assignment.assigned_by_id == 1 and assignment.assigned_at == order.assigned_at,
        "assignment_identity_mismatch",
    )
    participant = one(db, OrderAssignmentParticipant, "duplicate_or_missing_participant")
    require(participant.assignment_id == assignment.id and participant.employee_id == 6
            and participant.name == worker.name and participant.source == "live", "participant_identity_mismatch")

    photo = one(db, Photo, "duplicate_or_missing_photo")
    require(photo.id == photo_id and photo.order_id == order_id and photo.author_id == 6
            and photo.kind == "after" and len(photo.data) > 0, "photo_identity_mismatch")
    attempt = one(db, SubmissionAttempt, "duplicate_or_missing_submission_attempt")
    require(attempt.order_id == order_id and attempt.sequence == 1
            and attempt.assignment_id == assignment.id and attempt.author_id == 6
            and attempt.source == "live" and attempt.submitted_at == order.completed_at,
            "attempt_identity_mismatch")
    require(attempt.payload == frozen_report, "immutable_attempt_payload_mismatch")
    photo_link = one(db, SubmissionPhoto, "duplicate_or_missing_submission_photo")
    require(photo_link.attempt_id == attempt.id and photo_link.photo_id == photo_id, "submission_photo_link_mismatch")

    writeoff = one(db, MaterialWriteoff, "duplicate_or_missing_material_writeoff")
    require(writeoff.order_id == order_id and writeoff.material_id == 1
            and writeoff.author_id == 6 and writeoff.quantity == 2.0, "material_writeoff_mismatch")
    writeoff_link = one(db, SubmissionWriteoff, "duplicate_or_missing_submission_writeoff")
    require(writeoff_link.attempt_id == attempt.id and writeoff_link.writeoff_id == writeoff.id,
            "submission_writeoff_link_mismatch")
    complete_event = one(db, OrderEvent, "duplicate_or_missing_complete_event", OrderEvent.action == "complete")
    require(complete_event.order_id == order_id and complete_event.actor_id == 6
            and complete_event.from_status == "in_progress" and complete_event.to_status == "completed"
            and complete_event.comment == report["work_done"], "complete_event_mismatch")
    receipt = one(db, ClientCommand, "duplicate_or_missing_complete_receipt", ClientCommand.kind == "complete")
    require(receipt.employee_id == 6 and receipt.client_id == client_id
            and receipt.order_id == order_id and receipt.response_status == 200, "receipt_identity_mismatch")
    expected_version, previous = result.get("expected_version"), result.get("previous_command_id")
    require((expected_version is not None) != (previous is not None), "exactly_one_version_basis_required")
    if expected_version is not None:
        basis, value = "version", positive_int(expected_version, "invalid_expected_version")
        version_before = value
    else:
        require(isinstance(previous, str) and COMMAND_ID.fullmatch(previous) and previous != client_id,
                "invalid_previous_command_id")
        prior = one(db, ClientCommand, "previous_receipt_missing",
                    ClientCommand.employee_id == 6, ClientCommand.client_id == previous)
        require(prior.order_id == order_id and prior.response_status is not None
                and 200 <= prior.response_status < 300, "previous_receipt_identity_mismatch")
        version_before = positive_int(prior.order_version, "previous_receipt_version_missing")
        basis, value = "previous", previous
    canonical_hash = request_hash(json.dumps(report, sort_keys=True, ensure_ascii=False, default=str))
    require(receipt.request_hash == request_hash("client-command-v3", "complete", str(order_id),
            canonical_hash, basis, str(value)), "receipt_request_hash_mismatch")
    require(receipt.order_version == version_before + 1 and order.version >= receipt.order_version,
            "receipt_version_mismatch")
    body = receipt.response_body
    require(isinstance(body, dict) and body.get("id") == order_id
            and body.get("version") == receipt.order_version and body.get("completion") == frozen_report,
            "original_receipt_body_mismatch")
    # This fixture is SQLite-only: stored JSON preserves the original body key
    # order. Reproduce the actual Starlette JSONResponse renderer and compare
    # both captured HTTP responses to the immutable server receipt. This is a
    # concrete transport witness, not a general JSON field-order API promise.
    response_bytes = json.dumps(body, ensure_ascii=False, allow_nan=False,
                               separators=(",", ":")).encode("utf-8")
    response_hash = hashlib.sha256(response_bytes).hexdigest()
    require(result["original_response_sha256"] == response_hash
            and result["replay_response_sha256"] == response_hash,
            "http_response_receipt_hash_mismatch")
    saved_attempts = body.get("submission_attempts")
    require(isinstance(saved_attempts, list) and len(saved_attempts) == 1
            and saved_attempts[0].get("id") == attempt.id
            and saved_attempts[0].get("completion") == frozen_report,
            "original_receipt_attempt_mismatch")
    require(not db.connection().exec_driver_sql("PRAGMA foreign_key_check").first(), "broken_fixture_foreign_keys")
    # Notification delivery and current version may advance independently;
    # neither is evidence of another completion effect.
    return {
        "status": "verified", "run_marker": marker, "order_id": order_id,
        "attempt_id": attempt.id, "writeoff_id": writeoff.id,
        "receipt_version": receipt.order_version,
        "submission_attempts": 1, "material_writeoffs": 1, "material_quantity": 2,
        "complete_events": 1, "complete_receipts": 1,
    }


def prepared_fixture(args):
    database, manifest_path, result_path = fixture_paths(args.database_url, args.run_marker)
    require(database.is_file() and database.stat().st_size > 0, "prepared_database_missing")
    manifest = read_json(manifest_path)
    require(manifest.get("schema") == 1 and manifest.get("kind") == KIND
            and manifest.get("fresh") is True and manifest.get("run_marker") == args.run_marker
            and manifest.get("baseline") == BASELINE, "manifest_identity_mismatch")
    loopback_api(manifest.get("api_url", ""))
    require(manifest.get("result_file") == str(result_path), "manifest_result_path_mismatch")
    return database, manifest, result_path


def serve(args):
    database, manifest, _ = prepared_fixture(args)
    api = urlsplit(manifest["api_url"])
    database_url = str(URL.create("sqlite", database=str(database)))
    # app.main also exposes a module-level app, so set its explicit isolated
    # DB/environment before importing it. Nothing can select the working DB.
    os.environ.update({
        "DATABASE_URL": database_url, "PUSH_ENABLED": "false",
        "SEED_DEMO": "false",
    })
    import uvicorn
    from app.main import create_app

    uvicorn.run(create_app(database_url=database_url, seed=False, monitor=False),
                host=api.hostname, port=api.port, access_log=False)
    return {"status": "server_stopped", "run_marker": args.run_marker}


def verify(args):
    database, manifest, result_path = prepared_fixture(args)
    result = read_json(result_path)
    # sqlite3 mode=ro prevents the SQL oracle from mutating even an owned DB.
    engine = create_engine("sqlite://", poolclass=NullPool,
        creator=lambda: sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True))
    try:
        with engine.connect() as connection:
            connection.exec_driver_sql("PRAGMA query_only=ON")
            connection.exec_driver_sql("BEGIN")
            with Session(bind=connection) as db:
                return verify_snapshot(db, manifest, result)
    finally:
        engine.dispose()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subcommands = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "serve", "verify"):
        subparser = subcommands.add_parser(name)
        subparser.add_argument("--database-url", required=True)
        subparser.add_argument("--run-marker", required=True)
        if name == "prepare":
            subparser.add_argument("--api-url", required=True)
    args = parser.parse_args()
    try:
        result = {"prepare": prepare, "serve": serve, "verify": verify}[args.command](args)
    except FixtureError as error:
        print(json.dumps({"status": "failed", "code": str(error)}), file=sys.stderr)
        return 1
    except Exception as error:
        # A SQL/validation exception can contain a PIN hash or report. Its
        # class is sufficient diagnostic data for this synthetic CLI.
        print(json.dumps({"status": "failed", "code": "fixture_internal_error",
                          "error_type": type(error).__name__}), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
