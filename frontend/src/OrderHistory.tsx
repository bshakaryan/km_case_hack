import { useState } from "react";
import { formatDate, number } from "./model";
import type { OrderDetail, RefItem, SubmissionAttempt } from "./model";
import { Photo } from "./ui";

function AttemptPhotos({ photos }: { photos: SubmissionAttempt["photos"] }) {
  const [open, setOpen] = useState(false);
  if (!photos.length) return <p className="muted">Связанных фотографий нет.</p>;
  return (
    <details
      className="history-photos"
      onToggle={(event) => setOpen(event.currentTarget.open)}
    >
      <summary>Фото, доступные при сдаче · {photos.length}</summary>
      {open && (
        <>
          <p className="muted">
            Набор на момент сдачи; снимки могут повторяться в следующих сдачах.
          </p>
          <div className="history-photo-grid">
            {photos.map((photo) => (
              <figure key={photo.id}>
                <Photo
                  url={photo.url}
                  alt={`Сдача: ${photo.kind === "before" ? "до ремонта" : "после ремонта"}`}
                />
                <figcaption>
                  {photo.kind === "before" ? "До ремонта" : "После ремонта"} ·{" "}
                  {photo.author_name}
                  <br />
                  {formatDate(photo.created_at, true)}
                </figcaption>
              </figure>
            ))}
          </div>
        </>
      )}
    </details>
  );
}

