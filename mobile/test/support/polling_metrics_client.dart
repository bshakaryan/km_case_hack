// Test-only observer. Request/response bodies, headers, URLs and query values
// never enter the recorder. Response chunks pass through exactly once.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:naryad_ai/data/local_store.dart';

// Read message text only to select a fixed allowlisted category. Never return
// the message/URI/osError/address: ClientException.toString includes the URL.
String safePollingFailureCause(Object error) {
  if (error is TimeoutException) return 'timeout';
  final message = switch (error) {
    http.ClientException() => error.message.toLowerCase(),
    HttpException() => error.message.toLowerCase(),
    SocketException() => error.message.toLowerCase(),
    _ => '',
  };
  if (message.contains('connection closed before full header')) {
    return 'connection_closed_before_headers';
  }
  if (message.contains('connection closed before response') ||
      message.contains('connection closed before data')) {
    return 'connection_closed_before_response';
  }
  if (message.contains('connection closed before full body')) {
    return 'connection_closed_during_body';
  }
  if (message.contains('connection closed while receiving data')) {
    return 'connection_closed_during_body';
  }
  if (message.contains('connection reset') ||
      message.contains('forcibly closed')) {
    return 'connection_reset';
  }
  if (message.contains('connection refused')) return 'connection_refused';
  if (message.contains('failed host lookup')) return 'dns_lookup_failed';
  if (message.contains('already closed')) return 'client_closed';
  if (error is SocketException) return 'socket_other';
  if (error is http.ClientException) return 'client_transport_other';
  return 'transport_other';
}

String normalizedPollingRoute(Uri uri) {
  final path = uri.path;
  const fixed = {
    '/api/auth/login',
    '/api/auth/me',
    '/api/reference',
    '/api/employees',
    '/api/orders',
    '/api/dashboard',
    '/api/notifications',
    '/api/analytics',
  };
  if (fixed.contains(path)) return path;
  if (RegExp(r'^/api/orders/[0-9]+$').hasMatch(path)) {
    return '/api/orders/:id';
  }
  // An unexpected path might contain user text. Do not export it verbatim.
  return '/api/other';
}

class PollingMetricsRecorder {
  PollingMetricsRecorder(this.clock);

  final Stopwatch clock;
  PollingMetricsPhase? activePhase;
  int activeRequests = 0;

  PollingMetricsPhase beginPhase(String name) {
    if (activePhase != null || activeRequests != 0) {
      throw StateError('Drain warmup traffic before starting a phase.');
    }
    return activePhase = PollingMetricsPhase(name, clock.elapsedMicroseconds);
  }

  void endPhase(PollingMetricsPhase phase) {
    if (!identical(activePhase, phase)) {
      throw StateError('The measurement phase changed.');
    }
    phase.endMicros = clock.elapsedMicroseconds;
    phase.inFlightAtEnd = phase.inFlight;
    activePhase = null;
  }

