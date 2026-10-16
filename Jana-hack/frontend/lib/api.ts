export interface Profile {
  id: number;
  email: string;
  full_name: string;
  role: "employee" | "manager" | "hr_admin";
  company: string;
  position: string;
  department: string;
  manager_id: number | null;
  manager_name: string | null;
  hire_date: string;
  leave_balance: number;
  data_source: "mock_zup" | "zup";
}

export type RequestStatus = "submitted" | "manager_approved" | "approved" | "rejected";
export interface LeaveRequest {
  id: number;
  employee_id: number;
  employee_name: string;
  type: "leave";
  start_date: string;
  end_date: string;
  days_count: number;
  excluded_dates: string[];
  calendar_version: string;
  zup_sync_status: "not_required" | "pending" | "synced" | "error" | "legacy";
  zup_reference: string | null;
  comment: string;
  status: RequestStatus;
  version: number;
  created_at: string;
  history: { status: RequestStatus; actor_name: string; comment: string; created_at: string }[];
}
export interface RequestDraft { start_date: string; end_date: string; comment: string }
export interface LeaveCalculation {
  start_date: string; end_date: string; days_count: number; calendar_days: number;
  excluded_dates: string[]; calendar_version: string; available_balance: number;
  balance_after: number; sufficient_balance: boolean; source: "mock_zup_http" | "zup_http";
}
export interface Notification {
  id: number; kind: string; title: string; body: string; read: boolean; created_at: string;
}
export interface Course {
  id: number; title: string; description: string; content: string; duration_minutes: number;
  progress: number; completed: boolean; question: string; options: string[];
}
export interface Knowledge { document_id: number; title: string; section: string; content: string }
export interface AssistantAnswer {
  answer: string; sources: Knowledge[]; escalate_to_hr: boolean; mode: "extractive_demo";
}
export interface AuditEntry {
  id: number; actor_id: number; action: string; entity_type: string; entity_id: number; created_at: string;
}

export class ApiError extends Error {
  constructor(message: string, public status: number) { super(message); this.name = "ApiError"; }
}

function detailMessage(detail: unknown): string | undefined {
  if (typeof detail === "string") return detail;
  if (Array.isArray(detail)) return detail.map((item) => {
    if (item && typeof item === "object" && "msg" in item) {
      const value = item as { loc?: unknown[]; msg: string };
      return `${value.loc?.filter((part) => part !== "body").join(" · ") || "Поле"}: ${value.msg}`;
    }
    return "Проверьте введённые данные";
  }).join(". ");
}

export class ApiClient {
  constructor(private token: string | null = null, private expired?: () => void) {}

  async call<T>(path: string, options: RequestInit = {}): Promise<T> {
    const headers = new Headers(options.headers);
    headers.set("Accept", "application/json");
    if (options.body) headers.set("Content-Type", "application/json");
    if (this.token) headers.set("Authorization", `Bearer ${this.token}`);
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 20_000);
    try {
      const base = (process.env.NEXT_PUBLIC_API_URL || "/api").replace(/\/$/, "");
      const response = await fetch(`${base}${path}`, {
        ...options, headers, signal: controller.signal, cache: "no-store", credentials: "omit",
      });
      if (response.status === 401) {
        this.expired?.();
        throw new ApiError(this.token ? "Сессия завершена. Войдите снова." : "Не удалось войти. Проверьте почту и пароль.", 401);
      }
      const body: unknown = await response.json().catch(() => null);
      if (!response.ok) {
        const detail = body && typeof body === "object" && "detail" in body ? body.detail : null;
        throw new ApiError(detailMessage(detail) || (response.status === 409
          ? "Данные уже изменились. Обновите их перед повторной попыткой."
          : `Сервер вернул ошибку ${response.status}. Попробуйте ещё раз.`), response.status);
      }
      if (body === null) throw new ApiError("Сервер вернул пустой ответ. Обновите данные.", 0);
      return body as T;
    } catch (error) {
      if (error instanceof ApiError) throw error;
      throw new ApiError(controller.signal.aborted
        ? "Сервер не ответил вовремя. Проверьте соединение и повторите запрос."
        : "Не удалось связаться с сервером. Проверьте соединение и повторите запрос.", 0);
    } finally { clearTimeout(timer); }
  }

  post<T>(path: string, body: unknown, headers?: HeadersInit): Promise<T> {
    return this.call(path, { method: "POST", body: JSON.stringify(body), headers });
  }
  patch<T>(path: string, body: unknown): Promise<T> {
    return this.call(path, { method: "PATCH", body: JSON.stringify(body) });
  }
}

export const errorMessage = (error: unknown) => error instanceof Error ? error.message : "Произошла ошибка. Попробуйте ещё раз.";
export const roleLabel: Record<Profile["role"], string> = { employee: "Сотрудник", manager: "Руководитель", hr_admin: "HR-администратор" };
export const statusLabel: Record<RequestStatus, string> = { submitted: "У руководителя", manager_approved: "На проверке HR", approved: "Согласовано", rejected: "Отклонено" };
export const date = (value: string, full = false) => new Intl.DateTimeFormat("ru-RU", {
  day: "numeric", month: full ? "long" : "short", year: "numeric", timeZone: "UTC",
}).format(new Date(value.length === 10 ? `${value}T00:00:00Z` : value));
export const dateTime = (value: string) => new Intl.DateTimeFormat("ru-RU", {
  day: "numeric", month: "short", hour: "2-digit", minute: "2-digit",
}).format(new Date(value));
export const initials = (name: string) => name.trim().split(/\s+/).slice(0, 2).map((word) => word[0]).join("").toUpperCase();
