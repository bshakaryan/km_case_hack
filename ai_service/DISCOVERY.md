# Фаза 0 — разведка НарядAI

Срез: рабочее дерево на 7 октября 2026 года. Это анализ исходников, **не** проверка живой БД или контрактные тесты. Фаза 0 не меняет существующий код и не запускает миграции. Источники: `backend/app/main.py`, `models.py`, `schemas.py`, `services.py`, `ai.py`, `seed.py`, `db.py`, `docker-compose.yml`, `README.md`, `docs/api-contract.md`.

## 1. Стек и запуск

| Компонент | Реализовано | Запуск / порт |
| --- | --- | --- |
| API | Python 3.12 в Docker, FastAPI 0.115, Pydantic 2.11, SQLAlchemy 2.0, psycopg 3, Uvicorn | `docker compose up -d --build`, контейнер `backend:8000`, с хоста `127.0.0.1:${API_PORT:-8000}`; Swagger `/docs`, OpenAPI `/openapi.json` |
| Веб | React 19, TypeScript 5, Vite 6, pnpm 11; production-сборку обслуживает nginx | Контейнер `frontend:8080`, с хоста `127.0.0.1:${WEB_PORT:-8080}`; `/api/` и WebSocket проксируются на backend. Локально Vite `5173` |
| Мобильный клиент | Flutter в `mobile/`; `native-stub/` — историческая TS-заготовка | На Android Emulator использует `API_BASE_URL=http://10.0.2.2:8000`; реальной регистрации push-устройств нет |
| Фоновые задачи | Монитор сроков в процессе API каждые ~5 с; очередь проверки сдачи ИИ обрабатывается фоновым циклом при включённом провайдере | Отдельного планировщика/брокера и общего outbox нет |

`scripts/run-local.sh` запускает Uvicorn `8000` и Vite `5173`. Основной Compose не содержит отдельного ИИ-сервиса.

## 2. Данные, БД и модель

В Compose — PostgreSQL 17 в томе `postgres_data`; `DATABASE_URL` собирается из `POSTGRES_DB/USER/PASSWORD` и передаётся контейнеру API. Значения могут приходить из корневого `.env`, но секреты в этом отчёте не приводятся. `backend/app/db.py` берёт `DATABASE_URL` из среды; без него использует SQLite `backend/data/km.db`. `scripts/run-local.sh` явно задаёт другую SQLite-БД, `data/naryad.db`. API при запуске вызывает `Base.metadata.create_all`; Alembic есть, но **в фазе 0 миграции не запускались**. Наличие модели/миграции в дереве не доказывает состояние каждой развёрнутой БД.

Существующие ORM-таблицы:

| Таблица | Существенные поля / смысл |
| --- | --- |
| `areas` | `id, name` — участки |
| `brigades` | `id, name` — бригады; состава и персонального вклада в наряде нет |
| `employees` | `id, name, login, role, pin_hash, specialty, grade, brigade_id, on_shift`; роли `worker/master/manager/admin`, персональный телефон и push-токен не хранятся |
| `auth_sessions` | `id, token_hash, employee_id, expires_at`; Bearer-токен действителен 12 часов |
| `equipment` | `id, name, inventory_number, area_id, type, criticality` |
| `fault_codes` | `id, code, name`; нет связи шифра с материалами или типом оборудования |
| `materials` | `id, name, unit`; нормы расхода по шифру/операции нет |
| `time_norms` | `id, name, hours`; у наряда отдельное числовое `normal_hours`, связи с `time_norm_id` нет |
| `orders` | `id, number, title, description, work_type, area_id, equipment_id, assignee_id, brigade_id, master_id, priority, status, deadline, created_at, started_at, completed_at, closed_at, comment, normal_hours, downtime_minutes, score, completion, ai_review`. Последние два — JSON; `score` — окончательная оценка мастера |
| `order_events` | `id, order_id, action, from_status, to_status, actor_id, created_at, comment` — аудит действий. Отдельного `assigned_at`, версий/истории назначений и интервалов работы/паузы нет |
| `photos` | `id, order_id, kind(before/after), data, author_id, created_at`. Файл нормализуется Pillow в JPEG и хранится **байтами в БД**, не в каталоге; нет времени съёмки, phash и привязки к версии сдачи |
| `material_writeoffs` | `id, order_id, material_id, quantity, author_id, created_at` — отдельные строки расхода |
| `notifications` | `id, employee_id, title, message, kind, order_id, created_at, read, dedupe_key`; уникальный ключ подавляет повтор одного события |
| `integration_logs` | `id, adapter, operation, payload, created_at`; `native_stub/push_not_sent` — запись о **неотправленном** push |
| `ai_assessments` | `id, order_id, verdict, score, explanation, is_stub, master_score, created_at` — отдельные оценки, но без связи с неизменяемой версией полного отчёта |
| `ai_review_jobs` | `id, order_id, completion_event_id, snapshot, photo_ids, result, status, attempts, next_run_at, lease_until, created_at` — сохранённые задания текущего ИИ-адаптера |

