export type Id = number | string;
export type User = {
  id: Id;
  name: string;
  role: string;
  login: string;
  specialty?: string;
  brigade_id?: Id;
  on_shift?: boolean;
};
export type RefItem = { id: Id; name: string; [key: string]: any };
export type Reference = {
  areas: RefItem[];
  equipment: RefItem[];
  employees: RefItem[];
  brigades: RefItem[];
  fault_codes: RefItem[];
  materials: RefItem[];
  time_norms: RefItem[];
};
export type Employee = User & {
  status: string;
  current_order: string | null;
  queue_count: number;
  rating: number;
  completed_count: number;
  grade?: number;
};
export type AssignmentParticipant = {
  employee_id: Id;
  name: string;
  is_responsible: boolean;
  source: "live" | "legacy_snapshot";
};
export type AssignmentRoster = {
  assignee_id: Id;
  assignee_name: string;
  brigade_id: Id | null;
  participants?: AssignmentParticipant[];
  participants_source?: "live" | "legacy_snapshot";
};
export type Order = {
  id: Id;
  version: number;
  number: string;
  title: string;
  description: string;
  work_type: string;
  area_id: Id;
  area_name: string;
  equipment_id: Id;
  equipment_name: string;
  assignee_id: Id;
  assignee_name: string;
  brigade_id: Id | null;
  participants?: AssignmentParticipant[];
  participants_source?: "live" | "legacy_snapshot";
  master_id: Id;
  priority: string;
  status: string;
  queue_position?: number | null;
  deadline: string;
  created_at: string;
  started_at: string | null;
  completed_at: string | null;
  closed_at: string | null;
  comment: string | null;
  is_overdue: boolean;
  normal_hours: number;
  downtime_minutes: number;
  score: number | null;
};
export type OrderDetail = Order & {
  ai_review_job?: AiReviewJob | null;
  assignment_history?: AssignmentHistory[];
  submission_attempts?: SubmissionAttempt[];
  events: {
    id: Id;
    action: string;
    from_status: string | null;
    to_status: string;
    actor_name: string;
    created_at: string;
    comment: string | null;
  }[];
  photos: {
    id: Id;
    kind: string;
    url: string;
    created_at: string;
    author_name: string;
  }[];
  completion: {
    work_done: string;
    fault_code_id: Id;
    comment: string;
    materials: {
      material_id: Id;
      name: string;
      quantity: number;
      unit: string;
    }[];
  } | null;
  ai_review: {
    verdict: string;
    score: number | null;
    explanation: string;
    is_stub: boolean;
    master_score?: number | null;
    source_verdict?:
      | "accepted"
      | "accepted_with_remarks"
      | "needs_rework"
      | "needs_master_review";
    llm_used?: boolean;
    is_recommendation?: true;
  } | null;
};
export type AiReviewJob = {
  id: Id;
  attempt_id: Id;
  status: "pending" | "running" | "succeeded" | "failed" | "superseded";
  provider: "stub" | "ai_service";
  attempts: number;
  max_attempts: number;
  next_attempt_at: string | null;
  lease_expires_at: string | null;
  last_error_code: string | null;
  created_at: string;
  finished_at: string | null;
  retry_allowed: boolean;
};
export type AttemptAiReview = {
  attempt_id: Id;
  order_version: number;
  ai_review: OrderDetail["ai_review"];
  job: AiReviewJob | null;
};
export type AssignmentHistory = {
  id: Id;
  number: number;
  source: "live" | "legacy_snapshot";
  assignee_id: Id;
  assignee_name: string;
  brigade_id: Id | null;
  brigade_name: string | null;
  participants?: AssignmentParticipant[];
  participants_source?: "live" | "legacy_snapshot";
  assigned_by_id: Id | null;
  assigned_by_name: string | null;
  assigned_at: string;
  ended_at: string | null;
};
export type SubmissionAttempt = {
  ai_job?: AiReviewJob | null;
  id: Id;
  number: number;
  source: "live" | "legacy_snapshot";
  assignment_id: Id | null;
  submitted_at: string | null;
  author_id: Id | null;
  author_name: string | null;
  assessment_id: Id | null;
  completion: {
    work_done?: string;
    fault_code_id?: Id | null;
    comment?: string;
    materials?: {
      material_id: Id;
      quantity: number;
      name?: string;
      unit?: string;
    }[];
  };
  photos: OrderDetail["photos"];
  materials: {
    id: Id;
    material_id: Id;
    name: string;
    unit: string;
    quantity: number;
    author_id: Id | null;
    author_name: string | null;
    created_at: string;
  }[];
  ai_review: OrderDetail["ai_review"];
  decisions: {
    id: Id;
    actor_id: Id;
    actor_name: string;
    action: "close" | "rework";
    score: number | null;
    comment: string | null;
    created_at: string;
  }[];
};
export type Notice = {
  id: Id;
  title: string;
  message: string;
  kind: string;
  order_id: Id | null;
  created_at: string;
  read: boolean;
};
export type Dashboard = {
  issued: number;
  completed: number;
  overdue: number;
  downtime_count: number;
  active: number;
  total: number;
  avg_rating: number;
  shift_label: string;
};
export type Analytics = {
  summary: {
    total: number;
    closed: number;
    on_time_percent: number;
    avg_score: number;
    downtime_hours: number;
  };
  trend: { date: string; planned: number; unplanned: number }[];
  by_area: { name: string; count: number; downtime_hours: number }[];
  rankings: {
    id: Id;
    name: string;
    specialty: string;
    brigade: string;
    score: number;
    quality: number;
    on_time: number;
    closed_count: number;
    rework_rate: number;
  }[];
  equipment: {
    id: Id;
    name: string;
    area_name: string;
    orders: number;
    downtime_hours: number;
  }[];
  materials: { name: string; unit: string; quantity: number }[];
  insights: {
    title: string;
    description: string;
    severity: string;
    is_stub: boolean;
  }[];
  ai_summary: string;
  is_stub: boolean;
};
export const statusNames: Record<string, string> = {
  issued: "Выдан",
  accepted: "Принят · ожидает начала",
  queued: "В очереди",
  rejected: "Отклонён",
  in_progress: "В работе",
  paused: "Приостановлен",
  completed: "Исполнено",
  ai_review: "Проверка ИИ",
  rework: "На доработку",
  closed: "Закрыт",
  cancelled: "Отменён",
};
export const priorityNames: Record<string, string> = {
  emergency: "Аварийный",
  high: "Высокий",
  normal: "Обычный",
  planned: "Плановый",
};
export const roleNames: Record<string, string> = {
  master: "Мастер смены",
  worker: "Исполнитель",
  manager: "Руководитель",
  admin: "Администратор",
};
export const initials = (name: string) =>
  name
    .split(" ")
    .slice(0, 2)
    .map((n) => n[0])
    .join("");
