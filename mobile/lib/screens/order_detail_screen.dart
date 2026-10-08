import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

import '../data/app_controller.dart';
import '../data/api.dart';
import '../data/local_store.dart';
import '../data/models.dart';
import '../domain/navigation_scope.dart';
import '../ui.dart' as app_ui;
import '../widgets/order_photo.dart';
import '../widgets/order_history.dart';
import '../widgets/ai_job_status.dart';
import 'completion_screen.dart';
import 'order_journal_screen.dart';
import 'create_order_screen.dart' show prepareOrderPhoto;

const _blue = Color(0xFF173E68);
const _red = Color(0xFFB4232D);

class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({
    super.key,
    required this.controller,
    required this.orderId,
    this.notificationEntry = false,
    this.imagePicker,
    this.photoPreparer,
  });
  final AppController controller;
  final int orderId;
  final bool notificationEntry;
  final ImagePicker? imagePicker;
  final Future<Uint8List> Function(Uint8List)? photoPreparer;

  @override
  State<OrderDetailScreen> createState() => _OrderDetailScreenState();
}

class _OrderDetailScreenState extends State<OrderDetailScreen> {
  WorkOrder? _order;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  bool _fetching = false;
  bool _aiRetryUncertain = false;
  int _revision = 0;
  DateTime? _updatedAt;
  Timer? _timer;
  late final NavigationScope _scope;
  bool _detailRead = false;
  bool _accessDenied = false;
  ModalRoute<dynamic>? _dialogRoute;
  NavigatorState? _dialogNavigator;

