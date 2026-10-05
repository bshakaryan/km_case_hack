import test from "node:test";
import assert from "node:assert/strict";
import {
  attentionCounts,
  shiftTeam,
  nextWorkAction,
  periodBoundary,
  periodInputDate,
  withinCreatedPeriod,
} from "../src/workspace.ts";

test("Analytics drill-down retains exact shift bounds rather than widening to whole days", () => {
  const from = "2026-10-05T15:00:00.000Z";
  const to = "2026-10-06T03:00:00.000Z";
  assert.equal(withinCreatedPeriod("2026-10-05T14:59:59Z", from, to), false);
  assert.equal(withinCreatedPeriod(from, from, to), true);
  assert.equal(withinCreatedPeriod(to, from, to), true);
  assert.equal(withinCreatedPeriod("2026-10-06T03:00:01Z", from, to), false);
  assert.equal(periodInputDate("2026-10-05T22:30:00Z"), "2026-10-06");
});

test("Manual dates include the full enterprise day in UTC+05", () => {
  assert.equal(
    periodBoundary("2026-10-06"),
    Date.parse("2026-10-05T19:00:00Z"),
  );
  assert.equal(
    withinCreatedPeriod("2026-10-06T18:59:59.999Z", "2026-10-06", "2026-10-06"),
    true,
  );
  assert.equal(
    withinCreatedPeriod("2026-10-06T19:00:00Z", "2026-10-06", "2026-10-06"),
    false,
  );
});

test("Attention groups overlap without turning overdue into a lifecycle status", () => {
  const orders = [
    { status: "issued", priority: "emergency", is_overdue: true },
    { status: "ai_review", priority: "high", is_overdue: false },
    { status: "rejected", priority: "normal", is_overdue: true },
    { status: "closed", priority: "emergency", is_overdue: false },
    { status: "cancelled", priority: "emergency", is_overdue: true },
  ];
  assert.deepEqual(attentionCounts(orders), {
    emergency: 1,
    overdue: 2,
    issued: 1,
    ai_review: 1,
    rejected: 1,
  });
  assert.equal(orders[0].status, "issued");
});
test("Free on-shift workers are visible first without mutating employee data", () => {
  const team = [
    { id: 1, role: "worker", on_shift: true, status: "busy", name: "А" },
    { id: 2, role: "worker", on_shift: false, status: "free", name: "Б" },
    { id: 3, role: "worker", on_shift: true, status: "free", name: "В" },
    { id: 4, role: "master", on_shift: true, status: "free", name: "Г" },
  ];
  assert.deepEqual(
    shiftTeam(team).map((e) => e.id),
    [3, 1, 2],
  );
  assert.deepEqual(
    team.map((e) => e.id),
    [1, 2, 3, 4],
  );
});
test("Next action distinguishes acceptance, execution and pause", () => {
  assert.equal(nextWorkAction("issued"), "Ответить на назначение");
  assert.equal(nextWorkAction("accepted"), "Перейти к выполнению");
  assert.equal(nextWorkAction("paused"), "Продолжить работу");
  assert.equal(nextWorkAction("ai_review"), "Открыть наряд");
});
