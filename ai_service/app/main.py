import asyncio
import hmac
import logging
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Annotated

from fastapi import BackgroundTasks, Depends, FastAPI, File, Header, HTTPException, UploadFile
from fastapi.responses import JSONResponse, Response
from pydantic import BaseModel, Field

from .backend_source import BackendDataSource
from .analytics import AnalyticsService
from .assistant import MasterAssistant
from .config import Settings
from .datasource import DataSource, DataSourceError, IncompleteHistory
from .deadlines import DeadlineController
from .llm_client import LLMClient
from .intake import OpenAITranscriber, OrderIntake
from .notifier import LogNotifier, TelegramNotifier
from .photos import PhotoReviewService
from .rating import RatingService
from .reports import ReportService, export_pdf, export_xlsx
from .storage import AIStore
from .synthetic_source import SyntheticDataSource
from .verification import CompletionVerifier, source_version


LOG = logging.getLogger(__name__)


class TickRequest(BaseModel):
    now: datetime | None = None


class MasterOverrideRequest(BaseModel):
    source_version: str
    master_id: int
    verdict: str
    score: float = Field(ge=1, le=5)
    reason: str = Field(min_length=1)


class AssistantRequest(BaseModel):
    question: str = Field(min_length=1, max_length=1000)
    now: datetime | None = None


class IntakeRequest(BaseModel):
    phrase: str = Field(min_length=1, max_length=2000)
    now: datetime | None = None


