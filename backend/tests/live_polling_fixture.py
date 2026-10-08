"""Explicit synthetic HTTP polling baseline fixture; never a production seed.

The fixed workload has exactly 500 orders: 350 closed, 100 cancelled, 42 issued
and 8 queued. It uses one synthetic master, worker, area and equipment. States
and aggregate closed reports are seeded through SQL, with known singleton
assignment snapshots; this does not claim a full workflow or performance SLA.
Targets 1/2 are fresh issued orders, version 1. Target 1 is the only emergency
and all active deadlines are in the future, keeping its overview card visible.
The harness changes its deadline and target 2's description through the existing
authenticated, version-checked PATCH API; it does not create more orders.

All files must be NEW and outside the checkout, in the explicitly named
polling-baseline-<run-marker>/ directory. No default DB or environment URL is
accepted. Serve verifies the DB/manifest markers before importing app.main,
disables demo seeding, push, monitors and background AI, and disables HTTP access
logs. Auth tokens and headers are never printed or written by this utility.

Example (replace the path and marker):
  python backend/tests/live_polling_fixture.py prepare \
    --database-url sqlite:///C:/.../polling-baseline-run-000001/fixture.sqlite \
    --run-marker run-000001 --api-url http://127.0.0.1:8022/api
  python backend/tests/live_polling_fixture.py serve \
    --database-url sqlite:///C:/.../polling-baseline-run-000001/fixture.sqlite \
    --run-marker run-000001

Pass fixture.json to the separately invoked Flutter HTTP measurement test.
Its result_file is outside Git; the result contains measurements, not payloads
or credentials. Prepare/serve are not tests and perform no polling optimization.
"""

from __future__ import annotations

import argparse
from datetime import timedelta
import json
import os
from pathlib import Path
import re
import sqlite3
import sys

from sqlalchemy import create_engine, event, func, select
from sqlalchemy.engine import URL, make_url
from sqlalchemy.orm import Session

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.migrations import upgrade_database
from app.models import Area, Employee, Equipment, FaultCode, Material, Order, OrderEvent, TimeNorm, utcnow
from app.security import hash_pin
from app.services import append_assignment
from live_http_uncertainty_fixture import FixtureError, loopback_api, read_json, require


KIND = "naryad-live-polling-measurement-fixture"
MARKER = re.compile(r"[A-Za-z0-9_-]{8,64}")
STATUS_DISTRIBUTION = {"closed": 350, "cancelled": 100, "issued": 42, "queued": 8}
REFERENCE_COUNTS = {
    "areas": 1, "equipment": 1, "employees": 2, "brigades": 0,
    "fault_codes": 1, "materials": 1, "time_norms": 1,
}


def fixture_paths(database_url, marker):
    require(MARKER.fullmatch(marker) is not None, "invalid_run_marker")
    url = make_url(database_url)
    require(url.drivername == "sqlite" and url.database and not url.query
            and url.host is None and url.username is None and url.password is None,
            "explicit_sqlite_url_required")
    path = Path(url.database)
    require(path.is_absolute() and path.name == "fixture.sqlite", "absolute_owned_database_required")
    require(path.parent.name == f"polling-baseline-{marker}", "owned_run_directory_required")
    require(path.absolute() == path.resolve(), "redirected_database_path")
    require(not path.parent.is_relative_to(Path(__file__).resolve().parents[2]),
            "fixture_must_be_outside_git_checkout")
    return path, path.parent / "fixture.json", path.parent / "result.json"


