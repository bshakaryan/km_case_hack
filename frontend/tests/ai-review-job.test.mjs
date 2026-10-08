import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

const require = createRequire(import.meta.url);
const viteRequire = createRequire(import.meta.resolve("vite"));
const { buildSync } = viteRequire("esbuild");
const compiled = buildSync({
  entryPoints: [
    fileURLToPath(new URL("../src/AiReviewJob.tsx", import.meta.url)),
  ],
  bundle: true,
  write: false,
  platform: "node",
  format: "cjs",
  packages: "external",
  jsx: "automatic",
}).outputFiles[0].text;
const loaded = { exports: {} };
new Function("require", "module", "exports", compiled)(
  require,
  loaded,
  loaded.exports,
);
const {
  AiJobStatus,
  showAiReview,
  canRetryAiReview,
  requestAiReviewRetry,
  applyAiReviewJob,
  aiReviewScoreLabel,
  aiReviewTitle,
  aiReviewVerdict,
  aiReviewExplanation,
  aiReviewSource,
  aiReviewNote,
  AiReportChecks,
  AiPhotoCheck,
} = loaded.exports;
const job = (status, overrides = {}) => ({
  id: 8,
  attempt_id: 2,
  status,
  provider: "stub",
  attempts: 3,
  max_attempts: 3,
  retry_allowed: status === "failed",
  last_error_code: "PRIVATE_PROVIDER_DIAGNOSTIC",
  ...overrides,
});
const order = {
  id: 9,
  version: 4,
  status: "completed",
  ai_review: { explanation: "OLD_RESULT" },
  ai_review_job: job("failed"),
  submission_attempts: [
    {
      id: 1,
      completion: { work_done: "FIRST_REPORT" },
      ai_review: { explanation: "FIRST_RESULT" },
    },
    {
      id: 2,
      completion: { work_done: "LATEST_REPORT" },
      ai_job: job("failed"),
      ai_review: null,
    },
  ],
};
const render = (props) =>
  renderToStaticMarkup(React.createElement(AiJobStatus, props));
const photoCheck = (status = "checked", overrides = {}) => ({
  status, method: "openai_vision", scope: "submission_selected_pair",
  before_id: 21, after_id: 22,
  vision: { same_equipment: true, defect_resolved: null, quality: "unknown",
    confidence: 0.5, issues: [], explanation: "По снимкам нельзя уверенно подтвердить результат.",
    visual_criteria: Object.fromEntries(["cleanliness", "fasteners", "guards", "leakage"]
      .map((name) => [name, { status: "not_assessable", observation: "" }])) },
  capture_time_status: "unknown", history_status: "not_checked",
  ...overrides,
});
const renderPhotos = (check) => renderToStaticMarkup(React.createElement(AiPhotoCheck, { check }));

test("formal report checks are separate and unavailable norms stay explicit", () => {
  const html = renderToStaticMarkup(React.createElement(AiReportChecks, {
    isOpenAi: true,
    checks: {
      work_description: "present", fault_code: "present",
      fault_code_vs_problem: "match", work_vs_fault_code: "unknown",
      materials_vs_norm: "unknown", time_vs_norm: "unknown",
      deadline: "unknown", after_photo: "present", after_photo_required: true,
    },
  }));
  assert.match(html, /Отчёт и формальные критерии/);
  assert.match(html, /Описание выполненных работ[\s\S]*Заполнено/);
  assert.match(html, /словарное совпадение/);
  assert.match(html, /эвристики/);
  assert.match(html, /нормы не доступны этой проверке/);
  assert.match(html, /время\/норматив не подтверждены/);
  assert.match(html, /Обязательно для внеплановой работы/);

  const historical = renderToStaticMarkup(React.createElement(AiReportChecks, { isOpenAi: true }));
  assert.match(historical, /Детальная сводка не сохранена/);
  assert.match(historical, /не пересчитывался/);
});

