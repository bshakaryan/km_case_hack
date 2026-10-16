"use client";

import { useEffect, useRef, useState, type FormEvent } from "react";
import { ApiClient, ApiError, date, dateTime, errorMessage, initials, roleLabel, type Course, type LeaveCalculation, type LeaveRequest, type Notification, type Profile, type RequestDraft } from "@/lib/api";
import { Brand, Empty, ErrorBox, Icon, Loading, Modal, Status, type IconName } from "./ui";
import { useResource, type Resource } from "./use-resource";
import { Requests, RequestDetail } from "./requests";
import { Academy } from "./academy";
import { Assistant } from "./assistant";
import { Audit } from "./audit";
import { ZupIntegration } from "./zup-integration";
import { LeaveCalendar } from "./leave-calendar";

type Tab = "home" | "profile" | "requests" | "academy" | "assistant" | "notifications" | "team" | "audit";
const navigation: { tab: Tab; title: string; icon: IconName }[] = [
  { tab: "home", title: "Главная", icon: "home" }, { tab: "profile", title: "Мой профиль", icon: "user" },
  { tab: "requests", title: "Заявки", icon: "document" }, { tab: "academy", title: "Jana Academy", icon: "book" },
  { tab: "assistant", title: "HR-помощник", icon: "spark" }, { tab: "notifications", title: "Уведомления", icon: "bell" },
];
const blankDraft: RequestDraft = { start_date: "", end_date: "", comment: "" };

