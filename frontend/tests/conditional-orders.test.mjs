import test from "node:test";
import assert from "node:assert/strict";
import { api, ApiError, setToken } from "../src/model.ts";

const storage = new Map();
globalThis.localStorage = {
  getItem: (key) => storage.get(key) ?? null,
  setItem: (key, value) => storage.set(key, value),
  removeItem: (key) => storage.delete(key),
};
const tag = (value) => `"orders-v1-${value}"`;
const order = (id, extras = {}) => ({
  id,
  version: 1,
  participants: [{ employee_id: 6, name: "Synthetic worker" }],
  ...extras,
});
const complete = (items, etag = tag("initial"), status = 200) =>
  new Response(JSON.stringify(items), {
    status,
    headers: etag === null ? {} : { ETag: etag },
  });
const unchanged = (etag = tag("initial")) =>
  new Response(null, {
    status: 304,
    headers: etag === null ? {} : { ETag: etag },
  });
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((a, b) => {
    resolve = a;
    reject = b;
  });
  return { promise, resolve, reject };
};
const changedContext = (error) =>
  error instanceof ApiError &&
  error.statusCode === 409 &&
  error.code === "read_context_changed" &&
  !error.requestMayHaveSucceeded;
let unauthorized;
test.beforeEach(() => {
  globalThis.window = new EventTarget();
  window.location = { href: "https://synthetic.test/workspace" };
  unauthorized = 0;
  window.addEventListener("naryad:unauthorized", () => unauthorized++);
  setToken("synthetic-session");
});

test("200→304 uses immutable complete content and each call still reaches the server", async () => {
  const original = [order(1)];
  let calls = 0;
  globalThis.fetch = async (path, options) => {
    assert.equal(path, "/api/orders?limit=5000");
    assert.equal(options.cache, "no-store");
    assert.equal(
      options.headers.get("Authorization"),
      "Bearer synthetic-session",
    );
    assert.equal(
      options.headers.get("If-None-Match"),
      calls ? tag("initial") : null,
    );
    return calls++ ? unchanged() : complete(original);
  };
  const first = await api("/orders?limit=5000");
  first[0].participants[0].name = "Caller mutation";
  first.push(order(99));
  const second = await api("/orders?limit=5000");
  assert.deepEqual(second, original);
  second[0].participants.length = 0;
  assert.deepEqual(await api("/orders?limit=5000"), original);
  assert.equal(calls, 3);
});

test("a changed 200 replaces computed values and current role-visible rows without using order version", async () => {
  const initial = [
    order(1),
    order(2, { is_overdue: false, queue_position: 2 }),
  ];
  const permitted = [order(2, { is_overdue: true, queue_position: 1 })];
  let calls = 0;
  globalThis.fetch = async (_, options) => {
    if (calls++ === 0) return complete(initial);
    if (calls === 2) {
      assert.equal(options.headers.get("If-None-Match"), tag("initial"));
      return complete(permitted, tag("changed-role-and-computed"));
    }
    assert.equal(
      options.headers.get("If-None-Match"),
      tag("changed-role-and-computed"),
    );
    return unchanged(tag("changed-role-and-computed"));
  };
  await api("/orders");
  assert.deepEqual(await api("/orders"), permitted);
  assert.deepEqual(await api("/orders"), permitted);
});

test("full query variants retain separate representations", async () => {
  const paths = [
    "/orders?limit=5000&status=issued",
    "/orders?limit=100&status=issued",
    "/orders?status=issued&limit=5000",
    "/orders?limit=5000&search=%D0%A0%D0%B5%D0%BC%D0%BE%D0%BD%D1%82",
  ];
  const seen = new Map();
  globalThis.fetch = async (path, options) => {
    const i = paths.indexOf(path.slice(4));
    assert.notEqual(i, -1);
    const etag = tag(`query-${i}`);
    assert.equal(
      options.headers.get("If-None-Match"),
      seen.has(path) ? etag : null,
    );
    seen.set(path, true);
    return options.headers.has("If-None-Match")
      ? unchanged(etag)
      : complete([order(i)], etag);
  };
  for (const path of paths) await api(path);
  for (let i = 0; i < paths.length; i++)
    assert.deepEqual(await api(paths[i]), [order(i)]);
});