test("OpenAI photo result identifies the selected pair and preserves uncertainty", () => {
  const check = photoCheck();
  const html = renderPhotos(check);
  assert.match(html, /Визуальная проверка OpenAI/);
  assert.match(html, /до №21 · после №22/);
  assert.match(html, /Оборудование[\s\S]*Визуально похоже/);
  assert.match(html, /Общее впечатление по фото[\s\S]*недостаточно данных/);
  assert.match(html, /Чистота и мусор[\s\S]*Не видно или ракурс недостаточен/);
  assert.match(html, /Время съёмки, скрытое состояние и фото других нарядов не проверялись/);
  const review = { score: null, llm_used: true, source_verdict: "needs_master_review", photo_check: check };
  assert.match(aiReviewSource(review), /OpenAI Vision/);
  assert.match(aiReviewNote(review), /итоговую оценку и приёмку выполняет мастер/);
  assert.doesNotMatch(aiReviewNote(review), /Содержимое снимков не анализируется/);
  assert.equal(aiReviewScoreLabel(review.score, { photo_check: check, source_verdict: "needs_master_review" }), "Автоматический балл не выставляется");
});

test("OpenAI visual concerns remain advice and do not become a final verdict", () => {
  const html = renderPhotos(photoCheck("checked", {
    vision: { same_equipment: false, defect_resolved: false, quality: "poor", confidence: 0.8,
      issues: ["Дополнительная ржавчина на трубе."], explanation: "На фото после видны отдельные замечания.",
      visual_criteria: {
        cleanliness: { status: "issue_visible", observation: "Пятна на основании." },
        fasteners: { status: "not_assessable", observation: "" },
        guards: { status: "no_visible_issue", observation: "" },
        leakage: { status: "issue_visible", observation: "Видны масляные следы." },
      } },
  }));
  assert.match(html, /Оборудование[\s\S]*Визуально различается/);
  assert.match(html, /Видимый дефект[\s\S]*Признаки дефекта остаются/);
  assert.match(html, /Общее впечатление по фото[\s\S]*заметны существенные недостатки/);
  assert.match(html, /Чистота и мусор[\s\S]*Пятна на основании/);
  assert.match(html, /Дополнительные замечания[\s\S]*Дополнительная ржавчина на трубе/);
});

test("legacy local CV is labelled historical and missing-after stays explicit", () => {
  const legacy = photoCheck("checked", { method: "local_cv", duplicate_before: true,
    exact_duplicate_groups: [[21, 22]], equipment_status: "unknown", model_available: false });
  assert.match(aiReviewTitle({ photo_check: legacy }), /Историческая локальная проверка фото/);
  assert.match(renderPhotos(legacy), /Историческая локальная CV-проверка выполнена/);
  assert.match(renderPhotos(legacy), /прежнего локального модуля/);
  assert.doesNotMatch(renderPhotos(legacy), /Результат OpenAI/);

  const missing = photoCheck("no_after", { before_id: 21, after_id: null, vision: null });
  assert.match(renderPhotos(missing), /нет фото после выполнения/);
  assert.doesNotMatch(renderPhotos(missing), /фото проанализированы/);
  assert.equal(renderPhotos(undefined), "");
  assert.match(aiReviewNote({ is_stub: true }), /содержимое снимков не анализируется/);
});

test("a service job is a saved report awaiting a recommendation, not the local formal stub", () => {
  for (const status of ["pending", "running", "failed", "superseded"]) {
    const html = render({ job: job(status, { provider: "ai_service" }) });
    assert.match(html, /Проверка сдачи/);
    assert.match(html, /Окончательное решение принимает мастер/);
    assert.doesNotMatch(html, /Формальная проверка · демо|PRIVATE_PROVIDER_DIAGNOSTIC/);
    assert.doesNotMatch(html, /текст отчёта и правила|проверка изображений выполнена|Содержимое снимков не анализируется/);
    assert.equal(showAiReview(job(status, { provider: "ai_service" })), false);
  }
});

test("unknown scores never become zero or a blank scale, and valid scores retain the scale", () => {
  for (const value of [null, undefined, 0, NaN, Infinity, -1, 6, "4"])
    assert.equal(aiReviewScoreLabel(value), "Оценка не определена");
  assert.equal(aiReviewScoreLabel(4.5), "Предварительная оценка: 4,5 / 5");
  assert.equal(aiReviewScoreLabel(5), "Предварительная оценка: 5 / 5");
});

