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
export type Order = {
  id: Id;
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
  master_id: Id;
  priority: string;
  status: string;
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
    score: number;
    explanation: string;
    is_stub: boolean;
    master_score?: number | null;
  } | null;
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
  accepted: "Принят в работу",
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
export const token = () => localStorage.getItem("naryad_token");
export class ApiError extends Error {
  readonly statusCode: number | undefined;
  readonly requestMayHaveSucceeded: boolean;
  constructor(
    message: string,
    statusCode?: number,
    requestMayHaveSucceeded = false,
  ) {
    super(message);
    this.name = "ApiError";
    this.statusCode = statusCode;
    this.requestMayHaveSucceeded = requestMayHaveSucceeded;
  }
}
export async function api<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const headers = new Headers(options.headers);
  const sessionToken = token();
  const writing = !["GET", "HEAD"].includes(
    (options.method || "GET").toUpperCase(),
  );
  if (sessionToken) headers.set("Authorization", `Bearer ${sessionToken}`);
  if (options.body && !(options.body instanceof FormData))
    headers.set("Content-Type", "application/json");
  let res: Response;
  try {
    res = await fetch(`/api${path}`, { ...options, headers });
  } catch (error) {
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
  if (sessionToken !== token()) {
    throw new ApiError(
      "Сессия изменилась. Обновите данные под текущим пользователем.",
      401,
      writing,
    );
  }
  if (!res.ok) {
    let error: any;
    try {
      error = await res.json();
    } catch {
      error = { detail: res.statusText };
    }
    if (sessionToken !== token())
      throw new ApiError("Сессия изменилась. Обновите данные.", 401, writing);
    if (res.status === 401 && path != "/auth/login")
      window.dispatchEvent(new Event("naryad:unauthorized"));
    const detail = error.detail;
    throw new ApiError(
      Array.isArray(detail)
        ? detail.map((v: any) => v.msg).join("; ")
        : typeof detail === "string"
          ? detail
          : `Ошибка запроса (${res.status})`,
      res.status,
      writing && res.status >= 500,
    );
  }
  if (res.status === 204) return undefined as T;
  try {
    const data = await res.json();
    if (sessionToken !== token())
      throw new ApiError("Сессия изменилась. Обновите данные.", 401, writing);
    return data as T;
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(
      "Ответ сервера не удалось прочитать. Проверьте результат обновлением.",
      res.status,
      writing,
    );
  }
}
export const post = <T>(path: string, body: any) =>
  api<T>(path, { method: "POST", body: JSON.stringify(body) });
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