def prepare(args):
    database, manifest_path, result_path = fixture_paths(args.database_url, args.run_marker)
    api_url = loopback_api(args.api_url)
    require(not database.exists() and not manifest_path.exists() and not result_path.exists(),
            "prepare_refuses_existing_fixture")
    database.parent.mkdir(parents=True, exist_ok=True)
    with database.open("xb"):
        pass
    engine = create_engine(URL.create("sqlite", database=str(database)))

    @event.listens_for(engine, "connect")
    def foreign_keys(connection, _):
        connection.execute("PRAGMA foreign_keys=ON")

    try:
        upgrade_database(engine)
        now = utcnow()
        descriptions = {
            1: f"Synthetic overview polling baseline {args.run_marker}",
            2: f"Synthetic detail polling baseline {args.run_marker}",
        }
        with Session(engine) as db, db.begin():
            db.add(Area(id=1, name="Synthetic polling area"))
            db.flush()
            master = Employee(id=1, name="Synthetic polling master", login="master", role="master",
                              pin_hash=hash_pin("1234"), specialty="", grade=0, on_shift=True)
            worker = Employee(id=6, name="Synthetic polling worker", login="worker2", role="worker",
                              pin_hash=hash_pin("1234"), specialty="", grade=0, on_shift=True)
            db.add_all([
                master, worker,
                Equipment(id=1, name="Synthetic polling equipment", area_id=1, type="synthetic",
                          inventory_number=f"SYN-POLL-{args.run_marker}", criticality="medium"),
                FaultCode(id=1, code="SYN-POLL", name="Synthetic polling fault"),
                Material(id=1, name="Synthetic polling material", unit="шт"),
                TimeNorm(id=1, name="Synthetic polling norm", hours=1.5),
            ])
            db.flush()
            for id_ in range(1, 501):
                status = "issued" if id_ <= 42 else "queued" if id_ <= 50 else "closed" if id_ <= 400 else "cancelled"
                active = status in {"issued", "queued"}
                created = now - (timedelta(minutes=id_) if active else timedelta(days=1 + id_ % 89))
                completed = created + timedelta(hours=1) if status == "closed" else None
                closed = (completed + timedelta(minutes=10) if completed else created + timedelta(minutes=30)) if not active else None
                completion = {"work_done": "Synthetic completed repair for a polling baseline",
                              "fault_code_id": 1, "materials": [], "comment": "Synthetic SQL fixture"} if completed else None
                order = Order(
                    id=id_, version=1, number=f"SYN-POLL-{id_:05}",
                    title=f"{args.run_marker}-{'overview' if id_ == 1 else 'detail'}" if id_ <= 2 else f"Synthetic polling repair {id_}",
                    description=descriptions.get(id_, "Synthetic SQL polling workload"),
                    work_type="planned", area_id=1, equipment_id=1,
                    assignee_id=6, brigade_id=None, master_id=1,
                    priority="emergency" if id_ == 1 else "normal", status=status,
                    deadline=now + timedelta(hours=2) if active else created + timedelta(hours=3),
                    created_at=created, assigned_at=created,
                    started_at=created + timedelta(minutes=5) if completed else None,
                    completed_at=completed, closed_at=closed, normal_hours=1.5,
                    score=4.0 if completed else None, completion=completion,
                    comment="Synthetic polling measurement fixture", downtime_minutes=0,
                )
                db.add(order)
                db.flush()
                assignment = append_assignment(db, order, master.id, [worker])
                assignment.ended_at = closed
                db.add(OrderEvent(order_id=id_, action="issue" if id_ <= 2 else "fixture_seed",
                                  from_status=None, to_status=status, actor_id=1, created_at=created,
                                  comment="Synthetic SQL state for polling measurement"))
            db.flush()
            distribution = dict(db.execute(select(Order.status, func.count()).group_by(Order.status)).all())
            require(distribution == STATUS_DISTRIBUTION, "fixture_distribution_mismatch")
            require(db.scalar(select(func.count()).select_from(Order)) == 500, "fixture_count_mismatch")
        manifest = {
            "schema": 1, "kind": KIND, "fresh": True, "run_marker": args.run_marker,
            "api_url": api_url, "result_file": str(result_path),
            "master": {"id": 1, "login": "master", "pin": "1234"},
            "area_id": 1, "equipment_id": 1,
            "equipment_fixture_marker": f"SYN-POLL-{args.run_marker}",
            "order_title_marker": args.run_marker,
            "order_count": 500, "status_distribution": distribution,
            "reference_counts": REFERENCE_COUNTS, "worker_count": 1,
            "dataset_kind": "synthetic_sql_states_with_singleton_assignments",
            "overview_order_id": 1, "detail_order_id": 2,
            "overview_initial_version": 1, "detail_initial_version": 1,
            "overview_initial_description": descriptions[1],
            "detail_initial_description": descriptions[2],
            "overview_initial_deadline": (now + timedelta(hours=2)).isoformat(),
        }
        with manifest_path.open("x", encoding="utf-8") as output:
            json.dump(manifest, output, ensure_ascii=False, indent=2)
            output.write("\n")
    finally:
        engine.dispose()
    return {"status": "prepared", "run_marker": args.run_marker, "order_count": 500,
            "status_distribution": distribution, "manifest_file": str(manifest_path)}


