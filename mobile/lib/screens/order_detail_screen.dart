import 'dart:async';

import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../data/api.dart';
import '../data/models.dart';
import '../ui.dart' as app_ui;
import '../widgets/order_photo.dart';
import '../widgets/order_history.dart';
import '../widgets/ai_job_status.dart';
import 'completion_screen.dart';

const _blue = Color(0xFF173E68);
const _red = Color(0xFFB4232D);

class OrderDetailScreen extends StatefulWidget {
  const OrderDetailScreen({
    super.key,
    required this.controller,
    required this.orderId,
  });
  final AppController controller;
  final int orderId;

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

  @override
  void initState() {
    super.initState();
    _seedFromCache();
    unawaited(_load());
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (widget.controller.offline) return;
      if (!_busy && mounted && (ModalRoute.of(context)?.isCurrent ?? false)) {
        unawaited(_load(silent: true));
      }
    });
  }

  void _seedFromCache() {
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
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (_fetching) return;
    final revision = _revision;
    _fetching = true;
    if (!silent && mounted) setState(() => _loading = _order == null);
    try {
      final order = await widget.controller.loadOrder(widget.orderId);
      if (!mounted || revision != _revision) return;
      setState(() {
        _order = order;
        _error = null;
        _updatedAt = DateTime.now();
        if (!widget.controller.offline) _aiRetryUncertain = false;
      });
    } catch (error) {
      if (mounted && revision == _revision) {
        setState(() => _error = error.toString());
      }
    } finally {
      _fetching = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _retryAiReview() async {
    final order = _order;
    if (_busy ||
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
      );
      if (!mounted) return;
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
      if (mounted) {
        setState(() {
          _error = failure.toString();
          _aiRetryUncertain =
              failure is! ApiException || failure.requestMayHaveSucceeded;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _master => widget.controller.user?.isMaster ?? false;
  bool get _canExecute =>
      (widget.controller.user?.isWorker ?? false) &&
      _order?.data['assignee_id'] == widget.controller.user?.id;

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

  Future<void> _act(String action, {String? reason, double? score}) async {
    if (_busy) return;
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
      );
      if (!mounted) return;
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
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reason(String action, String title) async {
    final controller = TextEditingController();
    final key = GlobalKey<FormState>();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
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
    if (result != null && mounted) await _act(action, reason: result);
  }

  Future<void> _closeOrder() async {
    double? selected;
    final score = await showDialog<double>(
      context: context,
      builder: (context) => StatefulBuilder(
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
    if (score != null && mounted) await _act('close', score: score);
  }

  Future<void> _complete() async {
    final order = _order;
    if (order == null) return;
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) =>
            CompletionScreen(controller: widget.controller, order: order),
      ),
    );
    if (mounted) {
      await _load();
      if (result == true && mounted) {
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
            onPressed: _busy ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
          if (order != null &&
              _master &&
              !{'closed', 'cancelled'}.contains(order.status))
            PopupMenuButton<String>(
              tooltip: 'Другие действия',
              enabled: !_busy,
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
                      onPressed: _load,
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
                    _row('Исполнитель', order.assigneeName),
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
                                  _date(photo['created_at']),
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
    final stub = review['is_stub'] == true;
    final verdict = switch (review['verdict']) {
      'passed' => 'Принято',
      'needs_attention' => 'Принято с замечаниями',
      'rework' || 'needs_rework' => 'Требует доработки',
      _ => 'Нужна проверка мастером',
    };
    return _section(stub ? 'Формальная проверка · демо' : 'Проверка ИИ', [
      Text(
        verdict,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      if (review['score'] != null)
        Text('Предварительная оценка: ${_number(review['score'])} / 5'),
      const SizedBox(height: 8),
      Text(
        (review['explanation'] ??
                'Объяснение отсутствует. Требуется проверка мастера.')
            .toString(),
        style: const TextStyle(height: 1.4),
      ),
      if (stub) ...[
        const Divider(height: 24),
        const Text(
          'Проверяется наличие фото. Содержимое снимков не анализируется; настоящий ИИ пока не подключён.',
          style: TextStyle(fontSize: 14, color: Color(0xFF64748B)),
        ),
      ],
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
    if ((!_canExecute && !(_master && order.status == 'ai_review')) ||
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
          onPressed: _busy
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
            onPressed: _busy ? null : () => _act('queue'),
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
            onPressed: _busy ? null : () => _act('queue'),
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
            onPressed: _busy ? null : () => _act('queue'),
            child: const Text('В очередь'),
          ),
        );
      }
    } else if (order.status == 'in_progress') {
      primary = 'Исполнено · заполнить отчёт';
      action = _complete;
      secondary.add(
        OutlinedButton(
          onPressed: _busy ? null : () => _reason('pause', 'Приостановить'),
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
          onPressed: _busy
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
                  _busy ||
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