test("effective explicit authorization is isolated when there is no stored token", async () => {
  setToken(null);
  globalThis.fetch = async (_, options) => {
    const owner = options.headers.get("Authorization");
    const etag = tag(owner.endsWith("A") ? "owner-A" : "owner-B");
    if (options.headers.has("If-None-Match")) {
      assert.equal(options.headers.get("If-None-Match"), etag);
      return unchanged(etag);
    }
    return complete([order(owner.endsWith("A") ? 1 : 2)], etag);
  };
  assert.deepEqual(
    await api("/orders", { headers: { Authorization: "Bearer A" } }),
    [order(1)],
  );
  assert.deepEqual(
    await api("/orders", { headers: { Authorization: "Bearer B" } }),
    [order(2)],
  );
  assert.deepEqual(
    await api("/orders", { headers: { Authorization: "Bearer A" } }),
    [order(1)],
  );
});

test("stored authority overrides supplied headers exactly as before", async () => {
  let calls = 0;
  globalThis.fetch = async (_, options) => {
    assert.equal(
      options.headers.get("Authorization"),
      "Bearer synthetic-session",
    );
    return calls++ ? unchanged() : complete([order(1)]);
  };
  const options = { headers: { Authorization: "Bearer ignored-option" } };
  await api("/orders", options);
  assert.deepEqual(await api("/orders", options), [order(1)]);
});

test("base origin changes and direct observed token changes clear conditional bodies", async () => {
  let origin = "https://synthetic.test";
  globalThis.fetch = async (_, options) => {
    assert.equal(options.headers.get("If-None-Match"), null);
    return complete([order(1)], tag(origin));
  };
  await api("/orders");
  window.location.href = `${(origin = "https://other-synthetic.test")}/workspace`;
  await api("/orders");
  storage.set("naryad_token", "direct-new-session");
  await api("/orders");
  window.location.href = `${(origin = "https://synthetic.test")}/workspace`;
  await api("/orders");
});

for (const status of [401, 403, 404, 500]) {
  test(`current HTTP ${status} never falls back to cached data and clears that representation`, async () => {
    let calls = 0;
    globalThis.fetch = async (_, options) => {
      if (calls++ === 0) return complete([order(1)]);
      if (calls === 2)
        return new Response('{"detail":"Synthetic rejection"}', { status });
      assert.equal(options.headers.get("If-None-Match"), null);
      return complete([order(2)]);
    };
    await api("/orders");
    await assert.rejects(
      api("/orders"),
      (error) =>
        error instanceof ApiError &&
        error.statusCode === status &&
        !error.requestMayHaveSucceeded,
    );
    assert.equal(unauthorized, status === 401 ? 1 : 0);
    assert.deepEqual(await api("/orders"), [order(2)]);
    assert.equal(calls, 3);
  });
}

for (const etag of [
  null,
  'W/"weak"',
  "unquoted",
  '"invalid space"',
  `"${"x".repeat(4095)}"`,
]) {
  test(`200 without a usable strong ETag clears its prior cached representation: ${etag?.length > 4096 ? "oversized" : etag}`, async () => {
    let calls = 0;
    globalThis.fetch = async (_, options) => {
      if (calls++ === 0) return complete([order(1)]);
      if (calls === 2) return complete([order(2)], etag);
      assert.equal(options.headers.get("If-None-Match"), null);
      return complete([order(2)]);
    };
    await api("/orders");
    assert.deepEqual(await api("/orders"), [order(2)]);
    await api("/orders");
  });
}

for (const etag of [null, tag("unrelated"), tag("initial")]) {
  test(`304 without a corresponding captured body is a truthful single-request error: ${etag}`, async () => {
    let calls = 0;
    globalThis.fetch = async () => {
      calls++;
      return unchanged(etag);
    };
    await assert.rejects(
      api("/orders"),
      (error) =>
        error instanceof ApiError &&
        error.statusCode === 304 &&
        !error.requestMayHaveSucceeded,
    );
    assert.equal(calls, 1);
  });
}

test("304 missing or mismatched response ETag cannot reuse an otherwise valid body", async () => {
  for (const etag of [null, tag("other")]) {
    setToken("synthetic-session");
    let calls = 0;
    globalThis.fetch = async (_, options) => {
      if (calls++ === 0) return complete([order(1)]);
      if (calls === 2) return unchanged(etag);
      assert.equal(options.headers.get("If-None-Match"), null);
      return complete([order(2)]);
    };
    await api("/orders");
    await assert.rejects(api("/orders"), (error) => error.statusCode === 304);
    await api("/orders");
  }
});

