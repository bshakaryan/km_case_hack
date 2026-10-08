import 'dart:typed_data';

import 'local_store.dart';
import 'models.dart';

enum QueueRecoveryStatus {
  success,
  notFound,
  notRetryable,
  busy,
  scopeChanged,
  storageFailure,
  changed,
}

class QueueActionResult {
  QueueActionResult(
    this.status,
    this.message, {
    this.changed = false,
    this.warning,
    List<String> commandIds = const [],
  }) : commandIds = List.unmodifiable(commandIds);

  final QueueRecoveryStatus status;
  final String message;
  // A durable local commit, not confirmation of an HTTP write or its reversal.
  final bool changed;
  final String? warning;
  final List<String> commandIds;
}

class QueueCommandInspectionResult {
  const QueueCommandInspectionResult(
    this.status,
    this.message, {
    this.inspection,
  });

  final QueueRecoveryStatus status;
  final String message;
  final QueueCommandInspection? inspection;
}

class QueueCommandInspection {
  QueueCommandInspection({
    required OutboxCommand command,
    required List<OutboxCommand> dependentCommands,
    required Map<String, Uint8List> preparedPhotoBytesByCommandId,
    required Map<String, String> mediaWarnings,
    List<OutboxCommand> retainedPhotoCommands = const [],
    WorkOrder? cachedOrder,
  }) : command = _freezeCommand(command),
       dependentCommands = List.unmodifiable(
         dependentCommands.map(_freezeCommand),
       ),
       preparedPhotoBytesByCommandId = Map.unmodifiable(
         preparedPhotoBytesByCommandId.map(
           (key, bytes) =>
               MapEntry(key, Uint8List.fromList(bytes).asUnmodifiableView()),
         ),
       ),
       mediaWarnings = Map.unmodifiable(mediaWarnings),
       retainedPhotoCommands = List.unmodifiable(
         retainedPhotoCommands.map(_freezeCommand),
       ),
       cachedOrder = cachedOrder == null
           ? null
           : WorkOrder.fromJson(freezeRecoveryJson(cachedOrder.data));

  final OutboxCommand command;
  final List<OutboxCommand> dependentCommands;
  final Map<String, Uint8List> preparedPhotoBytesByCommandId;
  final Map<String, String> mediaWarnings;
  // Includes still-queued earlier photos in this lane; not deletion targets.
  final List<OutboxCommand> retainedPhotoCommands;
  // Context only: a cached server snapshot, never a refreshed write basis.
  final WorkOrder? cachedOrder;

  List<String> get commandIds => List.unmodifiable([
    command.commandId,
    ...dependentCommands.map((item) => item.commandId),
  ]);
}

Json freezeRecoveryJson(Json value) => Map<String, dynamic>.unmodifiable(
  value.map((key, item) => MapEntry(key, _freezeValue(item))),
);

Object? _freezeValue(Object? value) {
  if (value is Map) {
    return Map<String, dynamic>.unmodifiable(
      value.map((key, item) => MapEntry(key as String, _freezeValue(item))),
    );
  }
  if (value is List) return List.unmodifiable(value.map(_freezeValue));
  return value;
}

OutboxCommand _freezeCommand(OutboxCommand command) =>
    OutboxCommand.fromJson(freezeRecoveryJson(command.toJson()));
