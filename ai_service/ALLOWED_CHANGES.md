# Разрешённые изменения основной кодовой базы

Этап 1, ветка `feature/ai-integration`. Охранный тест допускает изменение только следующих файлов `backend/` и `frontend/`:

- `backend/app/ai.py`
- `backend/app/ai_service_client.py`
- `backend/app/main.py`
- `backend/tests/test_ai_service_integration.py`
- `frontend/src/Orders.tsx`
- `frontend/src/Pages.tsx`
- `frontend/src/model.ts`

Тест проверяет **индекс Git**, из которого будет создан коммит, а не всю рабочую копию: в ней до этапа уже были незакоммиченные изменения владельца. Поэтому перед каждым коммитом запускайте тест и отдельно просматривайте `git diff --cached --name-only` и `git diff --cached`. Изменения документации и конфигурации рассматриваются отдельно; тест не выдаёт их за созданные в этом этапе.