export function Workspace({ api, me: initialProfile, onLogout }: { api: ApiClient; me: Profile; onLogout: () => void }) {
  const profile = useResource<Profile>(api, "/me");
  const me = profile.data || initialProfile;
  const [tab, setTab] = useState<Tab>("home");
  const [menu, setMenu] = useState(false);
  const [create, setCreate] = useState(false);
  const [detailId, setDetailId] = useState<number | null>(null);
  const [draft, setDraft] = useState<RequestDraft>(blankDraft);
  const [creating, setCreating] = useState(false);
  const [createError, setCreateError] = useState("");
  const [uncertain, setUncertain] = useState(false);
  const [toast, setToast] = useState("");
  const attempt = useRef<{ key: string; body: RequestDraft } | null>(null);
  const busy = useRef(false);
  const requests = useResource<LeaveRequest[]>(api, "/requests");
  const courses = useResource<Course[]>(api, "/courses");
  const notifications = useResource<Notification[]>(api, "/notifications");
  const employees = useResource<Profile[]>(api, "/employees");
  const [calculation, setCalculation] = useState<LeaveCalculation | null>(null);
  const [calculationError, setCalculationError] = useState("");
  const [calculationRevision, setCalculationRevision] = useState(0);
  const currentCalculation = calculation?.start_date === draft.start_date && calculation.end_date === draft.end_date ? calculation : null;
  const sourceTitle = me.data_source === "zup" ? "1С:ЗУП" : "mock 1С:ЗУП";
  useEffect(() => {
    let active = true;
    setCalculation(null); setCalculationError("");
    if (!create || !draft.start_date || !draft.end_date || draft.end_date < draft.start_date) return;
    const timer = setTimeout(() => {
      api.post<LeaveCalculation>("/requests/calculate", { start_date: draft.start_date, end_date: draft.end_date })
        .then((value) => { if (active) setCalculation(value); })
        .catch((cause) => { if (active) setCalculationError(errorMessage(cause)); });
    }, 300);
    return () => { active = false; clearTimeout(timer); };
  }, [api, create, draft.start_date, draft.end_date, calculationRevision]);
  const unread = notifications.data?.filter((item) => !item.read).length;
  const pendingReviews = requests.data?.filter((item) => canReview(me, item, employees.data)).length;
  const nav = [...navigation, ...(me.role !== "employee" ? [{ tab: "team" as const, title: "Команда", icon: "people" as const }] : []), ...(me.role === "hr_admin" ? [{ tab: "audit" as const, title: "Журнал аудита", icon: "shield" as const }] : [])];
  const title = nav.find((item) => item.tab === tab)?.title;
  function navigate(value: Tab) { setTab(value); setMenu(false); window.scrollTo({ top: 0, behavior: "instant" }); }
  function changed() { requests.reload(); notifications.reload(); employees.reload(); profile.reload(); }
  useEffect(() => {
    const refresh = () => { profile.reload(); employees.reload(); requests.reload(); };
    window.addEventListener("focus", refresh);
    return () => window.removeEventListener("focus", refresh);
  }, [profile.reload, employees.reload, requests.reload]);
  useEffect(() => { if (!toast) return; const timer = setTimeout(() => setToast(""), 5500); return () => clearTimeout(timer); }, [toast]);

  async function submitRequest(event: FormEvent) {
    event.preventDefault();
    if (busy.current) return;
    if (!draft.start_date || !draft.end_date || draft.end_date < draft.start_date) { setCreateError("Дата окончания должна быть не раньше даты начала."); return; }
    if (!uncertain && (!currentCalculation || !currentCalculation.sufficient_balance)) { setCreateError("Дождитесь расчёта 1С:ЗУП и проверьте доступный остаток."); return; }
    busy.current = true; setCreating(true); setCreateError("");
    try {
      if (!attempt.current) attempt.current = { key: crypto.randomUUID(), body: { ...draft } };
      const result = await api.post<LeaveRequest>("/requests", attempt.current.body, { "Idempotency-Key": attempt.current.key });
      attempt.current = null; setUncertain(false); setDraft(blankDraft); setCreate(false);
      changed(); setToast(`Заявка №${result.id} отправлена на согласование`); setDetailId(result.id);
    } catch (cause) {
      const ambiguous = !(cause instanceof ApiError) || cause.status === 0 || cause.status >= 500;
      setUncertain(ambiguous);
      if (!ambiguous) { attempt.current = null; setCalculationRevision((value) => value + 1); }
      setCreateError(errorMessage(cause));
    } finally { busy.current = false; setCreating(false); }
  }

  return <div className="app-shell">
    <a href="#main-content" className="skip-link">Перейти к содержимому</a>
    {menu && <button className="sidebar-backdrop" onClick={() => setMenu(false)} aria-label="Закрыть меню" />}
    <aside className={`sidebar ${menu ? "sidebar-open" : ""}`} aria-label="Основная навигация"><Brand light /><button className="mobile-menu-close icon-button" onClick={() => setMenu(false)} aria-label="Закрыть меню"><Icon name="close" /></button><div className="workspace-label"><span className="live-dot" /> Пространство сотрудника</div><nav>{nav.map((item) => <button key={item.tab} onClick={() => navigate(item.tab)} className={`nav-item ${tab === item.tab ? "active" : ""}`} aria-current={tab === item.tab ? "page" : undefined}><Icon name={item.icon} /><span>{item.title}</span>{item.tab === "notifications" && !!unread && <span className="nav-count">{unread}</span>}{item.tab === "requests" && !!pendingReviews && <span className="nav-count">{pendingReviews}</span>}{item.tab === "assistant" && <span className="nav-ai">AI</span>}</button>)}</nav><div className="sidebar-bottom"><div className="sidebar-note"><Icon name="leaf" size={22} /><strong>На одной волне</strong><p>Всё важное для вашей<br />работы и развития.</p></div><div className="sidebar-account"><span className="avatar avatar-small">{initials(me.full_name)}</span><div><strong>{me.full_name}</strong><small>{roleLabel[me.role]}</small></div><button className="icon-button" aria-label="Выйти из аккаунта" onClick={onLogout}><Icon name="logout" size={18} /></button></div></div><span className="sidebar-version">JanaМен · Демо-пространство</span></aside>
    <div className="main-shell"><header className="topbar"><div className="breadcrumb"><button className="icon-button menu-button" onClick={() => setMenu(!menu)} aria-label="Открыть меню" aria-expanded={menu}><Icon name="menu" /></button><span>Моё пространство</span><Icon name="chevron" size={13} /><strong>{title}</strong></div><div className="topbar-actions"><span className="demo-indicator"><span /> Демо-режим</span><button className="icon-button notification-button" onClick={() => navigate("notifications")} aria-label={`Уведомления${unread ? `, непрочитанных: ${unread}` : ""}`}><Icon name="bell" />{!!unread && <i />}</button><button className="avatar avatar-small" onClick={() => navigate("profile")} aria-label="Открыть мой профиль">{initials(me.full_name)}</button></div></header>
    <main id="main-content" className="main-content" tabIndex={-1}>
      {profile.error && <ErrorBox message={`Не удалось обновить остаток: ${profile.error}`} retry={profile.reload} />}
      {tab === "home" && <Dashboard me={me} requests={requests} courses={courses} notifications={notifications} onCreate={() => setCreate(true)} onRequest={setDetailId} navigate={navigate} />}
      {tab === "profile" && <><PageHeading eyebrow="ЛИЧНОЕ" title="Мой профиль" description="Ваши кадровые данные — всегда под рукой." /><ProfileCard me={me} /></>}
      {tab === "requests" && <Requests me={me} employees={employees.data} resource={requests} onCreate={() => setCreate(true)} onOpen={setDetailId} />}
      {tab === "academy" && <Academy api={api} courses={courses} onChanged={() => { courses.reload(); notifications.reload(); }} notify={setToast} />}
      {tab === "assistant" && <Assistant api={api} />}
      {tab === "notifications" && <Notifications api={api} resource={notifications} />}
      {tab === "team" && <>{me.role === "hr_admin" && <ZupIntegration api={api} />}<Team resource={employees} me={me} /></>}
      {tab === "audit" && me.role === "hr_admin" && <Audit api={api} />}
      <footer className="page-footer"><span>JanaМен <span>·</span> Люди в центре всего</span><span>Демонстрационный прототип</span></footer>
    </main></div>
    <div className="toast-region" role="status" aria-live="polite">{toast && <div className="toast"><Icon name="check" /><span>{toast}</span><button className="icon-button" onClick={() => setToast("")} aria-label="Скрыть сообщение"><Icon name="close" size={16} /></button></div>}</div>
    {create && <Modal wide title="Заявка на отпуск" onClose={() => { if (!creating) setCreate(false); }}><p className="modal-description">Спланируйте время для себя. Сначала заявку согласует руководитель, затем финальное решение примет HR.</p><form onSubmit={submitRequest} className="stack-form"><div className="form-row"><label>Дата начала<input type="date" required value={draft.start_date} disabled={creating || uncertain || me.manager_id === null} onChange={(event) => setDraft({ ...draft, start_date: event.target.value })} /></label><label>Дата окончания<input type="date" required min={draft.start_date || undefined} value={draft.end_date} disabled={creating || uncertain || me.manager_id === null} onChange={(event) => setDraft({ ...draft, end_date: event.target.value })} /></label></div>{currentCalculation && <LeaveCalendar calculation={currentCalculation} />}<label>Комментарий <span className="optional">· необязательно</span><textarea rows={4} placeholder="Что нужно знать согласующему?" value={draft.comment} disabled={creating || uncertain || me.manager_id === null} onChange={(event) => setDraft({ ...draft, comment: event.target.value })} /></label><div className="notice"><Icon name="info" /><span>{currentCalculation ? <>По расчёту {sourceTitle}: <strong>{currentCalculation.days_count} дн.</strong> из {currentCalculation.calendar_days} календарных. Доступно <strong>{currentCalculation.available_balance} дн.</strong>{currentCalculation.sufficient_balance ? <> После одобрения останется <strong>{currentCalculation.balance_after} дн.</strong></> : " Недостаточно дней отпуска."}{currentCalculation.excluded_dates.length > 0 && <> Исключены праздники: {currentCalculation.excluded_dates.map((day) => date(day)).join(", ")}.</>}</> : draft.start_date && draft.end_date && !calculationError ? `Получаем расчёт из ${sourceTitle}…` : "Выберите период: календарные дни без праздничных дат. Выходные учитываются."}</span></div>{calculationError && <ErrorBox message={calculationError} retry={() => setCalculationRevision((value) => value + 1)} />}<p className="muted small-text">Дни списываются после финального одобрения HR. Ожидающие заявки не резервируют остаток.</p>{me.manager_id === null && <div className="notice warning"><Icon name="people" /><span>В профиле не назначен непосредственный руководитель. Обратитесь в HR для настройки маршрута согласования.</span></div>}{uncertain && <div className="notice warning"><Icon name="shield" /><span>Результат отправки не подтверждён. Повторим ту же заявку с сохранённым ключом: повтор не создаст вторую заявку. До подтверждения данные зафиксированы.</span></div>}{createError && <ErrorBox message={createError} />}<div className="form-actions"><button type="button" className="button button-secondary" disabled={creating} onClick={() => setCreate(false)}>Закрыть</button><button className="button button-primary" disabled={creating || me.manager_id === null || (!uncertain && (!currentCalculation || !currentCalculation.sufficient_balance))}>{creating ? <><span className="spinner" /> Отправляем…</> : <>{uncertain ? "Повторить отправку" : "Отправить заявку"}<Icon name="arrow" size={17} /></>}</button></div></form></Modal>}
    {detailId !== null && <RequestDetail key={detailId} id={detailId} api={api} me={me} employees={employees.data} onClose={() => setDetailId(null)} onChanged={changed} notify={setToast} />}
  </div>;
}

