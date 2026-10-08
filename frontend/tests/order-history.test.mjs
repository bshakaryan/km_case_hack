import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";

// Render the real TSX component in memory, using Vite's existing compiler.
// No browser, application server or production build is needed.
const require = createRequire(import.meta.url);
const viteRequire = createRequire(import.meta.resolve("vite"));
const { buildSync } = viteRequire("esbuild");
const compiled = buildSync({
  entryPoints: [
    new URL("../src/OrderHistory.tsx", import.meta.url).pathname.replace(
      /^\/(\w:)/,
      "$1",
    ),
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
const { OrderHistory } = loaded.exports;
const render = (order) =>
  renderToStaticMarkup(React.createElement(OrderHistory, { order }));
const assignment = {
  id: 10,
  number: 1,
  source: "live",
  assignee_name: "Первый работник",
  assigned_by_name: "Мастер",
  assigned_at: "2026-10-01T10:00:00Z",
  ended_at: null,
};
const attempt = (number, overrides = {}) => ({
  id: number,
  number,
  source: "live",
  assignment_id: 10,
  submitted_at: "2026-10-01T11:00:00Z",
  author_name: "Первый работник",
  completion: { work_done: `Самостоятельный отчёт ${number}` },
  materials: [
    {
      id: number,
      name: `Дополнительная деталь ${number}`,
      quantity: number,
      unit: "шт",
      author_name: "Первый работник",
      created_at: "2026-10-01T11:00:00Z",
    },
  ],
  photos: [
    {
      id: 90,
      kind: "after",
      url: "/api/photos/90",
      created_at: "2026-10-01T10:30:00Z",
      author_name: "Первый работник",
    },
  ],
  decisions: [
    {
      id: number,
      action: number === 1 ? "rework" : "close",
      actor_name: "Мастер",
      score: number === 1 ? null : 5,
      comment: `Решение по попытке ${number}`,
      created_at: "2026-10-01T12:00:00Z",
    },
  ],
  ...overrides,
});

test("old detail response without history remains compatible", () => {
  assert.equal(render({ completion: null }), "");
  assert.equal(render({ assignment_history: [], submission_attempts: [] }), "");
});

test("immutable attempts retain separate reports, extra expense, assessment and decisions", () => {
  const html = render({
    completion: {
      work_done: "Текущий общий отчёт",
      materials: [{ name: "Накопленный расход", quantity: 99 }],
    },
    assignment_history: [assignment],
    submission_attempts: [attempt(1), attempt(2)],
  });
  for (const value of [
    "Самостоятельный отчёт 1",
    "Самостоятельный отчёт 2",
    "Дополнительная деталь 1",
    "Дополнительная деталь 2",
    "Решение по попытке 1",
    "Решение по попытке 2",
    "Возвращено на доработку",
    "Принято мастером",
    "Фото, доступные при сдаче",
  ])
    assert.ok(html.includes(value), value);
  assert.ok(!html.includes("Накопленный расход"));
  assert.ok(!html.includes("Текущий общий отчёт"));
  assert.ok(html.indexOf("Сдача №1") < html.indexOf("Сдача №2"));
  assert.ok(
    html.includes("Фото, доступные при сдаче"),
  );
});

test("legacy snapshots expose uncertainty without assigning global photos or cumulative expense", () => {
  const html = render({
    status: "closed",
    photos: [{ id: 77, author_name: "Недоказанная связь" }],
    assignment_history: [
      { ...assignment, source: "legacy_snapshot", assigned_by_name: null },
    ],
    submission_attempts: [
      attempt(1, {
        source: "legacy_snapshot",
        author_name: null,
        assignment_id: null,
        submitted_at: null,
        completion: {
          work_done: "Старый сохранённый отчёт",
          materials: [
            {
              material_id: 1,
              name: "Прежний общий расход",
              quantity: 8,
              unit: "шт",
            },
          ],
        },
        materials: [],
        photos: [],
        decisions: [],
      }),
    ],
  });
  for (const value of [
    "Окончание неизвестно",
    "Время не зафиксировано",
    "Связь с назначением не установлена",
    "Общий расход из прежнего отчёта",
    "По отдельным сдачам не распределён",
    "Связь расхода с этой сдачей неизвестна",
    "Старый сохранённый отчёт",
  ])
    assert.ok(html.includes(value), value);
  assert.ok(!html.includes("Текущее назначение"));
  assert.ok(!html.includes("Недоказанная связь"));
});

test("assignment history retains each brigade roster independently of the current order", () => {
  const html = render({
    participants: [
      {
        employee_id: 99,
        name: "Новый участник",
        is_responsible: false,
        source: "live",
      },
    ],
    assignment_history: [
      {
        ...assignment,
        assignee_id: 1,
        brigade_id: 7,
        participants_source: "live",
        participants: [
          {
            employee_id: 1,
            name: "Исторический ответственный",
            is_responsible: true,
            source: "live",
          },
          {
            employee_id: 2,
            name: "Прежний участник",
            is_responsible: false,
            source: "live",
          },
        ],
      },
    ],
    submission_attempts: [],
  });
  assert.match(html, /Исторический ответственный/);
  assert.match(html, /Прежний участник/);
  assert.doesNotMatch(html, /Новый участник/);
});

test("immutable submission history shows the master's manual decision only", () => {
  const html = render({
    assignment_history: [],
    submission_attempts: [attempt(2)],
  });
  assert.match(html, /Решение по попытке 2/);
  assert.match(html, /Принято мастером/);
  assert.doesNotMatch(html, /Проверка сдачи|ИИ|OpenAI|заглушка/);
});
