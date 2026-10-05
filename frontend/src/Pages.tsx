import { useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import {
  Activity,
  ArrowDownToLine,
  ArrowRight,
  ArrowUpRight,
  Award,
  BookOpen,
  Box,
  CalendarDays,
  ChartNoAxesCombined,
  Check,
  ChevronRight,
  CircleCheck,
  Clock3,
  Code2,
  Database,
  Download,
  Factory,
  FileSpreadsheet,
  Fingerprint,
  HardHat,
  Info,
  Layers3,
  LoaderCircle,
  Package,
  Pencil,
  Plus,
  Radio,
  Search,
  ShieldCheck,
  Smartphone,
  Sparkles,
  Star,
  Timer,
  TrendingUp,
  Users,
  Wrench,
  Zap,
} from "lucide-react";
import {
  api,
  formatDate,
  idValue,
  initials,
  number,
  roleNames,
  token,
} from "./model";
import type {
  Analytics,
  Employee,
  Id,
  Order,
  Reference,
  RefItem,
  User,
} from "./model";
import {
  Empty,
  ErrorBox,
  Loading,
  Metric,
  Modal,
  SectionTitle,
  Status,
} from "./ui";

export function EmployeesPage({
  employees,
  orders,
  reference,
  onSelect,
}: {
  employees: Employee[];
  orders: Order[];
  reference: Reference;
  onSelect: (id: Id) => void;
}) {
  const [search, setSearch] = useState("");
  const [status, setStatus] = useState("");
  const [brigade, setBrigade] = useState("");
  const workers = employees.filter((e) => e.role === "worker");
  const filtered = workers.filter(
    (e) =>
      (!search ||
        `${e.name} ${e.specialty}`
          .toLowerCase()
          .includes(search.toLowerCase())) &&
      (!status || e.status === status) &&
      (!brigade || String(e.brigade_id) === brigade),
  );
  return (
    <>
      <div className="metrics-grid">
        <Metric
          label="В команде"
          value={workers.length}
          icon={<Users size={20} />}
          detail={<span>исполнителей в системе</span>}
        />
        <Metric
          label="На смене"
          value={workers.filter((e) => e.on_shift).length}
          icon={<HardHat size={20} />}
          detail={<span className="metric-green">Готовы к работе</span>}
        />
        <Metric
          label="Выполняют наряды"
          value={workers.filter((e) => e.status === "busy").length}
          icon={<Wrench size={20} />}
          detail={<span>заняты прямо сейчас</span>}
        />
        <Metric
          label="Свободны"
          value={workers.filter((e) => e.status === "free").length}
          icon={<CircleCheck size={20} />}
          detail={<span className="metric-green">Можно назначить работу</span>}
        />
      </div>
      <section className="panel">
        <SectionTitle
          title="Люди, на которых всё держится"
          caption="Текущая загрузка исполнителей и личные результаты."
        />
        <div className="employee-filters">
          <label className="search-box">
            <Search size={17} />
            <input
              aria-label="Поиск сотрудника"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Имя или специальность"
            />
          </label>
          <select
            aria-label="Бригада"
            value={brigade}
            onChange={(e) => setBrigade(e.target.value)}
          >
            <option value="">Все бригады</option>
            {reference.brigades.map((b) => (
              <option key={b.id} value={b.id}>
                {b.name}
              </option>
            ))}
          </select>
          <select
            aria-label="Загрузка"
            value={status}
            onChange={(e) => setStatus(e.target.value)}
          >
            <option value="">Любая загрузка</option>
            <option value="free">Свободен</option>
            <option value="busy">В работе</option>
            <option value="queued">В очереди</option>
            <option value="off_shift">Вне смены</option>
          </select>
          <span className="muted">Найдено {filtered.length}</span>
        </div>
        {filtered.length ? (
          <div className="table-wrap">
            <table className="data-table employees-table">
              <thead>
                <tr>
                  <th>Сотрудник</th>
                  <th>Бригада / разряд</th>
                  <th>Статус</th>
                  <th>Текущий наряд</th>
                  <th>В очереди</th>
                  <th>Выполнено</th>
                  <th>Рейтинг</th>
                </tr>
              </thead>
              <tbody>
                {filtered.map((e, i) => {
                  const current = orders.find(
                    (o) =>
                      String(o.id) === String(e.current_order) ||
                      o.number === e.current_order,
                  );
                  return (
                    <tr key={e.id}>
                      <td>
                        <div className="table-person">
                          <span className={`avatar avatar-${i % 4}`}>
                            {initials(e.name)}
                          </span>
                          <div>
                            <strong>{e.name}</strong>
                            <small>{e.specialty}</small>
                          </div>
                        </div>
                      </td>
                      <td>
                        {reference.brigades.find((b) => b.id === e.brigade_id)
                          ?.name || "—"}
                        <small>{e.grade ? `${e.grade} разряд` : "—"}</small>
                      </td>
                      <td>
                        <span className={`employee-status ${e.status}`}>
                          <i />
                          {
                            (
                              {
                                busy: "В работе",
                                free: "Свободен",
                                queued: "В очереди",
                                off_shift: "Вне смены",
                              } as Record<string, string>
                            )[e.status]
                          }
                        </span>
                      </td>
                      <td>
                        {current ? (
                          <button
                            className="text-button"
                            onClick={() => onSelect(current.id)}
                          >
                            {current.number}
                            <ArrowUpRight size={13} />
                          </button>
                        ) : (
                          e.current_order || "—"
                        )}
                      </td>
                      <td>{e.queue_count}</td>
                      <td>{e.completed_count}</td>
                      <td>
                        <span className="rating-pill">
                          <Star size={13} />
                          {number(e.rating, 1)}
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        ) : (
          <Empty
            title="Сотрудники не найдены"
            text="Измените параметры фильтра."
          />
        )}
      </section>
    </>
  );
}
type PresetBounds = { from_date: string; to_date: string };
function productionPeriod(preset: "shift" | "day"): PresetBounds {
  const now = new Date();
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-CA", {
      timeZone: "Asia/Almaty",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      hourCycle: "h23",
    })
      .formatToParts(now)
      .map((part) => [part.type, part.value]),
  );
  const hour = Number(parts.hour);
  const startHour = preset === "day" ? 0 : hour >= 8 && hour < 20 ? 8 : 20;
  const start = new Date(
    `${parts.year}-${parts.month}-${parts.day}T${String(startHour).padStart(2, "0")}:00:00+05:00`,
  );
  if (preset === "shift" && hour < 8) start.setUTCDate(start.getUTCDate() - 1);
  return { from_date: start.toISOString(), to_date: now.toISOString() };
}
export function AnalyticsPage({
  reference: r,
  notify,
}: {
  reference: Reference;
  notify: (s: string) => void;
}) {
  const [data, setData] = useState<Analytics | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [days, setDays] = useState("90");
  const [presetBounds, setPresetBounds] = useState<PresetBounds | null>(null);
  const [filters, setFilters] = useState({
    area_id: "",
    equipment_id: "",
    assignee_id: "",
    brigade_id: "",
    from_date: "",
    to_date: "",
  });
  const [advanced, setAdvanced] = useState(false);
  const [exporting, setExporting] = useState(false);
  const [tab, setTab] = useState("overview");
  const query = useMemo(() => {
    const p = new URLSearchParams();
    p.set("days", ["7", "30", "90"].includes(days) ? days : "90");
    if (presetBounds) {
      p.set("from_date", presetBounds.from_date);
      p.set("to_date", presetBounds.to_date);
    }
    Object.entries(filters).forEach(([k, v]) => {
      if (v) p.set(k, v);
    });
    return p.toString();
  }, [days, filters, presetBounds]);
  useEffect(() => {
    let alive = true;
    setBusy(true);
    api<Analytics>(`/analytics?${query}`)
      .then((d) => {
        if (alive) {
          setData(d);
          setError("");
        }
      })
      .catch((e) => {
        if (alive) setError(e.message);
      })
      .finally(() => {
        if (alive) setBusy(false);
      });
    return () => {
      alive = false;
    };
  }, [query]);
  async function download(format: string) {
    setExporting(true);
    try {
      const res = await fetch(`/api/reports/export?${query}&format=${format}`, {
        headers: { Authorization: `Bearer ${token()}` },
      });
      if (!res.ok) throw new Error("Не удалось сформировать отчёт");
      const url = URL.createObjectURL(await res.blob());
      const a = document.createElement("a");
      a.href = url;
      a.download = `НарядAI-${new Date().toISOString().slice(0, 10)}.${format}`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
      notify("Отчёт сформирован");
    } catch (e) {
      notify((e as Error).message);
    } finally {
      setExporting(false);
    }
  }
  function choosePeriod(period: string) {
    setDays(period);
    setPresetBounds(
      period === "shift" || period === "day" ? productionPeriod(period) : null,
    );
    setFilters((current) => ({ ...current, from_date: "", to_date: "" }));
  }
  function filter(key: string, value: string) {
    if (key === "from_date" || key === "to_date") {
      setDays("custom");
      setPresetBounds(null);
    }
    setFilters((current) => ({
      ...current,
      [key]: value,
      ...(key === "area_id" ? { equipment_id: "" } : {}),
    }));
  }
  return (
    <>
      <div className="analytics-toolbar">
        <div className="period-switch">
          {[
            ["shift", "Смена"],
            ["day", "Сутки"],
            ["7", "7 дней"],
            ["30", "30 дней"],
            ["90", "90 дней"],
          ].map(([value, label]) => (
            <button
              className={days === value ? "active" : ""}
              key={value}
              onClick={() => choosePeriod(value)}
            >
              {label}
            </button>
          ))}
        </div>
        <select
          aria-label="Участок аналитики"
          value={filters.area_id}
          onChange={(e) => filter("area_id", e.target.value)}
        >
          <option value="">Все участки</option>
          {r.areas.map((a) => (
            <option key={a.id} value={a.id}>
              {a.name}
            </option>
          ))}
        </select>
        <button
          className="button secondary"
          onClick={() => setAdvanced((v) => !v)}
        >
          <CalendarDays size={16} />
          Уточнить период
        </button>
        <div className="filter-spacer" />
        <button
          className="button secondary"
          disabled={exporting}
          onClick={() => download("csv")}
        >
          <Download size={16} />
          CSV
        </button>
        <button
          className="button primary"
          disabled={exporting}
          onClick={() => download("xlsx")}
        >
          {exporting ? (
            <LoaderCircle className="spin" size={16} />
          ) : (
            <FileSpreadsheet size={16} />
          )}
          Отчёт Excel
        </button>
      </div>
      {advanced && (
        <div className="advanced-filters analytics-filters">
          <label>
            Начало периода
            <input
              type="date"
              value={filters.from_date}
              onChange={(e) => filter("from_date", e.target.value)}
            />
          </label>
          <label>
            Конец периода
            <input
              type="date"
              value={filters.to_date}
              onChange={(e) => filter("to_date", e.target.value)}
            />
          </label>
          <label>
            Оборудование
            <select
              value={filters.equipment_id}
              onChange={(e) => filter("equipment_id", e.target.value)}
            >
              <option value="">Всё оборудование</option>
              {r.equipment
                .filter(
                  (e) =>
                    !filters.area_id || String(e.area_id) === filters.area_id,
                )
                .map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.name}
                  </option>
                ))}
            </select>
          </label>
          <label>
            Исполнитель
            <select
              value={filters.assignee_id}
              onChange={(e) => filter("assignee_id", e.target.value)}
            >
              <option value="">Все исполнители</option>
              {r.employees
                .filter((e) => e.role === "worker")
                .map((a) => (
                  <option key={a.id} value={a.id}>
                    {a.name}
                  </option>
                ))}
            </select>
          </label>
          <label>
            Бригада
            <select
              value={filters.brigade_id}
              onChange={(e) => filter("brigade_id", e.target.value)}
            >
              <option value="">Все бригады</option>
              {r.brigades.map((a) => (
                <option key={a.id} value={a.id}>
                  {a.name}
                </option>
              ))}
            </select>
          </label>
          <button
            className="text-button"
            onClick={() => {
              setFilters({
                area_id: "",
                equipment_id: "",
                assignee_id: "",
                brigade_id: "",
                from_date: "",
                to_date: "",
              });
              setDays("90");
              setPresetBounds(null);
            }}
          >
            Сбросить
          </button>
        </div>
      )}
      <div className="panel-note">
        <Info size={15} />
        <span>
          Статистика по нарядам, выданным за выбранный период.
          {days === "shift"
            ? " Текущая смена: 08:00–20:00 или 20:00–08:00, время Алматы."
            : days === "day"
              ? " Сегодня с 00:00, время Алматы."
              : ""}
        </span>
      </div>
      {error && <ErrorBox message={error} />}{" "}
      {busy && !data ? (
        <Loading />
      ) : (
        data && (
          <div className={busy ? "data-refreshing" : ""}>
            <div className="metrics-grid analytics-metrics">
              <Metric
                label="Всего нарядов"
                value={number(data.summary.total)}
                icon={<ClipboardIcon />}
                detail={
                  <span>{number(data.summary.closed)} закрыто за период</span>
                }
              />
              <Metric
                label="Выполнено в срок"
                value={
                  <>
                    {number(data.summary.on_time_percent, 1)}
                    <small>%</small>
                  </>
                }
                icon={<Timer size={20} />}
                detail={<span className="metric-green">Соблюдение сроков</span>}
              />
              <Metric
                label="Средняя оценка"
                value={
                  <>
                    {number(data.summary.avg_score, 2)}
                    <small> / 5</small>
                  </>
                }
                icon={<Star size={20} />}
                detail={<span>по результатам приёмки</span>}
              />
              <Metric
                label="Время простоя"
                value={
                  <>
                    {number(data.summary.downtime_hours, 1)}
                    <small> ч</small>
                  </>
                }
                icon={<Factory size={20} />}
                detail={<span>по нарядам за период</span>}
              />
            </div>
            <div className="analytics-tabs tabs">
              {[
                ["overview", "Обзор"],
                ["team", "Рейтинг сотрудников"],
                ["equipment", "Оборудование и материалы"],
              ].map(([v, l]) => (
                <button
                  className={tab === v ? "active" : ""}
                  key={v}
                  onClick={() => setTab(v)}
                >
                  {l}
                </button>
              ))}
            </div>
            {tab === "overview" ? (
              <>
                <div className="charts-grid">
                  <section className="panel trend-panel">
                    <SectionTitle
                      title="Динамика работ"
                      caption="Плановые и внеплановые наряды за период"
                      action={
                        <span className="outlined-tag">НАРЯДЫ / ДЕНЬ</span>
                      }
                    />
                    <div className="chart">
                      <ResponsiveContainer width="100%" height="100%">
                        <AreaChart
                          data={data.trend}
                          margin={{ top: 16, right: 16, left: -26, bottom: 0 }}
                        >
                          <CartesianGrid
                            strokeDasharray="3 4"
                            vertical={false}
                            stroke="#e8ebea"
                          />
                          <XAxis
                            dataKey="date"
                            tickFormatter={(v) => formatDate(v)}
                            axisLine={false}
                            tickLine={false}
                            minTickGap={35}
                            tick={{ fontSize: 10, fill: "#8a9391" }}
                          />
                          <YAxis
                            allowDecimals={false}
                            axisLine={false}
                            tickLine={false}
                            tick={{ fontSize: 10, fill: "#8a9391" }}
                          />
                          <Tooltip
                            labelFormatter={(v) => formatDate(String(v))}
                            contentStyle={{
                              border: "1px solid #e0e4e1",
                              borderRadius: 8,
                              fontSize: 12,
                            }}
                          />
                          <Legend
                            iconType="circle"
                            iconSize={7}
                            wrapperStyle={{ fontSize: 11, paddingTop: 16 }}
                          />
                          <Area
                            type="monotone"
                            dataKey="planned"
                            name="Плановые"
                            stroke="#367d6d"
                            fill="#e3eee8"
                            strokeWidth={2}
                            fillOpacity={0.8}
                          />
                          <Area
                            type="monotone"
                            dataKey="unplanned"
                            name="Внеплановые"
                            stroke="#ed6c35"
                            fill="#fff0e8"
                            strokeWidth={2}
                            fillOpacity={0.7}
                          />
                        </AreaChart>
                      </ResponsiveContainer>
                    </div>
                  </section>
                  <section className="panel area-panel">
                    <SectionTitle
                      title="Нагрузка по участкам"
                      caption="Количество нарядов за период"
                    />
                    <div className="area-ranking">
                      {data.by_area.map((a, i) => (
                        <div key={a.name}>
                          <div>
                            <span>
                              <i>{String(i + 1).padStart(2, "0")}</i>
                              {a.name}
                            </span>
                            <strong>{a.count}</strong>
                          </div>
                          <div className="progress-track">
                            <div
                              style={{
                                width: `${(a.count / Math.max(...data.by_area.map((v) => v.count), 1)) * 100}%`,
                              }}
                            />
                          </div>
                          <small>{number(a.downtime_hours, 1)} ч простоя</small>
                        </div>
                      ))}
                    </div>
                  </section>
                </div>
                <section className="insights-section">
                  <SectionTitle
                    title="На что обратить внимание"
                    caption="Примеры аналитических сигналов на данных демонстрационной системы"
                    action={
                      <span className="stub-tag">
                        <Sparkles size={12} />
                        ИИ · ЗАГЛУШКА
                      </span>
                    }
                  />
                  <div className="insights-grid">
                    {data.insights.map((ins, i) => (
                      <article key={i} className="insight-card">
                        <span
                          className={`insight-icon insight-${ins.severity}`}
                        >
                          {i === 0 ? (
                            <Wrench size={19} />
                          ) : i === 1 ? (
                            <Activity size={19} />
                          ) : (
                            <Package size={19} />
                          )}
                        </span>
                        <span className="insight-number">0{i + 1}</span>
                        <h3>{ins.title}</h3>
                        <p>{ins.description}</p>
                        <span className="insight-foot">
                          Демонстрационный алгоритм
                          <Info size={13} />
                        </span>
                      </article>
                    ))}
                  </div>
                </section>
                <div className="ai-summary">
                  <Sparkles size={20} />
                  <div>
                    <strong>
                      Краткий обзор периода{" "}
                      <span className="stub-tag">ЗАГЛУШКА</span>
                    </strong>
                    <p>{data.ai_summary}</p>
                  </div>
                </div>
              </>
            ) : tab === "team" ? (
              <section className="panel">
                <SectionTitle
                  title="Результаты команды"
                  caption="Итоговый рейтинг: 60% качество, 30% сроки, 10% отсутствие доработок."
                />
                <div className="table-wrap">
                  <table className="data-table">
                    <thead>
                      <tr>
                        <th>Место</th>
                        <th>Сотрудник</th>
                        <th>Бригада</th>
                        <th>Закрыто</th>
                        <th>Качество</th>
                        <th>В срок</th>
                        <th>Доработки</th>
                        <th>Рейтинг</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.rankings.map((e, i) => (
                        <tr key={e.id}>
                          <td>
                            <span className={`rank ${i < 3 ? "rank-top" : ""}`}>
                              {i < 3 ? <Award size={17} /> : i + 1}
                            </span>
                          </td>
                          <td>
                            <div className="table-person">
                              <span className={`avatar avatar-${i % 4}`}>
                                {initials(e.name)}
                              </span>
                              <div>
                                <strong>{e.name}</strong>
                                <small>{e.specialty}</small>
                              </div>
                            </div>
                          </td>
                          <td>{e.brigade}</td>
                          <td>{e.closed_count}</td>
                          <td>{number(e.quality, 1)} / 5</td>
                          <td>{number(e.on_time, 1)}%</td>
                          <td>{number(e.rework_rate, 1)}%</td>
                          <td>
                            <span className="rating-pill">
                              <Star size={13} />
                              {number(e.score, 1)}
                            </span>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
                <div className="panel-note">
                  <Info size={15} />
                  Рейтинг рассчитан на закрытых нарядах за выбранный период; это
                  справочный показатель.
                </div>
              </section>
            ) : (
              <div className="equipment-analytics">
                <section className="panel">
                  <SectionTitle
                    title="Оборудование"
                    caption="Нагрузка обслуживания и суммарные простои"
                  />
                  <div className="table-wrap">
                    <table className="data-table">
                      <thead>
                        <tr>
                          <th>Оборудование</th>
                          <th>Участок</th>
                          <th>Наряды</th>
                          <th>Простой, ч</th>
                        </tr>
                      </thead>
                      <tbody>
                        {data.equipment.map((e) => (
                          <tr key={e.id}>
                            <td>
                              <strong>{e.name}</strong>
                            </td>
                            <td>{e.area_name}</td>
                            <td>{e.orders}</td>
                            <td>{number(e.downtime_hours, 1)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                </section>
                <section className="panel">
                  <SectionTitle
                    title="Расход материалов"
                    caption="По отчётам исполнителей"
                  />
                  <div className="table-wrap">
                    <table className="data-table">
                      <thead>
                        <tr>
                          <th>Материал</th>
                          <th>Количество</th>
                          <th>Ед.</th>
                        </tr>
                      </thead>
                      <tbody>
                        {data.materials.map((m, i) => (
                          <tr key={i}>
                            <td>{m.name}</td>
                            <td>{number(m.quantity, 2)}</td>
                            <td>{m.unit}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                  {!data.materials.length && (
                    <Empty
                      title="Нет расхода материалов"
                      text="За выбранный период материалы не использовались."
                    />
                  )}
                </section>
              </div>
            )}
          </div>
        )
      )}
    </>
  );
}
function ClipboardIcon() {
  return <Layers3 size={20} />;
}
const collections = [
  { key: "equipment", label: "Оборудование", icon: Factory },
  { key: "areas", label: "Участки", icon: Layers3 },
  { key: "employees", label: "Сотрудники", icon: Users },
  { key: "brigades", label: "Бригады", icon: HardHat },
  { key: "fault_codes", label: "Неисправности", icon: Wrench },
  { key: "materials", label: "Материалы", icon: Package },
  { key: "time_norms", label: "Нормы времени", icon: Clock3 },
];
type Field = {
  key: string;
  label: string;
  type?: string;
  options?: string[];
  collection?: keyof Reference;
  required?: boolean;
  maxLength?: number;
};
const schemas: Record<string, Field[]> = {
  areas: [
    { key: "name", label: "Название участка", required: true, maxLength: 120 },
  ],
  brigades: [
    { key: "name", label: "Название бригады", required: true, maxLength: 120 },
  ],
  equipment: [
    { key: "name", label: "Название", required: true, maxLength: 120 },
    {
      key: "inventory_number",
      label: "Инвентарный номер",
      required: true,
      maxLength: 80,
    },
    { key: "area_id", label: "Участок", collection: "areas", required: true },
    { key: "type", label: "Тип оборудования", required: true, maxLength: 80 },
    {
      key: "criticality",
      label: "Критичность",
      options: ["high", "medium", "low"],
    },
  ],
  employees: [
    { key: "name", label: "ФИО", required: true, maxLength: 120 },
    { key: "login", label: "Логин", required: true, maxLength: 80 },
    {
      key: "role",
      label: "Роль",
      options: ["worker", "master", "manager", "admin"],
      required: true,
    },
    { key: "specialty", label: "Специальность", maxLength: 120 },
    { key: "grade", label: "Разряд", type: "number" },
    { key: "brigade_id", label: "Бригада", collection: "brigades" },
    { key: "on_shift", label: "На смене", type: "checkbox" },
  ],
  fault_codes: [
    { key: "code", label: "Код", required: true, maxLength: 30 },
    { key: "name", label: "Неисправность", required: true, maxLength: 180 },
  ],
  materials: [
    { key: "name", label: "Материал", required: true, maxLength: 180 },
    { key: "unit", label: "Единица измерения", required: true, maxLength: 30 },
  ],
  time_norms: [
    { key: "name", label: "Вид работы", required: true, maxLength: 180 },
    { key: "hours", label: "Норма, часов", type: "number", required: true },
  ],
};
const displayOption = (value: string) =>
  roleNames[value] ||
  (
    { high: "Высокая", medium: "Средняя", low: "Низкая" } as Record<
      string,
      string
    >
  )[value] ||
  value;

export function ReferencePage({
  reference: r,
  user,
  refresh,
  notify,
}: {
  reference: Reference;
  user: User;
  refresh: () => Promise<void>;
  notify: (s: string) => void;
}) {
  const [collection, setCollection] = useState("equipment");
  const [search, setSearch] = useState("");
  const [edit, setEdit] = useState<RefItem | true | null>(null);
  const [form, setForm] = useState<Record<string, string | number | boolean>>(
    {},
  );
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const items = r[collection as keyof Reference].filter((v) =>
    Object.values(v).some((s) =>
      String(s).toLocaleLowerCase().includes(search.toLocaleLowerCase()),
    ),
  );
  const label = collections.find((c) => c.key === collection)?.label;
  const fields = schemas[collection];

  function openEdit(item: RefItem | true) {
    setEdit(item);
    setForm({
      ...Object.fromEntries(
        fields.map((f) => [
          f.key,
          item === true
            ? f.type === "checkbox"
              ? true
              : f.key === "grade"
                ? 0
                : f.options?.[0] || ""
            : (item[f.key] ?? ""),
        ]),
      ),
      pin: "",
    });
    setError("");
  }
  function closeEdit() {
    setEdit(null);
    setForm({});
    setError("");
  }
  async function save(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError("");
    try {
      const body: Record<string, string | number | boolean | null> = {};
      for (const field of fields) {
        const raw = form[field.key];
        const value = typeof raw === "string" ? raw.trim() : raw;
        if (field.type === "checkbox") {
          body[field.key] = Boolean(value);
        } else if (field.collection) {
          if (value === "") {
            if (field.required)
              throw new Error(`Заполните поле «${field.label}».`);
            body[field.key] = null;
          } else {
            body[field.key] = idValue(String(value));
          }
        } else if (field.type === "number") {
          if (value === "") {
            if (field.key === "grade") body[field.key] = 0;
            else if (field.required)
              throw new Error(`Заполните поле «${field.label}».`);
          } else {
            const numeric = Number(value);
            if (!Number.isFinite(numeric))
              throw new Error(`Некорректное число: «${field.label}».`);
            if (
              field.key === "grade" &&
              (!Number.isInteger(numeric) || numeric < 0 || numeric > 8)
            )
              throw new Error("Разряд должен быть целым числом от 0 до 8.");
            if (field.key === "hours" && (numeric <= 0 || numeric > 1000))
              throw new Error(
                "Норма времени должна быть больше 0 и не более 1000 часов.",
              );
            body[field.key] = numeric;
          }
        } else if (value === "") {
          if (field.required)
            throw new Error(`Заполните поле «${field.label}».`);
          // Empty optional strings are omitted because the API validates supplied strings.
        } else {
          body[field.key] = String(value);
        }
      }
      if (collection === "employees") {
        const pin = String(form.pin ?? "");
        if (edit === true || pin !== "") {
          if (!/^[0-9]{4,12}$/.test(pin))
            throw new Error("PIN должен содержать от 4 до 12 цифр.");
          body.pin = pin;
        }
      }
      await api(
        `/reference/${collection}${edit !== true && edit ? `/${edit.id}` : ""}`,
        {
          method: edit === true ? "POST" : "PATCH",
          body: JSON.stringify(body),
        },
      );
      await refresh();
      closeEdit();
      notify("Справочник обновлён");
    } catch (error) {
      setError((error as Error).message);
    } finally {
      setBusy(false);
    }
  }
  const cell = (item: RefItem, field: Field) =>
    field.type === "checkbox" ? (
      <span
        className={`employee-status ${item[field.key] ? "free" : "off_shift"}`}
      >
        <i />
        {item[field.key] ? "Да" : "Нет"}
      </span>
    ) : field.collection ? (
      r[field.collection].find((v) => String(v.id) === String(item[field.key]))
        ?.name || "—"
    ) : field.options ? (
      displayOption(item[field.key])
    ) : (
      (item[field.key] ?? "—")
    );

  return (
    <div className="reference-layout">
      <aside className="reference-nav">
        {collections.map(({ key, label, icon: Icon }) => (
          <button
            key={key}
            className={collection === key ? "active" : ""}
            onClick={() => {
              setCollection(key);
              setSearch("");
            }}
          >
            <Icon size={17} />
            <span>{label}</span>
            <small>{r[key as keyof Reference].length}</small>
          </button>
        ))}
      </aside>
      <section className="panel reference-panel">
        <SectionTitle
          title={label || ""}
          caption={`${items.length} записей · ${user.role === "admin" ? "Управление справочником" : "Доступ для чтения"}`}
          action={
            user.role === "admin" ? (
              <button className="button primary" onClick={() => openEdit(true)}>
                <Plus size={16} />
                Добавить
              </button>
            ) : undefined
          }
        />
        <div className="reference-search">
          <label className="search-box">
            <Search size={17} />
            <input
              aria-label="Поиск в справочнике"
              placeholder="Поиск по справочнику"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </label>
        </div>
        <div className="table-wrap">
          <table className="data-table">
            <thead>
              <tr>
                {fields.map((field) => (
                  <th key={field.key}>{field.label}</th>
                ))}
                {user.role === "admin" && <th />}
              </tr>
            </thead>
            <tbody>
              {items.map((item) => (
                <tr key={item.id}>
                  {fields.map((field) => (
                    <td key={field.key}>{cell(item, field)}</td>
                  ))}
                  {user.role === "admin" && (
                    <td>
                      <button
                        className="icon-button"
                        title={`Редактировать ${item.name}`}
                        onClick={() => openEdit(item)}
                      >
                        <Pencil size={15} />
                      </button>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {!items.length && (
          <Empty
            title="Записи не найдены"
            text="Попробуйте другой поисковый запрос."
          />
        )}
      </section>
      {edit && (
        <Modal
          title={edit === true ? "Добавить запись" : "Изменить запись"}
          subtitle={label}
          onClose={closeEdit}
        >
          <form onSubmit={save} autoComplete="off">
            <div className="modal-body">
              {fields.map((field) => (
                <label
                  key={field.key}
                  className={field.type === "checkbox" ? "checkbox-label" : ""}
                >
                  {field.label}
                  {field.required && <b> *</b>}
                  {field.type === "checkbox" ? (
                    <input
                      type="checkbox"
                      checked={!!form[field.key]}
                      onChange={(e) =>
                        setForm({ ...form, [field.key]: e.target.checked })
                      }
                    />
                  ) : field.collection || field.options ? (
                    <select
                      required={field.required}
                      value={String(form[field.key] ?? "")}
                      onChange={(e) =>
                        setForm({ ...form, [field.key]: e.target.value })
                      }
                    >
                      <option value="">
                        {field.collection && !field.required
                          ? "Без бригады"
                          : "Выберите значение"}
                      </option>
                      {field.collection
                        ? r[field.collection].map((v) => (
                            <option key={v.id} value={v.id}>
                              {v.name}
                            </option>
                          ))
                        : field.options?.map((v) => (
                            <option key={v} value={v}>
                              {displayOption(v)}
                            </option>
                          ))}
                    </select>
                  ) : (
                    <input
                      required={field.required}
                      type={field.type || "text"}
                      min={field.key === "hours" ? "0.1" : "0"}
                      step={field.key === "hours" ? "0.1" : "1"}
                      max={
                        field.key === "grade"
                          ? "8"
                          : field.key === "hours"
                            ? "1000"
                            : undefined
                      }
                      maxLength={field.maxLength}
                      value={String(form[field.key] ?? "")}
                      onChange={(e) =>
                        setForm({ ...form, [field.key]: e.target.value })
                      }
                    />
                  )}
                </label>
              ))}
              {collection === "employees" && (
                <label>
                  {edit === true ? "PIN для входа" : "Новый PIN"}
                  {edit === true && <b> *</b>}
                  <input
                    type="password"
                    name="new-pin"
                    autoComplete="new-password"
                    inputMode="numeric"
                    pattern="[0-9]{4,12}"
                    minLength={4}
                    maxLength={12}
                    required={edit === true}
                    value={String(form.pin ?? "")}
                    onChange={(e) => setForm({ ...form, pin: e.target.value })}
                    aria-describedby="employee-pin-hint"
                  />
                  <span className="field-hint" id="employee-pin-hint">
                    {edit === true
                      ? "От 4 до 12 цифр. PIN потребуется сотруднику для входа."
                      : "Оставьте поле пустым, чтобы сохранить текущий PIN. Для замены укажите от 4 до 12 цифр."}
                  </span>
                </label>
              )}
              {error && <ErrorBox message={error} />}
            </div>
            <footer className="modal-footer">
              <button
                type="button"
                className="button secondary"
                onClick={closeEdit}
              >
                Отмена
              </button>
              <button className="button primary" disabled={busy}>
                {busy ? (
                  <LoaderCircle className="spin" size={16} />
                ) : (
                  <Check size={16} />
                )}
                Сохранить
              </button>
            </footer>
          </form>
        </Modal>
      )}
    </div>
  );
}
export function IntegrationsPage() {
  const [data, setData] = useState<Record<
    string,
    { mode: string; status: string; description: string }
  > | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    api<Record<string, { mode: string; status: string; description: string }>>(
      "/integrations",
    )
      .then(setData)
      .catch((e) => setError(e.message));
  }, []);
  return (
    <>
      {error && <ErrorBox message={error} />}{" "}
      {!data ? (
        <Loading />
      ) : (
        <>
          <div className="integration-intro">
            <div className="integration-logo">
              <PlugIcon />
            </div>
            <div>
              <span className="eyebrow">ОТКРЫТАЯ АРХИТЕКТУРА</span>
              <h2>Готова к следующему шагу</h2>
              <p>
                Рабочая веб-панель, API и база данных. Нативное приложение и
                интеллектуальные сервисы подключаются через выделенные
                интерфейсы.
              </p>
            </div>
            <span className="outlined-tag">DEMO / V1.0</span>
          </div>
          <div className="integration-grid">
            {[
              {
                key: "ai",
                title: "Интеллектуальная проверка",
                icon: Sparkles,
                subtitle: "AI ADAPTER",
                stub: true,
              },
              {
                key: "native",
                title: "Приложение исполнителя",
                icon: Smartphone,
                subtitle: "NATIVE ADAPTER",
                stub: true,
              },
              {
                key: "realtime",
                title: "Обновления в реальном времени",
                icon: Radio,
                subtitle: "REALTIME",
                stub: false,
              },
            ].map(({ key, title, icon: Icon, subtitle, stub }) => (
              <section className="integration-card" key={key}>
                <div className="integration-card-top">
                  <span className="integration-icon">
                    <Icon size={25} />
                  </span>
                  <span className={stub ? "stub-tag" : "status status-closed"}>
                    {stub ? "ЗАГЛУШКА" : "ПОДКЛЮЧЕНО"}
                  </span>
                </div>
                <div className="eyebrow">{subtitle}</div>
                <h3>{title}</h3>
                <p>{data[key]?.description}</p>
                <div className="integration-meta">
                  <span>Режим</span>
                  <code>{data[key]?.mode}</code>
                  <span>Статус</span>
                  <code>{data[key]?.status}</code>
                </div>
                {key === "ai" && (
                  <div className="integration-note">
                    <Info size={15} />
                    <span>
                      Выводы создаёт детерминированный алгоритм. Автоматической
                      приёмки нет: решение всегда за мастером.
                    </span>
                  </div>
                )}
                {key === "native" && (
                  <div className="integration-note">
                    <Info size={15} />
                    <span>
                      Действия доступны через веб-симулятор. Push-события
                      сохраняются на сервере; реальная отправка не выполняется.
                    </span>
                  </div>
                )}
                {key === "realtime" && (
                  <div className="integration-note">
                    <ShieldCheck size={15} />
                    <span>
                      WebSocket с авторизацией. При разрыве соединения данные
                      обновляются каждые 5 секунд.
                    </span>
                  </div>
                )}
              </section>
            ))}
          </div>
          <section className="panel architecture-panel">
            <SectionTitle
              title="Как связана система"
              caption="Разделённые компоненты и единый журнал производственных событий"
            />
            <div className="architecture-flow">
              <div>
                <Layers3 size={25} />
                <strong>Веб-панель</strong>
                <small>React · TypeScript</small>
              </div>
              <ArrowRight size={22} />
              <div>
                <Code2 size={25} />
                <strong>Сервер API</strong>
                <small>Python · FastAPI</small>
              </div>
              <ArrowRight size={22} />
              <div>
                <Database size={25} />
                <strong>База данных</strong>
                <small>PostgreSQL</small>
              </div>
            </div>
            <div className="panel-note">
              <Fingerprint size={16} />
              Авторизация по ролям · защищённые фотографии · аудит каждого
              действия
            </div>
          </section>
        </>
      )}
    </>
  );
}
function PlugIcon() {
  return <Zap size={31} />;
}
