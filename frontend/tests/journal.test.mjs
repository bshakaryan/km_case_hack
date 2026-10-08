import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import {
  JournalPager,
  canViewEquipmentHistory,
  journalFilters,
  journalQuery,
} from "../src/journal.ts";

const order = (id, version = 1) => ({ id, version, number: `SYNTHETIC-${id}` });
const page = (items, next_cursor = null, total = items.length) => ({
  items,
  next_cursor,
  total,
});
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((a, b) => {
    resolve = a;
    reject = b;
  });
  return { promise, resolve, reject };
};
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
const { EquipmentHistory } = load("../src/EquipmentHistory.tsx");
const { Modal } = load("../src/ui.tsx");

test("journal carries all server filters and exact successful analytics bounds", () => {
  const filters = journalFilters(
    {
      assigneeId: 9,
      equipmentId: 8,
      areaId: 7,
      brigadeId: 6,
      fromDate: "2026-10-07T15:00:00.000Z",
      toDate: "2026-10-08T03:00:00.000Z",
      focus: "all",
    },
    "all",
  );
  const params = new URLSearchParams(
    journalQuery({
      ...filters,
      search: "БРИГАДА %_",
      priority: "high",
      status: "closed",
      sort: "deadline",
    }),
  );
  assert.equal(params.get("limit"), "100");
  for (const [key, value] of Object.entries({
    assignee_id: "9",
    equipment_id: "8",
    area_id: "7",
    brigade_id: "6",
    from_date: filters.from_date,
    to_date: filters.to_date,
    scope: "all",
    focus: "all",
    sort: "deadline",
    search: "БРИГАДА %_",
    priority: "high",
    status: "closed",
  }))
    assert.equal(params.get(key), value, key);
});
test("only edited calendar dates expand to the enterprise day; equipment history has no default dates", () => {
  const params = new URLSearchParams(
    journalQuery({
      ...journalFilters({}, "all"),
      from_date: "2026-10-08",
      to_date: "2026-10-08",
    }),
  );
  assert.equal(params.get("from_date"), "2026-10-07T19:00:00.000Z");
  assert.equal(params.get("to_date"), "2026-10-08T18:59:59.999Z");
  const equipment = new URLSearchParams(
    journalQuery({ ...journalFilters({}, "all"), equipment_id: "99" }, 8),
  );
  assert.equal(equipment.get("equipment_id"), "8");
  assert.equal(equipment.get("scope"), "all");
  assert.equal(equipment.has("from_date"), false);
  assert.equal(equipment.has("to_date"), false);
});
test("load-more sends the cursor, deduplicates live rows and retains the newer known version", async () => {
  const paths = [];
  const pager = new JournalPager(
    async (path) => {
      paths.push(path);
      return paths.length === 1
        ? page([order(1, 4), order(2)], "SYNTHETIC_CURSOR", 4)
        : page([order(2, 2), order(1, 3), order(3)], null, 3);
    },
    () => "SYNTHETIC_SESSION",
  );
  const query = journalQuery(journalFilters());
  await pager.restart(query);
  pager.invalidate();
  await pager.loadMore();
  assert.equal(
    new URL(paths[1], "https://synthetic.example").searchParams.get("cursor"),
    "SYNTHETIC_CURSOR",
  );
  assert.deepEqual(
    pager.state.items.map(({ id }) => id),
    [1, 2, 3],
  );
  assert.deepEqual(
    pager.state.items.map(({ version }) => version),
    [4, 2, 1],
  );
  assert.equal(pager.state.total, 3);
  assert.equal(pager.state.changed, true);
  assert.equal(pager.state.next_cursor, null);
  await pager.restart(query);
  assert.equal(
    new URL(paths[2], "https://synthetic.example").searchParams.has("cursor"),
    false,
  );
  assert.equal(pager.state.changed, false);
});
test("late responses from replaced queries cannot overwrite the current page even if fetch ignores abort", async () => {
  const first = deferred(),
    second = deferred();
  const signals = [];
  const pager = new JournalPager(
    (_path, signal) => {
      signals.push(signal);
      return signals.length === 1 ? first.promise : second.promise;
    },
    () => "SYNTHETIC_SESSION",
  );
  const old = pager.restart("scope=active"),
    current = pager.restart("scope=closed");
  assert.equal(signals[0].aborted, true);
  second.resolve(page([order(2)]));
  await current;
  first.resolve(page([order(1)]));
  await old;
  assert.deepEqual(
    pager.state.items.map(({ id }) => id),
    [2],
  );
  assert.equal(pager.state.busy, false);
});
test("both failed refresh and failed next page retain the last successful page and cursor", async () => {
  let fail = false;
  const pager = new JournalPager(
    async () => {
      if (fail) throw new Error("SYNTHETIC_OFFLINE");
      return page([order(1)], "SYNTHETIC_CURSOR", 2);
    },
    () => "SYNTHETIC_SESSION",
  );
  await pager.restart("scope=all");
  fail = true;
  await pager.loadMore();
  assert.deepEqual(
    pager.state.items.map(({ id }) => id),
    [1],
  );
  assert.equal(pager.state.next_cursor, "SYNTHETIC_CURSOR");
  await pager.restart("scope=all");
  assert.deepEqual(
    pager.state.items.map(({ id }) => id),
    [1],
  );
  assert.equal(pager.state.loaded, true);
  assert.equal(pager.state.busy, false);
  assert.equal(pager.state.error, "SYNTHETIC_OFFLINE");
});
test("session change rejects stale results and forbids continuing a cursor bound to the old login", async () => {
  let session = "SYNTHETIC_FIRST";
  const pending = deferred();
  const pager = new JournalPager(
    async () => pending.promise,
    () => session,
  );
  const load = pager.restart("scope=all");
  session = "SYNTHETIC_SECOND";
  pending.resolve(page([order(1)], "OLD_SESSION_CURSOR", 2));
  await load;
  assert.equal(pager.state.items.length, 0);
  await pager.restart("scope=all");
  assert.equal(pager.state.items.length, 1);
  session = "SYNTHETIC_THIRD";
  await pager.loadMore();
  assert.equal(pager.state.items.length, 0);
  assert.equal(pager.state.next_cursor, null);
});
test("suspending a hidden history keeps its loaded page and ignores a pending late append", async () => {
  const next = deferred();
  let calls = 0;
  const pager = new JournalPager(
    async () =>
      ++calls === 1 ? page([order(1)], "SYNTHETIC_CURSOR", 2) : next.promise,
    () => "SYNTHETIC_SESSION",
  );
  await pager.restart("equipment_id=8&scope=all");
  const loading = pager.loadMore();
  pager.suspend();
  next.resolve(page([order(2)], null, 2));
  await loading;
  assert.deepEqual(
    pager.state.items.map(({ id }) => id),
    [1],
  );
  assert.equal(pager.state.next_cursor, "SYNTHETIC_CURSOR");
  assert.equal(pager.state.busy, false);
});
test("workers have only authorized order history and no full equipment metadata panel", () => {
  for (const role of ["master", "manager", "admin"])
    assert.equal(canViewEquipmentHistory(role), true);
  for (const role of ["worker", "unknown"])
    assert.equal(canViewEquipmentHistory(role), false);
  const reference = {
    areas: [],
    equipment: [],
    employees: [],
    brigades: [],
    fault_codes: [],
    materials: [],
    time_norms: [],
  };
  const worker = renderToStaticMarkup(
    React.createElement(EquipmentHistory, {
      id: 8,
      user: { id: 1, role: "worker" },
      reference,
      active: true,
      invalidation: 0,
      onSelect() {},
      onClose() {},
    }),
  );
  assert.match(worker, /Работнику доступны его наряды/);
  assert.doesNotMatch(
    worker,
    /Ремонты оборудования|Показать ещё|Поиск во всём журнале/,
  );
});
test("inactive modal retains its children while hiding the original order form", () => {
  const html = renderToStaticMarkup(
    React.createElement(
      Modal,
      { title: "SYNTHETIC_ORDER_FORM", active: false, onClose() {} },
      React.createElement("textarea", {
        defaultValue: "SYNTHETIC_DURABLE_REPORT",
      }),
    ),
  );
  assert.match(html, /display:none/);
  assert.match(html, /aria-hidden="true"/);
  assert.match(html, /SYNTHETIC_DURABLE_REPORT/);
});