def prepared_fixture(args):
    database, manifest_path, result_path = fixture_paths(args.database_url, args.run_marker)
    require(database.is_file() and database.stat().st_size > 0, "prepared_database_missing")
    manifest = read_json(manifest_path)
    require(manifest.get("schema") == 1 and manifest.get("kind") == KIND
            and manifest.get("fresh") is True and manifest.get("run_marker") == args.run_marker
            and manifest.get("order_count") == 500 and manifest.get("status_distribution") == STATUS_DISTRIBUTION
            and manifest.get("reference_counts") == REFERENCE_COUNTS
            and manifest.get("result_file") == str(result_path), "manifest_identity_mismatch")
    api_url = loopback_api(manifest.get("api_url", ""))
    # A read-only marker check also prevents serving a copied or mismatched DB.
    with sqlite3.connect(f"{database.as_uri()}?mode=ro", uri=True) as db:
        require(db.execute("SELECT COUNT(*) FROM orders").fetchone()[0] == 500, "fixture_count_mismatch")
        equipment = db.execute("SELECT inventory_number, area_id FROM equipment WHERE id=1").fetchone()
        require(equipment == (f"SYN-POLL-{args.run_marker}", 1), "equipment_marker_mismatch")
        targets = db.execute("SELECT id, title, status, master_id FROM orders WHERE id IN (1,2) ORDER BY id").fetchall()
        require(targets == [(1, f"{args.run_marker}-overview", "issued", 1),
                            (2, f"{args.run_marker}-detail", "issued", 1)], "target_marker_mismatch")
    return database, api_url


def serve(args):
    from urllib.parse import urlsplit

    database, api_url = prepared_fixture(args)
    api = urlsplit(api_url)
    database_url = str(URL.create("sqlite", database=str(database)))
    os.environ.update({"DATABASE_URL": database_url, "PUSH_ENABLED": "false",
                       "SEED_DEMO": "false", "AI_REVIEW_MODE": "queued_stub"})
    import uvicorn
    from app.main import create_app

    uvicorn.run(create_app(database_url=database_url, seed=False, monitor=False),
                host=api.hostname, port=api.port, access_log=False)
    return {"status": "server_stopped", "run_marker": args.run_marker}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subcommands = parser.add_subparsers(dest="command", required=True)
    for name in ("prepare", "serve"):
        subparser = subcommands.add_parser(name)
        subparser.add_argument("--database-url", required=True)
        subparser.add_argument("--run-marker", required=True)
        if name == "prepare":
            subparser.add_argument("--api-url", required=True)
    args = parser.parse_args()
    try:
        result = {"prepare": prepare, "serve": serve}[args.command](args)
    except FixtureError as error:
        print(json.dumps({"status": "failed", "code": str(error)}), file=sys.stderr)
        return 1
    except Exception as error:
        print(json.dumps({"status": "failed", "code": "fixture_internal_error",
                          "error_type": type(error).__name__}), file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
