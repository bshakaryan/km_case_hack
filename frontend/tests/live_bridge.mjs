// Opt in only against a seeded, disposable demo API. No browser UI is driven.
// Run together with mobile/integration_test/web_bridge_test.dart using the same
// BRIDGE_TITLE. This imports the actual web client and reaches API via Vite.
import assert from "node:assert/strict";
import { readFile, writeFile } from "node:fs/promises";
import { setTimeout as delay } from "node:timers/promises";
import { api, post, postOrder } from "../src/model.ts";

const base = new URL(process.env.LIVE_WEB_URL || "http://127.0.0.1:5174");
const title = process.env.BRIDGE_TITLE;
if (
  process.env.LIVE_DEMO !== "1" ||
  !title ||
  !["localhost", "127.0.0.1"].includes(base.hostname)
) {
  throw new Error(
    "Set LIVE_DEMO=1, BRIDGE_TITLE and a loopback LIVE_WEB_URL for a disposable demo server.",
  );
}
const storage = new Map();
globalThis.localStorage = {
  getItem: (key) => storage.get(key) || null,
  setItem: (key, value) => storage.set(key, value),
  removeItem: (key) => storage.delete(key),
};
globalThis.window = new EventTarget();
const httpFetch = globalThis.fetch.bind(globalThis);
globalThis.fetch = (path, options = {}) => {
  const url = new URL(path, base);
  assert.equal(url.origin, base.origin);
  return httpFetch(url, {
    ...options,
    signal: options.signal || AbortSignal.timeout(20000),
  });
};
const started = Date.now();
const report = {
  title,
  webClient: "frontend/src/model.ts",
  webOrigin: base.origin,
  scope:
    "Web API coordinator only; Android SDK PASS and exit 0 must be checked separately.",
  checks: [],
};
let order;
let finished = false;
function record(check, values = {}) {
  report.checks.push({ check, elapsedMs: Date.now() - started, ...values });
  console.log("WEB_BRIDGE " + JSON.stringify(report.checks.at(-1)));
}
async function waitOrder(description, predicate) {
  const until = Date.now() + 6 * 60000;
  while (Date.now() < until) {
    if (process.env.BRIDGE_NATIVE_LOG) {
      const nativeLog = await readFile(process.env.BRIDGE_NATIVE_LOG, "utf8");
      if (
        nativeLog.includes("BRIDGE_STEP TEARDOWN") &&
        !nativeLog.includes("BRIDGE_STEP PASS")
      )
        throw new Error(
          "Android test failed before PASS; cancelling only this coordinator's test order.",
        );
    }
    const detail = await api(`/orders/${order.id}`);
    assert.notEqual(
      detail.status,
      "cancelled",
      "The synthetic test order was cancelled.",
    );
    if (predicate(detail)) return detail;
    await delay(1000);
  }
  throw new Error(`Timed out waiting for Android: ${description}`);
}
try {
  const auth = await post("/auth/login", { login: "master", pin: "1234" });
  localStorage.setItem("naryad_token", auth.token);
  assert.equal(auth.user.role, "master");
  const reference = await api("/reference");
  const employee = (await api("/employees")).find(
    (item) => item.login === "worker2",
  );
  assert.ok(
    employee?.on_shift && !employee.current_order,
    "worker2 must have no current work; seeded orders are never changed.",
  );
  const equipment = reference.equipment[0];
  assert.equal(
    (await api(`/orders?search=${encodeURIComponent(title)}`)).length,
    0,
    "Use a fresh BRIDGE_TITLE.",
  );
  order = await post("/orders", {
    title,
    description:
      "Синтетическая проверка общего веб- и Android-сценария; оборудование фактически не ремонтируется.",
    work_type: "unplanned",
    area_id: equipment.area_id,
    equipment_id: equipment.id,
    assignee_id: employee.id,
    priority: "high",
    deadline: new Date(Date.now() + 2 * 3600000).toISOString(),
    normal_hours: 2,
    comment: "Автономный тест без физического телефона.",
  });
  assert.equal(order.status, "issued");
  record("web-created", { orderId: order.id, number: order.number });
  const first = await waitOrder(
    "first report",
    (detail) =>
      detail.status === "ai_review" &&
      detail.completion?.work_done.startsWith("BRIDGE_FIRST:"),
  );
  assert.equal(first.completion.materials.length, 1);
  assert.equal(first.completion.materials[0].quantity, 2);
  assert.ok(first.photos.some((photo) => photo.kind === "after"));
  record("android-first-report", {
    status: first.status,
    materialQuantity: 2,
    photoCount: first.photos.length,
  });
  // Let Android assert its submitted UI before an external transition arrives.
  await delay(10000);
  const returned = await postOrder(
    `/orders/${order.id}/transition`,
    first.version,
    {
      action: "rework",
      reason: "Учебная проверка: выполнить дополнительный контроль крепления.",
    },
  );
  assert.equal(returned.status, "rework");
  record("web-returned-for-rework");
  const second = await waitOrder(
    "revised report",
    (detail) =>
      detail.status === "ai_review" &&
      detail.completion?.work_done.startsWith("BRIDGE_REWORK:") &&
      detail.events.filter((event) => event.action === "complete").length === 2,
  );
  assert.equal(second.completion.materials[0].quantity, 3);
  record("android-revised-report", { materialQuantity: 3, attempts: 2 });
  await delay(10000);
  const closed = await postOrder(
    `/orders/${order.id}/transition`,
    second.version,
    {
      action: "close",
      score: 5,
    },
  );
  assert.equal(closed.status, "closed");
  assert.equal(closed.score, 5);
  assert.equal(closed.completion.materials[0].quantity, 3);
  const matches = await api(`/orders?search=${encodeURIComponent(title)}`);
  assert.equal(matches.length, 1, "One work order across both clients.");
  const actions = closed.events.map((event) => event.action);
  for (const action of [
    "issue",
    "accept",
    "start",
    "pause",
    "resume",
    "rework",
    "close",
  ])
    assert.ok(actions.includes(action), `Missing audited ${action}`);
  report.result = "web-api-passed";
  report.orderId = order.id;
  report.status = closed.status;
  report.score = closed.score;
  report.totalMaterialQuantity = 3;
  finished = true;
  record("web-closed", {
    status: closed.status,
    score: 5,
    materialQuantity: 3,
  });
  if (process.env.BRIDGE_REPORT)
    await writeFile(
      process.env.BRIDGE_REPORT,
      JSON.stringify(report, null, 2) + "\n",
    );
} finally {
  if (order && !finished) {
    try {
      const latest = await api(`/orders/${order.id}`);
      if (!["closed", "cancelled"].includes(latest.status))
        await postOrder(`/orders/${order.id}/transition`, latest.version, {
          action: "cancel",
          reason: "Очистка собственного незавершённого синтетического теста.",
        });
    } catch {
      /* Never retry a blind write after an ambiguous result. */
    }
  }
  if (localStorage.getItem("naryad_token")) {
    try {
      await post("/auth/logout", {});
    } catch {
      /* Session will expire on the demo server. */
    }
    localStorage.removeItem("naryad_token");
  }
}
