import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import {
  ApiError,
  confirmedOrderVersion,
  isOrderVersionConflict,
  orderWrite,
  post,
  postOrder,
} from "../src/model.ts";

const require = createRequire(import.meta.url);
const { buildSync } = createRequire(import.meta.resolve("vite"))("esbuild");
const loaded = { exports: {} };
new Function(
  "require",
  "module",
  "exports",
  buildSync({
    entryPoints: [
      fileURLToPath(new URL("../src/OrderVersion.tsx", import.meta.url)),
    ],
    bundle: true,
    write: false,
    platform: "node",
    format: "cjs",
    packages: "external",
    jsx: "automatic",
  }).outputFiles[0].text,
)(require, loaded, loaded.exports);
const { isStaleOrderForm, advancePhotoFormVersion, OrderVersionNotice } =
  loaded.exports;
globalThis.localStorage = { getItem: () => "synthetic-session" };

test("all existing-order write kinds send the captured version and keep authentication", async () => {
  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url, options });
    return Response.json({ version: 5 });
  };
  await postOrder("/orders/9/transition", 4, { action: "pause" });
  await postOrder("/orders/9/complete", 4, { work_done: "SYNTHETIC_REPORT" });
  await orderWrite("/orders/9", 4, { method: "PATCH", body: "{}" });
  const photo = new FormData();
  photo.append("kind", "after");
  await orderWrite("/orders/9/photos", 4, { method: "POST", body: photo });
  for (const { options } of calls) {
    assert.equal(options.headers.get("X-Expected-Order-Version"), "4");
    assert.equal(
      options.headers.get("Authorization"),
      "Bearer synthetic-session",
    );
    assert.equal(options.headers.has("X-Previous-Client-Command-Id"), false);
  }
  assert.equal(calls.at(-1).options.headers.has("Content-Type"), false);
  await post("/orders", { title: "SYNTHETIC_NEW_ORDER" });
  assert.equal(
    calls.at(-1).options.headers.has("X-Expected-Order-Version"),
    false,
  );
});

test("a missing or invalid cached version blocks the write before reaching the server", () => {
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    return Response.json({});
  };
  for (const version of [undefined, null, 0, -1, 1.5, "4", Number.NaN])
    assert.throws(
      () => postOrder("/orders/9/complete", version, {}),
      (error) => error instanceof ApiError && !error.requestMayHaveSucceeded,
    );
  assert.equal(calls, 0);
});

test("structured version rejection is known, retains its server message and is never retried", async () => {
  let calls = 0;
  for (const code of [
    "order_version_conflict",
    "order_precondition_unavailable",
  ]) {
    globalThis.fetch = async () => {
      calls++;
      return Response.json(
        {
          detail: {
            code,
            message: "Наряд изменился на сервере",
            expected_version: 4,
            current_version: 7,
          },
        },
        { status: 409 },
      );
    };
    await assert.rejects(
      postOrder("/orders/9/complete", 4, { materials: [{ quantity: 2 }] }),
      (error) =>
        isOrderVersionConflict(error) &&
        error.statusCode === 409 &&
        error.expectedVersion === 4 &&
        error.currentVersion === 7 &&
        !error.requestMayHaveSucceeded &&
        error.message === "Наряд изменился на сервере",
    );
  }
  assert.equal(calls, 2);
  assert.equal(isOrderVersionConflict(new ApiError("Unavailable", 409)), false);
});

test("polling a newer card does not silently advance a form opened on an older version", () => {
  const baseline = 4;
  assert.equal(isStaleOrderForm(baseline, 4), false);
  for (const currentVersion of [5, 8])
    assert.equal(isStaleOrderForm(baseline, currentVersion), true);
  assert.equal(isStaleOrderForm(null, 8), false);
});

test("only the confirmed photo of the form's own version advances its baseline", () => {
  assert.equal(advancePhotoFormVersion(4, 4, 5), 5);
  assert.equal(advancePhotoFormVersion(3, 4, 5), 3);
  assert.equal(advancePhotoFormVersion(null, 4, 5), null);
  assert.equal(isStaleOrderForm(advancePhotoFormVersion(4, 4, 5), 6), true);
});

test("opening another form cannot rebase the retained report and material draft", () => {
  const completionBaseline = 4;
  const currentCardVersion = 6;
  const newlyOpenedEditBaseline = currentCardVersion;
  assert.equal(
    isStaleOrderForm(newlyOpenedEditBaseline, currentCardVersion),
    false,
  );
  assert.equal(isStaleOrderForm(completionBaseline, currentCardVersion), true);
  assert.equal(
    advancePhotoFormVersion(completionBaseline, currentCardVersion, 7),
    4,
  );
  assert.equal(isStaleOrderForm(completionBaseline, 7), true);
});

test("creation photo sequence chains exact receipts without taking a newer GET version", async () => {
  const expected = [];
  globalThis.fetch = async (_url, options) => {
    const version = Number(options.headers.get("X-Expected-Order-Version"));
    expected.push(version);
    return Response.json({ id: expected.length, order_version: version + 1 });
  };
  let version = 1;
  for (let index = 0; index < 3; index++) {
    const receipt = await orderWrite("/orders/9/photos", version, {
      method: "POST",
      body: new FormData(),
    });
    version = confirmedOrderVersion(receipt.order_version, version);
  }
  assert.deepEqual(expected, [1, 2, 3]);
  assert.equal(version, 4);
});

test("unusable success receipt and unknown network result never become a new baseline", async () => {
  for (const value of [undefined, 3, "5", Number.NaN])
    assert.throws(
      () => confirmedOrderVersion(value, 4),
      (error) => error.requestMayHaveSucceeded,
    );
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    throw new TypeError("Synthetic disconnect");
  };
  await assert.rejects(
    orderWrite("/orders/9", 4, { method: "PATCH", body: "{}" }),
    (error) => error.requestMayHaveSucceeded && !isOrderVersionConflict(error),
  );
  assert.equal(calls, 1);
});

test("conflict notice keeps the old input separate from an explicit fresh action", () => {
  const render = (props) =>
    renderToStaticMarkup(
      React.createElement(OrderVersionNotice, { onReset() {}, ...props }),
    );
  for (const props of [{ stale: true }, { conflict: true }]) {
    const html = render(props);
    assert.match(html, /Введённые данные сохранены/);
    assert.match(html, /прежнего действия заблокирована/);
    assert.match(html, /Закрыть форму и обновить наряд/);
  }
  assert.match(
    render({ uncertain: true, busy: true }),
    /Результат действия неизвестен/,
  );
  assert.match(render({ uncertain: true, busy: true }), /disabled=""/);
  const persisted = render({ stale: true, persistentDraft: true });
  assert.match(persisted, /Черновик сохраняет прежнее основание/);
  assert.match(persisted, /Удалить черновик/);
  assert.doesNotMatch(persisted, /откройте её заново/);
  assert.equal(render({}), "");
});
