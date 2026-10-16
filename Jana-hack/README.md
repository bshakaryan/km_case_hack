# JanaМен Digital HR

Адаптивный HR-прототип для второго кейса Jana Post × Terricon Valley. Next.js + FastAPI, SQLAlchemy и PostgreSQL; SQLite — для быстрого локального запуска и тестов.

Сценарий: вход → read-only профиль → расчёт отпуска через HTTP mock 1С:ЗУП → заявка → руководитель → HR → списание и квитанция передачи. Дополнительно: назначенный курс с тестом и помощник с источниками из демонстрационной базы.

## Запуск в Docker

Нужны Git и запущенный Docker с Compose v2. Python, Node.js и PostgreSQL на компьютере устанавливать не нужно.

```bash
git clone https://github.com/bshakaryan/digital-hr.git
cd digital-hr
./scripts/docker-up.sh
```

Скрипт создаёт `.env` с уникальными секретами через временный Python-контейнер, затем выполняет `docker compose up --build --detach --wait`. Существующий `.env` сохраняется. При ошибке сборки, миграции или healthcheck команда завершится с ошибкой. Для Windows запускайте скрипт в WSL2 либо подготовьте `.env` через `python scripts/setup_env.py` и выполните `docker compose up --build -d --wait`.

Откройте http://localhost:3000. Документация backend: http://localhost:8000/docs. Compose поднимает PostgreSQL и отдельный mock 1С:ЗУП, применяет миграции и загружает демо-профили по HTTP, затем запускает backend, frontend и worker передачи отпусков. Повторный запуск не сбрасывает существующие записи и пароли. Данные PostgreSQL и mock сохраняются в двух именованных volume. Не используйте down -v, если хотите сохранить данные.

Если стандартные порты заняты:

```bash
WEB_PORT=3100 API_PORT=8100 ./scripts/docker-up.sh
```

В этом случае интерфейс доступен на http://localhost:3100, API — http://localhost:8100/docs. Чтобы сохранить выбор, добавьте `WEB_PORT=3100` и `API_PORT=8100` в `.env`. Браузер обращается к API через тот же origin интерфейса; адрес `backend` используется только внутри Docker. Порты опубликованы на loopback компьютера, PostgreSQL наружу не публикуется.

Управление из каталога проекта:

```bash
docker compose ps -a
docker compose logs -f backend frontend
docker compose down
```

`down` останавливает контейнеры, сохраняя базу; для следующего запуска используйте тот же скрипт. При смене каталога или Compose project name используется другой volume. Изменение `POSTGRES_PASSWORD` в `.env` не меняет пароль уже созданной базы; `DEMO_PASSWORD` также не меняет пароли существующих аккаунтов. Не подставляйте значения-заглушки из `.env.example` вместо генерации секретов.

## Тестовая публикация настоящей 1С:ЗУП

Backend можно переключить с mock на совместимый HTTP-сервис расширения 1С без изменения процесса заявок. Подготовлены Basic/Bearer-аутентификация, HTTPS с корпоративным CA или mTLS и read-only проверка, которая не создаёт документ:

Задайте параметры `ZUP_MODE`, `ZUP_DOCKER_BASE_URL`, `ZUP_AUTH_TYPE` и сервисный секрет в локальном `.env` с правами `0600`, пересоздайте backend, затем выполните:

```bash
docker compose exec -T backend python -m app.check_zup
```

Для постоянного переключения переменные задаются в `.env`; контейнерам нужен `ZUP_DOCKER_BASE_URL`, достижимый из Docker. Real-режим пропускает demo seed. До его включения в рабочем интерфейсе должны существовать согласованные аккаунты и сопоставления `employees.zup_id` с GUID 1С. Комплект для специалиста 1С и порядок приёмки: [docs/zup-integration.md](docs/zup-integration.md), [integration/1c-zup](integration/1c-zup/README.md). Без тестовой публикации и сервисных реквизитов фактическое подключение не выполняется.

## Учётные записи

Все имена, профили и кадровые данные вымышленные. Пароль для всех первоначально создаваемых аккаунтов — значение DEMO_PASSWORD из вашего локального .env. Пароль не зашит в исходники и не выводится в логи.

| Почта | Роль | Что можно проверить |
| --- | --- | --- |
| employee@example.com | Сотрудник | Свой профиль, заявки и курс |
| manager@example.com | Руководитель | Заявки сотрудника employee; запрет согласования собственной заявки |
| hr@example.com | HR | Все демо-заявки, решения, журнал через /api/audit |
| outsider@example.com | Сотрудник другого отдела | Изоляция от команды руководителя |

## Локальный запуск без Docker

Backend: Python 3.12+; frontend: Node.js 22+ и npm. Из корня проекта:

```bash
python3 -m venv .venv
.venv/bin/pip install -r backend/requirements.lock
python3 scripts/setup_env.py
```

