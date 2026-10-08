import { useEffect, useMemo, useRef, useState } from "react";
import { OrderHistory } from "./OrderHistory";
import { AssignmentParticipants } from "./AssignmentParticipants";
import { canViewEquipmentHistory } from "./journal";
import {
  assignmentEditChanges,
  brigadeWorkers,
  workerOrderPermissions,
} from "./brigade";
import { draftFieldSetter, FormDraftNotice, useFormDraft } from "./FormDraft";
import {
  recoverPhase,
  recoverPhotos,
  validateSavedDraft,
} from "./draft-storage";
import type { SavedPhoto } from "./draft-storage";
import {
  advancePhotoFormVersion,
  isStaleOrderForm,
  OrderVersionNotice,
} from "./OrderVersion";
import {
  AiJobStatus,
  applyAiReviewJob,
  canRetryAiReview,
  requestAiReviewRetry,
  showAiReview,
} from "./AiReviewJob";
import {
  completionValidationIssues,
  periodInputDate,
  withinCreatedPeriod,
} from "./workspace";
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
  ApiError,
  confirmedOrderVersion,
  formatDate,
  formatTime,
  idValue,
  initials,
  isOrderVersionConflict,
  number,
  post,
  postOrder,
  orderWrite,
  priorityNames,
  statusNames,
  token,
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
  initialFocus,
  initialAssignee,
  initialEquipment,
  initialArea,
  initialBrigade,
  initialFromDate,
  initialToDate,
  user,
  onCreate,
}: {
  orders: Order[];
  reference: Reference;
  onSelect: (id: Id) => void;
  compact?: boolean;
  initialSearch?: string;
  initialFocus?:
    "all" | "emergency" | "overdue" | "issued" | "ai_review" | "rejected";
  initialAssignee?: Id;
  initialEquipment?: Id;
  initialArea?: Id;
  initialBrigade?: Id;
  initialFromDate?: string;
  initialToDate?: string;
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
  const [focus, setFocus] = useState(initialFocus ?? "all");
  const [mobileGroup, setMobileGroup] = useState("all");
  useEffect(() => setSearch(initialSearch), [initialSearch]);
  useEffect(() => {
    setFocus(initialFocus ?? "all");
    setScope(initialFocus === "all" ? "all" : "active");
    setMobileGroup("all");
  }, [initialFocus]);
  useEffect(() => {
    setFilters({
      ...emptyFilters,
      area: initialArea === undefined ? "" : String(initialArea),
      brigade: initialBrigade === undefined ? "" : String(initialBrigade),
      assignee: initialAssignee === undefined ? "" : String(initialAssignee),
      equipment: initialEquipment === undefined ? "" : String(initialEquipment),
      from: initialFromDate ?? "",
      to: initialToDate ?? "",
    });
    setMobileGroup("all");
  }, [
    initialAssignee,
    initialEquipment,
    initialArea,
    initialBrigade,
    initialFromDate,
    initialToDate,
  ]);
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
          if (focus === "overdue" && !o.is_overdue) return false;
          if (focus === "emergency" && o.priority !== "emergency") return false;
          if (
            ["issued", "ai_review", "rejected"].includes(focus) &&
            o.status !== focus
          )
            return false;
          const q = search.toLocaleLowerCase().trim();
          if (
            q &&
            ![
              o.number,
              o.title,
              o.description,
              o.equipment_name,
              o.assignee_name,
              ...(o.participants?.map((member) => member.name) ?? []),
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
            withinCreatedPeriod(o.created_at, filters.from, filters.to)
          );
        })
        .sort((a, b) => {
          const waiting = (o: Order) =>
            ["accepted", "queued"].includes(o.status);
          if (
            waiting(a) &&
            waiting(b) &&
            String(a.assignee_id) === String(b.assignee_id)
          ) {
            const queueOrder =
              (a.queue_position ?? Number.MAX_SAFE_INTEGER) -
              (b.queue_position ?? Number.MAX_SAFE_INTEGER);
            if (queueOrder) return queueOrder;
          }
          return sort === "deadline"
            ? new Date(a.deadline).getTime() - new Date(b.deadline).getTime()
            : sort === "newest"
              ? new Date(b.created_at).getTime() -
                new Date(a.created_at).getTime()
              : ["emergency", "high", "normal", "planned"].indexOf(a.priority) -
                ["emergency", "high", "normal", "planned"].indexOf(b.priority);
        }),
    [orders, scope, search, filters, sort, focus],
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
      title: "Требует решения",
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
            : `${orders.length} загруженных нарядов`
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
              onClick={() => {
                setScope(v);
                setFocus("all");
                setMobileGroup("all");
              }}
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
      <div className="attention-filters" aria-label="Требуют внимания">
        {(
          [
            ["all", "Без ограничений"],
            ["emergency", "Аварийные"],
            ["overdue", "Просроченные"],
            ["issued", "Не приняты"],
            ["ai_review", "На приёмку"],
            ["rejected", "Отказы"],
          ] as const
        ).map(([value, label]) => (
          <button
            key={value}
            className={focus === value ? "active" : ""}
            aria-pressed={focus === value}
            onClick={() => {
              setFocus(value);
              if (value !== "all") setScope("active");
              setMobileGroup("all");
            }}
          >
            {label}
          </button>
        ))}
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
              value={periodInputDate(filters.from)}
              onChange={(e) => filter("from", e.target.value)}
            />
          </label>
          <label>
            По
            <input
              type="date"
              value={periodInputDate(filters.to)}
              onChange={(e) => filter("to", e.target.value)}
            />
          </label>
          <button
            className="text-button"
            onClick={() => {
              setFilters(emptyFilters);
              setSearch("");
              setFocus("all");
              setMobileGroup("all");
            }}
          >
            Сбросить
          </button>
        </div>
      )}
      <div className="order-context">
        <span>
          Найдено: {results.length}
          {filters.from || filters.to
            ? ` · созданные ${filters.from.includes("T") ? formatDate(filters.from, true) : filters.from || "без начала"} — ${filters.to.includes("T") ? formatDate(filters.to, true) : filters.to || "без конца"}`
            : ""}
        </span>
        {(activeFilters > 0 || search || focus !== "all") && (
          <button
            className="text-button"
            onClick={() => {
              setFilters(emptyFilters);
              setSearch("");
              setFocus("all");
              setMobileGroup("all");
            }}
          >
            Сбросить отбор
          </button>
        )}
      </div>
      <div className="order-board-desktop">
        {results.length === 0 ? (
          <Empty
            title="Наряды не найдены"
            text="Измените условия поиска или выберите другой период."
          />
        ) : view === "board" ? (
          <div className={`kanban ${columns.length > 4 ? "kanban-five" : ""}`}>
            {columns.map((c) => {
              const items = results.filter((o) =>
                c.statuses.includes(o.status),
              );
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
                      {o.brigade_id != null && (
                        <small>Ответственный · бригадный наряд</small>
                      )}
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
      </div>
      <div className="order-board-mobile">
        <label className="mobile-order-groups">
          Этап работы
          <select
            value={mobileGroup}
            onChange={(event) => setMobileGroup(event.target.value)}
          >
            <option value="all">Все этапы · {results.length}</option>
            {Object.entries(statusNames).map(([value, label]) => (
              <option key={value} value={value}>
                {label} ·{" "}
                {results.filter((order) => order.status === value).length}
              </option>
            ))}
          </select>
        </label>
        <div className="mobile-order-list">
          {results
            .filter(
              (order) => mobileGroup === "all" || order.status === mobileGroup,
            )
            .map((order) => (
              <OrderCard
                key={order.id}
                order={order}
                onClick={() => onSelect(order.id)}
              />
            ))}
          {!results.some(
            (order) => mobileGroup === "all" || order.status === mobileGroup,
          ) && (
            <Empty
              title="В этой группе нет нарядов"
              text="Выберите другой этап или сбросьте отбор."
            />
          )}
        </div>
      </div>
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
      <div className="card-substatus">
        <Status value={o.status} />
        {o.brigade_id != null && (
          <span className="outlined-tag">
            <Users size={13} /> Бригадный
          </span>
        )}
        {o.is_overdue && <span className="overdue">Просрочен</span>}
      </div>
      <div className="order-card-bottom">
        <span
          className="card-assignee"
          title={
            o.brigade_id != null
              ? `Ответственный: ${o.assignee_name}`
              : o.assignee_name
          }
        >
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
          {formatDate(o.deadline, true)}
        </span>
      </div>
    </button>
  );
}
const defaultDeadline = () =>
  new Date(Date.now() + 5 * 3600000 + 2 * 3600000).toISOString().slice(0, 16);

type DraftPhoto = SavedPhoto;
type CreateFormFields = {
  title: string;
  description: string;
  work_type: string;
  area_id: string;
  equipment_id: string;
  assignee_id: string;
  brigade_id: string;
  responsible_id: string;
  priority: string;
  deadline: string;
  normal_hours: string;
  comment: string;
};
type OrderSuggestion = {
  source: "openai" | "unavailable";
  fault_code: { id: number; code: string; name: string } | null;
  time_norm: { id: number; name: string; hours: number } | null;
  employee: {
    id: number;
    name: string;
    specialty: string;
    average_score: number | null;
    closed_count: number;
    reason: string;
  } | null;
  explanation: string;
};
type CreateFormDraft = {
  form: CreateFormFields;
  step: number;
  assignment: string;
  created: OrderDetail | null;
  phase: "editing" | "submitting" | "unknown" | "confirmed";
  photos: DraftPhoto[];
  creationPhotoConflict: boolean;
};
type CompletionFormDraft = {
  complete: { work_done: string; fault_code_id: string; comment: string };
  materials: { material_id: string; quantity: string }[];
  baseline: number | null;
  phase: "editing" | "submitting" | "unknown" | "confirmed";
  photos: DraftPhoto[];
};
export function recoverCreateDraft(stored: CreateFormDraft) {
  validateSavedDraft(stored);
  const fields = [
    "title",
    "description",
    "work_type",
    "area_id",
    "equipment_id",
    "assignee_id",
    "brigade_id",
    "priority",
    "deadline",
    "normal_hours",
    "comment",
  ];
  if (
    !stored.form ||
    fields.some(
      (key) =>
        typeof (stored.form as Record<string, unknown>)[key] !== "string",
    ) ||
    ![1, 2].includes(stored.step) ||
    !["employee", "brigade"].includes(stored.assignment) ||
    (stored.form.responsible_id !== undefined &&
      typeof stored.form.responsible_id !== "string") ||
    typeof stored.creationPhotoConflict !== "boolean" ||
    (stored.created !== null &&
      (!stored.created ||
        !Number.isSafeInteger(stored.created.version) ||
        stored.created.version < 1 ||
        !stored.created.id ||
        typeof stored.created.number !== "string")) ||
    (stored.phase === "confirmed" && !stored.created)
  )
    throw new Error(
      "Поля сохранённого черновика выдачи повреждены. Сохранённые данные не перезаписаны.",
    );
  return {
    ...stored,
    form: { ...stored.form, responsible_id: stored.form.responsible_id ?? "" },
    phase: recoverPhase(stored.phase),
    photos: recoverPhotos(stored.photos),
  };
}
export function recoverCompletionDraft(stored: CompletionFormDraft) {
  validateSavedDraft(stored);
  if (
    !stored.complete ||
    ["work_done", "fault_code_id", "comment"].some(
      (key) =>
        typeof (stored.complete as Record<string, unknown>)[key] !== "string",
    ) ||
    !Array.isArray(stored.materials) ||
    stored.materials.some(
      (item) =>
        !item ||
        typeof item.material_id !== "string" ||
        typeof item.quantity !== "string",
    ) ||
    (stored.baseline !== null &&
      (!Number.isSafeInteger(stored.baseline) || stored.baseline < 1))
  )
    throw new Error(
      "Поля сохранённого отчёта повреждены. Сохранённые данные не перезаписаны.",
    );
  return {
    ...stored,
    phase: recoverPhase(stored.phase),
    photos: recoverPhotos(stored.photos),
  };
}
const uploadLabels: Record<DraftPhoto["state"], string> = {
  queued: "Ожидает отправки",
  uploading: "Сжатие и отправка…",
  uploaded: "Получено сервером",
  failed: "Не отправлено",
  uncertain: "Результат неизвестен",
};

async function compressedPhoto(file: File): Promise<File> {
  if (!file.type.startsWith("image/") || file.size > 10 * 1024 * 1024)
    throw new Error("Выберите изображение до 10 МБ.");
  const url = URL.createObjectURL(file);
  try {
    const image = new Image();
    image.src = url;
    await image.decode();
    const ratio = Math.min(
      1,
      1920 / Math.max(image.naturalWidth, image.naturalHeight),
    );
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(image.naturalWidth * ratio));
    canvas.height = Math.max(1, Math.round(image.naturalHeight * ratio));
    const context = canvas.getContext("2d");
    if (!context) throw new Error("Браузер не смог подготовить изображение.");
    context.fillStyle = "#ffffff";
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise<Blob>((resolve, reject) =>
      canvas.toBlob(
        (value) =>
          value ? resolve(value) : reject(new Error("Не удалось сжать фото.")),
        "image/jpeg",
        0.82,
      ),
    );
    return new File([blob], file.name.replace(/\.[^.]+$/, "") + ".jpg", {
      type: "image/jpeg",
    });
  } finally {
    URL.revokeObjectURL(url);
  }
}

export function CreateOrder({
  reference: r,
  employees,
  onClose,
  onCreated,
  initialAssigneeId,
  initialEquipmentId,
  user,
}: {
  reference: Reference;
  employees: Employee[];
  onClose: () => void;
  onCreated: (order: OrderDetail) => void;
  initialAssigneeId?: Id;
  initialEquipmentId?: Id;
  user: User;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const nextPhotoId = useRef(0);
  const requestLock = useRef(false);
  const sessionToken = useRef(token());
  const sessionValid = () => token() === sessionToken.current;
  const [initialForm] = useState(() => {
    const equipment = r.equipment.find(
      (item) => String(item.id) === String(initialEquipmentId),
    );
    return {
      title: "",
      description: "",
      work_type: "unplanned",
      area_id: equipment ? String(equipment.area_id) : "",
      equipment_id: equipment ? String(equipment.id) : "",
      assignee_id:
        initialAssigneeId === undefined ? "" : String(initialAssigneeId),
      brigade_id: "",
      responsible_id: "",
      priority: "normal",
      deadline: defaultDeadline(),
      normal_hours: "2",
      comment: "",
    };
  });
  const draft = useFormDraft<CreateFormDraft>(
    {
      api: new URL("/api/", location.href).href,
      owner: String(user.id),
      form: "create",
      order: "new",
    },
    {
      form: initialForm,
      step: 1,
      assignment: "employee",
      created: null,
      phase: "editing",
      photos: [],
      creationPhotoConflict: false,
    },
    recoverCreateDraft,
  );
  const { step, form, assignment, created, photos, creationPhotoConflict } =
    draft.data;
  const unknownCreate =
    draft.data.phase === "unknown" || draft.data.phase === "submitting";
  const setStep = draftFieldSetter(draft.change, "step");
  const setForm = draftFieldSetter(draft.change, "form");
  const setAssignment = draftFieldSetter(draft.change, "assignment");
  const setPhotos = draftFieldSetter(draft.change, "photos");
  const draftBlocked = !draft.ready || !!draft.error;
  const selectedEmployee = employees.find(
    (person) => String(person.id) === form.assignee_id,
  );
  const suggestionKey = JSON.stringify([
    form.description.trim(),
    form.area_id,
    form.equipment_id,
  ]);
  const latestSuggestionKey = useRef(suggestionKey);
  latestSuggestionKey.current = suggestionKey;
  const suggestionRequest = useRef(0);
  const [suggestionResult, setSuggestionResult] = useState<{
    key: string;
    value: OrderSuggestion;
  } | null>(null);
  const [suggestionLoadingKey, setSuggestionLoadingKey] = useState<string | null>(null);
  const suggestion = suggestionResult?.key === suggestionKey ? suggestionResult.value : null;
  const suggesting = suggestionLoadingKey === suggestionKey;
  useEffect(() => () => { suggestionRequest.current += 1; }, []);
  async function loadSuggestions() {
    if (!form.equipment_id || !form.area_id || form.description.trim().length < 3) return;
    const key = suggestionKey;
    const request = ++suggestionRequest.current;
    setSuggestionLoadingKey(key);
    try {
      const value = await post<OrderSuggestion>("/orders/suggestions", {
        description: form.description.trim(),
        area_id: idValue(form.area_id),
        equipment_id: idValue(form.equipment_id),
      });
      if (request === suggestionRequest.current && latestSuggestionKey.current === key && sessionValid())
        setSuggestionResult({ key, value });
    } catch {
      if (request === suggestionRequest.current && latestSuggestionKey.current === key && sessionValid())
        setSuggestionResult({ key, value: {
          source: "unavailable", fault_code: null, time_norm: null,
          employee: null, explanation: "ИИ-подсказки сейчас недоступны.",
        } });
    } finally {
      if (request === suggestionRequest.current) setSuggestionLoadingKey(null);
    }
  }
  const eligibleBrigadeWorkers = brigadeWorkers(employees, form.brigade_id);
  const update = (key: string, value: string) =>
    setForm((current) => ({
      ...current,
      [key]: value,
      ...(key === "area_id" ? { equipment_id: "" } : {}),
      ...(key === "brigade_id" ? { responsible_id: "" } : {}),
    }));
  const close = () => {
    if (requestLock.current || busy) return;
    if (created) {
      onCreated(created);
      return;
    }
    if (
      (draft.pending || draft.error) &&
      !window.confirm(
        "Черновик ещё не сохранён. Закрытие сейчас может потерять последние изменения. Закрыть форму?",
      )
    )
      return;
    onClose();
  };
  async function addPhotos(files: FileList | null) {
    if (!files || busy || created || draftBlocked) return;
    const incoming = Array.from(files);
    if (photos.length + incoming.length > 5) {
      setError("Можно выбрать не более пяти фотографий до начала работ.");
      return;
    }
    if (
      incoming.some(
        (file) =>
          !["image/jpeg", "image/png", "image/webp"].includes(file.type) ||
          file.size > 10 * 1024 * 1024,
      )
    ) {
      setError("Допустимы JPEG, PNG или WebP, каждый файл не более 10 МБ.");
      return;
    }
    setBusy(true);
    try {
      const additions = await Promise.all(
        incoming.map(async (file) => ({
          id: Math.max(++nextPhotoId.current, Date.now() + nextPhotoId.current),
          file: await compressedPhoto(file),
          kind: "before" as const,
          state: "queued" as const,
        })),
      );
      if (!sessionValid()) return;
      await draft.write((current) => ({
        ...current,
        photos: [...current.photos, ...additions],
      }));
      setError("");
    } catch (failure) {
      if (sessionValid()) setError((failure as Error).message);
    } finally {
      if (sessionValid()) setBusy(false);
    }
  }
  async function sendPhotos(initialOrder: OrderDetail) {
    let order = initialOrder;
    for (const photo of photos.filter(
      (item) => item.state === "queued" || item.state === "failed",
    )) {
      let requestSent = false;
      try {
        const data = new FormData();
        data.append("file", photo.file);
        data.append("kind", "before");
        await draft.write((current) => ({
          ...current,
          photos: current.photos.map((item) =>
            item.id === photo.id
              ? { ...item, state: "uploading", error: undefined }
              : item,
          ),
        }));
        if (!sessionValid()) return null;
        requestSent = true;
        const receipt = await orderWrite<{ order_version: number }>(
          `/orders/${order.id}/photos`,
          order.version,
          { method: "POST", body: data },
        );
        order = {
          ...order,
          version: confirmedOrderVersion(receipt.order_version, order.version),
        };
        if (!sessionValid()) return null;
        const confirmed = order;
        await draft.write((current) => ({
          ...current,
          created: confirmed,
          photos: current.photos.map((item) =>
            item.id === photo.id ? { ...item, state: "uploaded" } : item,
          ),
        }));
      } catch (failure) {
        if (!sessionValid()) return null;
        const unknown =
          requestSent &&
          (!(failure instanceof ApiError) || failure.requestMayHaveSucceeded);
        await draft
          .write((current) => ({
            ...current,
            creationPhotoConflict:
              current.creationPhotoConflict || isOrderVersionConflict(failure),
            photos: current.photos.map((item) =>
              item.id === photo.id
                ? {
                    ...item,
                    state: unknown ? "uncertain" : "failed",
                    error: (failure as Error).message,
                  }
                : item,
            ),
          }))
          .catch(() => {});
        setError(
          isOrderVersionConflict(failure)
            ? "Наряд изменился после выдачи. Откройте актуальную карточку перед отправкой оставшихся фото."
            : unknown
              ? "Наряд создан, но результат загрузки фото неизвестен. Откройте карточку и проверьте снимки; автоматического повтора нет."
              : "Наряд создан. Неотправленное фото можно загрузить повторно; уже принятые снимки не повторяются.",
        );
        return null;
      }
    }
    return order;
  }
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (
      requestLock.current ||
      draftBlocked ||
      unknownCreate ||
      creationPhotoConflict ||
      photos.some((photo) => photo.state === "uncertain")
    )
      return;
    if (
      !form.title.trim() ||
      form.title.trim().length < 3 ||
      !form.description.trim() ||
      !form.area_id ||
      !form.equipment_id
    ) {
      setStep(1);
      setError(
        "Укажите задачу (от 3 символов), описание, участок и оборудование.",
      );
      return;
    }
    if (step === 1 && !created) {
      setStep(2);
      setError("");
      return;
    }
    requestLock.current = true;
    setBusy(true);
    setError("");
    let creating = false;
    try {
      let order = created;
      if (!order) {
        const deadline = new Date(form.deadline + ":00+05:00");
        if (
          !Number.isFinite(deadline.getTime()) ||
          deadline.getTime() <= Date.now()
        )
          throw new Error("Срок исполнения должен быть в будущем.");
        if (assignment === "employee") {
          const fresh = await api<Employee[]>("/employees");
          const person = fresh.find(
            (entry) => String(entry.id) === form.assignee_id,
          );
          if (!person || !person.on_shift || person.status === "off_shift")
            throw new Error(
              "Выбранный исполнитель недоступен на смене. Выберите другого сотрудника.",
            );
        } else {
          if (!form.brigade_id) throw new Error("Выберите бригаду.");
          const fresh = await api<Employee[]>("/employees");
          if (!sessionValid()) return;
          const eligible = brigadeWorkers(fresh, form.brigade_id);
          if (!eligible.length)
            throw new Error("В выбранной бригаде нет работников на смене.");
          if (
            form.responsible_id &&
            !eligible.some(
              (person) => String(person.id) === form.responsible_id,
            )
          )
            throw new Error(
              "Ответственный больше не входит в состав бригады на смене. Выберите его заново.",
            );
        }
        await draft.write((current) => ({ ...current, phase: "submitting" }));
        if (!sessionValid()) return;
        creating = true;
        order = await post<OrderDetail>("/orders", {
          ...form,
          title: form.title.trim(),
          description: form.description.trim(),
          area_id: idValue(form.area_id),
          equipment_id: idValue(form.equipment_id),
          assignee_id:
            assignment === "employee" ? idValue(form.assignee_id) : undefined,
          brigade_id:
            assignment === "brigade" ? idValue(form.brigade_id) : undefined,
          responsible_id:
            assignment === "brigade" && form.responsible_id
              ? idValue(form.responsible_id)
              : undefined,
          normal_hours: Number(form.normal_hours),
          deadline: deadline.toISOString(),
        });
        confirmedOrderVersion(order.version, 1);
        if (!order.id || typeof order.number !== "string")
          throw new ApiError(
            "Наряд мог быть создан, но его подтверждение неполное. Проверьте журнал перед новой выдачей.",
            undefined,
            true,
          );
        if (!sessionValid()) return;
        creating = false;
        const confirmed = order;
        await draft.write((current) => ({
          ...current,
          phase: "confirmed",
          created: confirmed,
        }));
      }
      const withPhotos = await sendPhotos(order);
      if (withPhotos && sessionValid()) {
        await draft.remove();
        if (sessionValid()) onCreated(withPhotos);
      }
    } catch (failure) {
      if (!sessionValid()) return;
      if (creating)
        await draft
          .write((current) => ({
            ...current,
            phase:
              !(failure instanceof ApiError) || failure.requestMayHaveSucceeded
                ? "unknown"
                : "editing",
          }))
          .catch(() => {});
      setError((failure as Error).message);
    } finally {
      requestLock.current = false;
      if (sessionValid()) setBusy(false);
    }
  }
  async function deleteCreateDraft() {
    if (
      busy ||
      !window.confirm(
        created || unknownCreate
          ? "Удалить локальный черновик? Уже созданный наряд и фото останутся на сервере. При неизвестном результате сначала проверьте журнал; новая выдача может стать дубликатом."
          : "Удалить сохранённые текст и фото черновика?",
      )
    )
      return;
    try {
      await draft.remove();
      if (sessionValid()) onClose();
    } catch (failure) {
      if (sessionValid()) setError((failure as Error).message);
    }
  }
  return (
    <Modal
      title={created ? `Наряд ${created.number} выдан` : "Выдать наряд"}
      subtitle="ПОСТАНОВКА ЗАДАЧИ"
      onClose={close}
      wide
    >
      <form onSubmit={submit}>
        <div className="modal-body">
          <FormDraftNotice
            {...draft}
            busy={busy}
            onDelete={() => void deleteCreateDraft()}
          />
          <nav className="create-steps" aria-label="Этапы выдачи">
            {[1, 2].map((value) => (
              <button
                key={value}
                type="button"
                disabled={busy || !!created || unknownCreate || value > step}
                className={step === value ? "active" : ""}
                aria-current={step === value ? "step" : undefined}
                onClick={() => setStep(value)}
              >
                <span>{value}</span>
                {value === 1 ? "Задача и оборудование" : "Назначение и срок"}
              </button>
            ))}
          </nav>
          {error && <ErrorBox message={error} />}
          {unknownCreate && (
            <div className="info-banner" role="status">
              <AlertTriangle size={18} />
              <p>
                Ответ о создании не получен. Наряд мог сохраниться. Повторная
                выдача заблокирована — закройте форму и проверьте журнал.
              </p>
            </div>
          )}
          {created && (
            <div className="info-banner" role="status">
              <CircleCheck size={18} />
              <p>
                Выдача подтверждена сервером. Дальнейшая отправка относится
                только к фото этого наряда.
              </p>
            </div>
          )}
          <fieldset
            disabled={busy || draftBlocked || !!created || unknownCreate}
          >
            {step === 1 ? (
              <>
                <div className="form-grid">
                  <label>
                    Участок <b>*</b>
                    <select
                      required
                      value={form.area_id}
                      onChange={(event) =>
                        update("area_id", event.target.value)
                      }
                    >
                      <option value="">Выберите участок</option>
                      {r.areas.map((item) => (
                        <option key={item.id} value={item.id}>
                          {item.name}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label>
                    Оборудование <b>*</b>
                    <select
                      required
                      disabled={!form.area_id}
                      value={form.equipment_id}
                      onChange={(event) =>
                        update("equipment_id", event.target.value)
                      }
                    >
                      <option value="">
                        {form.area_id
                          ? "Выберите оборудование"
                          : "Сначала выберите участок"}
                      </option>
                      {r.equipment
                        .filter((item) => String(item.area_id) === form.area_id)
                        .map((item) => (
                          <option key={item.id} value={item.id}>
                            {item.name} · {item.inventory_number}
                          </option>
                        ))}
                    </select>
                  </label>
                </div>
                <label>
                  Тип работ
                  <select
                    value={form.work_type}
                    onChange={(event) =>
                      update("work_type", event.target.value)
                    }
                  >
                    <option value="unplanned">Внеплановый ремонт</option>
                    <option value="planned">Плановые работы</option>
                  </select>
                </label>
                <label>
                  Краткая задача <b>*</b>
                  <input
                    required
                    minLength={3}
                    maxLength={200}
                    value={form.title}
                    onChange={(event) => update("title", event.target.value)}
                    placeholder="Например, устранить течь масла на насосе"
                  />
                </label>
                <label>
                  Проблема и ожидаемый результат <b>*</b>
                  <textarea
                    required
                    maxLength={5000}
                    rows={4}
                    value={form.description}
                    onChange={(event) =>
                      update("description", event.target.value)
                    }
                    placeholder="Что неисправно, что требуется сделать и как проверить результат"
                  />
                </label>
                <label className="upload-area">
                  <Camera size={24} />
                  <strong>Фото до начала работ · необязательно</strong>
                  <small>
                    Выберите до 5 снимков · JPEG, PNG, WebP · до 10 МБ каждый
                  </small>
                  <input
                    type="file"
                    multiple
                    accept="image/jpeg,image/png,image/webp"
                    onChange={(event) => {
                      addPhotos(event.target.files);
                      event.target.value = "";
                    }}
                  />
                </label>
              </>
            ) : (
              <>
                <div className="create-context">
                  <strong>{form.title}</strong>
                  <span>
                    {
                      r.equipment.find(
                        (item) => String(item.id) === form.equipment_id,
                      )?.name
                    }{" "}
                    ·{" "}
                    {
                      r.areas.find((item) => String(item.id) === form.area_id)
                        ?.name
                    }
                  </span>
                  <small>
                    {form.work_type === "unplanned"
                      ? "Внеплановый ремонт"
                      : "Плановая работа"}{" "}
                    · фото: {photos.length}
                  </small>
                </div>
                <button
                  type="button"
                  className="button secondary"
                  disabled={suggesting || !form.area_id || !form.equipment_id || form.description.trim().length < 3}
                  onClick={() => void loadSuggestions()}
                >
                  <Sparkles size={16} /> {assignment === "employee" && !form.assignee_id
                    ? "Подсказать шифр, норматив и исполнителя"
                    : "Подсказать шифр и норматив"}
                </button>
                {suggesting && <p className="field-hint">Подбираем шифр, норматив и исполнителя…</p>}
                {suggestion && (
                  <div className="info-banner" role="status">
                    <Sparkles size={18} />
                    <p>{suggestion.source === "unavailable"
                      ? "ИИ-подсказки недоступны. Выберите назначение и срок вручную."
                      : `Предложенный шифр: ${suggestion.fault_code ? `${suggestion.fault_code.code} — ${suggestion.fault_code.name}` : "не определён"}. ${suggestion.explanation}`}</p>
                  </div>
                )}
                <div className="segmented assignment-toggle">
                  <button
                    type="button"
                    className={assignment === "employee" ? "active" : ""}
                    onClick={() => setAssignment("employee")}
                  >
                    <UserRound size={16} />
                    Сотрудник
                  </button>
                  <button
                    type="button"
                    className={assignment === "brigade" ? "active" : ""}
                    onClick={() => setAssignment("brigade")}
                  >
                    <Users size={16} />
                    Бригада
                  </button>
                </div>
                <label>
                  {assignment === "employee" ? "Исполнитель" : "Бригада"}{" "}
                  <b>*</b>
                  <select
                    required
                    value={
                      assignment === "employee"
                        ? form.assignee_id
                        : form.brigade_id
                    }
                    onChange={(event) =>
                      update(
                        assignment === "employee"
                          ? "assignee_id"
                          : "brigade_id",
                        event.target.value,
                      )
                    }
                  >
                    <option value="">
                      {assignment === "employee"
                        ? "Выберите сотрудника"
                        : "Выберите бригаду"}
                    </option>
                    {assignment === "employee"
                      ? employees.map((person) => (
                          <option
                            key={person.id}
                            value={person.id}
                            disabled={
                              !person.on_shift || person.status === "off_shift"
                            }
                          >
                            {person.name} ·{" "}
                            {person.specialty || "Специальность не указана"} ·{" "}
                            {!person.on_shift
                              ? "Вне смены"
                              : person.current_order
                                ? `В работе: ${person.current_order}`
                                : person.status === "free"
                                  ? "Свободен"
                                  : "Есть очередь"}{" "}
                            · ждут начала {person.queue_count}
                          </option>
                        ))
                      : r.brigades.map((brigade) => (
                          <option key={brigade.id} value={brigade.id}>
                            {brigade.name}
                          </option>
                        ))}
                  </select>
                </label>
                {assignment === "employee" && selectedEmployee && (
                  <div
                    className={`employee-preview ${!selectedEmployee.on_shift ? "off-shift" : selectedEmployee.current_order ? "busy" : "available"}`}
                  >
                    <strong>{selectedEmployee.name}</strong>
                    <span>
                      {selectedEmployee.specialty} ·{" "}
                      {!selectedEmployee.on_shift
                        ? "Вне смены"
                        : selectedEmployee.current_order
                          ? "В работе"
                          : selectedEmployee.status === "free"
                            ? "Свободен"
                            : "Есть очередь"}
                    </span>
                    <span>
                      Текущий наряд: {selectedEmployee.current_order || "нет"} ·
                      ожидают начала: {selectedEmployee.queue_count}
                    </span>
                  </div>
                )}
                {assignment === "employee" && !form.assignee_id && suggestion?.employee && (
                  <div className="employee-preview available">
                    <strong>Подсказка: {suggestion.employee.name}</strong>
                    <span>{suggestion.employee.specialty} · {suggestion.employee.reason}</span>
                    <button className="text-button" type="button" onClick={() => update("assignee_id", String(suggestion.employee!.id))}
                      disabled={employees.find((person) => String(person.id) === String(suggestion.employee?.id))?.status !== "free"}>
                      Выбрать исполнителя
                    </button>
                  </div>
                )}
                {assignment === "employee" && !form.assignee_id && suggestion?.source === "openai" && !suggestion.employee && (
                  <p className="field-hint">Свободный исполнитель нужной специальности не найден. Выберите вручную.</p>
                )}
                {assignment === "brigade" && (
                  <>
                    <label>
                      Ответственный за общий результат
                      <select
                        value={form.responsible_id}
                        onChange={(event) =>
                          update("responsible_id", event.target.value)
                        }
                      >
                        <option value="">
                          Автоматически · наименее загруженный
                        </option>
                        {eligibleBrigadeWorkers.map((person) => (
                          <option key={person.id} value={person.id}>
                            {person.name}
                          </option>
                        ))}
                        {form.responsible_id &&
                          !eligibleBrigadeWorkers.some(
                            (person) =>
                              String(person.id) === form.responsible_id,
                          ) && (
                            <option value={form.responsible_id} disabled>
                              Прежний выбор недоступен
                            </option>
                          )}
                      </select>
                    </label>
                    <p className="field-hint">
                      При выдаче сервер зафиксирует работников бригады на смене.
                      Все участники смогут открыть наряд и добавить фото;
                      назначением и сдачей общего результата управляет
                      ответственный.
                    </p>
                    {form.brigade_id && (
                      <p className="field-hint">
                        Сейчас на смене:{" "}
                        {eligibleBrigadeWorkers
                          .map((person) => person.name)
                          .join(", ") || "нет работников"}
                        . Окончательный состав определяется при выдаче.
                      </p>
                    )}
                  </>
                )}
                <div className="form-grid">
                  <label>
                    Приоритет
                    <select
                      value={form.priority}
                      onChange={(event) =>
                        update("priority", event.target.value)
                      }
                    >
                      {Object.entries(priorityNames).map(([value, label]) => (
                        <option key={value} value={value}>
                          {label}
                        </option>
                      ))}
                    </select>
                  </label>
                  <label>
                    Срок, время предприятия <b>*</b>
                    <input
                      required
                      type="datetime-local"
                      value={form.deadline}
                      onChange={(event) =>
                        update("deadline", event.target.value)
                      }
                    />
                    <small>Asia/Almaty · предварительно через 2 часа</small>
                  </label>
                  <label>
                    Норматив, часы
                    <input
                      required
                      type="number"
                      min="0.1"
                      max="1000"
                      step="0.1"
                      value={form.normal_hours}
                      list="time-norms"
                      onChange={(event) =>
                        update("normal_hours", event.target.value)
                      }
                    />
                    <datalist id="time-norms">
                      {r.time_norms.map((item) => (
                        <option key={item.id} value={item.hours}>
                          {item.name}
                        </option>
                      ))}
                    </datalist>
                    {suggestion?.time_norm && (
                      <span className="field-hint">
                        Подсказка: {suggestion.time_norm.name} · {suggestion.time_norm.hours} ч{" "}
                        <button className="text-button" type="button" onClick={() => {
                          const hours = suggestion.time_norm!.hours;
                          setForm((current) => ({ ...current, normal_hours: String(hours),
                            deadline: new Date(Date.now() + hours * 3600000 + 5 * 3600000).toISOString().slice(0, 16) }));
                        }}>Применить норматив и срок</button>
                      </span>
                    )}
                  </label>
                </div>
                <label>
                  Комментарий мастера
                  <textarea
                    rows={2}
                    maxLength={3000}
                    value={form.comment}
                    onChange={(event) => update("comment", event.target.value)}
                    placeholder="Допуск, особые условия или дополнительные указания"
                  />
                </label>
              </>
            )}
          </fieldset>
          {photos.length > 0 && (
            <ul className="upload-list" aria-label="Отправка фотографий">
              {photos.map((photo) => (
                <li className={`upload-item ${photo.state}`} key={photo.id}>
                  <div className="upload-item-main">
                    <Camera size={18} />
                    <div>
                      <strong>{photo.file.name}</strong>
                      <span className="upload-state" role="status">
                        {uploadLabels[photo.state]}
                      </span>
                      {photo.error && <small>{photo.error}</small>}
                    </div>
                  </div>
                  {!created && !busy && (
                    <button
                      type="button"
                      className="icon-button"
                      aria-label={`Убрать фото ${photo.file.name}`}
                      onClick={() =>
                        setPhotos((current) =>
                          current.filter((item) => item.id !== photo.id),
                        )
                      }
                    >
                      <Trash2 size={18} />
                    </button>
                  )}
                </li>
              ))}
            </ul>
          )}
          <p className="field-hint">
            Номер и время выдачи формирует сервер. Черновик и сжатые фото
            сохраняются на этом устройстве для вашего аккаунта и API.
          </p>
        </div>
        <footer className="modal-footer">
          <span>
            <ShieldCheckSmall />
            {created ? "Выдача подтверждена" : `Шаг ${step} из 2`}
          </span>
          {step === 2 && !created && !unknownCreate && (
            <button
              type="button"
              className="button secondary"
              disabled={busy}
              onClick={() => setStep(1)}
            >
              Назад
            </button>
          )}
          <button
            type="button"
            className="button secondary"
            disabled={busy}
            onClick={close}
          >
            {created
              ? "Открыть наряд"
              : unknownCreate
                ? "Закрыть и проверить журнал"
                : "Отмена"}
          </button>
          {!unknownCreate &&
            !creationPhotoConflict &&
            !photos.some((photo) => photo.state === "uncertain") && (
              <button
                className="button primary"
                disabled={busy || draftBlocked}
              >
                {busy ? (
                  <LoaderCircle size={18} className="spin" />
                ) : created ? (
                  <Upload size={18} />
                ) : step === 1 ? (
                  <ArrowRight size={18} />
                ) : (
                  <Plus size={18} />
                )}
                {busy
                  ? "Отправка…"
                  : created
                    ? "Повторить неотправленные фото"
                    : step === 1
                      ? "Далее · назначение"
                      : "Выдать наряд"}
              </button>
            )}
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
  workerHasOpenOrder,
  workerHasActiveOrder,
  workerHasInProgressOrder,
  version,
  onClose,
  onChange,
  notify,
  onEquipment,
  active = true,
}: {
  id: Id;
  reference: Reference;
  user: User;
  workerHasOpenOrder: boolean;
  workerHasActiveOrder: boolean;
  workerHasInProgressOrder: boolean;
  version: number;
  onClose: () => void;
  onChange: () => void;
  notify: (s: string) => void;
  onEquipment?: (id: Id) => void;
  active?: boolean;
}) {
  const [order, setOrder] = useState<OrderDetail | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [mode, setMode] = useState<"none" | "complete" | "edit" | "action">(
    "none",
  );
  const [action, setAction] = useState("");
  const [reason, setReason] = useState("");
  const [score, setScore] = useState("");
  const [completionValidationError, setCompletionValidationError] =
    useState("");
  const [aiRetryUncertain, setAiRetryUncertain] = useState(false);
  const [formVersion, setFormVersion] = useState<number | null>(null);
  const [versionConflict, setVersionConflict] = useState(false);
  const [writeUncertain, setWriteUncertain] = useState(false);
  const [materialSearch, setMaterialSearch] = useState("");
  const mutationLock = useRef(false);
  const revision = useRef(0);
  const sessionToken = useRef(token());
  const sessionValid = () => token() === sessionToken.current;
  const emptyCompletion: CompletionFormDraft = {
    complete: { work_done: "", fault_code_id: "", comment: "" },
    materials: [],
    baseline: null,
    phase: "editing",
    photos: [],
  };
  const draft = useFormDraft<CompletionFormDraft>(
    {
      api: new URL("/api/", location.href).href,
      owner: String(user.id),
      form: "complete",
      order: String(id),
    },
    emptyCompletion,
    recoverCompletionDraft,
  );
  const { complete, materials, baseline: completionVersion } = draft.data;
  const setComplete = draftFieldSetter(draft.change, "complete");
  const setMaterials = draftFieldSetter(draft.change, "materials");
  const setCompletionVersion = draftFieldSetter(draft.change, "baseline");
  const completionUncertain = ["submitting", "unknown"].includes(
    draft.data.phase,
  );
  const photoUncertain = draft.data.photos.some((photo) =>
    ["uploading", "uncertain"].includes(photo.state),
  );
  const draftBlocked = !draft.ready || !!draft.error;
  const completionConfirmed = draft.data.phase === "confirmed";
  const restoredApplied = useRef(false);
  useEffect(() => {
    if (
      !draft.ready ||
      !draft.restored ||
      restoredApplied.current ||
      !sessionValid()
    )
      return;
    restoredApplied.current = true;
    setFormVersion(draft.data.baseline);
    if (
      draft.data.baseline !== null ||
      draft.data.complete.work_done ||
      draft.data.materials.length ||
      draft.data.phase !== "editing"
    )
      setMode("complete");
  }, [draft.ready, draft.restored]);
  const [edit, setEdit] = useState({
    assignment: "employee",
    assignee_id: "",
    brigade_id: "",
    responsible_id: "",
    renew_assignment: false,
    priority: "",
    deadline: "",
    comment: "",
  });
  useEffect(() => {
    if (mutationLock.current) return;
    let valid = true;
    const requestRevision = revision.current;
    api<OrderDetail>(`/orders/${id}`)
      .then((o) => {
        if (valid && requestRevision === revision.current) {
          setOrder(o);
          setError("");
          setAiRetryUncertain(false);
        }
      })
      .catch((e) => {
        if (valid && requestRevision === revision.current) setError(e.message);
      });
    return () => {
      valid = false;
    };
  }, [id, version]);
  const manager = ["master", "admin"].includes(user.role);
  const permissions = order ? workerOrderPermissions(order, user) : null;
  const worker = permissions?.responsible ?? false;
  const assistant = !!permissions?.participant && !worker;
  const canAct = manager || worker;
  const terminal = order && ["closed", "cancelled"].includes(order.status);
  const canUpload =
    (manager || permissions?.canUpload) &&
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
  const staleForm =
    mode !== "none" && !!order && isStaleOrderForm(formVersion, order.version);
  const writeBlocked =
    staleForm ||
    versionConflict ||
    writeUncertain ||
    draftBlocked ||
    photoUncertain ||
    completionUncertain;
  function beginForm(nextMode: "complete" | "edit" | "action") {
    if (
      !order ||
      mutationLock.current ||
      writeBlocked ||
      (nextMode === "complete" && !worker) ||
      (nextMode === "complete" && completionConfirmed)
    )
      return;
    if (nextMode === "complete" && completionVersion === null)
      setCompletionVersion(order.version);
    setFormVersion(
      nextMode === "complete"
        ? (completionVersion ?? order.version)
        : order.version,
    );
    setMode(nextMode);
  }
  function handleVersionFailure(failure: unknown) {
    if (!isOrderVersionConflict(failure)) return false;
    setVersionConflict(true);
    onChange();
    return true;
  }
  async function resetFormAndReload() {
    if (mutationLock.current) return;
    if (
      mode !== "none" &&
      mode !== "complete" &&
      !window.confirm(
        "Закрыть прежнюю форму и загрузить текущий наряд? Введённые текст, причины и материалы будут потеряны.",
      )
    )
      return;
    mutationLock.current = true;
    revision.current++;
    setBusy(true);
    try {
      const latest = await api<OrderDetail>(`/orders/${id}`);
      setOrder(latest);
      setMode("none");
      setFormVersion(null);
      setVersionConflict(false);
      setWriteUncertain(false);
      setAiRetryUncertain(false);
      setReason("");
      setScore("");
      setError("");
    } catch (failure) {
      setError((failure as Error).message);
    } finally {
      mutationLock.current = false;
      setBusy(false);
    }
  }
  function closeDialog() {
    if (mutationLock.current) return;
    if (
      mode === "complete" &&
      (complete.work_done ||
        complete.comment ||
        materials.length ||
        completionUncertain) &&
      (draft.pending || draft.error) &&
      !window.confirm(
        "Последние изменения черновика ещё не сохранены. Закрытие может потерять их. Закрыть форму?",
      )
    )
      return;
    onClose();
  }
  async function reloadDetail() {
    if (mutationLock.current) return;
    setBusy(true);
    try {
      const latest = await api<OrderDetail>(`/orders/${id}`);
      setOrder(latest);
      setAiRetryUncertain(false);
      setError(
        completionUncertain || photoUncertain
          ? "Карточка обновлена. Сравните отчёт, материалы и фото с черновиком. Неизвестная отправка остаётся заблокированной; удалить черновик можно только явным действием."
          : "",
      );
    } catch (failure) {
      setError((failure as Error).message);
    } finally {
      setBusy(false);
    }
  }
  async function retryAiReview() {
    if (
      mutationLock.current ||
      !order ||
      !canRetryAiReview(order, user.role) ||
      writeBlocked ||
      aiRetryUncertain
    )
      return;
    mutationLock.current = true;
    revision.current++;
    setBusy(true);
    setError("");
    try {
      const response = await requestAiReviewRetry(
        id,
        order.ai_review_job!.attempt_id,
        order.version,
      );
      setOrder((current) =>
        current ? applyAiReviewJob(current, response) : current,
      );
      notify("Проверка поставлена в очередь. Отчёт сохранён.");
      onChange();
    } catch (failure) {
      handleVersionFailure(failure);
      setAiRetryUncertain(
        !(failure instanceof ApiError) || failure.requestMayHaveSucceeded,
      );
      setError((failure as Error).message);
    } finally {
      mutationLock.current = false;
      setBusy(false);
    }
  }
  async function execute(actionName: string) {
    if (mutationLock.current || !order || writeBlocked) return;
    if (["close", "rework", "cancel"].includes(actionName) ? !manager : !worker)
      return;
    if (actionName === "close" && !score) {
      setError("Выберите итоговую оценку качества.");
      return;
    }
    if (
      ["pause", "reject", "rework", "cancel"].includes(actionName) &&
      !reason.trim()
    ) {
      setError("Укажите причину действия.");
      return;
    }
    mutationLock.current = true;
    revision.current++;
    setBusy(true);
    setError("");
    try {
      const o = await postOrder<OrderDetail>(
        `/orders/${id}/transition`,
        mode === "action" ? formVersion! : order.version,
        {
          action: actionName,
          reason: reason || undefined,
          comment: reason || undefined,
          score: actionName === "close" ? Number(score) : undefined,
        },
      );
      setOrder(o);
      setMode("none");
      setReason("");
      let message = "Статус наряда обновлён";
      if (actionName === "close") message = "Работа принята. Наряд закрыт.";
      else if (actionName === "queue")
        message = `Задание поставлено в очередь · позиция ${o.queue_position ?? "—"}`;
      else if (actionName === "accept")
        message = "Задание принято. Это ваше единственное текущее задание.";
      notify(message);
      onChange();
    } catch (e) {
      if (
        !handleVersionFailure(e) &&
        (!(e instanceof ApiError) || e.requestMayHaveSucceeded)
      )
        setWriteUncertain(true);
      setError((e as Error).message);
    } finally {
      mutationLock.current = false;
      setBusy(false);
    }
  }
  function actionClick(name: string) {
    if (mutationLock.current || writeBlocked || !order) return;
    if (["pause", "reject", "rework", "cancel", "close"].includes(name)) {
      setAction(name);
      setReason("");
      if (name === "close") setScore("");
      beginForm("action");
    } else void execute(name);
  }
  async function upload(file: File, kind: string, existing?: DraftPhoto) {
    if (
      mutationLock.current ||
      photoUncertain ||
      writeBlocked ||
      !order ||
      !canUpload
    )
      return;
    const requestedVersion =
      existing?.expectedVersion ??
      (mode === "complete"
        ? (completionVersion ?? order.version)
        : order.version);
    mutationLock.current = true;
    revision.current++;
    setBusy(true);
    setError("");
    let sent = false;
    let photo: DraftPhoto | undefined = existing;
    try {
      if (!photo) {
        photo = {
          id: Date.now(),
          file: await compressedPhoto(file),
          kind: kind as "before" | "after",
          state: "queued",
          expectedVersion: requestedVersion,
        };
        if (!sessionValid()) return;
        const prepared = photo;
        await draft.write((current) => ({
          ...current,
          photos: [...current.photos, prepared],
        }));
      }
      const photoId = photo.id;
      await draft.write((current) => ({
        ...current,
        photos: current.photos.map((item) =>
          item.id === photoId
            ? { ...item, state: "uploading", error: undefined }
            : item,
        ),
      }));
      if (!sessionValid()) return;
      const data = new FormData();
      data.append("file", photo.file);
      data.append("kind", kind);
      sent = true;
      const receipt = await orderWrite<{ order_version: number }>(
        `/orders/${id}/photos`,
        requestedVersion,
        { method: "POST", body: data },
      );
      const receivedVersion = confirmedOrderVersion(
        receipt.order_version,
        requestedVersion,
      );
      if (!sessionValid()) return;
      await draft.write((current) => ({
        ...current,
        baseline: advancePhotoFormVersion(
          current.baseline,
          requestedVersion,
          receivedVersion,
        ),
        photos: current.photos.map((item) =>
          item.id === photoId ? { ...item, state: "uploaded" } : item,
        ),
      }));
      setFormVersion((base) =>
        advancePhotoFormVersion(base, requestedVersion, receivedVersion),
      );
      setOrder((current) =>
        current && current.version === requestedVersion
          ? { ...current, version: receivedVersion }
          : current,
      );
      onChange();
      notify("Фото добавлено к наряду");
      try {
        setOrder(await api<OrderDetail>(`/orders/${id}`));
      } catch {
        setError(
          "Фото сохранено. Не удалось обновить карточку — обновите данные, не загружая снимок повторно.",
        );
      }
    } catch (e) {
      if (!sessionValid()) return;
      handleVersionFailure(e);
      const unknown =
        sent && (!(e instanceof ApiError) || e.requestMayHaveSucceeded);
      if (photo) {
        const photoId = photo.id;
        await draft
          .write((current) => ({
            ...current,
            photos: current.photos.map((item) =>
              item.id === photoId
                ? {
                    ...item,
                    state: unknown ? "uncertain" : "failed",
                    error: (e as Error).message,
                  }
                : item,
            ),
          }))
          .catch(() => {});
      }
      setError(
        unknown
          ? "Результат загрузки фото неизвестен. Обновите карточку и проверьте снимки; повторная загрузка в этой форме заблокирована."
          : (e as Error).message,
      );
    } finally {
      mutationLock.current = false;
      if (sessionValid()) setBusy(false);
    }
  }
  async function submitComplete(e: FormEvent) {
    e.preventDefault();
    if (
      mutationLock.current ||
      completionUncertain ||
      completionConfirmed ||
      writeBlocked ||
      !order ||
      !worker ||
      draft.data.photos.some((photo) => photo.state !== "uploaded")
    )
      return;
    setError("");
    const issues = completionValidationIssues({
      workDone: complete.work_done,
      faultCodeId: complete.fault_code_id,
      faultCodeIds: r.fault_codes.map((fault) => fault.id),
      workType: order?.work_type || "",
      hasAfterPhoto: Boolean(
        order?.photos.some((photo) => photo.kind === "after"),
      ),
      materials: materials.map((material) => ({
        materialId: material.material_id,
        quantity: material.quantity,
      })),
      materialIds: r.materials.map((material) => material.id),
    });
    if (issues.length) {
      setCompletionValidationError(issues.join(" "));
      return;
    }
    setCompletionValidationError("");
    mutationLock.current = true;
    revision.current++;
    setBusy(true);
    setError("");
    let sent = false;
    let acknowledged = false;
    try {
      await draft.write((current) => ({ ...current, phase: "submitting" }));
      if (!sessionValid()) return;
      sent = true;
      const o = await postOrder<OrderDetail>(
        `/orders/${id}/complete`,
        formVersion!,
        {
          ...complete,
          work_done: complete.work_done.trim(),
          fault_code_id: idValue(complete.fault_code_id),
          materials: materials.map((m) => ({
            material_id: idValue(m.material_id),
            quantity: Number(m.quantity),
          })),
        },
      );
      confirmedOrderVersion(o.version, formVersion!);
      if (!sessionValid()) return;
      acknowledged = true;
      await draft.write((current) => ({ ...current, phase: "confirmed" }));
      await draft.remove(emptyCompletion);
      setOrder(o);
      setMode("none");
      setFormVersion(null);
      onChange();
      notify("Отчёт сохранён и передан мастеру на приёмку");
    } catch (e) {
      if (!sessionValid()) return;
      handleVersionFailure(e);
      if (sent && !acknowledged)
        await draft
          .write((current) => ({
            ...current,
            phase:
              !(e instanceof ApiError) || e.requestMayHaveSucceeded
                ? "unknown"
                : "editing",
          }))
          .catch(() => {});
      setError((e as Error).message);
    } finally {
      mutationLock.current = false;
      if (sessionValid()) setBusy(false);
    }
  }
  async function deleteCompletionDraft() {
    if (
      busy ||
      !window.confirm(
        completionUncertain || photoUncertain
          ? "Сначала сравните отчёт, материалы и фото в карточке и истории. Удалить локальный черновик с неизвестной отправкой? Это не отменит действие на сервере; новая сдача может повторить расход."
          : "Удалить сохранённые поля отчёта и локальные фото? Уже загруженные фото и отчёт останутся на сервере.",
      )
    )
      return;
    try {
      await draft.remove(emptyCompletion);
      if (!sessionValid()) return;
      setMode("none");
      setFormVersion(null);
      setVersionConflict(false);
      setCompletionValidationError("");
      setError("");
      await reloadDetail();
    } catch (failure) {
      if (sessionValid()) setError((failure as Error).message);
    }
  }
  async function submitEdit(e: FormEvent) {
    e.preventDefault();
    if (mutationLock.current || writeBlocked || !manager) return;
    mutationLock.current = true;
    revision.current++;
    setBusy(true);
    setError("");
    try {
      if (!order) return;
      const changes: Record<string, unknown> = {};
      if (canReassign) {
        for (const [key, value] of Object.entries(
          assignmentEditChanges(order, edit),
        )) {
          if (!value)
            throw new Error(
              edit.assignment === "brigade"
                ? "Выберите бригаду."
                : "Выберите исполнителя.",
            );
          changes[key] = idValue(String(value));
        }
      }
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
      const o = await orderWrite<OrderDetail>(`/orders/${id}`, formVersion!, {
        method: "PATCH",
        body: JSON.stringify(changes),
      });
      setOrder(o);
      setMode("none");
      onChange();
      notify("Изменения сохранены");
    } catch (e) {
      if (
        !handleVersionFailure(e) &&
        (!(e instanceof ApiError) || e.requestMayHaveSucceeded)
      )
        setWriteUncertain(true);
      setError((e as Error).message);
    } finally {
      mutationLock.current = false;
      setBusy(false);
    }
  }
  function startEdit() {
    if (!order || mutationLock.current || writeBlocked) return;
    setEdit({
      assignment: order.brigade_id == null ? "employee" : "brigade",
      assignee_id: String(order.assignee_id),
      brigade_id: order.brigade_id == null ? "" : String(order.brigade_id),
      responsible_id: String(order.assignee_id),
      renew_assignment: false,
      priority: order.priority,
      deadline: new Date(new Date(order.deadline).getTime() + 5 * 3600000)
        .toISOString()
        .slice(0, 16),
      comment: order.comment || "",
    });
    beginForm("edit");
  }
  const actionLabels: Record<string, string> = {
    accept:
      order?.status === "rework" ? "Принять доработку" : "Принять задание",
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
    ? ["issued", "rework"].includes(order.status)
      ? workerHasOpenOrder
        ? ["queue", "reject"]
        : ["accept", "queue", "reject"]
      : order.status === "accepted"
        ? ["start", "queue", "reject"]
        : order.status === "queued"
          ? ["start", "reject"]
          : order.status === "in_progress"
            ? ["pause"]
            : order.status === "paused"
              ? ["resume"]
              : []
    : [];
  return (
    <Modal
      title={order ? order.number : "Наряд"}
      subtitle="КАРТОЧКА РАБОТЫ"
      onClose={closeDialog}
      wide
      active={active}
    >
      <div className="modal-body order-detail-body">
        {(mode === "complete" ||
          draft.restored ||
          draft.error ||
          draft.data.photos.length > 0) && (
          <FormDraftNotice
            {...draft}
            busy={busy}
            onDelete={() => void deleteCompletionDraft()}
          />
        )}
        <OrderVersionNotice
          persistentDraft={mode === "complete"}
          stale={staleForm}
          conflict={versionConflict}
          uncertain={writeUncertain}
          busy={busy}
          onReset={() => void resetFormAndReload()}
        />
        {error && (
          <ErrorBox
            message={error}
            retry={busy ? undefined : () => void reloadDetail()}
          />
        )}{" "}
        {!order ? (
          error ? (
            <Empty
              title="Не удалось открыть наряд"
              text="Проверьте подключение и обновите данные."
            />
          ) : (
            <Loading />
          )
        ) : (
          <>
            <div className="detail-title-line">
              <Status value={order.status} />
              <Priority value={order.priority} />
              {order.queue_position != null && (
                <span className="detail-worktype">
                  {order.queue_position === 1
                    ? "Следующий к началу"
                    : `Очередь · место ${order.queue_position}`}
                </span>
              )}
              <span className="detail-worktype">
                {order.work_type === "planned"
                  ? "Плановая работа"
                  : "Внеплановая работа"}
              </span>
              {manager && !terminal && (
                <button
                  className="icon-button"
                  title="Редактировать наряд"
                  disabled={busy || writeBlocked}
                  onClick={startEdit}
                >
                  <Pencil size={17} />
                </button>
              )}
            </div>
            <h2 className="detail-work-title">{order.title}</h2>
            <div className="detail-layout">
              <div className="detail-main">
                <div className={order.completion ? "review-comparison" : ""}>
                  <section className="review-problem">
                    <h3>Исходная задача</h3>
                    <p className="detail-description">
                      {order.description || "Описание не указано"}
                    </p>
                  </section>{" "}
                  {order.completion && (
                    <section className="completion-report review-result">
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
                </div>
                <div className="detail-info-grid">
                  <div>
                    <small>
                      <Factory size={14} />
                      Оборудование
                    </small>
                    {onEquipment && canViewEquipmentHistory(user.role) ? (
                      <button
                        type="button"
                        className="text-button equipment-history-link"
                        disabled={
                          busy ||
                          writeBlocked ||
                          draft.pending > 0 ||
                          mode === "edit" ||
                          mode === "action"
                        }
                        onClick={() => {
                          if (
                            !mutationLock.current &&
                            !busy &&
                            !writeBlocked &&
                            draft.pending === 0 &&
                            mode !== "edit" &&
                            mode !== "action"
                          )
                            onEquipment(order.equipment_id);
                        }}
                      >
                        {order.equipment_name} · история
                      </button>
                    ) : (
                      <strong>{order.equipment_name}</strong>
                    )}
                    <span>{order.area_name}</span>
                  </div>
                  <div>
                    <small>
                      <UserRound size={14} />
                      {order.brigade_id != null
                        ? "Ответственный"
                        : "Исполнитель"}
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
                    <span>
                      Расчёт простоя: {number(order.downtime_minutes)} мин
                    </span>
                  </div>
                </div>
                <AssignmentParticipants assignment={order} />
                {assistant && (
                  <p className="field-hint" role="status">
                    Вы участвуете в общем наряде. Можно просмотреть ход работ и
                    добавить фото; ответственный управляет очередью, статусом и
                    сдаёт общий результат.
                  </p>
                )}
                <div className="detail-timing">
                  <span>
                    Начало:{" "}
                    <strong>{formatDate(order.started_at, true)}</strong>
                  </span>
                  <span>
                    Сдача:{" "}
                    <strong>{formatDate(order.completed_at, true)}</strong>
                  </span>
                  {order.started_at && order.completed_at && (
                    <span>
                      От начала до сдачи:{" "}
                      <strong>
                        {number(
                          (new Date(order.completed_at).getTime() -
                            new Date(order.started_at).getTime()) /
                            3600000,
                          1,
                        )}{" "}
                        ч
                      </strong>{" "}
                      · включая паузы
                    </span>
                  )}
                  {order.work_type === "unplanned" && (
                    <small>
                      Простой в текущем API считается от выдачи. Фактические
                      остановки отдельно не измеряются.
                    </small>
                  )}
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
                    <fieldset disabled={!canReassign}>
                      <div className="segmented assignment-toggle">
                        <button
                          type="button"
                          className={
                            edit.assignment === "employee" ? "active" : ""
                          }
                          onClick={() =>
                            setEdit({ ...edit, assignment: "employee" })
                          }
                        >
                          <UserRound size={16} /> Сотрудник
                        </button>
                        <button
                          type="button"
                          className={
                            edit.assignment === "brigade" ? "active" : ""
                          }
                          onClick={() =>
                            setEdit({ ...edit, assignment: "brigade" })
                          }
                        >
                          <Users size={16} /> Бригада
                        </button>
                      </div>
                      <label>
                        {edit.assignment === "employee"
                          ? "Исполнитель"
                          : "Бригада"}
                        <select
                          required
                          value={
                            edit.assignment === "employee"
                              ? edit.assignee_id
                              : edit.brigade_id
                          }
                          onChange={(e) =>
                            setEdit(
                              edit.assignment === "employee"
                                ? { ...edit, assignee_id: e.target.value }
                                : {
                                    ...edit,
                                    brigade_id: e.target.value,
                                    responsible_id: "",
                                  },
                            )
                          }
                        >
                          <option value="">
                            Выберите{" "}
                            {edit.assignment === "employee"
                              ? "сотрудника"
                              : "бригаду"}
                          </option>
                          {edit.assignment === "employee"
                            ? r.employees
                                .filter((e) => e.role === "worker")
                                .map((e) => (
                                  <option
                                    key={e.id}
                                    value={e.id}
                                    disabled={e.on_shift === false}
                                  >
                                    {e.name} · {e.specialty}
                                    {e.on_shift === false ? " · вне смены" : ""}
                                  </option>
                                ))
                            : r.brigades.map((brigade) => (
                                <option key={brigade.id} value={brigade.id}>
                                  {brigade.name}
                                </option>
                              ))}
                        </select>
                      </label>
                      {edit.assignment === "brigade" && (
                        <>
                          <label>
                            Ответственный за общий результат
                            <select
                              value={edit.responsible_id}
                              onChange={(event) =>
                                setEdit({
                                  ...edit,
                                  responsible_id: event.target.value,
                                })
                              }
                            >
                              <option value="">
                                Автоматически · наименее загруженный
                              </option>
                              {brigadeWorkers(r.employees, edit.brigade_id).map(
                                (employee) => (
                                  <option key={employee.id} value={employee.id}>
                                    {employee.name}
                                  </option>
                                ),
                              )}
                              {edit.responsible_id &&
                                !brigadeWorkers(
                                  r.employees,
                                  edit.brigade_id,
                                ).some(
                                  (person) =>
                                    String(person.id) === edit.responsible_id,
                                ) && (
                                  <option value={edit.responsible_id} disabled>
                                    {order.assignee_name} · прежний
                                    ответственный недоступен
                                  </option>
                                )}
                            </select>
                          </label>
                          <p className="field-hint">
                            Смена бригады или ответственного создаёт новое
                            назначение с текущим составом работников на смене.
                            Прежний состав остаётся в истории.
                          </p>
                        </>
                      )}
                      <label className="checkbox-label">
                        <input
                          type="checkbox"
                          checked={edit.renew_assignment}
                          onChange={(event) =>
                            setEdit({
                              ...edit,
                              renew_assignment: event.target.checked,
                            })
                          }
                        />
                        Повторно назначить с текущим составом
                      </label>
                    </fieldset>
                    {!canReassign && (
                      <p className="field-hint">
                        В текущем статусе состав и ответственного менять нельзя.
                      </p>
                    )}
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
                      <button
                        className="button primary"
                        disabled={busy || writeBlocked}
                      >
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
                                className={`photo-add ${busy || photoUncertain || writeBlocked ? "disabled" : ""}`}
                              >
                                <Plus size={20} />
                                <span>Добавить</span>
                                <input
                                  disabled={
                                    busy || photoUncertain || writeBlocked
                                  }
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
                  {photoUncertain && (
                    <p className="field-hint" role="status">
                      Ответ о загрузке потерян. Проверьте сохранённые фотографии
                      перед новой отправкой; повтор в этой форме заблокирован.
                    </p>
                  )}
                  {draft.data.photos.length > 0 && (
                    <ul
                      className="upload-list"
                      aria-label="Локальные фото черновика"
                    >
                      {draft.data.photos.map((photo) => (
                        <li
                          key={photo.id}
                          className={`upload-item ${photo.state}`}
                        >
                          <div className="upload-item-main">
                            <Camera size={18} />
                            <div>
                              <strong>
                                {photo.file.name || "Фото черновика"}
                              </strong>
                              <span className="upload-state">
                                {uploadLabels[photo.state]}
                              </span>
                              {photo.error && <small>{photo.error}</small>}
                            </div>
                          </div>
                          {["queued", "failed"].includes(photo.state) && (
                            <button
                              type="button"
                              className="button secondary"
                              disabled={busy || writeBlocked || !canUpload}
                              onClick={() =>
                                void upload(photo.file, photo.kind, photo)
                              }
                            >
                              Отправить фото
                            </button>
                          )}
                        </li>
                      ))}
                    </ul>
                  )}
                </div>
                <AiJobStatus
                  job={order.ai_review_job}
                  busy={busy}
                  uncertain={aiRetryUncertain}
                  onRetry={
                    canRetryAiReview(order, user.role) && !writeBlocked
                      ? () => void retryAiReview()
                      : undefined
                  }
                />
                {order.ai_review && showAiReview(order.ai_review_job) && (
                  <section className="ai-review">
                    <div>
                      <Sparkles size={18} />
                      <h3>
                        {order.ai_review.is_stub
                          ? "Формальная проверка"
                          : "Проверка ИИ"}
                      </h3>
                      {order.ai_review.is_stub && (
                        <span className="stub-tag">ДЕМО · ЗАГЛУШКА</span>
                      )}
                    </div>
                    <div className="review-verdict">
                      <strong>
                        {(
                          {
                            passed: "Принято",
                            needs_attention: "Принято с замечаниями",
                            needs_rework: "Требует доработки",
                            rework: "Требует доработки",
                          } as Record<string, string>
                        )[order.ai_review.verdict] || "Нужна проверка мастером"}
                      </strong>
                      <span>
                        Предварительная оценка: {order.ai_review.score} / 5
                      </span>
                    </div>
                    <p style={{ whiteSpace: "pre-wrap" }}>{order.ai_review.explanation}</p>
                    <small>
                      {order.ai_review.is_stub
                        ? "Проверяется наличие фотографий. Содержимое снимков не анализируется. "
                        : ""}
                      Окончательное решение принимает мастер.
                    </small>
                    {order.score !== null && (
                      <strong className="final-score">
                        Оценка мастера: {order.score} / 5
                      </strong>
                    )}
                  </section>
                )}
                {mode === "complete" && (
                  <form
                    className="inline-form"
                    noValidate
                    onSubmit={submitComplete}
                  >
                    <fieldset
                      disabled={
                        !worker ||
                        busy ||
                        draftBlocked ||
                        completionUncertain ||
                        completionConfirmed
                      }
                    >
                      <h3>
                        <FileCheck2 size={18} />
                        Завершение работы
                      </h3>
                      {!worker && (
                        <p className="field-hint">
                          Сдавать общий результат может только ответственный.
                          Сохранённый черновик остаётся в этом браузере.
                        </p>
                      )}
                      <label>
                        Выполненные работы <b>*</b>
                        <textarea
                          required
                          minLength={10}
                          maxLength={5000}
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
                      {order.completion && (
                        <p className="field-hint">
                          При доработке указывайте только дополнительный расход.
                          Предыдущие списания уже учтены.
                        </p>
                      )}
                      <label>
                        Поиск материала
                        <input
                          type="search"
                          value={materialSearch}
                          onChange={(event) =>
                            setMaterialSearch(event.target.value)
                          }
                          placeholder="Название материала или запчасти"
                        />
                      </label>
                      {materials.map((m, i) => (
                        <div className="material-row" key={i}>
                          <select
                            aria-label={`Материал ${i + 1}`}
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
                            {r.materials
                              .filter(
                                (value) =>
                                  String(value.id) === m.material_id ||
                                  value.name
                                    .toLocaleLowerCase()
                                    .includes(
                                      materialSearch.toLocaleLowerCase(),
                                    ),
                              )
                              .map((v) => (
                                <option
                                  key={v.id}
                                  value={v.id}
                                  disabled={materials.some(
                                    (other, index) =>
                                      index !== i &&
                                      other.material_id === String(v.id),
                                  )}
                                >
                                  {v.name}, {v.unit}
                                </option>
                              ))}
                          </select>
                          <input
                            aria-label="Количество"
                            required
                            type="number"
                            min="0.01"
                            max="1000000"
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
                          maxLength={3000}
                          value={complete.comment}
                          onChange={(e) =>
                            setComplete({
                              ...complete,
                              comment: e.target.value,
                            })
                          }
                        />
                      </label>
                    </fieldset>
                    {completionValidationError && (
                      <div className="error-box" role="alert">
                        <AlertTriangle size={18} />
                        <span>{completionValidationError}</span>
                      </div>
                    )}
                    {completionUncertain && (
                      <div className="info-banner" role="status">
                        <AlertTriangle size={18} />
                        <p>
                          Результат отправки неизвестен. Повтор заблокирован,
                          чтобы не списать материалы дважды. Поля остаются в
                          локальном черновике после закрытия вкладки.
                        </p>
                      </div>
                    )}
                    {completionConfirmed && (
                      <div className="info-banner" role="status">
                        <p>
                          Отчёт подтверждён сервером. Черновик оставлен из-за
                          сбоя локального удаления; повторная сдача
                          заблокирована. Проверьте историю и удалите черновик
                          явно.
                        </p>
                      </div>
                    )}
                    <div className="inline-actions">
                      <button
                        type="button"
                        className="button secondary"
                        disabled={busy}
                        onClick={() => setMode("none")}
                      >
                        Отмена
                      </button>
                      {completionUncertain ? (
                        <button
                          type="button"
                          className="button primary"
                          disabled={busy}
                          onClick={() => void reloadDetail()}
                        >
                          Проверить отправку
                        </button>
                      ) : (
                        <button
                          className="button primary"
                          disabled={
                            !worker ||
                            busy ||
                            writeBlocked ||
                            completionConfirmed ||
                            draft.data.photos.some(
                              (photo) => photo.state !== "uploaded",
                            )
                          }
                        >
                          <Send size={16} />
                          Отправить на приёмку
                        </button>
                      )}
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
                            required
                            value={score}
                            onChange={(e) => setScore(e.target.value)}
                          >
                            <option value="">Выберите оценку</option>
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
                          maxLength={3000}
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
                        disabled={busy || writeBlocked}
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
                <OrderHistory order={order} faultCodes={r.fault_codes} />
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
                        {(
                          {
                            issue: "Наряд выдан",
                            edit: "Назначение или условия изменены",
                            photo: "Добавлено фото",
                            accept: "Задание принято",
                            queue: "Поставлен в очередь",
                            reject: "Задание отклонено",
                            start: "Начато исполнение",
                            pause: "Работа приостановлена",
                            resume: "Работа продолжена",
                            complete: "Отчёт отправлен",
                            ai_review: "Отчёт проверен",
                            rework: "Возвращён на доработку",
                            close: "Принят мастером",
                            cancel: "Отменён",
                          } as Record<string, string>
                        )[e.action] ||
                          statusNames[e.to_status] ||
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
          <button
            className="button secondary"
            disabled={busy}
            onClick={closeDialog}
          >
            Закрыть
          </button>
          <div className="footer-spacer" />
          {manager && !terminal && mode === "none" && (
            <button
              disabled={busy || writeBlocked}
              className="text-button muted"
              onClick={() => actionClick("cancel")}
            >
              Отменить наряд
            </button>
          )}
          {canAct && !terminal && mode === "none" && (
            <>
              {worker &&
                actions.map((a, i) => (
                  <button
                    key={a}
                    className={`button ${i === 0 && order.status !== "in_progress" ? "primary" : "secondary"}`}
                    disabled={
                      busy ||
                      writeBlocked ||
                      (a === "start" &&
                        (workerHasActiveOrder ||
                          (order.queue_position != null &&
                            order.queue_position !== 1))) ||
                      (a === "resume" && workerHasInProgressOrder)
                    }
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
              {worker && order.status === "in_progress" && (
                <button
                  className="button primary"
                  disabled={
                    busy ||
                    writeBlocked ||
                    completionUncertain ||
                    completionConfirmed
                  }
                  onClick={() => beginForm("complete")}
                >
                  <CheckCheck size={16} />
                  Завершить работу
                </button>
              )}
              {manager && order.status === "ai_review" && (
                <>
                  <button
                    className="button secondary"
                    disabled={busy || writeBlocked}
                    onClick={() => actionClick("rework")}
                  >
                    На доработку
                  </button>
                  <button
                    className="button primary"
                    disabled={busy || writeBlocked}
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
