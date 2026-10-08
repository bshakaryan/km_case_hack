import { useEffect, useRef, useState } from "react";
import { DraftWriter, draftKey } from "./draft-storage";
import type { DraftScope } from "./draft-storage";

export function useFormDraft<T>(
  scope: DraftScope,
  initial: T,
  recover: (data: T) => T,
) {
  const key = draftKey(scope);
  const writer = useRef<DraftWriter<T> | null>(null);
  if (!writer.current) writer.current = new DraftWriter<T>(key);
  const current = useRef(initial);
  const active = useRef(true);
  const generation = useRef(0);
  const loading = useRef<Promise<{ value?: T; restored: boolean }> | null>(
    null,
  );
  const [data, setData] = useState(initial);
  const [ready, setReady] = useState(false);
  const [restored, setRestored] = useState(false);
  const [pending, setPending] = useState(0);
  const [error, setError] = useState("");
  const [saved, setSaved] = useState(false);
  useEffect(() => {
    active.current = true;
    const requestGeneration = ++generation.current;
    if (!loading.current)
      loading.current = writer.current!.load().then(async (stored) => {
        if (!stored) return { restored: false };
        const recovered = recover(stored);
        await writer.current!.save(recovered);
        return { value: recovered, restored: true };
      });
    loading.current
      .then(({ value, restored: found }) => {
        if (!active.current || requestGeneration !== generation.current) return;
        if (value) {
          current.current = value;
          setData(value);
          setRestored(found);
          setSaved(true);
        }
        setReady(true);
      })
      .catch((failure) => {
        if (active.current && requestGeneration === generation.current)
          setError((failure as Error).message);
      });
    return () => {
      active.current = false;
    };
  }, [key]);
  async function write(update: (value: T) => T) {
    if (!active.current || writer.current!.key !== key)
      throw new Error("Форма уже закрыта или сменился её владелец.");
    if (!ready || error) throw new Error(error || "Черновик ещё не прочитан.");
    const next = update(current.current);
    current.current = next;
    setData(next);
    setSaved(false);
    setPending((count) => count + 1);
    try {
      await writer.current!.save(next);
      if (active.current) setSaved(true);
      return next;
    } catch (failure) {
      if (active.current) setError((failure as Error).message);
      throw failure;
    } finally {
      if (active.current) setPending((count) => count - 1);
    }
  }
  function change(update: (value: T) => T) {
    void write(update).catch(() => {});
  }
  async function remove(reset?: T) {
    if (!active.current || writer.current!.key !== key)
      throw new Error("Форма уже закрыта или сменился её владелец.");
    if (!ready || error) throw new Error(error || "Черновик ещё не прочитан.");
    await writer.current!.save(null);
    if (active.current) {
      if (reset !== undefined) {
        current.current = reset;
        setData(reset);
      }
      setSaved(false);
      setRestored(false);
    }
  }
  return {
    data,
    ready,
    restored,
    pending,
    error,
    saved,
    write,
    change,
    remove,
  };
}

export function FormDraftNotice({
  ready,
  restored,
  pending,
  error,
  saved,
  onDelete,
  busy = false,
}: {
  ready: boolean;
  restored: boolean;
  pending: number;
  error: string;
  saved: boolean;
  onDelete: () => void;
  busy?: boolean;
}) {
  return (
    <div
      className={error ? "error-box" : "info-banner"}
      role={error ? "alert" : "status"}
    >
      <div>
        <p>
          {error
            ? `Черновик не сохранён: ${error}`
            : !ready
              ? "Чтение локального черновика…"
              : pending
                ? "Сохранение черновика…"
                : saved
                  ? `${restored ? "Черновик восстановлен. " : ""}Сохранено в этом браузере.`
                  : "Введённые данные и фото сохраняются в этом браузере. Это ещё не отправка на сервер."}
        </p>
        {ready && !error && (
          <button
            type="button"
            className="text-button muted"
            disabled={busy || pending > 0}
            onClick={onDelete}
          >
            Удалить черновик
          </button>
        )}
      </div>
    </div>
  );
}

export function draftFieldSetter<T, K extends keyof T>(
  change: (update: (data: T) => T) => void,
  key: K,
) {
  return (value: T[K] | ((previous: T[K]) => T[K])) =>
    change((data) => ({
      ...data,
      [key]:
        typeof value === "function"
          ? (value as (previous: T[K]) => T[K])(data[key])
          : value,
    }));
}
