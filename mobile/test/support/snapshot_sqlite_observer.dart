// Test-only observation of production snapshot puts and their actual SQL.
// Never pass logger events to the default logger/toString: arguments are private.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/local_store_io.dart';
import 'package:sqflite_common/sqflite_logger.dart';
import 'package:sqflite_common/sqlite_api.dart';

import 'polling_metrics_client.dart';

final _putContext = Object();

String _section(String key) =>
    SnapshotKeys.all.where((name) => key.endsWith(':$name')).firstOrNull ??
    'other';

class _Put {
  _Put(this.phase, this.section, this.start);
  final PollingMetricsPhase? phase;
  final String section;
  final int start;
  int? end;
  bool success = false;
}

class _Row {
  _Row(this.payload, this.updatedAt);
  final String payload;
  final int updatedAt;
}

class _Sql {
  _Sql({
    required this.put,
    required this.duration,
    required this.end,
    required this.success,
    required this.bytes,
    required this.content,
    required this.timestamp,
  });
  final _Put put;
  final int duration;
  final int end;
  final bool success;
  final int bytes;
  final String content;
  final String timestamp;
}

Map<String, Object?> _durations(Iterable<int> micros) {
  final values = micros.toList()..sort();
  double? percentile(double fraction) => values.isEmpty
      ? null
      : values[(values.length * fraction).ceil() - 1] / 1000;
  return {
    'count': values.length,
    'total_ms': values.fold<int>(0, (sum, value) => sum + value) / 1000,
    'min_ms': values.isEmpty ? null : values.first / 1000,
    'p50_ms': percentile(.5),
    'p95_ms': percentile(.95),
    'max_ms': values.isEmpty ? null : values.last / 1000,
  };
}

// SQL callbacks occur after the real awaited operation. The put's Zone retains
// its originating phase even when the callback arrives after the phase ended.
class SnapshotSqliteObserver {
  SnapshotSqliteObserver(this.recorder, DatabaseFactory delegate) {
    // This test-only public logger is experimental in pinned SDK 2.5.13+1.
    // Production never imports it; SDK updates need renewed observer review.
    // ignore: experimental_member_use
    factory = SqfliteDatabaseFactoryLogger(
      delegate,
      options: SqfliteLoggerOptions(
        type: SqfliteDatabaseFactoryLoggerType.all,
        log: _observeSql,
      ),
    );
  }

  final PollingMetricsRecorder recorder;
  late final DatabaseFactory factory;
  final List<_Put> _puts = [];
  final List<_Sql> _sql = [];
  final Map<String, _Row> _lastSuccessful = {};
  final Map<PollingMetricsPhase, int> _pendingAtEnd = {};
  final Map<PollingMetricsPhase, List<int>> _callbackDurations = {};
  Database? _database;
  Map<String, _Row>? _beforeClose;
  Map<String, int>? _tablesBeforeClose;
  int activePuts = 0;
  int activity = 0;
  int observerErrors = 0;

  Future<void> put(String key, Future<void> Function() action) async {
    final phase = recorder.activePhase;
    final metric = _Put(
      phase,
      _section(key),
      recorder.clock.elapsedMicroseconds,
    );
    _puts.add(metric);
    activePuts++;
    activity++;
    if (phase != null) {
      phase.snapshotCalls[metric.section] =
          (phase.snapshotCalls[metric.section] ?? 0) + 1;
    }
    try {
      await runZoned(action, zoneValues: {_putContext: metric});
      metric.success = true;
    } finally {
      metric.end = recorder.clock.elapsedMicroseconds;
      activePuts--;
      activity++;
    }
  }

