"use client";

import { useRef, useState, type FormEvent } from "react";
import { ApiClient, errorMessage, type AssistantAnswer, type Knowledge } from "@/lib/api";
import { ErrorBox, Icon, Loading, Modal } from "./ui";
import { useResource } from "./use-resource";
import { PageHeading } from "./workspace";

const suggestions = ["Как подать заявку на отпуск?", "Как пройти обучение?", "Как работает HR-помощник?"];
interface Exchange { question: string; result: AssistantAnswer }

export function Assistant({ api }: { api: ApiClient }) {
  const [question, setQuestion] = useState("");
  const [exchanges, setExchanges] = useState<Exchange[]>([]);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [sourceId, setSourceId] = useState<number | null>(null);
  const busy = useRef(false);
  const end = useRef<HTMLDivElement>(null);
  async function ask(value: string) {
    if (busy.current || value.trim().length < 3) return;
    busy.current = true; setPending(true); setError("");
    try { const result = await api.post<AssistantAnswer>("/assistant/query", { question: value.trim() }); setExchanges((old) => [...old, { question: value.trim(), result }]); setQuestion(""); requestAnimationFrame(() => end.current?.scrollIntoView({ behavior: "smooth", block: "nearest" })); }
    catch (cause) { setQuestion(value); setError(errorMessage(cause)); }
    finally { busy.current = false; setPending(false); }
  }
  function submit(event: FormEvent) { event.preventDefault(); void ask(question); }
  return <><PageHeading eyebrow="HR-ПОМОЩНИК" title="Давайте найдём ответ" description="Вопросы о прототипе, заявках и обучении — в одном диалоге." /><section className="panel assistant-panel"><div className="assistant-panel-header"><span className="assistant-mark"><Icon name="spark" size={23} /></span><div><strong>Jana · HR-помощник</strong><span><span className="live-dot" /> Демонстрационная база знаний</span></div><span className="tag">Поиск по документам</span></div><div className="chat-body">{exchanges.length === 0 && <div className="assistant-welcome"><span className="assistant-welcome-icon"><Icon name="spark" size={38} /></span><h2>Чем помочь сегодня?</h2><p>Задайте вопрос — я найду подходящие фрагменты<br />в базе знаний и укажу источник ответа.</p><div className="suggestions">{suggestions.map((suggestion) => <button key={suggestion} onClick={() => { setQuestion(suggestion); void ask(suggestion); }} disabled={pending}>{suggestion}<Icon name="arrow" size={16} /></button>)}</div></div>}{exchanges.map((exchange, index) => <div className="exchange" key={index}><div className="user-message"><span className="small-label">ВЫ</span><p>{exchange.question}</p></div><div className="assistant-message"><span className="assistant-message-icon"><Icon name="spark" size={20} /></span><div><span className="small-label">JANA · ОТВЕТ ИЗ БАЗЫ ЗНАНИЙ</span><p>{exchange.result.answer}</p>{exchange.result.sources.length > 0 && <div className="sources"><span className="small-label">ИСТОЧНИКИ</span>{exchange.result.sources.map((source, sourceIndex) => <button className="source-link" key={`${source.document_id}-${sourceIndex}`} onClick={() => setSourceId(source.document_id)}><span>{sourceIndex + 1}</span><div><strong>{source.title}</strong><small>{source.section}</small></div><Icon name="arrow" size={16} /></button>)}</div>}{exchange.result.escalate_to_hr && <div className="notice warning"><Icon name="people" size={18} /><span>По этому вопросу обратитесь к HR лично. Помощник не отправляет обращения автоматически.</span></div>}<small className="answer-mode">Ответ из фрагментов демонстрационной базы знаний</small></div></div></div>)}{pending && <Loading label="Ищем в базе знаний…" />}<div ref={end} /></div><div className="chat-composer">{error && <ErrorBox message={error} />}<form onSubmit={submit}><label className="sr-only" htmlFor="assistant-question">Ваш вопрос</label><textarea id="assistant-question" rows={2} placeholder="Например, как подать заявку на отпуск?" minLength={3} maxLength={1000} required value={question} onChange={(event) => setQuestion(event.target.value)} disabled={pending} /><button className="button button-primary" aria-label="Отправить вопрос" disabled={pending || question.trim().length < 3}><Icon name="send" size={20} /></button></form><div className="composer-footnote"><span>Демо-база описывает прототип, а не кадровые правила компании.</span><span>{question.length}/1000</span></div></div></section>{sourceId !== null && <KnowledgeReader key={sourceId} api={api} id={sourceId} onClose={() => setSourceId(null)} />}</>;
}

function KnowledgeReader({ api, id, onClose }: { api: ApiClient; id: number; onClose: () => void }) {
  const resource = useResource<Knowledge>(api, `/knowledge/${id}`);
  return <Modal title="Источник ответа" wide onClose={onClose}>{resource.error ? <ErrorBox message={resource.error} retry={resource.reload} /> : resource.loading ? <Loading /> : resource.data && <article className="knowledge-content"><span className="eyebrow">ДОКУМЕНТ №{resource.data.document_id}</span><h2>{resource.data.title}</h2><span className="tag">{resource.data.section}</span><div>{resource.data.content}</div><p className="muted small-text">Демонстрационный материал о работе прототипа.</p></article>}</Modal>;
}
