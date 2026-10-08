import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/api.dart';
import '../data/app_controller.dart';
import '../data/local_store.dart';
import '../data/recovery_models.dart';
import '../ui.dart';

/// Protected recovery views capture their source before any storage await.
class RecoveryScope {
  RecoveryScope(AppController controller)
    : api = controller.api,
      token = controller.api.token,
      ownerId = controller.user?.id,
      role = controller.user?.role,
      ownerName = controller.user?.name ?? '';

  final NaryadApi api;
  final String? token, role;
  final int? ownerId;
  final String ownerName;

  bool matches(AppController controller) =>
      ownerId != null &&
      identical(controller.api, api) &&
      controller.api.token == token &&
      controller.user?.id == ownerId &&
      controller.user?.role == role;

  bool owns(OutboxCommand command) =>
      command.ownerId == ownerId && command.serverUrl == api.baseUrl;
}

/// Remove this protected route and its confirmation/inspection descendants.
/// The first route is kept for isolated widget hosts, but its data is hidden.
void closeRecoveryRoute(BuildContext context, ModalRoute<dynamic>? route) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted || route?.isActive != true || route!.isFirst) return;
    final navigator = Navigator.of(context);
    navigator.popUntil((item) => identical(item, route) || item.isFirst);
    if (route.isActive) navigator.removeRoute(route);
  });
}

String retainedCommandText(OutboxCommand command, AppController controller) {
  final lines = <String>[];
  const fields = {
    'title': 'Задача',
    'description': 'Описание',
    'work_done': 'Выполненные работы',
    'reason': 'Причина',
    'comment': 'Комментарий',
    'fault_code_id': 'Шифр неисправности',
    'action': 'Действие',
    'deadline': 'Срок',
    'score': 'Выбранная оценка',
  };
  for (final entry in fields.entries) {
    final value = command.payload[entry.key];
    if (value != null && '$value'.isNotEmpty) {
      lines.add('${entry.value}: $value');
    }
  }
  final materials = command.payload['materials'];
  if (materials is List && materials.isNotEmpty) {
    lines.add('Материалы этой команды:');
    final reference = controller.reference['materials'];
    for (final item in materials.whereType<Map>()) {
      final id = item['material_id'];
      Map? known;
      if (reference is List) {
        known = reference
            .whereType<Map>()
            .where((row) => row['id'] == id)
            .firstOrNull;
      }
      final name = item['name'] ?? known?['name'] ?? 'Материал #$id';
      final unit = item['unit'] ?? known?['unit'] ?? '';
      lines.add('$name · ${item['quantity'] ?? 'не сохранено'} $unit');
    }
  }
  return lines.join('\n');
}

String recoveryCommandStatus(OutboxCommand command) {
  final code = command.response?['code'];
  if (!command.hasOrderPrecondition ||
      code == 'order_precondition_unavailable' ||
      code == 'local_order_precondition_unavailable') {
    return 'Основание действия неизвестно';
  }
  if (code == 'order_version_conflict') return 'Конфликт версии';
  if (command.state == OutboxState.running) return 'Отправка выполняется';
  final status = command.responseStatus;
  final definiteRejection =
      status != null && status >= 400 && status < 500 && status != 408;
  if (command.state == OutboxState.conflict) {
    return definiteRejection
        ? 'Команда отклонена'
        : 'Результат отправки неизвестен';
  }
  if (status == 0 ||
      (status != null && status >= 500) ||
      (!definiteRejection &&
          (command.lastError != null || command.attempts > 0))) {
    return 'Результат предыдущей отправки не подтверждён';
  }
  return 'Ожидает отправки';
}

/// Storage errors can contain transport diagnostics. Keep credentials out of UI.
String recoveryMessage(String message, RecoveryScope scope) {
  var safe = message;
  if (scope.token?.isNotEmpty == true) {
    safe = safe.replaceAll(scope.token!, '[скрыто]');
  }
  return safe.replaceAll(RegExp(r'https?://\S+'), '[адрес сервера]');
}

class CommandInspectorScreen extends StatefulWidget {
  const CommandInspectorScreen({
    required this.controller,
    required this.commandId,
    required this.scope,
    required this.commandLabel,
    super.key,
  });
  final AppController controller;
  final String commandId;
  final RecoveryScope scope;
  final String Function(OutboxCommand) commandLabel;

  @override
  State<CommandInspectorScreen> createState() => _CommandInspectorScreenState();
}

class _CommandInspectorScreenState extends State<CommandInspectorScreen> {
  QueueCommandInspection? _inspection;
  String? _error;
  bool _loading = true, _copying = false, _revoked = false;
  ModalRoute<dynamic>? _route;

