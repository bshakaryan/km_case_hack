import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../data/order_journal.dart';
import '../data/order_journal_controller.dart';
import '../ui.dart';
import 'order_detail_screen.dart';

class OrderJournalScreen extends StatefulWidget {
  const OrderJournalScreen({
    required this.controller,
    this.equipmentId,
    this.assigneeId,
    super.key,
  });
  final AppController controller;
  final int? equipmentId, assigneeId;
  @override
  State<OrderJournalScreen> createState() => _OrderJournalScreenState();
}

class _OrderJournalScreenState extends State<OrderJournalScreen> {
  late final OrderJournalController _journal;
  final _search = TextEditingController();
  final _from = TextEditingController();
  final _to = TextEditingController();
  String _scope = 'all',
      _focus = 'all',
      _sort = 'newest',
      _status = 'all',
      _priority = 'all';
  int? _area;
  String? _filterError;

  @override
  void initState() {
    super.initState();
    _journal = OrderJournalController(
      widget.controller,
      equipmentHistory: widget.equipmentId != null,
      query: OrderJournalQuery(
        equipmentId: widget.equipmentId,
        assigneeId: widget.assigneeId,
      ),
    );
    unawaited(_journal.refresh());
  }

  @override
  void dispose() {
    _journal.dispose();
    _search.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  void _apply() {
    String? date(String value) {
      final raw = value.trim();
      if (raw.isEmpty) return null;
      final parsed = DateTime.tryParse(raw);
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw) ||
          parsed == null ||
          parsed.toIso8601String().substring(0, 10) != raw) {
        throw const FormatException('Введите дату в формате ГГГГ-ММ-ДД.');
      }
      return raw;
    }

