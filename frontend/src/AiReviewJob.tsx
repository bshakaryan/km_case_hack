import type { AiReviewJob, AttemptAiReview, OrderDetail, SubmissionPhotoCheck } from "./model";
import { confirmedOrderVersion, number, postOrder } from "./model";

type Review = NonNullable<OrderDetail["ai_review"]>;

function isServiceReview(review: Review, job?: AiReviewJob | null) {
  return (
    job?.provider === "ai_service" ||
    review.source_verdict !== undefined ||
    typeof review.llm_used === "boolean"
  );
}

export function aiReviewTitle(review: Review, job?: AiReviewJob | null) {
  return isServiceReview(review, job)
    ? "Сервис проверки"
    : review.is_stub
      ? "Формальная проверка · демо"
      : "Проверка ИИ";
}

export function aiReviewScoreLabel(score: number | null | undefined) {
  return typeof score === "number" &&
    Number.isFinite(score) &&
    score >= 1 &&
    score <= 5
    ? `Предварительная оценка: ${number(score, 1)} / 5`
    : "Оценка не определена";
}

export function aiReviewVerdict(review: Review) {
  if (review.source_verdict) {
    return ({
      accepted: "Рекомендовано принять",
      accepted_with_remarks: "Рекомендовано принять с замечаниями",
      needs_rework: "Рекомендована доработка",
      needs_master_review: "Нужна проверка мастером",
    }[review.source_verdict] || "Нужна проверка мастером");
  }
  return (
    ({
      passed: "Принято",
      needs_attention: "Принято с замечаниями",
      rework: "Требует доработки",
      needs_rework: "Требует доработки",
    } as Record<string, string>)[review.verdict] ||
    "Нужна проверка мастером"
  );
}

export function aiReviewSource(review: Review) {
  const photos = review.photo_check?.status === "checked";
  return review.llm_used === true
    ? photos
      ? "Источник: текстовая модель, правила и локальная проверка фото"
      : "Источник: текстовая модель и правила"
    : review.llm_used === false
      ? photos
        ? "Источник: текст отчёта, правила и локальная проверка фото; языковая модель не использовалась"
        : "Источник: текст отчёта и правила; языковая модель не использовалась"
      : null;
}

export function aiReviewNote(review: Review, job?: AiReviewJob | null) {
  if (review.photo_check?.status === "checked") {
    return "Локальная проверка фото даёт технические признаки, а не подтверждение ремонта. Окончательное решение принимает мастер.";
  }
  if (review.photo_check?.status === "unavailable") {
    return "Проверка содержимого фото не завершена. Окончательное решение принимает мастер.";
  }
  if (review.photo_check?.status === "no_after") {
    return "Фото после выполнения отсутствует в этой сдаче. Окончательное решение принимает мастер.";
  }
  if (isServiceReview(review, job)) {
    return "Проверяются текст отчёта и правила. Содержимое снимков не анализируется. Окончательное решение принимает мастер.";
  }
  return review.is_stub
    ? "Проверяется наличие фото; содержимое снимков не анализируется. Окончательное решение принимает мастер."
    : "Окончательное решение принимает мастер.";
}

export function aiPhotoCheckLines(check?: SubmissionPhotoCheck | null) {
  if (!check || !["checked", "unavailable", "no_after"].includes(check.status)) return [];
  const lines = [
    check.status === "checked"
      ? "Локальная проверка изображений выполнена."
      : check.status === "no_after"
        ? "В сохранённых фото этой сдачи нет фото после выполнения."
        : "Локальная проверка изображений недоступна; вывод по содержимому не получен.",
  ];
  if (check.before_id != null || check.after_id != null) {
    lines.push(`Для сравнения выбраны фото этой сдачи: до ${check.before_id == null ? "не выбрано" : `№${check.before_id}`}; после ${check.after_id == null ? "не выбрано" : `№${check.after_id}`}.`);
  }
  if (check.status === "checked") {
    if (check.duplicate_before === true) {
      lines.push("В выбранной паре есть признаки повтора фото до ремонта; сверьте снимки вручную.");
    } else if (check.duplicate_before === false) {
      lines.push("В выбранной паре признаков повтора не найдено.");
    } else {
      lines.push("Признаки повтора относительно фото до не определены.");
    }
    lines.push(check.equipment_status === "different"
      ? "Возможно, на выбранных снимках разное оборудование; проверьте вручную."
      : "Совпадение оборудования не подтверждено.");
    if (!check.model_available) {
      lines.push("Модель сравнения оборудования недоступна.");
    }
  }
  const duplicates = check.exact_duplicate_groups.length;
  if (duplicates > 0) {
    lines.push(`В сохранённых фото этой сдачи есть группы полностью одинаковых файлов: ${duplicates}.`);
  } else if (check.status === "checked") {
    lines.push("Полностью одинаковые файлы среди фото этой сдачи не найдены.");
  }
  lines.push("Качество ремонта и время съёмки не подтверждены. Фото других нарядов и сдач не проверялись.");
  return lines;
}

export function AiPhotoCheck({ check }: { check?: SubmissionPhotoCheck | null }) {
  const lines = aiPhotoCheckLines(check);
  if (!lines.length) return null;
  return (
    <div className="history-assessment">
      <h4>Результат проверки фото</h4>
      {lines.map((line) => <p key={line}>{line}</p>)}
    </div>
  );
}

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
        {job.provider === "ai_service"
          ? "Сервис проверки · рекомендация. Окончательное решение принимает мастер."
          : "Формальная проверка · демо. Содержимое снимков не анализируется. Окончательное решение принимает мастер."}
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
