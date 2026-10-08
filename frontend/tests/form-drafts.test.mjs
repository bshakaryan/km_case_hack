import test from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import React from "react";
import { renderToStaticMarkup } from "react-dom/server";
import {
  DraftWriter,
  draftKey,
  recoverPhase,
  recoverPhotos,
  validateSavedDraft,
} from "../src/draft-storage.ts";

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
const { recoverCreateDraft, recoverCompletionDraft } =
  load("../src/Orders.tsx");
const { FormDraftNotice } = load("../src/FormDraft.tsx");

class MemoryAdapter {
  records = new Map();
  commits = 0;
  fail = false;
  hold;
  async read(key) {
    return structuredClone(this.records.get(key));
  }
  async replace(key, data, expected) {
    if (this.hold) await this.hold;
    if (this.fail) throw new Error("SYNTHETIC_QUOTA_ERROR");
    if ((this.records.get(key)?.revision || 0) !== expected)
      throw new Error("SYNTHETIC_CAS_CONFLICT");
    this.records.set(key, {
      schema: 1,
      key,
      revision: expected + 1,
      updatedAt: "SYNTHETIC_TIME",
      data: structuredClone(data),
    });
    this.commits++;
    return expected + 1;
  }
}
const scope = {
  api: "https://synthetic.example:8443/api/",
  owner: "17",
  form: "complete",
  order: "31",
};
const completion = () => ({
  complete: {
    work_done: "SYNTHETIC_REPORT",
    fault_code_id: "7",
    comment: "SYNTHETIC_COMMENT",
  },
  materials: [{ material_id: "9", quantity: "1," }],
  baseline: 4,
  phase: "editing",
  photos: [],
});
const photo = (state = "queued", id = 1) => ({
  id,
  file: new File(["SYNTHETIC_IMAGE_BYTES"], "synthetic.jpg", {
    type: "image/jpeg",
  }),
  kind: "after",
  state,
  expectedVersion: 4,
});

test("draft identity isolates full API URL, owner, form and order without storing tokens", () => {
  const variants = [
    scope,
    { ...scope, api: "http://synthetic.example:8443/api/" },
    { ...scope, api: "https://synthetic.example:9443/api/" },
    { ...scope, api: "https://synthetic.example:8443/other-api/" },
    { ...scope, owner: "18" },
    { ...scope, form: "create", order: "new" },
    { ...scope, order: "32" },
  ].map(draftKey);
  assert.equal(new Set(variants).size, variants.length);
  assert.equal(
    draftKey({ ...scope, api: "https://synthetic.example:8443/api/../api/" }),
    variants[0],
  );
  assert.doesNotMatch(variants[0], /token|bearer/i);
});

test("restart restores exact text, invalid raw quantity, frozen version and media bytes", async () => {
  const adapter = new MemoryAdapter();
  const key = draftKey(scope);
  const writer = new DraftWriter(key, adapter);
  assert.equal(await writer.load(), undefined);
  const data = { ...completion(), photos: [photo()] };
  await writer.save(data);
  const reopened = new DraftWriter(key, adapter);
  const restored = await reopened.load();
  assert.equal(restored.materials[0].quantity, "1,");
  assert.equal(restored.complete.work_done, "SYNTHETIC_REPORT");
  assert.equal(restored.baseline, 4);
  assert.equal(await restored.photos[0].file.text(), "SYNTHETIC_IMAGE_BYTES");
  assert.equal(restored.photos[0].expectedVersion, 4);
});

test("before HTTP marker waits for earlier autosaves and captures immutable input", async () => {
  const adapter = new MemoryAdapter();
  const writer = new DraftWriter(draftKey(scope), adapter);
  await writer.load();
  let release;
  adapter.hold = new Promise((resolve) => {
    release = resolve;
  });
  const input = completion();
  const autosave = writer.save(input);
  input.complete.work_done = "SYNTHETIC_LATER_INPUT";
  const marker = writer.save({ ...input, phase: "submitting" });
  let sent = false;
  const http = marker.then(() => {
    sent = true;
  });
  await Promise.resolve();
  assert.equal(sent, false);
  assert.equal(adapter.commits, 0);
  release();
  await Promise.all([autosave, http]);
  assert.equal(sent, true);
  assert.equal(adapter.commits, 2);
  assert.equal((await adapter.read(draftKey(scope))).data.phase, "submitting");
});

test("recovered in-flight create/complete/photo remains unknown; ready media never automatically sends", () => {
  for (const phase of ["editing", "unknown", "confirmed"])
    assert.equal(recoverPhase(phase), phase);
  assert.equal(recoverPhase("submitting"), "unknown");
  const source = [
    photo("uploaded", 1),
    photo("uploading", 2),
    photo("failed", 3),
    photo("queued", 4),
  ];
  const result = recoverPhotos(source);
  assert.deepEqual(
    result.map((item) => item.state),
    ["uploaded", "uncertain", "failed", "queued"],
  );
  assert.equal(source[1].state, "uploading");
  assert.equal(result[1].expectedVersion, 4);
});

