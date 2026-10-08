import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import {
  assignmentEditChanges,
  brigadeWorkers,
  isAssignmentParticipant,
  workerOrderGroups,
  workerOrderPermissions,
} from "../src/brigade.ts";

const require = createRequire(import.meta.url);
const { buildSync } = createRequire(import.meta.resolve("vite"))("esbuild");
function load(path) {
  const module = { exports: {} };
  new Function(
    "require",
    "module",
    "exports",
    buildSync({
      entryPoints: [fileURLToPath(new URL(path, import.meta.url))],
      bundle: true,
      write: false,
      platform: "node",
      format: "cjs",
      packages: "external",
      jsx: "automatic",
    }).outputFiles[0].text,
  )(require, module, module.exports);
  return module.exports;
}
const { AssignmentParticipants } = load("../src/AssignmentParticipants.tsx");
const { WorkerOrderSections } = load("../src/WorkerOrderSections.tsx");
const order = (overrides = {}) => ({
  id: 20,
  number: "SYNTHETIC-BRIGADE",
  title: "Общая работа",
  assignee_id: 1,
  assignee_name: "Ответственный снимка",
  brigade_id: 7,
  priority: "normal",
  equipment_name: "Оборудование",
  area_name: "Участок",
  deadline: "2030-01-01T00:00:00Z",
  status: "in_progress",
  participants_source: "live",
  participants: [
    {
      employee_id: 1,
      name: "Ответственный снимка",
      is_responsible: true,
      source: "live",
    },
    {
      employee_id: 2,
      name: "Участник снимка",
      is_responsible: false,
      source: "live",
    },
  ],
  ...overrides,
});
test("snapshot participants can upload, while only the responsible worker controls work", () => {
  const live = order();
  assert.deepEqual(
    workerOrderPermissions(live, { id: "2", role: "worker", brigade_id: 99 }),
    { responsible: false, participant: true, canUpload: true },
  );
  assert.deepEqual(workerOrderPermissions(live, { id: 1, role: "worker" }), {
    responsible: true,
    participant: true,
    canUpload: true,
  });
  assert.deepEqual(
    workerOrderPermissions(live, { id: 3, role: "worker", brigade_id: 7 }),
    { responsible: false, participant: false, canUpload: false },
  );
  assert.deepEqual(workerOrderPermissions(live, { id: 2, role: "manager" }), {
    responsible: false,
    participant: false,
    canUpload: false,
  });
  for (const status of ["ai_review", "completed", "closed", "cancelled"])
    assert.equal(
      workerOrderPermissions(order({ status }), { id: 2, role: "worker" })
        .canUpload,
      false,
    );
});
test("older responses only recognize the saved assignee, and never reconstruct membership", () => {
  const legacy = order({
    participants: undefined,
    participants_source: undefined,
  });
  assert.equal(isAssignmentParticipant(legacy, 1), true);
  assert.equal(isAssignmentParticipant(legacy, 2), false);
  assert.equal(isAssignmentParticipant(order({ participants: [] }), 2), false);
});
test("assistant work stays outside the worker's personal task and queue", () => {
  const orders = [
    order(),
    order({ id: 21, assignee_id: 2, status: "in_progress" }),
    order({ id: 22, assignee_id: 2, status: "queued", queue_position: 2 }),
    order({ id: 23, assignee_id: 2, status: "queued", queue_position: 1 }),
    order({ id: 24, status: "closed" }),
    order({ id: 25, participants: undefined }),
    order({ id: 26, assignee_id: 2, status: "issued" }),
  ];
  const grouped = workerOrderGroups(orders, 2);
  assert.deepEqual(
    grouped.current.map(({ id }) => id),
    [21],
  );
  assert.deepEqual(
    grouped.queue.map(({ id }) => id),
    [23, 22],
  );
  assert.deepEqual(
    grouped.incoming.map(({ id }) => id),
    [26],
  );
  assert.deepEqual(
    grouped.assisting.map(({ id }) => id),
    [20],
  );
});
test("responsible choices contain only currently on-shift workers of the selected brigade", () => {
  const employees = [
    { id: 1, role: "worker", brigade_id: 7, on_shift: true },
    { id: 2, role: "worker", brigade_id: 7, on_shift: false },
    { id: 3, role: "worker", brigade_id: 8, on_shift: true },
    { id: 4, role: "master", brigade_id: 7, on_shift: true },
  ];
  assert.deepEqual(
    brigadeWorkers(employees, "7").map(({ id }) => id),
    [1],
  );
});
test("brigade leadership or deliberate roster renewal is always a full assignment", () => {
  const edit = {
    assignment: "brigade",
    assignee_id: "1",
    brigade_id: "7",
    responsible_id: "1",
    renew_assignment: false,
  };
  assert.deepEqual(assignmentEditChanges(order(), edit), {});
  assert.deepEqual(
    assignmentEditChanges(order(), { ...edit, responsible_id: "2" }),
    { brigade_id: "7", responsible_id: "2" },
  );
  assert.deepEqual(
    assignmentEditChanges(order(), { ...edit, responsible_id: "" }),
    { brigade_id: "7" },
  );
  assert.deepEqual(
    assignmentEditChanges(order(), { ...edit, renew_assignment: true }),
    { brigade_id: "7", responsible_id: "1" },
  );
  assert.deepEqual(
    assignmentEditChanges(order(), { ...edit, assignment: "employee" }),
    { assignee_id: "1" },
  );
});
test("roster rendering shows immutable names and uncertainty for older brigade records", () => {
  const render = (assignment) =>
    renderToStaticMarkup(
      React.createElement(AssignmentParticipants, { assignment }),
    );
  const live = render(order());
  assert.match(live, /Участник снимка/);
  assert.match(live, /ответственный за общий результат/);
  assert.match(live, /Состав зафиксирован при назначении/);
  const legacy = render(
    order({ participants_source: "legacy_snapshot", participants: undefined }),
  );
  assert.match(legacy, /Ответственный снимка/);
  assert.match(legacy, /Полный прежний состав неизвестен/);
  assert.doesNotMatch(legacy, /Участник снимка/);
  assert.equal(render(order({ brigade_id: null })), "");
});
test("worker UI labels participation separately and offers no takeover or completion for assistants", () => {
  const html = renderToStaticMarkup(
    React.createElement(WorkerOrderSections, {
      queue: [order({ status: "queued", queue_position: 1 })],
      assisting: [order()],
      onSelect() {},
    }),
  );
  assert.match(html, /Моя очередь/);
  assert.match(html, /Участие в бригадных нарядах/);
  assert.match(html, /Ответственный: Ответственный снимка/);
  assert.match(html, /Открыть общий наряд/);
  assert.doesNotMatch(html, /Завершить работу|Принять задание|Начать работу/);
});
