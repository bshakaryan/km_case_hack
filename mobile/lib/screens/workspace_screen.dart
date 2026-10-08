import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../data/local_store.dart';
import '../data/models.dart';
import '../data/recovery_models.dart';
import '../domain/navigation_scope.dart';
import '../ui.dart';
import 'command_inspector_screen.dart';
import 'create_order_screen.dart';
import 'order_detail_screen.dart';
import 'overview_screen.dart';
import 'orders_screen.dart';
import 'reports_screen.dart';
import 'reference_catalog_screen.dart';
import 'master_assistant_sheet.dart';

class _NoticeTarget {
  const _NoticeTarget(this.id, this.orderId, this.scope);
  final int id;
  final int? orderId;
  final NavigationScope scope;
}

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
  final Set<int> _openingNotices = {};
  _NoticeTarget? _pendingNotice;
  Object? _noticeCallback;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_resumeNotice);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_resumeNotice);
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

  Future<void> openOrder(int id, {bool notificationEntry = false}) async {
    final scope = widget.controller.captureNavigationScope();
    if (!scope.isCurrent) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: 'order:$id'),
        builder: (_) => OrderDetailScreen(
          controller: widget.controller,
          orderId: id,
          notificationEntry: notificationEntry,
        ),
      ),
    );
    if (mounted && scope.isCurrent) {
      _refresh(silent: true);
      _resumeNotice();
    }
  }

  void _openNotice(Json notice) {
    final id = notice['id'];
    final orderId = notice['order_id'];
    if (id is! int || id <= 0 || _openingNotices.contains(id)) return;
    final scope = widget.controller.captureNavigationScope();
    if (!scope.isCurrent) return;
    _pendingNotice = _NoticeTarget(
      id,
      orderId is int && orderId > 0 ? orderId : null,
      scope,
    );
    if (widget.controller.referenceWriteBusy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Уведомление откроется после текущей отправки.'),
        ),
      );
    }
    _resumeNotice();
  }

  bool _emergencyNotice(Json notice) => widget.controller.orders.any(
    (order) => order.id == notice['order_id'] && order.priority == 'emergency',
  );

  void _resumeNotice() {
    final target = _pendingNotice;
    if (!mounted || target == null) return;
    if (!target.scope.isCurrent) {
      _pendingNotice = null;
      _noticeCallback = null;
      return;
    }
    if (_noticeCallback != null || widget.controller.referenceWriteBusy) return;
    final ticket = Object();
    _noticeCallback = ticket;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_noticeCallback, ticket)) return;
      _noticeCallback = null;
      if (!identical(_pendingNotice, target) || !target.scope.isCurrent) {
        _resumeNotice();
        return;
      }
      if (widget.controller.referenceWriteBusy ||
          !(ModalRoute.of(context)?.isCurrent ?? false)) {
        return;
      }
      _pendingNotice = null;
      unawaited(_launchNotice(target));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _launchNotice(_NoticeTarget target) async {
    if (!target.scope.isCurrent || !_openingNotices.add(target.id)) return;
    // Reading is independent of viewing/answering. Never accept on a tap.
    final read = _markNoticeRead(target);
    try {
      if (target.orderId != null && mounted && target.scope.isCurrent) {
        await openOrder(target.orderId!, notificationEntry: true);
      } else {
        await read;
      }
    } finally {
      _openingNotices.remove(target.id);
    }
  }

  Future<void> _markNoticeRead(_NoticeTarget target) async {
    try {
      await widget.controller.markRead(target.id);
    } catch (failure) {
      if (mounted && target.scope.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Не удалось отметить уведомление прочитанным: $failure',
            ),
          ),
        );
      }
    }
  }

  Future<void> createOrder({int? assigneeId}) async {
    final scope = widget.controller.captureNavigationScope();
    final order = await Navigator.of(context).push<WorkOrder>(
      MaterialPageRoute(
        builder: (_) => CreateOrderScreen(
          controller: widget.controller,
          assigneeId: assigneeId,
        ),
      ),
    );
    if (mounted && scope.isCurrent && order != null) openOrder(order.id);
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
      barrierDismissible: false,
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
      floatingActionButton: c.user!.role == 'master'
          ? FloatingActionButton(
              tooltip: 'Ассистент мастера',
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => MasterAssistantSheet(controller: c),
              ),
              child: const Icon(Icons.chat_bubble_outline),
            )
          : null,
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
          if (c.canManageReferences)
            IconButton(
              tooltip: 'Справочники',
              onPressed: c.referenceWriteBusy
                  ? null
                  : () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => ReferenceCatalogScreen(controller: c),
                      ),
                    ),
              icon: const Icon(Icons.inventory_2_outlined),
            ),
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
                        c.user!.role == 'admin'
                            ? 'Администратор'
                            : master
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
                                    color: _emergencyNotice(n)
                                        ? danger
                                        : n['read'] == true
                                        ? muted
                                        : navy,
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
                                  onTap: () => _openNotice(n),
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