Статусы: `issued, accepted, queued, rejected, in_progress, paused, completed, ai_review, rework, closed, cancelled`. Приоритеты: `emergency, high, normal, planned`. `closed/cancelled` терминальные. `completed` — сдача, `ai_review` — результат проверки до решения человека. Просрочка вычисляется по `deadline` отдельно от статуса. Разрешённые переходы в `POST /orders/{id}/transition`:

| Действие | Откуда → куда | Особое правило |
| --- | --- | --- |
| `accept` | issued/queued/rework → accepted | Назначенный работник, мастер или admin |
| `queue` | issued/accepted/rework → queued | FIFO-позиции нет |
| `reject` | issued/accepted/queued → rejected | Обязательная причина |
| `start` | accepted/queued/rework → in_progress | На смене, нет другого `in_progress` |
| `pause` | in_progress → paused | Обязательная причина |
| `resume` | paused → in_progress | Проверка занятости как при start |
| `close` | ai_review → closed | Только master/admin, оценка 1–5 обязательна |
| `rework` | ai_review → rework | Только master/admin, обязательная причина |
| `cancel` | любой нетерминальный → cancelled | Только master/admin, обязательная причина |

`POST /orders/{id}/complete` отдельно переводит `in_progress → completed → ai_review` (в режиме заглушки сразу; с OpenAI — после фоновой задачи). `PATCH /orders/{id}` с переназначением возвращает `issued`; менять назначение нельзя во время `in_progress/paused/completed/ai_review`.

## 3. HTTP и WebSocket

Все пути ниже буквальны; основной префикс `/api`. Кроме health, входа и автоматически генерируемых `/docs`, `/redoc`, `/openapi.json`, HTTP требует `Authorization: Bearer <token>`. Работник читает только свои наряды/фото; мастер и admin — все, manager — чтение. Большая часть выходных словарей не имеет `response_model`, поэтому OpenAPI не описывает все ответы полностью.