  Future<void> waitForIdle({
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final deadline = clock.elapsedMicroseconds + timeout.inMicroseconds;
    while (activeRequests != 0) {
      if (clock.elapsedMicroseconds >= deadline) {
        throw StateError(
          'HTTP responses did not drain within the observation window.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }
}

class PollingMetricsPhase {
  PollingMetricsPhase(this.name, this.startMicros);

  final String name;
  final int startMicros;
  int? endMicros;
  int inFlight = 0;
  int peakConcurrency = 0;
  int inFlightAtEnd = 0;
  final List<_RequestMetric> _requests = [];
  final Map<String, int> snapshotCalls = {};
  final List<int> _ordersReturnLengths = [];

  void recordSuccessfulOrdersReturn(int length) =>
      _ordersReturnLengths.add(length);

  Map<String, Object?> toJson() {
    final routes = <String, List<_RequestMetric>>{};
    for (final request in _requests) {
      routes.putIfAbsent(request.route, () => []).add(request);
    }
    return {
      'name': name,
      'duration_ms': ((endMicros ?? startMicros) - startMicros) / 1000,
      'requests_started': _requests.length,
      'responses_fully_consumed': _requests
          .where((r) => r.finished && !r.failed)
          .length,
      'transport_failures': _requests.where((r) => r.failed).length,
      'not_modified_responses': _requests
          .where((r) => r.status == 304 && r.finished && !r.failed)
          .length,
      'not_modified_received_body_bytes': _requests
          .where((r) => r.status == 304)
          .fold<int>(0, (sum, r) => sum + r.bytes),
      'peak_concurrency': peakConcurrency,
      'in_flight_at_end': inFlightAtEnd,
      'unfinished_after_drain': _requests.where((r) => !r.finished).length,
      'logical_response_body_bytes': _requests.fold<int>(
        0,
        (sum, r) => sum + r.bytes,
      ),
      'snapshot_put_calls': snapshotCalls,
      'orders_application_returns': {
        'completed_successful_calls': _ordersReturnLengths.length,
        'returned_list_lengths': List<int>.of(_ordersReturnLengths),
      },
      'routes': {
        for (final entry in routes.entries) entry.key: _routeJson(entry.value),
      },
    };
  }

  Map<String, Object?> _routeJson(List<_RequestMetric> requests) {
    final durations =
        requests
            .where((r) => r.finished && !r.failed)
            .map((r) => (r.endMicros! - r.startMicros) / 1000)
            .toList()
          ..sort();
    final statuses = <String, int>{};
    for (final request in requests) {
      final status = '${request.status ?? 0}';
      statuses[status] = (statuses[status] ?? 0) + 1;
    }
    double? percentile(double fraction) => durations.isEmpty
        ? null
        : durations[(durations.length * fraction).ceil() - 1];
    return {
      'requests': requests.length,
      'status_counts': statuses,
      'not_modified_responses': requests
          .where((r) => r.status == 304 && r.finished && !r.failed)
          .length,
      'not_modified_received_body_bytes': requests
          .where((r) => r.status == 304)
          .fold<int>(0, (sum, r) => sum + r.bytes),
      'logical_response_body_bytes': requests.fold<int>(
        0,
        (sum, r) => sum + r.bytes,
      ),
      'request_start_ms': [
        for (final r in requests) (r.startMicros - startMicros) / 1000,
      ],
      'full_response_latency_ms': {
        'min': durations.isEmpty ? null : durations.first,
        'mean': durations.isEmpty
            ? null
            : durations.reduce((a, b) => a + b) / durations.length,
        'p50': percentile(0.5),
        'p95': percentile(0.95),
        'max': durations.isEmpty ? null : durations.last,
      },
      'failures': [
        for (final r in requests.where((r) => r.failed))
          {
            'start_at_phase_ms': (r.startMicros - startMicros) / 1000,
            'duration_ms': (r.endMicros! - r.startMicros) / 1000,
            'status': r.status ?? 0,
            'stage': r.failureStage,
            'runtime_type': r.failureType,
            'cause': r.failureCause,
          },
      ],
      'responses_completed_after_phase_end': requests
          .where((r) => r.endMicros != null && r.endMicros! > endMicros!)
          .length,
    };
  }
}

class _RequestMetric {
  _RequestMetric(this.route, this.startMicros);

  final String route;
  final int startMicros;
  int? status;
  int bytes = 0;
  int? endMicros;
  bool failed = false;
  String? failureStage;
  String? failureType;
  String? failureCause;
  bool get finished => endMicros != null;
}

class PollingMetricsClient extends http.BaseClient {
  PollingMetricsClient(this.inner, this.recorder);

  final http.Client inner;
  final PollingMetricsRecorder recorder;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final phase = recorder.activePhase;
    final metric = phase == null
        ? null
        : _RequestMetric(
            '${request.method == 'GET' ? 'GET' : 'MUTATION'} ${normalizedPollingRoute(request.url)}',
            recorder.clock.elapsedMicroseconds,
          );
    recorder.activeRequests++;
    if (phase != null) {
      phase._requests.add(metric!);
      phase.inFlight++;
      phase.peakConcurrency = math.max(phase.peakConcurrency, phase.inFlight);
    }
    var finished = false;
    void finish({bool failed = false, Object? error, String? stage}) {
      if (finished) return;
      finished = true;
      recorder.activeRequests--;
      if (phase != null) phase.inFlight--;
      if (metric != null) {
        metric.failed = failed;
        if (failed) {
          metric.failureStage = stage;
          metric.failureType =
              error?.runtimeType.toString() ?? 'stream_cancelled';
          metric.failureCause = error == null
              ? 'stream_cancelled'
              : safePollingFailureCause(error);
        }
        metric.endMicros = recorder.clock.elapsedMicroseconds;
      }
    }

    try {
      final response = await inner.send(request);
      metric?.status = response.statusCode;
      Stream<List<int>> observe() async* {
        var fullyConsumed = false;
        Object? streamFailure;
        try {
          await for (final chunk in response.stream) {
            if (metric != null) metric.bytes += chunk.length;
            yield chunk;
          }
          fullyConsumed = true;
        } catch (error) {
          streamFailure = error;
          rethrow;
        } finally {
          finish(
            failed: !fullyConsumed,
            error: streamFailure,
            stage: 'response_stream',
          );
        }
      }

      return http.StreamedResponse(
        observe(),
        response.statusCode,
        contentLength: response.contentLength,
        request: response.request,
        headers: response.headers,
        isRedirect: response.isRedirect,
        persistentConnection: response.persistentConnection,
        reasonPhrase: response.reasonPhrase,
      );
    } catch (error) {
      finish(failed: true, error: error, stage: 'send');
      rethrow;
    }
  }

  @override
  void close() => inner.close();
}

// Count controller calls only. This memory platform double proves neither disk
// writes nor transactions, physical I/O, fsync duration or durable persistence.
class PollingMetricsMemoryStore extends MemoryLocalStore {
  PollingMetricsMemoryStore(this.recorder);
  final PollingMetricsRecorder recorder;

  @override
  Future<void> putSnapshot(
    String key,
    Object? data, {
    required DateTime updatedAt,
  }) {
    final phase = recorder.activePhase;
    if (phase != null) {
      final category =
          SnapshotKeys.all
              .where((name) => key.endsWith(':$name'))
              .firstOrNull ??
          'other';
      phase.snapshotCalls[category] = (phase.snapshotCalls[category] ?? 0) + 1;
    }
    return super.putSnapshot(key, data, updatedAt: updatedAt);
  }
}
