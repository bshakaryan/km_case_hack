"use client";

import { ApiClient } from "@/lib/api";
import { ErrorBox, Icon, Loading } from "./ui";
import { useResource } from "./use-resource";

interface Integration { connected: boolean; mode: "mock_http" | "real_http"; contract: string; auth_type: "bearer" | "basic"; tls_verified: boolean; mapped_employees: number; pending: number; error: number; synced: number }

export function ZupIntegration({ api }: { api: ApiClient }) {
  const resource = useResource<Integration>(api, "/integrations/zup");
  const real = resource.data?.mode === "real_http";
  return <section className="panel"><div className="panel-heading"><div><h2>Интеграция 1С:ЗУП</h2><p className="muted small-text">{real ? "Реальная база" : "Демонстрационный сервис"} · jana-zup-v1</p></div><button className="text-button" onClick={resource.reload} disabled={resource.loading}><Icon name="refresh" size={16} /> Проверить связь</button></div><div className="request-comment">{resource.error ? <ErrorBox message={resource.error} retry={resource.reload} /> : !resource.data ? <Loading /> : <div className="notice"><Icon name="check" /><span>{real ? "1С:ЗУП" : "Mock 1С:ЗУП"} подключён по HTTP{real ? `S, ${resource.data.auth_type === "basic" ? "Basic" : "Bearer"}-аутентификация${resource.data.tls_verified ? ", сертификат проверяется" : ""}` : ""}. Сопоставлено сотрудников: <strong>{resource.data.mapped_employees}</strong>. Передано отпусков: <strong>{resource.data.synced}</strong>; в очереди: {resource.data.pending}; требуют повтора: {resource.data.error}. Квитанция передачи доступна в карточке заявки.</span></div>}</div></section>;
}