  bool get _current => !_revoked && widget.scope.matches(widget.controller);
  bool get _blocked =>
      _copying ||
      widget.controller.recoveringQueue ||
      widget.controller.syncing ||
      widget.controller.saving ||
      widget.controller.restoring;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _current) _load();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(CommandInspectorScreen oldWidget) {
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
    widget.controller.removeListener(_changed);
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

  Future<void> _load() async {
    try {
      final result = await widget.controller.inspectCommand(widget.commandId);
      if (!mounted) return;
      if (!_current || result.status == QueueRecoveryStatus.scopeChanged) {
        setState(() => _revoked = true);
        closeRecoveryRoute(context, _route);
        return;
      }
      final inspection = result.inspection;
      final commands = inspection == null
          ? <OutboxCommand>[]
          : [
              inspection.command,
              ...inspection.dependentCommands,
              ...inspection.retainedPhotoCommands,
            ];
      setState(() {
        _loading = false;
        if (result.status == QueueRecoveryStatus.success &&
            inspection != null &&
            commands.every(widget.scope.owns)) {
          _inspection = inspection;
        } else {
          _error = recoveryMessage(result.message, widget.scope);
        }
      });
    } catch (_) {
      if (!mounted || !_current) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось прочитать сохранённую команду. Данные очереди не изменены.';
      });
    }
  }

  Future<void> _copy() async {
    final inspection = _inspection;
    if (!_current || _blocked || inspection == null) return;
    final text = [inspection.command, ...inspection.dependentCommands]
        .map((command) {
          final body = retainedCommandText(command, widget.controller);
          return '${widget.commandLabel(command)}\n$body';
        })
        .join('\n\n');
    setState(() {
      _copying = true;
      _error = null;
    });
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted && _current) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Сохранённый текст скопирован')),
        );
      }
    } catch (_) {
      if (mounted && _current) {
        setState(
          () => _error = 'Не удалось скопировать текст. Он остаётся в очереди.',
        );
      }
    } finally {
      if (mounted && _current) setState(() => _copying = false);
    }
  }

  Widget _commandCard(
    OutboxCommand command,
    QueueCommandInspection inspection,
  ) {
    final text = retainedCommandText(command, widget.controller);
    final bytes = inspection.preparedPhotoBytesByCommandId[command.commandId];
    final warning = inspection.mediaWarnings[command.commandId];
    final isPhoto = command.kind == OutboxKind.uploadPhoto;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.commandLabel(command),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(recoveryCommandStatus(command)),
            const SizedBox(height: 8),
            Text('Автор: ${widget.scope.ownerName} · #${command.ownerId}'),
            if (command.orderId != null) Text('Наряд: #${command.orderId}'),
            Text(
              'Сохранено: ${dateLabel(DateTime.fromMillisecondsSinceEpoch(command.createdAt))}',
            ),
            SelectableText('Ключ команды: ${command.commandId}'),
            if (command.expectedVersion != null)
              Text('Зафиксированная версия: ${command.expectedVersion}'),
            if (command.previousCommandId != null)
              SelectableText('Основание: команда ${command.previousCommandId}'),
            if (text.isNotEmpty) ...[
              const SizedBox(height: 10),
              SelectableText(text),
            ],
            if (isPhoto) ...[
              const SizedBox(height: 10),
              Text(
                'Подготовленное фото: ${command.photoFilename ?? 'без имени'}',
              ),
              if (command.photoKind != null)
                Text(
                  'Тип: ${command.photoKind == 'before'
                      ? 'До работ'
                      : command.photoKind == 'after'
                      ? 'После работ'
                      : command.photoKind}',
                ),
              if (bytes != null)
                Image.memory(
                  bytes,
                  key: ValueKey('prepared-photo-${command.commandId}'),
                  fit: BoxFit.contain,
                  height: 220,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Text(
                    'Сохранённое фото не удалось показать. Текст и сведения команды доступны.',
                    style: TextStyle(color: danger),
                  ),
                )
              else
                const Text(
                  'Подготовленное фото недоступно. Текст и сведения команды сохранены.',
                  style: TextStyle(color: danger),
                ),
              if (warning != null)
                Text(
                  recoveryMessage(warning, widget.scope),
                  style: const TextStyle(color: danger),
                ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_current) return const SizedBox.shrink();
    final inspection = _inspection;
    final cached = inspection?.cachedOrder;
    final chainIds = inspection?.commandIds.toSet() ?? <String>{};
    final earlierPhotos =
        inspection?.retainedPhotoCommands
            .where((command) => !chainIds.contains(command.commandId))
            .toList() ??
        <OutboxCommand>[];
    return PopScope(
      canPop: !_copying,
      child: AlertDialog(
        title: const Text('Сохранённая команда'),
        content: SizedBox(
          width: double.maxFinite,
          child: _loading
              ? const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    const Text(
                      'Это локально сохранённые данные. Чтение очереди не подтверждает результат действия на сервере и не меняет основание отправки.',
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: danger),
                        ),
                      ),
                    if (cached != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          'Последнее состояние из кэша: ${cached.number} · ${statuses[cached.status] ?? cached.status}. Оно могло измениться.',
                        ),
                      ),
                    if (inspection != null) ...[
                      _commandCard(inspection.command, inspection),
                      if (inspection.dependentCommands.isNotEmpty)
                        const Text('Зависимые команды этой цепи'),
                      for (final command in inspection.dependentCommands)
                        _commandCard(command, inspection),
                      if (earlierPhotos.isNotEmpty)
                        const Text(
                          'Фото из предыдущих команд. Они не входят в выбранную цепь удаления.',
                        ),
                      for (final command in earlierPhotos)
                        _commandCard(command, inspection),
                    ],
                  ],
                ),
        ),
        actions: [
          if (inspection != null)
            TextButton.icon(
              onPressed: _blocked || _loading ? null : _copy,
              icon: const Icon(Icons.copy),
              label: const Text('Скопировать текст'),
            ),
          TextButton(
            onPressed: _copying ? null : () => Navigator.pop(context),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
  }
}