export function OrderHistory({
  order,
  faultCodes = [],
}: {
  order: OrderDetail;
  faultCodes?: RefItem[];
}) {
  const assignments = order.assignment_history ?? [];
  const attempts = order.submission_attempts ?? [];
  if (!assignments.length && !attempts.length) return null;
  return (
    <details className="order-history-versions">
      <summary>
        Сдачи и назначения · {attempts.length} / {assignments.length}
      </summary>
      <div className="history-versions-body">
        {assignments.length > 0 && (
          <section>
            <h4>История назначений</h4>
            {assignments.map((assignment) => (
              <article className="history-version" key={assignment.id}>
                <strong>
                  Назначение №{assignment.number} ·{" "}
                  {assignment.assignee_name || "Исполнитель не зафиксирован"}
                </strong>
                {assignment.source === "legacy_snapshot" && (
                  <p className="history-uncertainty">
                    Снимок прежних данных. Предыдущие назначения и границы
                    периода не восстановлены.
                  </p>
                )}
                <p>
                  {formatDate(assignment.assigned_at, true)} —{" "}
                  {assignment.ended_at
                    ? formatDate(assignment.ended_at, true)
                    : assignment.source === "legacy_snapshot"
                      ? "Окончание неизвестно"
                      : "Текущее назначение"}
                </p>
                <p className="muted">
                  Назначил: {assignment.assigned_by_name || "Не зафиксировано"}
                  {assignment.brigade_name &&
                    ` · Бригада: ${assignment.brigade_name}`}
                </p>
              </article>
            ))}
          </section>
        )}
        {attempts.length > 0 && (
          <section>
            <h4>Неизменяемые сдачи</h4>
            {attempts.map((attempt) => {
              const assignment = assignments.find(
                (item) => String(item.id) === String(attempt.assignment_id),
              );
              const fault = faultCodes.find(
                (item) =>
                  String(item.id) === String(attempt.completion.fault_code_id),
              );
              return (
                <details className="history-version" key={attempt.id}>
                  <summary>
                    Сдача №{attempt.number} ·{" "}
                    {attempt.submitted_at
                      ? formatDate(attempt.submitted_at, true)
                      : "Время не зафиксировано"}
                  </summary>
                  <p className="muted">
                    Автор: {attempt.author_name || "Не зафиксирован"} ·{" "}
                    {assignment
                      ? `Назначение №${assignment.number}`
                      : "Связь с назначением не установлена"}
                  </p>
                  {attempt.source === "legacy_snapshot" && (
                    <p className="history-uncertainty">
                      Снимок прежнего отчёта. Фото, расход и решения без
                      подтверждённой связи не отнесены к этой сдаче; расход в
                      прежнем отчёте мог быть общим за несколько сдач.
                    </p>
                  )}
                  <p className="history-report">
                    {attempt.completion.work_done ||
                      "Текст отчёта не сохранён."}
                  </p>
                  {attempt.completion.fault_code_id != null && (
                    <p className="muted">
                      Шифр неисправности:{" "}
                      {fault
                        ? `${fault.code} · ${fault.name}`
                        : `#${attempt.completion.fault_code_id} · шифр недоступен`}
                    </p>
                  )}
                  {attempt.completion.comment && (
                    <p>Комментарий исполнителя: {attempt.completion.comment}</p>
                  )}
                  {attempt.source === "legacy_snapshot" &&
                    !!attempt.completion.materials?.length && (
                      <>
                        <h5>Общий расход из прежнего отчёта</h5>
                        <p className="muted">
                          По отдельным сдачам не распределён.
                        </p>
                        <ul>
                          {attempt.completion.materials.map(
                            (material, index) => (
                              <li key={index}>
                                {material.name ||
                                  `Материал #${material.material_id}`}{" "}
                                · {number(material.quantity, 3)}{" "}
                                {material.unit || ""}
                              </li>
                            ),
                          )}
                        </ul>
                      </>
                    )}
                  <h5>Дополнительный расход этой сдачи</h5>
                  {attempt.materials.length ? (
                    <ul>
                      {attempt.materials.map((material) => (
                        <li key={material.id}>
                          {material.name} · {number(material.quantity, 3)}{" "}
                          {material.unit}
                          <br />
                          <span className="muted">
                            {material.author_name || "Автор не зафиксирован"} ·{" "}
                            {formatDate(material.created_at, true)}
                          </span>
                        </li>
                      ))}
                    </ul>
                  ) : (
                    <p className="muted">
                      {attempt.source === "legacy_snapshot"
                        ? "Связь расхода с этой сдачей неизвестна."
                        : "Материалы не списывались."}
                    </p>
                  )}
                  <AttemptPhotos photos={attempt.photos} />
                  {attempt.ai_review && (
                    <section className="history-assessment">
                      <h5>
                        {attempt.ai_review.is_stub
                          ? "Формальная проверка · демо"
                          : "Проверка ИИ"}
                      </h5>
                      <p>
                        {(
                          {
                            passed: "Принято",
                            needs_attention: "Принято с замечаниями",
                            rework: "Требует доработки",
                            needs_rework: "Требует доработки",
                          } as Record<string, string>
                        )[attempt.ai_review.verdict] ||
                          "Нужна проверка мастером"}{" "}
                        · предварительная оценка{" "}
                        {number(attempt.ai_review.score, 1)} / 5
                      </p>
                      <p>{attempt.ai_review.explanation}</p>
                      {attempt.ai_review.is_stub && (
                        <p className="muted">
                          Проверяется наличие фото; содержимое снимков не
                          анализируется.
                        </p>
                      )}
                    </section>
                  )}
                  <h5>Решения мастера</h5>
                  {attempt.decisions.length ? (
                    attempt.decisions.map((decision) => (
                      <div className="history-decision" key={decision.id}>
                        <strong>
                          {decision.action === "close"
                            ? "Принято мастером"
                            : "Возвращено на доработку"}
                          {decision.score != null &&
                            ` · ${number(decision.score, 1)} / 5`}
                        </strong>
                        <p className="muted">
                          {decision.actor_name} ·{" "}
                          {formatDate(decision.created_at, true)}
                        </p>
                        {decision.comment && <p>{decision.comment}</p>}
                      </div>
                    ))
                  ) : (
                    <p className="muted">
                      Решение для этой сдачи не зафиксировано.
                    </p>
                  )}
                </details>
              );
            })}
          </section>
        )}
      </div>
    </details>
  );
}