export function canReview(me: Profile, request: LeaveRequest, employees: Profile[] | null) {
  if (request.employee_id === me.id) return false;
  if (request.status === "manager_approved") return me.role === "hr_admin";
  return request.status === "submitted" && me.role === "manager" && employees?.some((employee) => employee.id === request.employee_id && employee.manager_id === me.id) === true;
}

export function PageHeading({ eyebrow, title, description, action }: { eyebrow: string; title: string; description: string; action?: React.ReactNode }) {
  return <div className="page-heading"><div><span className="eyebrow">{eyebrow}</span><h1>{title}</h1><p>{description}</p></div>{action}</div>;
}

function Dashboard({ me, requests, courses, notifications, onCreate, onRequest, navigate }: {
  me: Profile; requests: Resource<LeaveRequest[]>; courses: Resource<Course[]>; notifications: Resource<Notification[]>;
  onCreate: () => void; onRequest: (id: number) => void; navigate: (tab: Tab) => void;
}) {
  const own = requests.data?.filter((item) => item.employee_id === me.id);
  const completed = courses.data?.filter((item) => item.completed).length;
  const course = courses.data?.find((item) => !item.completed) || courses.data?.[0];
  const firstName = me.full_name.split(" ")[0];
  const today = new Intl.DateTimeFormat("ru-RU", { day: "numeric", month: "long", weekday: "long" }).format(new Date());
  return <><PageHeading eyebrow="МОЁ ПРОСТРАНСТВО" title={`Сәлем, ${firstName}!`} description="Хороший день, чтобы сделать следующий шаг." action={<span className="today"><Icon name="calendar" size={17} />{today}</span>} />
    <section className="welcome-banner"><div><span className="eyebrow">РАБОТА СТАНОВИТСЯ ПРОЩЕ</span><h2>Больше времени<br />на то, что важно.</h2><p>Заявки, обучение и ответы на вопросы.<br />Ваш HR — на расстоянии одного клика.</p><button className="button button-dark" onClick={onCreate}><Icon name="plus" size={18} /> Создать заявку</button></div><div className="welcome-art" aria-hidden="true"><span className="welcome-orbit orbit-a" /><span className="welcome-orbit orbit-b" /><span className="welcome-orbit orbit-c" /><div className="floating-card"><span className="floating-icon"><Icon name="leaf" size={28} /></span><span>Время для себя<strong>Новые силы. Новые идеи.</strong></span><span className="floating-check"><Icon name="check" size={16} /></span></div><span className="welcome-star">✳</span><span className="welcome-pill"><span className="live-dot" /> Баланс начинается с заботы</span></div></section>
    <section className="metrics-grid" aria-label="Обзор"><div className="metric-card"><div><span className="metric-label">Остаток отпуска</span><div className="metric-number">{me.leave_balance}<small>дней</small></div><span className="metric-hint">С учётом одобренных заявок</span></div><span className="metric-icon mint"><Icon name="leaf" size={22} /></span></div><button className="metric-card" onClick={() => navigate("requests")}><div><span className="metric-label">Мои заявки в работе</span><div className="metric-number">{own ? own.filter((item) => item.status === "submitted").length : "—"}<small>заявок</small></div><span className="metric-hint">Ожидают решения</span></div><span className="metric-icon peach"><Icon name="document" size={22} /></span></button><button className="metric-card" onClick={() => navigate("academy")}><div><span className="metric-label">Моё обучение</span><div className="metric-number">{completed ?? "—"}<small>/ {courses.data?.length ?? "—"} курсов</small></div><span className="metric-hint">Завершено в Jana Academy</span></div><span className="metric-icon lavender"><Icon name="book" size={22} /></span></button></section>
    <div className="dashboard-columns"><div className="dashboard-primary"><section className="panel"><div className="panel-heading"><h2>Мои заявки</h2><button className="text-button" onClick={() => navigate("requests")}>Все заявки <Icon name="arrow" size={16} /></button></div>{requests.error ? <ErrorBox message={requests.error} retry={requests.reload} /> : requests.loading && !requests.data ? <Loading /> : !own?.length ? <Empty title="Пока без заявок" text="Когда понадобится отпуск, начните здесь." action={<button className="text-button" onClick={onCreate}>Создать первую заявку <Icon name="plus" size={16} /></button>} /> : <div className="request-preview-list">{own.slice(0, 3).map((request) => <button className="request-preview" key={request.id} onClick={() => onRequest(request.id)}><span className="request-type-icon"><Icon name="calendar" /></span><span className="request-preview-main"><strong>Ежегодный отпуск <small>№{request.id}</small></strong><span>{date(request.start_date)} — {date(request.end_date)}</span></span><Status value={request.status} /><Icon name="chevron" size={16} /></button>)}</div>}</section>
      <section className="panel academy-preview"><div className="panel-heading"><div><span className="small-label">УЧИТЬСЯ. ПРИМЕНЯТЬ. РАСТИ.</span><h2>Jana Academy</h2></div><button className="text-button" onClick={() => navigate("academy")}>Мои курсы <Icon name="arrow" size={16} /></button></div>{courses.error ? <ErrorBox message={courses.error} retry={courses.reload} /> : courses.loading && !courses.data ? <Loading /> : course ? <div className="featured-course"><div className="course-cover" aria-hidden="true"><Icon name="book" size={50} /><span>JANA<br />ACADEMY</span><i>↗</i></div><div className="featured-course-copy"><span className="course-meta"><Icon name="clock" size={14} /> {course.duration_minutes} мин. <span>·</span> {course.completed ? "Завершён" : "Назначен вам"}</span><h3>{course.title}</h3><p>{course.description}</p><div className="progress-label"><span>Ваш прогресс</span><strong>{course.progress}%</strong></div><progress max={100} value={course.progress} aria-label="Прогресс курса" /><button className="text-button" onClick={() => navigate("academy")}>{course.completed ? "Открыть курс" : course.progress ? "Продолжить обучение" : "Начать обучение"}<Icon name="arrow" size={16} /></button></div></div> : <Empty icon="book" title="Новые знания впереди" text="Назначенные курсы появятся здесь." />}</section>
    </div><div className="dashboard-secondary"><section className="assistant-teaser"><span className="assistant-mark"><Icon name="spark" size={28} /></span><span className="small-label">ВАШ HR-ПОМОЩНИК</span><h2>Есть вопрос? <br />Давайте разберёмся.</h2><p>Найдём ответ в демонстрационной базе знаний и покажем источник.</p><button className="button button-secondary" onClick={() => navigate("assistant")}>Задать вопрос <Icon name="arrow" size={17} /></button><span className="teaser-footnote">Ответы на основе документов</span></section>
      <section className="panel updates-panel"><div className="panel-heading"><h2>На связи</h2><Icon name="bell" size={19} /></div>{notifications.error ? <ErrorBox message={notifications.error} retry={notifications.reload} /> : notifications.loading && !notifications.data ? <Loading /> : notifications.data?.length ? <>{notifications.data.slice(0, 2).map((item) => <button className={`update-preview ${item.read ? "" : "unread"}`} key={item.id} onClick={() => navigate("notifications")}><span className="update-dot" /><span><strong>{item.title}</strong><p>{item.body}</p><small>{dateTime(item.created_at)}</small></span></button>)}<button className="text-button" onClick={() => navigate("notifications")}>Все уведомления <Icon name="arrow" size={15} /></button></> : <div className="quiet-state"><Icon name="check" size={23} /><p>Пока всё спокойно.<br />Важные обновления будут здесь.</p></div>}</section></div></div>
  </>;
}

