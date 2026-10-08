import type { AiReviewJob, AttemptAiReview, OrderDetail } from "./model";
import { confirmedOrderVersion, postOrder } from "./model";

export function showAiReview(job?: AiReviewJob | null) {
  return !job || job.status === "succeeded";
}

export function canRetryAiReview(order: OrderDetail, role: string) {
  const job = order.ai_review_job;
  const latest = order.submission_attempts?.at(-1);
  return (
    ["master", "admin"].includes(role) &&
    order.status === "completed" &&
    job?.status === "failed" &&
    job.retry_allowed &&
    !!latest &&
    latest.ai_review == null &&
    latest.assessment_id == null &&
    String(latest.id) === String(job.attempt_id)
  );
}

export async function requestAiReviewRetry(
  orderId: OrderDetail["id"],
  attemptId: AiReviewJob["attempt_id"],
  version: number,
) {
  const response = await postOrder<AttemptAiReview>(
    `/orders/${orderId}/submissions/${attemptId}/ai-review/retry`,
    version,
    {},
  );
  confirmedOrderVersion(response.order_version, version);
  return response;
}

export function applyAiReviewJob(
  order: OrderDetail,
  response: AttemptAiReview,
): OrderDetail {
  const latest = order.submission_attempts?.at(-1);
  if (response.order_version < order.version) return order;
  if (latest && String(latest.id) !== String(response.attempt_id)) return order;
  const advancedStates = ["running", "succeeded", "superseded"];
  if (
    response.job?.status === "pending" &&
    (order.status !== "completed" ||
      latest?.assessment_id != null ||
      latest?.ai_review != null ||
      advancedStates.includes(latest?.ai_job?.status || "") ||
      advancedStates.includes(order.ai_review_job?.status || ""))
  )
    return order;
  return {
    ...order,
    version: response.order_version ?? order.version,
    ai_review: response.ai_review,
    ai_review_job: response.job,
    submission_attempts: order.submission_attempts?.map((attempt) =>
      String(attempt.id) === String(response.attempt_id)
        ? { ...attempt, ai_job: response.job, ai_review: response.ai_review }
        : attempt,
    ),
  };
}

export function AiJobStatus({
  job,
  onRetry,
  busy = false,
  uncertain = false,
}: {
  job?: AiReviewJob | null;
  onRetry?: () => void;
  busy?: boolean;
  uncertain?: boolean;
}) {
  if (!job || job.status === "succeeded") return null;
  const title = {
    pending: "Проверка в очереди",
    running: "Проверка выполняется",
    failed: "Проверка не завершена",
    superseded: "Проверка прежней сдачи остановлена",
  }[job.status];
  return (
    <section className="ai-review ai-job-status" role="status">
      <h3>{title}</h3>
      <p>
        {job.status === "failed"
          ? "Отчёт сохранён на сервере. Нужна проверка мастера; результат проверки пока недоступен."
          : job.status === "superseded"
            ? "Эта проверка больше не меняет текущий наряд. Смотрите более новую сдачу."
            : "Отчёт сохранён на сервере. Результат появится после завершения проверки."}
      </p>
      <small>
        Формальная проверка · демо. Содержимое снимков не анализируется.
        Окончательное решение принимает мастер.
      </small>
      {uncertain && (
        <p>
          Результат повтора неизвестен. Обновите карточку перед повторной
          отправкой.
        </p>
      )}
      {onRetry && (
        <button
          type="button"
          className="button secondary"
          disabled={busy || uncertain}
          onClick={onRetry}
        >
          {busy ? "Отправляется…" : "Повторить проверку"}
        </button>
      )}
    </section>
  );
}
