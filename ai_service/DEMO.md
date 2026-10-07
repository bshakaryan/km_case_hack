# Ручная проверка отдельного ИИ-сервиса, фаза 6

Это **не** финальное семиминутное демо всего кейса: нет реальных пар фото с экспертной разметкой, автоматической передачи событий из backend и живого push. Шаги ниже работают только с отдельным сервисом, не меняют основной backend. Фоновый монитор по умолчанию выключен; токен для маршрутов задаётся в `ai_service/.env`.

## Подготовка

Из каталога `ai_service/` создайте данные и запустите сервис:

```powershell
python -m data_gen.generate
python -m uvicorn app.main:app --host 127.0.0.1 --port 8090
```

Во втором терминале из того же каталога задайте **свой** токен, совпадающий с `AI_SERVICE_TOKEN` в `ai_service/.env`:

```powershell
$headers = @{ Authorization = "Bearer <ваш-AI_SERVICE_TOKEN>" }
Invoke-RestMethod http://127.0.0.1:8090/ai/health
```

`http://127.0.0.1:8090/docs` показывает контракт отдельного сервиса.

## Сценарий

1. Проверка сдачи без внешней модели: `Invoke-RestMethod -Method Post -Headers $headers http://127.0.0.1:8090/ai/reviews/1`. Ответ `scheduled` содержит `source_version`; спустя секунду `Invoke-RestMethod -Headers $headers http://127.0.0.1:8090/ai/reviews/1` показывает рекомендательный вердикт, флаги и оценку. При `DEMO_MODE=true` API-ключ не используется.
2. Отчёт мастеру: `Invoke-RestMethod -Headers $headers 'http://127.0.0.1:8090/ai/reports/orders/1?audience=master'`. Для исполнителя замените `master` на `worker`. Экспорт: `Invoke-WebRequest -Headers $headers 'http://127.0.0.1:8090/ai/reports/orders/1?format=pdf' -OutFile state/order-report.pdf`; XLSX — `format=xlsx`.
3. Отчёт периода: `Invoke-RestMethod -Headers $headers 'http://127.0.0.1:8090/ai/reports/shift?start=2026-07-01T00%3A00%3A00Z&end=2026-07-02T00%3A00%3A00Z'`. Рейтинг: тот же период через `/ai/ratings?start=...&end=...`; для всего набора используйте конец `2026-10-01`.
4. Контроль сроков: `Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' -Body '{}' http://127.0.0.1:8090/ai/deadlines/tick`. Все 719 исторических синтетических нарядов закрыты, поэтому список уведомлений здесь **пуст**. Проверка аварийного порога, повтора, эскалации, замены и отсутствия дублей — `python -m pytest -q tests/test_mvp_modules.py::test_deadline_tick_thresholds_repeats_and_persistence`.
5. Фото после: `Invoke-RestMethod -Method Post -Headers $headers http://127.0.0.1:8090/ai/photos/1/review`; затем `Invoke-RestMethod -Headers $headers http://127.0.0.1:8090/ai/photos/1/review`. В `DEMO_MODE=true` возвращается `needs_master_review`, а не вымышленная оценка качества; время съёмки — `unknown`. Технические дубли демонстрирует `python -m pytest -q tests/test_phase5.py::test_photo_fallback_duplicate_and_missing_after`.
6. Аналитика за 90 дней: `Invoke-RestMethod -Headers $headers 'http://127.0.0.1:8090/ai/analytics?start=2026-07-01T03%3A00%3A00Z&end=2026-09-29T03%3A00%3A01Z'`. В ответе — факты, ссылки на наряды и рекомендации; среди них конвейер К-3, E-11, насос после ППР, ночная смена бригады 2, E-04 и рост по мельнице. Еженедельная сводка по запросу: `/ai/analytics/weekly?end=2026-09-29T03%3A00%3A01Z`.
7. Воспроизводимые метрики: `python -m eval.run`, затем откройте `reports/metrics.md`. На процедурных фото оцениваются только технические дубли, не качество ремонта; у аналитики две дополнительные неразмеченные гипотезы, которые проверяет мастер.

Бонусы фазы 6 можно показать после основного сценария:

```powershell
Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' -Body '{"question":"Кто свободен из слесарей?","now":"2026-09-29T03:00:00Z"}' http://127.0.0.1:8090/ai/assistant/ask
Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json' -Body '{"phrase":"Конвейер К-3: обрыв ремня. Участок Дробильно-сортировочный комплекс, срок через 3 ч.","now":"2026-07-03T03:00:00Z"}' http://127.0.0.1:8090/ai/intake/text
```

Первый ответ содержит кодом рассчитанное число свободных работников; второй — только черновик с ID и сроком, **без создания наряда**. Голосовой маршрут `/ai/intake/voice` без настроенного `STT_MODEL` возвращает `needs_transcript`. Реальное аудио в демо не отправляйте во внешний STT без отдельного решения Q01.

Для реального Telegram задайте `TELEGRAM_BOT_TOKEN` и карту `TELEGRAM_CHATS`; без них `LogNotifier` не утверждает факт доставки. Негативные кейсы «без фото», «лишний материал», «чужая работа» проверяются `tests/test_mvp_modules.py::test_rule_verdicts_fresh_store_per_card`. Реальную vision-accuracy пока невозможно показать без 15–20 экспертно размеченных пар.