function ProfileCard({ me }: { me: Profile }) {
  const fields = [["Компания", me.company], ["Должность", me.position], ["Подразделение", me.department], ["Руководитель", me.manager_name || "Не назначен"], ["Рабочая почта", me.email], ["Дата приёма", date(me.hire_date, true)], ["Роль в системе", roleLabel[me.role]]];
  const source = me.data_source === "zup" ? "1С:ЗУП" : "mock 1С:ЗУП";
  return <section className="panel profile-panel"><div className="profile-cover"><span className="eyebrow">JANA · PEOPLE FIRST</span><span aria-hidden="true">↗</span></div><div className="profile-intro"><span className="avatar avatar-large">{initials(me.full_name)}</span><div><h2>{me.full_name}</h2><p>{me.position} · {me.department}</p></div><span className="tag">{me.data_source === "zup" ? "Профиль 1С" : "Демо-профиль"}</span></div><dl className="profile-fields">{fields.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{value}</dd></div>)}</dl><div className="profile-balance"><span className="metric-icon mint"><Icon name="leaf" size={24} /></span><div><strong>{me.leave_balance} дней отпуска</strong><p>Остаток из {source} с учётом заявок в передаче</p></div></div><div className="notice"><Icon name="info" /><span>Профиль подключён к {source} по HTTP. Расчёт учитывает календарь источника; кадровые данные доступны для просмотра.</span></div></section>;
}