| Метод и путь | Вход → выход | Доступ |
| --- | --- | --- |
| `GET /api/health`, `GET /health` | Проверка БД → `{status,database,ai,native}` | Публично |
| `POST /api/auth/login` | `{login,pin}` → `{token,user}`; лимит 10 попыток/мин по IP+login | Публично |
| `GET /api/auth/me` | → профиль `Employee` | Bearer |
| `POST /api/auth/logout` | → `{ok:true}`, отзыв текущей сессии | Bearer |
| `GET /api/reference` | → `{areas,equipment,employees,brigades,fault_codes,materials,time_norms}` | Bearer |
| `POST /api/reference/{collection}` | JSON полей справочника → созданная запись, 201 | admin |
| `PATCH /api/reference/{collection}/{id}` | JSON изменяемых полей → запись | admin |
| `GET /api/employees` | → работники со `status,current_order,queue_count,rating,completed_count` | Bearer |
| `GET /api/orders` | Фильтры `area_id,equipment_id,assignee_id,brigade_id,priority,status,search,from_date,to_date,limit(1–5000)` → массив кратких нарядов; период по `created_at` | Bearer; worker — свои |
| `GET /api/orders/{id}` | → полная карточка `OrderDetail`: поля наряда, `events,photos,completion,ai_review` | Bearer; worker — свой |
| `POST /api/orders` | `{title,description?,work_type,area_id,equipment_id,assignee_id? XOR brigade_id?,priority?,deadline,normal_hours?,comment?}` → `OrderDetail`, 201 | master/admin |
| `PATCH /api/orders/{id}` | `{assignee_id?,brigade_id?,priority?,deadline?,comment?}` → `OrderDetail` | master/admin |
| `POST /api/orders/{id}/transition` | `{action,reason?,comment?,score?}` → `OrderDetail`; правила выше | worker своего наряда/master/admin; close/rework/cancel — master/admin |
| `POST /api/orders/{id}/complete` | `{work_done,fault_code_id,materials?:[{material_id,quantity}],comment?}` → `OrderDetail`; внеплановый требует фото `after` | worker своего наряда/master/admin |
| `POST /api/orders/{id}/photos` | multipart `file` + `kind=before|after` → `{id,kind,url,created_at,author_name}`, 201; до 5 каждого вида, файл до 10 МиБ | worker своего наряда/master/admin |
| `GET /api/photos/{id}` | → защищённый `image/jpeg`, `Cache-Control: private, no-store` | Bearer + доступ к наряду |
| `GET /api/dashboard` | → `{issued,completed,overdue,downtime_count,active,total,avg_rating,shift_label}` | Bearer; worker — свои данные |
| `GET /api/notifications` | → последние 200 собственных `{id,title,message,kind,order_id,created_at,read}` | Bearer |
| `POST /api/notifications/{id}/read` | → `{ok:true}` | Только получатель |
| `GET /api/analytics` | `days(1–731),from_date,to_date,area_id,equipment_id,assignee_id,brigade_id` → `summary,trend,by_area,rankings,equipment,materials,insights,ai_summary,is_stub` | Bearer; worker — свои наряды |
| `POST /api/ai/insights` | Те же фильтры периода → `{summary,insights:[{title,description,recommendation,fact_ids}],facts,model,is_stub:false}` | master/manager/admin; 503 без OpenAI |
| `POST /api/ai/assistant` | `{question}` → `{answer,fact_ids,facts,model,is_stub:false}` | master/manager/admin; 503 без OpenAI |
| `POST /api/ai/order-hints` | `{description}` → `{fault_code_id,time_norm_id,explanation,model,is_stub:false}` | master/admin; 503 без OpenAI |
| `GET /api/reports/export` | Фильтры как у analytics + `format=csv|xlsx` → бинарный CSV/XLSX | Bearer; worker — свои наряды |
| `GET /api/integrations` | → состояния `ai,native,realtime` | Bearer |
| `WS /api/ws?token=…`, `WS /ws?token=…` | `connected`, затем `orders.updated`/`notifications.updated` с необязательным `order_id`; события без полной карточки | Токен сессии в query, повторная проверка ~30 с; нет replay |

Идентификаторы целочисленные. Время API — ISO 8601 UTC; пользовательские календарные даты трактуются по `Asia/Almaty`. У `GET /orders` нет offset/cursor/total, только `limit≤5000`. У POST/PATCH нет идемпотентного ключа или версии записи. Справочники и чтение заказов доступны через API, но записи `material_writeoffs` и `ai_assessments` напрямую отдельными REST-маршрутами не выдаются.

## 4. Уведомления

`backend/app/services.py:notify` пишет `notifications` и `integration_logs`. Встроенный монитор проверяет сроки, непринятие, повторы и эскалацию руководителю; пороги задаются переменными среды. `NativePushStub` пишет `push_not_sent`, **не** отправляет FCM/APNs/Telegram. Веб получает событие `notifications.updated` через WebSocket и в любом случае опрашивает API примерно каждые 5 с; Flutter также использует опрос. WebSocket — сигнал обновить данные, не внешняя доставка. Устройства и токены для push не зарегистрированы.

