import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import {
  Activity,
  ArrowDown,
  ArrowRight,
  ArrowUpRight,
  Bell,
  BookOpen,
  CalendarDays,
  ChartNoAxesCombined,
  Check,
  CheckCheck,
  ChevronDown,
  ChevronRight,
  CircleHelp,
  ClipboardList,
  Factory,
  Gauge,
  Layers3,
  LayoutDashboard,
  LogOut,
  Menu,
  Plus,
  Plug,
  Radio,
  Search,
  Settings2,
  ShieldCheck,
  Sparkles,
  Users,
  Wrench,
  X,
  CircleCheck,
  TriangleAlert,
  Timer,
  Zap,
  LoaderCircle,
} from "lucide-react";
import {
  api,
  emptyReference,
  formatDate,
  formatTime,
  initials,
  number,
  post,
  roleNames,
  token,
} from "./model";
import type {
  Dashboard,
  Employee,
  Id,
  Notice,
  Order,
  Reference,
  User,
} from "./model";
import { Empty, ErrorBox, Loading, Metric, SectionTitle } from "./ui";
import { OrderBoard, CreateOrder, OrderDialog } from "./Orders";
import {
  AnalyticsPage,
  ReferencePage,
  IntegrationsPage,
  EmployeesPage,
} from "./Pages";

type Page =
  | "dashboard"
  | "orders"
  | "employees"
  | "analytics"
  | "reference"
  | "integrations";
const navigation: { id: Page; name: string; icon: typeof Gauge }[] = [
  { id: "dashboard", name: "Обзор смены", icon: LayoutDashboard },
  { id: "orders", name: "Наряды", icon: ClipboardList },
  { id: "employees", name: "Сотрудники", icon: Users },
  { id: "analytics", name: "Аналитика", icon: ChartNoAxesCombined },
];

