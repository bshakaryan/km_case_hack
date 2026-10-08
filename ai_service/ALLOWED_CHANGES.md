# Разрешённый объём переноса в master

По явному поручению владельца переносим модули из `feature/ai-integration`, а не восстанавливаем удалённые таблицы/статус ИИ из старого master.

Изменения допускаются только в этих путях (новые файлы внутри `ai_service/` включены):

- `.env.example`
- `README.md`
- `ai_service/`
- `backend/app/ai_service_client.py`
- `backend/app/main.py`
- `backend/tests/test_ai_service_bridge.py`
- `docker-compose.yml`
- `docs/README.md`
- `docs/architecture.md`
- `docs/api-contract.md`
- `docs/decisions.md`
- `docs/implementation-plan.md`
- `docs/requirements.md`
- `docs/verification.md`
- `docs/web-ux.md`
- `frontend/src/Orders.tsx`
- `frontend/src/Pages.tsx`

Исходная ветка не изменяется. Миграция `0009_remove_ai_modules` остаётся; рекомендации хранятся отдельно. Автоматического изменения статуса по рекомендации нет.
