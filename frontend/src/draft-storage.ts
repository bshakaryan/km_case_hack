export type DraftScope = {
  api: string;
  owner: string;
  form: "create" | "complete";
  order: string;
};
export type DraftEnvelope<T> = {
  schema: 1;
  key: string;
  revision: number;
  updatedAt: string;
  data: T;
};
export interface DraftAdapter {
  read<T>(key: string): Promise<DraftEnvelope<T> | undefined>;
  replace<T>(key: string, data: T | null, expected: number): Promise<number>;
}
export function draftKey(scope: DraftScope) {
  return JSON.stringify([
    1,
    new URL(scope.api).href,
    scope.owner,
    scope.form,
    scope.order,
  ]);
}

let database: Promise<IDBDatabase> | undefined;
function openDatabase() {
  if (!database)
    database = new Promise<IDBDatabase>((resolve, reject) => {
      if (!globalThis.indexedDB) {
        reject(
          new Error(
            "Браузер не предоставляет постоянное хранилище черновиков.",
          ),
        );
        return;
      }
      const request = indexedDB.open("naryad-form-drafts", 1);
      request.onupgradeneeded = () =>
        request.result.createObjectStore("drafts", { keyPath: "key" });
      request.onerror = () => {
        database = undefined;
        reject(request.error);
      };
      request.onblocked = () => {
        database = undefined;
        reject(
          new Error(
            "Закройте другую вкладку, блокирующую хранилище черновиков.",
          ),
        );
      };
      request.onsuccess = () => {
        const db = request.result;
        db.onversionchange = () => {
          db.close();
          database = undefined;
        };
        resolve(db);
      };
    });
  return database;
}
export const indexedDraftAdapter: DraftAdapter = {
  async read<T>(key: string) {
    const db = await openDatabase();
    return new Promise<DraftEnvelope<T> | undefined>((resolve, reject) => {
      const tx = db.transaction("drafts", "readonly");
      const request = tx.objectStore("drafts").get(key);
      tx.oncomplete = () => resolve(request.result);
      tx.onabort = () =>
        reject(tx.error || new Error("Не удалось прочитать черновик."));
      tx.onerror = () => reject(tx.error);
    });
  },
  async replace<T>(key: string, data: T | null, expected: number) {
    const db = await openDatabase();
    return new Promise<number>((resolve, reject) => {
      const tx = db.transaction("drafts", "readwrite");
      const store = tx.objectStore("drafts");
      const request = store.get(key);
      let conflict = false;
      request.onsuccess = () => {
        if ((request.result?.revision || 0) !== expected) {
          conflict = true;
          tx.abort();
          return;
        }
        // Retain a revision tombstone so an old tab cannot resurrect a deleted draft.
        store.put({
          schema: 1,
          key,
          revision: expected + 1,
          updatedAt: new Date().toISOString(),
          data,
        });
      };
      tx.oncomplete = () => resolve(expected + 1);
      tx.onabort = () =>
        reject(
          conflict
            ? new Error(
                "Черновик изменён в другой вкладке. Закройте форму и откройте её заново.",
              )
            : tx.error ||
                new Error(
                  "Не удалось сохранить черновик. Проверьте место и настройки браузера.",
                ),
        );
      tx.onerror = () => reject(tx.error);
    });
  },
};

/** Serial writes and a compare-and-swap revision protect submit markers across tabs. */
export class DraftWriter<T> {
  private revision = 0;
  private loaded = false;
  private queue: Promise<unknown> = Promise.resolve();
  private failed: unknown;
  readonly key: string;
  private adapter: DraftAdapter;
  constructor(key: string, adapter: DraftAdapter = indexedDraftAdapter) {
    this.key = key;
    this.adapter = adapter;
  }
  async load(): Promise<T | undefined> {
    const record = await this.adapter.read<T | null>(this.key);
    if (
      record &&
      (record.schema !== 1 ||
        record.key !== this.key ||
        !Number.isSafeInteger(record.revision) ||
        record.revision < 1)
    )
      throw new Error(
        "Формат черновика повреждён. Сохранённые данные не заменены новой формой.",
      );
    this.revision = record?.revision || 0;
    this.loaded = true;
    return record?.data ?? undefined;
  }
  save(data: T | null): Promise<void> {
    // Capture at enqueue time: later edits cannot mutate an earlier submitting marker.
    const snapshot = data === null ? null : structuredClone(data);
    const next = this.queue.then(async () => {
      if (!this.loaded) throw new Error("Черновик ещё не прочитан.");
      if (this.failed) throw this.failed;
      try {
        this.revision = await this.adapter.replace(
          this.key,
          snapshot,
          this.revision,
        );
      } catch (error) {
        this.failed = error;
        throw error;
      }
    });
    this.queue = next.catch(() => {});
    return next;
  }
}

export type SavedPhoto = {
  id: number;
  file: File;
  kind: "before" | "after";
  state: "queued" | "uploading" | "uploaded" | "failed" | "uncertain";
  error?: string;
  expectedVersion?: number;
};
export function recoverPhotos(photos: SavedPhoto[]) {
  return photos.map((photo) =>
    photo.state === "uploading"
      ? {
          ...photo,
          state: "uncertain" as const,
          error:
            "Вкладка закрылась во время отправки. Проверьте снимки на сервере.",
        }
      : photo,
  );
}
export function recoverPhase(
  phase: "editing" | "submitting" | "unknown" | "confirmed",
) {
  return phase === "submitting" ? ("unknown" as const) : phase;
}

export function validateSavedDraft(
  data: unknown,
): asserts data is {
  phase: "editing" | "submitting" | "unknown" | "confirmed";
  photos: SavedPhoto[];
} {
  const value = data as { phase?: unknown; photos?: unknown };
  if (
    !value ||
    !["editing", "submitting", "unknown", "confirmed"].includes(
      String(value.phase),
    ) ||
    !Array.isArray(value.photos) ||
    value.photos.some(
      (item) =>
        !item ||
        !Number.isSafeInteger(item.id) ||
        !(item.file instanceof Blob) ||
        item.file.size > 10 * 1024 * 1024 ||
        !["before", "after"].includes(item.kind) ||
        !["queued", "uploading", "uploaded", "failed", "uncertain"].includes(
          item.state,
        ) ||
        (item.expectedVersion !== undefined &&
          (!Number.isSafeInteger(item.expectedVersion) ||
            item.expectedVersion < 1)),
    )
  )
    throw new Error(
      "Сохранённый черновик повреждён. Его поля и фото не заменены новой формой.",
    );
}
