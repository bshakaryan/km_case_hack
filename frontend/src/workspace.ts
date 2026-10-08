import type { Employee, Order } from "./model";

// Drill-downs carry exact report bounds; date inputs carry enterprise calendar dates.
export function periodBoundary(value: string, end = false): number {
  return new Date(
    /^\d{4}-\d{2}-\d{2}$/.test(value)
      ? `${value}T${end ? "23:59:59.999" : "00:00:00"}+05:00`
      : value,
  ).getTime();
}
export function periodInputDate(value: string): string {
  if (!value || /^\d{4}-\d{2}-\d{2}$/.test(value)) return value;
  const milliseconds = periodBoundary(value);
  return Number.isFinite(milliseconds)
    ? new Date(milliseconds + 5 * 3600000).toISOString().slice(0, 10)
    : "";
}
export function withinCreatedPeriod(
  createdAt: string,
  from: string,
  to: string,
): boolean {
  const created = new Date(createdAt).getTime();
  return (
    (!from || created >= periodBoundary(from)) &&
    (!to || created <= periodBoundary(to, true))
  );
}

export type BoardFocus =
  "all" | "emergency" | "overdue" | "issued" | "completed" | "rejected";
export const isActive = (order: Order) =>
  !["closed", "cancelled"].includes(order.status);

export function attentionCounts(orders: Order[]) {
  const active = orders.filter(isActive);
  return {
    emergency: active.filter((order) => order.priority === "emergency").length,
    overdue: active.filter((order) => order.is_overdue).length,
    issued: active.filter((order) => order.status === "issued").length,
    completed: active.filter((order) => order.status === "completed").length,
    rejected: active.filter((order) => order.status === "rejected").length,
  };
}

export function shiftTeam(employees: Employee[]) {
  const rank: Record<string, number> = {
    free: 0,
    busy: 1,
    queued: 2,
    off_shift: 3,
  };
  return employees
    .filter((employee) => employee.role === "worker")
    .sort(
      (a, b) =>
        (a.on_shift ? 0 : 1) - (b.on_shift ? 0 : 1) ||
        (rank[a.status] ?? 3) - (rank[b.status] ?? 3) ||
        a.name.localeCompare(b.name, "ru"),
    );
}

export function nextWorkAction(status: string) {
  switch (status) {
    case "issued":
      return "Ответить на назначение";
    case "accepted":
    case "queued":
    case "rework":
      return "Перейти к выполнению";
    case "paused":
      return "Продолжить работу";
    case "in_progress":
      return "Открыть работу и отчёт";
    default:
      return "Открыть наряд";
  }
}

export type CompletionMaterialInput = {
  materialId: string;
  quantity: string;
};

export function completionValidationIssues(input: {
  workDone: string;
  faultCodeId: string;
  faultCodeIds: Array<string | number>;
  workType: string;
  hasAfterPhoto: boolean;
  materials: CompletionMaterialInput[];
  materialIds: Array<string | number>;
}): string[] {
  const issues: string[] = [];
  const workDoneLength = input.workDone.trim().length;
  if (workDoneLength < 10 || workDoneLength > 5000)
    issues.push("Опишите выполненные работы: от 10 до 5 000 символов.");
  if (
    !input.faultCodeId ||
    !input.faultCodeIds.some((id) => String(id) === input.faultCodeId)
  )
    issues.push("Выберите код неисправности.");
  if (input.workType === "unplanned" && !input.hasAfterPhoto)
    issues.push("Для внепланового ремонта добавьте фото «После выполнения».");
  if (input.materials.length > 100)
    issues.push("В отчёте можно указать не более 100 материалов.");

  const materialIds = input.materials.map((material) => material.materialId);
  if (
    new Set(materialIds.filter(Boolean)).size !==
    materialIds.filter(Boolean).length
  )
    issues.push(
      "Один и тот же материал укажите один раз, суммируя количество.",
    );
  if (input.materials.some((material) => !material.materialId))
    issues.push("Выберите материал в каждой добавленной строке.");
  else if (
    input.materials.some(
      (material) =>
        !input.materialIds.some((id) => String(id) === material.materialId),
    )
  )
    issues.push("Выбранный материал больше недоступен. Выберите его заново.");
  if (
    input.materials.some((material) => {
      const quantity = Number(material.quantity);
      return (
        !Number.isFinite(quantity) || quantity <= 0 || quantity > 1_000_000
      );
    })
  )
    issues.push(
      "Количество материала должно быть больше 0 и не превышать 1 000 000.",
    );
  return issues;
}