Перед миграцией/seed запустите mock в отдельном терминале (для существующей .env без ZUP_API_TOKEN задайте отдельный токен минимум 32 символа):

```bash
PYTHONPATH=backend ZUP_MOCK_DATABASE=./zup-mock.sqlite3 .venv/bin/python -m app.run_mock_zup
```

Затем из корня проекта:

```bash
PYTHONPATH=backend .venv/bin/alembic -c backend/alembic.ini upgrade head
PYTHONPATH=backend .venv/bin/python -m app.seed
PYTHONPATH=backend .venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
```

Для автоматических повторов в ещё одном терминале: `PYTHONPATH=backend .venv/bin/python -m app.zup_worker`. `ZUP_BASE_URL` по умолчанию указывает на mock на 8300; сервисный токен хранится на backend.

Если .env уже создан, пропустите setup_env.py. В отдельном терминале:

```bash
cd frontend
npm ci
npm run dev
```

По умолчанию используется локальная SQLite jana.db. Для PostgreSQL задайте DATABASE_URL в окружении или .env и примените те же команды миграции/seed. Не переключайте URL, рассчитывая на автоматический перенос данных: миграции создают/обновляют схему в выбранной БД, перенос записей — отдельная операция.

## Проверки

Проверки полностью внутри Docker для уже запущенного стека:

```bash
docker compose exec -T backend python -m pytest -q
docker compose exec -T backend python - < scripts/compose_smoke.py
docker compose exec -T -e POSTGRES_TEST=1 backend python -m pytest -q tests/test_zup.py tests/test_requests.py tests/test_persistence.py
```

Первый набор проверяет регрессии на изолированных SQLite-базах. Второй проходит через Next.js proxy к FastAPI, PostgreSQL и отдельному mock: расчёт, права, создание/повтор/решение заявки, списание, квитанция, уведомления, курс и помощник. Он сравнивает прикладные таблицы после повторных миграции и seed. Создаёт вымышленный отпуск и расходует один день; запускайте без параллельных действий пользователей. Третий проверяет отпускной учёт и конкурентные решения на PostgreSQL в создаваемых временных схемах, которые удаляются после теста; прикладные таблицы демо не изменяются. Mock в этих тестах использует изолированное хранилище и HTTP test transport. Проверки и повторный подъём с сохранёнными volume настроены в `.github/workflows/docker.yml`.

Проверки без Docker:

```bash
cd backend
../.venv/bin/python -m pytest -q
```

```bash
cd frontend
npm run typecheck
npm run build
```

Фактические результаты и ограничения: [docs/verification.md](docs/verification.md).

Браузерный сценарий для уже запущенной локальной платформы (использует DEMO_PASSWORD из .env и создаёт демонстрационную заявку):

```bash
npm install --prefix frontend --no-save --package-lock=false playwright
cd frontend
npx playwright install chromium
cd ..
node scripts/browser_smoke.mjs
```

Runner и снимки не входят в production-образ. Снимки сохраняются в игнорируемый frontend/.qa/browser-smoke. При установленном внешнем Playwright можно указать PLAYWRIGHT_PACKAGE вместо дополнительной установки. Тест рассчитан на исходные демо-имена и назначенный seed-курс.

## Границы первой версии

- Демо-маршрут последовательный: непосредственный руководитель, затем HR; отказ завершает заявку. Для создания нужен назначенный руководитель. HTTP mock считает календарные дни без праздничных дат Казахстана (2026–2028), проверяет остаток; финальное одобрение создаёт списание и команду передачи. Ожидающие заявки не резервируют остаток, пересечения блокируются. Особые кадровые правила компании не утверждены.
- Отдельный mock 1С:ЗУП действительно читает/сохраняет данные и выдаёт квитанцию через HTTP. Реальная конфигурация компании не подключена; контракт требует реализации/сопоставления расширения 1С. [Интеграция и сценарий показа](docs/zup-integration.md). Documentolog не подключён.
- Помощник работает в mode=extractive_demo: извлекает подготовленный текст и возвращает источник либо отказ. Генеративный LLM, embeddings и pgvector пока не подключены. Для фактического AI-требования кейса следующий этап — оценённый RAG с разрешённым провайдером.
- Нет SSO, электронной подписи, полноценной LMS, внешних push/email, RU/KZ-переключателя и production-эксплуатации. Нет обещаний работы на реальном телефоне без отдельной проверки.
- JWT живёт 60 минут; frontend держит токен в памяти, перезагрузка требует нового входа. Для production нужны SSO/сессионная политика, ограничения частоты входа, TLS и операционные настройки.

[Архитектура](docs/architecture.md) · [Контракт API](docs/api-contract.md) · [Решения и открытые вопросы](docs/decisions.md) · [План и делегирование](docs/implementation-plan.md)
