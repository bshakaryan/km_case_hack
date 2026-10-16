import json

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import Course, CourseAssignment, Employee
from app.modules.audit import record
from app.modules.notifications import notify
from app.schemas import Completion, CourseOut, Progress
from app.security import current_user

router = APIRouter(prefix="/courses", tags=["academy"])


def assigned(db: Session, employee_id: int, course_id: int):
    pair = db.execute(select(Course, CourseAssignment).join(CourseAssignment, CourseAssignment.course_id == Course.id).where(Course.id == course_id, CourseAssignment.employee_id == employee_id)).first()
    if pair is None:
        raise HTTPException(404, "Курс не назначен")
    return pair


def present(course: Course, assignment: CourseAssignment):
    return CourseOut(id=course.id, title=course.title, description=course.description, content=course.content, duration_minutes=course.duration_minutes, progress=assignment.progress, completed=assignment.completed, question=course.question, options=json.loads(course.options_json))


@router.get("", response_model=list[CourseOut])
def courses(user: Employee = Depends(current_user), db: Session = Depends(get_db)):
    pairs = db.execute(select(Course, CourseAssignment).join(CourseAssignment, CourseAssignment.course_id == Course.id).where(CourseAssignment.employee_id == user.id).order_by(Course.id)).all()
    return [present(c, a) for c, a in pairs]


@router.get("/{course_id}", response_model=CourseOut)
def course(course_id: int, user: Employee = Depends(current_user), db: Session = Depends(get_db)):
    return present(*assigned(db, user.id, course_id))


@router.post("/{course_id}/progress", response_model=CourseOut)
def progress(course_id: int, data: Progress, user: Employee = Depends(current_user), db: Session = Depends(get_db)):
    c, a = assigned(db, user.id, course_id)
    changed = db.execute(update(CourseAssignment).where(CourseAssignment.id == a.id, CourseAssignment.progress < data.progress).values(progress=data.progress).execution_options(synchronize_session=False))
    if changed.rowcount:
        record(db, user.id, "course.progressed", "course", course_id)
    db.commit()
    db.refresh(a)
    return present(c, a)


@router.post("/{course_id}/complete", response_model=CourseOut)
def complete(course_id: int, data: Completion, user: Employee = Depends(current_user), db: Session = Depends(get_db)):
    c, a = assigned(db, user.id, course_id)
    if data.answer_index != c.correct_index:
        raise HTTPException(422, "Ответ неверный. Прочитайте материал и попробуйте ещё раз")
    changed = db.execute(update(CourseAssignment).where(CourseAssignment.id == a.id, CourseAssignment.completed.is_(False)).values(progress=100, completed=True).execution_options(synchronize_session=False))
    if changed.rowcount:
        notify(db, user.id, "course_completed", "Курс завершён", f"Вы прошли «{c.title}».")
        record(db, user.id, "course.completed", "course", course_id)
    db.commit()
    db.refresh(a)
    return present(c, a)