def create_app(settings: Settings | None = None, source: DataSource | None = None, store: AIStore | None = None):
    settings = settings or Settings.from_env()
    store = store or AIStore(settings.ai_database_url, settings.ai_db_confirmed_separate)
    if source is None:
        if settings.data_source == "backend":
            source = BackendDataSource(settings.backend_url, settings.backend_token.get_secret_value())
        else:
            source = SyntheticDataSource(settings.synthetic_data_path)
    notifier = (TelegramNotifier(settings.telegram_bot_token.get_secret_value(), settings.telegram_chats)
                if settings.telegram_bot_token.get_secret_value() and settings.telegram_chats else LogNotifier())
    deadline_controller = DeadlineController(source, store, notifier, settings)
    llm_client = LLMClient(settings, store)
    verifier = CompletionVerifier(source, store, llm_client)
    photo_service = PhotoReviewService(source, store, llm_client, settings)
    analytics = AnalyticsService(source)
    assistant = MasterAssistant(source, llm_client)
    transcriber = (OpenAITranscriber(settings.openai_api_key.get_secret_value(), settings.stt_model)
                   if settings.data_source == "synthetic" and not settings.demo_mode and
                   settings.llm_provider == "openai" and settings.stt_model else None)
    intake = OrderIntake(source, llm_client, transcriber)
    reports = ReportService(source, store)
    rating = RatingService(source, settings, store)
    review_tasks = set()

    async def run_review_job(order_id: int, version: str):
        saved = store.get_result("review_job", str(order_id), version)
        attempts = saved["payload"].get("attempts", 0) if saved else 0
        if attempts >= 3:
            return
        store.update_result("review_job", str(order_id), version,
                            {"status": "running", "attempts": attempts + 1})
        try:
            await verifier.verify(order_id, expected_version=version)
            store.update_result("review_job", str(order_id), version,
                                {"status": "completed", "attempts": attempts + 1})
        except (LookupError, ValueError, DataSourceError) as error:
            status = "stale" if isinstance(error, ValueError) else "failed"
            store.update_result("review_job", str(order_id), version,
                                {"status": status, "attempts": attempts + 1, "error": type(error).__name__})
            LOG.warning("Review job %s/%s ended as %s", order_id, version, status)
        except Exception:
            store.update_result("review_job", str(order_id), version,
                                {"status": "failed", "attempts": attempts + 1, "error": "unexpected"})
            LOG.exception("Review job %s/%s failed", order_id, version)

    async def run_photo_job(order_id: int, version: str):
        saved = store.get_result("photo_review_job", str(order_id), version)
        attempts = saved["payload"].get("attempts", 0) if saved else 0
        if attempts >= 3:
            return
        store.update_result("photo_review_job", str(order_id), version,
                            {"status": "running", "attempts": attempts + 1})
        try:
            await photo_service.review(order_id, expected_version=version)
            store.update_result("photo_review_job", str(order_id), version,
                                {"status": "completed", "attempts": attempts + 1})
        except (LookupError, ValueError, DataSourceError) as error:
            status = "stale" if isinstance(error, ValueError) else "failed"
            store.update_result("photo_review_job", str(order_id), version,
                                {"status": status, "attempts": attempts + 1, "error": type(error).__name__})
            LOG.warning("Photo job %s/%s ended as %s", order_id, version, status)
        except Exception:
            store.update_result("photo_review_job", str(order_id), version,
                                {"status": "failed", "attempts": attempts + 1, "error": "unexpected"})
            LOG.exception("Photo job %s/%s failed", order_id, version)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        photo_service.equipment_matcher.require_ready()
        store.initialize()
        for job in store.list_results("review_job"):
            if job["payload"].get("status") in {"pending", "running", "failed"} and job["payload"].get("attempts", 0) < 3:
                task = asyncio.create_task(run_review_job(int(job["subject_id"]), job["source_version"]))
                review_tasks.add(task)
                task.add_done_callback(review_tasks.discard)
        for job in store.list_results("photo_review_job"):
            if job["payload"].get("status") in {"pending", "running", "failed"} and job["payload"].get("attempts", 0) < 3:
                task = asyncio.create_task(run_photo_job(int(job["subject_id"]), job["source_version"]))
                review_tasks.add(task)
                task.add_done_callback(review_tasks.discard)
        scheduler = None
        if settings.deadline_scheduler_enabled:
            from apscheduler.schedulers.asyncio import AsyncIOScheduler

            async def monitored_tick():
                await deadline_controller.tick(datetime.now(timezone.utc))

            scheduler = AsyncIOScheduler(timezone="UTC")
            scheduler.add_job(monitored_tick, "interval", seconds=settings.deadline_poll_seconds,
                              max_instances=1, coalesce=True)
            scheduler.start()
        yield
        if scheduler:
            scheduler.shutdown(wait=False)
        for task in review_tasks:
            task.cancel()
        if review_tasks:
            await asyncio.gather(*review_tasks, return_exceptions=True)
        store.close()

    app = FastAPI(title="НарядAI — отдельный ИИ-сервис", version="0.1.0", lifespan=lifespan)
    app.state.source = source
    app.state.store = store
    app.state.deadline_controller = deadline_controller
    app.state.verifier = verifier
    app.state.photo_service = photo_service
    app.state.analytics = analytics
    app.state.assistant = assistant
    app.state.intake = intake

    @app.exception_handler(IncompleteHistory)
    async def incomplete_history_handler(request, error):
        return JSONResponse(status_code=409, content={"detail": str(error)})

    @app.exception_handler(DataSourceError)
    async def datasource_handler(request, error):
        return JSONResponse(status_code=503, content={"detail": str(error)})

    @app.exception_handler(LookupError)
    async def missing_handler(request, error):
        return JSONResponse(status_code=404, content={"detail": str(error)})

    @app.exception_handler(ValueError)
    async def invalid_handler(request, error):
        return JSONResponse(status_code=422, content={"detail": str(error)})

    def require_token(authorization: Annotated[str | None, Header()] = None):
        expected = settings.ai_service_token.get_secret_value()
        if not expected:
            raise HTTPException(503, "AI_SERVICE_TOKEN не настроен")
        supplied = authorization.removeprefix("Bearer ") if authorization and authorization.startswith("Bearer ") else ""
        if not hmac.compare_digest(supplied, expected):
            raise HTTPException(401, "Неверный токен ИИ-сервиса")

    @app.get("/ai/health")
    def health():
        if photo_service.equipment_matcher.model_error:
            raise HTTPException(503, photo_service.equipment_matcher.model_error)
        store.ping()
        return {"status": "ok", "source": settings.data_source, "demo_mode": settings.demo_mode,
                "equipment_model": "ready"}

    @app.get("/ai/source/summary", dependencies=[Depends(require_token)])
    async def source_summary():
        try:
            snapshot = await source.snapshot()
        except IncompleteHistory as error:
            raise HTTPException(409, str(error)) from error
        except DataSourceError as error:
            raise HTTPException(503, str(error)) from error
        return {
            "source": settings.data_source,
            "orders": len(snapshot.orders),
            "employees": len(snapshot.employees),
            "equipment": len(snapshot.equipment),
            "areas": len(snapshot.areas),
        }

    @app.post("/ai/deadlines/tick", dependencies=[Depends(require_token)])
    async def deadlines_tick(request: TickRequest):
        return {"notifications": await deadline_controller.tick(request.now or datetime.now(timezone.utc))}

    @app.post("/ai/reviews/{order_id}", status_code=202, dependencies=[Depends(require_token)])
    async def review_order(order_id: int, background: BackgroundTasks):
        snapshot = await source.snapshot()
        order = next((item for item in snapshot.orders if item.id == order_id), None)
        if order is None:
            raise LookupError("Наряд не найден")
        if order.completion is None:
            raise HTTPException(409, "Наряд ещё не сдан")
        version = source_version(order)
        if store.get_result("review", str(order_id), version):
            return {"order_id": order_id, "source_version": version, "status": "completed"}
        store.put_result("review_job", str(order_id), version, {"status": "pending", "attempts": 0})
        background.add_task(run_review_job, order_id, version)
        return {"order_id": order_id, "source_version": version, "status": "scheduled"}

    @app.get("/ai/reviews/{order_id}", dependencies=[Depends(require_token)])
    async def get_review(order_id: int):
        snapshot = await source.snapshot()
        order = next((item for item in snapshot.orders if item.id == order_id), None)
        if order is None:
            raise LookupError("Наряд не найден")
        result = store.get_result("review", str(order_id), source_version(order))
        if result is None:
            job = store.get_result("review_job", str(order_id), source_version(order))
            if job:
                return JSONResponse(status_code=202, content={"order_id": order_id, **job["payload"]})
            raise HTTPException(404, "Проверка ещё не запущена")
        return result

    @app.post("/ai/reviews/{order_id}/master-override", dependencies=[Depends(require_token)])
    async def master_override(order_id: int, request: MasterOverrideRequest):
        snapshot = await source.snapshot()
        master = next((person for person in snapshot.employees if person.id == request.master_id), None)
        order = next((item for item in snapshot.orders if item.id == order_id), None)
        if master is None or master.role not in {"master", "admin"} or order is None:
            raise HTTPException(403, "Нужен мастер и существующий наряд")
        if request.verdict not in {"accepted", "accepted_with_remarks", "needs_rework", "needs_master_review"}:
            raise HTTPException(422, "Неизвестный вердикт")
        if source_version(order) != request.source_version:
            raise HTTPException(409, "Проверка относится к устаревшей сдаче")
        override = {"master_id": master.id, "verdict": request.verdict, "score": request.score,
                    "reason": request.reason, "at": datetime.now(timezone.utc).isoformat()}
        if not store.set_master_override("review", str(order_id), request.source_version, override):
            raise HTTPException(404, "Оценка ИИ не найдена")
        return {"order_id": order_id, "master_override": override}

    @app.post("/ai/photos/{order_id}/review", status_code=202, dependencies=[Depends(require_token)])
    async def review_photo(order_id: int, background: BackgroundTasks):
        snapshot = await source.snapshot()
        order = next((item for item in snapshot.orders if item.id == order_id), None)
        if order is None:
            raise LookupError("Наряд не найден")
        if order.completion is None:
            raise HTTPException(409, "Наряд ещё не сдан")
        version = source_version(order)
        if store.get_result("photo_review", str(order_id), version):
            return {"order_id": order_id, "source_version": version, "status": "completed"}
        store.put_result("photo_review_job", str(order_id), version, {"status": "pending", "attempts": 0})
        background.add_task(run_photo_job, order_id, version)
        return {"order_id": order_id, "source_version": version, "status": "scheduled"}

    @app.get("/ai/photos/{order_id}/review", dependencies=[Depends(require_token)])
    async def get_photo_review(order_id: int):
        snapshot = await source.snapshot()
        order = next((item for item in snapshot.orders if item.id == order_id), None)
        if order is None:
            raise LookupError("Наряд не найден")
        version = source_version(order)
        result = store.get_result("photo_review", str(order_id), version)
        if result:
            return result
        job = store.get_result("photo_review_job", str(order_id), version)
        if job:
            return JSONResponse(status_code=202, content={"order_id": order_id, **job["payload"]})
        raise HTTPException(404, "Фотоанализ ещё не запущен")

    @app.get("/ai/analytics", dependencies=[Depends(require_token)])
    async def analytics_report(start: datetime, end: datetime, area_id: int | None = None):
        return await analytics.analyze(start, end, area_id)

    @app.get("/ai/analytics/weekly", dependencies=[Depends(require_token)])
    async def weekly_analytics(end: datetime | None = None, area_id: int | None = None):
        end = end or datetime.now(timezone.utc)
        return await analytics.analyze(end - timedelta(days=7), end, area_id)

    @app.post("/ai/assistant/ask", dependencies=[Depends(require_token)])
    async def assistant_ask(request: AssistantRequest):
        return await assistant.ask(request.question, request.now or datetime.now(timezone.utc))

    @app.post("/ai/intake/text", dependencies=[Depends(require_token)])
    async def intake_text(request: IntakeRequest):
        return await intake.from_text(request.phrase, request.now or datetime.now(timezone.utc))

    @app.post("/ai/intake/voice", dependencies=[Depends(require_token)])
    async def intake_voice(file: UploadFile = File(...), now: datetime | None = None):
        if file.content_type not in {"audio/wav", "audio/x-wav", "audio/mpeg", "audio/mp4", "audio/webm"}:
            raise HTTPException(415, "Нужен WAV, MP3, MP4 или WebM")
        audio = await file.read(10_000_001)
        return await intake.from_voice(audio, file.filename or "recording.wav", now or datetime.now(timezone.utc))

    @app.get("/ai/reports/orders/{order_id}", dependencies=[Depends(require_token)])
    async def order_report(order_id: int, audience: str = "master", format: str = "json"):
        report = await reports.order_report(order_id, audience)
        if format == "pdf":
            return Response(export_pdf(report), media_type="application/pdf")
        if format == "xlsx":
            return Response(export_xlsx(report), media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        if format != "json":
            raise HTTPException(422, "Формат должен быть json, pdf или xlsx")
        return report

    @app.get("/ai/reports/shift", dependencies=[Depends(require_token)])
    async def shift_report(start: datetime, end: datetime, format: str = "json"):
        report = await reports.shift_report(start, end)
        if format == "pdf":
            return Response(export_pdf(report), media_type="application/pdf")
        if format == "xlsx":
            return Response(export_xlsx(report), media_type="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        if format != "json":
            raise HTTPException(422, "Формат должен быть json, pdf или xlsx")
        return report

    @app.get("/ai/ratings", dependencies=[Depends(require_token)])
    async def ratings(start: datetime, end: datetime):
        return await rating.calculate(start, end)

    return app


app = create_app()