  @override
  void initState() {
    super.initState();
    _scope = widget.controller.captureNavigationScope();
    widget.controller.addListener(_controllerChanged);
    if (!_scope.isCurrent) {
      _loading = false;
      _error = 'Войдите в приложение и откройте наряд заново.';
    }
    _seedFromCache();
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_scope.isCurrent || widget.controller.offline) return;
      if (!_busy && mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
        unawaited(_load(silent: true));
      }
    });
  }

  void _seedFromCache() {
    if (!_scope.isCurrent ||
        !widget.controller.canUseCachedOrder(widget.orderId)) {
      return;
    }
    for (final item in widget.controller.orders) {
      if (item.id == widget.orderId) {
        _order = item;
        _loading = false;
        break;
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  bool get _current => mounted && _scope.isCurrent;
  bool get _canWrite =>
      _scope.isCurrent &&
      widget.controller.canUseCachedOrder(widget.orderId) &&
      !_accessDenied &&
      (_detailRead || (!widget.notificationEntry && _order != null));
  bool get _writeBusy => _busy || widget.controller.referenceWriteBusy;

  void _controllerChanged() {
    if (!mounted) return;
    if (!_scope.isCurrent) {
      _revision++;
      final route = _dialogRoute;
      final navigator = _dialogNavigator;
      if (route != null && navigator != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (navigator.mounted && route.isActive) navigator.removeRoute(route);
        });
      }
      setState(() {
        _order = null;
        _loading = false;
        _error = 'Сессия или сервер изменились. Откройте наряд заново.';
      });
      return;
    }
    if (!widget.controller.canUseCachedOrder(widget.orderId)) {
      _order = null;
      _accessDenied = true;
    }
    if (!_accessDenied) {
      final cached = widget.controller.orders
          .where((order) => order.id == widget.orderId)
          .firstOrNull;
      if (cached != null) {
        _order = cached.withCachedHistory(_order);
      }
    }
    setState(() {});
  }

  Future<T?> _showScopedDialog<T>(WidgetBuilder builder) async {
    if (!_current) return null;
    return _pushScopedRoute(DialogRoute<T>(context: context, builder: builder));
  }

  Future<T?> _showScopedSheet<T>(WidgetBuilder builder) async {
    if (!_current) return null;
    return _pushScopedRoute(
      ModalBottomSheetRoute<T>(
        builder: builder,
        isScrollControlled: false,
        useSafeArea: true,
      ),
    );
  }

  Future<T?> _pushScopedRoute<T>(ModalRoute<T> route) async {
    if (!_current) return null;
    final navigator = Navigator.of(context, rootNavigator: true);
    _dialogRoute = route;
    _dialogNavigator = navigator;
    try {
      return await navigator.push(route);
    } finally {
      if (identical(_dialogRoute, route)) {
        _dialogRoute = null;
        _dialogNavigator = null;
      }
    }
  }

  Future<void> _load({bool silent = false}) async {
    if (_fetching || !_scope.isCurrent) return;
    final revision = _revision;
    _fetching = true;
    if (!silent && mounted) setState(() => _loading = _order == null);
    try {
      final order = await widget.controller.loadOrder(widget.orderId);
      if (!_current || revision != _revision) return;
      if (_accessDenied && widget.controller.offline) {
        // loadOrder may fall back to a retained snapshot. A cached result is
        // not evidence that the earlier server denial has been lifted.
        setState(() {
          _error =
              'Доступ к наряду ранее был отклонён сервером. '
              'Без связи повторная проверка доступа не выполнена.';
        });
        return;
      }
      setState(() {
        _order = order;
        _error = null;
        _updatedAt = DateTime.now();
        _detailRead = true;
        _accessDenied = false;
        if (!widget.controller.offline) _aiRetryUncertain = false;
      });
    } catch (error) {
      if (_current && revision == _revision) {
        setState(() {
          _error = error.toString();
          if (error is ApiException && {403, 404}.contains(error.statusCode)) {
            // Retained controller data and drafts are not deleted. The server
            // denial removes this screen's obsolete presentation and actions.
            _order = null;
            _accessDenied = true;
          }
        });
      }
    } finally {
      _fetching = false;
      if (_current) setState(() => _loading = false);
    }
  }

  Future<void> _retryAiReview() async {
    final order = _order;
    if (!_canWrite ||
        _writeBusy ||
        _aiRetryUncertain ||
        order == null ||
        !order.canRetryAiReview) {
      return;
    }
    _revision++;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await widget.controller.retryAiReview(
        order.id,
        (order.aiReviewJob!['attempt_id'] as num).toInt(),
        basis: OrderWriteBasis(expectedVersion: order.version),
      );
      if (!mounted || !_scope.isCurrent) return;
      setState(() {
        _order = updated;
        _updatedAt = DateTime.now();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Проверка поставлена в очередь. Отчёт сохранён.'),
        ),
      );
    } catch (failure) {
      if (mounted && _scope.isCurrent) {
        setState(() {
          _error = failure.toString();
          _aiRetryUncertain =
              failure is! ApiException || failure.requestMayHaveSucceeded;
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  bool get _master =>
      _scope.isCurrent && (widget.controller.user?.isMaster ?? false);
  bool get _canExecute =>
      _canWrite &&
      (widget.controller.user?.isWorker ?? false) &&
      (_order?.isResponsible(widget.controller.user?.id) ?? false);

  bool _canAddPhoto(WorkOrder order) {
    if (!_canWrite) return false;
    if ({'ai_review', 'closed', 'cancelled'}.contains(order.status)) {
      return false;
    }
    final user = widget.controller.user;
    return user?.isMaster == true ||
        (user?.isWorker == true && order.hasParticipant(user?.id));
  }

  Future<void> _addPhoto(String kind) async {
    final order = _order;
    if (_writeBusy || order == null || !_canAddPhoto(order)) return;
    final controller = widget.controller;
    final api = controller.api;
    final ownerId = controller.user?.id;
    // Freeze before the picker and compression; a GET cannot rebase this write.
    final basis = controller.captureOrderBasis(order);
    final saved = _maps(order.data['photos'])
        .where((p) => p['kind'] == kind)
        .length;
    final waiting = controller.outbox
        .where(
          (command) =>
              command.kind == OutboxKind.uploadPhoto &&
              command.photoKind == kind &&
              (command.orderId == order.id ||
                  command.localRef == '${order.id}'),
        )
        .length;
    if (saved + waiting >= 5) {
      setState(
        () => _error = 'Допускается до 5 фото каждого вида на наряд. Проверьте карточку и очередь.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final source = await _showScopedSheet<ImageSource>(
        (context) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(kind == 'before' ? 'Фото до ремонта' : 'Фото после ремонта'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => Navigator.pop(context, ImageSource.camera),
                icon: const Icon(Icons.camera_alt_outlined),
                label: const Text('Сделать снимок'),
              ),
              OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, ImageSource.gallery),
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Выбрать из галереи'),
              ),
            ],
          ),
        ),
      );
      if (!_current || source == null) return;
      final file = await (widget.imagePicker ?? ImagePicker()).pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 88,
      );
      if (!_current || file == null) return;
      final original = await file.readAsBytes();
      if (original.length > 30 * 1024 * 1024) {
        throw const ApiException('Выберите снимок до 30 МБ.', 413);
      }
      final bytes =
          await (widget.photoPreparer?.call(original) ??
              compute(prepareOrderPhoto, original));
      if (!mounted || !_scope.isCurrent) return;
      if (!identical(controller.api, api) || controller.user?.id != ownerId) {
        throw const ApiException(
          'Аккаунт или сервер изменился. Фото не отправлено.',
          401,
        );
      }
      final current = controller.orders
          .where((item) => item.id == order.id)
          .firstOrNull;
      if (!_canAddPhoto(current ?? order)) {
        throw const ApiException(
          'Вы больше не можете добавлять фото в этот наряд.',
          403,
        );
      }
      await controller.uploadPhoto(
        order.id,
        bytes,
        '$kind-${DateTime.now().microsecondsSinceEpoch}.jpg',
        kind,
        basis: basis,
      );
      if (!mounted || !_scope.isCurrent) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            controller.isOrderPending(order.id)
                ? 'Фото сохранено в очереди на устройстве. Ожидает отправки.'
                : 'Фотография подтверждена сервером.',
          ),
        ),
      );
      await _load(silent: true);
    } catch (error) {
      if (_current) setState(() => _error = '$error');
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  bool _hasOtherOpenOrder(WorkOrder order) {
    final userId = widget.controller.user?.id;
    if (userId == null) return false;
    const openStatuses = {'accepted', 'queued', 'in_progress', 'paused'};
    return widget.controller.orders.any((candidate) {
      final assigneeId = (candidate.data['assignee_id'] as num?)?.toInt();
      return candidate.id != order.id &&
          assigneeId == userId &&
          openStatuses.contains(candidate.status);
    });
  }

  bool _hasOtherExecutingOrder(WorkOrder order) {
    final userId = widget.controller.user?.id;
    if (userId == null) return false;
    return widget.controller.orders.any((candidate) {
      final assigneeId = (candidate.data['assignee_id'] as num?)?.toInt();
      return candidate.id != order.id &&
          assigneeId == userId &&
          {'in_progress', 'paused'}.contains(candidate.status);
    });
  }

  bool _hasOtherInProgressOrder(WorkOrder order) {
    final userId = widget.controller.user?.id;
    if (userId == null) return false;
    return widget.controller.orders.any((candidate) {
      final assigneeId = (candidate.data['assignee_id'] as num?)?.toInt();
      return candidate.id != order.id &&
          assigneeId == userId &&
          candidate.status == 'in_progress';
    });
  }

  Future<void> _act(
    String action, {
    String? reason,
    double? score,
    OrderWriteBasis? basis,
  }) async {
    if (!_canWrite || _writeBusy) return;
    if (!_master && !_canExecute) return;
    _revision++;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final updated = await widget.controller.transition(
        widget.orderId,
        action,
        reason: reason,
        score: score,
        basis:
            basis ??
            (_order == null
                ? const OrderWriteBasis()
                : widget.controller.captureOrderBasis(_order!)),
      );
      if (!mounted || !_scope.isCurrent) return;
      setState(() {
        _order = updated;
        _updatedAt = DateTime.now();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            updated.pendingSync || widget.controller.isOrderPending(updated.id)
                ? 'Действие сохранено на устройстве. Ожидает отправки.'
                : action == 'queue' && updated.status == 'queued'
                ? 'Задание поставлено в очередь · место ${updated.data['queue_position'] ?? '—'}'
                : action == 'accept'
                ? 'Задание принято. Это ваше единственное текущее задание.'
                : 'Сервер подтвердил: ${_status(updated.status)}',
          ),
        ),
      );
    } catch (error) {
      if (_current) setState(() => _error = error.toString());
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _reason(String action, String title) async {
    if (!_canWrite || _writeBusy) return;
    final basis = _order == null
        ? const OrderWriteBasis()
        : widget.controller.captureOrderBasis(_order!);
    final controller = TextEditingController();
    final key = GlobalKey<FormState>();
    final result = await _showScopedDialog<String>(
      (context) => AlertDialog(
        title: Text(title),
        content: Form(
          key: key,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            maxLength: 3000,
            decoration: const InputDecoration(
              labelText: 'Причина',
              hintText: 'Что мешает продолжить работу?',
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Укажите причину'
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Назад'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 52)),
            onPressed: () {
              if (key.currentState!.validate()) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: Text(title),
          ),
        ],
      ),
    );
    // The dialog route may still animate; the controller is no longer modified.
    if (result != null && _current) {
      await _act(action, reason: result, basis: basis);
    }
  }

  Future<void> _closeOrder() async {
    if (!_canWrite || _writeBusy) return;
    final basis = _order == null
        ? const OrderWriteBasis()
        : widget.controller.captureOrderBasis(_order!);
    double? selected;
    final score = await _showScopedDialog<double>(
      (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Принять работу'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Проверьте отчёт и фотографии. Итоговую оценку ставит мастер.',
              ),
              const SizedBox(height: 20),
              const Text(
                'Оценка качества',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: List.generate(5, (index) {
                  final value = index + 1;
                  return ChoiceChip(
                    label: Text('$value'),
                    selected: selected == value,
                    showCheckmark: false,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    onSelected: (_) =>
                        setDialogState(() => selected = value.toDouble()),
                  );
                }),
              ),
              const SizedBox(height: 8),
              const Text(
                '1 — неудовлетворительно · 5 — отлично',
                style: TextStyle(fontSize: 14),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Назад'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(140, 52)),
              onPressed: selected == null
                  ? null
                  : () => Navigator.pop(context, selected),
              child: const Text('Закрыть наряд'),
            ),
          ],
        ),
      ),
    );
    if (score != null && _current) {
      await _act('close', score: score, basis: basis);
    }
  }

  Future<void> _complete() async {
    final order = _order;
    if (_writeBusy || order == null || !_canExecute) return;
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            CompletionScreen(controller: widget.controller, order: order),
      ),
    );
    if (mounted && _scope.isCurrent) {
      await _load();
      if (result == true && mounted && _scope.isCurrent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.controller.isOrderPending(widget.orderId) ||
                      (_order?.pendingSync ?? false)
                  ? 'Отчёт сохранён на устройстве. Ожидает отправки.'
                  : 'Отчёт получен сервером. Ожидается приёмка мастера.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final order = _order;
    return Scaffold(
      backgroundColor: const Color(0xFFF3F5F8),
      appBar: AppBar(
        title: Text(order?.number ?? 'Карточка наряда'),
        actions: [
          IconButton(
            tooltip: 'Обновить наряд',
            onPressed: !_scope.isCurrent || _busy ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
          if (order != null &&
              _master &&
              !{'closed', 'cancelled'}.contains(order.status))
            PopupMenuButton<String>(
              tooltip: 'Другие действия',
              enabled: _canWrite && !_writeBusy,
              onSelected: (_) => _reason('cancel', 'Отменить наряд'),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'cancel',
                  child: Text('Отменить наряд'),
                ),
              ],
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : order == null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cloud_off_outlined,
                      size: 40,
                      color: _blue,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      _error ?? 'Наряд недоступен',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: _scope.isCurrent ? _load : null,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Повторить загрузку'),
                    ),
                  ],
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                children: [
                  if (_error != null) _errorNotice(),
                  _overview(order),
                  const SizedBox(height: 16),
                  if (order.priority == 'emergency') _emergencyResponse(order),
                  _section('Задание', [
                    Text(
                      order.description.isEmpty
                          ? 'Описание не указано'
                          : order.description,
                      style: const TextStyle(fontSize: 17, height: 1.45),
                    ),
                    if ((order.data['comment'] ?? '')
                        .toString()
                        .isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text('Комментарий мастера: ${order.data['comment']}'),
                    ],
                  ]),
                  _section('Сроки и оборудование', [
                    _row('Участок', order.areaName),
                    _row('Оборудование', order.equipmentName),
                    if (const {
                          'master',
                          'manager',
                          'admin',
                        }.contains(widget.controller.user?.role) &&
                        order.data['equipment_id'] is int)
                      TextButton.icon(
                        onPressed: !_scope.isCurrent || _busy
                            ? null
                            : () => Navigator.of(context).push<void>(
                                MaterialPageRoute(
                                  builder: (_) => OrderJournalScreen(
                                    controller: widget.controller,
                                    equipmentId:
                                        order.data['equipment_id'] as int,
                                  ),
                                ),
                              ),
                        icon: const Icon(Icons.history),
                        label: const Text('История оборудования'),
                      ),
                    _row(
                      order.isBrigade ? 'Ответственный' : 'Исполнитель',
                      order.assigneeName,
                    ),
                    _row('Выдан', _date(order.data['created_at'])),
                    _row(
                      'Срок',
                      _date(order.data['deadline']),
                      danger: order.isOverdue,
                    ),
                    _row('Норматив', '${_number(order.normalHours)} ч'),
                    if (order.data['started_at'] != null)
                      _row('Начало', _date(order.data['started_at'])),
                    if (order.data['completed_at'] != null)
                      _row('Сдан', _date(order.data['completed_at'])),
                    if (_elapsed(order) != null)
                      _row('От начала до сдачи', _elapsed(order)!),
                    if (order.workType == 'unplanned') ...[
                      _row(
                        'Простой по данным сервера',
                        '${_number(order.data['downtime_minutes'])} мин',
                      ),
                      const Text(
                        'Расчёт от выдачи наряда. Фактические остановки и паузы отдельно пока не учитываются.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ]),
                  if (order.isBrigade)
                    _section('Участники назначения', [
                      if (order.id < 0)
                        const Text(
                          'Состав и ответственный пока не подтверждены сервером.',
                        )
                      else ...[
                        for (final participant in order.participants)
                          _row(
                            participant.isResponsible
                                ? 'Ответственный'
                                : 'Участник',
                            participant.name,
                          ),
                        if (order.participantsSource == 'legacy_snapshot')
                          const Text(
                            'Из прежних данных подтверждён только сохранённый исполнитель. Полный состав этой бригады неизвестен.',
                          ),
                        if (widget.controller.user?.isWorker == true &&
                            !_canExecute)
                          const Text(
                            'Вы участвуете в общем наряде и можете добавлять фотографии. Переходы и сдачу выполняет ответственный.',
                          ),
                      ],
                    ]),
                  _photos(order),
                  if (order.data['completion'] is Map) _report(order),
                  if (!order.pendingSync)
                    AiJobStatus(
                      job: order.aiReviewJob,
                      onRetry: _master && order.canRetryAiReview
                          ? _retryAiReview
                          : null,
                      busy: _busy,
                      uncertain: _aiRetryUncertain,
                      offline: widget.controller.offline,
                    ),
                  if (order.data['ai_review'] is Map &&
                      order.showAiReview &&
                      !order.pendingSync)
                    _review(order),
                  OrderHistory(order: order, controller: widget.controller),
                  _history(order),
                  if (_updatedAt != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Обновлено ${app_ui.clockLabel(_updatedAt!)} · время предприятия',
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ),
                ],
              ),
            ),
      bottomNavigationBar: order == null ? null : _actions(order),
    );
  }

  Widget _errorNotice() => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: const Color(0xFFFFF1F1),
      border: Border.all(color: const Color(0xFFEFC2C4)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_error!, style: const TextStyle(color: _red)),
        const Text(
          'Показаны последние полученные данные.',
          style: TextStyle(fontSize: 13),
        ),
        TextButton.icon(
          onPressed: _busy ? null : () => _load(),
          icon: const Icon(Icons.refresh),
          label: const Text('Проверить состояние на сервере'),
        ),
      ],
    ),
  );

  Widget _overview(WorkOrder order) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFD8E0E9)),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _tag(_status(order.status), _blue),
            if (order.data['queue_position'] is num)
              _tag(
                (order.data['queue_position'] as num).toInt() == 1
                    ? 'Следующий к началу'
                    : 'Очередь · место ${order.data['queue_position']}',
                app_ui.navy,
              ),
            if (order.pendingSync || widget.controller.isOrderPending(order.id))
              _tag('Ожидает синхронизации', const Color(0xFF8C5A00)),
            _tag(
              _priority(order.priority),
              order.priority == 'emergency' ? _red : const Color(0xFF5B6575),
            ),
            if (order.isOverdue) _tag('Просрочен', _red),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          order.title,
          style: const TextStyle(
            fontSize: 24,
            height: 1.2,
            fontWeight: FontWeight.w800,
            color: Color(0xFF15283E),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          order.equipmentName,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          order.workType == 'planned'
              ? 'Плановая работа'
              : 'Внеплановый ремонт',
          style: const TextStyle(color: Color(0xFF64748B)),
        ),
        if ({'completed', 'ai_review'}.contains(order.status)) ...[
          const Divider(height: 28),
          Text(
            order.pendingSync || widget.controller.isOrderPending(order.id)
                ? 'Отчёт сохранён на устройстве. Сервер ещё не подтвердил сдачу.'
                : 'Работы сданы. Окончательное решение принимает мастер.',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
        if (order.score != null) ...[
          const SizedBox(height: 12),
          Text(
            order.pendingSync || widget.controller.isOrderPending(order.id)
                ? 'Выбранная оценка: ${_number(order.score)} / 5 · ожидает подтверждения сервера'
                : 'Итоговая оценка мастера: ${_number(order.score)} / 5',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ],
    ),
  );

  Widget _emergencyResponse(WorkOrder order) {
    final pending =
        order.pendingSync || widget.controller.isOrderPending(order.id);
    final responsible =
        widget.controller.user?.isWorker == true &&
        order.isResponsible(widget.controller.user?.id);
    final responsePending = widget.controller.outbox.any(
      (command) =>
          command.kind == OutboxKind.transition &&
          (command.orderId == order.id || command.localRef == '${order.id}') &&
          {'accept', 'queue', 'reject'}.contains(command.payload['action']),
    );
    final waitingResponse = {'issued', 'rework'}.contains(order.status);
    String message;
    if (!_detailRead && widget.notificationEntry) {
      message =
          'Проверяем доступ и текущее состояние наряда на сервере. '
          'Уведомление само по себе не подтверждает назначение.';
    } else if (responsePending) {
      message =
          'Рабочий ответ сохранён на устройстве. Сервер ещё не подтвердил '
          'его результат. Ожидающая отправка и конфликт разбираются в очереди.';
    } else if (pending) {
      message =
          'Есть изменения без подтверждения сервера. Показанное состояние '
          'может включать локальные действия; проверьте очередь.';
    } else if (waitingResponse && responsible) {
      if (order.status == 'rework') {
        message = _hasOtherOpenOrder(order)
            ? 'Требуется ваш рабочий ответ. У вас уже есть незавершённое задание: '
                  'поставьте доработку в очередь.'
            : 'Требуется ваш рабочий ответ: примите доработку или поставьте её '
                  'в очередь.';
      } else {
        message = _hasOtherOpenOrder(order)
            ? 'Требуется ваш рабочий ответ. У вас уже есть незавершённое задание: '
                  'поставьте этот наряд в очередь или отклоните с причиной.'
            : 'Требуется ваш рабочий ответ: примите задание, поставьте в очередь '
                  'или отклоните с причиной.';
      }
    } else if (waitingResponse && widget.controller.user?.isWorker == true) {
      message = order.hasParticipant(widget.controller.user?.id)
          ? 'Вы участник бригады. Рабочий ответ и переходы выполняет '
                'ответственный: ${order.assigneeName}.'
          : 'Вы больше не ответственный за этот наряд. Рабочие действия '
                'для вас недоступны.';
    } else if ({
      'accepted',
      'queued',
      'in_progress',
      'paused',
    }.contains(order.status)) {
      message = widget.controller.offline
          ? 'Показано последнее полученное состояние: ${_status(order.status)}. '
                'Текущее состояние на сервере без связи не проверено.'
          : 'Последнее подтверждённое состояние: ${_status(order.status)}. '
                'Следующее рабочее действие выбирается отдельно.';
    } else if ({'closed', 'cancelled', 'rejected'}.contains(order.status)) {
      message =
          'Наряд ${_status(order.status).toLowerCase()}. '
          'Принять или начать его из уведомления нельзя.';
    } else {
      message =
          'Аварийный приоритет сохранён. '
          'Текущее состояние: ${_status(order.status)}.';
    }
    return Container(
      key: const ValueKey('emergency-response'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F1),
        border: Border.all(color: const Color(0xFFEFC2C4)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: _red),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Аварийный наряд',
                  style: TextStyle(color: _red, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(message, style: const TextStyle(height: 1.4)),
          if (widget.controller.offline && waitingResponse && !pending) ...[
            const SizedBox(height: 8),
            const Text(
              'Нет связи. Ответ будет сохранён в локальную очередь и не '
              'считается принятым сервером до подтверждения.',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
          if (waitingResponse || pending) ...[
            const SizedBox(height: 8),
            const Text(
              'Открытие и прочтение уведомления не принимают наряд и не '
              'останавливают эскалацию непринятого задания.',
              style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 16),
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFDDE3EB)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            color: Color(0xFF15283E),
          ),
        ),
        const SizedBox(height: 14),
        ...children,
      ],
    ),
  );

  Widget _row(String label, String value, {bool danger = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 13, color: Color(0xFF64748B)),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 16,
            color: danger ? _red : const Color(0xFF192E43),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _tag(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w700),
    ),
  );

  Widget _photos(WorkOrder order) {
    final photos = _maps(order.data['photos']);
    return _section('Фотографии до и после', [
      if (photos.isEmpty)
        const Text(
          'Фотографии ещё не добавлены.',
          style: TextStyle(color: Color(0xFF64748B)),
        )
      else
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final kind in ['before', 'after']) ...[
              if (kind == 'after') const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      kind == 'before' ? 'До ремонта' : 'После ремонта',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    if (!photos.any((photo) => photo['kind'] == kind))
                      const Text(
                        'Нет фото',
                        style: TextStyle(
                          fontSize: 14,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ...photos
                        .where((photo) => photo['kind'] == kind)
                        .map(
                          (photo) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                OrderPhoto(
                                  key: ValueKey(photo['id']),
                                  controller: widget.controller,
                                  photo: photo,
                                  height: 145,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${photo['author_name'] ?? 'Автор не зафиксирован'} · ${_date(photo['created_at'])}',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Color(0xFF64748B),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                  ],
                ),
              ),
            ],
          ],
        ),
      if (_canAddPhoto(order)) ...[
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final kind in ['before', 'after'])
              OutlinedButton.icon(
                onPressed: _writeBusy ? null : () => _addPhoto(kind),
                icon: const Icon(Icons.add_a_photo_outlined),
                label: Text(
                  kind == 'before' ? 'Добавить фото до' : 'Добавить фото после',
                ),
              ),
          ],
        ),
      ],
    ]);
  }

  Widget _report(WorkOrder order) {
    final report = Map<String, dynamic>.from(order.data['completion'] as Map);
    final faults = _maps(widget.controller.reference['fault_codes']);
    final fault = faults
        .where((row) => row['id'] == report['fault_code_id'])
        .firstOrNull;
    final materials = _maps(report['materials']);
    return _section('Отчёт исполнителя', [
      Text(
        (report['work_done'] ?? '').toString(),
        style: const TextStyle(fontSize: 17, height: 1.4),
      ),
      const SizedBox(height: 14),
      _row(
        'Шифр неисправности',
        fault == null
            ? '#${report['fault_code_id']}'
            : '${fault['code']} · ${fault['name']}',
      ),
      const Text(
        'Материалы за все сдачи',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      if (materials.isEmpty) const Text('Расход не указан'),
      ...materials.map(
        (row) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: Text(row['name'].toString())),
              const SizedBox(width: 12),
              Text(
                '${_number(row['quantity'])} ${row['unit']}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
      if ((report['comment'] ?? '').toString().isNotEmpty) ...[
        const SizedBox(height: 8),
        _row('Комментарий исполнителя', report['comment'].toString()),
      ],
    ]);
  }

  Widget _review(WorkOrder order) {
    final review = Map<String, dynamic>.from(order.data['ai_review'] as Map);
    return _section(aiReviewTitle(review, job: order.aiReviewJob), [
      Text(
        aiReviewVerdict(review),
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(aiReviewScoreLabel(review['score'])),
      const SizedBox(height: 8),
      if (aiReviewSource(review) != null) ...[
        Text(aiReviewSource(review)!),
        const SizedBox(height: 8),
      ],
      Text(
        (review['explanation'] ??
                'Объяснение отсутствует. Требуется проверка мастера.')
            .toString(),
        style: const TextStyle(height: 1.4),
      ),
      AiPhotoCheck(check: review['photo_check']),
      const Divider(height: 24),
      Text(
        aiReviewNote(review, job: order.aiReviewJob),
        style: const TextStyle(fontSize: 14, color: Color(0xFF64748B)),
      ),
    ]);
  }

  Widget _history(WorkOrder order) {
    final events = _maps(order.data['events']).reversed.toList();
    return _section('История наряда', [
      if (events.isEmpty) const Text('Событий пока нет.'),
      ...events.map(
        (event) => Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Icon(Icons.circle, color: _blue, size: 10),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _event(event['action'].toString()),
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Text(
                      '${event['actor_name']} · ${_date(event['created_at'])}',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    if ((event['comment'] ?? '').toString().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          event['comment'].toString(),
                          style: const TextStyle(fontSize: 14),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ]);
  }

  Widget? _actions(WorkOrder order) {
    if (!_canWrite ||
        (!_canExecute && !(_master && order.status == 'ai_review')) ||
        {
          'closed',
          'cancelled',
          'rejected',
          'completed',
        }.contains(order.status)) {
      return null;
    }
    String? primary;
    VoidCallback? action;
    final secondary = <Widget>[];
    final hasOtherOpenOrder = _hasOtherOpenOrder(order);
    final queuePosition = (order.data['queue_position'] as num?)?.toInt();
    final startBlocked =
        _hasOtherExecutingOrder(order) ||
        (queuePosition != null && queuePosition > 1);
    if (order.status == 'ai_review') {
      if (!_master) return null;
      primary = 'Принять работу';
      action = _closeOrder;
      secondary.add(
        OutlinedButton(
          onPressed: _writeBusy
              ? null
              : () => _reason('rework', 'Вернуть на доработку'),
          child: const Text('На доработку'),
        ),
      );
    } else if (order.status == 'issued') {
      if (hasOtherOpenOrder) {
        primary = 'В очередь';
        action = () => _act('queue');
      } else {
        primary = 'Принять задание';
        action = () => _act('accept');
        secondary.add(
          OutlinedButton(
            onPressed: _writeBusy ? null : () => _act('queue'),
            child: const Text('В очередь'),
          ),
        );
      }
    } else if (order.status == 'rework') {
      if (hasOtherOpenOrder) {
        primary = 'В очередь';
        action = () => _act('queue');
      } else {
        primary = 'Принять доработку';
        action = () => _act('accept');
        secondary.add(
          OutlinedButton(
            onPressed: _writeBusy ? null : () => _act('queue'),
            child: const Text('В очередь'),
          ),
        );
      }
    } else if ({'accepted', 'queued'}.contains(order.status)) {
      primary = 'Начать исполнение';
      action = () => _act('start');
      if (order.status == 'accepted') {
        secondary.add(
          OutlinedButton(
            onPressed: _writeBusy ? null : () => _act('queue'),
            child: const Text('В очередь'),
          ),
        );
      }
    } else if (order.status == 'in_progress') {
      primary = 'Исполнено · заполнить отчёт';
      action = _complete;
      secondary.add(
        OutlinedButton(
          onPressed: _writeBusy
              ? null
              : () => _reason('pause', 'Приостановить'),
          child: const Text('Приостановить'),
        ),
      );
    } else if (order.status == 'paused') {
      primary = 'Продолжить работу';
      action = () => _act('resume');
    }
    if ({'issued', 'accepted', 'queued'}.contains(order.status)) {
      secondary.add(
        TextButton(
          onPressed: _writeBusy
              ? null
              : () => _reason('reject', 'Отклонить задание'),
          child: const Text('Отклонить'),
        ),
      );
    }
    if (primary == null) return null;
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: const BoxDecoration(
          color: Colors.white,
          border: Border(top: BorderSide(color: Color(0xFFDDE3EB))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size(double.infinity, 56),
                backgroundColor: _blue,
              ),
              onPressed:
                  _writeBusy ||
                      (primary == 'Начать исполнение' && startBlocked) ||
                      (primary == 'Продолжить работу' &&
                          _hasOtherInProgressOrder(order))
                  ? null
                  : action,
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(primary, textAlign: TextAlign.center),
            ),
            if (secondary.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  for (var i = 0; i < secondary.length; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(child: SizedBox(height: 52, child: secondary[i])),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

List<Json> _maps(dynamic value) => value is List
    ? value
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList()
    : [];
String _number(dynamic value) {
  final number = value is num ? value : num.tryParse('$value');
  return number == null
      ? '—'
      : number == number.roundToDouble()
      ? number.toInt().toString()
      : number.toStringAsFixed(1);
}

String _time(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
String _date(dynamic value) {
  final instant = DateTime.tryParse('$value');
  if (instant == null) return '—';
  final parsed = app_ui.plantTime(instant);
  return '${parsed.day.toString().padLeft(2, '0')}.${parsed.month.toString().padLeft(2, '0')}.${parsed.year} ${_time(parsed)}';
}

String? _elapsed(WorkOrder order) {
  final start = DateTime.tryParse('${order.data['started_at']}');
  final end = DateTime.tryParse('${order.data['completed_at']}');
  if (start == null || end == null) return null;
  return '${_number(end.difference(start).inMinutes / 60)} ч, включая паузы';
}

String _status(String value) => app_ui.statuses[value] ?? value;
String _priority(String value) =>
    const {
      'emergency': 'Аварийный',
      'high': 'Высокий',
      'normal': 'Обычный',
      'planned': 'Плановый',
    }[value] ??
    value;
String _event(String value) =>
    const {
      'issue': 'Наряд выдан',
      'edit': 'Изменён мастером',
      'accept': 'Задание принято',
      'queue': 'Поставлен в очередь',
      'reject': 'Задание отклонено',
      'start': 'Начато исполнение',
      'pause': 'Работа приостановлена',
      'resume': 'Работа продолжена',
      'complete': 'Отчёт отправлен',
      'ai_review': 'Отчёт проверен',
      'close': 'Работа принята мастером',
      'rework': 'Возвращён на доработку',
      'cancel': 'Наряд отменён',
      'photo': 'Добавлена фотография',
      'seed_state': 'Демонстрационное состояние',
    }[value] ??
    value;
