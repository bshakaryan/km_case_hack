import re

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.database import get_db
from app.models import Employee, KnowledgeDocument
from app.schemas import AssistantOut, Question, Source
from app.security import current_user

router = APIRouter(tags=["assistant"])


def allowed_documents(db: Session, user: Employee):
    # Filter BEFORE retrieval. Restricted text never enters the answer context.
    scopes = ["all", user.role]
    return db.scalars(select(KnowledgeDocument).where(KnowledgeDocument.access_scope.in_(scopes))).all()


def source(document: KnowledgeDocument):
    return Source(document_id=document.id, title=document.title, section=document.section, content=document.content)


@router.get("/knowledge/{document_id}", response_model=Source)
def knowledge(document_id: int, user: Employee = Depends(current_user), db: Session = Depends(get_db)):
    item = next((d for d in allowed_documents(db, user) if d.id == document_id), None)
    if item is None:
        raise HTTPException(404, "Источник не найден")
    return source(item)


@router.post("/assistant/query", response_model=AssistantOut)
def query(data: Question, user: Employee = Depends(current_user), db: Session = Depends(get_db)):
    question = data.question.lower().replace("ё", "е")
    refusal = AssistantOut(answer="В демонстрационной базе нет надёжного ответа на этот вопрос. Обратитесь в HR. Я не получаю персональные данные сотрудников и не принимаю кадровые решения.", sources=[], escalate_to_hr=True)
    # This first version is deliberately extractive, not an LLM or legal adviser.
    if re.search(r"игнориру|забудь|инструкци[ию].*систем|system prompt|ignore|зарплат|иин|паспорт|увол|закон|коллег|чуж|персональн.*данн|сколько|положен|начисл|остат|рассчит|пересчит|компенсац|больнич|аванс", question):
        return refusal
    tokens = re.findall(r"[а-яa-z0-9]+", question)
    matches = []
    for doc in allowed_documents(db, user):
        stems = [stem.strip() for stem in doc.keywords.split(",") if stem.strip()]
        score = sum(any(token.startswith(stem) for token in tokens) for stem in stems)
        exact = sum(stem in tokens for stem in stems)
        if score:
            matches.append((score, exact, doc.id, doc))
    if not matches:
        return refusal
    matches.sort(key=lambda match: (-match[0], -match[1], match[2]))
    document = matches[0][3]
    return AssistantOut(answer="Из демонстрационной базы знаний о работе прототипа:\n\n" + document.content, sources=[source(document)], escalate_to_hr=False)