export const formatDate = (date: string | null, full = false) =>
  date
    ? new Intl.DateTimeFormat("ru-RU", {
        timeZone: "Asia/Almaty",
        day: "2-digit",
        month: "short",
        ...(full ? { hour: "2-digit", minute: "2-digit" } : {}),
      }).format(new Date(date))
    : "—";
export const formatTime = (date: string) =>
  new Intl.DateTimeFormat("ru-RU", {
    timeZone: "Asia/Almaty",
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(date));
export const number = (n: number | undefined, digits = 0) =>
  new Intl.NumberFormat("ru-RU", { maximumFractionDigits: digits }).format(
    n || 0,
  );
export const idValue = (v: string): Id => (/^\d+$/.test(v) ? Number(v) : v);
type OrdersResponse = { etag: string; body: string };
const ordersResponses = new Map<string, OrdersResponse>();
const latestOrdersReads = new Map<string, number>();
let ordersReadSequence = 0;
let apiSessionEpoch = 0;
let observedToken: string | null | undefined;
let observedBase: string | undefined;
let storageWindow: Window | undefined;

function apiBase() {
  if (typeof window === "undefined") return "";
  return (
    window.location?.origin ||
    (window.location?.href ? new URL(window.location.href).origin : "")
  );
}
function clearApiContext() {
  ++apiSessionEpoch;
  ordersResponses.clear();
  latestOrdersReads.clear();
  observedToken = localStorage.getItem("naryad_token");
  observedBase = apiBase();
}
function changedStorage(event: StorageEvent) {
  if (event.key === null || event.key === "naryad_token") clearApiContext();
}
function apiContext() {
  if (
    typeof window !== "undefined" &&
    typeof window.addEventListener === "function" &&
    storageWindow !== window
  ) {
    storageWindow?.removeEventListener("storage", changedStorage);
    storageWindow = window;
    storageWindow.addEventListener("storage", changedStorage);
  }
  const currentToken = localStorage.getItem("naryad_token");
  const base = apiBase();
  if (currentToken !== observedToken || base !== observedBase) {
    ++apiSessionEpoch;
    ordersResponses.clear();
    latestOrdersReads.clear();
    observedToken = currentToken;
    observedBase = base;
  }
  return { token: currentToken, base, epoch: apiSessionEpoch };
}
export const token = () => apiContext().token;
// Even replacing a token with the same value establishes a new local session.
// Login/logout use this setter; storage events also fence an A→B→A change.
export function setToken(value: string | null) {
  if (value === null) localStorage.removeItem("naryad_token");
  else localStorage.setItem("naryad_token", value);
  clearApiContext();
}
function strongOrdersEtag(value: string | null) {
  return value &&
    value.length <= 4096 &&
    /^"[\x21\x23-\x7e\x80-\xff]*"$/.test(value)
    ? value
    : null;
}
export class ApiError extends Error {
  readonly statusCode: number | undefined;
  readonly requestMayHaveSucceeded: boolean;
  readonly code: string | undefined;
  readonly expectedVersion: number | undefined;
  readonly currentVersion: number | undefined;
  constructor(
    message: string,
    statusCode?: number,
    requestMayHaveSucceeded = false,
    code?: string,
    expectedVersion?: number,
    currentVersion?: number,
  ) {
    super(message);
    this.name = "ApiError";
    this.statusCode = statusCode;
    this.requestMayHaveSucceeded = requestMayHaveSucceeded;
    this.code = code;
    this.expectedVersion = expectedVersion;
    this.currentVersion = currentVersion;
  }
}
export async function api<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const headers = new Headers(options.headers);
  const context = apiContext();
  const sessionToken = context.token;
  const method = (options.method || "GET").toUpperCase();
  const writing = !["GET", "HEAD"].includes(method);
  if (sessionToken) headers.set("Authorization", `Bearer ${sessionToken}`);
  if (options.body && !(options.body instanceof FormData))
    headers.set("Content-Type", "application/json");
  const url = `/api${path}`;
  const requestUrl = context.base ? new URL(url, context.base).href : url;
  const conditionalOrders =
    method === "GET" && options.body == null && /^\/orders(?:\?|$)/.test(path);
  const cacheKey = `${context.epoch}\0${requestUrl}\0${headers.get("Authorization") || ""}`;
  const readId = conditionalOrders ? ++ordersReadSequence : 0;
  if (conditionalOrders) latestOrdersReads.set(cacheKey, readId);
  const cached = conditionalOrders ? ordersResponses.get(cacheKey) : undefined;
  const suppliedCondition = headers.get("If-None-Match");
  const revalidated =
    cached && (suppliedCondition === null || suppliedCondition === cached.etag)
      ? cached
      : undefined;
  if (revalidated) headers.set("If-None-Match", revalidated.etag);
  function assertContext() {
    const current = apiContext();
    if (
      current.epoch !== context.epoch ||
      current.token !== context.token ||
      current.base !== context.base
    )
      throw new ApiError(
        "Контекст запроса изменился. Обновите данные под текущим пользователем.",
        conditionalOrders ? 409 : 401,
        writing,
        conditionalOrders ? "read_context_changed" : undefined,
      );
    if (conditionalOrders && options.signal?.aborted)
      throw new DOMException("Чтение отменено.", "AbortError");
  }
  function forgetResponse() {
    if (
      conditionalOrders &&
      latestOrdersReads.get(cacheKey) === readId &&
      ordersResponses.get(cacheKey) === cached
    )
      ordersResponses.delete(cacheKey);
  }
  try {
    let res: Response;
    try {
      res = await fetch(url, {
        ...options,
        headers,
        ...(conditionalOrders ? { cache: "no-store" } : {}),
      });
    } catch (error) {
      forgetResponse();
      assertContext();
      if (
        !writing &&
        error instanceof DOMException &&
        error.name === "AbortError"
      )
        throw error;
      throw new ApiError(
        writing
          ? "Сервер не подтвердил результат. Проверьте наряд перед повторной отправкой."
          : "Нет связи с сервером. Проверьте подключение и повторите обновление.",
        undefined,
        writing,
      );
    }
    assertContext();
    if (conditionalOrders && res.status === 304) {
      try {
        const body = await res.text();
        assertContext();
        if (
          !revalidated ||
          ordersResponses.get(cacheKey) !== revalidated ||
          res.headers.get("ETag") !== revalidated.etag ||
          body !== ""
        )
          throw new ApiError(
            "Сервер не прислал список нарядов, а соответствующая сохранённая копия недоступна. Повторите обновление.",
            304,
          );
        // Each caller receives its own objects, including nested participants.
        return JSON.parse(revalidated.body) as T;
      } catch (error) {
        forgetResponse();
        assertContext();
        if (error instanceof ApiError) throw error;
        throw new ApiError("Ответ сервера не удалось прочитать.", 304);
      }
    }
    if (!res.ok) {
      forgetResponse();
      let error: any;
      try {
        error = await res.json();
      } catch {
        error = { detail: res.statusText };
      }
      assertContext();
      if (res.status === 401 && path != "/auth/login")
        window.dispatchEvent(new Event("naryad:unauthorized"));
      const detail = error.detail;
      throw new ApiError(
        Array.isArray(detail)
          ? detail.map((v: any) => v.msg).join("; ")
          : typeof detail === "string"
            ? detail
            : typeof detail?.message === "string"
              ? detail.message
              : `Ошибка запроса (${res.status})`,
        res.status,
        writing && res.status >= 500,
        typeof detail?.code === "string" ? detail.code : undefined,
        Number.isSafeInteger(detail?.expected_version)
          ? detail.expected_version
          : undefined,
        Number.isSafeInteger(detail?.current_version)
          ? detail.current_version
          : undefined,
      );
    }
    if (res.status === 204) {
      if (conditionalOrders) {
        forgetResponse();
        throw new ApiError("Сервер не прислал список нарядов.", 204);
      }
      return undefined as T;
    }
    try {
      const body = conditionalOrders ? await res.text() : undefined;
      const data = conditionalOrders ? JSON.parse(body!) : await res.json();
      assertContext();
      if (conditionalOrders) {
        if (
          !Array.isArray(data) ||
          !data.every(
            (row) =>
              row !== null && typeof row === "object" && !Array.isArray(row),
          )
        )
          throw new ApiError(
            "Сервер вернул неверный формат списка нарядов.",
            res.status,
          );
        const etag = strongOrdersEtag(res.headers.get("ETag"));
        if (
          res.status === 200 &&
          etag &&
          latestOrdersReads.get(cacheKey) === readId
        ) {
          // Bound retained bodies; an evicted query needs a new full response.
          if (!ordersResponses.has(cacheKey) && ordersResponses.size >= 8)
            ordersResponses.delete(ordersResponses.keys().next().value!);
          ordersResponses.set(cacheKey, { etag, body: body! });
        } else forgetResponse();
      }
      return data as T;
    } catch (error) {
      forgetResponse();
      assertContext();
      if (error instanceof ApiError) throw error;
      throw new ApiError(
        "Ответ сервера не удалось прочитать. Проверьте результат обновлением.",
        res.status,
        writing,
      );
    }
  } finally {
    // An absent ID must not let an older pending 200 restore a newer read's
    // cleared/replaced body. Retain metadata only while the latest read runs.
    if (conditionalOrders && latestOrdersReads.get(cacheKey) === readId)
      latestOrdersReads.delete(cacheKey);
  }
}
export const post = <T>(path: string, body: any) =>
  api<T>(path, { method: "POST", body: JSON.stringify(body) });
