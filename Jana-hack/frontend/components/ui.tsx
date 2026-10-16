"use client";

import { useEffect, useId, useRef, type ReactNode } from "react";
import { statusLabel, type RequestStatus } from "@/lib/api";

const paths = {
  home: "m3 10 9-7 9 7v10a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1Z",
  user: "M20 21v-2a7 7 0 0 0-14 0v2M16 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z",
  document: "M14 2H5v20h14V7ZM14 2v6h5M8 12h8M8 16h6",
  book: "M12 5C8 2 5 3 2 4v15c3-1 6-2 10 1 4-3 7-2 10-1V4c-3-1-6-2-10 1ZM12 5v15",
  spark: "m12 3 2.5 6.5L21 12l-6.5 2.5L12 21l-2.5-6.5L3 12l6.5-2.5ZM20 2v4M18 4h4",
  bell: "M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4",
  arrow: "M5 12h14m-5-5 5 5-5 5",
  plus: "M12 5v14M5 12h14",
  close: "m6 6 12 12M6 18 18 6",
  check: "m5 12 4 4L19 6",
  logout: "M9 4H4v16h5M13 7l5 5-5 5M8 12h12",
  calendar: "M4 5h16v16H4ZM8 2v6M16 2v6M4 10h16M8 14h2M14 14h2",
  clock: "M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0ZM12 6v6l4 2",
  chevron: "m9 5 7 7-7 7",
  menu: "M4 6h16M4 12h16M4 18h16",
  shield: "m12 2 8 4v6c0 5-8 10-8 10S4 17 4 12V6ZM8 12l3 3 5-6",
  people: "M16 21v-2a6 6 0 0 0-12 0v2M14 7a4 4 0 1 1-8 0 4 4 0 0 1 8 0ZM20 21v-2a6 6 0 0 0-3-5M17 3a4 4 0 0 1 0 8",
  refresh: "M20 7a9 9 0 1 0 1 9M20 2v6h-6",
  leaf: "M20 3C8 2 3 8 5 15c3 8 16 5 15-12ZM5 20 16 9",
  mail: "M3 5h18v14H3ZM3 5l9 8 9-8",
  info: "M22 12a10 10 0 1 1-20 0 10 10 0 0 1 20 0ZM12 11v6M12 7h.01",
  eye: "M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12ZM15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z",
  send: "m22 2-7 20-4-9-9-4ZM22 2 11 13",
} as const;
export type IconName = keyof typeof paths;
export function Icon({ name, size = 20, className = "" }: { name: IconName; size?: number; className?: string }) {
  return <svg className={className} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.65" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={paths[name]} /></svg>;
}
export function Brand({ light = false }: { light?: boolean }) {
  return <div className={`brand ${light ? "brand-light" : ""}`}><span className="brand-symbol">j<span>↗</span></span><span>Jana<span className="brand-men">Мен</span><small>DIGITAL HR</small></span></div>;
}
export function Status({ value }: { value: RequestStatus }) {
  return <span className={`status status-${value}`}><span />{statusLabel[value]}</span>;
}
export function Loading({ label = "Загружаем данные…" }: { label?: string }) {
  return <div className="loading-state" role="status"><span className="spinner" /><span>{label}</span></div>;
}
export function ErrorBox({ message, retry }: { message: string; retry?: () => void }) {
  return <div className="error-box" role="alert"><Icon name="info" /><div>{message}{retry && <button className="text-button" onClick={retry}>Попробовать снова <Icon name="refresh" size={14} /></button>}</div></div>;
}
export function Empty({ icon = "document", title, text, action }: { icon?: IconName; title: string; text: string; action?: ReactNode }) {
  return <div className="empty-state"><span className="empty-icon"><Icon name={icon} size={27} /></span><h3>{title}</h3><p>{text}</p>{action}</div>;
}
export function Modal({ title, children, onClose, wide = false }: { title: string; children: ReactNode; onClose: () => void; wide?: boolean }) {
  const id = useId();
  const dialog = useRef<HTMLDialogElement>(null);
  const close = useRef(onClose);
  close.current = onClose;
  useEffect(() => {
    const element = dialog.current;
    const previous = document.activeElement;
    element?.showModal();
    const cancel = (event: Event) => { event.preventDefault(); close.current(); };
    element?.addEventListener("cancel", cancel);
    return () => { element?.removeEventListener("cancel", cancel); element?.close(); if (previous instanceof HTMLElement) previous.focus(); };
  }, []);
  return <dialog ref={dialog} className={`modal ${wide ? "modal-wide" : ""}`} aria-labelledby={id} onClick={(event) => { if (event.target === event.currentTarget) onClose(); }}><div className="modal-inner"><div className="modal-header"><h2 id={id}>{title}</h2><button className="icon-button" onClick={onClose} aria-label="Закрыть"><Icon name="close" /></button></div>{children}</div></dialog>;
}
