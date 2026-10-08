import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

// Length-safe, collision-free namespaces include the complete normalized API
// address, not just its host. Legacy unscoped keys are deliberately not read.
String localScopeKey(String serverUrl, int ownerId, String key) =>
    'v2:${base64Url.encode(utf8.encode(serverUrl))}:$ownerId:$key';

abstract final class SnapshotKeys {
  static const profile = 'profile';
  static const orders = 'orders';
  static const reference = 'reference';
  static const employees = 'employees';
  static const dashboard = 'dashboard';
  static const notifications = 'notifications';
  static const analytics = 'analytics';

  static const all = <String>[
    profile,
    orders,
    reference,
    employees,
    dashboard,
    notifications,
    analytics,
  ];
}

abstract final class OutboxKind {
  static const createOrder = 'order_create';
  static const transition = 'transition';
  static const complete = 'complete';
  static const uploadPhoto = 'photo_upload';
  static const markRead = 'mark_read';
}

abstract final class OutboxState {
  static const pending = 'pending';
  static const running = 'running';
  static const conflict = 'conflict';
}

class SnapshotEntry {
  const SnapshotEntry(this.data, this.updatedAt);

  final Object? data;
  final DateTime updatedAt;
}

// The form captures this before editing. Reads must never replace its basis.
class OrderWriteBasis {
  const OrderWriteBasis({this.expectedVersion, this.previousCommandId});
  final int? expectedVersion;
  final String? previousCommandId;
}

class OutboxCommand {
  const OutboxCommand({
    required this.commandId,
    required this.kind,
    required this.createdAt,
    this.ownerId,
    this.serverUrl,
    this.orderId,
    this.localRef,
    this.expectedVersion,
    this.previousCommandId,
    this.payload = const {},
    this.photoPath,
    this.photoFilename,
    this.photoKind,
    this.attempts = 0,
    this.state = OutboxState.pending,
    this.responseStatus,
    this.response,
    this.lastError,
  });

  factory OutboxCommand.fromJson(Json json) => OutboxCommand(
    commandId: json['command_id'] as String,
    kind: json['kind'] as String,
    createdAt: (json['created_at'] as num).toInt(),
    ownerId: (json['owner_id'] as num?)?.toInt(),
    serverUrl: json['server_url'] as String?,
    orderId: (json['order_id'] as num?)?.toInt(),
    localRef: json['local_ref'] as String?,
    expectedVersion: json['expected_version'] is int
        ? json['expected_version'] as int
        : null,
    previousCommandId: json['previous_command_id'] as String?,
    payload: (json['payload'] as Json?) ?? const {},
    photoPath: json['photo_path'] as String?,
    photoFilename: json['photo_filename'] as String?,
    photoKind: json['photo_kind'] as String?,
    attempts: (json['attempts'] as num?)?.toInt() ?? 0,
    state: json['state'] as String? ?? OutboxState.pending,
    responseStatus: (json['response_status'] as num?)?.toInt(),
    response: json['response'] as Json?,
    lastError: json['last_error'] as String?,
  );

  static const _undefined = Object();

  final String commandId;
  final String kind;
  final int createdAt;
  final int? ownerId;
  final String? serverUrl;
  final int? orderId;
  final String? localRef;
  final int? expectedVersion;
  final String? previousCommandId;
  final Json payload;
  final String? photoPath;
  final String? photoFilename;
  final String? photoKind;
  final int attempts;
  final String state;
  final int? responseStatus;
  final Json? response;
  final String? lastError;

  bool get hasOrderPrecondition =>
      kind == OutboxKind.createOrder ||
      kind == OutboxKind.markRead ||
      (expectedVersion != null &&
          expectedVersion! >= 1 &&
          previousCommandId == null) ||
      (expectedVersion == null &&
          previousCommandId != null &&
          RegExp(r'^[A-Za-z0-9._:-]{8,64}$').hasMatch(previousCommandId!));

  bool get canRetry =>
      hasOrderPrecondition &&
      !const {
        'order_version_conflict',
        'order_precondition_unavailable',
        'local_order_precondition_unavailable',
      }.contains(response?['code']);

  Json toJson() => <String, dynamic>{
    'command_id': commandId,
    'kind': kind,
    'created_at': createdAt,
    'owner_id': ownerId,
    'server_url': serverUrl,
    'order_id': orderId,
    'local_ref': localRef,
    'expected_version': expectedVersion,
    'previous_command_id': previousCommandId,
    'payload': payload,
    'photo_path': photoPath,
    'photo_filename': photoFilename,
    'photo_kind': photoKind,
    'attempts': attempts,
    'state': state,
    'response_status': responseStatus,
    'response': response,
    'last_error': lastError,
  };

  OutboxCommand copyWith({
    Object? orderId = _undefined,
    Object? attempts = _undefined,
    Object? state = _undefined,
    Object? responseStatus = _undefined,
    Object? response = _undefined,
    Object? lastError = _undefined,
    Object? photoPath = _undefined,
  }) => OutboxCommand(
    commandId: commandId,
    kind: kind,
    createdAt: createdAt,
    ownerId: ownerId,
    serverUrl: serverUrl,
    orderId: identical(orderId, _undefined) ? this.orderId : orderId as int?,
    localRef: localRef,
    expectedVersion: expectedVersion,
    previousCommandId: previousCommandId,
    payload: payload,
    photoPath: identical(photoPath, _undefined)
        ? this.photoPath
        : photoPath as String?,
    photoFilename: photoFilename,
    photoKind: photoKind,
    attempts: identical(attempts, _undefined) ? this.attempts : attempts as int,
    state: identical(state, _undefined) ? this.state : state as String,
    responseStatus: identical(responseStatus, _undefined)
        ? this.responseStatus
        : responseStatus as int?,
    response: identical(response, _undefined)
        ? this.response
        : response as Json?,
    lastError: identical(lastError, _undefined)
        ? this.lastError
        : lastError as String?,
  );
}

