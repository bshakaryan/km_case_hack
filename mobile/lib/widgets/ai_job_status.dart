import 'package:flutter/material.dart';

import '../data/models.dart';

bool showAttemptAiReview(Object? job) =>
    job is! Map || job['status'] == 'succeeded';

bool _serviceReview(Json review, Object? job) =>
    (job is Map && job['provider'] == 'ai_service') ||
    review.containsKey('source_verdict') ||
    review['llm_used'] is bool;

String aiReviewTitle(Json review, {Object? job}) => _serviceReview(review, job)
    ? 'Сервис проверки'
    : review['is_stub'] == true
    ? 'Формальная проверка · демо'
    : 'Проверка ИИ';

String aiReviewScoreLabel(Object? value) {
  if (value is! num || !value.isFinite || value < 1 || value > 5) {
    return 'Оценка не определена';
  }
  final number = value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);
  return 'Предварительная оценка: $number / 5';
}

String aiReviewVerdict(Json review) => switch (review['source_verdict']) {
  'accepted' => 'Рекомендовано принять',
  'accepted_with_remarks' => 'Рекомендовано принять с замечаниями',
  'needs_rework' => 'Рекомендована доработка',
  'needs_master_review' => 'Нужна проверка мастером',
  _ => switch (review['verdict']) {
    'passed' => 'Принято',
    'needs_attention' => 'Принято с замечаниями',
    'rework' || 'needs_rework' => 'Требует доработки',
    _ => 'Нужна проверка мастером',
  },
};

String? aiReviewSource(Json review) {
  final photoCheck = review['photo_check'];
  final photos = photoCheck is Map && photoCheck['status'] == 'checked';
  if (review['llm_used'] == true) {
    return photos
        ? 'Источник: текстовая модель, правила и локальная проверка фото'
        : 'Источник: текстовая модель и правила';
  }
  if (review['llm_used'] == false) {
    return photos
        ? 'Источник: текст отчёта, правила и локальная проверка фото; языковая модель не использовалась'
        : 'Источник: текст отчёта и правила; языковая модель не использовалась';
  }
  return null;
}

String aiReviewNote(Json review, {Object? job}) {
  final photoCheck = review['photo_check'];
  if (photoCheck is Map) {
    switch (photoCheck['status']) {
      case 'checked':
        return 'Локальная проверка фото даёт технические признаки, а не подтверждение ремонта. Окончательное решение принимает мастер.';
      case 'unavailable':
        return 'Проверка содержимого фото не завершена. Окончательное решение принимает мастер.';
      case 'no_after':
        return 'Фото после выполнения отсутствует в этой сдаче. Окончательное решение принимает мастер.';
    }
  }
  if (_serviceReview(review, job)) {
    return 'Проверяются текст отчёта и правила. Содержимое снимков не анализируется. Окончательное решение принимает мастер.';
  }
  return review['is_stub'] == true
      ? 'Проверяется наличие фото; содержимое снимков не анализируется. Окончательное решение принимает мастер.'
      : 'Окончательное решение принимает мастер.';
}

List<String> aiPhotoCheckLines(Object? check) {
  if (check is! Map ||
      !['checked', 'unavailable', 'no_after'].contains(check['status'])) {
    return [];
  }
  final status = check['status'];
  final lines = [
    status == 'checked'
        ? 'Локальная проверка изображений выполнена.'
        : status == 'no_after'
        ? 'В сохранённых фото этой сдачи нет фото после выполнения.'
        : 'Локальная проверка изображений недоступна; вывод по содержимому не получен.',
  ];
  final before = check['before_id'];
  final after = check['after_id'];
  final beforeId = before is int && before > 0 ? before : null;
  final afterId = after is int && after > 0 ? after : null;
  if (beforeId != null || afterId != null) {
    lines.add(
      'Для сравнения выбраны фото этой сдачи: до ${beforeId == null ? 'не выбрано' : '№$beforeId'}; после ${afterId == null ? 'не выбрано' : '№$afterId'}.',
    );
  }
  if (status == 'checked') {
    if (check['duplicate_before'] == true) {
      lines.add(
        'В выбранной паре есть признаки повтора фото до ремонта; сверьте снимки вручную.',
      );
    } else if (check['duplicate_before'] == false) {
      lines.add('В выбранной паре признаков повтора не найдено.');
    } else {
      lines.add('Признаки повтора относительно фото до не определены.');
    }
    lines.add(
      check['equipment_status'] == 'different'
          ? 'Возможно, на выбранных снимках разное оборудование; проверьте вручную.'
          : 'Совпадение оборудования не подтверждено.',
    );
    if (check['model_available'] == false) {
      lines.add('Модель сравнения оборудования недоступна.');
    }
  }
  final groups = check['exact_duplicate_groups'];
  final duplicates = groups is List
      ? groups.whereType<List>().where((group) => group.length > 1).length
      : 0;
  if (duplicates > 0) {
    lines.add(
      'В сохранённых фото этой сдачи есть группы полностью одинаковых файлов: $duplicates.',
    );
  } else if (status == 'checked') {
    lines.add('Полностью одинаковые файлы среди фото этой сдачи не найдены.');
  }
  lines.add(
    'Качество ремонта и время съёмки не подтверждены. Фото других нарядов и сдач не проверялись.',
  );
  return lines;
}

class AiPhotoCheck extends StatelessWidget {
  const AiPhotoCheck({super.key, this.check});

  final Object? check;

  @override
  Widget build(BuildContext context) {
    final lines = aiPhotoCheckLines(check);
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Результат проверки фото',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          for (final line in lines)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text(line)),
        ],
      ),
    );
  }
}

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
          Text(
            job?['provider'] == 'ai_service'
                ? 'Сервис проверки · рекомендация. Окончательное решение принимает мастер.'
                : 'Формальная проверка · демо. Содержимое снимков не анализируется. Окончательное решение принимает мастер.',
            style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
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
