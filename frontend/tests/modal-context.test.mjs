import test from "node:test";
import assert from "node:assert/strict";
import { activateModal } from "../src/modal-context.ts";

function environment() {
  const listeners = new Set();
  const document = {
    body: { style: { overflow: "auto" } },
    activeElement: null,
    addEventListener(_type, listener) {
      listeners.add(listener);
    },
    removeEventListener(_type, listener) {
      listeners.delete(listener);
    },
    key(key, shiftKey = false) {
      const event = {
        key,
        shiftKey,
        prevented: 0,
        preventDefault() {
          this.prevented++;
        },
      };
      for (const listener of [...listeners]) listener(event);
      return event;
    },
  };
  function element() {
    return {
      isConnected: true,
      focus() {
        document.activeElement = this;
      },
      getClientRects() {
        return [1];
      },
    };
  }
  function panel() {
    const first = element(),
      last = element();
    return {
      ...element(),
      first,
      last,
      querySelectorAll() {
        return [first, last];
      },
      contains(item) {
        return item === this || item === first || item === last;
      },
    };
  }
  return { document, panel, element };
}
test("only the active top modal consumes Escape and Tab; releasing it restores the underlying focus", () => {
  const { document, panel } = environment();
  const first = panel(),
    second = panel();
  const closed = [];
  const releaseFirst = activateModal(document, first, () =>
    closed.push("first"),
  );
  const releaseSecond = activateModal(document, second, () =>
    closed.push("second"),
  );
  assert.equal(document.key("Escape").prevented, 1);
  assert.deepEqual(closed, ["second"]);
  second.last.focus();
  assert.equal(document.key("Tab").prevented, 1);
  assert.equal(document.activeElement, second.first);
  second.first.focus();
  document.key("Tab", true);
  assert.equal(document.activeElement, second.last);
  releaseSecond();
  assert.equal(document.activeElement, first);
  assert.equal(document.body.style.overflow, "hidden");
  document.key("Escape");
  assert.deepEqual(closed, ["second", "first"]);
  releaseFirst();
  assert.equal(document.body.style.overflow, "auto");
});
test("cleanup order never unlocks a remaining active dialog and restores initial scrolling exactly once", () => {
  for (const firstReleased of [0, 1]) {
    const { document, panel, element } = environment();
    const previous = element();
    previous.focus();
    const release = [
      activateModal(document, panel(), () => {}),
      activateModal(document, panel(), () => {}),
    ];
    release[firstReleased]();
    release[firstReleased]();
    assert.equal(document.body.style.overflow, "hidden");
    release[1 - firstReleased]();
    assert.equal(document.body.style.overflow, "auto");
    assert.equal(document.key("Escape").prevented, 0);
  }
});
