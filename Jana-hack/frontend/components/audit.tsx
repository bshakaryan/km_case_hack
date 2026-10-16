"use client";

import { ApiClient, dateTime, type AuditEntry } from "@/lib/api";
import { Empty, ErrorBox, Icon, Loading } from "./ui";
import { useResource } from "./use-resource";
import { PageHeading } from "./workspace";

export function Audit({ api }: { api: ApiClient }) {
  const resource = useResource<AuditEntry[]>(api, "/audit");
  return <><PageHeading eyebrow="КОНТРОЛЬ И ПРОЗРАЧНОСТЬ" title="Журнал аудита" description="События системы в пределах доступа HR. Данные только для чтения." action={<button className="button button-secondary" onClick={resource.reload} disabled={resource.loading}><Icon name="refresh" size={17} /> Обновить</button>} /><section className="panel">{resource.error ? <ErrorBox message={resource.error} retry={resource.reload} /> : resource.loading && !resource.data ? <Loading /> : !resource.data?.length ? <Empty icon="shield" title="Событий пока нет" text="Сохранённые события системы появятся здесь." /> : <div className="table-scroll"><table><thead><tr><th>Событие</th><th>Пользователь</th><th>Объект</th><th>Время</th></tr></thead><tbody>{resource.data.map((entry) => <tr key={entry.id}><td><strong>{entry.action}</strong><small className="cell-note">Событие №{entry.id}</small></td><td>#{entry.actor_id}</td><td>{entry.entity_type} · #{entry.entity_id}</td><td>{dateTime(entry.created_at)}</td></tr>)}</tbody></table></div>}</section></>;
}
