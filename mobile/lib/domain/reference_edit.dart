import '../data/models.dart';

enum ReferenceCollection { equipment, materials }

enum ReferenceEditState { editing, sending, saved, uncertain }

enum ReferenceMutationStatus {
  saved,
  rejected,
  uncertain,
  scopeChanged,
  busy,
  offline,
}

enum ReferenceRefreshStatus { refreshed, failed, scopeChanged }

class ReferenceEditError {
  const ReferenceEditError(
    this.message, {
    this.statusCode,
    this.fieldErrors = const {},
  });
  final String message;
  final int? statusCode;
  final Map<String, String> fieldErrors;
}

class ReferenceMutationResult {
  const ReferenceMutationResult(
    this.status, {
    this.row,
    this.error,
    this.mayHaveSucceeded = false,
  });
  final ReferenceMutationStatus status;
  final Json? row;
  final ReferenceEditError? error;
  final bool mayHaveSucceeded;
}

class ReferenceRefreshResult {
  const ReferenceRefreshResult(this.status, {this.error});
  final ReferenceRefreshStatus status;
  final ReferenceEditError? error;
}

class ReferenceEditScope {
  ReferenceEditScope(bool Function() current) : _current = current;
  final bool Function() _current;
  bool get isCurrent => _current();
}

class ReferenceValidationException implements Exception {
  ReferenceValidationException(this.fieldErrors);
  final Map<String, String> fieldErrors;
  String get message => fieldErrors.values.join('\n');
}

Map<String, int> _stringFields(ReferenceCollection collection) =>
    collection == ReferenceCollection.equipment
    ? {'name': 120, 'inventory_number': 80, 'type': 80, 'criticality': 40}
    : {'name': 180, 'unit': 30};

// Normalize the submitted fields, not existing unedited catalog values. The
// server validates its received strings and remains authoritative for Area/FK
// and unique inventory constraints. Length is Unicode codepoints, like Python.
Json validateReferenceValues(
  ReferenceCollection collection,
  Json values, {
  required bool create,
}) {
  final fields = _stringFields(collection);
  final allowed = {
    ...fields.keys,
    if (collection == ReferenceCollection.equipment) 'area_id',
  };
  final required = collection == ReferenceCollection.equipment
      ? {'name', 'inventory_number', 'area_id', 'type'}
      : {'name', 'unit'};
  final errors = <String, String>{};
  final clean = <String, dynamic>{};
  if (values.isEmpty) {
    errors['_form'] = 'Нет изменений для сохранения.';
  }
  if (values.keys.any((key) => !allowed.contains(key))) {
    errors['_form'] = 'Неизвестные поля или изменение id запрещены.';
  }
  if (create) {
    for (final field in required) {
      if (!values.containsKey(field)) {
        errors[field] = 'Заполните поле: $field.';
      }
    }
  }
  for (final entry in values.entries) {
    if (fields.containsKey(entry.key)) {
      final value = entry.value;
      if (value is! String ||
          value.trim().isEmpty ||
          value.trim().runes.length > fields[entry.key]!) {
        errors[entry.key] =
            'Поле ${entry.key}: от 1 до ${fields[entry.key]} символов.';
      } else {
        clean[entry.key] = value.trim();
      }
    } else if (entry.key == 'area_id') {
      if (entry.value is! int || (entry.value as int) <= 0) {
        errors[entry.key] = 'Выберите существующий участок.';
      } else {
        clean[entry.key] = entry.value;
      }
    }
  }
  if (errors.isNotEmpty) {
    throw ReferenceValidationException(Map.unmodifiable(errors));
  }
  return clean;
}

Json referenceChangedValues(
  ReferenceCollection collection,
  Json initial,
  Json edited,
) {
  final fields = {
    ..._stringFields(collection).keys,
    if (collection == ReferenceCollection.equipment) 'area_id',
  };
  return {
    for (final field in fields)
      if (edited.containsKey(field) && edited[field] != initial[field])
        field: edited[field],
  };
}

bool isCompleteReferenceRow(ReferenceCollection collection, Object? value) {
  if (value is! Json || value['id'] is! int || (value['id'] as int) <= 0) {
    return false;
  }
  final fields = collection == ReferenceCollection.equipment
      ? ['name', 'inventory_number', 'area_id', 'type', 'criticality']
      : ['name', 'unit'];
  if (fields.any((field) => !value.containsKey(field))) {
    return false;
  }
  try {
    validateReferenceValues(collection, {
      for (final field in fields) field: value[field],
    }, create: true);
    return true;
  } on ReferenceValidationException {
    return false;
  }
}

// A controller-owned, memory-only operation. Closing/reopening the editor or
// refreshing the catalog cannot turn an uncertain operation into a second POST.
class ReferenceEditTicket {
  factory ReferenceEditTicket({
    required ReferenceCollection collection,
    required int? id,
    required ReferenceEditScope scope,
    required Json initialValues,
    required ReferenceMutationResult? Function() preflight,
    required Future<ReferenceMutationResult> Function(Json) send,
    required void Function() changed,
  }) => ReferenceEditTicket._(
    collection,
    id,
    scope,
    initialValues,
    preflight,
    send,
    changed,
  );

  ReferenceEditTicket._(
    this.collection,
    this.id,
    this.scope,
    Json initialValues,
    this._preflight,
    this._send,
    this._changed,
  ) : initialValues = Map.unmodifiable(initialValues);

  final ReferenceCollection collection;
  final int? id;
  final ReferenceEditScope scope;
  final Json initialValues;
  final ReferenceMutationResult? Function() _preflight;
  final Future<ReferenceMutationResult> Function(Json) _send;
  final void Function() _changed;
  ReferenceEditState _state = ReferenceEditState.editing;
  Json? _submittedValues;
  ReferenceMutationResult? _lastResult;
  ReferenceEditState get state => _state;
  Json? get submittedValues => _submittedValues;
  ReferenceMutationResult? get lastResult => _lastResult;
  bool get isCurrent => scope.isCurrent;

  Future<ReferenceMutationResult> submit(Json values) async {
    if (!isCurrent) {
      return const ReferenceMutationResult(
        ReferenceMutationStatus.scopeChanged,
      );
    }
    if (_state == ReferenceEditState.sending) {
      return const ReferenceMutationResult(ReferenceMutationStatus.busy);
    }
    if (_state == ReferenceEditState.saved ||
        _state == ReferenceEditState.uncertain) {
      return _lastResult!;
    }
    final blocked = _preflight();
    if (blocked != null) {
      return blocked;
    }
    Json clean;
    try {
      clean = validateReferenceValues(collection, values, create: id == null);
    } on ReferenceValidationException catch (failure) {
      return _lastResult = ReferenceMutationResult(
        ReferenceMutationStatus.rejected,
        error: ReferenceEditError(
          failure.message,
          statusCode: 422,
          fieldErrors: failure.fieldErrors,
        ),
      );
    }
    _submittedValues = Map.unmodifiable(clean);
    _state = ReferenceEditState.sending;
    final result = _lastResult = await _send(clean);
    _state = switch (result.status) {
      ReferenceMutationStatus.saved => ReferenceEditState.saved,
      ReferenceMutationStatus.uncertain => ReferenceEditState.uncertain,
      ReferenceMutationStatus.scopeChanged when result.mayHaveSucceeded =>
        ReferenceEditState.uncertain,
      _ => ReferenceEditState.editing,
    };
    _changed();
    return result;
  }
}
