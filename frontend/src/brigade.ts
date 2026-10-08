import type { AssignmentRoster, Id, Order, RefItem, User } from "./model";

export function isResponsible(
  order: Pick<AssignmentRoster, "assignee_id">,
  employeeId: Id,
) {
  return String(order.assignee_id) === String(employeeId);
}

export function isAssignmentParticipant(
  order: AssignmentRoster,
  employeeId: Id,
) {
  // Older responses have no roster: only their saved assignee is known.
  // Current brigade membership never grants access to a historic assignment.
  return order.participants === undefined
    ? isResponsible(order, employeeId)
    : order.participants.some(
        (member) => String(member.employee_id) === String(employeeId),
      );
}

export function workerOrderPermissions(order: Order, user: User) {
  const responsible = user.role === "worker" && isResponsible(order, user.id);
  const participant =
    user.role === "worker" && isAssignmentParticipant(order, user.id);
  return {
    responsible,
    participant,
    canUpload:
      participant &&
      !["ai_review", "completed", "closed", "cancelled"].includes(order.status),
  };
}

export function workerOrderGroups(orders: Order[], employeeId: Id) {
  const personal = orders.filter((order) => isResponsible(order, employeeId));
  return {
    current: personal.filter((order) =>
      ["in_progress", "paused"].includes(order.status),
    ),
    incoming: personal
      .filter((order) =>
        ["issued", "accepted", "rework"].includes(order.status),
      )
      .sort(
        (a, b) =>
          Number(b.priority === "emergency") -
          Number(a.priority === "emergency"),
      ),
    queue: personal
      .filter((order) => order.status === "queued")
      .sort(
        (a, b) =>
          (a.queue_position ?? Number.MAX_SAFE_INTEGER) -
          (b.queue_position ?? Number.MAX_SAFE_INTEGER),
      ),
    assisting: orders.filter(
      (order) =>
        order.brigade_id != null &&
        !isResponsible(order, employeeId) &&
        isAssignmentParticipant(order, employeeId) &&
        !["closed", "cancelled"].includes(order.status),
    ),
  };
}

export function brigadeWorkers(employees: RefItem[], brigadeId: string) {
  return employees.filter(
    (employee) =>
      employee.role === "worker" &&
      employee.on_shift === true &&
      String(employee.brigade_id) === brigadeId,
  );
}

export type AssignmentEdit = {
  assignment: string;
  assignee_id: string;
  brigade_id: string;
  responsible_id: string;
  renew_assignment: boolean;
};

export function assignmentEditChanges(
  order: AssignmentRoster,
  edit: AssignmentEdit,
): Record<string, Id> {
  if (edit.assignment === "employee") {
    if (
      order.brigade_id != null ||
      edit.assignee_id !== String(order.assignee_id) ||
      edit.renew_assignment
    )
      return { assignee_id: edit.assignee_id };
    return {};
  }
  if (
    order.brigade_id == null ||
    edit.brigade_id !== String(order.brigade_id) ||
    edit.responsible_id !== String(order.assignee_id) ||
    edit.renew_assignment
  ) {
    return {
      brigade_id: edit.brigade_id,
      ...(edit.responsible_id ? { responsible_id: edit.responsible_id } : {}),
    };
  }
  return {};
}