const int maxPhotoCacheBytes = 50 * 1024 * 1024;

abstract class LocalStore {
  Future<void> open();
  Future<void> close();

  Future<void> putSnapshot(
    String key,
    Object? data, {
    required DateTime updatedAt,
  });
  Future<SnapshotEntry?> getSnapshot(String key);
  Future<void> clearSnapshots({String? prefix});

  Future<OutboxCommand> enqueue(OutboxCommand command, {Uint8List? photoBytes});
  Future<List<OutboxCommand>> outbox();
  Future<void> updateOutbox(OutboxCommand command);
  Future<void> removeOutbox(String commandId);
  Future<Uint8List?> outboxPhoto(String commandId);
  Future<void> resetRunningOutbox();

  Future<void> putServerId(String localRef, int serverId);
  Future<int?> serverId(String localRef);
  Future<void> removeServerId(String localRef);

  Future<void> putPhoto(String url, Uint8List bytes);
  Future<Uint8List?> getPhoto(String url);
  Future<void> clearPhotos({String? prefix});
  Future<int> photoCacheBytes();
}

class MemoryLocalStore implements LocalStore {
  final Map<String, SnapshotEntry> _snapshots = {};
  final Map<String, Json> _outbox = {};
  final Map<String, int> _serverIds = {};
  final Map<String, Uint8List> _photos = {};

  @override
  Future<void> open() async {
    await resetRunningOutbox();
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> putSnapshot(
    String key,
    Object? data, {
    required DateTime updatedAt,
  }) async {
    _snapshots[key] = SnapshotEntry(data, updatedAt);
  }

  @override
  Future<SnapshotEntry?> getSnapshot(String key) async => _snapshots[key];

  @override
  Future<void> clearSnapshots({String? prefix}) async {
    _snapshots.removeWhere(
      (key, _) => prefix == null || key.startsWith(prefix),
    );
  }

  @override
  Future<OutboxCommand> enqueue(
    OutboxCommand command, {
    Uint8List? photoBytes,
  }) async {
    if (photoBytes != null) {
      _photos['outbox:${command.commandId}'] = photoBytes;
    }
    _outbox[command.commandId] = command.toJson();
    return command;
  }

  @override
  Future<List<OutboxCommand>> outbox() async =>
      _outbox.values.map(OutboxCommand.fromJson).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  @override
  Future<void> updateOutbox(OutboxCommand command) async {
    if (_outbox.containsKey(command.commandId)) {
      _outbox[command.commandId] = command.toJson();
    }
  }

  @override
  Future<void> removeOutbox(String commandId) async {
    _outbox.remove(commandId);
    _photos.remove('outbox:$commandId');
  }

  @override
  Future<Uint8List?> outboxPhoto(String commandId) async =>
      _photos['outbox:$commandId'];

  @override
  Future<void> resetRunningOutbox() async {
    for (final command in _outbox.values) {
      if (command['server_url'] == null || command['owner_id'] == null) {
        command['state'] = OutboxState.conflict;
        command['last_error'] = 'Старая команда без подтверждённого сервера и аккаунта изолирована.';
      } else if (!OutboxCommand.fromJson(command).hasOrderPrecondition) {
        command['state'] = OutboxState.conflict;
        command['response'] = {'code': 'local_order_precondition_unavailable'};
        command['last_error'] = 'Версия наряда для этого действия неизвестна. Текст и фото сохранены. Обновите наряд и создайте действие заново; удаление этой команды не отменяет уже сохранённое сервером действие.';
      } else if (command['state'] == OutboxState.running) {
        command['state'] = OutboxState.pending;
      }
    }
  }

  @override
  Future<void> putServerId(String localRef, int serverId) async {
    _serverIds[localRef] = serverId;
  }

  @override
  Future<int?> serverId(String localRef) async => _serverIds[localRef];

  @override
  Future<void> removeServerId(String localRef) async {
    _serverIds.remove(localRef);
  }

  @override
  Future<void> putPhoto(String url, Uint8List bytes) async {
    _photos[url] = bytes;
    var total = 0;
    final keys = _photos.keys.where((key) => !key.startsWith('outbox:'));
    final entries = <String, int>{};
    for (final key in keys) {
      entries[key] = _photos[key]!.length;
      total += _photos[key]!.length;
    }
    if (total <= maxPhotoCacheBytes) return;
    final entriesInOrder = entries.entries.toList();
    for (final entry in entriesInOrder) {
      if (total <= maxPhotoCacheBytes) break;
      total -= entry.value;
      _photos.remove(entry.key);
    }
  }

  @override
  Future<Uint8List?> getPhoto(String url) async => _photos[url];

  @override
  Future<void> clearPhotos({String? prefix}) async {
    _photos.removeWhere(
      (key, _) =>
          !key.startsWith('outbox:') &&
          (prefix == null || key.startsWith(prefix)),
    );
  }

  @override
  Future<int> photoCacheBytes() async {
    var total = 0;
    _photos.forEach((key, value) {
      if (!key.startsWith('outbox:')) total += value.length;
    });
    return total;
  }
}