function Login({ onLogin }: { onLogin: (user: User) => void }) {
  const [login, setLogin] = useState("master");
  const [pin, setPin] = useState("1234");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function submit(e?: FormEvent, demo?: string) {
    e?.preventDefault();
    setBusy(true);
    setError("");
    try {
      const res = await post<{ token: string; user: User }>("/auth/login", {
        login: demo || login,
        pin: demo ? "1234" : pin,
      });
      localStorage.setItem("naryad_token", res.token);
      onLogin(res.user);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="login-page">
      <aside className="login-story">
        <Brand />
        <div className="login-story-copy">
          <div className="eyebrow light">КОСТАНАЙСКИЕ МИНЕРАЛЫ</div>
          <h1>
            Каждая задача.
            <br />
            Под контролем<span>.</span>
          </h1>
          <p>
            Единое рабочее пространство для смены,
            <br />
            оборудования и людей.
          </p>
          <div className="login-illustration">
            <div className="illustration-caption">
              <span className="live-dot" /> ПРОИЗВОДСТВО В РИТМЕ
            </div>
            <div className="conveyor">
              <span />
              <span />
              <span />
              <span />
              <span />
              <span />
              <span />
            </div>
            <div className="factory-blocks">
              <div />
              <div />
              <div />
              <div />
            </div>
            <div className="illustration-line">
              <Factory size={34} />
              <div />
              <Wrench size={28} />
              <div />
              <CircleCheck size={28} />
            </div>
          </div>
          <div className="login-features">
            <span>
              <ClipboardList size={17} /> Электронные наряды
            </span>
            <span>
              <Activity size={17} /> Прозрачная смена
            </span>
            <span>
              <ShieldCheck size={17} /> Контроль качества
            </span>
          </div>
        </div>
        <div className="login-footer">
          ЦИФРОВОЕ ПРОИЗВОДСТВО <span>01 / ОПЕРАЦИОННАЯ ЭФФЕКТИВНОСТЬ</span>
        </div>
      </aside>
      <main className="login-main">
        <div className="login-top">
          <span className="outlined-tag">ДЕМОНСТРАЦИОННАЯ СРЕДА</span>
          <span>RU</span>
        </div>
        <div className="login-form">
          <div className="login-mark">
            <Factory size={27} />
          </div>
          <h2>С возвращением</h2>
          <p>Войдите, чтобы начать работу со сменой.</p>
          <form onSubmit={submit}>
            <label>
              Логин
              <input
                autoComplete="username"
                value={login}
                onChange={(e) => setLogin(e.target.value)}
                required
                placeholder="Ваш логин"
              />
            </label>
            <label>
              PIN-код
              <input
                autoComplete="current-password"
                type="password"
                value={pin}
                onChange={(e) => setPin(e.target.value)}
                required
                placeholder="••••"
              />
            </label>
            {error && <ErrorBox message={error} />}
            <button className="button primary login-submit" disabled={busy}>
              {busy ? (
                <LoaderCircle size={18} className="spin" />
              ) : (
                <>
                  Войти в систему
                  <ArrowRight size={18} />
                </>
              )}
            </button>
          </form>
          <div className="login-demo">
            <span>ПОСМОТРЕТЬ В РОЛИ</span>
            <div>
              {["master", "manager", "worker", "admin"].map((r) => (
                <button
                  key={r}
                  disabled={busy}
                  onClick={() => submit(undefined, r)}
                >
                  {roleNames[r]}
                  <ArrowUpRight size={14} />
                </button>
              ))}
            </div>
            <p>Демо-аккаунты · PIN 1234 · Учебные данные</p>
          </div>
        </div>
        <div className="login-bottom">
          НарядAI · Система управления обслуживанием <span>v1.0</span>
        </div>
      </main>
    </div>
  );
}
function Brand() {
  return (
    <div className="brand">
      <div className="brand-symbol">
        <Layers3 size={24} strokeWidth={2.2} />
      </div>
      <span>
        наряд<span className="brand-ai">AI</span>
        <small>УПРАВЛЕНИЕ ПРОИЗВОДСТВОМ</small>
      </span>
    </div>
  );
}

export default function App() {
  const [user, setUser] = useState<User | null>(null);
  const [authLoading, setAuthLoading] = useState(!!token());
  const [page, setPage] = useState<Page>("dashboard");
  const [reference, setReference] = useState<Reference>(emptyReference);
  const [orders, setOrders] = useState<Order[]>([]);
  const [employees, setEmployees] = useState<Employee[]>([]);
  const [dashboard, setDashboard] = useState<Dashboard | null>(null);
  const [notices, setNotices] = useState<Notice[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [selected, setSelected] = useState<Id | null>(null);
  const [create, setCreate] = useState(false);
  const [notifications, setNotifications] = useState(false);
  const [menu, setMenu] = useState(false);
  const [toast, setToast] = useState("");
  const [version, setVersion] = useState(0);
  const [online, setOnline] = useState(false);
  const [quickSearch, setQuickSearch] = useState("");
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const notify = useCallback((message: string) => {
    setToast(message);
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(""), 4500);
  }, []);
  const logout = useCallback(() => {
    localStorage.removeItem("naryad_token");
    setUser(null);
    setOrders([]);
    setNotices([]);
    setReference(emptyReference);
    setDashboard(null);
    setSelected(null);
    setCreate(false);
    setMenu(false);
    setNotifications(false);
    setQuickSearch("");
    setToast("");
    setError("");
    setAuthLoading(false);
    setPage("dashboard");
  }, []);
  useEffect(() => {
    if (token())
      api<User>("/auth/me")
        .then(setUser)
        .catch(() => logout())
        .finally(() => setAuthLoading(false));
    window.addEventListener("naryad:unauthorized", logout);
    return () => window.removeEventListener("naryad:unauthorized", logout);
  }, [logout]);
  const refresh = useCallback(async () => {
    if (!token()) return;
    try {
      const [r, o, e, d, n] = await Promise.all([
        api<Reference>("/reference"),
        api<Order[]>("/orders"),
        api<Employee[]>("/employees"),
        api<Dashboard>("/dashboard"),
        api<Notice[]>("/notifications"),
      ]);
      setReference(r);
      setOrders(o);
      setEmployees(e);
      setDashboard(d);
      setNotices(n);
      setError("");
      setVersion((v) => v + 1);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    if (!user) return;
    setLoading(true);
    void refresh();
    const timer = setInterval(() => void refresh(), 5000);
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(
      `${proto}//${location.host}/api/ws?token=${encodeURIComponent(token() || "")}`,
    );
    const heartbeat = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) ws.send("ping");
    }, 30000);
    ws.onopen = () => setOnline(true);
    ws.onclose = () => setOnline(false);
    ws.onerror = () => setOnline(false);
    ws.onmessage = (e) => {
      try {
        const v = JSON.parse(e.data);
        if (v.type !== "connected") void refresh();
      } catch {}
    };
    return () => {
      clearInterval(timer);
      clearInterval(heartbeat);
      ws.close();
      setOnline(false);
    };
  }, [user, refresh]);
  useEffect(
    () => () => {
      if (toastTimer.current) clearTimeout(toastTimer.current);
    },
    [],
  );
  const canManage = user?.role === "master" || user?.role === "admin";
  const title =
    navigation.find((n) => n.id === page)?.name ||
    (
      { reference: "Справочники", integrations: "Интеграции" } as Record<
        string,
        string
      >
    )[page];
  const unread = notices.filter((n) => !n.read).length;
  async function signOut() {
    try {
      await post("/auth/logout", {});
    } catch {
    } finally {
      logout();
    }
  }
  function navigate(p: Page) {
    setPage(p);
    setMenu(false);
    setQuickSearch("");
  }
  async function readNotice(n: Notice) {
    try {
      await post(`/notifications/${n.id}/read`, {});
      setNotices((ns) =>
        ns.map((v) => (v.id === n.id ? { ...v, read: true } : v)),
      );
      if (n.order_id) {
        setSelected(n.order_id);
        setNotifications(false);
      }
    } catch (e) {
      notify((e as Error).message);
    }
  }
  if (authLoading)
    return (
      <div className="auth-loading">
        <Loading />
      </div>
    );
  if (!user)
    return (
      <Login
        onLogin={(u) => {
          setLoading(true);
          setUser(u);
        }}
      />
    );
  return (
    <div className="app-shell">
      {menu && (
        <div className="sidebar-backdrop" onClick={() => setMenu(false)} />
      )}
      <aside className={`sidebar ${menu ? "is-open" : ""}`}>
        <Brand />
        <div className="workspace-switch">
          <span className="workspace-avatar">
            <Factory size={17} />
          </span>
          <div>
            <strong>Костанайские минералы</strong>
            <small>Производственный комплекс</small>
          </div>
          <ChevronDown size={15} />
        </div>
        <div className="nav-caption">РАБОЧЕЕ ПРОСТРАНСТВО</div>
        <nav>
          {navigation.map(({ id, name, icon: Icon }) => (
            <button
              key={id}
              className={page === id ? "active" : ""}
              onClick={() => navigate(id)}
            >
              <Icon size={19} />
              <span>{name}</span>
              {id === "orders" && (
                <span className="nav-count">{dashboard?.active || 0}</span>
              )}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="nav-caption">СИСТЕМА</div>
          <nav>
            <button
              className={page === "reference" ? "active" : ""}
              onClick={() => navigate("reference")}
            >
              <BookOpen size={19} />
              <span>Справочники</span>
            </button>
            <button
              className={page === "integrations" ? "active" : ""}
              onClick={() => navigate("integrations")}
            >
              <Plug size={19} />
              <span>Интеграции</span>
              <span className="tiny-dot" />
            </button>
          </nav>
          <div className="sidebar-status">
            <span className="live-dot" />
            <div>
              <strong>
                {online
                  ? "Данные в реальном времени"
                  : "Обновление каждые 5 секунд"}
              </strong>
              <small>Демонстрационная среда</small>
            </div>
          </div>
          <div className="sidebar-user">
            <div className="avatar user-avatar">{initials(user.name)}</div>
            <div>
              <strong>{user.name}</strong>
              <small>{roleNames[user.role]}</small>
            </div>
            <button
              title="Выйти"
              aria-label="Выйти"
              onClick={() => void signOut()}
            >
              <LogOut size={17} />
            </button>
          </div>
        </div>
      </aside>
      <div className="main-shell">
        <header className="topbar">
          <div className="breadcrumb">
            <button
              className="icon-button mobile-menu"
              onClick={() => setMenu(true)}
              aria-label="Открыть меню"
            >
              <Menu size={21} />
            </button>
            <span>Рабочее пространство</span>
            <ChevronRight size={14} />
            <strong>{title}</strong>
          </div>
          <div className="topbar-right">
            <span className="topbar-date">
              <CalendarDays size={15} />
              {new Intl.DateTimeFormat("ru-RU", {
                timeZone: "Asia/Almaty",
                day: "numeric",
                month: "long",
                year: "numeric",
              }).format(new Date())}
            </span>
            <span className="top-divider" />
            <div className="notification-wrap">
              <button
                className={`icon-button ${notifications ? "selected" : ""}`}
                onClick={() => setNotifications((v) => !v)}
                aria-label="Уведомления"
              >
                <Bell size={19} />
                {unread > 0 && <span className="notification-dot" />}
              </button>
              {notifications && (
                <div className="notification-panel">
                  <div className="notification-head">
                    <strong>
                      Уведомления <span>{unread}</span>
                    </strong>
                    <button
                      className="icon-button"
                      onClick={() => setNotifications(false)}
                      aria-label="Закрыть уведомления"
                    >
                      <X size={17} />
                    </button>
                  </div>
                  {notices.length ? (
                    notices.slice(0, 40).map((n) => (
                      <button
                        key={n.id}
                        className={`notice ${n.read ? "read" : ""}`}
                        onClick={() => readNotice(n)}
                      >
                        <span
                          className={`notice-icon ${n.kind.includes("overdue") ? "red" : ""}`}
                        >
                          <Bell size={17} />
                        </span>
                        <span>
                          <strong>{n.title}</strong>
                          <p>{n.message}</p>
                          <small>{formatDate(n.created_at, true)}</small>
                        </span>
                        {!n.read && <i />}
                      </button>
                    ))
                  ) : (
                    <Empty
                      title="Всё спокойно"
                      text="Новые события появятся здесь."
                    />
                  )}
                </div>
              )}
            </div>
            <span className="avatar top-avatar">{initials(user.name)}</span>
          </div>
        </header>
        <main className="main-content">
          <div className="page-heading">
            <div>
              <div className="eyebrow">
                {page === "dashboard"
                  ? "ПРОИЗВОДСТВО НА ЛАДОНИ"
                  : page === "analytics"
                    ? "ОТ ДАННЫХ К РЕШЕНИЯМ"
                    : page === "orders"
                      ? "ЕДИНЫЙ ЖУРНАЛ РАБОТ"
                      : "РАБОЧЕЕ ПРОСТРАНСТВО"}
              </div>
              <h1>
                {page === "dashboard" ? "Обзор смены" : title}
                <span className="heading-dot">.</span>
              </h1>
              <p>
                {page === "dashboard"
                  ? "Всё, что происходит на производстве, — в одном месте."
                  : page === "orders"
                    ? "Планируйте работы, назначайте исполнителей и контролируйте результат."
                    : page === "employees"
                      ? "Команда смены, текущая загрузка и результаты работы."
                      : page === "analytics"
                        ? "Эффективность обслуживания в цифрах и фактах."
                        : page === "reference"
                          ? "Единые данные для точной постановки производственных задач."
                          : "Подключения и готовность системы к расширению."}
              </p>
            </div>
            <div className="page-actions">
              {(page === "dashboard" || page === "orders") && (
                <div className="shift-badge">
                  <span className="live-dot" />
                  <span>{dashboard?.shift_label || "Текущая смена"}</span>
                </div>
              )}
              {canManage && (page === "dashboard" || page === "orders") && (
                <button
                  className="button primary"
                  onClick={() => setCreate(true)}
                >
                  <Plus size={18} />
                  Создать наряд
                </button>
              )}
            </div>
          </div>
          {user.role === "worker" && (
            <div className="simulation-banner">
              <Radio size={17} />
              <span>
                <strong>Веб-симулятор исполнителя.</strong> Мобильное приложение
                — заглушка. Здесь доступны действия с назначенными вам нарядами.
              </span>
            </div>
          )}
          {error && <ErrorBox message={error} retry={() => void refresh()} />}
          {loading ? (
            <Loading />
          ) : page === "dashboard" || page === "orders" ? (
            <>
              {page === "dashboard" && (
                <>
                  <div className="metrics-grid">
                    <Metric
                      label="Выдано за смену"
                      value={number(dashboard?.issued)}
                      icon={<ClipboardList size={20} />}
                      detail={
                        <>
                          <span className="metric-neutral">Текущая смена</span>
                          <span>нарядов в системе</span>
                        </>
                      }
                    />
                    <Metric
                      label="Завершено"
                      value={number(dashboard?.completed)}
                      icon={<CircleCheck size={20} />}
                      detail={
                        <>
                          <span className="metric-green">
                            <Check size={13} />
                            Работа выполнена
                          </span>
                          <span>за текущую смену</span>
                        </>
                      }
                    />
                    <Metric
                      label="Просрочено"
                      value={number(dashboard?.overdue)}
                      icon={<Timer size={20} />}
                      accent
                      detail={
                        <>
                          <span className="metric-red">Требуют внимания</span>
                          <span>срок исполнения истёк</span>
                        </>
                      }
                    />
                    <Metric
                      label="Простои оборудования"
                      value={number(dashboard?.downtime_count)}
                      icon={<Factory size={20} />}
                      detail={
                        <>
                          <span className="metric-neutral">На контроле</span>
                          <span>аварийные работы</span>
                        </>
                      }
                    />
                  </div>
                  <section className="workforce-section">
                    <SectionTitle
                      title="Команда смены"
                      caption={`${employees.filter((e) => e.on_shift && e.role === "worker").length} сотрудников на смене`}
                      action={
                        <button
                          className="text-button"
                          onClick={() => navigate("employees")}
                        >
                          Все сотрудники
                          <ArrowUpRight size={15} />
                        </button>
                      }
                    />
                    <div className="workforce-strip">
                      {employees
                        .filter((e) => e.on_shift && e.role === "worker")
                        .slice(0, 7)
                        .map((e, i) => (
                          <button
                            className="worker-card"
                            key={e.id}
                            onClick={() => {
                              setQuickSearch(e.name);
                              setPage("orders");
                            }}
                          >
                            <span
                              className={`avatar worker-avatar avatar-${i % 4}`}
                            >
                              {initials(e.name)}
                              <i className={`employee-dot ${e.status}`} />
                            </span>
                            <strong>
                              {e.name.split(" ").slice(0, 2).join(" ")}
                            </strong>
                            <small>{e.specialty}</small>
                            <span className={`worker-status ${e.status}`}>
                              {e.status === "busy"
                                ? "В работе"
                                : e.status === "queued"
                                  ? "В очереди"
                                  : e.status === "free"
                                    ? "Свободен"
                                    : "Вне смены"}
                            </span>
                          </button>
                        ))}
                    </div>
                  </section>
                </>
              )}
              <OrderBoard
                orders={orders}
                reference={reference}
                onSelect={setSelected}
                compact={page === "dashboard"}
                initialSearch={quickSearch}
                user={user}
                onCreate={() => setCreate(true)}
              />
              {page === "dashboard" && (
                <div className="dashboard-bottom">
                  <div>
                    <ShieldCheck size={16} />
                    <span>Каждое действие сохраняется в истории наряда</span>
                  </div>
                  <span>Часовой пояс: Алматы (UTC+5)</span>
                </div>
              )}
            </>
          ) : page === "employees" ? (
            <EmployeesPage
              employees={employees}
              orders={orders}
              reference={reference}
              onSelect={setSelected}
            />
          ) : page === "analytics" ? (
            <AnalyticsPage reference={reference} notify={notify} />
          ) : page === "reference" ? (
            <ReferencePage
              reference={reference}
              user={user}
              refresh={refresh}
              notify={notify}
            />
          ) : (
            <IntegrationsPage />
          )}
        </main>
        <footer className="main-footer">
          <span>
            НАРЯДAI <i /> КОСТАНАЙСКИЕ МИНЕРАЛЫ
          </span>
          <span>Работаем слаженно. Действуем точно.</span>
        </footer>
      </div>
      {create && (
        <CreateOrder
          reference={reference}
          employees={employees}
          onClose={() => setCreate(false)}
          onCreated={(o) => {
            setCreate(false);
            setSelected(o.id);
            void refresh();
            notify(`Наряд ${o.number} создан`);
          }}
        />
      )}
      {selected !== null && (
        <OrderDialog
          id={selected}
          reference={reference}
          user={user}
          version={version}
          onClose={() => setSelected(null)}
          onChange={() => void refresh()}
          notify={notify}
        />
      )}{" "}
      {toast && (
        <div className="toast" role="status">
          <CheckCheck size={18} />
          {toast}
          <button onClick={() => setToast("")} aria-label="Закрыть">
            <X size={16} />
          </button>
        </div>
      )}
    </div>
  );
}
