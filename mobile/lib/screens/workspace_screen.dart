import 'package:flutter/material.dart';

import '../data/app_controller.dart';
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
                            'Уведомления обновляются, пока приложение открыто. Push в фоне будет подключён отдельным этапом.',
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
