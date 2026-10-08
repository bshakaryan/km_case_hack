import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../ui.dart';
import 'overview_screen.dart';

class ReportsScreen extends StatelessWidget {
  const ReportsScreen({
    required this.controller,
    required this.onOrders,
    super.key,
  });
  final AppController controller;
  final void Function(int?) onOrders;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final a = c.analytics;
    final summary = a['summary'] as Map? ?? {};
    final ranking = (a['rankings'] as List? ?? [])
        .where((r) => !c.user!.isWorker || r['id'] == c.user!.id)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Tag('Последние 90 дней'),
        const SizedBox(height: 16),
        if (a.isEmpty)
          const InfoPanel(
            'Отчёт ещё не загружен. Потяните экран вниз для обновления.',
          ),
        Row(
          children: [
            Expanded(
              child: Metric(
                label: 'Нарядов за период',
                value: numeric(summary['total']),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Metric(
                label: 'Закрыто мастером',
                value: numeric(summary['closed']),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Metric(
                label: 'В срок, %',
                value: numeric(summary['on_time_percent'], digits: 1),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Metric(
                label: 'Средняя оценка / 5',
                value: numeric(summary['avg_score'], digits: 1),
              ),
            ),
          ],
        ),
        const SectionTitle('Текущая смена'),
        Text(
          '${c.dashboard['shift_label'] ?? '—'} · Asia/Almaty',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Metric(
                label: 'Выдано за смену',
                value: numeric(c.dashboard['issued']),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Metric(
                label: 'Исполнено за смену',
                value: numeric(c.dashboard['completed']),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () => onOrders(null),
            icon: const Icon(Icons.assignment_outlined),
            label: const Text('Перейти к нарядам'),
          ),
        ),
        SectionTitle(
          c.user!.isWorker ? 'Мои показатели' : 'Рейтинг исполнителей',
        ),
        const InfoPanel(
          'Текущая формула: качество — 60%, сроки — 30%, доля работ без доработки — 10%. Сложность и причины отказов ещё не учтены.',
          icon: Icons.calculate_outlined,
        ),
        const SizedBox(height: 12),
        if (ranking.isEmpty)
          const Text('Недостаточно закрытых нарядов для рейтинга.'),
        for (final r in ranking)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Card(
              child: InkWell(
                onTap: () => onOrders(r['id'] as int),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${r['name']}',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${numeric(r['score'], digits: 1)} / 100',
                            style: const TextStyle(
                              color: navy,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${r['specialty']} · ${r['brigade']}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Divider(height: 24),
                      Wrap(
                        spacing: 16,
                        runSpacing: 8,
                        children: [
                          Text(
                            'Качество ${numeric(r['quality'], digits: 1)}/5',
                          ),
                          Text('В срок ${numeric(r['on_time'], digits: 1)}%'),
                          Text('Закрыто ${numeric(r['closed_count'])}'),
                          Text(
                            'Доработки ${numeric(r['rework_rate'], digits: 1)}%',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Посмотреть наряды →',
                        style: TextStyle(
                          color: navy,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SectionTitle('Границы текущего отчёта'),
        const InfoPanel(
          '90 дней отбираются сервером по дате создания наряда. Переходящие работы и фактические интервалы простоя ещё требуют исправления. Показатели нельзя считать производственной отчётностью.',
        ),
        const SizedBox(height: 12),
        const InfoPanel(
          'Сигналы строятся по агрегатам выбранных данных. Проверяйте исходные наряды.',
          icon: Icons.science_outlined,
        ),
      ],
    );
  }
}
