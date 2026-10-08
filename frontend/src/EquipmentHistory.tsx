import { useEffect, useState } from "react";
import { api, token } from "./model";
import type { Id, Reference, User } from "./model";
import { canViewEquipmentHistory } from "./journal";
import { OrderJournal } from "./OrderJournal";
import { ErrorBox, Loading, Modal } from "./ui";

type Equipment = {
  id: Id;
  name: string;
  inventory_number: string;
  area_id: Id;
  area_name: string;
  type: string;
  criticality: string;
};
const criticalities: Record<string, string> = {
  high: "Высокая",
  medium: "Средняя",
  low: "Низкая",
};
export function EquipmentHistory({
  id,
  user,
  reference,
  active,
  invalidation,
  onSelect,
  onClose,
}: {
  id: Id;
  user: User;
  reference: Reference;
  active: boolean;
  invalidation: number;
  onSelect: (id: Id) => void;
  onClose: () => void;
}) {
  const [equipment, setEquipment] = useState<Equipment | null>(null);
  const [error, setError] = useState("");
  const [retry, setRetry] = useState(0);
  const allowed = canViewEquipmentHistory(user.role);
  useEffect(() => {
    if (!allowed || !active) return;
    const controller = new AbortController();
    const session = token();
    let current = true;
    api<Equipment>(`/equipment/${id}`, { signal: controller.signal })
      .then((value) => {
        if (current && token() === session) {
          setEquipment(value);
          setError("");
        }
      })
      .catch((failure) => {
        if (current && token() === session) setError(failure.message);
      });
    return () => {
      current = false;
      controller.abort();
    };
  }, [active, allowed, id, retry, user.id]);
  return (
    <Modal
      title={equipment?.name ?? "История оборудования"}
      subtitle="ОБОРУДОВАНИЕ И РЕМОНТЫ"
      onClose={onClose}
      active={active}
      wide
    >
      <div className="modal-body">
        {!allowed ? (
          <p>
            История оборудования доступна мастеру, руководителю и
            администратору. Работнику доступны его наряды.
          </p>
        ) : (
          <>
            {error && (
              <ErrorBox
                message={error}
                retry={() => setRetry((value) => value + 1)}
              />
            )}
            {!equipment && !error && <Loading />}
            {equipment && (
              <div className="detail-info-grid equipment-summary">
                <div>
                  <small>Инвентарный номер</small>
                  <strong>{equipment.inventory_number}</strong>
                </div>
                <div>
                  <small>Участок</small>
                  <strong>{equipment.area_name}</strong>
                </div>
                <div>
                  <small>Тип</small>
                  <strong>{equipment.type}</strong>
                </div>
                <div>
                  <small>Критичность</small>
                  <strong>
                    {criticalities[equipment.criticality] ??
                      equipment.criticality}
                  </strong>
                </div>
              </div>
            )}
            <p className="field-hint">
              История включает все доступные ремонты, включая закрытые.
              Интервалы фактической остановки оборудования отдельно пока не
              измеряются.
            </p>
            <OrderJournal
              user={user}
              reference={reference}
              onSelect={onSelect}
              initialScope="all"
              equipmentId={id}
              invalidation={invalidation}
              active={active}
            />
          </>
        )}
      </div>
      <footer className="modal-footer">
        <button className="button secondary" onClick={onClose}>
          Закрыть историю
        </button>
      </footer>
    </Modal>
  );
}
