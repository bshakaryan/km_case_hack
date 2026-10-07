import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../data/local_store.dart';
import '../data/models.dart';
import '../ui.dart';
import 'create_order_screen.dart';
import 'order_detail_screen.dart';
import 'overview_screen.dart';
import 'orders_screen.dart';
import 'reports_screen.dart';

class WorkspaceScreen extends StatefulWidget {
  const WorkspaceScreen({required this.controller, super.key});
  final AppController controller;
  @override
  State<WorkspaceScreen> createState() => _WorkspaceScreenState();
}

class _WorkspaceScreenState extends State<WorkspaceScreen>
    with WidgetsBindingObserver {
  int page = 0;
  String? orderFilter;
  int? assigneeFilter;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(silent: true);
    if (state == AppLifecycleState.paused) {
      unawaited(widget.controller.flushSnapshot());
    }
  }

  Future<void> _refresh({bool silent = false}) async {
    try {
      await widget.controller.refresh(silent: silent);
    } catch (_) {
      /* Error is displayed from controller state. */
    }
  }

  Future<void> openOrder(int id) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            OrderDetailScreen(controller: widget.controller, orderId: id),
      ),
    );
    if (mounted) _refresh(silent: true);
  }

  Future<void> createOrder({int? assigneeId}) async {
    final order = await Navigator.of(context).push<WorkOrder>(
      MaterialPageRoute(
        builder: (_) => CreateOrderScreen(
          controller: widget.controller,
          assigneeId: assigneeId,
        ),
      ),
    );
    if (mounted && order != null) openOrder(order.id);
  }

  String commandLabel(OutboxCommand command) => switch (command.kind) {
    OutboxKind.createOrder => 'Создание наряда',
    OutboxKind.transition => 'Переход по наряду',
    OutboxKind.complete => 'Сдача отчёта',
    OutboxKind.uploadPhoto => 'Загрузка фото',
    OutboxKind.markRead => 'Отметка о прочтении',
    _ => command.kind,
  };

  Future<void> showSyncQueue() async {
    await showDialog<void>(
      context: context,
      builder: (context) => SyncQueueDialog(
        controller: widget.controller,
        commandLabel: commandLabel,
      ),
    );
    if (mounted) _refresh(silent: true);
  }

  void showOrders(String? filter, {int? assignee}) => setState(() {
    page = 1;
    orderFilter = filter;
    assigneeFilter = assignee;
  });
  Future<void> logout() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Выйти из аккаунта?'),
        content: const Text('Для продолжения потребуется логин и ПИН.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Остаться'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Выйти'),
          ),
        ],
      ),
    );
    if (yes == true) await widget.controller.logout();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final master = c.user!.isMaster;
    final titles = [
      master
          ? 'Рабочая смена'
          : c.user!.isWorker
          ? 'Моя работа'
          : 'Обзор смены',
      'Наряды',
      'Уведомления',
      'Отчёты',
    ];
    final unread = c.notifications
        .where((n) => n['is_read'] != true && n['read'] != true)
        .length;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Icon(Icons.assignment_turned_in_outlined, color: navy),
            const SizedBox(width: 10),
            const Flexible(
              child: Text(
                'НарядAI',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(width: 10),
            const Tag('ДЕМО'),
          ],
        ),
        actions: [
          IconButton(
            onPressed: c.loading ? null : () => _refresh(),
            tooltip: 'Обновить данные',
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            onPressed: logout,
            tooltip: 'Выйти',
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (c.loading) const LinearProgressIndicator(minHeight: 2),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              decoration: const BoxDecoration(
                color: Colors.white,
                border: Border(bottom: BorderSide(color: line)),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: Row(
                    children: [
                      Icon(
                        c.error == null
                            ? Icons.check_circle_outline
                            : Icons.cloud_off_outlined,
                        size: 15,
                        color: c.error == null
                            ? const Color(0xff267044)
                            : danger,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          c.error != null
                              ? 'Не удалось обновить данные'
                              : c.lastUpdated == null
                              ? 'Подключение…'
                              : 'Обновлено в ${clockLabel(c.lastUpdated!)}',
                          style: const TextStyle(fontSize: 12, color: muted),
                        ),
                      ),
                      Text(
                        master
                            ? 'Мастер'
                            : c.user!.isWorker
                            ? 'Исполнитель'
                            : 'Руководитель',
                        style: const TextStyle(fontSize: 12, color: muted),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (c.offline)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                decoration: const BoxDecoration(
                  color: Color(0xfffff8e1),
                  border: Border(bottom: BorderSide(color: line)),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.cloud_off_outlined,
                          size: 16,
                          color: Color(0xff8c6d00),
                        ),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Нет соединения. Действия сохраняются на устройстве и отправятся после восстановления связи.',
                            style: TextStyle(
                              fontSize: 12,
                              color: Color(0xff6b5300),
                            ),
                          ),
                        ),
                        IconButton(
                          onPressed: () => _refresh(),
                          tooltip: 'Повторить соединение',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(
                            Icons.sync,
                            size: 16,
                            color: Color(0xff8c6d00),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _refresh(),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: ListView(
                      key: PageStorageKey('workspace-$page'),
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                titles[page],
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineMedium,
                              ),
                            ),
                            if (page == 0)
                              const Icon(Icons.wb_sunny_outlined, color: muted),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          page == 0
                              ? '${c.user!.name} · ${c.dashboard['shift_label'] ?? 'Текущая смена'}'
                              : page == 1
                              ? 'Все задания и история работ'
                              : page == 2
                              ? 'События и задания, требующие внимания'
                              : 'Результаты работ и оценки исполнителей',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (c.error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: InfoPanel(
                              '${c.error}\nПоказаны последние полученные данные.',
                              color: danger,
                              action: TextButton(
                                onPressed: () => _refresh(),
                                child: const Text('Повторить обновление'),
                              ),
                            ),
                          ),
                        if (c.hasPendingWrites || c.conflictCommands.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: InfoPanel(
                              c.conflictCommands.isEmpty
                                  ? 'На устройстве ${c.outbox.where((item) => item.state != OutboxState.conflict).length} действие(й) ожидает отправки после восстановления связи.'
                                  : 'Некоторые сохранённые действия требуют решения: сервер их не принял.',
                              color: c.conflictCommands.isEmpty ? navy : danger,
                              icon: c.conflictCommands.isEmpty
                                  ? Icons.sync
                                  : Icons.warning_amber_outlined,
                              action: TextButton(
                                onPressed: showSyncQueue,
                                child: Text(
                                  c.conflictCommands.isEmpty
                                      ? 'Открыть очередь'
                                      : 'Решить конфликт',
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 20),
                        if (page == 0)
                          OverviewScreen(
                            controller: c,
                            onOrder: openOrder,
                            onCreate: createOrder,
                            onFilter: showOrders,
                          ),
                        if (page == 1)
                          OrdersScreen(
                            key: ValueKey('$orderFilter-$assigneeFilter'),
                            controller: c,
                            initialFilter: orderFilter,
                            assigneeId: assigneeFilter,
                            onOrder: openOrder,
                            onCreate: () => createOrder(),
                          ),
                        if (page == 2) ...[
                          const InfoPanel(
                            'Push-уведомления теперь приходят и в фоне: приложение может быть закрыто, а событие или аварийный наряд всё равно придёт со звуком. Нажмите на событие, чтобы сразу открыть наряд.',
                            icon: Icons.notifications_none,
                          ),
                          const SizedBox(height: 16),
                          if (c.notifications.isEmpty)
                            const InfoPanel(
                              'Новых событий пока нет.',
                              icon: Icons.inbox_outlined,
                            ),
                          for (final n in c.notifications)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: Card(
                                child: ListTile(
                                  contentPadding: const EdgeInsets.all(14),
                                  leading: Icon(
                                    n['read'] == true
                                        ? Icons.notifications_none
                                        : Icons.notifications_active_outlined,
                                    color: n['read'] == true ? muted : navy,
                                  ),
                                  title: Text(
                                    '${n['title'] ?? 'Событие наряда'}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: Text(
                                      '${n['message'] ?? n['body'] ?? ''}\n${dateLabel(DateTime.parse(n['created_at'] as String))}',
                                    ),
                                  ),
                                  trailing: n['order_id'] != null
                                      ? const Icon(Icons.chevron_right)
                                      : null,
                                  onTap: () async {
                                    try {
                                      await c.markRead(n['id'] as int);
                                      if (mounted && n['order_id'] != null) {
                                        openOrder(n['order_id'] as int);
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(content: Text(e.toString())),
                                        );
                                      }
                                    }
                                  },
                                ),
                              ),
                            ),
                        ],
                        if (page == 3)
                          ReportsScreen(
                            controller: c,
                            onOrders: (id) => showOrders('all', assignee: id),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: page,
        onDestinationSelected: (i) => setState(() {
          page = i;
          if (i == 1) {
            orderFilter = null;
            assigneeFilter = null;
          }
        }),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.space_dashboard_outlined),
            selectedIcon: Icon(Icons.space_dashboard),
            label: 'Главная',
          ),
          const NavigationDestination(
            icon: Icon(Icons.assignment_outlined),
            selectedIcon: Icon(Icons.assignment),
            label: 'Наряды',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text(unread > 99 ? '99+' : '$unread'),
              child: const Icon(Icons.notifications_none),
            ),
            label: 'События',
          ),
          const NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Отчёты',
          ),
        ],
      ),
    );
  }
}