test("an older concurrent 200 cannot overwrite a newer complete representation", async () => {
  const gate = deferred();
  globalThis.fetch = () => gate.promise;
  const older = api("/orders");
  globalThis.fetch = async () => complete([order(2)], tag("newer"));
  assert.deepEqual(await api("/orders"), [order(2)]);
  gate.resolve(complete([order(1)], tag("older")));
  await older;
  globalThis.fetch = async (_, options) => {
    assert.equal(options.headers.get("If-None-Match"), tag("newer"));
    return unchanged(tag("newer"));
  };
  assert.deepEqual(await api("/orders"), [order(2)]);
});

test("an older concurrent 200 cannot restore a body cleared by a newer response without ETag", async () => {
  globalThis.fetch = async () => complete([order(1)]);
  await api("/orders");
  const gate = deferred();
  globalThis.fetch = () => gate.promise;
  const older = api("/orders");
  globalThis.fetch = async () => complete([order(2)], null);
  await api("/orders");
  gate.resolve(complete([order(1)], tag("older")));
  await older;
  globalThis.fetch = async (_, options) => {
    assert.equal(options.headers.get("If-None-Match"), null);
    return complete([order(2)]);
  };
  assert.deepEqual(await api("/orders"), [order(2)]);
});

test("an older failed read does not clear a body successfully revalidated by a newer read", async () => {
  globalThis.fetch = async () => complete([order(1)]);
  await api("/orders");
  const gate = deferred();
  globalThis.fetch = () => gate.promise;
  const older = assert.rejects(
    api("/orders"),
    (error) => error instanceof ApiError,
  );
  globalThis.fetch = async () => unchanged();
  await api("/orders");
  gate.reject(new TypeError("Synthetic older transport failure"));
  await older;
  globalThis.fetch = async (_, options) => {
    assert.equal(options.headers.get("If-None-Match"), tag("initial"));
    return unchanged();
  };
  assert.deepEqual(await api("/orders"), [order(1)]);
});

test("an unrelated caller condition cannot authorize reuse of a different cached body", async () => {
  globalThis.fetch = async () => complete([order(1)]);
  await api("/orders");
  globalThis.fetch = async (_, options) => {
    assert.equal(options.headers.get("If-None-Match"), tag("caller-unknown"));
    return unchanged(tag("caller-unknown"));
  };
  await assert.rejects(
    api("/orders", { headers: { "If-None-Match": tag("caller-unknown") } }),
    (error) => error.statusCode === 304,
  );
});

for (const kind of [
  "network",
  "bad-json",
  "bad-shape",
  "incomplete-body",
  "204",
]) {
  test(`${kind} is not replaced by a prior successful array`, async () => {
    let calls = 0;
    globalThis.fetch = async (_, options) => {
      if (calls++ === 0) return complete([order(1)]);
      if (calls === 2) {
        if (kind === "network")
          throw new TypeError("Synthetic transport failure");
        if (kind === "bad-json")
          return new Response("unfinished-json", {
            headers: { ETag: tag("bad") },
          });
        if (kind === "bad-shape") return complete({ private: true });
        if (kind === "204") return new Response(null, { status: 204 });
        return new Response(
          new ReadableStream({
            start(controller) {
              controller.error(new TypeError("Synthetic body failure"));
            },
          }),
          { headers: { ETag: tag("bad") } },
        );
      }
      assert.equal(options.headers.get("If-None-Match"), null);
      return complete([order(2)]);
    };
    await api("/orders");
    await assert.rejects(
      api("/orders"),
      (error) => error instanceof ApiError && !error.requestMayHaveSucceeded,
    );
    assert.deepEqual(await api("/orders"), [order(2)]);
  });
}

for (const invalidRows of [[null], [1], [[]]]) {
  test(`invalid list rows ${JSON.stringify(invalidRows)} are not cached or replaced by a later 304`, async () => {
    let calls = 0;
    globalThis.fetch = async (_, options) => {
      if (calls++ === 0) return complete([order(1)]);
      if (calls === 2) return complete(invalidRows, tag("invalid-rows"));
      assert.equal(options.headers.get("If-None-Match"), null);
      return calls === 3 ? unchanged() : complete([order(2)]);
    };
    await api("/orders");
    await assert.rejects(
      api("/orders"),
      (error) => error instanceof ApiError && error.statusCode === 200,
    );
    await assert.rejects(
      api("/orders"),
      (error) => error instanceof ApiError && error.statusCode === 304,
    );
    assert.deepEqual(await api("/orders"), [order(2)]);
    assert.equal(calls, 4);
  });
}

