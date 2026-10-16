# API Digital HR v0.2

Это целевой контракт первой реализации. Наличие маршрутов проверяется тестами и OpenAPI; статус реализации перечислен в verification.md. Префикс /api. JSON, даты YYYY-MM-DD, время UTC ISO 8601. Bearer JWT для всех маршрутов кроме login и health. Ошибки: {"detail": "сообщение"}; валидация FastAPI — detail массив.

## Вход и профиль

- POST /api/auth/login — {email, password} → {access_token, token_type:"bearer"}.
- GET /api/me → {id:number, email, full_name, role:"employee"|"manager"|"hr_admin", company, position, department, manager_id:number|null, manager_name:string|null, hire_date, leave_balance:number, data_source:"mock_zup"|"zup"}. `leave_balance` — текущий остаток из настроенного HTTP-источника 1С:ЗУП минус локальные списания, которые источник ещё не подтвердил по ключу команды. Исходные кадровые поля не перезаписываются. Недоступный источник → 503; несопоставленный профиль → 409. Имя руководителя является частью разрешённого собственного профиля; полный профиль руководителя сотруднику не раскрывается.
- GET /api/employees → массив тех же профилей: сотруднику только свой, руководителю свой и прямые подчинённые, HR все.
- GET /api/employees/{id} → профиль; недоступный id возвращает 404.

## Заявки

- GET /api/requests → массив доступных заявок, новые первыми.
- POST /api/requests/calculate — {start_date,end_date,comment?:string}; только для текущего пользователя. Возвращает {start_date,end_date,days_count,calendar_days,excluded_dates:string[],calendar_version,available_balance,balance_after,sufficient_balance,source:"mock_zup_http"|"zup_http"}. В mock-режиме действуют демонстрационные правила ниже; в real-режиме дни, исключения и версию календаря возвращает опубликованный сервис 1С. Недоступность источника → 503, неподдерживаемый период/неверный порядок/ноль списываемых дней → 422. Недостаточный остаток показывается `sufficient_balance=false`, отрицательный `balance_after` — прогноз нехватки. Расчёт ничего не резервирует и не создаёт заявку.

Пересечение с действующей локальной заявкой или зарегистрированным отпуском источника при расчёте → 409.
- POST /api/requests — заголовок Idempotency-Key обязателен (8–128 символов); тело {start_date,end_date,comment:string}; результат 201. Сервер заново запрашивает расчёт и сохраняет его снимок. Ненастроенный руководитель, недостаточный остаток или пересечение с submitted/manager_approved/approved своего сотрудника → 409 без создания. При недоступности источника → 503; клиентский days_count/employee_id не принимается.
- GET /api/requests/{id} → доступная заявка.
- PATCH /api/requests/{id}/status — {status:"approved"|"rejected",version:number,comment:string}. Для `submitted` решение принимает только непосредственный руководитель: `approved` переводит заявку в `manager_approved`, `rejected` завершает её. Для `manager_approved` решение принимает только HR: `approved` атомарно создаёт списание и outbox, `rejected` завершает заявку без списания. Перед списанием сервер повторно проверяет расчёт и доступный остаток под блокировкой сотрудника. Нехватка дней, новый календарь или пересечение с одобренным периодом → 409; источник недоступен → 503; заявка остаётся `manager_approved`. Исторические ожидающие заявки получают актуальный расчёт при финальном решении. Автор не может согласовывать свою заявку; неверный этап или устаревшая version → 409. После commit выполняется попытка доставки: её ошибка сохраняет решение HR и очередь, отражается `zup_sync_status="error"` в успешном ответе.
- POST /api/requests/{id}/sync — только HR, повторяет сохранённую команду. Возвращает заявку; доставка уже подтверждена → безопасный повтор, команда отсутствует → 409. Отказ/таймаут внешней системы сохраняется в очереди для повторной попытки. Worker повторяет автоматически с задержкой до 300 секунд.

Заявка: {id,employee_id,employee_name,type:"leave",start_date,end_date,days_count:number,excluded_dates:string[],calendar_version:string,zup_sync_status:"not_required"|"pending"|"synced"|"error"|"legacy",zup_reference:string|null,comment,status:"submitted"|"manager_approved"|"approved"|"rejected",version:number,created_at,history:[{status,actor_name,comment,created_at}]}.

`legacy` означает историческое одобрение без новой команды доставки. Такой статус не выдаётся за успешную передачу. Статусы бизнес-согласования и доставки независимы.

`calendar_version="legacy-deducted"` сохраняет число ранее списанных дней по прежнему правилу. Для него `excluded_dates=[]`; современный календарь не переопределяет исторический расчёт.

Повтор POST с тем же ключом и телом возвращает тот же id (201); другое тело — 409. Создание и промежуточное согласование не резервируют остаток; поэтому конкурирующая ожидающая заявка может получить 409 при финальном решении HR. Повтор финального решения не создаёт второе списание. Отправка в Documentolog в MVP отсутствует.

## Уведомления

- GET /api/notifications → [{id,kind,title,body,read:boolean,created_at}]; только свои.
- PATCH /api/notifications/{id}/read → тот же объект; повтор безопасен.

## Academy

- GET /api/courses → назначенные текущему пользователю курсы.
- GET /api/courses/{id} → назначенный курс.
- POST /api/courses/{id}/progress — {progress:integer 0..100}; увеличивает прогресс, не отмечает завершение без теста.
- POST /api/courses/{id}/complete — {answer_index:integer}; неверный ответ → 422. При успехе progress=100, completed=true. Повтор не создаёт второе уведомление.

Курс: {id,title,description,content:string,duration_minutes,progress,completed,question,options:string[]}.

## Помощник

- POST /api/assistant/query — {question:string 3..1000} → {answer,sources:[{document_id,title,section,content}],escalate_to_hr:boolean,mode:"extractive_demo"}.
- GET /api/knowledge/{id} → {document_id,title,section,content}; доступ только по области документа. Никаких персональных данных и инструментов записи у помощника нет.

Демо-база описывает прототип, а не кадровые правила компании. Неизвестный вопрос → отказ и sources=[]. Источник открывается в UI по document_id. Внешний LLM не вызывается.

## Служебное

- GET /api/integrations/zup — только HR; проверяет HTTP-соединение и возвращает {connected:true,mode:"mock_http"|"real_http",contract:"jana-zup-v1",auth_type:"bearer"|"basic",tls_verified:boolean,mapped_employees,pending,error,synced}. Если источник не ответил → 503. URL, имя пользователя и секреты не раскрываются. Контракт и подключение настоящей 1С — [zup-integration.md](zup-integration.md).

- GET /api/health → {status:"ok"}; проверяет БД.
- GET /api/audit → [{id,actor_id,action,entity_type,entity_id,created_at}]; только HR, последние 200 событий. Записываются входы, создание/решения заявок, `leave.deducted`, подтверждение `zup.leave_registered`, назначение/увеличение прогресса/завершение курса и первое прочтение уведомления. Неудачные попытки доставки и их число сохранены в outbox. Аудит не содержит паролей, JWT и текста вопросов.
- GET /docs, GET /openapi.json — автоматически формируются FastAPI.
