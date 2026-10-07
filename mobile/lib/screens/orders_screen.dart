import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../data/models.dart';
import '../ui.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({
    required this.controller,
    required this.onOrder,
    required this.onCreate,
    this.initialFilter,
    this.assigneeId,
    super.key,
  });
  final AppController controller;
  final void Function(int) onOrder;
  final VoidCallback onCreate;
  final String? initialFilter;
  final int? assigneeId;
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  late String filter = widget.initialFilter ?? 'active';
  String query = '';
  int? area;
  int count = 30;
  @override
  Widget build(BuildContext context) {
    final source = widget.controller.orders;
    final orders = source.where((o) {
      final matches = switch (filter) {
        'all' => true,
        'active' => !terminal(o),
        'history' => terminal(o),
        'queue' => {'accepted', 'queued'}.contains(o.status),
        'emergency' => o.priority == 'emergency' && !terminal(o),
        'overdue' => o.isOverdue,
        _ => o.status == filter,
      };
      return matches &&
          (widget.assigneeId == null ||
              o.data['assignee_id'] == widget.assigneeId) &&
          (area == null || o.data['area_id'] == area) &&
          '${o.number} ${o.title} ${o.description} ${o.equipmentName} ${o.assigneeName}'
              .toLowerCase()
              .contains(query.toLowerCase());
    }).toList();
    if (filter == 'queue') {
      int position(WorkOrder order) =>
          (order.data['queue_position'] as num?)?.toInt() ?? 1 << 30;
      orders.sort((a, b) => position(a).compareTo(position(b)));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          decoration: const InputDecoration(
            hintText: 'Номер, оборудование, проблема',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (v) => setState(() {
            query = v;
            count = 30;
          }),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: filter,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Состояние'),
          items: [
            for (final e in {
              'active': 'Активные',
              'queue': 'Очередь к выполнению',
              'all': 'Все наряды',
              'emergency': 'Аварийные',
              'overdue': 'Срок истёк',
              ...statuses,
              'history': 'История',
            }.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
          onChanged: (v) => setState(() {
            filter = v!;
            count = 30;
          }),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<int>(
          initialValue: area ?? 0,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Участок'),
          items: [
            const DropdownMenuItem(value: 0, child: Text('Все участки')),
            for (final a in widget.controller.reference['areas'] as List? ?? [])
              DropdownMenuItem(
                value: a['id'] as int,
                child: Text('${a['name']}', overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() {
            area = v == 0 ? null : v;
            count = 30;
          }),
        ),
        if (widget.controller.user!.isMaster)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: widget.onCreate,
                icon: const Icon(Icons.add),
                label: const Text('Выдать наряд'),
              ),
            ),
          ),
        SectionTitle('Найдено · ${orders.length}'),
        if (widget.assigneeId != null)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: InfoPanel(
              'Показаны наряды выбранного исполнителя. Список включает все доступные даты.',
            ),
          ),
        if (source.length >= 5000)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: InfoPanel(
              'Поиск выполняется среди последних 5000 загруженных нарядов. Полная серверная пагинация — следующий этап.',
            ),
          ),
        if (orders.isEmpty)
          const InfoPanel(
            'По выбранным условиям нарядов нет. Попробуйте другой статус или участок.',
            icon: Icons.search_off,
          ),
        for (final o in orders.take(count))
          OrderCard(order: o, onTap: () => widget.onOrder(o.id)),
        if (orders.length > count)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => setState(() => count += 30),
              child: const Text('Показать ещё'),
            ),
          ),
      ],
    );
  }
}
