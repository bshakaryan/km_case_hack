import type { AssignmentRoster } from "./model";

export function AssignmentParticipants({
  assignment,
}: {
  assignment: AssignmentRoster;
}) {
  if (assignment.brigade_id == null) return null;
  const known = assignment.participants ?? [
    {
      employee_id: assignment.assignee_id,
      name: assignment.assignee_name,
      is_responsible: true,
      source: "legacy_snapshot" as const,
    },
  ];
  const legacy = assignment.participants_source !== "live";
  return (
    <section
      className="assignment-participants"
      aria-label="Состав бригадного назначения"
    >
      <h4>Участники назначения</h4>
      <ul>
        {known.map((member) => (
          <li key={member.employee_id}>
            {member.name || `Сотрудник #${member.employee_id}`}
            {member.is_responsible
              ? " · ответственный за общий результат"
              : " · участник"}
          </li>
        ))}
      </ul>
      <p className={legacy ? "history-uncertainty" : "field-hint"}>
        {legacy
          ? "Полный прежний состав неизвестен. Показаны только подтверждённые участники; текущий состав бригады не подставляется."
          : "Состав зафиксирован при назначении. Изменения справочника бригад не меняют это назначение."}
      </p>
    </section>
  );
}
