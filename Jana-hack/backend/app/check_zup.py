"""Read-only contract probe for mock or real 1C:ZUP.

This command never calls the document registration endpoint.
"""
import argparse
import json
from datetime import date

from app.config import get_settings
from app.modules.integrations import zup_adapter


def main():
    parser = argparse.ArgumentParser(description="Проверка HTTP-контракта 1С:ЗУП без записи документов")
    parser.add_argument("--employee-id", help="GUID/идентификатор сотрудника в 1С для проверки остатка")
    parser.add_argument("--start", type=date.fromisoformat, help="Начало тестового периода YYYY-MM-DD")
    parser.add_argument("--end", type=date.fromisoformat, help="Конец тестового периода YYYY-MM-DD")
    args = parser.parse_args()
    if bool(args.start) != bool(args.end):
        parser.error("--start и --end задаются вместе")
    if args.start and not args.employee_id:
        parser.error("для расчёта требуется --employee-id")

    settings = get_settings()
    adapter = zup_adapter()
    employees = adapter.employees()
    result = {
        "connected": True,
        "mode": f"{settings.zup_mode}_http",
        "contract": "jana-zup-v1",
        "auth_type": settings.zup_auth_type,
        "tls_verified": settings.zup_tls_verified,
        "employees_available": len(employees),
        "write_performed": False,
    }
    if args.employee_id:
        balance = adapter.balance(args.employee_id)
        result["employee_found"] = any(item.zup_id == args.employee_id for item in employees)
        result["balance"] = balance.balance
        result["applied_commands"] = len(balance.applied_commands)
    if args.start:
        calculation = adapter.calculate(args.employee_id, args.start, args.end)
        result["calculation"] = {
            "start_date": args.start.isoformat(),
            "end_date": args.end.isoformat(),
            "calendar_days": calculation.calendar_days,
            "days_count": calculation.days_count,
            "excluded_dates": [day.isoformat() for day in calculation.excluded_dates],
            "calendar_version": calculation.calendar_version,
        }
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
