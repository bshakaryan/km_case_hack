import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../data/models.dart';
import '../ui.dart' as app_ui;
import 'order_photo.dart';
import 'ai_job_status.dart';

/// Detail-only snapshots supplied by the server; current editing stays separate.
class OrderHistory extends StatelessWidget {
  const OrderHistory({
    super.key,
    required this.order,
    required this.controller,
  });

  final WorkOrder order;
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final assignments = order.assignmentHistory;
    final attempts = order.submissionAttempts;
    if (assignments.isEmpty && attempts.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Material(
        color: Colors.white,
        shape: RoundedRectangleBorder(
          side: const BorderSide(color: Color(0xFFDDE3EB)),
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: ExpansionTile(
          title: const Text(
            'Сдачи и назначения',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(
            'Сдач: ${attempts.length} · назначений: ${assignments.length}',
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            if (assignments.isNotEmpty) ...[
              _heading('История назначений'),
              for (final assignment in assignments) _assignment(assignment),
            ],
            if (attempts.isNotEmpty) ...[
              _heading('Неизменяемые сдачи'),
              for (final attempt in attempts) _attempt(attempt, assignments),
            ],
          ],
        ),
      ),
    );
  }

  Widget _assignment(Json assignment) {
    final legacy = assignment['source'] == 'legacy_snapshot';
    return _card(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Назначение №${assignment['number']} · ${assignment['assignee_name'] ?? 'Исполнитель не зафиксирован'}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (legacy)
            _uncertainty(
              'Снимок прежних данных. Предыдущие назначения и границы периода не восстановлены.',
            ),
          _text(
            '${_date(assignment['assigned_at'])} — ${assignment['ended_at'] != null
                ? _date(assignment['ended_at'])
                : legacy
                ? 'Окончание неизвестно'
                : 'Текущее назначение'}',
          ),
          _text(
            'Назначил: ${assignment['assigned_by_name'] ?? 'Не зафиксировано'}',
          ),
          if (assignment['brigade_name'] != null)
            _text('Бригада: ${assignment['brigade_name']}'),
        ],
      ),
    );
  }

  Widget _attempt(Json attempt, List<Json> assignments) {
    final legacy = attempt['source'] == 'legacy_snapshot';
    final report = _map(attempt['completion']);
    final materials = _rows(attempt['materials']);
    final photos = _rows(attempt['photos']);
    final review = _map(attempt['ai_review']);
    final decisions = _rows(attempt['decisions']);
    final fault = _rows(controller.reference['fault_codes'])
        .where((row) => row['id'] == report['fault_code_id'])
        .firstOrNull;
    final assignment = assignments
        .where((row) => row['id'] == attempt['assignment_id'])
        .firstOrNull;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        border: Border.all(color: const Color(0xFFDDE3EB)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ExpansionTile(
        title: Text(
          'Сдача №${attempt['number']}',
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(
          attempt['submitted_at'] == null
              ? 'Время не зафиксировано'
              : _date(attempt['submitted_at']),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _text('Автор: ${attempt['author_name'] ?? 'Не зафиксирован'}'),
              _text(
                assignment == null
                    ? 'Связь с назначением не установлена'
                    : 'Назначение №${assignment['number']}',
              ),
              if (legacy)
                _uncertainty(
                  'Снимок прежнего отчёта. Фото, расход и решения без подтверждённой связи не отнесены к этой сдаче; расход в прежнем отчёте мог быть общим за несколько сдач.',
                ),
              _text('${report['work_done'] ?? 'Текст отчёта не сохранён.'}'),
              if (report['fault_code_id'] != null)
                _text(
                  'Шифр неисправности: ${fault == null ? '#${report['fault_code_id']} · шифр недоступен' : '${fault['code']} · ${fault['name']}'}',
                ),
              if ('${report['comment'] ?? ''}'.isNotEmpty)
                _text('Комментарий исполнителя: ${report['comment']}'),
              if (legacy && _rows(report['materials']).isNotEmpty) ...[
                _heading('Общий расход из прежнего отчёта'),
                _text('По отдельным сдачам не распределён.'),
                for (final material in _rows(report['materials']))
                  _text(
                    '${material['name'] ?? 'Материал #${material['material_id']}'} · ${material['quantity']} ${material['unit'] ?? ''}',
                  ),
              ],
              _heading('Дополнительный расход этой сдачи'),
              if (materials.isEmpty)
                _text(
                  legacy
                      ? 'Связь расхода с этой сдачей неизвестна.'
                      : 'Материалы не списывались.',
                ),
              for (final material in materials) ...[
                _text(
                  '${material['name']} · ${material['quantity']} ${material['unit']}',
                ),
                _text(
                  '${material['author_name'] ?? 'Автор не зафиксирован'} · ${_date(material['created_at'])}',
                ),
              ],
              _heading('Фото, доступные при сдаче'),
              if (photos.isEmpty) _text('Связанных фотографий нет.'),
              if (photos.isNotEmpty)
                _text(
                  'Набор на момент сдачи; снимки могут повторяться в следующих сдачах.',
                ),
              for (final photo in photos) ...[
                OrderPhoto(controller: controller, photo: photo, height: 145),
                _text(
                  '${photo['kind'] == 'before' ? 'До ремонта' : 'После ремонта'} · ${photo['author_name'] ?? 'Автор не зафиксирован'} · ${_date(photo['created_at'])}',
                ),
              ],
              AiJobStatus(
                job: attempt['ai_job'] is Map ? _map(attempt['ai_job']) : null,
              ),
              if (review.isNotEmpty &&
                  showAttemptAiReview(attempt['ai_job'])) ...[
                _heading(
                  review['is_stub'] == true
                      ? 'Формальная проверка · демо'
                      : 'Проверка ИИ',
                ),
                _text(_verdict('${review['verdict']}')),
                if (review['score'] != null)
                  _text('Предварительная оценка: ${review['score']} / 5'),
                _text('${review['explanation'] ?? 'Объяснение не сохранено.'}'),
                if (review['is_stub'] == true)
                  _text(
                    'Проверяется наличие фото; содержимое снимков не анализируется.',
                  ),
              ],
              _heading('Решения мастера'),
              if (decisions.isEmpty)
                _text('Решение для этой сдачи не зафиксировано.'),
              for (final decision in decisions) ...[
                _text(
                  '${decision['action'] == 'close' ? 'Принято мастером' : 'Возвращено на доработку'}${decision['score'] == null ? '' : ' · ${decision['score']} / 5'}',
                ),
                _text(
                  '${decision['actor_name'] ?? 'Автор не зафиксирован'} · ${_date(decision['created_at'])}',
                ),
                if ('${decision['comment'] ?? ''}'.isNotEmpty)
                  _text('${decision['comment']}'),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _heading(String text) => Padding(
    padding: const EdgeInsets.only(top: 12, bottom: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
  );
  Widget _text(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(text, style: const TextStyle(fontSize: 14, height: 1.4)),
  );
  Widget _card(Widget child) => Container(
    margin: const EdgeInsets.symmetric(vertical: 6),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      border: Border.all(color: const Color(0xFFDDE3EB)),
      borderRadius: BorderRadius.circular(8),
    ),
    child: child,
  );
  Widget _uncertainty(String text) => Container(
    margin: const EdgeInsets.symmetric(vertical: 8),
    padding: const EdgeInsets.all(10),
    color: const Color(0xFFFFF7E7),
    child: Text(
      text,
      style: const TextStyle(fontSize: 13, color: Color(0xFF795817)),
    ),
  );
  static Json _map(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  static List<Json> _rows(Object? value) => value is List
      ? value.whereType<Map>().map((row) => _map(row)).toList()
      : [];
  static String _date(Object? value) {
    final date = DateTime.tryParse('$value');
    return date == null ? 'Не зафиксировано' : app_ui.dateLabel(date);
  }

  static String _verdict(String value) =>
      const {
        'passed': 'Принято',
        'needs_attention': 'Принято с замечаниями',
        'rework': 'Требует доработки',
        'needs_rework': 'Требует доработки',
      }[value] ??
      'Нужна проверка мастером';
}
