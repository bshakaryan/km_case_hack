import { useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import {
  AlertTriangle,
  ArrowDownUp,
  ArrowRight,
  CalendarDays,
  Camera,
  Check,
  CheckCheck,
  ChevronDown,
  ChevronRight,
  CircleCheck,
  CirclePause,
  ClipboardList,
  Clock3,
  Columns3,
  Download,
  Factory,
  FileCheck2,
  Flag,
  History,
  List,
  LoaderCircle,
  MessageSquare,
  MoreHorizontal,
  Package,
  Pencil,
  Play,
  Plus,
  Search,
  Send,
  SlidersHorizontal,
  Sparkles,
  Trash2,
  Upload,
  UserRound,
  Users,
  Wrench,
  X,
} from "lucide-react";
import {
  api,
  formatDate,
  formatTime,
  idValue,
  initials,
  number,
  post,
  priorityNames,
  statusNames,
} from "./model";
import type {
  Employee,
  Id,
  Order,
  OrderDetail,
  Reference,
  User,
} from "./model";
import {
  Empty,
  ErrorBox,
  Loading,
  Modal,
  Photo,
  Priority,
  SectionTitle,
  Status,
} from "./ui";

type Filters = {
  area: string;
  equipment: string;
  assignee: string;
  brigade: string;
  priority: string;
  status: string;
  from: string;
  to: string;
};
const emptyFilters: Filters = {
  area: "",
  equipment: "",
  assignee: "",
  brigade: "",
  priority: "",
  status: "",
  from: "",
  to: "",
};
export function OrderBoard({
  orders,
  reference,
  onSelect,
  compact = false,
  initialSearch = "",
  user,
  onCreate,
}: {
  orders: Order[];
  reference: Reference;
  onSelect: (id: Id) => void;
  compact?: boolean;
  initialSearch?: string;
  user: User;
  onCreate: () => void;
}) {
  const [search, setSearch] = useState(initialSearch);
  const [view, setView] = useState<"board" | "list">("board");
  const [scope, setScope] = useState("active");
  const [advanced, setAdvanced] = useState(false);
  const [filters, setFilters] = useState<Filters>(emptyFilters);
  const [expanded, setExpanded] = useState<string[]>([]);
  const [sort, setSort] = useState("priority");
  useEffect(() => setSearch(initialSearch), [initialSearch]);
  const filter = (key: keyof Filters, value: string) =>
    setFilters((f) => ({
      ...f,
      [key]: value,
      ...(key === "area" ? { equipment: "" } : {}),
    }));
  const results = useMemo(
    () =>
      orders
        .filter((o) => {
          const isClosed = ["closed", "cancelled"].includes(o.status);
          if (scope === "active" && isClosed) return false;
          if (scope === "closed" && !isClosed) return false;
          const q = search.toLocaleLowerCase().trim();
          if (
            q &&
            ![
              o.number,
              o.title,
              o.description,
              o.equipment_name,
              o.assignee_name,
              o.area_name,
            ].some((v) => v?.toLocaleLowerCase().includes(q))
          )
            return false;
          return (
            (!filters.area || String(o.area_id) === filters.area) &&
            (!filters.equipment ||
              String(o.equipment_id) === filters.equipment) &&
            (!filters.assignee || String(o.assignee_id) === filters.assignee) &&
            (!filters.brigade || String(o.brigade_id) === filters.brigade) &&
            (!filters.priority || o.priority === filters.priority) &&
            (!filters.status || o.status === filters.status) &&
            (!filters.from ||
              new Date(o.created_at) >=
                new Date(`${filters.from}T00:00:00+05:00`)) &&
            (!filters.to ||
              new Date(o.created_at) <=
                new Date(`${filters.to}T23:59:59+05:00`))
          );
        })
        .sort((a, b) =>
          sort === "deadline"
            ? new Date(a.deadline).getTime() - new Date(b.deadline).getTime()
            : sort === "newest"
              ? new Date(b.created_at).getTime() -
                new Date(a.created_at).getTime()
              : ["emergency", "high", "normal", "planned"].indexOf(a.priority) -
                ["emergency", "high", "normal", "planned"].indexOf(b.priority),
        ),
    [orders, scope, search, filters, sort],
  );
  const columns = [
    {
      id: "todo",
      title: "К выполнению",
      color: "blue",
      statuses: ["issued", "accepted", "queued"],
    },
    {
      id: "progress",
      title: "В работе",
      color: "orange",
      statuses: ["in_progress", "paused"],
    },
    {
      id: "review",
      title: "На проверке",
      color: "violet",
      statuses: ["completed", "ai_review"],
    },
    {
      id: "rework",
      title: "Доработка",
      color: "red",
      statuses: ["rework", "rejected"],
    },
    ...(scope !== "active"
      ? [
          {
            id: "closed",
            title: "Закрытые",
            color: "green",
            statuses: ["closed", "cancelled"],
          },
        ]
      : []),
  ];
  const activeFilters = Object.values(filters).filter(Boolean).length;
  return (
    <section className="orders-section">
      <SectionTitle
        title={compact ? "Наряды смены" : "Журнал нарядов"}
        caption={
          compact
            ? "От назначения до приёмки — весь путь работы."
            : `${orders.length} нарядов в системе`
        }
        action={
          <div className="view-switch">
            <button
              className={view === "board" ? "active" : ""}
              title="Канбан"
              onClick={() => setView("board")}
            >
              <Columns3 size={16} />
              <span>Доска</span>
            </button>
            <button
              className={view === "list" ? "active" : ""}
              title="Список"
              onClick={() => setView("list")}
            >
              <List size={17} />
              <span>Список</span>
            </button>
          </div>
        }
      />
      <div className="order-toolbar">
        <div className="tabs">
          {[
            ["active", "Активные"],
            ["all", "Все наряды"],
            ["closed", "Закрытые"],
          ].map(([v, l]) => (
            <button
              key={v}
              className={scope === v ? "active" : ""}
              onClick={() => setScope(v)}
            >
              {l}
              {scope === v && <span>{results.length}</span>}
            </button>
          ))}
        </div>
        <div className="toolbar-controls">
          <label className="search-box">
            <Search size={17} />
            <input
              aria-label="Поиск наряда"
              placeholder="Номер, оборудование, сотрудник…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
            {search && (
              <button onClick={() => setSearch("")} aria-label="Очистить поиск">
                <X size={14} />
              </button>
            )}
          </label>
          <button
            className={`button secondary filters-button ${advanced || activeFilters ? "pressed" : ""}`}
            onClick={() => setAdvanced((v) => !v)}
          >
            <SlidersHorizontal size={16} />
            Фильтры{activeFilters > 0 && <span>{activeFilters}</span>}
          </button>
        </div>
      </div>
      <div className="quick-filters">
        <select
          aria-label="Участок"
          value={filters.area}
          onChange={(e) => filter("area", e.target.value)}
        >
          <option value="">Все участки</option>
          {reference.areas.map((r) => (
            <option key={r.id} value={r.id}>
              {r.name}
            </option>
          ))}
        </select>
        <select
          aria-label="Приоритет"
          value={filters.priority}
          onChange={(e) => filter("priority", e.target.value)}
        >
          <option value="">Любой приоритет</option>
          {Object.entries(priorityNames).map(([v, l]) => (
            <option key={v} value={v}>
              {l}
            </option>
          ))}
        </select>
        <select
          aria-label="Исполнитель"
          value={filters.assignee}
          onChange={(e) => filter("assignee", e.target.value)}
        >
          <option value="">Все исполнители</option>
          {reference.employees
            .filter((e) => e.role === "worker")
            .map((r) => (
              <option key={r.id} value={r.id}>
                {r.name}
              </option>
            ))}
        </select>
        <div className="filter-spacer" />
        <label className="sort-control">
          <ArrowDownUp size={14} />
          <select
            aria-label="Сортировка"
            value={sort}
            onChange={(e) => setSort(e.target.value)}
          >
            <option value="priority">По приоритету</option>
            <option value="deadline">По сроку</option>
            <option value="newest">Сначала новые</option>
          </select>
        </label>
      </div>
      {advanced && (
        <div className="advanced-filters">
          <label>
            Оборудование
            <select
              value={filters.equipment}
              onChange={(e) => filter("equipment", e.target.value)}
            >
              <option value="">Всё оборудование</option>
              {reference.equipment
                .filter(
                  (e) => !filters.area || String(e.area_id) === filters.area,
                )
                .map((r) => (
                  <option key={r.id} value={r.id}>
                    {r.name}
                  </option>
                ))}
            </select>
          </label>
          <label>
            Бригада
            <select
              value={filters.brigade}
              onChange={(e) => filter("brigade", e.target.value)}
            >
              <option value="">Все бригады</option>
              {reference.brigades.map((r) => (
                <option key={r.id} value={r.id}>
                  {r.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Статус
            <select
              value={filters.status}
              onChange={(e) => filter("status", e.target.value)}
            >
              <option value="">Все статусы</option>
              {Object.entries(statusNames).map(([v, l]) => (
                <option key={v} value={v}>
                  {l}
                </option>
              ))}
            </select>
          </label>
          <label>
            Создан с
            <input
              type="date"
              value={filters.from}
              onChange={(e) => filter("from", e.target.value)}
            />
          </label>
          <label>
            По
            <input
              type="date"
              value={filters.to}
              onChange={(e) => filter("to", e.target.value)}
            />
          </label>
          <button
            className="text-button"
            onClick={() => {
              setFilters(emptyFilters);
              setSearch("");
            }}
          >
            Сбросить
          </button>
        </div>
      )}
      {results.length === 0 ? (
        <Empty
          title="Наряды не найдены"
          text="Измените условия поиска или выберите другой период."
        />
      ) : view === "board" ? (
        <div className={`kanban ${columns.length > 4 ? "kanban-five" : ""}`}>
          {columns.map((c) => {
            const items = results.filter((o) => c.statuses.includes(o.status));
            const shown = expanded.includes(c.id)
              ? items
              : items.slice(0, compact ? 3 : 6);
            return (
              <div key={c.id} className="kanban-column">
                <div className="kanban-title">
                  <span className={`column-dot ${c.color}`} />
                  <h3>{c.title}</h3>
                  <span className="column-count">{items.length}</span>
                  <MoreHorizontal size={17} />
                </div>
                <div className="kanban-cards">
                  {shown.map((o) => (
                    <OrderCard
                      key={o.id}
                      order={o}
                      onClick={() => onSelect(o.id)}
                    />
                  ))}
                  {!items.length && (
                    <div className="column-empty">
                      <CircleCheck size={21} />
                      <span>Нет нарядов</span>
                    </div>
                  )}
                  {shown.length < items.length && (
                    <button
                      className="show-more"
                      onClick={() => setExpanded((v) => [...v, c.id])}
                    >
                      Показать ещё {items.length - shown.length}
                      <ChevronDown size={15} />
                    </button>
                  )}
                  {c.id === "todo" &&
                    ["master", "admin"].includes(user.role) && (
                      <button className="new-card" onClick={onCreate}>
                        <Plus size={16} />
                        Новый наряд
                      </button>
                    )}
                </div>
              </div>
            );
          })}
        </div>
      ) : (
        <div className="table-wrap">
          <table className="data-table orders-table">
            <thead>
              <tr>
                <th>Наряд / оборудование</th>
                <th>Участок</th>
                <th>Исполнитель</th>
                <th>Приоритет</th>
                <th>Статус</th>
                <th>Срок</th>
                <th />
              </tr>
            </thead>
            <tbody>
              {results.map((o) => (
                <tr
                  key={o.id}
                  onClick={() => onSelect(o.id)}
                  tabIndex={0}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") onSelect(o.id);
                  }}
                >
                  <td>
                    <span className="table-eyebrow">{o.number}</span>
                    <strong>{o.title}</strong>
                    <small>{o.equipment_name}</small>
                  </td>
                  <td>{o.area_name}</td>
                  <td>
                    <div className="table-person">
                      <span className="avatar mini-avatar">
                        {initials(o.assignee_name || "?")}
                      </span>
                      {o.assignee_name || "Не назначен"}
                    </div>
                  </td>
                  <td>
                    <Priority value={o.priority} />
                  </td>
                  <td>
                    <Status value={o.status} />
                  </td>
                  <td className={o.is_overdue ? "overdue" : ""}>
                    {formatDate(o.deadline, true)}
                    {o.is_overdue && <small>Просрочено</small>}
                  </td>
                  <td>
                    <ChevronRight size={16} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  );
}
function OrderCard({
  order: o,
  onClick,
}: {
  order: Order;
  onClick: () => void;
}) {
  return (
    <button
      className={`order-card ${o.priority === "emergency" ? "emergency-card" : ""}`}
      onClick={onClick}
    >
      <div className="order-card-top">
        <span className="order-number">{o.number}</span>
        <Priority value={o.priority} />
      </div>
      <h4>{o.title}</h4>
      <div className="card-equipment">
        <Factory size={14} />
        <span>{o.equipment_name}</span>
      </div>
      <div className="card-area">
        <span>{o.area_name}</span>
        <span>{o.work_type === "planned" ? "Плановая" : "Внеплановая"}</span>
      </div>
      {["paused", "queued", "rejected", "accepted"].includes(o.status) && (
        <div className="card-substatus">
          <Status value={o.status} />
        </div>
      )}
      <div className="order-card-bottom">
        <span className="card-assignee">
          <span className="avatar tiny-avatar">
            {initials(o.assignee_name || "?")}
          </span>
          <span>
            {o.assignee_name?.split(" ").slice(0, 2).join(" ") || "Не назначен"}
          </span>
        </span>
        <span
          className={`card-deadline ${o.is_overdue ? "overdue" : ""}`}
          title={formatDate(o.deadline, true)}
        >
          {o.is_overdue ? <AlertTriangle size={13} /> : <Clock3 size={13} />}{" "}
          {formatTime(o.deadline)}
        </span>
      </div>
    </button>
  );
}
const defaultDeadline = () =>
  new Date(Date.now() + 5 * 60 * 60 * 1000 + 4 * 60 * 60 * 1000)
    .toISOString()
    .slice(0, 16);
export function CreateOrder({
  reference: r,
  employees,
  onClose,
  onCreated,
}: {
  reference: Reference;
  employees: Employee[];
  onClose: () => void;
  onCreated: (order: OrderDetail) => void;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [created, setCreated] = useState<OrderDetail | null>(null);
  const [photo, setPhoto] = useState<File | null>(null);
  const [assignment, setAssignment] = useState("employee");
  const [form, setForm] = useState({
    title: "",
    description: "",
    work_type: "unplanned",
    area_id: "",
    equipment_id: "",
    assignee_id: "",
    brigade_id: "",
    priority: "normal",
    deadline: defaultDeadline(),
    normal_hours: "2",
    comment: "",
  });
  const update = (k: string, v: string) =>
    setForm((f) => ({
      ...f,
      [k]: v,
      ...(k === "area_id" ? { equipment_id: "" } : {}),
    }));
  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      let order = created;
      if (!order) {
        order = await post<OrderDetail>("/orders", {
          ...form,
          area_id: idValue(form.area_id),
          equipment_id: idValue(form.equipment_id),
          assignee_id:
            assignment === "employee" ? idValue(form.assignee_id) : undefined,
          brigade_id:
            assignment === "brigade" ? idValue(form.brigade_id) : undefined,
          normal_hours: Number(form.normal_hours),
          deadline: new Date(form.deadline + ":00+05:00").toISOString(),
        });
        setCreated(order);
      }
      if (photo) {
        const data = new FormData();
        data.append("file", photo);
        data.append("kind", "before");
        await api(`/orders/${order.id}/photos`, { method: "POST", body: data });
      }
      onCreated(order);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <Modal
      title="Новый наряд"
      subtitle="ПОСТАНОВКА ЗАДАЧИ"
      onClose={onClose}
      wide
    >
      <form onSubmit={submit}>
        <div className="modal-body">
          <fieldset disabled={!!created || busy}>
            <div className="form-section-heading">
              <span>01</span>
              <h3>Что необходимо сделать</h3>
            </div>
            <label>
              Название работы <b>*</b>
              <input
                value={form.title}
                onChange={(e) => update("title", e.target.value)}
                required
                maxLength={200}
                placeholder="Например, заменить подшипник конвейера"
              />
            </label>
            <label>
              Описание задачи <b>*</b>
              <textarea
                value={form.description}
                onChange={(e) => update("description", e.target.value)}
                required
                rows={3}
                placeholder="Опишите неисправность, объём работ и ожидаемый результат"
              />
            </label>
            <div className="form-grid">
              <label>
                Участок <b>*</b>
                <select
                  required
                  value={form.area_id}
                  onChange={(e) => update("area_id", e.target.value)}
                >
                  <option value="">Выберите участок</option>
                  {r.areas.map((v) => (
                    <option key={v.id} value={v.id}>
                      {v.name}
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Оборудование <b>*</b>
                <select
                  required
                  value={form.equipment_id}
                  onChange={(e) => update("equipment_id", e.target.value)}
                  disabled={!form.area_id}
                >
                  <option value="">Выберите оборудование</option>
                  {r.equipment
                    .filter((v) => String(v.area_id) === form.area_id)
                    .map((v) => (
                      <option key={v.id} value={v.id}>
                        {v.name} · {v.inventory_number}
                      </option>
                    ))}
                </select>
              </label>
              <label>
                Тип работы
                <select
                  value={form.work_type}
                  onChange={(e) => update("work_type", e.target.value)}
                >
                  <option value="unplanned">Внеплановая</option>
                  <option value="planned">Плановая</option>
                </select>
              </label>
              <label>
                Приоритет
                <select
                  value={form.priority}
                  onChange={(e) => update("priority", e.target.value)}
                >
                  {Object.entries(priorityNames).map(([v, l]) => (
                    <option key={v} value={v}>
                      {l}
                    </option>
                  ))}
                </select>
              </label>
            </div>
            <div className="form-section-heading">
              <span>02</span>
              <h3>Исполнитель и сроки</h3>
            </div>
            <div className="segmented assignment-toggle">
              <button
                type="button"
                className={assignment === "employee" ? "active" : ""}
                onClick={() => setAssignment("employee")}
              >
                <UserRound size={15} />
                Сотрудник
              </button>
              <button
                type="button"
                className={assignment === "brigade" ? "active" : ""}
                onClick={() => setAssignment("brigade")}
              >
                <Users size={15} />
                Бригада
              </button>
            </div>
            <label>
              {assignment === "employee" ? "Исполнитель" : "Бригада"} <b>*</b>
              <select
                required
                value={
                  assignment === "employee" ? form.assignee_id : form.brigade_id
                }
                onChange={(e) =>
                  update(
                    assignment === "employee" ? "assignee_id" : "brigade_id",
                    e.target.value,
                  )
                }
              >
                <option value="">
                  Выберите{" "}
                  {assignment === "employee" ? "сотрудника" : "бригаду"}
                </option>
                {(assignment === "employee"
                  ? r.employees.filter((v) => v.role === "worker")
                  : r.brigades
                ).map((v) => (
                  <option key={v.id} value={v.id}>
                    {v.name}
                    {v.specialty ? ` · ${v.specialty}` : ""}
                    {assignment === "employee"
                      ? ` · ${({ busy: "В работе", free: "Свободен", queued: "В очереди", off_shift: "Вне смены" } as Record<string, string>)[employees.find((e) => String(e.id) === String(v.id))?.status || "off_shift"]} · в очереди: ${employees.find((e) => String(e.id) === String(v.id))?.queue_count || 0}`
                      : ""}
                  </option>
                ))}
              </select>
            </label>
            <div className="form-grid">
              <label>
                Срок исполнения, Алматы <b>*</b>
                <input
                  required
                  type="datetime-local"
                  value={form.deadline}
                  onChange={(e) => update("deadline", e.target.value)}
                />
              </label>
              <label>
                Норма времени, часов
                <input
                  required
                  type="number"
                  min="0.1"
                  max="1000"
                  step="0.1"
                  value={form.normal_hours}
                  onChange={(e) => update("normal_hours", e.target.value)}
                  list="time-norms"
                />
                <datalist id="time-norms">
                  {r.time_norms.map((v) => (
                    <option key={v.id} value={v.hours}>
                      {v.name}
                    </option>
                  ))}
                </datalist>
              </label>
            </div>
            <label>
              Комментарий мастера
              <textarea
                value={form.comment}
                onChange={(e) => update("comment", e.target.value)}
                rows={2}
                placeholder="Дополнительные указания или требования"
              />
            </label>
          </fieldset>
          <label className="upload-area">
            <Camera size={24} />
            <strong>
              {photo ? photo.name : "Добавить фото до начала работ"}
            </strong>
            <small>JPEG, PNG или WebP · до 10 МБ</small>
            <input
              type="file"
              accept="image/jpeg,image/png,image/webp"
              onChange={(e) => {
                const f = e.target.files?.[0];
                if (f && f.size > 10 * 1024 * 1024) {
                  setError("Фото должно быть не более 10 МБ");
                  return;
                }
                setPhoto(f || null);
              }}
            />
          </label>
          {created && (
            <div className="info-banner">
              <CircleCheck size={17} />
              Наряд {created.number} уже создан. Можно повторить загрузку фото.
            </div>
          )}
          {error && <ErrorBox message={error} />}
        </div>
        <footer className="modal-footer">
          <span>
            <ShieldCheckSmall />
            История действий сохраняется
          </span>
          <button
            type="button"
            className="button secondary"
            onClick={() => (created ? onCreated(created) : onClose())}
          >
            {created ? "Открыть наряд" : "Отмена"}
          </button>
          <button className="button primary" disabled={busy}>
            {busy ? (
              <LoaderCircle className="spin" size={17} />
            ) : (
              <Plus size={17} />
            )}{" "}
            {created ? "Загрузить фото" : "Создать наряд"}
          </button>
        </footer>
      </form>
    </Modal>
  );
}
function ShieldCheckSmall() {
  return <CheckCheck size={15} />;
}

export function OrderDialog({
  id,
  reference: r,
  user,
  version,
  onClose,
  onChange,
  notify,
}: {
  id: Id;
  reference: Reference;
  user: User;
  version: number;
  onClose: () => void;
  onChange: () => void;
  notify: (s: string) => void;
}) {
  const [order, setOrder] = useState<OrderDetail | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [mode, setMode] = useState<"none" | "complete" | "edit" | "action">(
    "none",
  );
  const [action, setAction] = useState("");
  const [reason, setReason] = useState("");
  const [score, setScore] = useState("5");
  const [complete, setComplete] = useState({
    work_done: "",
    fault_code_id: "",
    comment: "",
  });
  const [materials, setMaterials] = useState<
    { material_id: string; quantity: string }[]
  >([]);
  const [edit, setEdit] = useState({
    assignee_id: "",
    priority: "",
    deadline: "",
    comment: "",
  });
  useEffect(() => {
    let valid = true;
    api<OrderDetail>(`/orders/${id}`)
      .then((o) => {
        if (valid) {
          setOrder(o);
          setError("");
        }
      })
      .catch((e) => {
        if (valid) setError(e.message);
      });
    return () => {
      valid = false;
    };
  }, [id, version]);
  const manager = ["master", "admin"].includes(user.role);
  const worker =
    user.role === "worker" && String(user.id) === String(order?.assignee_id);
  const canAct = manager || worker;
  const terminal = order && ["closed", "cancelled"].includes(order.status);
  const canUpload =
    canAct &&
    order &&
    !["ai_review", "completed", "closed", "cancelled"].includes(order.status);
  const canReassign =
    order &&
    ![
      "in_progress",
      "paused",
      "ai_review",
      "completed",
      "closed",
      "cancelled",
    ].includes(order.status);
  async function execute(actionName: string) {
    setBusy(true);
    setError("");
    try {
      const o = await post<OrderDetail>(`/orders/${id}/transition`, {
        action: actionName,
        reason: reason || undefined,
        comment: reason || undefined,
        score: actionName === "close" ? Number(score) : undefined,
      });
      setOrder(o);
      setMode("none");
      setReason("");
      notify(
        actionName === "close"
          ? "Работа принята. Наряд закрыт."
          : "Статус наряда обновлён",
      );
      onChange();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  function actionClick(name: string) {
    if (["pause", "reject", "rework", "cancel", "close"].includes(name)) {
      setAction(name);
      setReason("");
      setMode("action");
    } else void execute(name);
  }
  async function upload(file: File, kind: string) {
    setBusy(true);
    setError("");
    try {
      const data = new FormData();
      data.append("file", file);
      data.append("kind", kind);
      await api(`/orders/${id}/photos`, { method: "POST", body: data });
      setOrder(await api<OrderDetail>(`/orders/${id}`));
      onChange();
      notify("Фото добавлено к наряду");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function submitComplete(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      const o = await post<OrderDetail>(`/orders/${id}/complete`, {
        ...complete,
        fault_code_id: idValue(complete.fault_code_id),
        materials: materials.map((m) => ({
          material_id: idValue(m.material_id),
          quantity: Number(m.quantity),
        })),
      });
      setOrder(o);
      setMode("none");
      onChange();
      notify("Отчёт сохранён и передан мастеру на приёмку");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function submitEdit(e: FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError("");
    try {
      if (!order) return;
      const changes: Record<string, unknown> = {};
      if (edit.assignee_id !== String(order.assignee_id))
        changes.assignee_id = idValue(edit.assignee_id);
      if (edit.priority !== order.priority) changes.priority = edit.priority;
      if (edit.comment !== (order.comment || ""))
        changes.comment = edit.comment;
      const previousDeadline = new Date(
        new Date(order.deadline).getTime() + 5 * 3600000,
      )
        .toISOString()
        .slice(0, 16);
      if (edit.deadline !== previousDeadline)
        changes.deadline = new Date(edit.deadline + ":00+05:00").toISOString();
      if (!Object.keys(changes).length) {
        setMode("none");
        return;
      }
      const o = await api<OrderDetail>(`/orders/${id}`, {
        method: "PATCH",
        body: JSON.stringify(changes),
      });
      setOrder(o);
      setMode("none");
      onChange();
      notify("Изменения сохранены");
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  function startEdit() {
    if (!order) return;
    setEdit({
      assignee_id: String(order.assignee_id),
      priority: order.priority,
      deadline: new Date(new Date(order.deadline).getTime() + 5 * 3600000)
        .toISOString()
        .slice(0, 16),
      comment: order.comment || "",
    });
    setMode("edit");
  }
  const actionLabels: Record<string, string> = {
    accept: "Принять наряд",
    queue: "В очередь",
    reject: "Отклонить",
    start: "Начать работу",
    pause: "Приостановить",
    resume: "Продолжить",
    close: "Принять работу",
    rework: "На доработку",
    cancel: "Отменить наряд",
  };
  const actions = order
    ? order.status === "issued"
      ? ["accept", "queue", "reject"]
      : order.status === "accepted" || order.status === "queued"
        ? ["start", "reject"]
        : order.status === "in_progress"
          ? ["pause"]
          : order.status === "paused"
            ? ["resume"]
            : order.status === "rework"
              ? ["start"]
              : []
    : [];
  return (
    <Modal
      title={order ? order.number : "Наряд"}
      subtitle="КАРТОЧКА РАБОТЫ"
      onClose={onClose}
      wide
    >
      <div className="modal-body order-detail-body">
        {error && <ErrorBox message={error} />}{" "}
        {!order ? (
          <Loading />
        ) : (
          <>
            <div className="detail-title-line">
              <Status value={order.status} />
              <Priority value={order.priority} />
              <span className="detail-worktype">
                {order.work_type === "planned"
                  ? "Плановая работа"
                  : "Внеплановая работа"}
              </span>
              {manager && !terminal && (
                <button
                  className="icon-button"
                  title="Редактировать наряд"
                  onClick={startEdit}
                >
                  <Pencil size={17} />
                </button>
              )}
            </div>
            <h2 className="detail-work-title">{order.title}</h2>
            <div className="detail-layout">
              <div className="detail-main">
                <div className="detail-description">{order.description}</div>
                <div className="detail-info-grid">
                  <div>
                    <small>
                      <Factory size={14} />
                      Оборудование
                    </small>
                    <strong>{order.equipment_name}</strong>
                    <span>{order.area_name}</span>
                  </div>
                  <div>
                    <small>
                      <UserRound size={14} />
                      Исполнитель
                    </small>
                    <strong>{order.assignee_name}</strong>
                    <span>
                      {order.brigade_id
                        ? r.brigades.find((b) => b.id === order.brigade_id)
                            ?.name
                        : "Индивидуальное назначение"}
                    </span>
                  </div>
                  <div className={order.is_overdue ? "overdue" : ""}>
                    <small>
                      <CalendarDays size={14} />
                      Выполнить до
                    </small>
                    <strong>{formatDate(order.deadline, true)}</strong>
                    <span>
                      {order.is_overdue
                        ? "Срок исполнения истёк"
                        : "Время Алматы"}
                    </span>
                  </div>
                  <div>
                    <small>
                      <Clock3 size={14} />
                      Норма времени
                    </small>
                    <strong>{number(order.normal_hours, 1)} ч</strong>
                    <span>Простой: {number(order.downtime_minutes)} мин</span>
                  </div>
                </div>
                {order.comment && (
                  <div className="comment-block">
                    <MessageSquare size={16} />
                    <div>
                      <strong>Комментарий мастера</strong>
                      <p>{order.comment}</p>
                    </div>
                  </div>
                )}
                {mode === "edit" && (
                  <form className="inline-form" onSubmit={submitEdit}>
                    <h3>
                      <Pencil size={17} />
                      Изменить назначение
                    </h3>
                    <label>
                      Исполнитель
                      <select
                        required
                        disabled={!canReassign}
                        value={edit.assignee_id}
                        onChange={(e) =>
                          setEdit({ ...edit, assignee_id: e.target.value })
                        }
                      >
                        {r.employees
                          .filter((e) => e.role === "worker")
                          .map((e) => (
                            <option key={e.id} value={e.id}>
                              {e.name}
                            </option>
                          ))}
                      </select>
                    </label>
                    <div className="form-grid">
                      <label>
                        Приоритет
                        <select
                          value={edit.priority}
                          onChange={(e) =>
                            setEdit({ ...edit, priority: e.target.value })
                          }
                        >
                          {Object.entries(priorityNames).map(([v, l]) => (
                            <option key={v} value={v}>
                              {l}
                            </option>
                          ))}
                        </select>
                      </label>
                      <label>
                        Срок, Алматы
                        <input
                          required
                          type="datetime-local"
                          value={edit.deadline}
                          onChange={(e) =>
                            setEdit({ ...edit, deadline: e.target.value })
                          }
                        />
                      </label>
                    </div>
                    <label>
                      Комментарий
                      <textarea
                        rows={2}
                        value={edit.comment}
                        onChange={(e) =>
                          setEdit({ ...edit, comment: e.target.value })
                        }
                      />
                    </label>
                    <div className="inline-actions">
                      <button
                        type="button"
                        className="button secondary"
                        onClick={() => setMode("none")}
                      >
                        Отмена
                      </button>
                      <button className="button primary" disabled={busy}>
                        Сохранить
                      </button>
                    </div>
                  </form>
                )}
                <div className="detail-photos">
                  <h3>
                    <Camera size={17} />
                    Фотофиксация
                  </h3>
                  <div className="photo-groups">
                    {["before", "after"].map((kind) => (
                      <div key={kind}>
                        <div className="photo-group-label">
                          <span>
                            {kind === "before"
                              ? "До выполнения"
                              : "После выполнения"}
                          </span>
                          <small>
                            {order.photos.filter((p) => p.kind === kind).length}
                            /5
                          </small>
                        </div>
                        <div className="photo-grid">
                          {order.photos
                            .filter((p) => p.kind === kind)
                            .map((p) => (
                              <Photo
                                key={p.id}
                                url={p.url}
                                alt={
                                  kind === "before"
                                    ? "Фото до выполнения"
                                    : "Фото после выполнения"
                                }
                              />
                            ))}
                          {canUpload &&
                            order.photos.filter((p) => p.kind === kind).length <
                              5 && (
                              <label
                                className={`photo-add ${busy ? "disabled" : ""}`}
                              >
                                <Plus size={20} />
                                <span>Добавить</span>
                                <input
                                  disabled={busy}
                                  type="file"
                                  accept="image/jpeg,image/png,image/webp"
                                  onChange={(e) => {
                                    const f = e.target.files?.[0];
                                    if (f) void upload(f, kind);
                                    e.target.value = "";
                                  }}
                                />
                              </label>
                            )}
                          {!order.photos.some((p) => p.kind === kind) &&
                            !canUpload && (
                              <span className="muted">Нет фотографий</span>
                            )}
                        </div>
                      </div>
                    ))}
                  </div>
                  {order.work_type === "unplanned" && canUpload && (
                    <p className="field-hint">
                      Для завершения внеплановой работы нужно фото «После
                      выполнения».
                    </p>
                  )}
                </div>
                {order.completion && (
                  <section className="completion-report">
                    <h3>
                      <FileCheck2 size={17} />
                      Отчёт исполнителя
                    </h3>
                    <p>{order.completion.work_done}</p>
                    <div className="report-fault">
                      <span>Код неисправности</span>
                      <strong>
                        {
                          r.fault_codes.find(
                            (f) =>
                              String(f.id) ===
                              String(order.completion?.fault_code_id),
                          )?.code
                        }{" "}
                        ·{" "}
                        {
                          r.fault_codes.find(
                            (f) =>
                              String(f.id) ===
                              String(order.completion?.fault_code_id),
                          )?.name
                        }
                      </strong>
                    </div>
                    {order.completion.materials.length > 0 && (
                      <div className="materials-report">
                        {order.completion.materials.map((m, i) => (
                          <div key={i}>
                            <span>
                              <Package size={14} />
                              {m.name}
                            </span>
                            <strong>
                              {m.quantity} {m.unit}
                            </strong>
                          </div>
                        ))}
                      </div>
                    )}
                    {order.completion.comment && (
                      <p className="muted">{order.completion.comment}</p>
                    )}
                  </section>
                )}
                {order.ai_review && (
                  <section className="ai-review">
                    <div>
                      <Sparkles size={18} />
                      <h3>Предварительная проверка</h3>
                      <span className="stub-tag">ИИ · ЗАГЛУШКА</span>
                    </div>
                    <p>{order.ai_review.explanation}</p>
                    <small>
                      Демонстрационный алгоритм. Окончательное решение принимает
                      мастер.
                    </small>
                    {order.score !== null && (
                      <strong className="final-score">
                        Оценка мастера: {order.score} / 5
                      </strong>
                    )}
                  </section>
                )}
                {mode === "complete" && (
                  <form className="inline-form" onSubmit={submitComplete}>
                    <h3>
                      <FileCheck2 size={18} />
                      Завершение работы
                    </h3>
                    <label>
                      Выполненные работы <b>*</b>
                      <textarea
                        required
                        minLength={10}
                        rows={3}
                        placeholder="Что было сделано и какой результат получен"
                        value={complete.work_done}
                        onChange={(e) =>
                          setComplete({
                            ...complete,
                            work_done: e.target.value,
                          })
                        }
                      />
                    </label>
                    <label>
                      Код неисправности <b>*</b>
                      <select
                        required
                        value={complete.fault_code_id}
                        onChange={(e) =>
                          setComplete({
                            ...complete,
                            fault_code_id: e.target.value,
                          })
                        }
                      >
                        <option value="">Выберите неисправность</option>
                        {r.fault_codes.map((f) => (
                          <option key={f.id} value={f.id}>
                            {f.code} · {f.name}
                          </option>
                        ))}
                      </select>
                    </label>
                    <div className="materials-form-title">
                      <strong>Использованные материалы</strong>
                      <button
                        type="button"
                        className="text-button"
                        onClick={() =>
                          setMaterials((m) => [
                            ...m,
                            { material_id: "", quantity: "1" },
                          ])
                        }
                      >
                        <Plus size={14} />
                        Добавить
                      </button>
                    </div>
                    {materials.map((m, i) => (
                      <div className="material-row" key={i}>
                        <select
                          required
                          value={m.material_id}
                          onChange={(e) =>
                            setMaterials((ms) =>
                              ms.map((v, j) =>
                                j === i
                                  ? { ...v, material_id: e.target.value }
                                  : v,
                              ),
                            )
                          }
                        >
                          <option value="">Материал</option>
                          {r.materials.map((v) => (
                            <option key={v.id} value={v.id}>
                              {v.name}, {v.unit}
                            </option>
                          ))}
                        </select>
                        <input
                          aria-label="Количество"
                          required
                          type="number"
                          min="0.01"
                          step="0.01"
                          value={m.quantity}
                          onChange={(e) =>
                            setMaterials((ms) =>
                              ms.map((v, j) =>
                                j === i
                                  ? { ...v, quantity: e.target.value }
                                  : v,
                              ),
                            )
                          }
                        />
                        <button
                          type="button"
                          className="icon-button"
                          onClick={() =>
                            setMaterials((ms) => ms.filter((_, j) => j !== i))
                          }
                          aria-label="Удалить материал"
                        >
                          <Trash2 size={16} />
                        </button>
                      </div>
                    ))}
                    <label>
                      Комментарий
                      <textarea
                        rows={2}
                        value={complete.comment}
                        onChange={(e) =>
                          setComplete({ ...complete, comment: e.target.value })
                        }
                      />
                    </label>
                    <div className="inline-actions">
                      <button
                        type="button"
                        className="button secondary"
                        onClick={() => setMode("none")}
                      >
                        Отмена
                      </button>
                      <button className="button primary" disabled={busy}>
                        <Send size={16} />
                        На проверку
                      </button>
                    </div>
                  </form>
                )}
                {mode === "action" && (
                  <form
                    className="inline-form"
                    onSubmit={(e) => {
                      e.preventDefault();
                      void execute(action);
                    }}
                  >
                    <h3>{actionLabels[action]}</h3>
                    {action === "close" ? (
                      <>
                        <label>
                          Оценка качества работы
                          <select
                            value={score}
                            onChange={(e) => setScore(e.target.value)}
                          >
                            {[5, 4, 3, 2, 1].map((s) => (
                              <option key={s} value={s}>
                                {s} —{" "}
                                {
                                  [
                                    "",
                                    "Неудовлетворительно",
                                    "Ниже ожиданий",
                                    "Удовлетворительно",
                                    "Хорошо",
                                    "Отлично",
                                  ][s]
                                }
                              </option>
                            ))}
                          </select>
                        </label>
                        <p className="field-hint">
                          Вы подтверждаете выполнение и качество работы. Наряд
                          будет закрыт.
                        </p>
                      </>
                    ) : (
                      <label>
                        Причина <b>*</b>
                        <textarea
                          required
                          minLength={3}
                          value={reason}
                          onChange={(e) => setReason(e.target.value)}
                          rows={3}
                          placeholder="Укажите причину — она сохранится в истории"
                        />
                      </label>
                    )}
                    <div className="inline-actions">
                      <button
                        type="button"
                        className="button secondary"
                        onClick={() => setMode("none")}
                      >
                        Отмена
                      </button>
                      <button
                        className={`button ${action === "cancel" ? "danger" : "primary"}`}
                        disabled={busy}
                      >
                        {busy ? (
                          <LoaderCircle size={16} className="spin" />
                        ) : (
                          <Check size={16} />
                        )}
                        Подтвердить
                      </button>
                    </div>
                  </form>
                )}
              </div>
              <aside className="detail-history">
                <h3>
                  <History size={16} />
                  История наряда
                </h3>
                <div className="timeline">
                  {order.events.map((e, i) => (
                    <div className="timeline-item" key={e.id}>
                      <span
                        className={`timeline-point ${i === order.events.length - 1 ? "latest" : ""}`}
                      />
                      <strong>
                        {statusNames[e.to_status] ||
                          (
                            {
                              created: "Наряд создан",
                              updated: "Наряд изменён",
                              photo_uploaded: "Фото добавлено",
                            } as Record<string, string>
                          )[e.action] ||
                          e.action}
                      </strong>
                      <span>{e.actor_name}</span>
                      {e.comment && <p>{e.comment}</p>}
                      <small>{formatDate(e.created_at, true)}</small>
                    </div>
                  ))}
                </div>
                <div className="detail-created">
                  Создан {formatDate(order.created_at, true)}
                </div>
              </aside>
            </div>
          </>
        )}
      </div>
      {order && (
        <footer className="modal-footer detail-footer">
          <button className="button secondary" onClick={onClose}>
            Закрыть
          </button>
          <div className="footer-spacer" />
          {manager && !terminal && mode === "none" && (
            <button
              disabled={busy}
              className="text-button muted"
              onClick={() => actionClick("cancel")}
            >
              Отменить наряд
            </button>
          )}
          {canAct && !terminal && mode === "none" && (
            <>
              {actions.map((a, i) => (
                <button
                  key={a}
                  className={`button ${i === 0 ? "primary" : "secondary"}`}
                  disabled={busy}
                  onClick={() => actionClick(a)}
                >
                  {a === "start" || a === "resume" ? (
                    <Play size={15} />
                  ) : a === "pause" ? (
                    <CirclePause size={15} />
                  ) : a === "accept" ? (
                    <Check size={15} />
                  ) : null}
                  {actionLabels[a]}
                </button>
              ))}
              {order.status === "in_progress" && (
                <button
                  className="button primary"
                  disabled={busy}
                  onClick={() => setMode("complete")}
                >
                  <CheckCheck size={16} />
                  Завершить работу
                </button>
              )}
              {manager && order.status === "ai_review" && (
                <>
                  <button
                    className="button secondary"
                    disabled={busy}
                    onClick={() => actionClick("rework")}
                  >
                    На доработку
                  </button>
                  <button
                    className="button primary"
                    disabled={busy}
                    onClick={() => actionClick("close")}
                  >
                    <CheckCheck size={17} />
                    Принять работу
                  </button>
                </>
              )}
            </>
          )}
        </footer>
      )}
    </Modal>
  );
}