for (const kind of ["200", "304", "401", "network"]) {
  test(`late ${kind} from an ABA token session cannot return data, replace the new cache or expire it`, async () => {
    globalThis.fetch = async () => complete([order(1)]);
    await api("/orders");
    const gate = deferred();
    globalThis.fetch = () => gate.promise;
    const pending = assert.rejects(api("/orders"), changedContext);
    setToken("synthetic-intermediate");
    setToken("synthetic-session");
    globalThis.fetch = async (_, options) => {
      assert.equal(options.headers.get("If-None-Match"), null);
      return complete([order(2)], tag("new-session"));
    };
    await api("/orders");
    if (kind === "network")
      gate.reject(new TypeError("Synthetic transport failure"));
    else
      gate.resolve(
        kind === "304"
          ? unchanged()
          : kind === "401"
            ? new Response('{"detail":"Old login expired"}', { status: 401 })
            : complete([order(99)], tag("old-late")),
      );
    await pending;
    assert.equal(unauthorized, 0);
    globalThis.fetch = async (_, options) => {
      assert.equal(options.headers.get("If-None-Match"), tag("new-session"));
      return unchanged(tag("new-session"));
    };
    assert.deepEqual(await api("/orders"), [order(2)]);
  });
}

test("an identical token assignment fences a response still reading its body", async () => {
  const gate = deferred();
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    headers: new Headers({ ETag: tag("late-body") }),
    text: () => gate.promise,
  });
  const pending = assert.rejects(api("/orders"), changedContext);
  await Promise.resolve();
  setToken("synthetic-session");
  gate.resolve(JSON.stringify([order(99)]));
  await pending;
  globalThis.fetch = async (_, options) => {
    assert.equal(options.headers.get("If-None-Match"), null);
    return complete([order(2)]);
  };
  assert.deepEqual(await api("/orders"), [order(2)]);
});

test("a storage event fences an ABA change even when the stored token already returned to its initial value", async () => {
  const gate = deferred();
  globalThis.fetch = () => gate.promise;
  const pending = assert.rejects(api("/orders"), changedContext);
  storage.set("naryad_token", "synthetic-intermediate");
  storage.set("naryad_token", "synthetic-session");
  const event = new Event("storage");
  Object.defineProperty(event, "key", { value: "naryad_token" });
  window.dispatchEvent(event);
  gate.resolve(complete([order(99)]));
  await pending;
});

test("late unauthorized body after logout/login does not dispatch expiry in the new scope", async () => {
  const gate = deferred();
  globalThis.fetch = async () => ({
    ok: false,
    status: 401,
    json: () => gate.promise,
  });
  const pending = assert.rejects(api("/orders"), changedContext);
  await Promise.resolve();
  setToken(null);
  setToken("synthetic-session");
  gate.resolve({ detail: "Expired old session" });
  await pending;
  assert.equal(unauthorized, 0);
});

test("an aborted request cannot apply or cache a late complete body even when fetch ignores abort", async () => {
  globalThis.fetch = async () => complete([order(1)]);
  await api("/orders");
  const gate = deferred();
  globalThis.fetch = () => gate.promise;
  const controller = new AbortController();
  const pending = assert.rejects(
    api("/orders", { signal: controller.signal }),
    (error) => error.name === "AbortError",
  );
  controller.abort();
  gate.resolve(complete([order(99)], tag("aborted")));
  await pending;
  globalThis.fetch = async (_, options) => {
    assert.equal(options.headers.get("If-None-Match"), tag("initial"));
    return unchanged();
  };
  assert.deepEqual(await api("/orders"), [order(1)]);
});

test("pages, details, body-bearing GET and mutations do not opt into the list cache", async () => {
  for (const [path, options, result] of [
    [
      "/orders/page?limit=100",
      {},
      { items: [order(1)], total: 1, next_cursor: null },
    ],
    ["/orders/1", {}, order(1)],
    ["/orders", { method: "GET", body: "synthetic-body" }, { unchanged: true }],
    ["/orders", { method: "POST", body: "{}" }, order(2)],
  ]) {
    let calls = 0;
    globalThis.fetch = async (_, sent) => {
      calls++;
      assert.equal(sent.cache, undefined);
      assert.equal(sent.headers.get("If-None-Match"), null);
      return complete(result);
    };
    assert.deepEqual(await api(path, options), result);
    assert.deepEqual(await api(path, options), result);
    assert.equal(calls, 2);
  }
});
