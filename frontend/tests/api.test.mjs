import test from "node:test";
import assert from "node:assert/strict";
import { api, ApiError } from "../src/model.ts";

let currentToken = "demo-token";
let unauthorized = 0;
globalThis.localStorage = { getItem: () => currentToken };
globalThis.window = {
  dispatchEvent: () => {
    unauthorized++;
  },
};
test.beforeEach(() => {
  currentToken = "demo-token";
  unauthorized = 0;
});

test("Ambiguous POST is not retried and carries an unknown result", async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    calls++;
    throw new TypeError("network");
  };
  await assert.rejects(
    api("/orders", { method: "POST", body: "{}" }),
    (e) => e instanceof ApiError && e.requestMayHaveSucceeded,
  );
  assert.equal(calls, 1);
});
test("Rejected fields expose a known rejection and keep the session", async () => {
  globalThis.fetch = async () =>
    new Response(
      JSON.stringify({ detail: [{ msg: "Описание обязательно" }] }),
      { status: 422 },
    );
  await assert.rejects(
    api("/orders", { method: "POST", body: "{}" }),
    (e) =>
      e.statusCode === 422 &&
      !e.requestMayHaveSucceeded &&
      e.message.includes("Описание"),
  );
  assert.equal(unauthorized, 0);
});
test("Server failure or unreadable success cannot safely be repeated", async () => {
  for (const response of [
    new Response("{}", { status: 500 }),
    new Response("not-json", { status: 201 }),
  ]) {
    globalThis.fetch = async () => response;
    await assert.rejects(
      api("/orders", { method: "POST", body: "{}" }),
      (e) => e.requestMayHaveSucceeded,
    );
  }
});
test("Late unauthorized body from old login does not log out a newer session", async () => {
  globalThis.fetch = async () => ({
    ok: false,
    status: 401,
    json: async () => {
      currentToken = "new-session";
      return { detail: "expired" };
    },
  });
  await assert.rejects(api("/orders"), (e) => e instanceof ApiError);
  assert.equal(unauthorized, 0);
});
test("Bearer is sent and successful old-session data is discarded", async () => {
  globalThis.fetch = async (_path, options) => {
    assert.equal(options.headers.get("Authorization"), "Bearer demo-token");
    currentToken = "new-session";
    return new Response('{"private":true}');
  };
  await assert.rejects(
    api("/orders"),
    (e) => e.statusCode === 409 && e.code === "read_context_changed",
  );
});
test("Read error never claims a write occurred; current 401 requests login", async () => {
  globalThis.fetch = async () => {
    throw new TypeError("network");
  };
  await assert.rejects(api("/orders"), (e) => !e.requestMayHaveSucceeded);
  globalThis.fetch = async () =>
    new Response('{"detail":"Сессия истекла"}', { status: 401 });
  await assert.rejects(api("/orders"), (e) => e.statusCode === 401);
  assert.equal(unauthorized, 1);
});
