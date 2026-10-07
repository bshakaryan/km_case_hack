typedef Json = Map<String, dynamic>;

class User {
  const User({required this.id, required this.name, required this.role});

  factory User.fromJson(Json json) => User(
    id: (json['id'] as num).toInt(),
    name: json['name'] as String,
    role: json['role'] as String,
  );

  final int id;
  final String name;
  final String role;
  bool get isMaster => role == 'master' || role == 'admin';
  bool get isWorker => role == 'worker';
}

class WorkOrder {
  WorkOrder.fromJson(Json json)
    : data = Map<String, dynamic>.unmodifiable(json);

  final Json data;
  Json toJson() => Map<String, dynamic>.from(data);

  List<Json> get assignmentHistory => _historyRows(data['assignment_history']);
  List<Json> get submissionAttempts =>
      _historyRows(data['submission_attempts']);

  // Lists and historical command replays may omit detail-only fields. A new
  // explicit empty array is authoritative; only missing fields use the cache.
  WorkOrder withCachedHistory(WorkOrder? previous) => WorkOrder.fromJson({
    for (final key in ['assignment_history', 'submission_attempts'])
      if (!data.containsKey(key) && previous?.data.containsKey(key) == true)
        key: previous!.data[key],
    ...data,
  });

  static List<Json> _historyRows(Object? value) => value is List
      ? value
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList()
      : [];
  int get id => (data['id'] as num).toInt();
  String get number => data['number'] as String;
  String get title => data['title'] as String;
  String get description => data['description'] as String? ?? '';
  String get status => data['status'] as String;
  bool get pendingSync =>
      data['_pending_sync'] == true || data['_queued_status'] != null || id < 0;
  String get priority => data['priority'] as String;
  String get workType => data['work_type'] as String;
  String get areaName => data['area_name'] as String? ?? '';
  String get equipmentName => data['equipment_name'] as String? ?? '';
  String get assigneeName => data['assignee_name'] as String? ?? '';
  DateTime get deadline => DateTime.parse(data['deadline'] as String);
  bool get isOverdue => data['is_overdue'] == true;
  double get normalHours => (data['normal_hours'] as num).toDouble();
  double? get score => (data['score'] as num?)?.toDouble();
}
