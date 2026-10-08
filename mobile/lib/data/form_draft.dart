import 'dart:convert';

import 'local_store.dart';
import 'models.dart';

abstract final class FormDraftKind {
  static const create = 'create';
  static const completion = 'completion';
}

abstract final class FormDraftState {
  static const editing = 'editing';
  static const submitting = 'submitting';
  static const uncertain = 'uncertain';
}

// Text, selections and compressed media belong to the draft, never the cache.
// JSON snapshots also keep an awaited disk write independent of later UI edits.
class FormDraft {
  FormDraft({
    required this.kind,
    required Json data,
    this.orderId,
    this.basis,
    this.state = FormDraftState.editing,
    DateTime? updatedAt,
  }) : data = jsonDecode(jsonEncode(data)) as Json,
       updatedAt = updatedAt ?? DateTime.now() {
    if (!const {
          FormDraftKind.create,
          FormDraftKind.completion,
        }.contains(kind) ||
        (kind == FormDraftKind.create && orderId != null) ||
        (kind == FormDraftKind.completion && orderId == null) ||
        !const {
          FormDraftState.editing,
          FormDraftState.submitting,
          FormDraftState.uncertain,
        }.contains(state)) {
      throw const FormatException('Недопустимый контекст черновика.');
    }
    if (basis != null &&
        !((basis!.expectedVersion == null &&
                basis!.previousCommandId == null) ||
            (basis!.expectedVersion != null &&
                basis!.expectedVersion! > 0 &&
                basis!.previousCommandId == null) ||
            (basis!.expectedVersion == null &&
                basis!.previousCommandId != null &&
                RegExp(r'^[A-Za-z0-9._:-]{8,64}$')
                    .hasMatch(basis!.previousCommandId!)))) {
      throw const FormatException('Основание черновика повреждено.');
    }
  }

  factory FormDraft.fromJson(Json json) {
    if (json['schema'] != 1 ||
        json['data'] is! Map ||
        json['updated_at'] is! int) {
      throw const FormatException('Не удалось прочитать сохранённый черновик.');
    }
    final basis = json['basis'];
    if (basis != null && basis is! Map) {
      throw const FormatException('Основание черновика повреждено.');
    }
    return FormDraft(
      kind: json['kind'] as String,
      orderId: json['order_id'] as int?,
      data: Map<String, dynamic>.from(json['data'] as Map),
      basis: basis == null
          ? null
          : OrderWriteBasis(
              expectedVersion: basis['expected_version'] as int?,
              previousCommandId: basis['previous_command_id'] as String?,
            ),
      state: json['state'] as String,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(json['updated_at'] as int),
    );
  }

  final String kind;
  final int? orderId;
  final Json data;
  final OrderWriteBasis? basis;
  final String state;
  final DateTime updatedAt;

  bool get submissionUncertain => state != FormDraftState.editing;

  Json toJson() => {
    'schema': 1,
    'kind': kind,
    'order_id': orderId,
    'data': data,
    'state': state,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'basis': basis == null
        ? null
        : {
            'expected_version': basis!.expectedVersion,
            'previous_command_id': basis!.previousCommandId,
          },
  };

  FormDraft copyWith({
    Json? data,
    OrderWriteBasis? basis,
    String? state,
    DateTime? updatedAt,
  }) => FormDraft(
    kind: kind,
    orderId: orderId,
    data: data ?? this.data,
    basis: basis ?? this.basis,
    state: state ?? this.state,
    updatedAt: updatedAt ?? DateTime.now(),
  );
}

// A handle captures its owner/API/session and is invalid after removal or after
// a replacement handle is opened. Delayed autosaves cannot resurrect a draft.
class FormDraftSession {
  FormDraftSession(this._read, this._save, this._delete);

  final Future<FormDraft?> Function() _read;
  final Future<void> Function(FormDraft, bool) _save;
  final Future<void> Function() _delete;
  bool _closed = false;

  void _ensureOpen() {
    if (_closed) throw StateError('Черновик уже закрыт.');
  }

  Future<FormDraft?> read() {
    _ensureOpen();
    return _read();
  }

  Future<void> save(FormDraft draft, {bool acknowledgeSubmission = false}) {
    _ensureOpen();
    return _save(FormDraft.fromJson(draft.toJson()), acknowledgeSubmission);
  }

  Future<void> delete() async {
    _ensureOpen();
    _closed = true;
    try {
      await _delete();
    } catch (_) {
      _closed = false;
      rethrow;
    }
  }
}
