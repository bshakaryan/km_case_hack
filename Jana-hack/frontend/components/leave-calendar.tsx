import type { LeaveCalculation } from "@/lib/api";

const weekdays = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"];
const monthTitle = new Intl.DateTimeFormat("ru-RU", { month: "long", year: "numeric", timeZone: "UTC" });
const fullDate = new Intl.DateTimeFormat("ru-RU", { day: "numeric", month: "long", year: "numeric", timeZone: "UTC" });

function isoDate(year: number, month: number, day: number) {
  return `${year}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

function monthsBetween(start: string, end: string) {
  const [startYear, startMonth] = start.split("-").map(Number);
  const [endYear, endMonth] = end.split("-").map(Number);
  const months: { year: number; month: number }[] = [];
  let year = startYear;
  let month = startMonth - 1;
  while (year < endYear || (year === endYear && month <= endMonth - 1)) {
    months.push({ year, month });
    month += 1;
    if (month === 12) { month = 0; year += 1; }
  }
  return months;
}

export function LeaveCalendar({ calculation }: { calculation: LeaveCalculation }) {
  const holidays = new Set(calculation.excluded_dates);
  const months = monthsBetween(calculation.start_date, calculation.end_date);
  const source = calculation.source === "zup_http" ? "1С:ЗУП" : "mock 1С:ЗУП";
  return <section className="leave-calendar" aria-label="Календарь расчёта отпуска">
    <div className="leave-calendar-heading">
      <div><strong>Календарь расчёта</strong><span>Праздники отмечены по данным {source}</span></div>
      <div className="leave-calendar-legend" aria-label="Условные обозначения">
        <span><i className="legend-holiday" /> Праздник · не списывается</span>
        <span><i className="legend-weekend" /> Выходной · учитывается</span>
      </div>
    </div>
    <div className="leave-calendar-months">
      {months.map(({ year, month }) => {
        const firstDay = new Date(Date.UTC(year, month, 1));
        const leading = (firstDay.getUTCDay() + 6) % 7;
        const days = new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
        return <div className="leave-calendar-month" key={`${year}-${month}`}>
          <h3>{monthTitle.format(firstDay)}</h3>
          <div className="leave-calendar-weekdays" aria-hidden="true">
            {weekdays.map((day) => <span key={day}>{day}</span>)}
          </div>
          <div className="leave-calendar-grid">
            {Array.from({ length: leading }, (_, index) => <span className="calendar-empty" key={`empty-${index}`} />)}
            {Array.from({ length: days }, (_, index) => {
              const day = index + 1;
              const value = isoDate(year, month, day);
              const weekDay = new Date(Date.UTC(year, month, day)).getUTCDay();
              const holiday = holidays.has(value);
              const weekend = weekDay === 0 || weekDay === 6;
              const selected = value >= calculation.start_date && value <= calculation.end_date;
              const boundary = value === calculation.start_date || value === calculation.end_date;
              const label = `${fullDate.format(new Date(`${value}T00:00:00Z`))}${!selected ? ", вне выбранного периода" : holiday ? ", праздничный день, не списывается" : weekend ? ", выходной день, учитывается" : ", учитывается"}`;
              return <span
                key={value}
                className={`calendar-day${selected ? " selected" : ""}${selected && holiday ? " holiday" : ""}${selected && weekend ? " weekend" : ""}${boundary ? " boundary" : ""}`}
                aria-label={label}
                title={label}
              >{day}</span>;
            })}
          </div>
        </div>;
      })}
    </div>
  </section>;
}
