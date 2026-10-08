import { useEffect, useMemo, useRef, useState } from "react";
import { ChevronRight, RefreshCw, Search } from "lucide-react";
import { api, formatDate, priorityNames, statusNames, token } from "./model";
import type { Id, Reference, User } from "./model";
import { JournalPager, journalFilters, journalQuery } from "./journal";
import type { JournalContext, JournalFilters, OrderPage } from "./journal";
import { periodInputDate } from "./workspace";
import { Empty, ErrorBox, Loading, Priority, SectionTitle, Status } from "./ui";

export function OrderJournal({
  user,
  reference,
  onSelect,
  context = {},
  initialScope = "active",
  equipmentId,
  invalidation = 0,
  active = true,
}: {
  user: User;
  reference: Reference;
  onSelect: (id: Id) => void;
  context?: JournalContext;
  initialScope?: JournalFilters["scope"];
  equipmentId?: Id;
  invalidation?: number;
  active?: boolean;
}) {
  const [filters, setFilters] = useState(() =>
    journalFilters(context, initialScope),
  );
  const [search, setSearch] = useState("");
  const [pager] = useState(
    () =>
      new JournalPager(
        (path, signal) => api<OrderPage>(path, { signal }),
        token,
      ),
  );
  const [, render] = useState(0);
  const seenInvalidation = useRef(invalidation);
  const query = useMemo(
    () => journalQuery(filters, equipmentId),
    [filters, equipmentId],
  );
  useEffect(() => pager.subscribe(() => render((value) => value + 1)), [pager]);
  useEffect(() => {
    const timer = setTimeout(
      () => setFilters((current) => ({ ...current, search })),
      300,
    );
    return () => clearTimeout(timer);
  }, [search]);
  const loadedQuery = useRef("");
  useEffect(() => {
    if (!active) {
      pager.suspend();
      return;
    }
    if (loadedQuery.current !== query || !pager.state.loaded) {
      loadedQuery.current = query;
      void pager.restart(query);
    }
    return () => pager.suspend();
  }, [active, pager, query, user.id]);
  useEffect(() => {
    if (invalidation !== seenInvalidation.current && active) {
      seenInvalidation.current = invalidation;
      pager.invalidate();
    }
  }, [active, invalidation, pager]);
  const state = pager.state;
  function update(key: keyof JournalFilters, value: string) {
    setFilters((current) => ({
      ...current,
      [key]: value,
      ...(key === "area_id" ? { equipment_id: "" } : {}),
      ...(key === "scope" ? { focus: "all" as const } : {}),
    }));
  }
  function resetFilters() {
    setSearch("");
    setFilters(journalFilters({}, initialScope));
  }
  return (
    <section className="orders-section server-journal">
      <SectionTitle
        title={
          equipmentId === undefined ? "Журнал нарядов" : "Ремонты оборудования"
        }
        caption="Поиск и фильтры охватывают весь доступный журнал."
        action={
          <button
            className="button secondary"
            disabled={state.busy}
            onClick={() => void pager.restart(query)}
          >
            <RefreshCw size={16} /> Обновить журнал
          </button>
        }
      />
      <div className="order-toolbar">
        <div className="tabs">
          {(["active", "all", "closed"] as const).map((scope) => (
            <button
              key={scope}
              className={filters.scope === scope ? "active" : ""}
              onClick={() => update("scope", scope)}
            >
              {scope === "active"
                ? "Активные"
                : scope === "all"
                  ? "Все наряды"
                  : "Закрытые"}
            </button>
          ))}
        </div>
        <label className="search-box">
          <Search size={17} />
          <input
            aria-label="Поиск во всём журнале"
            maxLength={200}
            placeholder="Номер, оборудование, сотрудник…"
            value={search}
            onChange={(event) => setSearch(event.target.value)}
          />
        </label>
      </div>
      <div className="journal-filters">
        <label>
          Участок
          <select
            aria-label="Участок журнала"
            value={filters.area_id}
            onChange={(e) => update("area_id", e.target.value)}
          >
            <option value="">Все участки</option>
            {reference.areas.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name}
              </option>
            ))}
          </select>
        </label>
        {equipmentId === undefined && (
          <label>
            Оборудование
            <select
              value={filters.equipment_id}
              onChange={(e) => update("equipment_id", e.target.value)}
            >
              <option value="">Всё оборудование</option>
              {reference.equipment
                .filter(
                  (item) =>
                    !filters.area_id ||
                    String(item.area_id) === filters.area_id,
                )
                .map((item) => (
                  <option key={item.id} value={item.id}>
                    {item.name}
                  </option>
                ))}
            </select>
          </label>
        )}
        {user.role !== "worker" && (
          <>
            <label>
              Ответственный / исполнитель
              <select
                value={filters.assignee_id}
                onChange={(e) => update("assignee_id", e.target.value)}
              >
                <option value="">Все исполнители</option>
                {reference.employees
                  .filter((item) => item.role === "worker")
                  .map((item) => (
                    <option key={item.id} value={item.id}>
                      {item.name}
                    </option>
                  ))}
              </select>
            </label>
            <label>
              Бригада
              <select
                value={filters.brigade_id}
                onChange={(e) => update("brigade_id", e.target.value)}
              >
                <option value="">Все бригады</option>
                {reference.brigades.map((item) => (
                  <option key={item.id} value={item.id}>
                    {item.name}
                  </option>
                ))}
              </select>
            </label>
          </>
        )}
        <label>
          Приоритет
          <select
            value={filters.priority}
            onChange={(e) => update("priority", e.target.value)}
          >
            <option value="">Любой приоритет</option>
            {Object.entries(priorityNames).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Статус
          <select
            value={filters.status}
            onChange={(e) => update("status", e.target.value)}
          >
            <option value="">Все статусы</option>
            {Object.entries(statusNames).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Требуют внимания
          <select
            value={filters.focus}
            onChange={(e) => update("focus", e.target.value)}
          >
            {Object.entries({
              all: "Без ограничений",
              overdue: "Просроченные",
              emergency: "Аварийные",
              issued: "Не приняты",
              ai_review: "На приёмку",
              rejected: "Отказы",
            }).map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Порядок
          <select
            value={filters.sort}
            onChange={(e) => update("sort", e.target.value)}
          >
            <option value="newest">Сначала новые</option>
            <option value="deadline">По сроку</option>
            <option value="priority">По приоритету</option>
          </select>
        </label>
        <label>
          Созданы с
          <input
            type="date"
            value={periodInputDate(filters.from_date)}
            onChange={(e) => update("from_date", e.target.value)}
          />
        </label>
        <label>
          По
          <input
            type="date"
            value={periodInputDate(filters.to_date)}
            onChange={(e) => update("to_date", e.target.value)}
          />
        </label>
        <button className="text-button" onClick={resetFilters}>
          Сбросить фильтры
        </button>
      </div>
      {(filters.from_date || filters.to_date) && (
        <p className="field-hint">
          Период создания:{" "}
          {filters.from_date.includes("T")
            ? formatDate(filters.from_date, true)
            : filters.from_date || "без начала"}{" "}
          —{" "}
          {filters.to_date.includes("T")
            ? formatDate(filters.to_date, true)
            : filters.to_date || "без конца"}
          .
        </p>
      )}
      {state.changed && (
        <p className="info-banner" role="status">
          Журнал мог измениться. Можно продолжить просмотр; обновление начнёт
          загрузку заново с первой страницы.
        </p>
      )}
      {state.error && (
        <ErrorBox
          message={`${state.error}${state.loaded ? " Сохранён последний загруженный результат." : ""}`}
          retry={() => void pager.restart(query)}
        />
      )}
      <p className="order-context" aria-live="polite">
        Загружено: {state.items.length} · найдено: {state.total}
        {state.loaded ? " · состав меняется при новых действиях" : ""}
      </p>
      {!state.loaded && state.busy ? (
        <Loading />
      ) : state.loaded && !state.items.length ? (
        <Empty title="Наряды не найдены" text="Измените фильтры или период." />
      ) : (
        <div className="journal-list">
          {state.items.map((order) => (
            <button
              className="journal-row"
              key={order.id}
              onClick={() => onSelect(order.id)}
            >
              <div>
                <span className="table-eyebrow">{order.number}</span>
                <strong>{order.title}</strong>
                <small>
                  {order.equipment_name} · {order.area_name}
                </small>
              </div>
              <div>
                <strong>{order.assignee_name}</strong>
                <small>
                  {order.brigade_id != null
                    ? "Ответственный · бригадный наряд"
                    : "Индивидуальное назначение"}
                </small>
              </div>
              <div className="journal-flags">
                <Priority value={order.priority} />
                <Status value={order.status} />
              </div>
              <div className={order.is_overdue ? "overdue" : ""}>
                <small>Выполнить до</small>
                <span>{formatDate(order.deadline, true)}</span>
              </div>
              <ChevronRight size={17} />
            </button>
          ))}
        </div>
      )}
      <div className="journal-paging">
        {state.next_cursor && (
          <button
            className="button secondary"
            disabled={state.busy}
            onClick={() => void pager.loadMore()}
          >
            {state.busy ? "Загружаем…" : "Показать ещё"}
          </button>
        )}
        {state.loaded && !state.next_cursor && (
          <span className="muted">
            В текущем просмотре показаны все найденные наряды.
          </span>
        )}
      </div>
    </section>
  );
}
