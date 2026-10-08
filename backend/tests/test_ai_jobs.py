"""Queued review durability, authorization and lease fencing on real databases."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
from threading import Barrier, Event, current_thread

import pytest
import sqlalchemy as sa

import app.ai_jobs as jobs
import app.main as main_module
import test_order_history as history_tests
from app.main import create_app
from app.models import AIAssessment, AIReviewJob, ClientCommand, MaterialWriteoff, Order, OrderEvent, Photo, SubmissionAttempt, utcnow
from test_order_history import MASTER, WORKER, act, complete, history_client as sqlite_client_fixture, new_order, start
from test_postgresql import parallel_requests, pg_client as pg_client_fixture


@pytest.fixture
def job_client(request, tmp_path, monkeypatch):
    monkeypatch.setenv("AI_REVIEW_MODE", "queued_stub")
    if getattr(request, "param", None) == "background":
        def background_app(*args, **kwargs):
            return create_app(*args, **{**kwargs, "monitor": True})
        monkeypatch.setattr(history_tests, "create_app", background_app)
    if getattr(request, "param", None) == "postgresql":
        yield from pg_client_fixture.__wrapped__(request.getfixturevalue("pg_database"), monkeypatch)
    else:
        yield from sqlite_client_fixture.__wrapped__(tmp_path, monkeypatch)


def submitted(client):
    id_ = new_order(client)
    start(client, id_)
    response, report = complete(client, id_)
    assert response["status"] == "completed" and response["ai_review"] is None
    attempt = response["submission_attempts"][-1]
    assert attempt["ai_review"] is None and attempt["assessment_id"] is None
    assert response["ai_review_job"]["status"] == "pending"
    return id_, attempt["id"], response, report


def gateway(id_, attempt):
    return f"/api/orders/{id_}/submissions/{attempt}/ai-review"


def due_now(client):
    with client.app.state.sessions() as db:
        for job in db.scalars(sa.select(AIReviewJob)):
            job.next_attempt_at = utcnow() - timedelta(seconds=1)
        db.commit()


def test_default_queued_and_unknown_mode_refused_before_database_creation(tmp_path, monkeypatch):
    monkeypatch.delenv("AI_REVIEW_MODE", raising=False)
    app = create_app(f"sqlite:///{tmp_path / 'default.db'}", seed=False, monitor=False)
    assert app.state.ai_review_mode == "queued_stub"
    app.state.engine.dispose()
    monkeypatch.setenv("AI_REVIEW_MODE", "external-provider-typo")
    with pytest.raises(ValueError, match="AI_REVIEW_MODE"):
        create_app(f"sqlite:///{tmp_path / 'invalid.db'}", seed=False, monitor=False)
    assert not (tmp_path / "invalid.db").exists()


def test_queued_snapshot_commit_replay_and_gateway_access(job_client):
    client = job_client
    id_, attempt_id, cached, report = submitted(client)
    path = gateway(id_, attempt_id)
    assert client.get(path).status_code == 401
    assert client.get(path, headers={"Authorization": "Bearer history-other-worker"}).status_code == 403
    other = new_order(client)
    assert client.get(gateway(other, attempt_id), headers=MASTER).status_code == 404
    assert client.post(path + "/retry", headers=WORKER).status_code == 403
    assert client.post(path + "/retry", headers=MASTER).status_code == 409
    class InspectProvider:
        def review(self, snapshot):
            assert snapshot["report"]["work_done"] == report["work_done"]
            assert snapshot["photos"] == []
            # A second connection can commit while the provider runs. Newly
            # available order photos are outside this attempt's frozen input.
            with client.app.state.sessions() as db:
                db.get(Order, id_).comment = "changed during provider"
                db.add(Photo(order_id=id_, kind="after", author_id=6, data=b"synthetic-later-photo"))
                db.commit()
            return jobs.FormalStub().review(snapshot)
    notified = []
    def published(order_id):
        with client.app.state.sessions() as db:
            assert db.get(Order, order_id).status == "ai_review"
            assert db.scalar(sa.select(AIReviewJob.status)) == "succeeded"
        notified.append(order_id)
    assert jobs.dispatch_ai_jobs(client.app.state.sessions, provider=InspectProvider(), publish=published) == [id_]
    assert notified == [id_]
    assert client.app.state.run_ai_jobs() == []
    result = client.get(path, headers=WORKER).json()
    assert result["job"]["status"] == "succeeded" and result["ai_review"]["is_stub"] is True
    assert "lease_token" not in result["job"]
    replay = client.post(f"/api/orders/{id_}/complete", headers={**WORKER, "X-Client-Command-Id": "history-complete-001"}, json=report)
    assert replay.status_code == 200 and replay.json() == cached
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(AIReviewJob)) == 1
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 1
        assert db.scalar(sa.select(sa.func.count()).select_from(MaterialWriteoff)) == 1


@pytest.mark.parametrize("job_client", ["background"], indirect=True)
def test_background_worker_lifecycle_completes_and_publishes_after_commit(job_client, monkeypatch):
    finished = Event()
    publish = job_client.app.state.realtime.publish
    async def observe(type_, order_id=None):
        await publish(type_, order_id)
        if type_ == "orders.updated" and order_id:
            with job_client.app.state.sessions() as db:
                if db.get(Order, order_id).status == "ai_review":
                    finished.set()
    monkeypatch.setattr(job_client.app.state.realtime, "publish", observe)
    id_, attempt, _, _ = submitted(job_client)
    assert finished.wait(timeout=5), "monitor=True must dispatch without a manual drain"
    assert job_client.get(gateway(id_, attempt), headers=MASTER).json()["job"]["status"] == "succeeded"


def test_completion_job_failure_rolls_back_report_history_and_expenses(job_client, monkeypatch):
    id_ = new_order(job_client)
    start(job_client, id_)
    def broken_enqueue(db, attempt, provider="stub"):
        jobs.enqueue_job(db, attempt, provider)
        raise RuntimeError("synthetic transaction failure")
    monkeypatch.setattr(main_module, "enqueue_job", broken_enqueue)
    with pytest.raises(RuntimeError, match="synthetic transaction failure"):
        complete(job_client, id_)
    with job_client.app.state.sessions() as db:
        assert db.get(Order, id_).status == "in_progress"
        for model in [SubmissionAttempt, AIReviewJob, MaterialWriteoff]:
            assert db.scalar(sa.select(sa.func.count()).select_from(model)) == 0
        assert db.scalar(sa.select(sa.func.count()).select_from(ClientCommand).where(ClientCommand.kind == "complete")) == 0


@pytest.mark.parametrize("patch", [{"score": float("nan")}, {"score": 9.0}, {"is_stub": False}, {"verdict": "invented"}])
def test_invalid_provider_result_never_creates_assessment(job_client, patch):
    _, _, _, _ = submitted(job_client)
    class InvalidProvider:
        def review(self, snapshot):
            return {**jobs.FormalStub().review(snapshot), **patch}
    job_client.app.state.run_ai_jobs(provider=InvalidProvider())
    with job_client.app.state.sessions() as db:
        job = db.scalar(sa.select(AIReviewJob))
        assert job.status == "pending" and job.last_error_code == "invalid_result"
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 0
        assert db.scalar(sa.select(SubmissionAttempt.ai_review)) is None


def test_failure_cap_sanitized_errors_and_manual_retry_exact_replay(job_client):
    client = job_client
    id_, attempt, _, _ = submitted(client)
    class BrokenProvider:
        def review(self, snapshot):
            raise RuntimeError("RAW_SECRET_AND_SUBMITTED_REPORT_MUST_NOT_PERSIST")
    for _ in range(3):
        due_now(client)
        client.app.state.run_ai_jobs(provider=BrokenProvider())
    path = gateway(id_, attempt)
    failed = client.get(path, headers=MASTER).json()["job"]
    assert failed["status"] == "failed" and failed["attempts"] == 3
    assert failed["last_error_code"] == "provider_error" and failed["retry_allowed"] is True
    assert client.get(path, headers=WORKER).json()["job"]["retry_allowed"] is False
    headers = {**MASTER, "X-Client-Command-Id": "ai-manual-retry-001"}
    first = client.post(path + "/retry", headers=headers)
    repeated = client.post(path + "/retry", headers=headers)
    assert first.status_code == repeated.status_code == 200
    assert first.json() == repeated.json()
    assert first.json()["job"]["id"] == failed["id"] and first.json()["job"]["attempts"] == 0
    assert client.post(path + "/retry", headers=MASTER).status_code == 409
    client.app.state.run_ai_jobs()
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 1
        assert db.scalar(sa.select(sa.func.count()).select_from(OrderEvent).where(OrderEvent.action == "ai_review_retry")) == 1


@pytest.mark.parametrize("job_client", ["sqlite", "postgresql"], indirect=True)
def test_expired_lease_restart_fences_old_worker_and_applies_once(job_client):
    client = job_client
    id_, _, _, _ = submitted(client)
    old = jobs.claim_job(client.app.state.sessions)
    with client.app.state.sessions() as db:
        db.get(AIReviewJob, old["job_id"]).lease_expires_at = utcnow() - timedelta(seconds=1)
        db.commit()
    # A new worker/session recovers the persisted lease after a restart.
    fresh = jobs.claim_job(client.app.state.sessions)
    assert fresh["token"] != old["token"]
    result = jobs.FormalStub().review(fresh["snapshot"])
    assert jobs.finish_job(client.app.state.sessions, old, result) is False
    assert jobs.finish_job(client.app.state.sessions, fresh, result) is True
    assert jobs.finish_job(client.app.state.sessions, fresh, result) is False
    with client.app.state.sessions() as db:
        assert db.get(Order, id_).status == "ai_review"
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 1


def test_cancelled_order_supersedes_result_without_effects(job_client):
    client = job_client
    id_, attempt, _, _ = submitted(client)
    claim = jobs.claim_job(client.app.state.sessions)
    act(client, id_, "cancel", headers=MASTER, reason="Cancelled before AI result")
    assert jobs.finish_job(client.app.state.sessions, claim, jobs.FormalStub().review(claim["snapshot"])) is True
    assert client.get(gateway(id_, attempt), headers=MASTER).json()["job"]["status"] == "superseded"
    with client.app.state.sessions() as db:
        assert db.get(Order, id_).status == "cancelled"
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 0


@pytest.mark.parametrize("job_client", ["sqlite", "postgresql"], indirect=True)
def test_two_workers_and_two_manual_retries_have_one_effect(job_client):
    client = job_client
    id_, attempt, _, _ = submitted(client)
    barrier = Barrier(2)
    def drain():
        barrier.wait(timeout=5)
        return client.app.state.run_ai_jobs()
    with ThreadPoolExecutor(max_workers=2) as pool:
        results = list(pool.map(lambda _: drain(), range(2)))
    assert sum(len(result) for result in results) == 1
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 1
    id_ = new_order(client)
    start(client, id_)
    response, _ = complete(client, id_, key="retry-concurrency-complete-002")
    attempt = response["submission_attempts"][-1]["id"]
    class BrokenProvider:
        def review(self, snapshot):
            raise RuntimeError("synthetic provider failure")
    for _ in range(3):
        due_now(client)
        client.app.state.run_ai_jobs(provider=BrokenProvider())
    request = ("POST", gateway(id_, attempt) + "/retry", None, MASTER)
    responses = parallel_requests(client, request, request)
    assert sorted(r.status_code for r in responses) == [200, 409]
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(OrderEvent).where(OrderEvent.action == "ai_review_retry")) == 1


def test_sqlite_finish_holds_write_lock_before_fence_reads(job_client, monkeypatch):
    client = job_client
    submitted(client)
    claim = jobs.claim_job(client.app.state.sessions)
    fence_read = Event()
    allow_finish = Event()
    reclaim_started = Event()
    reclaim_acquired = Event()
    clock = [utcnow()]
    monkeypatch.setattr(jobs, "utcnow", lambda: clock[0])
    def before(connection, cursor, statement, parameters, context, many):
        if current_thread().name.startswith("reclaim") and statement == "BEGIN IMMEDIATE":
            reclaim_started.set()
        if current_thread().name.startswith("finish") and statement.startswith("SELECT submission_attempts.id") and "ORDER BY submission_attempts.sequence DESC" in statement:
            fence_read.set()
            assert allow_finish.wait(timeout=5)
    def after(connection, cursor, statement, parameters, context, many):
        if current_thread().name.startswith("reclaim") and statement == "BEGIN IMMEDIATE":
            reclaim_acquired.set()
    engine = client.app.state.engine
    sa.event.listen(engine, "before_cursor_execute", before)
    sa.event.listen(engine, "after_cursor_execute", after)
    try:
        with ThreadPoolExecutor(max_workers=1, thread_name_prefix="finish") as finisher, ThreadPoolExecutor(max_workers=1, thread_name_prefix="reclaim") as reclaimer:
            finish = finisher.submit(jobs.finish_job, client.app.state.sessions, claim, jobs.FormalStub().review(claim["snapshot"]))
            assert fence_read.wait(timeout=5)
            clock[0] += timedelta(seconds=60)
            reclaim = reclaimer.submit(jobs.claim_job, client.app.state.sessions)
            assert reclaim_started.wait(timeout=5)
            try:
                assert not reclaim_acquired.wait(timeout=0.1)
            finally:
                allow_finish.set()
            assert finish.result(timeout=5) is True
            assert reclaim.result(timeout=5) is None
    finally:
        allow_finish.set()
        sa.event.remove(engine, "before_cursor_execute", before)
        sa.event.remove(engine, "after_cursor_execute", after)
    with client.app.state.sessions() as db:
        assert db.scalar(sa.select(sa.func.count()).select_from(AIAssessment)) == 1
