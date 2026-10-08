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

test("pending and running preserve report confirmation without showing an old result", () => {
  for (const status of ["pending", "running"]) {
    const html = render({ job: job(status) });
    assert.match(html, /Отчёт сохранён на сервере/);
    assert.match(html, /Формальная проверка/);
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
  const response = { attempt_id: 2, ai_review: null, job: job("pending") };
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return new Response(JSON.stringify(response), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  const pending = applyAiReviewJob(order, await requestAiReviewRetry(9, 2));
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "/api/orders/9/submissions/2/ai-review/retry");
  assert.equal(calls[0].options.method, "POST");
  assert.equal(
    calls[0].options.headers.get("Authorization"),
    "Bearer synthetic-bearer",
  );
  assert.equal(calls[0].options.headers.has("X-Client-Command-Id"), false);
  assert.equal(calls[0].options.body, "{}");
  assert.equal(pending.ai_review_job.status, "pending");
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
    requestAiReviewRetry(9, 2),
    (failure) => failure.requestMayHaveSucceeded === true,
  );
  assert.equal(calls, 1);
  assert.match(
    render({ job: job("failed"), onRetry() {}, uncertain: true }),
    /disabled=""/,
  );
});