export function isOrderVersionConflict(error: unknown) {
  return (
    error instanceof ApiError &&
    ["order_version_conflict", "order_precondition_unavailable"].includes(
      error.code || "",
    )
  );
}
export function orderWrite<T>(
  path: string,
  version: number,
  options: RequestInit,
): Promise<T> {
  if (!Number.isSafeInteger(version) || version < 1)
    throw new ApiError("Обновите наряд перед отправкой действия.");
  const headers = new Headers(options.headers);
  headers.set("X-Expected-Order-Version", String(version));
  return api<T>(path, { ...options, headers });
}
export const postOrder = <T>(path: string, version: number, body: any) =>
  orderWrite<T>(path, version, {
    method: "POST",
    body: JSON.stringify(body),
  });
export function confirmedOrderVersion(
  receivedVersion: number,
  requestedVersion: number,
) {
  if (
    !Number.isSafeInteger(receivedVersion) ||
    receivedVersion < requestedVersion
  )
    throw new ApiError(
      "Действие отправлено, но версия ответа неизвестна. Обновите наряд перед новым действием.",
      undefined,
      true,
    );
  return receivedVersion;
}
export async function downloadReport(query: string) {
  const res = await fetch(`/api/reports/export?${query}`, {
    headers: { Authorization: `Bearer ${token()}` },
  });
  if (!res.ok) throw new Error("Не удалось сформировать отчёт");
  const url = URL.createObjectURL(await res.blob());
  const a = document.createElement("a");
  a.href = url;
  a.download = `НарядAI-отчёт-${new Date().toISOString().slice(0, 10)}.csv`;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}
export const emptyReference: Reference = {
  areas: [],
  equipment: [],
  employees: [],
  brigades: [],
  fault_codes: [],
  materials: [],
  time_norms: [],
};