test("partial creation retains confirmed ID/version and each photo acknowledgement on restore", () => {
  const data = {
    form: {
      title: "SYNTHETIC_TITLE",
      description: "SYNTHETIC_DESCRIPTION",
      work_type: "planned",
      area_id: "1",
      equipment_id: "2",
      assignee_id: "17",
      brigade_id: "",
      priority: "normal",
      deadline: "2027-01-01T12:00",
      normal_hours: "2",
      comment: "",
    },
    step: 2,
    assignment: "employee",
    phase: "confirmed",
    created: { id: 31, version: 6, number: "SYNTHETIC_ORDER" },
    creationPhotoConflict: false,
    photos: [photo("uploaded", 1), photo("uploading", 2), photo("queued", 3)],
  };
  const restored = recoverCreateDraft(data);
  assert.equal(restored.created.id, 31);
  assert.equal(restored.created.version, 6);
  assert.deepEqual(
    restored.photos.map((item) => item.state),
    ["uploaded", "uncertain", "queued"],
  );
  assert.equal(restored.phase, "confirmed");
});

test("completion restore never advances its report to a newer card or coerces raw quantity", () => {
  const data = {
    ...completion(),
    phase: "submitting",
    photos: [photo("uploaded")],
  };
  const restored = recoverCompletionDraft(data);
  assert.equal(restored.baseline, 4);
  assert.equal(restored.phase, "unknown");
  assert.equal(restored.materials[0].quantity, "1,");
  assert.notEqual(restored.baseline, 9); // A newer GET is not an acknowledgement of this draft.
});

test("another tab cannot overwrite a submitting marker or resurrect a deleted draft", async () => {
  const adapter = new MemoryAdapter();
  const key = draftKey(scope);
  const first = new DraftWriter(key, adapter),
    stale = new DraftWriter(key, adapter);
  await Promise.all([first.load(), stale.load()]);
  await first.save({ ...completion(), phase: "submitting" });
  await assert.rejects(stale.save(completion()), /CAS_CONFLICT/);
  assert.equal((await adapter.read(key)).data.phase, "submitting");
  const second = new DraftWriter(key, adapter),
    old = new DraftWriter(key, adapter);
  await Promise.all([second.load(), old.load()]);
  await second.save(null);
  await assert.rejects(old.save(completion()), /CAS_CONFLICT/);
  assert.equal((await adapter.read(key)).data, null);
  const fresh = new DraftWriter(key, adapter);
  assert.equal(await fresh.load(), undefined);
  await fresh.save(completion());
  assert.equal((await adapter.read(key)).revision, 3);
});

test("storage failure prevents marker acknowledgement and keeps previous durable data", async () => {
  const adapter = new MemoryAdapter();
  const key = draftKey(scope),
    writer = new DraftWriter(key, adapter);
  await writer.load();
  await writer.save(completion());
  adapter.fail = true;
  await assert.rejects(
    writer.save({ ...completion(), phase: "submitting" }),
    /QUOTA_ERROR/,
  );
  adapter.fail = false;
  await assert.rejects(
    writer.save({ ...completion(), phase: "confirmed" }),
    /QUOTA_ERROR/,
  );
  assert.equal((await adapter.read(key)).data.phase, "editing");
  assert.equal(adapter.commits, 1);
});

test("corrupted envelope/payload blocks restore without overwriting retained evidence", async () => {
  const adapter = new MemoryAdapter();
  const key = draftKey(scope);
  adapter.records.set(key, {
    schema: 99,
    key,
    revision: 2,
    data: completion(),
  });
  await assert.rejects(new DraftWriter(key, adapter).load(), /повреждён/);
  assert.equal(adapter.commits, 0);
  for (const data of [
    null,
    { phase: "unknown", photos: [{}] },
    { ...completion(), baseline: -1 },
    { ...completion(), materials: [{ material_id: "9", quantity: 2 }] },
  ])
    assert.throws(() => recoverCompletionDraft(data), /поврежд/);
  assert.throws(
    () =>
      validateSavedDraft({
        phase: "editing",
        photos: [{ ...photo(), file: "SYNTHETIC_BAD_BYTES" }],
      }),
    /поврежд/,
  );
});

test("draft notice distinguishes restored local bytes, saving and storage failure from server success", () => {
  const render = (props) =>
    renderToStaticMarkup(
      React.createElement(FormDraftNotice, {
        ready: true,
        restored: false,
        pending: 0,
        error: "",
        saved: false,
        onDelete() {},
        ...props,
      }),
    );
  assert.match(render({}), /Это ещё не отправка на сервер/);
  assert.match(
    render({ saved: true, restored: true }),
    /Черновик восстановлен/,
  );
  assert.match(render({ pending: 1 }), /Сохранение черновика/);
  assert.match(render({ pending: 1 }), /disabled=""/);
  const failure = render({ saved: true, error: "SYNTHETIC_QUOTA_ERROR" });
  assert.match(failure, /Черновик не сохранён/);
  assert.doesNotMatch(failure, /Сохранено в этом браузере/);
});