  void _observeSql(SqfliteLoggerEvent event) {
    final callbackClock = Stopwatch()..start();
    final context = Zone.current[_putContext];
    // Observer failure must not turn a committed SQL operation into an error.
    try {
      activity++;
      if (event is SqfliteLoggerDatabaseOpenEvent && event.error == null) {
        _database = event.db;
      }
      if (event is! SqfliteLoggerSqlEvent ||
          event.type != SqliteSqlCommandType.insert) {
        return;
      }
      final command = SqfliteSqlCommand.insert('snapshot', {
        'key': '',
        'payload': '',
        'updated_at': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      if (event.sql != command.sql) return;
      final args = event.arguments;
      final put = Zone.current[_putContext];
      if (args is! List ||
          args.length != 3 ||
          args[0] is! String ||
          args[1] is! String ||
          args[2] is! int ||
          put is! _Put ||
          event.sw == null) {
        observerErrors++;
        return;
      }
      final key = args[0] as String;
      final payload = args[1] as String;
      final updatedAt = args[2] as int;
      if (_section(key) != put.section) {
        observerErrors++;
        return;
      }
      final previous = _lastSuccessful[key];
      final success = event.error == null;
      _sql.add(
        _Sql(
          put: put,
          duration: event.sw!.elapsedMicroseconds,
          end: recorder.clock.elapsedMicroseconds,
          success: success,
          bytes: utf8.encode(payload).length,
          content: previous == null
              ? 'first'
              : previous.payload == payload
              ? 'identical'
              : 'changed',
          timestamp: previous == null
              ? 'first'
              : previous.updatedAt == updatedAt
              ? 'identical'
              : 'changed',
        ),
      );
      if (success) _lastSuccessful[key] = _Row(payload, updatedAt);
    } catch (_) {
      observerErrors++;
    } finally {
      callbackClock.stop();
      if (context is _Put && context.phase != null) {
        _callbackDurations
            .putIfAbsent(context.phase!, () => [])
            .add(callbackClock.elapsedMicroseconds);
      }
    }
  }

  void endPhase(PollingMetricsPhase phase) {
    _pendingAtEnd[phase] = _puts
        .where((put) => identical(put.phase, phase) && put.end == null)
        .length;
  }

  // Wait for entered puts and HTTP, then a real quiet tick so the controller's
  // post-response continuations can enter their writes. Private queued captures
  // are not observable and may be cancelled by dispose's session fence.
  Future<void> drain() async {
    final deadline = recorder.clock.elapsedMicroseconds + 12000000;
    while (true) {
      await recorder.waitForIdle();
      final before = activity;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (activePuts == 0 &&
          recorder.activeRequests == 0 &&
          before == activity) {
        return;
      }
      if (recorder.clock.elapsedMicroseconds >= deadline) {
        throw StateError('Entered snapshot/HTTP work did not drain.');
      }
    }
  }

  Map<String, Object?> phaseJson(PollingMetricsPhase phase) {
    final puts = _puts.where((put) => identical(put.phase, phase)).toList();
    final sql = _sql.where((sql) => identical(sql.put.phase, phase)).toList();
    return {
      'put_in_flight_at_end': _pendingAtEnd[phase],
      'unfinished_puts_after_drain': puts
          .where((put) => put.end == null)
          .length,
      'sql_events_observed_after_boundary': sql
          .where((sql) => sql.end > phase.endMicros!)
          .length,
      'sql_in_flight_at_end': null,
      'observer_errors_total': observerErrors,
      'observer_sql_callback_duration': _durations(
        _callbackDurations[phase] ?? [],
      ),
      'sections': {
        for (final section in SnapshotKeys.all)
          section: _sectionJson(
            puts.where((put) => put.section == section).toList(),
            sql.where((sql) => sql.put.section == section).toList(),
          ),
      },
    };
  }

  Map<String, Object?> _sectionJson(List<_Put> puts, List<_Sql> sql) => {
    'put_attempts': puts.length,
    'put_successes': puts.where((put) => put.end != null && put.success).length,
    'put_failures': puts.where((put) => put.end != null && !put.success).length,
    'put_awaited_duration': _durations(
      puts.where((put) => put.end != null).map((put) => put.end! - put.start),
    ),
    'completed_sql_attempts': sql.length,
    'sql_successes': sql.where((sql) => sql.success).length,
    'sql_failures': sql.where((sql) => !sql.success).length,
    'serialized_json_utf8_bytes_submitted': sql.fold<int>(
      0,
      (sum, sql) => sum + sql.bytes,
    ),
    'content_vs_last_successful': {
      for (final state in ['first', 'identical', 'changed'])
        state: sql.where((sql) => sql.content == state).length,
    },
    'updated_at_vs_last_successful': {
      for (final state in ['first', 'identical', 'changed'])
        state: sql.where((sql) => sql.timestamp == state).length,
    },
    'sql_wrapper_awaited_duration': _durations(sql.map((sql) => sql.duration)),
    'inferred_sql_start_after_put_entry': _durations(
      sql.map((sql) => sql.end - sql.duration - sql.put.start),
    ),
  };

  Future<Map<String, _Row>> _rows(Database database) async => {
    for (final row in await database.query('snapshot'))
      row['key'] as String: _Row(
        row['payload'] as String,
        row['updated_at'] as int,
      ),
  };

  Future<Map<String, int>> _otherTables(Database database) async => {
    for (final table in ['outbox', 'id_map', 'form_drafts', 'photo_cache'])
      table:
          (await database.rawQuery('SELECT COUNT(*) AS count FROM $table'))
                  .single['count']
              as int,
  };

  bool _sameRows(Map<String, _Row> left, Map<String, _Row> right) =>
      left.length == right.length &&
      left.entries.every(
        (entry) =>
            entry.value.payload == right[entry.key]?.payload &&
            entry.value.updatedAt == right[entry.key]?.updatedAt,
      );

  Future<Map<String, Object?>> beforeClose({
    required String server,
    required int owner,
    required Map<String, Object?> currentSections,
    required int overviewId,
    required int detailId,
    required DateTime expectedDeadline,
    required String expectedDescription,
  }) async {
    final database = _database!;
    final rows = _beforeClose = await _rows(database);
    final tables = _tablesBeforeClose = await _otherTables(database);
    final keys = {
      for (final key in SnapshotKeys.all) localScopeKey(server, owner, key),
    };
    final orderPayload =
        rows[localScopeKey(server, owner, SnapshotKeys.orders)]?.payload;
    final orders = orderPayload == null
        ? <Object?>[]
        : jsonDecode(orderPayload) as List;
    Map<String, Object?>? order(int id) => orders
        .whereType<Map<String, Object?>>()
        .where((row) => row['id'] == id)
        .firstOrNull;
    final overview = order(overviewId);
    final detail = order(detailId);
    return {
      'row_count': rows.length,
      'all_seven_expected_scoped_keys':
          rows.length == 7 && keys.every(rows.containsKey),
      'all_payloads_and_timestamps_match_last_successful_sql': _sameRows(
        rows,
        _lastSuccessful,
      ),
      'matches_controller_sections': {
        for (final entry in currentSections.entries)
          entry.key:
              rows[localScopeKey(server, owner, entry.key)]?.payload ==
              jsonEncode(entry.value),
      },
      'profile_owner_matches':
          rows[localScopeKey(server, owner, SnapshotKeys.profile)] != null &&
          (jsonDecode(
                rows[localScopeKey(server, owner, SnapshotKeys.profile)]!
                    .payload,
              ) as Map)['id'] ==
              owner,
      'latest_overview_version': overview?['version'],
      'latest_overview_deadline_matches_edit':
          overview?['deadline'] is String &&
          DateTime.parse(overview!['deadline'] as String).toUtc() ==
              expectedDeadline.toUtc(),
      'latest_detail_version': detail?['version'],
      'latest_detail_description_matches_edit':
          detail?['description'] == expectedDescription,
      'detail_history_fields_present': {
        for (final field in [
          'assignment_history',
          'submission_attempts',
        ])
          field: detail?.containsKey(field) == true,
      },
      'detail_assignment_history_count':
          (detail?['assignment_history'] as List?)?.length,
      'detail_submission_attempts_count':
          (detail?['submission_attempts'] as List?)?.length,
      'other_table_counts': tables,
      'all_other_tables_empty': tables.values.every((count) => count == 0),
      'active_puts_after_drain': activePuts,
      'observer_errors_total': observerErrors,
    };
  }

  Future<Map<String, Object?>> afterReopen(Database database) async {
    final rows = await _rows(database);
    final tables = await _otherTables(database);
    final result = <String, Object?>{
      'row_count_after_reopen': rows.length,
      'reopened_payloads_and_timestamps_match_before_close': _sameRows(
        rows,
        _beforeClose!,
      ),
      'reopened_payloads_and_timestamps_match_last_successful_sql': _sameRows(
        rows,
        _lastSuccessful,
      ),
      'other_table_counts_after_reopen': tables,
      'other_tables_unchanged': tables.entries.every(
        (entry) => _tablesBeforeClose![entry.key] == entry.value,
      ),
      'ordinary_close_reopen_only': true,
    };
    _beforeClose = null;
    _lastSuccessful.clear();
    return result;
  }
}

class PollingMetricsSqliteStore extends SqfliteLocalStore {
  PollingMetricsSqliteStore({required String directory, required this.observer})
    : super(directoryPath: directory, dbFactory: observer.factory);
  final SnapshotSqliteObserver observer;

  @override
  Future<void> putSnapshot(
    String key,
    Object? data, {
    required DateTime updatedAt,
  }) => observer.put(
    key,
    () => super.putSnapshot(key, data, updatedAt: updatedAt),
  );
}

// Deliberately refuse reuse, symlinks, relatives and any directory outside the
// fresh synthetic fixture's own canonical parent. The harness never deletes it.
Future<Directory> prepareSnapshotDirectory(
  String path,
  File fixture,
  String marker,
) async {
  String canonical(String value) {
    final normalized = value.replaceAll('\\', '/');
    return Platform.isWindows ? normalized.toLowerCase() : normalized;
  }

  final absolute = Platform.isWindows
      ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path)
      : path.startsWith('/');
  if (!absolute || path.split(RegExp(r'[\\/]')).any((part) => part == '..')) {
    throw StateError(
      'SQLite measurement requires an explicit absolute fresh directory.',
    );
  }
  final directory = Directory(path);
  if (await FileSystemEntity.type(path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw StateError('Refusing an existing SQLite measurement directory.');
  }
  final parent = await directory.parent.resolveSymbolicLinks();
  final fixtureParent = await fixture.parent.resolveSymbolicLinks();
  final leaf = path.replaceAll('\\', '/').split('/').last;
  if (canonical(parent) != canonical(fixtureParent) ||
      leaf != 'snapshot-sqlite-$marker') {
    throw StateError(
      'SQLite directory must be a fresh owned child of this fixture.',
    );
  }
  var ancestor = Directory(parent);
  while (true) {
    if (await FileSystemEntity.type(
          '${ancestor.path}/.git',
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      throw StateError('SQLite measurement files must remain outside Git.');
    }
    if (ancestor.parent.path == ancestor.path) break;
    ancestor = ancestor.parent;
  }
  await directory.create();
  if (canonical(await directory.resolveSymbolicLinks()) !=
      canonical(directory.absolute.path)) {
    throw StateError('Refusing a noncanonical SQLite measurement directory.');
  }
  return directory;
}