test("source metadata distinguishes rules from text models without making a final decision", () => {
  const review = {
    verdict: "needs_attention", score: null, is_stub: true,
    source_verdict: "needs_master_review", llm_used: false,
    is_recommendation: true, explanation: "Проверьте отчёт",
  };
  assert.equal(aiReviewTitle(review, job("succeeded", { provider: "ai_service" })), "Проверка сдачи");
  assert.equal(aiReviewVerdict(review), "Нужна проверка мастером");
  assert.match(aiReviewSource(review), /языковая модель не использовалась/);
  assert.match(aiReviewSource({ ...review, llm_used: true }), /текстовая модель и правила/);
  assert.match(aiReviewNote(review), /Содержимое снимков не анализируется/);
  assert.match(aiReviewNote(review), /Окончательное решение принимает мастер/);
  assert.equal(aiReviewSource({ verdict: "passed", score: 4.5, is_stub: true }), null);
  const legacy = { verdict: "passed", score: 4.5, is_stub: true, explanation: "Заглушка ИИ: legacy output" };
  assert.equal(aiReviewTitle(legacy), "Историческая формальная проверка");
  assert.equal(aiReviewVerdict(legacy), "Старая рекомендация: принять");
  assert.equal(aiReviewScoreLabel(legacy.score, legacy), "Сохранённая оценка старой проверки: 4,5 / 5");
  assert.doesNotMatch(aiReviewExplanation(legacy), /Заглушка ИИ/);
  assert.equal(aiReviewVerdict({ ...review, source_verdict: "accepted" }), "Рекомендовано принять");
  assert.equal(aiReviewVerdict({ ...review, source_verdict: "accepted_with_remarks" }), "Рекомендовано принять с замечаниями");
  assert.equal(aiReviewVerdict({ ...review, source_verdict: "needs_rework" }), "Рекомендована доработка");
});