    try {
      final from = date(_from.text), to = date(_to.text);
      if (from != null && to != null && from.compareTo(to) > 0) {
        throw const FormatException('Начало периода позже окончания.');
      }
      setState(() => _filterError = null);
      unawaited(
        _journal.replaceQuery(
          OrderJournalQuery(
            equipmentId: widget.equipmentId,
            assigneeId: widget.assigneeId,
            areaId: _area,
            search: _search.text,
            scope: _scope,
            focus: _focus,
            sort: _sort,
            priority: _priority == 'all' ? null : _priority,
            status: _status == 'all' ? null : _status,
            fromDate: from,
            toDate: to,
          ),
        ),
      );
    } on FormatException catch (error) {
      setState(() => _filterError = error.message);
    }
  }

  Future<void> _openOrder(int id) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            OrderDetailScreen(controller: widget.controller, orderId: id),
      ),
    );
  }

  Widget _select(
    String label,
    String value,
    Map<String, String> items,
    void Function(String) change,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: items.entries
          .map(
            (entry) =>
                DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) setState(() => change(value));
      },
    ),
  );

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _journal,
    builder: (context, _) {
      final metadata = _journal.equipment;
      final equipmentMode = widget.equipmentId != null;
      return Scaffold(
        appBar: AppBar(
          title: Text(equipmentMode ? 'История оборудования' : 'Полный журнал'),
          actions: [
            IconButton(
              tooltip: 'Обновить журнал',
              onPressed: _journal.allowed ? _journal.refresh : null,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: !_journal.allowed
            ? const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Недостаточно прав для этого журнала.'),
              )
            : RefreshIndicator(
                onRefresh: _journal.refresh,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(16),
                  children: [
                    if (equipmentMode) ...[
                      Text(
                        metadata?.name ?? 'Оборудование #${widget.equipmentId}',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      if (metadata != null)
                        Text(
                          'Инв. № ${metadata.inventoryNumber} · ${metadata.areaName}\n${metadata.type} · критичность: ${metadata.criticality}',
                        ),
                      const SizedBox(height: 12),
                    ],
                    const InfoPanel(
                      'Серверный журнал загружает все доступные наряды страницами. Период по умолчанию не ограничен. Для работы без сети используйте сохранённый список нарядов.',
                      icon: Icons.manage_search,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _search,
                      onSubmitted: (_) => _apply(),
                      maxLength: 200,
                      decoration: const InputDecoration(
                        labelText: 'Поиск по нарядам',
                        hintText: 'Номер, оборудование, описание, участник',
                        prefixIcon: Icon(Icons.search),
                      ),
                    ),
                    ExpansionTile(
                      title: const Text('Фильтры и сортировка'),
                      children: [
                        _select('Состояние журнала', _scope, const {
                          'all': 'Все наряды',
                          'active': 'Активные',
                          'closed': 'Закрытые и отменённые',
                        }, (value) => _scope = value),
                        _select('Требуют внимания', _focus, const {
                          'all': 'Все',
                          'overdue': 'Срок истёк',
                          'emergency': 'Аварийные',
                          'issued': 'Ещё не приняты',
                          'completed': 'Ожидают приёмки',
                          'rejected': 'Отклонены',
                        }, (value) => _focus = value),
                        _select('Порядок', _sort, const {
                          'newest': 'Новые сначала',
                          'deadline': 'По сроку',
                          'priority': 'По приоритету',
                        }, (value) => _sort = value),
                        _select('Точный статус', _status, const {
                          'all': 'Любой статус',
                          ...statuses,
                        }, (value) => _status = value),
                        _select('Приоритет', _priority, const {
                          'all': 'Любой приоритет',
                          ...priorities,
                        }, (value) => _priority = value),
                        if (!widget.controller.user!.isWorker && !equipmentMode)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: DropdownButtonFormField<int>(
                              initialValue: _area ?? 0,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Участок',
                              ),
                              items: [
                                const DropdownMenuItem(
                                  value: 0,
                                  child: Text('Все участки'),
                                ),
                                for (final row
                                    in widget.controller.reference['areas']
                                            as List? ??
                                        [])
                                  DropdownMenuItem(
                                    value: row['id'] as int,
                                    child: Text('${row['name']}'),
                                  ),
                              ],
                              onChanged: (value) => setState(
                                () => _area = value == 0 ? null : value,
                              ),
                            ),
                          ),
                        TextField(
                          controller: _from,
                          decoration: const InputDecoration(
                            labelText: 'Создан с · ГГГГ-ММ-ДД',
                          ),
                          keyboardType: TextInputType.datetime,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _to,
                          decoration: const InputDecoration(
                            labelText: 'Создан по · ГГГГ-ММ-ДД',
                          ),
                          keyboardType: TextInputType.datetime,
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                    if (_filterError != null)
                      Text(
                        _filterError!,
                        style: const TextStyle(color: danger),
                      ),
                    FilledButton.icon(
                      onPressed: _apply,
                      icon: const Icon(Icons.search),
                      label: const Text('Найти'),
                    ),
                    const SizedBox(height: 16),
                    if (_journal.loading) const LinearProgressIndicator(),
                    if (_journal.error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: InfoPanel(
                          _journal.error!,
                          color: danger,
                          action: TextButton(
                            onPressed: _journal.loading
                                ? null
                                : _journal.refresh,
                            child: const Text('Повторить'),
                          ),
                        ),
                      ),
                    SectionTitle(
                      'Загружено: ${_journal.items.length} · найдено: ${_journal.total ?? '—'}',
                    ),
                    if (_journal.total != null)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Количество отражает текущие серверные данные. Новые записи появятся после обновления журнала.',
                          style: TextStyle(fontSize: 13, color: muted),
                        ),
                      ),
                    if (!_journal.loading &&
                        _journal.items.isEmpty &&
                        _journal.error == null)
                      const InfoPanel('По выбранным условиям нарядов нет.'),
                    for (final order in _journal.items)
                      OrderCard(
                        order: order,
                        onTap: () => _openOrder(order.id),
                      ),
                    if (_journal.nextCursor != null)
                      OutlinedButton(
                        onPressed: _journal.loading ? null : _journal.loadMore,
                        child: const Text('Загрузить ещё'),
                      ),
                  ],
                ),
              ),
      );
    },
  );
}
