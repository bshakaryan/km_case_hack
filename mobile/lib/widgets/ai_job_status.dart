import 'package:flutter/material.dart';

import '../data/models.dart';

bool showAttemptAiReview(Object? job) =>
    job is! Map || job['status'] == 'succeeded';

class AiJobStatus extends StatelessWidget {
  const AiJobStatus({
    super.key,
    this.job,
    this.onRetry,
    this.busy = false,
    this.uncertain = false,
    this.offline = false,
  });

  final Json? job;
  final VoidCallback? onRetry;
  final bool busy;
  final bool uncertain;
  final bool offline;

  @override
  Widget build(BuildContext context) {
    final status = job?['status'];
    if (job == null || status == 'succeeded') return const SizedBox.shrink();
    final title = switch (status) {
      'pending' => 'Проверка в очереди',
      'running' => 'Проверка выполняется',
      'failed' => 'Проверка не завершена',
      'superseded' => 'Проверка прежней сдачи остановлена',
      _ => 'Состояние проверки неизвестно',
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 16, top: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFF0F5FA),
        border: Border.all(color: const Color(0xFFDDE3EB)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            status == 'failed'
                ? 'Отчёт сохранён на сервере. Нужна проверка мастера; результат проверки пока недоступен.'
                : status == 'superseded'
                ? 'Эта проверка больше не меняет текущий наряд. Смотрите более новую сдачу.'
                : 'Отчёт сохранён на сервере. Результат появится после завершения проверки.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Формальная проверка · демо. Содержимое снимков не анализируется. Окончательное решение принимает мастер.',
            style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
          ),
          if (uncertain)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Результат повтора неизвестен. Обновите карточку перед повторной отправкой.',
              ),
            ),
          if (onRetry != null) ...[
            if (offline)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Для повтора проверки подключитесь к серверу.'),
              ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: busy || uncertain || offline ? null : onRetry,
              child: Text(busy ? 'Отправляется…' : 'Повторить проверку'),
            ),
          ],
        ],
      ),
    );
  }
}
