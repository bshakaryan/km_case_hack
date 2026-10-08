import { useRef, useState } from "react";
import type { FormEvent } from "react";
import { MessageCircle, Send, X } from "lucide-react";
import { post, token } from "./model";

type Entry = { question: string; answer: string };

export function MasterAssistant() {
  const [open, setOpen] = useState(false);
  const [input, setInput] = useState("");
  const [entries, setEntries] = useState<Entry[]>([]);
  const [busy, setBusy] = useState(false);
  const serial = useRef(0);

  async function ask(event: FormEvent) {
    event.preventDefault();
    const question = input.trim();
    if (busy || question.length < 2) return;
    const capturedToken = token();
    const request = ++serial.current;
    setBusy(true);
    setInput("");
    try {
      const result = await post<{ answer: string }>("/assistant/ask", { message: question });
      if (request === serial.current && token() === capturedToken)
        setEntries((current) => [...current, { question, answer: result.answer }]);
    } catch (error) {
      if (request === serial.current && token() === capturedToken)
        setEntries((current) => [...current, { question, answer: (error as Error).message }]);
    } finally {
      if (request === serial.current) setBusy(false);
    }
  }

  return (
    <div className="master-assistant">
      {open && <section className="assistant-panel" aria-label="Ассистент мастера">
        <header><strong>Ассистент мастера</strong><button type="button" aria-label="Закрыть ассистента" onClick={() => setOpen(false)}><X size={18} /></button></header>
        <div className="assistant-messages" aria-live="polite">
          {entries.length === 0 && <p>Спросите: «Кто сейчас свободен из электриков?», «Что просрочено?» или «Отчёт за неделю по участку обогащения».</p>}
          {entries.map((entry, index) => <div key={index}><p className="assistant-question">{entry.question}</p><p className="assistant-answer">{entry.answer}</p></div>)}
          {busy && <p>Проверяю актуальные данные…</p>}
        </div>
        <form onSubmit={(event) => void ask(event)}>
          <input value={input} onChange={(event) => setInput(event.target.value)} maxLength={500} placeholder="Задайте вопрос" aria-label="Вопрос ассистенту" />
          <button type="submit" disabled={busy || input.trim().length < 2} aria-label="Отправить"><Send size={18} /></button>
        </form>
      </section>}
      <button className="assistant-toggle" type="button" onClick={() => setOpen((value) => !value)} aria-label="Ассистент мастера" aria-expanded={open}><MessageCircle size={23} /></button>
    </div>
  );
}
