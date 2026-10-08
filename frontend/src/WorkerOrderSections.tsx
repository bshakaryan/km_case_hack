import { ArrowRight } from "lucide-react";
import { formatDate } from "./model";
import type { Id, Order } from "./model";
import { AssignmentParticipants } from "./AssignmentParticipants";
import { Priority, SectionTitle, Status } from "./ui";

export function WorkerOrderSections({
  queue,
  assisting,
  onSelect,
}: {
  queue: Order[];
  assisting: Order[];
  onSelect: (id: Id) => void;
}) {
  return (
    <>
      {queue.length > 0 && (
        <section className="incoming-section">
          <SectionTitle
            title={`Моя очередь · ${queue.length}`}
            caption="Начало по порядку очереди ответственного."
          />
          <div className="current-work-grid">
            {queue.map((order) => (
              <article className="current-task" key={order.id}>
                <div className="section-topline">
                  <span>{order.number}</span>
                  <Status value={order.status} />
                </div>
                <h3>{order.title}</h3>
                <p>
                  {order.equipment_name} · {order.area_name}
                </p>
                <p>
                  Позиция {order.queue_position ?? "—"} · до{" "}
                  {formatDate(order.deadline, true)}
                </p>
                <button
                  className="button secondary"
                  onClick={() => onSelect(order.id)}
                >
                  Открыть задание <ArrowRight size={16} />
                </button>
              </article>
            ))}
          </div>
        </section>
      )}
      {assisting.length > 0 && (
        <section className="incoming-section">
          <SectionTitle
            title={`Участие в бригадных нарядах · ${assisting.length}`}
            caption="Общие работы, в которых вы участник. Очередью и сдачей результата управляет ответственный."
          />
          <div className="current-work-grid">
            {assisting.map((order) => (
              <article className="current-task" key={order.id}>
                <div className="section-topline">
                  <span>{order.number}</span>
                  <Status value={order.status} />
                </div>
                <h3>{order.title}</h3>
                <p>
                  {order.equipment_name} · {order.area_name}
                </p>
                <div className="task-flags">
                  <Priority value={order.priority} />
                </div>
                <p>Ответственный: {order.assignee_name}</p>
                <AssignmentParticipants assignment={order} />
                <button
                  className="button secondary"
                  onClick={() => onSelect(order.id)}
                >
                  Открыть общий наряд <ArrowRight size={16} />
                </button>
              </article>
            ))}
          </div>
        </section>
      )}
    </>
  );
}
