"use client";

import { useRef, useState, type FormEvent } from "react";
import { ApiClient, errorMessage, type Course } from "@/lib/api";
import { Empty, ErrorBox, Icon, Loading, Modal } from "./ui";
import { useResource, type Resource } from "./use-resource";
import { PageHeading } from "./workspace";

export function Academy({ api, courses, onChanged, notify }: { api: ApiClient; courses: Resource<Course[]>; onChanged: () => void; notify: (message: string) => void }) {
  const [selected, setSelected] = useState<number | null>(null);
  return <><PageHeading eyebrow="JANA ACADEMY" title="Ваш следующий шаг" description="Знания, которые помогают чувствовать себя увереннее каждый день." /><div className="academy-banner"><span className="metric-icon mint"><Icon name="book" size={27} /></span><div><h2>Растём вместе</h2><p>Изучите материал и пройдите тест, чтобы завершить назначенный курс.</p></div><span className="academy-total">{courses.data ? `${courses.data.filter((course) => course.completed).length} / ${courses.data.length}` : "—"}<small>курсов завершено</small></span></div>{courses.error ? <ErrorBox message={courses.error} retry={courses.reload} /> : courses.loading && !courses.data ? <Loading /> : !courses.data?.length ? <section className="panel"><Empty icon="book" title="Ваше обучение ещё впереди" text="Когда вам назначат курс, он появится здесь." /></section> : <div className="courses-grid">{courses.data.map((course, index) => <article className="panel course-card" key={course.id}><div className={`course-card-cover cover-${index % 3}`}><span className="small-label">JANA ACADEMY</span><Icon name={index % 2 ? "shield" : "leaf"} size={64} /><span className="course-cover-arrow">↗</span>{course.completed && <span className="course-completed"><Icon name="check" size={14} /> Пройден</span>}</div><div className="course-card-body"><span className="course-meta"><Icon name="clock" size={14} />{course.duration_minutes} мин.<span>·</span>Назначенный курс</span><h2>{course.title}</h2><p>{course.description}</p><div className="progress-label"><span>Прогресс</span><strong>{course.progress}%</strong></div><progress value={course.progress} max={100} aria-label={`Прогресс: ${course.title}`} /><button className="button button-secondary" onClick={() => setSelected(course.id)}>{course.completed ? "Повторить материал" : course.progress ? "Продолжить" : "Начать обучение"}<Icon name="arrow" size={17} /></button></div></article>)}</div>}{selected !== null && <CourseReader key={selected} id={selected} api={api} onClose={() => setSelected(null)} onChanged={onChanged} notify={notify} />}</>;
}

function CourseReader({ id, api, onClose, onChanged, notify }: { id: number; api: ApiClient; onClose: () => void; onChanged: () => void; notify: (message: string) => void }) {
  const resource = useResource<Course>(api, `/courses/${id}`);
  const [answer, setAnswer] = useState<number | null>(null);
  const [error, setError] = useState("");
  const [pending, setPending] = useState(false);
  const [materialRead, setMaterialRead] = useState(false);
  const busy = useRef(false);
  const course = resource.data;
  async function saveProgress() {
    if (!course || busy.current) return;
    busy.current = true; setPending(true); setError("");
    try { await api.post<Course>(`/courses/${id}/progress`, { progress: Math.max(course.progress, 70) }); setMaterialRead(true); resource.reload(); onChanged(); }
    catch (cause) { setError(errorMessage(cause)); }
    finally { busy.current = false; setPending(false); }
  }
  async function complete(event: FormEvent) {
    event.preventDefault();
    if (answer === null || busy.current) return;
    busy.current = true; setPending(true); setError("");
    try { await api.post<Course>(`/courses/${id}/complete`, { answer_index: answer }); resource.reload(); onChanged(); notify("Курс завершён. Отличная работа!"); }
    catch (cause) { setError(errorMessage(cause)); }
    finally { busy.current = false; setPending(false); }
  }
  return <Modal title="Jana Academy · Обучение" wide onClose={() => { if (!pending) onClose(); }}>
    {resource.error ? <ErrorBox message={resource.error} retry={resource.reload} /> : resource.loading && !course ? <Loading /> : course && <>
      <div className="course-reader-heading"><span className="course-meta"><Icon name="clock" size={15} />{course.duration_minutes} мин.</span><h2>{course.title}</h2><p>{course.description}</p><div className="progress-label"><span>Ваш прогресс</span><strong>{course.progress}%</strong></div><progress value={course.progress} max={100} aria-label="Прогресс курса" /></div>
      <article className="course-content"><span className="small-label">МАТЕРИАЛ КУРСА</span><div>{course.content}</div></article>
      {error && <ErrorBox message={error} />}
      {course.completed ? <div className="course-success"><Icon name="check" size={26} /><div><h3>Курс завершён</h3><p>Тест пройден, прогресс сохранён на сервере.</p></div></div> : <>
        {!materialRead && course.progress < 70 && <button className="button button-primary material-read" onClick={saveProgress} disabled={pending || resource.loading}>{pending ? "Сохраняем…" : "Материал изучен — перейти к тесту"}<Icon name="arrow" size={17} /></button>}
        {(materialRead || course.progress >= 70) && <form className="course-test" onSubmit={complete}><span className="small-label">ПРОВЕРИМ ЗНАНИЯ</span><fieldset disabled={pending || resource.loading}><legend>{course.question}</legend>{course.options.map((option, index) => <label className={`answer-option ${answer === index ? "answer-selected" : ""}`} key={index}><input type="radio" name="course-answer" checked={answer === index} onChange={() => setAnswer(index)} required /><span>{option}</span></label>)}</fieldset><button className="button button-primary" disabled={pending || resource.loading || answer === null}>{pending ? "Проверяем…" : "Отправить ответ"}<Icon name="check" size={17} /></button></form>}
      </>}
    </>}
  </Modal>;
}
