import type { Id, Order } from "./model";

export type JournalFilters = {
  search: string;
  area_id: string;
  equipment_id: string;
  assignee_id: string;
  brigade_id: string;
  priority: string;
  status: string;
  from_date: string;
  to_date: string;
  scope: "all" | "active" | "closed";
  focus: "all" | "overdue" | "emergency" | "issued" | "completed" | "rejected";
  sort: "newest" | "deadline" | "priority";
};
export type JournalContext = {
  assigneeId?: Id;
  equipmentId?: Id;
  areaId?: Id;
  brigadeId?: Id;
  fromDate?: string;
  toDate?: string;
  focus?: JournalFilters["focus"];
};
export type OrderPage = {
  items: Order[];
  next_cursor: string | null;
  total: number;
};
export type JournalState = OrderPage & {
  busy: boolean;
  error: string;
  changed: boolean;
  loaded: boolean;
};
export function journalFilters(
  context: JournalContext = {},
  scope: JournalFilters["scope"] = "active",
): JournalFilters {
  return {
    search: "",
    area_id: String(context.areaId ?? ""),
    equipment_id: String(context.equipmentId ?? ""),
    assignee_id: String(context.assigneeId ?? ""),
    brigade_id: String(context.brigadeId ?? ""),
    priority: "",
    status: "",
    from_date: context.fromDate ?? "",
    to_date: context.toDate ?? "",
    scope,
    focus: context.focus ?? "all",
    sort: "newest",
  };
}
export function journalQuery(filters: JournalFilters, fixedEquipmentId?: Id) {
  const query = new URLSearchParams({ limit: "100" });
  for (const [key, value] of Object.entries(filters)) {
    if (!value) continue;
    // Report drill-downs already contain exact UTC bounds. Date input edits
    // alone expand to the complete enterprise calendar day.
    query.set(
      key,
      /^(from_date|to_date)$/.test(key) && /^\d{4}-\d{2}-\d{2}$/.test(value)
        ? new Date(
            `${value}T${key === "to_date" ? "23:59:59.999" : "00:00:00"}+05:00`,
          ).toISOString()
        : value,
    );
  }
  if (fixedEquipmentId !== undefined)
    query.set("equipment_id", String(fixedEquipmentId));
  return query.toString();
}
export function canViewEquipmentHistory(role: string) {
  return ["master", "manager", "admin"].includes(role);
}

const emptyState = (): JournalState => ({
  items: [],
  next_cursor: null,
  total: 0,
  busy: false,
  error: "",
  changed: false,
  loaded: false,
});

/** A journal page never owns application workstations, order forms or drafts. */
export class JournalPager {
  state = emptyState();
  private generation = 0;
  private abort?: AbortController;
  private query = "";
  private ownerToken: string | null = null;
  private listeners = new Set<() => void>();
  private readonly fetchPage: (
    path: string,
    signal: AbortSignal,
  ) => Promise<OrderPage>;
  private readonly sessionToken: () => string | null;
  constructor(
    fetchPage: (path: string, signal: AbortSignal) => Promise<OrderPage>,
    sessionToken: () => string | null,
  ) {
    this.fetchPage = fetchPage;
    this.sessionToken = sessionToken;
  }
  subscribe(listener: () => void) {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }
  private publish(state: JournalState) {
    this.state = state;
    for (const listener of this.listeners) listener();
  }
  invalidate() {
    if (this.state.loaded && !this.state.changed)
      this.publish({ ...this.state, changed: true });
  }
  suspend() {
    ++this.generation;
    this.abort?.abort();
    if (this.state.busy) this.publish({ ...this.state, busy: false });
  }
  reset() {
    this.suspend();
    this.query = "";
    this.ownerToken = null;
    this.publish(emptyState());
  }
  restart(query: string) {
    const same =
      query === this.query && this.ownerToken === this.sessionToken();
    this.suspend();
    this.query = query;
    this.ownerToken = this.sessionToken();
    if (!same) this.publish(emptyState());
    return this.request(false);
  }
  loadMore() {
    if (this.state.busy || !this.state.next_cursor) return Promise.resolve();
    if (this.ownerToken !== this.sessionToken()) {
      this.reset();
      return Promise.resolve();
    }
    return this.request(true);
  }
  private async request(append: boolean) {
    const generation = ++this.generation;
    const capturedToken = this.ownerToken;
    if (!capturedToken) {
      this.reset();
      return;
    }
    const previous = this.state;
    const query = new URLSearchParams(this.query);
    if (append) query.set("cursor", previous.next_cursor!);
    const controller = new AbortController();
    this.abort = controller;
    const current = () =>
      generation === this.generation && capturedToken === this.sessionToken();
    this.publish({ ...previous, busy: true, error: "" });
    try {
      const page = await this.fetchPage(
        `/orders/page?${query}`,
        controller.signal,
      );
      if (!current()) return;
      if (
        !Array.isArray(page.items) ||
        !Number.isSafeInteger(page.total) ||
        page.total < 0 ||
        (page.next_cursor !== null && typeof page.next_cursor !== "string")
      )
        throw new Error(
          "Сервер вернул неполную страницу журнала. Обновите просмотр.",
        );
      const items = new Map<string, Order>();
      for (const order of [...(append ? previous.items : []), ...page.items]) {
        const old = items.get(String(order.id));
        if (!old || order.version >= old.version)
          items.set(String(order.id), order);
      }
      this.publish({
        ...page,
        items: [...items.values()],
        busy: false,
        error: "",
        changed: append ? this.state.changed : false,
        loaded: true,
      });
    } catch (error) {
      if (!current()) return;
      this.publish({
        ...previous,
        busy: false,
        error: (error as Error).message,
        changed: this.state.changed,
      });
    } finally {
      if (generation === this.generation) this.abort = undefined;
    }
  }
}