## 5. Уже существующие ИИ/отчёты

- В `orders.ai_review` есть JSON текущего вердикта, `orders.score` — итог мастера, `ai_assessments` — строки оценок; `ai_review_jobs` хранит snapshot/фото-ID/попытки фоновой проверки. Режимы: детерминированная заглушка по умолчанию или внешний OpenAI при `AI_PROVIDER=openai`. Отрицательный вывод не закрывает и не возвращает наряд автоматически.
- `GET /dashboard`, `GET /analytics`, `GET /reports/export`, `GET /employees` уже отдают сводки, демонстрационный рейтинг 60/30/10, CSV/XLSX. `POST /api/ai/insights|assistant|order-hints` уже существуют. Новый слой не должен объявлять их отсутствующими или менять их незаметно.
- Нет нормы материалов по шифру, полной истории попыток сдачи, достоверных интервалов простоя, календаря реальных смен/бригады на момент наряда и подтверждённой точности существующего фотоанализа. Текущее `downtime_minutes` и фильтрация отчётов по `created_at` не дают точный простой/период. Отдельного PDF-экспорта нет.

## 6. Синтетические данные

`backend/app/seed.py` при пустой таблице сотрудников и `SEED_DEMO=true` создаёт **540 исторических закрытых + 16 текущих = 556 нарядов** примерно за 89 дней; 4 участка, 25 единиц оборудования, 2 мастера, 15 работников, 3 бригады, 20 шифров `F01…F20`, 40 материалов, 6 нормативов, manager и admin. История содержит события, списания и демонстрационные оценки; стартовые фото в сиде не создаются. Уже развёрнутая база может содержать больше записей; реальное число не измерялось. Сид не совпадает с планируемым набором 600+ и шифрами `М/Э/Г/П/С` — это требования **нового** генератора, не факт о текущей БД.

## 7. Рекомендация по интеграции

**Вариант В — комбинация, поэтапно.** Для первого безопасного демо `BackendDataSource` может читать справочники, статусы, карточки и авторизованные фото через существующий API по выделенной сервисной сессии. Это сохраняет серверные проверки доступа, но токен обычного `master/admin` живёт 12 часов, отдельной сервисной роли нет, а `GET /orders` обрезается на 5000 записях и потребует N+1 запросов деталей. Поэтому для полной трёхмесячной аналитики и аудита нужен отдельный **SELECT-only пользователь PostgreSQL**, созданный администратором БД вне этого пакета; чтение следует ограничить нужными таблицами и обезличить до LLM. Свои результаты и кэш хранить в **отдельной БД `ai`**, чтобы не добавлять таблицы/миграции в существующую схему. `SyntheticDataSource` должен работать полностью автономно.

API-only (А) проще, но не гарантирует полноту истории и не раскрывает все строки списаний/оценок. DB-only (Б) даёт полноту, но обходит прикладные права, сильнее связывает сервис со схемой и не является готовым способом авторизованного показа фото пользователю. Для фаз 1–4 допустим режим API-only или synthetic с явным признаком неполной выборки; переключение на SELECT-only БД — после предоставления отдельного пользователя и проверки прав. Никаких записей в таблицы НарядAI новый сервис делать не должен.

## Ограничения фазы и состояние Git

Вне `ai_service/` **уже до этой разведки** были изменённые и неотслеживаемые файлы. Обязательная команда `git diff --name-only HEAD -- . ':!ai_service'` возвращает непустой список; она также не охватывает untracked-файлы. Эти изменения не отменялись и не включались в новый документ. **Коммит фазы 0 невозможен без нарушения условия пользователя**; нужен отдельный чистый worktree/репозиторий либо предварительное разрешение владельца на существующий diff. Тест `ai_service/tests/test_repo_untouched.py` относится к следующей подтверждённой фазе, но на этом рабочем дереве ожидаемо не пройдёт, пока внешний diff остаётся.

Фаза 0 завершена. Каркас, тесты, Dockerfile, данные, миграции и запросы к LLM **не создавались**; продолжение только после подтверждения владельца.
