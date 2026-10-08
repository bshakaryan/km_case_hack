import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import {
  ArrowRight,
  Bell,
  BookOpen,
  CalendarDays,
  CheckCheck,
  ChevronRight,
  CircleCheck,
  ClipboardCheck,
  ClipboardList,
  Factory,
  LayoutDashboard,
  ChartNoAxesCombined,
  LogOut,
  Menu,
  Plus,
  Plug,
  RefreshCw,
  ShieldCheck,
  Timer,
  TriangleAlert,
  Users,
  X,
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
  setToken,
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
import { Empty, ErrorBox, Loading, Priority, SectionTitle, Status } from "./ui";
import { OrderBoard, CreateOrder, OrderDialog } from "./Orders";
import { workerOrderGroups } from "./brigade";
import { WorkerOrderSections } from "./WorkerOrderSections";
import { OrderJournal } from "./OrderJournal";
import { EquipmentHistory } from "./EquipmentHistory";
import { canViewEquipmentHistory } from "./journal";
import {
  AnalyticsPage,
  ReferencePage,
  IntegrationsPage,
  EmployeesPage,
} from "./Pages";
import {
  attentionCounts,
  isActive,
  nextWorkAction,
  shiftTeam,
} from "./workspace";
import type { BoardFocus } from "./workspace";

type Page =
  | "dashboard"
  | "orders"
  | "employees"
  | "analytics"
  | "reference"
  | "integrations";
type CreateContext = { assigneeId?: Id; equipmentId?: Id };
type BoardContext = {
  focus?: BoardFocus;
  assigneeId?: Id;
  equipmentId?: Id;
  areaId?: Id;
  brigadeId?: Id;
  fromDate?: string;
  toDate?: string;
  revision: number;
};
const navigation = [
  { id: "dashboard" as Page, name: "Обзор смены", icon: LayoutDashboard },
  { id: "orders" as Page, name: "Наряды", icon: ClipboardList },
  { id: "employees" as Page, name: "Сотрудники", icon: Users },
  { id: "analytics" as Page, name: "Аналитика", icon: ChartNoAxesCombined },
];
const pageRoles: Record<Page, string[]> = {
  dashboard: ["master", "worker", "manager", "admin"],
  orders: ["master", "manager", "admin"],
  employees: ["master", "manager", "admin"],
  analytics: ["master", "manager", "admin"],
  reference: ["master", "admin"],
  integrations: ["master", "manager", "admin"],
};

function canOpenPage(role: string, target: Page) {
  return pageRoles[target].includes(role);
}

function Brand() {
  return (
    <div className="brand">
      <div className="brand-symbol">
        <ClipboardCheck size={25} strokeWidth={1.9} />
      </div>
      <span>
        Наряд<span className="brand-ai">AI</span>
        <small>УПРАВЛЕНИЕ РАБОТАМИ</small>
      </span>
    </div>
  );
}

function Login({ onLogin }: { onLogin: (user: User) => void }) {
  const [login, setLogin] = useState("");
  const [pin, setPin] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function submit(e?: FormEvent, demo?: string) {
    e?.preventDefault();
    if (busy) return;
    setBusy(true);
    setError("");
    try {
      const res = await post<{ token: string; user: User }>("/auth/login", {
        login: demo || login.trim(),
        pin: demo ? "1234" : pin,
      });
      setToken(res.token);
      onLogin(res.user);
    } catch (error) {
      setError((error as Error).message);
    } finally {
      setBusy(false);
    }
  }
  return (
    <div className="login-page">
      <aside className="login-story">
        <Brand />
        <div className="login-story-copy">
          <div className="eyebrow">КОСТАНАЙСКИЕ МИНЕРАЛЫ</div>
          <h1>
            Рабочая смена.
            <br />
            Всё под контролем.
          </h1>
          <p>
            Назначайте работу, следите за выполнением и принимайте результат по
            отчёту и фотографиям.
          </p>
          <div className="login-features">
            <span>
              <ClipboardList size={20} /> Наряды и сроки
            </span>
            <span>
              <Users size={20} /> Загрузка команды
            </span>
            <span>
              <ShieldCheck size={20} /> Приёмка мастером
            </span>
          </div>
        </div>
        <div className="login-footer">
          Веб-панель · мастер, исполнитель, руководитель
        </div>
      </aside>
      <main className="login-main">
        <div className="login-top">
          <span className="outlined-tag">Демонстрационная среда</span>
          <span>RU</span>
        </div>
        <div className="login-form">
          <div className="login-mark">
            <ClipboardCheck size={28} />
          </div>
          <h2>Вход в рабочее пространство</h2>
          <p>Используйте свой логин и ПИН-код.</p>
          <form onSubmit={submit}>
            <label>
              Логин
              <input
                autoComplete="username"
                value={login}
                onChange={(e) => setLogin(e.target.value)}
                required
                disabled={busy}
                placeholder="Введите логин"
              />
            </label>
            <label>
              ПИН-код
              <input
                autoComplete="current-password"
                type="password"
                inputMode="numeric"
                value={pin}
                onChange={(e) => setPin(e.target.value)}
                required
                minLength={4}
                disabled={busy}
                placeholder="Введите ПИН"
              />
            </label>
            {error && <ErrorBox message={error} />}
            <button className="button primary login-submit" disabled={busy}>
              {busy ? (
                <LoaderCircle className="spin" size={18} />
              ) : (
                <>
                  Войти <ArrowRight size={18} />
                </>
              )}
            </button>
          </form>
          <div className="login-demo">
            <span>ДЕМО-АККАУНТЫ</span>
            <div>
              {[
                { login: "master", role: "master" },
                { login: "worker2", role: "worker" },
                { login: "manager", role: "manager" },
                { login: "admin", role: "admin" },
              ].map((account) => (
                <button
                  key={account.login}
                  disabled={busy}
                  onClick={() => void submit(undefined, account.login)}
                >
                  {roleNames[account.role]}
                  <ArrowRight size={15} />
                </button>
              ))}
            </div>
            <p>
              ПИН 1234 · Учебные данные. В Compose новые сдачи проверяет локальный модуль; решение принимает мастер.
            </p>
          </div>
        </div>
        <div className="login-bottom">НарядAI · Техническое обслуживание</div>
      </main>
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
  const [equipmentHistory, setEquipmentHistory] = useState<Id | null>(null);
  const [equipmentShowing, setEquipmentShowing] = useState(false);
  const [workerHistoryOpen, setWorkerHistoryOpen] = useState(false);
  const [journalInvalidation, setJournalInvalidation] = useState(0);
  const operationalSignature = useRef("");
  const [create, setCreate] = useState(false);
  const [createContext, setCreateContext] = useState<CreateContext>({});
  const [boardContext, setBoardContext] = useState<BoardContext>({
    revision: 0,
  });
  const [notifications, setNotifications] = useState(false);
  const [menu, setMenu] = useState(false);
  const [toast, setToast] = useState("");
  const [version, setVersion] = useState(0);
  const [online, setOnline] = useState(false);
  const [lastUpdated, setLastUpdated] = useState<string | null>(null);
  const session = useRef(0);
  const refreshAgain = useRef(false);
  const pending = useRef<{ token: string; promise: Promise<void> } | null>(
    null,
  );
  const toastTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const notify = useCallback((message: string) => {
    setToast(message);
    if (toastTimer.current) clearTimeout(toastTimer.current);
    toastTimer.current = setTimeout(() => setToast(""), 5500);
  }, []);
  const logout = useCallback(() => {
    ++session.current;
    pending.current = null;
    refreshAgain.current = false;
    setToken(null);
    setUser(null);
    setOrders([]);
    setEmployees([]);
    setNotices([]);
    setReference(emptyReference);
    setDashboard(null);
    setSelected(null);
    setEquipmentHistory(null);
    setEquipmentShowing(false);
    setWorkerHistoryOpen(false);
    operationalSignature.current = "";
    setCreate(false);
    setCreateContext({});
    setMenu(false);
    setNotifications(false);
    setToast("");
    setError("");
    setAuthLoading(false);
    setPage("dashboard");
    setOnline(false);
    setLastUpdated(null);
    setBoardContext((context) => ({ revision: context.revision + 1 }));
  }, []);
  useEffect(() => {
    let active = true;
    if (token())
      api<User>("/auth/me")
        .then((value) => {
          if (active) setUser(value);
        })
        .catch(() => {
          if (active) logout();
        })
        .finally(() => {
          if (active) setAuthLoading(false);
        });
    window.addEventListener("naryad:unauthorized", logout);
    const syncSession = (event: StorageEvent) => {
      if (
        event.key === null ||
        (event.key === "naryad_token" && event.oldValue !== event.newValue)
      )
        window.location.reload();
    };
    window.addEventListener("storage", syncSession);
    return () => {
      active = false;
      window.removeEventListener("naryad:unauthorized", logout);
      window.removeEventListener("storage", syncSession);
    };
  }, [logout]);

  const refresh = useCallback(
    (revalidate = true): Promise<void> => {
      const capturedToken = token();
      if (!capturedToken) return Promise.resolve();
      if (pending.current?.token === capturedToken) {
        if (revalidate) refreshAgain.current = true;
        return pending.current.promise;
      }
      const generation = session.current;
      const current = () =>
        generation === session.current && capturedToken === token();
      const promise = (async () => {
        try {
          do {
            refreshAgain.current = false;
            const [r, o, e, d, n] = await Promise.all([
              api<Reference>("/reference"),
              api<Order[]>("/orders?limit=5000"),
              user?.role === "worker"
                ? Promise.resolve([] as Employee[])
                : api<Employee[]>("/employees"),
              api<Dashboard>("/dashboard"),
              api<Notice[]>("/notifications"),
            ]);
            if (!current()) return;
            const signature = JSON.stringify(
              o.map((item) => [
                item.id,
                item.version,
                item.status,
                item.queue_position,
              ]),
            );
            if (
              operationalSignature.current &&
              signature !== operationalSignature.current
            )
              setJournalInvalidation((value) => value + 1);
            operationalSignature.current = signature;
            setReference(r);
            setOrders(o);
            setEmployees(e);
            setDashboard(d);
            setNotices(n);
            setError("");
            setLastUpdated(new Date().toISOString());
            setVersion((v) => v + 1);
          } while (current() && refreshAgain.current);
        } catch (failure) {
          if (current()) setError((failure as Error).message);
        } finally {
          if (current()) {
            pending.current = null;
            setLoading(false);
          }
        }
      })();
      pending.current = { token: capturedToken, promise };
      return promise;
    },
    [user?.role],
  );

  useEffect(() => {
    if (!user) return;
    let disposed = false;
    let socket: WebSocket | undefined;
    let retryTimer: ReturnType<typeof setTimeout> | undefined;
    let attempts = 0;
    setLoading(true);
    void refresh();
    const timer = setInterval(() => void refresh(false), 5000);
    const connect = () => {
      if (disposed || !token()) return;
      const proto = location.protocol === "https:" ? "wss:" : "ws:";
      socket = new WebSocket(
        `${proto}//${location.host}/api/ws?token=${encodeURIComponent(token() || "")}`,
      );
      socket.onopen = () => {
        if (!disposed) {
          attempts = 0;
          setOnline(true);
          void refresh();
        }
      };
      socket.onerror = () => {
        if (!disposed) setOnline(false);
      };
      socket.onclose = () => {
        if (!disposed) {
          setOnline(false);
          retryTimer = setTimeout(
            connect,
            Math.min(15000, 1000 * 2 ** Math.min(attempts++, 4)),
          );
        }
      };
      socket.onmessage = (e) => {
        if (disposed) return;
        try {
          const event = JSON.parse(e.data);
          if (event.type === "orders.updated")
            setJournalInvalidation((value) => value + 1);
          if (event.type !== "connected") void refresh();
        } catch {
          /* Ignore non-event heartbeats. */
        }
      };
    };
    connect();
    const heartbeat = setInterval(() => {
      if (socket?.readyState === WebSocket.OPEN) socket.send("ping");
    }, 30000);
    return () => {
      disposed = true;
      clearInterval(timer);
      clearInterval(heartbeat);
      clearTimeout(retryTimer);
      socket?.close();
    };
  }, [user, refresh]);
  useEffect(
    () => () => {
      if (toastTimer.current) clearTimeout(toastTimer.current);
    },
    [],
  );
  const canManage = user?.role === "master" || user?.role === "admin";
  const currentPage =
    user && canOpenPage(user.role, page) ? page : ("dashboard" as Page);
  const title =
    currentPage === "dashboard" && user?.role === "worker"
      ? "Моя работа"
      : navigation.find((n) => n.id === currentPage)?.name ||
        { reference: "Справочники", integrations: "Интеграции" }[
          currentPage as "reference" | "integrations"
        ];
  const unread = notices.filter((n) => !n.read).length;
  const attention = attentionCounts(orders);
  const team = shiftTeam(employees);
  const workerGroups = workerOrderGroups(orders, user?.id ?? "");
  const currentWork = workerGroups.current;
  const incoming = workerGroups.incoming;
  function openCreate(context: CreateContext = {}) {
    setCreateContext(context);
    setCreate(true);
  }
  function openEquipmentHistory(id: Id) {
    if (!user || !canViewEquipmentHistory(user.role)) return;
    setEquipmentHistory(id);
    setEquipmentShowing(true);
  }
  function closeOrder() {
    setSelected(null);
    if (equipmentHistory !== null) setEquipmentShowing(true);
  }
  function navigate(next: Page) {
    if (!user || !canOpenPage(user.role, next)) return;
    setPage(next);
    setMenu(false);
    setBoardContext((context) => ({ revision: context.revision + 1 }));
  }
  function inspectOrders(filters: Omit<BoardContext, "revision">) {
    if (!user || !canOpenPage(user.role, "orders")) return;
    setPage("orders");
    setMenu(false);
    setBoardContext((context) => ({
      ...filters,
      revision: context.revision + 1,
    }));
  }
  function signOut() {
    // post captures the current token synchronously; a slow revocation must not
    // leave private data visible or clear a subsequent user's session.
    void post("/auth/logout", {}).catch(() => {});
    logout();
  }
  async function readNotice(notice: Notice) {
    try {
      await post(`/notifications/${notice.id}/read`, {});
      setNotices((all) =>
        all.map((n) => (n.id === notice.id ? { ...n, read: true } : n)),
      );
      if (notice.order_id) {
        setSelected(notice.order_id);
        setNotifications(false);
      }
    } catch (failure) {
      notify((failure as Error).message);
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
        onLogin={(value) => {
          ++session.current;
          setLoading(true);
          setUser(value);
        }}
      />
    );

  return (
    <div className="app-shell">
      {menu && (
        <div className="sidebar-backdrop" onClick={() => setMenu(false)} />
      )}
      <aside
        className={`sidebar ${menu ? "is-open" : ""}`}
        aria-label="Основная навигация"
      >
        <Brand />
        <div className="workspace-switch">
          <span className="workspace-avatar">
            <Factory size={20} />
          </span>
          <div>
            <strong>Костанайские минералы</strong>
            <small>Производственный комплекс</small>
          </div>
        </div>
        <div className="nav-caption">РАБОЧЕЕ ПРОСТРАНСТВО</div>
        <nav>
          {navigation
            .filter(({ id }) => canOpenPage(user.role, id))
            .map(({ id, name, icon: Icon }) => (
              <button
                key={id}
                className={currentPage === id ? "active" : ""}
                aria-current={currentPage === id ? "page" : undefined}
                onClick={() => navigate(id)}
              >
                <Icon size={20} />
                <span>
                  {id === "dashboard" && user.role === "worker"
                    ? "Моя работа"
                    : name}
                </span>
                {id === "orders" && (
                  <span className="nav-count">{dashboard?.active || 0}</span>
                )}
              </button>
            ))}
        </nav>
        <div className="sidebar-bottom">
          {(canOpenPage(user.role, "reference") ||
            canOpenPage(user.role, "integrations")) && (
            <>
              <div className="nav-caption">СИСТЕМА</div>
              <nav>
                {canOpenPage(user.role, "reference") && (
                  <button
                    className={currentPage === "reference" ? "active" : ""}
                    onClick={() => navigate("reference")}
                  >
                    <BookOpen size={20} />
                    <span>Справочники</span>
                  </button>
                )}
                {canOpenPage(user.role, "integrations") && (
                  <button
                    className={currentPage === "integrations" ? "active" : ""}
                    onClick={() => navigate("integrations")}
                  >
                    <Plug size={20} />
                    <span>Интеграции</span>
                  </button>
                )}
              </nav>
            </>
          )}
          <div className="sidebar-status">
            <span className={`live-dot ${error ? "is-stale" : ""}`} />
            <div>
              <strong>
                {error
                  ? "Нет свежих данных"
                  : online
                    ? "Связь с сервером"
                    : "Опрос сервера"}
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
              <LogOut size={19} />
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
              <Menu size={22} />
            </button>
            <span>Рабочее пространство</span>
            <ChevronRight size={15} />
            <strong>{title}</strong>
          </div>
          <div className="topbar-right">
            <span className="outlined-tag">ДЕМО</span>
            <span className={`connection-label ${error ? "is-stale" : ""}`}>
              <span className="live-dot" />
              {error
                ? "Данные не обновлены"
                : lastUpdated
                  ? `Обновлено ${formatTime(lastUpdated)}`
                  : "Подключение…"}
            </span>
            <button
              className="icon-button"
              onClick={() => void refresh()}
              aria-label="Обновить данные"
              disabled={loading}
            >
              <RefreshCw size={19} />
            </button>
            <div className="notification-wrap">
              <button
                className={`icon-button ${notifications ? "selected" : ""}`}
                onClick={() => setNotifications((value) => !value)}
                aria-label={`Уведомления, непрочитанных: ${unread}`}
                aria-expanded={notifications}
              >
                <Bell size={20} />
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
                      <X size={19} />
                    </button>
                  </div>
                  {notices.length ? (
                    notices.slice(0, 40).map((notice) => (
                      <button
                        key={notice.id}
                        className={`notice ${notice.read ? "read" : ""}`}
                        onClick={() => void readNotice(notice)}
                      >
                        <span
                          className={`notice-icon ${notice.kind.includes("overdue") ? "red" : ""}`}
                        >
                          <Bell size={18} />
                        </span>
                        <span>
                          <strong>{notice.title}</strong>
                          <p>{notice.message}</p>
                          <small>{formatDate(notice.created_at, true)}</small>
                        </span>
                        {!notice.read && <i />}
                      </button>
                    ))
                  ) : (
                    <Empty
                      title="Новых событий пока нет"
                      text="Здесь появятся назначения и напоминания по нарядам."
                    />
                  )}
                </div>
              )}
            </div>
            <span className="avatar top-avatar">{initials(user.name)}</span>
          </div>
        </header>
        <main className="main-content" id="workspace">
          <div className="page-heading">
            <div>
              <div className="eyebrow">
                {currentPage === "dashboard"
                  ? "ТЕКУЩАЯ СМЕНА"
                  : currentPage === "orders"
                    ? "ЗАДАНИЯ И ИСТОРИЯ"
                    : "РАБОЧЕЕ ПРОСТРАНСТВО"}
              </div>
              <h1>{title}</h1>
              <p>
                {currentPage === "dashboard"
                  ? user.role === "worker"
                    ? "Текущее задание и следующие действия."
                    : "Приоритеты, ход работ и решения мастера."
                  : currentPage === "orders"
                    ? "Назначение, выполнение и приёмка — в одном журнале."
                    : currentPage === "employees"
                      ? "Кто свободен, что выполняет и сколько назначений ожидает."
                      : currentPage === "analytics"
                        ? "Результаты за период, показатели и исходные наряды."
                        : currentPage === "reference"
                          ? "Участки, оборудование, сотрудники и материалы."
                          : "Текущее состояние подключений."}
              </p>
            </div>
            <div className="page-actions">
              {(currentPage === "dashboard" || currentPage === "orders") && (
                <div className="shift-badge">
                  <CalendarDays size={17} />
                  <span>{dashboard?.shift_label || "Текущая смена"}</span>
                </div>
              )}
              {canManage &&
                (currentPage === "dashboard" || currentPage === "orders") && (
                  <button
                    className="button primary"
                    onClick={() => openCreate()}
                  >
                    <Plus size={19} />
                    Выдать наряд
                  </button>
                )}
            </div>
          </div>
          {error && (
            <ErrorBox
              message={`${error}${lastUpdated ? ` Последнее обновление: ${formatTime(lastUpdated)}.` : ""}`}
              retry={() => void refresh()}
            />
          )}
          {loading ? (
            <Loading />
          ) : currentPage === "dashboard" || currentPage === "orders" ? (
            <>
              {currentPage === "dashboard" &&
                (user.role === "worker" ? (
                  <>
                    <SectionTitle
                      title="Сейчас в работе"
                      caption="Откройте наряд, чтобы продолжить работу или заполнить отчёт."
                    />
                    <div className="current-work-grid">
                      {currentWork.length ? (
                        currentWork.map((order) => (
                          <article className="current-task" key={order.id}>
                            <div className="section-topline">
                              <span>{order.number}</span>
                              <Status value={order.status} />
                            </div>
                            <h2>{order.title}</h2>
                            <p>
                              {order.equipment_name} · {order.area_name}
                            </p>
                            <div className="task-flags">
                              <Priority value={order.priority} />
                              {order.is_overdue && (
                                <span className="overdue">Срок истёк</span>
                              )}
                            </div>
                            <p>До {formatDate(order.deadline, true)}</p>
                            <button
                              className="button primary"
                              onClick={() => setSelected(order.id)}
                            >
                              {nextWorkAction(order.status)}
                              <ArrowRight size={17} />
                            </button>
                          </article>
                        ))
                      ) : (
                        <Empty
                          title="Нет работы в исполнении"
                          text="Примите поступивший наряд или выберите задание из очереди."
                        />
                      )}
                    </div>
                    {incoming.length > 0 && (
                      <section className="incoming-section">
                        <SectionTitle
                          title={`Поступления и доработка · ${incoming.length}`}
                        />
                        <div className="current-work-grid">
                          {incoming.slice(0, 3).map((order) => (
                            <article className="current-task" key={order.id}>
                              <div className="section-topline">
                                <span>{order.number}</span>
                                <Priority value={order.priority} />
                              </div>
                              <h3>{order.title}</h3>
                              <p>
                                {order.equipment_name} · {order.area_name}
                              </p>
                              <Status value={order.status} />
                              <button
                                className="button secondary"
                                onClick={() => setSelected(order.id)}
                              >
                                {nextWorkAction(order.status)}
                                <ArrowRight size={16} />
                              </button>
                            </article>
                          ))}
                        </div>
                      </section>
                    )}
                    <WorkerOrderSections
                      queue={workerGroups.queue}
                      assisting={workerGroups.assisting}
                      onSelect={setSelected}
                    />
                  </>
                ) : (
                  <>
                    <SectionTitle
                      title="Требуют внимания"
                      caption="Выберите группу, чтобы сразу перейти к нужным нарядам."
                    />
                    <div className="attention-grid">
                      {[
                        {
                          focus: "emergency" as const,
                          title: "Аварийные",
                          hint: "Приоритетное реагирование",
                          icon: Zap,
                          tone: "danger",
                        },
                        {
                          focus: "overdue" as const,
                          title: "Нарушен срок",
                          hint: "Уточнить причину и ход работ",
                          icon: Timer,
                          tone: "danger",
                        },
                        {
                          focus: "issued" as const,
                          title: "Не приняты",
                          hint: "Ожидают ответа исполнителя",
                          icon: ClipboardList,
                          tone: "warning",
                        },
                        {
                          focus: "ai_review" as const,
                          title: "На приёмке",
                          hint: "Проверить отчёт и результат",
                          icon: ClipboardCheck,
                          tone: "primary",
                        },
                      ].map(
                        ({ focus, title: label, hint, icon: Icon, tone }) => (
                          <button
                            className={`attention-card tone-${tone}`}
                            key={focus}
                            onClick={() => inspectOrders({ focus })}
                          >
                            <div className="attention-copy">
                              <Icon size={21} />
                              <strong>{label}</strong>
                              <span>{hint}</span>
                            </div>
                            <span className="attention-count">
                              {attention[focus]}
                            </span>
                            <ChevronRight size={18} />
                          </button>
                        ),
                      )}
                    </div>
                    {attention.rejected > 0 && (
                      <button
                        className="text-button attention-followup"
                        onClick={() => inspectOrders({ focus: "rejected" })}
                      >
                        <TriangleAlert size={17} />
                        Отклонено назначений: {attention.rejected}. Нужны
                        причина и решение мастера.
                        <ArrowRight size={16} />
                      </button>
                    )}
                    <div className="shift-strip">
                      <div>
                        <ClipboardList size={19} />
                        <strong>{number(dashboard?.issued)}</strong>
                        <span>выдано за смену</span>
                      </div>
                      <div>
                        <CircleCheck size={19} />
                        <strong>{number(dashboard?.completed)}</strong>
                        <span>исполнено за смену</span>
                      </div>
                      <div>
                        <Users size={19} />
                        <strong>
                          {
                            team.filter(
                              (e) => e.on_shift && e.status === "free",
                            ).length
                          }
                        </strong>
                        <span>свободных исполнителей</span>
                      </div>
                      <div>
                        <Factory size={19} />
                        <strong>{number(dashboard?.downtime_count)}</strong>
                        <span>ед. оборудования в активном ремонте</span>
                      </div>
                    </div>
                  </>
                ))}
              {currentPage === "dashboard" && orders.length >= 5000 && (
                <div className="simulation-banner">
                  <TriangleAlert size={18} />
                  <span>
                    Загружены последние 5000 нарядов. Счётчики групп и фильтры
                    относятся к этой выборке. Полная история доступна в журнале
                    с серверной загрузкой страниц.
                  </span>
                </div>
              )}
              {currentPage === "orders" ? (
                <OrderJournal
                  key={`${user.id}:${boardContext.revision}`}
                  user={user}
                  reference={reference}
                  onSelect={setSelected}
                  context={boardContext}
                  initialScope={boardContext.focus === "all" ? "all" : "active"}
                  invalidation={journalInvalidation}
                  active={selected === null && !equipmentShowing}
                />
              ) : (
                <OrderBoard
                  key={`${currentPage}-${boardContext.revision}`}
                  orders={orders}
                  reference={reference}
                  onSelect={setSelected}
                  compact={currentPage === "dashboard"}
                  initialFocus={boardContext.focus}
                  initialAssignee={boardContext.assigneeId}
                  initialEquipment={boardContext.equipmentId}
                  initialArea={boardContext.areaId}
                  initialBrigade={boardContext.brigadeId}
                  initialFromDate={boardContext.fromDate}
                  initialToDate={boardContext.toDate}
                  user={user}
                  onCreate={() => openCreate()}
                />
              )}
              {currentPage === "dashboard" && user.role === "worker" && (
                <details
                  className="worker-full-history"
                  onToggle={(event) =>
                    setWorkerHistoryOpen(event.currentTarget.open)
                  }
                >
                  <summary>Полная история доступных нарядов</summary>
                  <OrderJournal
                    key={String(user.id)}
                    user={user}
                    reference={reference}
                    onSelect={setSelected}
                    initialScope="closed"
                    invalidation={journalInvalidation}
                    active={workerHistoryOpen && selected === null}
                  />
                </details>
              )}
              {currentPage === "dashboard" && user.role !== "worker" && (
                <section className="workforce-section">
                  <SectionTitle
                    title="Команда смены"
                    caption={`${team.filter((e) => e.on_shift).length} на смене · сначала свободные`}
                    action={
                      <button
                        className="text-button"
                        onClick={() => navigate("employees")}
                      >
                        Все сотрудники
                        <ArrowRight size={16} />
                      </button>
                    }
                  />
                  <div className="team-table">
                    {team.slice(0, 6).map((employee) => (
                      <div className="team-person" key={employee.id}>
                        <div className="avatar worker-avatar">
                          {initials(employee.name)}
                        </div>
                        <div className="team-identity">
                          <strong>{employee.name}</strong>
                          <small>
                            {employee.specialty} · {employee.grade} разряд
                          </small>
                        </div>
                        <span className={`worker-status ${employee.status}`}>
                          {employee.status === "free"
                            ? "Свободен"
                            : employee.status === "busy"
                              ? "В работе"
                              : employee.status === "queued"
                                ? "Есть назначения"
                                : "Вне смены"}
                        </span>
                        <div className="team-load">
                          <span>
                            {employee.current_order || "Нет текущей работы"}
                          </span>
                          <small>Ожидают начала: {employee.queue_count}</small>
                        </div>
                        <div className="team-actions">
                          <button
                            className="button secondary"
                            onClick={() =>
                              inspectOrders({
                                focus: "all",
                                assigneeId: employee.id,
                              })
                            }
                          >
                            Наряды
                          </button>
                          {canManage && (
                            <button
                              className="button secondary"
                              disabled={!employee.on_shift}
                              onClick={() =>
                                openCreate({ assigneeId: employee.id })
                              }
                            >
                              <Plus size={16} />
                              Выдать
                            </button>
                          )}
                        </div>
                      </div>
                    ))}
                  </div>
                </section>
              )}
              {currentPage === "dashboard" && (
                <div className="dashboard-bottom">
                  <div>
                    <ShieldCheck size={17} />
                    <span>Действия сохраняются в истории наряда</span>
                  </div>
                  <span>Время предприятия · Asia/Almaty</span>
                </div>
              )}
            </>
          ) : currentPage === "employees" ? (
            <EmployeesPage
              employees={employees}
              orders={orders}
              reference={reference}
              onSelect={setSelected}
              onCreate={canManage ? openCreate : undefined}
            />
          ) : currentPage === "analytics" ? (
            <AnalyticsPage
              reference={reference}
              notify={notify}
              version={version}
              onInspectOrders={(filters) =>
                inspectOrders({ focus: "all", ...filters })
              }
            />
          ) : currentPage === "reference" ? (
            <ReferencePage
              reference={reference}
              user={user}
              refresh={refresh}
              notify={notify}
              onCreate={canManage ? openCreate : undefined}
              onEquipment={openEquipmentHistory}
            />
          ) : (
            <IntegrationsPage />
          )}
        </main>
        <footer className="main-footer">
          <span>НарядAI · Костанайские минералы</span>
          <span>Демо · учебные данные · локальная проверка сдачи</span>
        </footer>
      </div>
      {create && (
        <CreateOrder
          key={String(user.id)}
          user={user}
          reference={reference}
          employees={employees}
          initialAssigneeId={createContext.assigneeId}
          initialEquipmentId={createContext.equipmentId}
          onClose={() => setCreate(false)}
          onCreated={(order) => {
            setCreate(false);
            setSelected(order.id);
            void refresh();
            notify(`Наряд ${order.number} выдан`);
          }}
        />
      )}
      {selected !== null && (
        <OrderDialog
          key={`${user.id}:${selected}`}
          id={selected}
          reference={reference}
          user={user}
          workerHasOpenOrder={orders.some(
            (order) =>
              String(order.assignee_id) === String(user.id) &&
              String(order.id) !== String(selected) &&
              ["accepted", "queued", "in_progress", "paused"].includes(
                order.status,
              ),
          )}
          workerHasActiveOrder={orders.some(
            (order) =>
              String(order.assignee_id) === String(user.id) &&
              String(order.id) !== String(selected) &&
              ["in_progress", "paused"].includes(order.status),
          )}
          workerHasInProgressOrder={orders.some(
            (order) =>
              String(order.assignee_id) === String(user.id) &&
              String(order.id) !== String(selected) &&
              order.status === "in_progress",
          )}
          version={version}
          active={!equipmentShowing}
          onEquipment={
            canViewEquipmentHistory(user.role)
              ? openEquipmentHistory
              : undefined
          }
          onClose={closeOrder}
          onChange={() => void refresh()}
          notify={notify}
        />
      )}
      {equipmentHistory !== null && (
        <EquipmentHistory
          key={`${user.id}:${equipmentHistory}`}
          id={equipmentHistory}
          user={user}
          reference={reference}
          active={equipmentShowing}
          invalidation={journalInvalidation}
          onSelect={(id) => {
            setSelected(id);
            setEquipmentShowing(false);
          }}
          onClose={() => {
            setEquipmentHistory(null);
            setEquipmentShowing(false);
          }}
        />
      )}
      {toast && (
        <div className="toast" role="status">
          <CheckCheck size={19} />
          {toast}
          <button onClick={() => setToast("")} aria-label="Закрыть сообщение">
            <X size={18} />
          </button>
        </div>
      )}
    </div>
  );
}