class SyncQueueDialog extends StatefulWidget {
  const SyncQueueDialog({
    required this.controller,
    required this.commandLabel,
    super.key,
  });
  final AppController controller;
  final String Function(OutboxCommand) commandLabel;

  @override
  State<SyncQueueDialog> createState() => _SyncQueueDialogState();
}

class _SyncQueueDialogState extends State<SyncQueueDialog> {
  late final RecoveryScope _scope;
  ModalRoute<dynamic>? _route;
  bool _working = false, _revoked = false;
  String? _error;
  AppController get _controller => widget.controller;
  bool get _current => !_revoked && _scope.matches(_controller);
  bool get _controllerBusy =>
      _controller.recoveringQueue ||
      _controller.syncing ||
      _controller.saving ||
      _controller.restoring;
  bool get _blocked => _working || _controllerBusy;

  @override
  void initState() {
    super.initState();
    _scope = RecoveryScope(_controller);
    _controller.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(SyncQueueDialog oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
      _revoked = true;
      closeRecoveryRoute(context, _route);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    if (!_current) {
      _revoked = true;
      closeRecoveryRoute(context, _route);
    }
    setState(() {});
  }

  bool _acceptScope(QueueRecoveryStatus status) {
    if (!mounted) return false;
    if (!_current || status == QueueRecoveryStatus.scopeChanged) {
      setState(() => _revoked = true);
      closeRecoveryRoute(context, _route);
      return false;
    }
    return true;
  }

  void _showResult(QueueActionResult result, String success) {
    if (!_acceptScope(result.status)) return;
    if (result.status == QueueRecoveryStatus.success && result.changed) {
      final warning = result.warning;
      setState(
        () =>
            _error = warning == null ? null : recoveryMessage(warning, _scope),
      );
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
    } else {
      final warning = result.changed ? result.warning : null;
      setState(
        () => _error = recoveryMessage(
          [result.message, ?warning].join('\n'),
          _scope,
        ),
      );
    }
  }

  Future<void> _retry(OutboxCommand command) async {
    if (!_current ||
        _blocked ||
        !_scope.owns(command) ||
        command.state != OutboxState.conflict ||
        !command.canRetry) {
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final result = await _controller.retryCommand(command.commandId);
      _showResult(result, 'Повторная отправка поставлена в очередь');
    } catch (_) {
      if (mounted && _current) {
        setState(
          () => _error = 'Не удалось подтвердить сохранение повторной отправки. Проверьте очередь.',
        );
      }
    } finally {
      if (mounted && _current) setState(() => _working = false);
    }
  }

  Future<void> _inspect(OutboxCommand command) async {
    if (!_current || _blocked || !_scope.owns(command)) return;
    setState(() => _working = true);
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CommandInspectorScreen(
          controller: _controller,
          commandId: command.commandId,
          scope: _scope,
          commandLabel: widget.commandLabel,
        ),
      );
    } finally {
      if (mounted && _current) setState(() => _working = false);
    }
  }

  Future<void> _discard(OutboxCommand command) async {
    if (!_current ||
        _blocked ||
        !_scope.owns(command) ||
        command.state != OutboxState.conflict) {
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final read = await _controller.inspectCommand(command.commandId);
      if (!_acceptScope(read.status)) return;
      final inspection = read.inspection;
      if (read.status != QueueRecoveryStatus.success || inspection == null) {
        setState(() => _error = recoveryMessage(read.message, _scope));
        return;
      }
      final chain = [inspection.command, ...inspection.dependentCommands];
      if (!chain.every(_scope.owns)) {
        _acceptScope(QueueRecoveryStatus.scopeChanged);
        return;
      }
      if (_controllerBusy) {
        setState(
          () => _error = 'Сейчас выполняется отправка. Дождитесь её завершения и проверьте цепь снова.',
        );
        return;
      }
      if (!mounted || !_current) return;
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AnimatedBuilder(
          animation: _controller,
          builder: (_, _) {
            if (!_current) return const SizedBox.shrink();
            return AlertDialog(
              title: const Text('Удалить выбранную цепь?'),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    const Text(
                      'Повторная отправка выбранной команды и зависимых действий будет остановлена. Их сохранённый текст и подготовленные фото будут удалены с устройства.',
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Если сервер уже сохранил действие, удаление из очереди его не отменит. Проверьте состояние наряда после восстановления связи.',
                    ),
                    const SizedBox(height: 12),
                    Text('Команд в выбранной цепи: ${chain.length}'),
                    for (final item in chain)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(widget.commandLabel(item)),
                        subtitle: Text(
                          'Ключ: ${item.commandId}${item.photoFilename != null ? '\nФото: ${item.photoFilename}' : ''}',
                        ),
                      ),
                    if (_controllerBusy)
                      const Text(
                        'Дождитесь завершения текущей операции.',
                        style: TextStyle(color: danger),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Оставить'),
                ),
                FilledButton(
                  onPressed: _controllerBusy
                      ? null
                      : () => Navigator.pop(dialogContext, true),
                  child: const Text('Удалить цепь'),
                ),
              ],
            );
          },
        ),
      );
      if (!mounted || !_current || confirmed != true) return;
      if (_controllerBusy) {
        setState(
          () => _error = 'Очередь занята. Проверьте выбранную цепь снова после завершения операции.',
        );
        return;
      }
      final result = await _controller.discardCommand(
        command.commandId,
        expectedCommandIds: inspection.commandIds,
        expectedCommands: chain,
      );
      _showResult(result, 'Выбранная цепь удалена из локальной очереди');
    } catch (_) {
      if (mounted && _current) {
        setState(
          () => _error = 'Не удалось удалить цепь. Проверьте очередь перед повторным действием.',
        );
      }
    } finally {
      if (mounted && _current) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) return const SizedBox.shrink();
    final commands = _controller.outbox.where(_scope.owns).toList();
    return PopScope(
      canPop: !_working,
      child: AlertDialog(
        title: const Text('Очередь отправки'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: const TextStyle(color: danger)),
                ),
              if (_working)
                const Text('Завершите текущее действие с очередью.'),
              if (_controllerBusy)
                const Text(
                  'Выполняется операция с очередью. Действия временно недоступны.',
                ),
              if (commands.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('Сохранённых действий нет.'),
                ),
              for (final command in commands)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        command.state == OutboxState.conflict
                            ? Icons.warning_amber_outlined
                            : Icons.sync,
                        color: command.state == OutboxState.conflict
                            ? danger
                            : navy,
                      ),
                      title: Text(widget.commandLabel(command)),
                      subtitle: Text(
                        '${recoveryCommandStatus(command)} · ${dateLabel(DateTime.fromMillisecondsSinceEpoch(command.createdAt))}',
                      ),
                      onTap: _blocked ? null : () => _inspect(command),
                    ),
                    Wrap(
                      spacing: 4,
                      children: [
                        TextButton.icon(
                          onPressed: _blocked ? null : () => _inspect(command),
                          icon: const Icon(Icons.description_outlined),
                          label: const Text('Посмотреть данные'),
                        ),
                        if (command.state == OutboxState.conflict) ...[
                          if (command.canRetry)
                            TextButton.icon(
                              onPressed: _blocked
                                  ? null
                                  : () => _retry(command),
                              icon: const Icon(Icons.replay),
                              label: const Text('Отправить снова'),
                            ),
                          TextButton.icon(
                            onPressed: _blocked
                                ? null
                                : () => _discard(command),
                            icon: const Icon(
                              Icons.delete_outline,
                              color: danger,
                            ),
                            label: const Text('Удалить команду'),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _working ? null : () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }
}
