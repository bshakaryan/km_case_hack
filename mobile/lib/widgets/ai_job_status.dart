import 'package:flutter/material.dart';

import '../data/models.dart';

bool showAttemptAiReview(Object? job) =>
    job is! Map || job['status'] == 'succeeded';

bool _serviceReview(Json review, Object? job) =>
    (job is Map && job['provider'] == 'ai_service') ||
    review.containsKey('source_verdict') ||
    review['llm_used'] is bool;

String aiReviewTitle(Json review, {Object? job}) =>
    (review['photo_check'] is Map &&
            (review['photo_check'] as Map)['method'] == 'openai_vision')
    ? 'Проверка OpenAI'
    : (review['photo_check'] is Map &&
            (review['photo_check'] as Map)['method'] == 'local_cv')
    ? 'Историческая локальная проверка фото'
    : _serviceReview(review, job)
    ? 'Проверка сдачи'
    : review['is_stub'] == true
    ? 'Историческая формальная проверка'
    : 'Проверка ИИ';

String aiReviewScoreLabel(Object? value, {Json? review}) {
  if (review?['photo_check'] is Map &&
      (review!['photo_check'] as Map)['method'] == 'openai_vision' &&
      review['source_verdict'] == 'needs_master_review') {
    return 'Автоматический балл не выставляется';
  }
  if (value is! num || !value.isFinite || value < 1 || value > 5) {
    return 'Оценка не определена';
  }
  final number = value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(1);
  return review?['is_stub'] == true && !_serviceReview(review!, null)
      ? 'Сохранённая оценка старой проверки: $number / 5'
      : 'Предварительная оценка: $number / 5';
}

String aiReviewVerdict(Json review) {
  switch (review['source_verdict']) {
    case 'accepted':
      return 'Рекомендовано принять';
    case 'accepted_with_remarks':
      return 'Рекомендовано принять с замечаниями';
    case 'needs_rework':
      return 'Рекомендована доработка';
    case 'needs_master_review':
      return 'Нужна проверка мастером';
  }
  if (review['is_stub'] == true) {
    return switch (review['verdict']) {
      'passed' => 'Старая рекомендация: принять',
      'needs_attention' => 'Старая рекомендация: проверить мастеру',
      'rework' || 'needs_rework' => 'Старая рекомендация: доработка',
      _ => 'Старый результат формальной проверки',
    };
  }
  return switch (review['verdict']) {
    'passed' => 'Принято',
    'needs_attention' => 'Принято с замечаниями',
    'rework' || 'needs_rework' => 'Требует доработки',
    _ => 'Нужна проверка мастером',
  };
}

String aiReviewExplanation(Json review, {Object? job}) =>
    review['photo_check'] is Map &&
            (review['photo_check'] as Map)['method'] == 'openai_vision'
    ? 'Ниже отдельно показаны формальные проверки отчёта и визуальные признаки выбранных фото.'
    : review['is_stub'] == true && !_serviceReview(review, job)
    ? 'Сохранённый результат прежнего формального режима: проверялись поля отчёта и наличие фотографий, содержимое изображений не анализировалось. Локальный модуль для этой сдачи не запускался; запись не пересчитывалась.'
    : (review['explanation'] ?? 'Объяснение отсутствует. Требуется проверка мастера.').toString();

String? aiReviewSource(Json review) {
  final photoCheck = review['photo_check'];
  final photos = photoCheck is Map && photoCheck['status'] == 'checked';
  if (photos && photoCheck['method'] == 'openai_vision') {
    return 'Фото: OpenAI Vision · отчёт: формальные правила сервера';
  }
  if (photoCheck is Map && photoCheck['method'] == 'local_cv') {
    return 'Источник: сохранённый результат прежней локальной CV-проверки; повторно не запускалась';
  }
  if (review['llm_used'] == true) {
    return photos
        ? 'Источник: текстовая модель и правила'
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
        return photoCheck['method'] == 'openai_vision'
            ? 'Результат по фото — только рекомендация; итоговую оценку и приёмку выполняет мастер.'
            : 'Это сохранённый результат прежней локальной проверки фото; модуль больше не используется для новых сдач. Окончательное решение принимает мастер.';
      case 'unavailable':
        return 'Проверка содержимого фото не завершена. Окончательное решение принимает мастер.';
      case 'no_after':
        return 'Фото после выполнения отсутствует в этой сдаче. Окончательное решение принимает мастер.';
    }
  }
  if (_serviceReview(review, job)) {
    return 'Проверяются текст отчёта и правила. Содержимое снимков не анализируется. Окончательное решение принимает мастер.';
  }
  if (review['is_stub'] == true) {
    return 'Это исторический результат прежней проверки; содержимое снимков не анализируется и запись не пересчитывалась. Окончательное решение принимает мастер.';
  }
  return 'Окончательное решение принимает мастер.';
}

