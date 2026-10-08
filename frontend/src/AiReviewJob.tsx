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
  if (review.photo_check?.method === "openai_vision") return "Проверка OpenAI";
  if (review.photo_check?.method === "local_cv") return "Историческая локальная проверка фото";
  return isServiceReview(review, job)
    ? "Проверка сдачи"
    : review.is_stub
      ? "Историческая формальная проверка"
      : "Проверка ИИ";
}

export function aiReviewScoreLabel(
  score: number | null | undefined,
  review?: Review,
) {
  if (
    review?.photo_check?.method === "openai_vision" &&
    review.source_verdict === "needs_master_review"
  ) return "Автоматический балл не выставляется";
  return typeof score === "number" &&
    Number.isFinite(score) &&
    score >= 1 &&
    score <= 5
    ? review?.is_stub && !isServiceReview(review)
      ? `Сохранённая оценка старой проверки: ${number(score, 1)} / 5`
      : `Предварительная оценка: ${number(score, 1)} / 5`
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
  if (review.is_stub) {
    return ({
      passed: "Старая рекомендация: принять",
      needs_attention: "Старая рекомендация: проверить мастеру",
      rework: "Старая рекомендация: доработка",
      needs_rework: "Старая рекомендация: доработка",
    } as Record<string, string>)[review.verdict] || "Старый результат формальной проверки";
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

export function aiReviewExplanation(review: Review, job?: AiReviewJob | null) {
  if (review.photo_check?.method === "openai_vision") {
    return "Ниже отдельно показаны формальные проверки отчёта и визуальные признаки выбранных фото.";
  }
  return review.is_stub && !isServiceReview(review, job)
    ? "Сохранённый результат прежнего формального режима: проверялись поля отчёта и наличие фотографий, содержимое изображений не анализировалось. Локальный модуль для этой сдачи не запускался; запись не пересчитывалась."
    : review.explanation;
}

export function aiReviewSource(review: Review) {
  const photos = review.photo_check?.status === "checked";
  if (review.photo_check?.method === "openai_vision" && photos) {
    return "Фото: OpenAI Vision · отчёт: формальные правила сервера";
  }
  if (review.photo_check?.method === "local_cv") {
    return "Источник: сохранённый результат прежней локальной CV-проверки; повторно не запускалась";
  }
  return review.llm_used === true
    ? photos
      ? "Источник: текстовая модель и правила"
      : "Источник: текстовая модель и правила"
    : review.llm_used === false
      ? photos
        ? "Источник: текст отчёта, правила и локальная проверка фото; языковая модель не использовалась"
        : "Источник: текст отчёта и правила; языковая модель не использовалась"
      : null;
}

export function aiReviewNote(review: Review, job?: AiReviewJob | null) {
  if (review.photo_check?.status === "checked") {
    if (review.photo_check.method === "openai_vision") {
      return "Результат по фото — только рекомендация; итоговую оценку и приёмку выполняет мастер.";
    }
    return "Это сохранённый результат прежней локальной проверки фото; модуль больше не используется для новых сдач. Окончательное решение принимает мастер.";
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
  if (review.is_stub) {
    return "Это исторический результат прежней проверки; содержимое снимков не анализируется и запись не пересчитывалась. Окончательное решение принимает мастер.";
  }
  return "Окончательное решение принимает мастер.";
}

export function aiPhotoCheckLines(check?: SubmissionPhotoCheck | null) {
  if (!check || !["checked", "unavailable", "no_after"].includes(check.status)) return [];
  const lines = [
    check.status === "checked"
      ? check.method === "openai_vision"
        ? "Выбранные фото проанализированы OpenAI Vision."
        : "Историческая локальная CV-проверка выполнена."
      : check.status === "no_after"
        ? "В сохранённых фото этой сдачи нет фото после выполнения."
        : check.method === "local_cv"
          ? "Старая локальная проверка изображений была недоступна; запись не пересчитывалась."
          : "Проверка изображений недоступна; вывод по содержимому не получен.",
  ];
  if (check.before_id != null || check.after_id != null) {
    lines.push(`Для сравнения выбраны фото этой сдачи: до ${check.before_id == null ? "не выбрано" : `№${check.before_id}`}; после ${check.after_id == null ? "не выбрано" : `№${check.after_id}`}.`);
  }
  if (check.status === "checked") {
    if (check.method === "openai_vision" && check.vision) {
      const vision = check.vision;
      lines.push(`Оборудование: ${equipmentStatus(vision.same_equipment)}.`);
      lines.push(`Видимый дефект: ${defectStatus(vision.defect_resolved)}.`);
      lines.push(`Общее впечатление по фото: ${qualityStatus(vision.quality)}.`);
      for (const [label, criterion] of visualCriterionRows(vision.visual_criteria)) {
        lines.push(`${label}: ${criterion.value}${criterion.observation ? ` — ${criterion.observation}` : ""}.`);
      }
      if (vision.explanation) lines.push(vision.explanation);
      lines.push(...vision.issues.map((issue) => `Замечание: ${issue}`));
    } else {
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
      if (!check.model_available) lines.push("Модель сравнения оборудования недоступна.");
    }
  }
  if (check.method === "local_cv") {
    const duplicates = check.exact_duplicate_groups?.length ?? 0;
    if (duplicates > 0) {
      lines.push(`В сохранённых фото этой сдачи есть группы полностью одинаковых файлов: ${duplicates}.`);
    } else if (check.status === "checked") {
      lines.push("Полностью одинаковые файлы среди фото этой сдачи не найдены.");
    }
  }
  lines.push(check.method === "openai_vision" && check.status === "checked"
    ? "Проверены только видимые признаки выбранной пары. Факт и скрытое качество ремонта, время съёмки и фото других нарядов не проверялись."
    : check.method === "local_cv"
      ? "Это сохранённый результат прежнего локального модуля; он не подтверждает факт и качество ремонта или время съёмки. Запись не пересчитывалась."
      : "Фото других нарядов и сдач не проверялись. Окончательное решение принимает мастер.");
  return lines;
}

function equipmentStatus(value: boolean | null) {
  return value === true ? "Визуально похоже" : value === false ? "Визуально различается" : "Не удалось сопоставить";
}

function defectStatus(value: boolean | null) {
  return value === true ? "Прежний дефект не виден после" : value === false ? "Признаки дефекта остаются" : "По снимкам не определить";
}

function qualityStatus(value: string) {
  return ({
    excellent: "без видимых замечаний",
    good: "в целом приемлемо по видимым признакам",
    mixed: "есть и положительные признаки, и замечания",
    poor: "заметны существенные недостатки",
    critical: "заметны выраженные недостатки",
    unknown: "недостаточно данных",
  } as Record<string, string>)[value] || "недостаточно данных";
}

const visualCriterionLabels = {
  cleanliness: "Чистота и мусор",
  fasteners: "Крепления и опоры",
  guards: "Кожухи и ограждения",
  leakage: "Видимые следы жидкости",
};

function visualCriterionRows(criteria: NonNullable<SubmissionPhotoCheck["vision"]>["visual_criteria"]) {
  if (!criteria || typeof criteria !== "object") return [] as [string, { value: string; observation: string }][];
  const statuses: Record<string, string> = {
    no_visible_issue: "Явного замечания не видно",
    issue_visible: "Есть видимое замечание",
    not_assessable: "Не видно или ракурс недостаточен",
  };
  return Object.entries(visualCriterionLabels).flatMap(([key, label]) => {
    const criterion = (criteria as Record<string, { status?: string; observation?: string } | null>)[key];
    if (!criterion || typeof criterion !== "object") return [];
    return [[label, {
      value: statuses[criterion.status || ""] || "Не оценено",
      observation: typeof criterion.observation === "string" ? criterion.observation : "",
    }] as [string, { value: string; observation: string }]];
  });
}

export function aiReportCheckRows(checks: Review["report_checks"]) {
  if (!checks) return [] as { label: string; value: string; detail?: string }[];
  const fields = (value: string) => value === "present" ? "Заполнено" : "Отсутствует";
  const match = (value: string, positive: string) => value === "match"
    ? positive : value === "mismatch" ? "Не совпало по словарному правилу" : "Не определено";
  const materials = ({
    within_norm: "В пределах доступных норм",
    issue: "Нужна сверка с нормой",
    missing: "Расход не указан при наличии нормы",
    unknown: "Не оценено: нормы не доступны этой проверке",
  } as Record<string, string>)[checks.materials_vs_norm];
  const timing = ({
    within_norm: "В пределах норматива",
    over_norm: "Выше норматива",
    unknown: "Не оценено: время/норматив не подтверждены",
  } as Record<string, string>)[checks.time_vs_norm];
  const deadline = ({
    on_time: "Срок соблюдён",
    late: "Сдано после срока",
    unknown: "Срок не определён",
  } as Record<string, string>)[checks.deadline];
  return [
    { label: "Описание выполненных работ", value: fields(checks.work_description) },
    { label: "Код неисправности", value: fields(checks.fault_code) },
    { label: "Код ↔ описание неисправности", value: match(checks.fault_code_vs_problem, "Есть словарное совпадение"), detail: "Эвристика по словам, не семантический вывод модели." },
    { label: "Работы ↔ код неисправности", value: match(checks.work_vs_fault_code, "Есть словарное совпадение"), detail: "Эвристика по тексту отчёта, не подтверждение факта ремонта." },
    { label: "Материалы ↔ нормы", value: materials },
    { label: "Время ↔ норматив", value: timing },
    { label: "Срок сдачи", value: deadline },
    { label: "Фото после", value: checks.after_photo === "present" ? "Есть" : "Нет", detail: checks.after_photo_required ? "Обязательно для внеплановой работы." : "Для этого типа работы сервер не требует фото после." },
  ];
}

export function AiReportChecks({ checks, isOpenAi = false }: { checks?: Review["report_checks"]; isOpenAi?: boolean }) {
  const rows = aiReportCheckRows(checks);
  if (!rows.length && !isOpenAi) return null;
  return (
    <section className="ai-check-section">
      <h4>Отчёт и формальные критерии</h4>
      {!rows.length ? (
        <p className="muted">Детальная сводка не сохранена в этой старой проверке; результат не пересчитывался.</p>
      ) : (
        <>
      <p className="muted">Текст отчёта не отправлялся в OpenAI. Совпадения слов — только эвристики.</p>
      <div className="ai-check-grid">
        {rows.map((row) => (
          <div className="ai-check-row" key={row.label}>
            <strong>{row.label}</strong>
            <div><span>{row.value}</span>{row.detail && <small>{row.detail}</small>}</div>
          </div>
        ))}
      </div>
        </>
      )}
    </section>
  );
}

export function AiPhotoCheck({ check }: { check?: SubmissionPhotoCheck | null }) {
  if (check?.status === "checked" && check.method === "openai_vision" && check.vision) {
    const vision = check.vision;
    const criteria = visualCriterionRows(vision.visual_criteria);
    const before = check.before_id == null ? "не выбрано" : `№${check.before_id}`;
    const after = check.after_id == null ? "не выбрано" : `№${check.after_id}`;
    return (
      <section className="ai-check-section">
        <h4>Визуальная проверка OpenAI</h4>
        <p className="muted">Пара этой сдачи: до {before} · после {after}</p>
        <div className="ai-check-grid">
          <div className="ai-check-row"><strong>Оборудование</strong><span>{equipmentStatus(vision.same_equipment)}</span></div>
          <div className="ai-check-row"><strong>Видимый дефект</strong><span>{defectStatus(vision.defect_resolved)}</span></div>
          <div className="ai-check-row"><strong>Общее впечатление по фото</strong><span>{qualityStatus(vision.quality)}</span></div>
          {criteria.length ? criteria.map(([label, criterion]) => (
            <div className="ai-check-row" key={label}>
              <strong>{label}</strong>
              <div><span>{criterion.value}</span>{criterion.observation && <small>{criterion.observation}</small>}</div>
            </div>
          )) : (
            <div className="ai-check-row"><strong>Чистота, крепления, кожухи и потёки</strong><span>Отдельный чек-лист отсутствует в сохранённой версии результата</span></div>
          )}
        </div>
        {vision.explanation && <p><strong>Краткое пояснение:</strong> {vision.explanation}</p>}
        {vision.issues.length > 0 && <div><strong>Дополнительные замечания</strong><ul>{vision.issues.map((issue, index) => <li key={`${index}-${issue}`}>{issue}</li>)}</ul></div>}
        <p className="muted">Только видимые признаки выбранных фото. Время съёмки, скрытое состояние и фото других нарядов не проверялись.</p>
      </section>
    );
  }
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
          ? "Проверка сдачи с OpenAI Vision · рекомендация. Окончательное решение принимает мастер."
          : "Старая формальная проверка · демо. Содержимое снимков не анализируется. Окончательное решение принимает мастер."}
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
