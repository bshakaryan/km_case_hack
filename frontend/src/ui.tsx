import { useEffect, useRef, useState } from "react";
import type { ReactNode } from "react";
import {
  X,
  AlertTriangle,
  LoaderCircle,
  ArrowUpRight,
  Clock3,
  ImageOff,
} from "lucide-react";
import { statusNames, priorityNames, token } from "./model";
export function Status({ value }: { value: string }) {
  return (
    <span className={`status status-${value}`}>
      <i />
      {statusNames[value] || value}
    </span>
  );
}
export function Priority({ value }: { value: string }) {
  return (
    <span className={`priority priority-${value}`}>
      <i />
      {priorityNames[value] || value}
    </span>
  );
}
export function Empty({
  title = "Здесь пока нет нарядов",
  text = "Попробуйте изменить фильтры или создать новый наряд.",
  icon,
}: {
  title?: string;
  text?: string;
  icon?: ReactNode;
}) {
  return (
    <div className="empty">
      {icon || <Clock3 size={28} />}
      <strong>{title}</strong>
      <p>{text}</p>
    </div>
  );
}
export function Loading() {
  return (
    <div className="loading">
      <LoaderCircle className="spin" size={22} /> Загружаем данные…
    </div>
  );
}
export function ErrorBox({
  message,
  retry,
}: {
  message: string;
  retry?: () => void;
}) {
  return (
    <div className="error-box" role="alert">
      <AlertTriangle size={18} />
      <span>{message}</span>
      {retry && (
        <button className="text-button" onClick={retry}>
          Повторить
        </button>
      )}
    </div>
  );
}
export function Modal({
  title,
  subtitle,
  onClose,
  children,
  wide = false,
}: {
  title: string;
  subtitle?: string;
  onClose: () => void;
  children: ReactNode;
  wide?: boolean;
}) {
  const panel = useRef<HTMLElement>(null);
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null;
    const focusable = () =>
      Array.from(
        panel.current?.querySelectorAll<HTMLElement>(
          'button:not(:disabled), a[href], input:not(:disabled), select:not(:disabled), textarea:not(:disabled), [tabindex="0"]',
        ) || [],
      ).filter((element) => element.getClientRects().length > 0);
    panel.current?.focus();
    const fn = (e: KeyboardEvent) => {
      if (e.key === "Escape") {
        e.preventDefault();
        close.current();
      }
      if (e.key === "Tab") {
        const elements = focusable();
        const first = elements[0],
          last = elements.at(-1);
        if (!first) {
          e.preventDefault();
          panel.current?.focus();
          return;
        }
        if (
          e.shiftKey &&
          (document.activeElement === first ||
            document.activeElement === panel.current)
        ) {
          e.preventDefault();
          last?.focus();
        } else if (
          !e.shiftKey &&
          (document.activeElement === last ||
            !panel.current?.contains(document.activeElement))
        ) {
          e.preventDefault();
          first.focus();
        }
      }
    };
    document.addEventListener("keydown", fn);
    const old = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", fn);
      document.body.style.overflow = old;
      if (previous?.isConnected) previous.focus();
    };
  }, []);
  return (
    <div
      className="modal-overlay"
      onMouseDown={(e) => {
        if (e.target === e.currentTarget) onClose();
      }}
    >
      <section
        ref={panel}
        tabIndex={-1}
        className={`modal ${wide ? "modal-wide" : ""}`}
        role="dialog"
        aria-modal="true"
        aria-label={title}
      >
        <header className="modal-header">
          <div>
            {subtitle && <div className="eyebrow">{subtitle}</div>}
            <h2>{title}</h2>
          </div>
          <button
            className="icon-button"
            onClick={onClose}
            aria-label="Закрыть"
          >
            <X size={21} />
          </button>
        </header>
        {children}
      </section>
    </div>
  );
}
export function Metric({
  label,
  value,
  detail,
  icon,
  accent = false,
}: {
  label: string;
  value: ReactNode;
  detail: ReactNode;
  icon: ReactNode;
  accent?: boolean;
}) {
  return (
    <div className={`metric ${accent ? "metric-accent" : ""}`}>
      <div className="metric-top">
        <span>{label}</span>
        {icon}
      </div>
      <div className="metric-value">{value}</div>
      <div className="metric-detail">{detail}</div>
    </div>
  );
}
export function SectionTitle({
  title,
  caption,
  action,
}: {
  title: string;
  caption?: string;
  action?: ReactNode;
}) {
  return (
    <div className="section-title">
      <div>
        <h2>{title}</h2>
        {caption && <p>{caption}</p>}
      </div>
      {action}
    </div>
  );
}
export function Photo({ url, alt }: { url: string; alt: string }) {
  const [src, setSrc] = useState<string>();
  const [error, setError] = useState(false);
  useEffect(() => {
    let objectUrl = "";
    let alive = true;
    fetch(url.startsWith("/api") ? url : `/api${url}`, {
      headers: { Authorization: `Bearer ${token()}` },
    })
      .then((r) => {
        if (!r.ok) throw new Error();
        return r.blob();
      })
      .then((b) => {
        objectUrl = URL.createObjectURL(b);
        if (alive) setSrc(objectUrl);
      })
      .catch(() => {
        if (alive) setError(true);
      });
    return () => {
      alive = false;
      if (objectUrl) URL.revokeObjectURL(objectUrl);
    };
  }, [url]);
  return error ? (
    <div className="photo-error">
      <ImageOff size={20} />
      Фото недоступно
    </div>
  ) : src ? (
    <a href={src} target="_blank" rel="noreferrer" title="Открыть фото">
      <img className="report-photo" src={src} alt={alt} />
      <ArrowUpRight className="photo-open" size={16} />
    </a>
  ) : (
    <div className="photo-error">
      <LoaderCircle size={18} className="spin" />
    </div>
  );
}