test("pending and running preserve report confirmation without showing an old result", () => {
  for (const status of ["pending", "running"]) {
    const html = render({ job: job(status) });
    assert.match(html, /Отчёт сохранён на сервере/);
    assert.match(html, /Старая формальная проверка/);
    assert.doesNotMatch(html, /PRIVATE_PROVIDER_DIAGNOSTIC/);
    assert.equal(showAiReview(job(status)), false);
  }
});
test("failed job has a friendly message and retry is limited to the latest completed submission", () => {
  assert.match(
    render({ job: job("failed"), onRetry() {} }),
    /Повторить проверку/,
  );
  assert.doesNotMatch(
    render({ job: job("failed") }),
    /PRIVATE_PROVIDER_DIAGNOSTIC|Повторить проверку/,
  );
  for (const role of ["master", "admin"])
    assert.equal(canRetryAiReview(order, role), true);
  for (const role of ["worker", "manager"])
    assert.equal(canRetryAiReview(order, role), false);
  assert.equal(
    canRetryAiReview({ ...order, status: "ai_review" }, "master"),
    false,
  );
  assert.equal(
    canRetryAiReview(
      { ...order, ai_review_job: job("failed", { attempt_id: 1 }) },
      "master",
    ),
    false,
  );
  assert.equal(
    canRetryAiReview(
      { ...order, ai_review_job: job("failed", { retry_allowed: false }) },
      "master",
    ),
    false,
  );
  assert.equal(
    canRetryAiReview(
      {
        ...order,
        submission_attempts: [
          ...order.submission_attempts.slice(0, -1),
          { ...order.submission_attempts.at(-1), assessment_id: 33 },
        ],
      },
      "master",
    ),
    false,
  );
});
test("superseded checks do not act as current results and legacy snapshots remain compatible", () => {
  assert.match(
    render({ job: job("superseded") }),
    /больше не меняет текущий наряд/,
  );
  assert.equal(showAiReview(job("superseded")), false);
  assert.equal(showAiReview(job("failed")), false);
  assert.equal(showAiReview(job("succeeded")), true);
  assert.equal(showAiReview(undefined), true);
  assert.equal(render({}), "");
});
test("a late retry reply cannot replace a newer submission or its result", () => {
  const newer = {
    ...order,
    ai_review: { explanation: "NEWER_RESULT" },
    ai_review_job: job("succeeded", { attempt_id: 3 }),
    submission_attempts: [...order.submission_attempts, { id: 3, number: 3 }],
  };
  assert.equal(
    applyAiReviewJob(newer, {
      attempt_id: 2,
      ai_review: null,
      job: job("pending"),
    }),
    newer,
  );
  assert.equal(newer.ai_review.explanation, "NEWER_RESULT");
});
test("retry uses one authenticated POST and only replaces AI metadata for its attempt", async (t) => {
  const previousFetch = globalThis.fetch;
  const previousStorage = globalThis.localStorage;
  t.after(() => {
    globalThis.fetch = previousFetch;
    globalThis.localStorage = previousStorage;
  });
  globalThis.localStorage = { getItem: () => "synthetic-bearer" };
  const calls = [];
  const response = {
    attempt_id: 2,
    order_version: 5,
    ai_review: null,
    job: job("pending"),
  };
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return new Response(JSON.stringify(response), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  const pending = applyAiReviewJob(order, await requestAiReviewRetry(9, 2, 4));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "/api/orders/9/submissions/2/ai-review/retry");
  assert.equal(calls[0].options.method, "POST");
  assert.equal(
    calls[0].options.headers.get("Authorization"),
    "Bearer synthetic-bearer",
  );
  assert.equal(calls[0].options.headers.has("X-Client-Command-Id"), false);
  assert.equal(calls[0].options.headers.get("X-Expected-Order-Version"), "4");
  assert.equal(calls[0].options.body, "{}");
  assert.equal(pending.ai_review_job.status, "pending");
  assert.equal(pending.version, 5);
  assert.equal(pending.ai_review, null);
  assert.equal(
    pending.submission_attempts[0].ai_review.explanation,
    "FIRST_RESULT",
  );
  assert.equal(
    pending.submission_attempts[1].completion.work_done,
    "LATEST_REPORT",
  );
});
test("a late pending retry reply preserves an advanced result of the same submission", () => {
  const response = { attempt_id: 2, ai_review: null, job: job("pending") };
  for (const progressed of [
    { assessment_id: 33 },
    { ai_review: { explanation: "SAME_ATTEMPT_RESULT" } },
    { ai_job: job("succeeded") },
    { ai_job: job("running") },
    { ai_job: job("superseded") },
  ]) {
    const current = {
      ...order,
      submission_attempts: [
        order.submission_attempts[0],
        { ...order.submission_attempts[1], ...progressed },
      ],
    };
    assert.equal(applyAiReviewJob(current, response), current);
  }
});

test("unknown retry outcome is surfaced once without automatic replay", async (t) => {
  const previousFetch = globalThis.fetch;
  const previousStorage = globalThis.localStorage;
  t.after(() => {
    globalThis.fetch = previousFetch;
    globalThis.localStorage = previousStorage;
  });
  globalThis.localStorage = { getItem: () => "synthetic-bearer" };
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    throw new TypeError("Synthetic disconnect");
  };
  await assert.rejects(
    requestAiReviewRetry(9, 2, 4),
    (failure) => failure.requestMayHaveSucceeded === true,
  );
  assert.equal(calls, 1);
  assert.match(
    render({ job: job("failed"), onRetry() {}, uncertain: true }),
    /disabled=""/,
  );
});

test("a retry receipt for an older order version cannot restore an old job", () => {
  const current = { ...order, version: 6 };
  assert.equal(
    applyAiReviewJob(current, {
      attempt_id: 2,
      order_version: 5,
      ai_review: null,
      job: job("pending"),
    }),
    current,
  );
});

test("a retry success without a usable version remains an unknown write outcome", async (t) => {
  const previousFetch = globalThis.fetch;
  const previousStorage = globalThis.localStorage;
  t.after(() => {
    globalThis.fetch = previousFetch;
    globalThis.localStorage = previousStorage;
  });
  globalThis.localStorage = { getItem: () => "synthetic-bearer" };
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return Response.json({
      attempt_id: 2,
      ai_review: null,
      job: job("pending"),
    });
  };
  await assert.rejects(
    requestAiReviewRetry(9, 2, 4),
    (failure) => failure.requestMayHaveSucceeded === true,
  );
  assert.equal(calls, 1);
});
