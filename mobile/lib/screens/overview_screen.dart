import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../data/models.dart';
import '../ui.dart';

class OverviewScreen extends StatelessWidget {
  const OverviewScreen({
    required this.controller,
    required this.onOrder,
    required this.onCreate,
    required this.onFilter,
    super.key,
  });
  final AppController controller;
  final void Function(int) onOrder;
  final void Function({int? assigneeId}) onCreate;
  final void Function(String?) onFilter;
  @override
  Widget build(BuildContext context) {
    final c = controller;
    final active = c.orders.where((o) => !terminal(o)).toList();
    final urgent = active.where((o) => o.priority == 'emergency').toList();
    final review = active.where((o) => o.status == 'ai_review').toList();
    final overdue = active.where((o) => o.isOverdue).toList();
    final master = c.user!.isMaster;
    if (c.user!.isWorker) {
      final working = active
          .where((o) => {'in_progress', 'paused'}.contains(o.status))
          .toList();
      final incoming =
          active.where((o) => {'issued', 'rework'}.contains(o.status)).toList()
            ..sort(
              (a, b) => (a.priority == 'emergency' ? 0 : 1).compareTo(
                b.priority == 'emergency' ? 0 : 1,
              ),
            );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (urgent.any((o) => o.status == 'issued'))
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: InfoPanel(
                'Поступил аварийный наряд. Откройте задание и ответьте на назначение.',
                icon: Icons.priority_high,
                color: danger,
              ),
            ),
          if (working.isNotEmpty) ...[
            Text(
              'Текущее задание',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            for (final o in working)
              OrderCard(
                order: o,
                onTap: () => onOrder(o.id),
                nextAction: o.status == 'paused'
                    ? 'Продолжить работу'
                    : 'Открыть и выполнить',
              ),
          ] else
            const InfoPanel(
              'Сейчас нет работы в исполнении. Примите поступивший наряд или откройте очередь.',
              icon: Icons.assignment_outlined,
            ),
          SectionTitle('Ожидают вашего ответа · ${incoming.length}'),
          if (incoming.isEmpty)
            const InfoPanel(
              'Все поступившие задания обработаны.',
              icon: Icons.check_circle_outline,
            ),
          for (final o in incoming.take(4))
            OrderCard(
              order: o,
              onTap: () => onOrder(o.id),
              nextAction: o.status == 'issued'
                  ? 'Посмотреть назначение'
                  : 'Перейти к заданию',
            ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => onFilter('queue'),
              icon: const Icon(Icons.format_list_numbered),
              label: Text(
                'Моя очередь к началу · ${active.where((o) => {'accepted', 'queued'}.contains(o.status)).length}',
              ),
            ),
          ),
          SectionTitle('На проверке · ${review.length}'),
          for (final o in review.take(3))
            OrderCard(order: o, onTap: () => onOrder(o.id)),
          if (review.isEmpty)
            const Text(
              'Сданных работ, ожидающих приёмки, пока нет.',
              style: TextStyle(color: muted),
            ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (master)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () => onCreate(),
              icon: const Icon(Icons.add),
              label: const Text('Выдать наряд'),
            ),
          ),
        const SectionTitle('Требуют внимания'),
        _AttentionTile(
          title: 'Аварийные наряды',
          subtitle: 'Приоритетное реагирование',
          count: urgent.length,
          color: danger,
          icon: Icons.warning_amber_rounded,
          onTap: () => onFilter('emergency'),
        ),
        _AttentionTile(
          title: 'Нарушен срок',
          subtitle: 'Проверить причину и ход работ',
          count: overdue.length,
          color: danger,
          icon: Icons.schedule,
          onTap: () => onFilter('overdue'),
        ),
        _AttentionTile(
          title: 'Ожидают приёмки',
          subtitle: 'Отчёты готовы к решению мастера',
          count: review.length,
          color: navy,
          icon: Icons.fact_check_outlined,
          onTap: () => onFilter('ai_review'),
        ),
        _AttentionTile(
          title: 'Ещё не приняты',
          subtitle: 'Нужен ответ исполнителя',
          count: active.where((o) => o.status == 'issued').length,
          color: const Color(0xff8a5100),
          icon: Icons.pending_actions,
          onTap: () => onFilter('issued'),
        ),
        const SectionTitle('За текущую смену'),
        Row(
          children: [
            Expanded(
              child: Metric(
                label: 'Выдано',
                value: '${c.dashboard['issued'] ?? '—'}',
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Metric(
                label: 'Исполнено',
                value: '${c.dashboard['completed'] ?? '—'}',
              ),
            ),
          ],
        ),
        const SectionTitle('Ближайшие действия'),
        if (urgent.isEmpty && review.isEmpty && overdue.isEmpty)
          const InfoPanel(
            'Срочных действий нет. Все наряды доступны в списке.',
            icon: Icons.check_circle_outline,
          ),
        for (final o in _distinct([...urgent, ...overdue, ...review]).take(3))
          OrderCard(order: o, onTap: () => onOrder(o.id)),
        const SectionTitle('Исполнители на смене'),
        if (c.employees.isEmpty)
          const InfoPanel('Список исполнителей ещё не загружен.'),
        for (final e
            in [...c.employees]..sort(
              (a, b) => (a['status'] == 'free' ? 0 : 1).compareTo(
                b['status'] == 'free' ? 0 : 1,
              ),
            ))
          _EmployeeTile(
            employee: e,
            onAssign: master && e['on_shift'] == true
                ? () => onCreate(assigneeId: e['id'] as int)
                : null,
          ),
      ],
    );
  }

  List<WorkOrder> _distinct(List<WorkOrder> orders) {
    final seen = <int>{};
    return orders.where((o) => seen.add(o.id)).toList();
  }
}

class Metric extends StatelessWidget {
  const Metric({required this.label, required this.value, super.key});
  final String label, value;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w700,
              color: navy,
            ),
          ),
          const SizedBox(height: 5),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    ),
  );
}

class _AttentionTile extends StatelessWidget {
  const _AttentionTile({
    required this.title,
    required this.subtitle,
    required this.count,
    required this.color,
    required this.icon,
    required this.onTap,
  });
  final String title, subtitle;
  final int count;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Card(
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: Icon(icon, color: count == 0 ? muted : color),
        title: Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        subtitle: Text(subtitle, style: const TextStyle(fontSize: 13)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '$count',
              style: TextStyle(
                fontSize: 23,
                fontWeight: FontWeight.w700,
                color: count == 0 ? muted : color,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, size: 20),
          ],
        ),
      ),
    ),
  );
}

class _EmployeeTile extends StatelessWidget {
  const _EmployeeTile({required this.employee, this.onAssign});
  final Json employee;
  final VoidCallback? onAssign;
  @override
  Widget build(BuildContext context) {
    final e = employee;
    final (label, color) = switch (e['status']) {
      'free' => ('Свободен', const Color(0xff267044)),
      'busy' => ('В работе', const Color(0xff8a5100)),
      'queued' => ('Есть очередь', navy),
      _ => ('Вне смены', muted),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${e['name']}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Tag(label, color: color),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${e['specialty']} · ${e['grade']} разряд',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                e['current_order'] != null
                    ? 'В работе ${e['current_order']}\nОжидают начала: ${e['queue_count']}'
                    : 'Ожидают начала: ${e['queue_count']}',
                style: const TextStyle(fontSize: 14, color: muted),
              ),
              if (onAssign != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onAssign,
                    icon: const Icon(Icons.add, size: 19),
                    label: const Text('Выдать задание'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