List<String> aiPhotoCheckLines(Object? check) {
  if (check is! Map ||
      !['checked', 'unavailable', 'no_after'].contains(check['status'])) {
    return [];
  }
  final status = check['status'];
  final openAi = check['method'] == 'openai_vision';
  final lines = [
    status == 'checked'
        ? openAi
            ? 'Выбранные фото проанализированы OpenAI Vision.'
            : 'Историческая локальная CV-проверка выполнена.'
        : status == 'no_after'
        ? 'В сохранённых фото этой сдачи нет фото после выполнения.'
        : check['method'] == 'local_cv'
        ? 'Старая локальная проверка изображений была недоступна; запись не пересчитывалась.'
        : 'Проверка изображений недоступна; вывод по содержимому не получен.',
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
    final vision = check['vision'];
    if (openAi && vision is Map) {
      lines.add(
        'Оборудование: ${_equipmentStatus(vision['same_equipment'])}.',
      );
      lines.add(
        'Видимый дефект: ${_defectStatus(vision['defect_resolved'])}.',
      );
      lines.add('Общее впечатление по фото: ${_qualityStatus(vision['quality'])}.');
      for (final row in aiPhotoCriterionRows(vision['visual_criteria'])) {
        lines.add('${row['label']}: ${row['value']}${row['observation']!.isNotEmpty ? ' — ${row['observation']}' : ''}.');
      }
      if (vision['explanation'] is String && (vision['explanation'] as String).isNotEmpty) {
        lines.add(vision['explanation'] as String);
      }
      final issues = vision['issues'];
      if (issues is List) {
        for (final issue in issues.whereType<String>()) {
          lines.add('Замечание: $issue');
        }
      }
    } else if (!openAi) {
      if (check['duplicate_before'] == true) {
        lines.add('В выбранной паре есть признаки повтора фото до ремонта; сверьте снимки вручную.');
      } else if (check['duplicate_before'] == false) {
        lines.add('В выбранной паре признаков повтора не найдено.');
      } else {
        lines.add('Признаки повтора относительно фото до не определены.');
      }
      lines.add(check['equipment_status'] == 'different'
          ? 'Возможно, на выбранных снимках разное оборудование; проверьте вручную.'
          : 'Совпадение оборудования не подтверждено.');
      if (check['model_available'] == false) lines.add('Модель сравнения оборудования недоступна.');
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
  } else if (status == 'checked' && !openAi) {
    lines.add('Полностью одинаковые файлы среди фото этой сдачи не найдены.');
  }
  lines.add(openAi && status == 'checked'
      ? 'Проверены только видимые признаки выбранной пары. Факт и скрытое качество ремонта, время съёмки и фото других нарядов не проверялись.'
      : check['method'] == 'local_cv'
      ? 'Это сохранённый результат прежнего локального модуля; он не подтверждает факт и качество ремонта или время съёмки. Запись не пересчитывалась.'
      : 'Фото других нарядов и сдач не проверялись. Окончательное решение принимает мастер.');
  return lines;
}

String _equipmentStatus(Object? value) => value == true
    ? 'визуально похоже'
    : value == false
    ? 'визуально различается'
    : 'не удалось сопоставить';

String _defectStatus(Object? value) => value == true
    ? 'прежний дефект не виден после'
    : value == false
    ? 'признаки дефекта остаются'
    : 'по снимкам не определить';

String _qualityStatus(Object? value) => switch (value) {
  'excellent' => 'без видимых замечаний',
  'good' => 'в целом приемлемо по видимым признакам',
  'mixed' => 'есть положительные признаки и замечания',
  'poor' => 'заметны существенные недостатки',
  'critical' => 'заметны выраженные недостатки',
  _ => 'недостаточно данных',
};

List<Json> aiPhotoCriterionRows(Object? criteria) {
  if (criteria is! Map) return <Json>[];
  const labels = {
    'cleanliness': 'Чистота и мусор',
    'fasteners': 'Крепления и опоры',
    'guards': 'Кожухи и ограждения',
    'leakage': 'Видимые следы жидкости',
  };
  const statuses = {
    'no_visible_issue': 'явного замечания не видно',
    'issue_visible': 'есть видимое замечание',
    'not_assessable': 'не видно или ракурс недостаточен',
  };
  return [
    for (final entry in labels.entries)
      if (criteria[entry.key] is Map)
        {
          'label': entry.value,
          'value': statuses[(criteria[entry.key] as Map)['status']] ?? 'не оценено',
          'observation': (criteria[entry.key] as Map)['observation'] is String
              ? (criteria[entry.key] as Map)['observation'] as String
              : '',
        },
  ];
}

List<Json> aiReportCheckRows(Object? checks) {
  if (checks is! Map) return <Json>[];
  String field(Object? value) => value == 'present' ? 'Заполнено' : 'Отсутствует';
  String match(Object? value) => value == 'match'
      ? 'Есть словарное совпадение'
      : value == 'mismatch'
      ? 'Не совпало по словарному правилу'
      : 'Не определено';
  final materials = switch (checks['materials_vs_norm']) {
    'within_norm' => 'В пределах доступных норм',
    'issue' => 'Нужна сверка с нормой',
    'missing' => 'Расход не указан при наличии нормы',
    _ => 'Не оценено: нормы не доступны этой проверке',
  };
  final timing = switch (checks['time_vs_norm']) {
    'within_norm' => 'В пределах норматива',
    'over_norm' => 'Выше норматива',
    _ => 'Не оценено: время/норматив не подтверждены',
  };
  final deadline = switch (checks['deadline']) {
    'on_time' => 'Срок соблюдён',
    'late' => 'Сдано после срока',
    _ => 'Срок не определён',
  };
  return [
    {'label': 'Описание выполненных работ', 'value': field(checks['work_description'])},
    {'label': 'Код неисправности', 'value': field(checks['fault_code'])},
    {'label': 'Код ↔ описание неисправности', 'value': match(checks['fault_code_vs_problem']), 'detail': 'Эвристика по словам, не семантический вывод модели.'},
    {'label': 'Работы ↔ код неисправности', 'value': match(checks['work_vs_fault_code']), 'detail': 'Эвристика по отчёту, не подтверждение факта ремонта.'},
    {'label': 'Материалы ↔ нормы', 'value': materials},
    {'label': 'Время ↔ норматив', 'value': timing},
    {'label': 'Срок сдачи', 'value': deadline},
    {'label': 'Фото после', 'value': checks['after_photo'] == 'present' ? 'Есть' : 'Нет', 'detail': checks['after_photo_required'] == true ? 'Обязательно для внеплановой работы.' : 'Для этого типа работы фото после не обязательно.'},
  ];
}

class AiReportChecks extends StatelessWidget {
  const AiReportChecks({super.key, this.checks, this.isOpenAi = false});

  final Object? checks;
  final bool isOpenAi;

  @override
  Widget build(BuildContext context) {
    final rows = aiReportCheckRows(checks);
    if (rows.isEmpty && !isOpenAi) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        const Text('Отчёт и формальные критерии', style: TextStyle(fontWeight: FontWeight.w700)),
        if (rows.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Детальная сводка не сохранена в этой старой проверке; результат не пересчитывался.'),
          )
        else ...[
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text('Текст отчёта не отправлялся в OpenAI. Словарные совпадения — только эвристики.'),
          ),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 4, child: Text(row['label'] as String, style: const TextStyle(fontWeight: FontWeight.w600))),
                  Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(row['value'] as String),
                    if (row['detail'] is String) Text(row['detail'] as String, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                  ])),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class AiPhotoCheck extends StatelessWidget {
  const AiPhotoCheck({super.key, this.check});

  final Object? check;

  @override
  Widget build(BuildContext context) {
    final photoCheck = check;
    if (photoCheck is Map &&
        photoCheck['status'] == 'checked' &&
        photoCheck['method'] == 'openai_vision' &&
        photoCheck['vision'] is Map) {
      final vision = photoCheck['vision'] as Map;
      final criteria = aiPhotoCriterionRows(vision['visual_criteria']);
      final before = photoCheck['before_id'] is int ? '№${photoCheck['before_id']}' : 'не выбрано';
      final after = photoCheck['after_id'] is int ? '№${photoCheck['after_id']}' : 'не выбрано';
      final rows = <Json>[
        {'label': 'Оборудование', 'value': _equipmentStatus(vision['same_equipment'])},
        {'label': 'Видимый дефект', 'value': _defectStatus(vision['defect_resolved'])},
        {'label': 'Общее впечатление по фото', 'value': _qualityStatus(vision['quality'])},
        ...criteria,
      ];
      if (criteria.isEmpty) {
        rows.add({
          'label': 'Чистота, крепления, кожухи и потёки',
          'value': 'Отдельный чек-лист отсутствует в сохранённой версии результата',
        });
      }
      final issues = vision['issues'] is List
          ? (vision['issues'] as List).whereType<String>().toList()
          : <String>[];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Визуальная проверка OpenAI', style: TextStyle(fontWeight: FontWeight.w700)),
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Пара этой сдачи: до $before · после $after'),
            ),
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 4, child: Text(row['label'] as String, style: const TextStyle(fontWeight: FontWeight.w600))),
                    Expanded(flex: 5, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(row['value'] as String),
                      if (row['observation'] is String && (row['observation'] as String).isNotEmpty)
                        Text(row['observation'] as String, style: const TextStyle(fontSize: 12, color: Color(0xFF64748B))),
                    ])),
                  ],
                ),
              ),
            if (vision['explanation'] is String && (vision['explanation'] as String).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Краткое пояснение: ${vision['explanation']}'),
              ),
            if (issues.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('Дополнительные замечания', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
              for (final issue in issues) Padding(padding: const EdgeInsets.only(top: 4), child: Text('• $issue')),
            ],
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Только видимые признаки выбранных фото. Время съёмки, скрытое состояние и фото других нарядов не проверялись.',
                style: TextStyle(fontSize: 12, color: Color(0xFF64748B)),
              ),
            ),
          ],
        ),
      );
    }
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
                ? 'Проверка сдачи с OpenAI Vision · рекомендация. Окончательное решение принимает мастер.'
                : 'Старая формальная проверка · демо. Содержимое снимков не анализируется. Окончательное решение принимает мастер.',
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
