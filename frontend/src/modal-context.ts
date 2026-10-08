type ActiveModal = { panel: HTMLElement };
const contexts = new WeakMap<Document, ActiveModal[]>();
const scrollLocks = new WeakMap<
  HTMLElement,
  { count: number; previous: string }
>();

/** Active dialogs share a scroll lock, and only the top dialog traps keys. */
export function activateModal(
  document: Document,
  panel: HTMLElement,
  close: () => void,
) {
  const previous = document.activeElement as HTMLElement | null;
  const stack = contexts.get(document) ?? [];
  const modal = { panel };
  stack.push(modal);
  contexts.set(document, stack);
  const lock = scrollLocks.get(document.body) ?? {
    count: 0,
    previous: document.body.style.overflow,
  };
  lock.count++;
  scrollLocks.set(document.body, lock);
  document.body.style.overflow = "hidden";
  panel.focus();
  const keydown = (event: KeyboardEvent) => {
    if (stack.at(-1) !== modal) return;
    if (event.key === "Escape") {
      event.preventDefault();
      close();
    }
    if (event.key !== "Tab") return;
    const elements = Array.from(
      panel.querySelectorAll<HTMLElement>(
        'button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]',
      ),
    ).filter((element) => element.getClientRects().length > 0);
    const first = elements[0],
      last = elements.at(-1);
    if (!first) {
      event.preventDefault();
      panel.focus();
      return;
    }
    if (
      event.shiftKey &&
      (document.activeElement === first || document.activeElement === panel)
    ) {
      event.preventDefault();
      last?.focus();
    } else if (
      !event.shiftKey &&
      (document.activeElement === last ||
        !panel.contains(document.activeElement))
    ) {
      event.preventDefault();
      first.focus();
    }
  };
  document.addEventListener("keydown", keydown);
  let disposed = false;
  return () => {
    if (disposed) return;
    disposed = true;
    document.removeEventListener("keydown", keydown);
    const top = stack.at(-1) === modal;
    stack.splice(stack.indexOf(modal), 1);
    if (--lock.count === 0) {
      document.body.style.overflow = lock.previous;
      scrollLocks.delete(document.body);
    }
    if (top) {
      const remaining = stack.at(-1);
      if (remaining) remaining.panel.focus();
      else if (previous?.isConnected) previous.focus();
    }
  };
}
