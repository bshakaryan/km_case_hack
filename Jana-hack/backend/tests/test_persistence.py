"""Migration reapplication and provisioning preserve populated databases.

This verifies SQLite only; it does not establish PostgreSQL migration/lock behavior.
"""
import os
import sqlite3
import subprocess
import sys
from pathlib import Path


def test_sequential_approval_migration_preserves_populated_0001_database(tmp_path):
    backend = Path(__file__).resolve().parents[1]
    database = tmp_path / "legacy.sqlite3"
    environment = os.environ.copy()
    environment["DATABASE_URL"] = f"sqlite:///{database}"
    environment["JWT_SECRET"] = "migration-test-secret-never-use-outside-pytest-2026"

    result = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "0001"], cwd=backend,
        env=environment, capture_output=True, text=True, timeout=30, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    with sqlite3.connect(database) as connection:
        connection.execute("INSERT INTO employees VALUES (1,'employee@example.com','hash','Employee','employee','Demo','Role','Team',2,'2024-01-01',10)")
        connection.execute("INSERT INTO employees VALUES (2,'manager@example.com','hash','Manager','manager','Demo','Manager','Team',NULL,'2020-01-01',10)")
        connection.execute("INSERT INTO leave_requests VALUES (10,1,'2027-01-01','2027-01-02','keep me','submitted',1,'2026-10-16T00:00:00Z','legacy-key','legacy-hash')")
        connection.execute("INSERT INTO request_history VALUES (10,10,1,'submitted','keep history','2026-10-16T00:00:00Z')")
        connection.execute("INSERT INTO leave_requests VALUES (12,1,'2026-10-01','2026-10-03','old approval','approved',3,'2026-10-16T00:00:00Z','old-approved','legacy-hash')")
        connection.commit()

    result = subprocess.run(
        [sys.executable, "-m", "alembic", "upgrade", "head"], cwd=backend,
        env=environment, capture_output=True, text=True, timeout=30, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT status, comment FROM leave_requests WHERE id=10").fetchone() == ("submitted", "keep me")
        assert connection.execute("SELECT status, comment FROM request_history WHERE id=10").fetchone() == ("submitted", "keep history")
        assert connection.execute("SELECT leave_balance FROM employees WHERE id=1").fetchone() == (10,)
        assert connection.execute("SELECT COUNT(*) FROM leave_deductions").fetchone() == (0,)
        assert connection.execute("SELECT status,days_count FROM leave_requests WHERE id=12").fetchone() == ("approved", 3)
        assert connection.execute("SELECT COUNT(*) FROM zup_deliveries").fetchone() == (0,)
        connection.execute("INSERT INTO leave_requests (id,employee_id,start_date,end_date,comment,status,version,created_at,idempotency_key,payload_hash,days_count,excluded_dates_json,calendar_version) VALUES (11,1,'2027-02-01','2027-02-02','new stage','manager_approved',2,'2026-10-16T00:00:00Z','new-stage-key','new-stage-hash',2,'[]','legacy-unquoted')")
        connection.execute("INSERT INTO leave_deductions (request_id,employee_id,actor_id,days,created_at) VALUES (10,1,2,2,'2026-10-16T00:00:00Z')")
        connection.commit()
        assert connection.execute("SELECT request_id, employee_id, actor_id, days FROM leave_deductions").fetchone() == (10, 1, 2, 2)


def test_seed_rerun_preserves_existing_data_password_and_course_progress(api, monkeypatch):
    from app.config import get_settings
    from app.models import Course, Employee, KnowledgeDocument
    from app.security import password_hash

    api.headers()
    api.headers("manager")
    item = api.leave()
    manager_approved = api.decide(item).json()
    assert manager_approved["status"] == "manager_approved"
    assert api.decide(manager_approved, "hr").status_code == 200
    assert api.post("/api/courses/1/progress", {"progress": 67}).status_code == 200
    with api.db.session() as db:
        employee = db.get(Employee, 1)
        employee.full_name = "Retained profile name"
        employee.leave_balance = 7
        employee.password_hash = password_hash.hash("changed-existing-password-2026")
        db.get(Course, 1).content = "Retained edited course material"
        db.get(KnowledgeDocument, 1).content = "Retained edited knowledge material"
        db.commit()
    before = api.db.snapshot()
    monkeypatch.setenv("DEMO_PASSWORD", "different-provisioning-password-2026")
    get_settings.cache_clear()
    api.db.seed()
    api.db.seed()
    assert api.db.snapshot() == before
    assert api.get("/api/me").json()["full_name"] == "Retained profile name"
    assert api.get("/api/courses/1").json()["progress"] == 67
    for password, status in (("changed-existing-password-2026", 200), (api.db.password, 401), ("different-provisioning-password-2026", 401)):
        response = api.client.post("/api/auth/login", json={"email": "employee@example.com", "password": password})
        assert response.status_code == status


def test_http_migration_preserves_existing_0003_deduction_without_reexport(tmp_path):
    backend = Path(__file__).resolve().parents[1]
    database = tmp_path / "ledger.sqlite3"
    environment = os.environ.copy()
    environment["DATABASE_URL"] = f"sqlite:///{database}"
    environment["JWT_SECRET"] = "ledger-migration-test-only-secret-2026"
    for revision in ("0003", "head"):
        result = subprocess.run([sys.executable, "-m", "alembic", "upgrade", revision], cwd=backend,
            env=environment, capture_output=True, text=True, timeout=30, check=False)
        assert result.returncode == 0, result.stdout + result.stderr
        if revision == "0003":
            with sqlite3.connect(database) as connection:
                connection.execute("INSERT INTO employees VALUES (1,'employee@example.com','hash','Retained','employee','Demo','Role','Team',NULL,'2024-01-01',18)")
                connection.execute("INSERT INTO leave_requests VALUES (10,1,'2027-01-01','2027-01-05','keep approval','approved',3,'2026-10-16T00:00:00Z','kept-key','kept-hash')")
                connection.execute("INSERT INTO leave_deductions VALUES (7,10,1,1,5,'2026-10-16T00:00:00Z')")
                connection.execute("INSERT INTO request_history VALUES (8,10,1,'approved','keep history','2026-10-16T00:00:00Z')")
    with sqlite3.connect(database) as connection:
        assert connection.execute("SELECT * FROM leave_deductions").fetchone() == (7, 10, 1, 1, 5, "2026-10-16T00:00:00Z")
        assert connection.execute("SELECT status,version,days_count,calendar_version FROM leave_requests").fetchone() == ("approved", 3, 5, "legacy-deducted")
        assert connection.execute("SELECT full_name,leave_balance,zup_id FROM employees").fetchone() == ("Retained", 18, "demo-1")
        assert connection.execute("SELECT comment FROM request_history").fetchone() == ("keep history",)
        assert connection.execute("SELECT COUNT(*) FROM zup_deliveries").fetchone() == (0,)


def test_seed_rerun_preserves_completed_course_and_does_not_notify_again(api):
    from app.models import Course

    with api.db.session() as db:
        right = db.get(Course, 1).correct_index
    assert api.post("/api/courses/1/complete", {"answer_index": right}).status_code == 200
    before = api.db.snapshot()
    api.db.seed()
    assert api.db.snapshot() == before
    assert api.get("/api/courses/1").json()["completed"] is True


def test_alembic_upgrade_preserves_populated_database_and_check_has_no_drift(api):
    from app.models import Course

    item = api.leave()
    manager_approved = api.decide(item).json()
    assert api.decide(manager_approved, "hr").status_code == 200
    with api.db.session() as db:
        right = db.get(Course, 1).correct_index
    assert api.post("/api/courses/1/complete", {"answer_index": right}).status_code == 200
    notification = api.get("/api/notifications").json()[0]
    assert api.patch(f"/api/notifications/{notification['id']}/read").status_code == 200
    before = api.db.snapshot()
    backend = Path(__file__).resolve().parents[1]
    for arguments in (("upgrade", "head"), ("check",)):
        result = subprocess.run(
            [sys.executable, "-m", "alembic", *arguments], cwd=backend,
            capture_output=True, text=True, timeout=30, check=False,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert api.db.snapshot() == before
    assert api.get(f"/api/requests/{item['id']}").json()["status"] == "approved"
    assert api.get("/api/courses/1").json()["completed"] is True
