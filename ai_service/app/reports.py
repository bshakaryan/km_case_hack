"""Worker/master and shift reports with conservative downtime wording."""

import json
import textwrap
from datetime import datetime
from io import BytesIO
from pathlib import Path

from openpyxl import Workbook
from PIL import Image, ImageDraw, ImageFont

from .datasource import DataSource
from .deadlines import utc
from .schemas import OrderRecord, Snapshot
from .storage import AIStore
from .verification import source_version


def safe_cell(value):
    if isinstance(value, str) and value.startswith(("=", "+", "-", "@")):
        return "'" + value
    return value


def export_xlsx(report: dict):
    workbook = Workbook()
    sheet = workbook.active
    sheet.title = "Отчёт"
    for key, value in report.items():
        shown = json.dumps(value, ensure_ascii=False) if isinstance(value, (dict, list)) else value
        sheet.append([safe_cell(str(key)), safe_cell(shown)])
    sheet.column_dimensions["A"].width = 30
    sheet.column_dimensions["B"].width = 100
    output = BytesIO()
    workbook.save(output)
    return output.getvalue()


def export_pdf(report: dict):
    font_paths = [Path("C:/Windows/Fonts/arial.ttf"),
                  Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf")]
    font = next((ImageFont.truetype(str(path), 18) for path in font_paths if path.exists()),
                ImageFont.load_default())
    lines = [wrapped for line in json.dumps(report, ensure_ascii=False, indent=2, default=str).splitlines()
             for wrapped in textwrap.wrap(line, width=105, break_long_words=True,
                                          replace_whitespace=False) or [""]]
    pages = []
    for start in range(0, len(lines), 48):
        page = Image.new("RGB", (1240, 1754), "white")
        drawer = ImageDraw.Draw(page)
        drawer.text((50, 35), "НарядAI — отчёт", fill="black", font=font)
        for index, line in enumerate(lines[start:start + 48]):
            drawer.text((50, 85 + index * 33), line, fill="black", font=font)
        pages.append(page)
    output = BytesIO()
    pages[0].save(output, format="PDF", save_all=True, append_images=pages[1:])
    return output.getvalue()


class ReportService:
    def __init__(self, source: DataSource, store: AIStore):
        self.source = source
        self.store = store

    async def order_report(self, order_id: int, audience: str):
        snapshot = await self.source.snapshot()
        order = next((item for item in snapshot.orders if item.id == order_id), None)
        if order is None:
            raise LookupError("Наряд не найден")
        saved = self.store.get_result("review", str(order.id), source_version(order))
        saved_photo = self.store.get_result("photo_review", str(order.id), source_version(order))
        review = saved["payload"] if saved else None
        photo_review = saved_photo["payload"] if saved_photo else None
        override = saved["master_override"] if saved else None
        final_verdict = override.get("verdict") if override else review.get("verdict") if review else "unknown"
        final_score = override.get("score") if override else order.score
        if final_score is None and order.ai_review:
            final_score = order.ai_review.get("score")
        if final_score is None and review:
            final_score = review.get("suggested_score")
        actual_hours = None
        if order.started_at and order.completed_at:
            actual_hours = round((utc(order.completed_at) - utc(order.started_at)).total_seconds() / 3600, 2)
        timing = {"actual_hours": actual_hours,
                  "normal_hours": order.normal_hours if order.normal_hours and order.normal_hours > 0 else None,
                  "comparison": "unknown" if actual_hours is None or not order.normal_hours else
                  "over_norm" if actual_hours > order.normal_hours else "within_norm"}
        base = {"order_id": order.id, "number": order.number, "audience": audience,
                "score": final_score, "score_source": "master" if order.score is not None or override else
                "backend_ai" if order.ai_review and order.ai_review.get("score") is not None else
                "ai_rules" if review and review.get("suggested_score") is not None else "unknown",
                "timing": timing, "verdict_recommendation": review.get("verdict") if review else "unknown",
                "final_verdict": final_verdict, "master_override": override,
                "photo_review_status": photo_review.get("status") if photo_review else "unknown",
                "photo_score_recommendation": photo_review.get("score") if photo_review else None,
                "photo_needs_master_review": photo_review.get("needs_master_review") if photo_review else None,
                "final_decision_by_master": order.status == "closed" or bool(override)}
        if audience == "worker":
            base.update({"good": ["Работы описаны"] if order.completion and order.completion.work_done else [],
                         "improve": review.get("concerns", []) if review else [],
                         "explanation": review.get("explanation_worker") if review else "Проверка ИИ ещё не выполнялась."})
            return base
        if audience != "master":
            raise ValueError("Аудитория должна быть worker или master")
        equipment = next((item.name for item in snapshot.equipment if item.id == order.equipment_id), "unknown")
        area = next((item.name for item in snapshot.areas if item.id == order.area_id), "unknown")
        base.update({
            "equipment": equipment, "area": area, "problem": order.description or order.title,
            "status": order.status, "deadline": utc(order.deadline).isoformat(),
            "assignee_id": order.assignee_id, "master_id": order.master_id,
            "events": [event.model_dump(mode="json") for event in order.events],
            "completion": order.completion.model_dump(mode="json") if order.completion else None,
            "photos": [photo.model_dump(mode="json") for photo in order.photos],
            "review": review, "photo_review": photo_review,
            "reported_downtime_minutes": order.downtime_minutes,
            "actual_downtime_verified": False,
        })
        return base

    async def shift_report(self, start: datetime, end: datetime):
        start, end = utc(start), utc(end)
        if end <= start:
            raise ValueError("Конец смены должен быть позже начала")
        snapshot = await self.source.snapshot()
        issued = [order for order in snapshot.orders if start <= utc(order.created_at) < end]
        completed = [order for order in snapshot.orders if order.completed_at and start <= utc(order.completed_at) < end]
        overdue = [order for order in snapshot.orders if start <= utc(order.deadline) < end and
                   (not order.completed_at or utc(order.completed_at) > utc(order.deadline))]
        rejected = [order for order in snapshot.orders if any(
            event.action in {"reject", "rework"} and start <= utc(event.created_at) < end
            for event in order.events)]
        workload = {}
        for order in issued:
            worker = f"E-{order.assignee_id:02}"
            workload[worker] = workload.get(worker, 0) + 1
        downtime_values = [order.downtime_minutes for order in issued if order.downtime_minutes is not None]
        return {"from": start.isoformat(), "to": end.isoformat(), "issued": len(issued),
                "completed": len(completed), "overdue": len(overdue), "rejected_or_reworked": len(rejected),
                "workload_by_worker": workload,
                "reported_downtime_minutes": round(sum(downtime_values), 1) if downtime_values else None,
                "actual_downtime_verified": False,
                "summary": (f"Выдано {len(issued)}, выполнено {len(completed)}, "
                            f"просрочено {len(overdue)}, отклонено или возвращено {len(rejected)}. "
                            "Простой указан по карточкам, фактические интервалы не подтверждены.")}
