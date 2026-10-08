export function isStaleOrderForm(
  formVersion: number | null,
  currentVersion: number,
) {
  return formVersion !== null && formVersion !== currentVersion;
}

export function advancePhotoFormVersion(
  formVersion: number | null,
  requestedVersion: number,
  receivedVersion: number,
) {
  return formVersion === requestedVersion ? receivedVersion : formVersion;
}

export function OrderVersionNotice({
  stale = false,
  conflict = false,
  uncertain = false,
  busy = false,
  persistentDraft = false,
  onReset,
}: {
  stale?: boolean;
  conflict?: boolean;
  uncertain?: boolean;
  busy?: boolean;
  persistentDraft?: boolean;
  onReset: () => void;
}) {
  if (!stale && !conflict && !uncertain) return null;
  return (
    <div className="info-banner" role="status">
      <div>
        <p>
          {uncertain
            ? "Результат действия неизвестен. Отправка заблокирована до проверки текущего наряда."
            : "Наряд изменился. Введённые данные сохранены в открытой форме, но отправка прежнего действия заблокирована."}
        </p>
        <p>
          {persistentDraft
            ? 'Проверьте актуальные назначение, статус и отчёт. Черновик сохраняет прежнее основание. Для нового отчёта после проверки удалите прежний черновик кнопкой «Удалить черновик».'
            : 'Проверьте актуальные назначение, статус и отчёт. Чтобы выполнить новое действие, закройте прежнюю форму и откройте её заново.'}
        </p>
        <button
          type="button"
          className="button secondary"
          disabled={busy}
          onClick={onReset}
        >
          {persistentDraft ? 'Обновить наряд и сохранить черновик' : 'Закрыть форму и обновить наряд'}
        </button>
      </div>
    </div>
  );
}
