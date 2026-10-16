"""Versioned demo calendar for Kazakhstan annual paid leave (not payroll)."""
from datetime import date

CALENDAR_VERSION = "kz-statutory-2026-v1"
SUPPORTED_YEARS = (2026, 2027, 2028)
HOLIDAYS = ((1, 1), (1, 2), (3, 8), (3, 21), (3, 22), (3, 23),
            (5, 1), (5, 7), (5, 9), (7, 6), (8, 30), (10, 25), (12, 16))


def calculate_days(start: date, end: date) -> dict:
    if end < start:
        raise ValueError("Дата окончания должна быть не раньше даты начала")
    if start.year not in SUPPORTED_YEARS or end.year not in SUPPORTED_YEARS:
        raise ValueError("Демо-календарь поддерживает только 2026–2028 годы")
    excluded = sorted(date(year, month, day) for year in range(start.year, end.year + 1)
                      for month, day in HOLIDAYS if start <= date(year, month, day) <= end)
    total = (end - start).days + 1
    return {"days_count": total - len(excluded), "calendar_days": total,
            "excluded_dates": [day.isoformat() for day in excluded],
            "calendar_version": CALENDAR_VERSION}