function Notifications({ api, resource }: { api: ApiClient; resource: Resource<Notification[]> }) {
  const [pending, setPending] = useState<number | null>(null);
  const [error, setError] = useState("");
  const [filter, setFilter] = useState(false);
  const busy = useRef(false);
  const items = resource.data?.filter((item) => !filter || !item.read);
  async function read(id: number) {
    if (busy.current) return;
    busy.current = true; setPending(id); setError("");
    try { await api.patch<Notification>(`/notifications/${id}/read`, {}); resource.reload(); }
    catch (cause) { setError(errorMessage(cause)); }
    finally { busy.current = false; setPending(null); }
  }
  return <><PageHeading eyebrow="НА СВЯЗИ" title="Уведомления" description="Решения по заявкам и важные обновления обучения." /><div className="list-toolbar"><div className="segmented"><button className={!filter ? "selected" : ""} onClick={() => setFilter(false)}>Все</button><button className={filter ? "selected" : ""} onClick={() => setFilter(true)}>Непрочитанные</button></div><button className="text-button" onClick={resource.reload} disabled={resource.loading}><Icon name="refresh" size={16} /> Обновить</button></div>{error && <ErrorBox message={error} />}<section className="panel">{resource.error ? <ErrorBox message={resource.error} retry={resource.reload} /> : resource.loading && !resource.data ? <Loading /> : !items?.length ? <Empty icon="bell" title={filter ? "Всё прочитано" : "Пока нет уведомлений"} text="Обновления появятся после событий в вашем пространстве." /> : <div className="notification-list">{items.map((item) => <article className={`notification-card ${item.read ? "" : "is-unread"}`} key={item.id}><span className="metric-icon mint"><Icon name={item.kind.includes("course") ? "book" : "bell"} /></span><div><div className="notification-title"><h3>{item.title}</h3>{!item.read && <span className="tag">Новое</span>}</div><p>{item.body}</p><time dateTime={item.created_at}>{dateTime(item.created_at)}</time></div>{!item.read && <button className="button button-secondary button-small" disabled={pending !== null} onClick={() => read(item.id)}>{pending === item.id ? "Сохраняем…" : "Прочитано"}<Icon name="check" size={15} /></button>}</article>)}</div>}</section></>;
}

function Team({ resource, me }: { resource: Resource<Profile[]>; me: Profile }) {
  const [selected, setSelected] = useState<Profile | null>(null);
  return <><PageHeading eyebrow="ЛЮДИ JANA" title={me.role === "hr_admin" ? "Сотрудники" : "Моя команда"} description="Профили, доступные в рамках вашей роли. Данные только для чтения." /><section className="panel">{resource.error ? <ErrorBox message={resource.error} retry={resource.reload} /> : resource.loading && !resource.data ? <Loading /> : !resource.data?.length ? <Empty icon="people" title="Профили не найдены" text="В вашей области доступа пока нет сотрудников." /> : <div className="team-grid">{resource.data.map((person) => <button className="person-card" key={person.id} onClick={() => setSelected(person)}><span className="avatar">{initials(person.full_name)}</span><strong>{person.full_name}{person.id === me.id && <small> · вы</small>}</strong><span>{person.position}</span><small>{person.department}</small><span className="tag">{roleLabel[person.role]}</span></button>)}</div>}</section>{selected && <Modal title="Профиль сотрудника" wide onClose={() => setSelected(null)}><ProfileCard me={selected} /></Modal>}</>;
}
