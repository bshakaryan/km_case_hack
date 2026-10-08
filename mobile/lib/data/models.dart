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

  int? get assigneeId => (data['assignee_id'] as num?)?.toInt();
  bool get isBrigade => data['brigade_id'] != null;
  String get participantsSource =>
      data['participants_source'] == 'live' ? 'live' : 'legacy_snapshot';
  List<OrderParticipant> get participants => assignmentParticipants(data);
  bool isResponsible(int? userId) =>
      userId != null && id > 0 && assigneeId == userId;
  bool hasParticipant(int? userId) =>
      userId != null &&
      id > 0 &&
      participants.any((participant) => participant.employeeId == userId);

  List<Json> get assignmentHistory => _historyRows(data['assignment_history']);
  List<Json> get submissionAttempts =>
      _historyRows(data['submission_attempts']);
  Json? get aiReviewJob => data['ai_review_job'] is Map
      ? Map<String, dynamic>.from(data['ai_review_job'] as Map)
      : null;
  bool get showAiReview =>
      aiReviewJob == null || aiReviewJob!['status'] == 'succeeded';
  bool get canRetryAiReview {
    final job = aiReviewJob;
    return !pendingSync &&
        status == 'completed' &&
        job?['status'] == 'failed' &&
        job?['retry_allowed'] == true &&
        submissionAttempts.isNotEmpty &&
        submissionAttempts.last['ai_review'] == null &&
        submissionAttempts.last['assessment_id'] == null &&
        submissionAttempts.last['id'] == job?['attempt_id'];
  }

  // Lists and historical command replays may omit detail-only fields. A new
  // explicit empty array is authoritative; only missing fields use the cache.
  WorkOrder withCachedHistory(WorkOrder? previous) {
    if (previous != null &&
        previous.version != null &&
        (version == null || version! < previous.version!)) {
      return previous;
    }
    return WorkOrder.fromJson({
      for (final key in [
        'assignment_history',
        'submission_attempts',
        'ai_review_job',
      ])
        if (!data.containsKey(key) && previous?.data.containsKey(key) == true)
          key: previous!.data[key],
      ...data,
    });
  }

  static List<Json> _historyRows(Object? value) => value is List
      ? value
            .whereType<Map>()
            .map((row) => Map<String, dynamic>.from(row))
            .toList()
      : [];
  int get id => (data['id'] as num).toInt();
  int? get version {
    final value = data['version'];
    return value is int && value >= 1 ? value : null;
  }

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

/// Only the assignment snapshot can grant crew access. Current references and
/// requested responsible_id are never treated as a confirmed assignment.
class OrderParticipant {
  const OrderParticipant({
    required this.employeeId,
    required this.name,
    required this.isResponsible,
    required this.source,
  });

  final int employeeId;
  final String name;
  final bool isResponsible;
  final String source;
}

List<OrderParticipant> assignmentParticipants(Json assignment) {
  if ((assignment['id'] as num?)?.toInt().isNegative == true) return [];
  final rows = assignment['participants'];
  if (rows is List) {
    return rows
        .whereType<Map>()
        .where((row) {
          return row['employee_id'] is int && (row['employee_id'] as int) > 0;
        })
        .map(
          (row) => OrderParticipant(
            employeeId: row['employee_id'] as int,
            name: '${row['name'] ?? ''}',
            isResponsible: row['is_responsible'] == true,
            source: row['source'] == 'live' ? 'live' : 'legacy_snapshot',
          ),
        )
        .toList();
  }
  final assigneeId = (assignment['assignee_id'] as num?)?.toInt();
  if (assigneeId == null || assigneeId < 1) return [];
  return [
    OrderParticipant(
      employeeId: assigneeId,
      name: '${assignment['assignee_name'] ?? ''}',
      isResponsible: true,
      source: 'legacy_snapshot',
    ),
  ];
}
