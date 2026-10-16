"use client";

import { useCallback, useMemo, useRef, useState, type FormEvent } from "react";
import { ApiClient, errorMessage, type Profile } from "@/lib/api";
import { Brand, ErrorBox, Icon } from "@/components/ui";
import { Workspace } from "@/components/workspace";

interface Session { token: string; profile: Profile }
const demoAccounts = [
  ["Сотрудник", "employee@example.com"], ["Руководитель", "manager@example.com"],
  ["HR", "hr@example.com"], ["Другая команда", "outsider@example.com"],
];

export default function Home() {
  const [session, setSession] = useState<Session | null>(null);
  const [sessionMessage, setSessionMessage] = useState("");
  const expire = useCallback((token: string) => {
    setSession((current) => {
      if (current?.token !== token) return current;
      return null;
    });
    setSessionMessage("Сессия завершена. Войдите снова, чтобы продолжить.");
  }, []);
  const api = useMemo(() => session ? new ApiClient(session.token, () => expire(session.token)) : null, [session, expire]);
  if (!session || !api) return <Login message={sessionMessage} onLogin={(value) => { setSessionMessage(""); setSession(value); }} />;
  return <Workspace key={session.token} api={api} me={session.profile} onLogout={() => { setSession(null); setSessionMessage(""); }} />;
}

function Login({ onLogin, message }: { onLogin: (session: Session) => void; message: string }) {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [visible, setVisible] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const busy = useRef(false);
  async function submit(event: FormEvent) {
    event.preventDefault();
    if (busy.current) return;
    busy.current = true; setPending(true); setError("");
    try {
      const auth = await new ApiClient().post<{ access_token: string; token_type: "bearer" }>("/auth/login", { email: email.trim(), password });
      const profile = await new ApiClient(auth.access_token).call<Profile>("/me");
      setPassword("");
      onLogin({ token: auth.access_token, profile });
    } catch (cause) { setError(errorMessage(cause)); }
    finally { busy.current = false; setPending(false); }
  }
  return <main className="login-page">
    <section className="login-story">
      <Brand light />
      <div className="login-story-main"><span className="eyebrow light-eyebrow"><span className="live-dot" /> ЛЮДИ. ВОЗМОЖНОСТИ. JANA.</span><h1>Всё для работы.<br /><span>Больше для вас.</span></h1><p>Личное пространство сотрудника:<br />меньше рутины, больше движения вперёд.</p><div className="login-art" aria-hidden="true"><div className="orbit orbit-one" /><div className="orbit orbit-two" /><div className="orbit orbit-three" /><div className="art-center"><Icon name="leaf" size={56} /></div><span className="art-chip chip-one"><Icon name="check" size={17} /> Быть в команде</span><span className="art-chip chip-two"><Icon name="spark" size={17} /> Расти каждый день</span><span className="art-dot dot-one" /><span className="art-dot dot-two" /></div></div>
      <div className="login-story-footer"><span>Jana Post · Digital HR</span><span>С заботой о людях ↗</span></div>
    </section>
    <section className="login-form-side"><div className="login-mobile-brand"><Brand /></div><div className="login-form-wrap"><span className="eyebrow">РАБОЧИЙ ДЕНЬ НАЧИНАЕТСЯ ЗДЕСЬ</span><h2>Добро пожаловать</h2><p className="muted">Войдите в своё пространство JanaМен.</p>
      {message && <div className="notice"><Icon name="info" />{message}</div>}
      <form onSubmit={submit} className="login-form"><label htmlFor="email">Рабочая почта</label><div className="input-with-icon"><Icon name="mail" /><input id="email" type="email" autoComplete="username" placeholder="name@example.com" value={email} onChange={(event) => setEmail(event.target.value)} required disabled={pending} /></div><label htmlFor="password">Пароль</label><div className="input-with-icon"><Icon name="shield" /><input id="password" type={visible ? "text" : "password"} autoComplete="current-password" placeholder="Введите пароль" value={password} onChange={(event) => setPassword(event.target.value)} required disabled={pending} /><button type="button" className="password-toggle" onClick={() => setVisible(!visible)} aria-label={visible ? "Скрыть пароль" : "Показать пароль"} aria-pressed={visible}><Icon name="eye" size={18} /></button></div>
        {error && <ErrorBox message={error} />}<button className="button button-primary login-submit" disabled={pending}>{pending ? <><span className="spinner" /> Входим…</> : <>Войти в JanaМен <Icon name="arrow" size={18} /></>}</button>
      </form>
      <div className="demo-accounts"><span className="small-label">ДЕМО-ДОСТУП</span><p>Выберите роль и введите настроенный демо-пароль.</p><div>{demoAccounts.map(([label, address]) => <button key={address} className={email === address ? "demo-choice selected" : "demo-choice"} onClick={() => setEmail(address)} disabled={pending}>{label}</button>)}</div><small>Демо-профили вымышлены. Пароль задаётся при запуске сервера.</small></div>
    </div><div className="login-footer"><Icon name="shield" size={15} /> После обновления страницы потребуется войти снова</div></section>
  </main>;
}