class SyncQueueDialog extends StatelessWidget {
  const SyncQueueDialog({
    required this.controller,
    required this.commandLabel,
    super.key,
  });
  final AppController controller;
  final String Function(OutboxCommand) commandLabel;

  Future<void> _retry(BuildContext context, OutboxCommand command) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await controller.retryCommand(command.commandId);
    messenger.showSnackBar(
      SnackBar(content: Text('${commandLabel(command)}: отправка снова.')),
    );
    if (navigator.mounted) navigator.pop();
  }

  Future<void> _discard(BuildContext context, OutboxCommand command) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить команду?'),
        content: const Text(
          'Повторная отправка будет остановлена. Если сервер уже сохранил действие, удаление команды его не отменит. Зависимые команды (фото, сдача) тоже будут удалены. Проверьте состояние наряда после восстановления связи.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Оставить'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await controller.discardCommand(command.commandId);
    messenger.showSnackBar(
      SnackBar(content: Text('${commandLabel(command)} удалено.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final pending = controller.outbox
            .where((item) => item.state != OutboxState.conflict)
            .toList();
        final conflicts = controller.conflictCommands;
        return AlertDialog(
          title: const Text('Очередь отправки'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView(
              shrinkWrap: true,
              children: [
                if (pending.isEmpty && conflicts.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Сохранённых действий нет.'),
                  ),
                for (final command in pending)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.sync, color: navy),
                    title: Text(commandLabel(command)),
                    subtitle: Text(
                      'Ожидает отправки · ${dateLabel(DateTime.fromMillisecondsSinceEpoch(command.createdAt))}',
                    ),
                  ),
                for (final command in conflicts)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.warning_amber_outlined,
                      color: danger,
                    ),
                    title: Text(commandLabel(command)),
                    subtitle: Text(
                      command.lastError != null && command.lastError!.isNotEmpty
                          ? command.lastError!
                          : 'Сервер не принял действие',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _retry(context, command),
                          tooltip: 'Отправить снова',
                          icon: const Icon(Icons.replay),
                        ),
                        IconButton(
                          onPressed: () => _discard(context, command),
                          tooltip: 'Удалить команду',
                          icon: const Icon(Icons.delete_outline, color: danger),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Закрыть'),
            ),
          ],
        );
      },
    );
  }
}
