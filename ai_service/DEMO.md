# Семиминутное демо отдельного ИИ-сервиса

Это **не** финальное семиминутное демо всего кейса: нет реальных пар фото с экспертной разметкой, автоматической передачи событий из backend и живого push. Шаги ниже работают только с отдельным сервисом, не меняют основной backend. Фоновый монитор по умолчанию выключен; токен для маршрутов задаётся в `ai_service/.env`.

Если показываете открытые фото-пары на экране, сначала выполните `python -m eval.photos.select_demo` из `ai_service/` и берите изображения только из `eval/photos/demo_safe/` с `manifest.csv`. Старую папку `eval/photos/demo/` и любые изображения `project-7mbdj/999-krc03` не используйте: лицензия этого источника не подтверждена.

## Подготовка

Из каталога `ai_service/` создайте данные и запустите сервис:

```powershell
python -m eval.fetch_equipment_model
python -m data_gen.generate
python -m uvicorn app.main:app --host 127.0.0.1 --port 8090
```

Во втором терминале из того же каталога задайте **свой** токен, совпадающий с `AI_SERVICE_TOKEN` в `ai_service/.env`:

```powershell
$headers = @{ Authorization = "Bearer <ваш-AI_SERVICE_TOKEN>" }
Invoke-RestMethod http://127.0.0.1:8090/ai/health
```

`http://127.0.0.1:8090/docs` показывает контракт отдельного сервиса.

## Тайминг на 7 минут

| Время | Действие | Честная граница |
| --- | --- | --- |
| 0:00–0:40 | Открыть `/docs`, `/ai/health`, показать отдельный сервис и токен | Это не экран существующего frontend |
| 0:40–1:30 | Запустить тест сроков из шага 4: аварийный порог, напоминание, просрочка и отсутствие дубля | Уведомления перехватывает тест; реальный push не демонстрируется |
| 1:30–2:20 | Запустить проверку наряда 1 из шага 1 и открыть отчёт мастера из шага 2 | Никакой автоматической приёмки или изменения статуса |
| 2:20–3:10 | Показать негативные карточки тестом из последнего абзаца | Backend сам не допускает закрытие без обязательного фото; это офлайн-карточки |
| 3:10–4:00 | Показать фотоанализ из шага 5 и `needs_master_review` | Качество ремонта не доказано процедурными изображениями |
| 4:00–5:00 | Показать отчёт смены и рейтинг из шага 3 | Простой и веса рейтинга предварительные |
| 5:00–6:10 | Показать аналитические шесть сигналов из шага 6 | Две дополнительные гипотезы остаются на проверку |
| 6:10–7:00 | Показать ассистента и черновик ввода командами ниже, затем `reports/metrics.md` | Реальный голос и LLM-accuracy не измерялись |

Это демо **отдельного ИИ-слоя**, а не сквозной сценарий «push → принят → закрыт» существующего мобильного приложения. Не называйте тестовый `CaptureNotifier` доставленным push.

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
