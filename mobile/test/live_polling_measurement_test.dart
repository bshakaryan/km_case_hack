// Opt-in desktop polling comparison; production app and real transport.
// flutter test test/live_polling_measurement_test.dart \
//   --dart-define=LIVE_POLLING_FIXTURE_FILE=<fresh synthetic fixture.json>
// Each phase lasts 60 REAL seconds. FullyLive binding uses no FakeAsync;
// no pump(Duration), fake clock, transport mocks or cadence substitutions.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/main.dart';
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:naryad_ai/ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/http_fault_proxy.dart' show isLoopbackHttpUri;
import 'support/polling_metrics_client.dart';

const _manifestPath = String.fromEnvironment('LIVE_POLLING_FIXTURE_FILE');
const _viewport = Size(480, 1000);
const _phaseDuration = Duration(seconds: 60);
const _editAt = Duration(seconds: 31);
const _samplePeriod = Duration(milliseconds: 50);

// The normal widget-test HttpClient override fabricates HTTP 400. This empty
// override restores dart:io's genuine HttpClient for login, polling and edits.
class _RealHttpOverrides extends HttpOverrides {}

// Observe genuine API return values without changing transport, timers, auth,
// cache behavior or the controller. Only count/length leave this observer.
class _ObservedApi extends NaryadApi {
  _ObservedApi(super.baseUrl, {required super.client, required this.recorder});
  final PollingMetricsRecorder recorder;

  @override
  Future<List<Json>> orders() async {
    final phase = recorder.activePhase;
    final result = await super.orders();
    phase?.recordSuccessfulOrdersReturn(result.length);
    return result;
  }
}

class _CompletedFrames {
  _CompletedFrames(this.binding, this.clock) {
    binding.addPersistentFrameCallback((_) {
      if (!_active) return;
      binding.addPostFrameCallback((_) {
        if (!_active) return;
        count++;
        lastMicros = clock.elapsedMicroseconds;
      });
    });
  }

  final LiveTestWidgetsFlutterBinding binding;
  final Stopwatch clock;
  bool _active = true;
  int count = 0;
  int? lastMicros;
  void dispose() => _active = false;
}

// A Text element by itself is insufficient evidence. Observe its laid-out
// RenderParagraph after a completed live frame, with no pending layout/paint,
// wholly inside both the fixed view and every enclosing scrolling viewport.
bool _visibleRenderedText(Finder finder, _CompletedFrames frames) {
  if (frames.lastMicros == null) return false;
  for (final element in finder.evaluate()) {
    final paragraph = element.findRenderObject();
    if (paragraph is! RenderParagraph ||
        !paragraph.attached ||
        !paragraph.hasSize ||
        paragraph.debugNeedsLayout ||
        paragraph.debugNeedsPaint ||
        paragraph.size.isEmpty) {
      continue;
    }
    final rect = paragraph.localToGlobal(Offset.zero) & paragraph.size;
    final view = Offset.zero & _viewport;
    if (!_contains(view, rect)) continue;
    var unclipped = true;
    RenderObject? parent = paragraph.parent;
    while (parent != null) {
      if (parent is RenderBox && parent is RenderAbstractViewport) {
        final clip = parent.localToGlobal(Offset.zero) & parent.size;
        if (!_contains(clip, rect)) {
          unclipped = false;
          break;
        }
      }
      parent = parent.parent;
    }
    if (unclipped) return true;
  }
  return false;
}

bool _contains(Rect outer, Rect inner) =>
    inner.left >= outer.left &&
    inner.top >= outer.top &&
    inner.right <= outer.right &&
    inner.bottom <= outer.bottom;

Future<void> _waitUntil(bool Function() condition, {String? reason}) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > const Duration(seconds: 15)) {
      throw StateError(reason ?? 'The real UI/network warmup did not finish.');
    }
    await Future<void>.delayed(_samplePeriod);
  }
}

Finder _card(int orderId) => find.byWidgetPredicate(
  (widget) => widget is OrderCard && widget.order.id == orderId,
);

class _EditAck {
  const _EditAck(this.version, this.micros, this.status);
  final int version;
  final int micros;
  final int status;
}

Future<_EditAck> _externalEdit({
  required http.Client client,
  required NaryadApi externalApi,
  required int orderId,
  required int initialVersion,
  required String commandId,
  required Json changes,
  required Stopwatch clock,
}) async {
  final response = await client
      .patch(
        Uri.parse('${externalApi.baseUrl}/orders/$orderId'),
        headers: {
          'Authorization': 'Bearer ${externalApi.token}',
          'Content-Type': 'application/json; charset=utf-8',
          'X-Client-Command-Id': commandId,
          'X-Expected-Order-Version': '$initialVersion',
        },
        body: jsonEncode(changes),
      )
      .timeout(const Duration(seconds: 10));
  // ACK is local receipt of the full 2xx body, not server commit time.
  final acknowledgedMicros = clock.elapsedMicroseconds;
  if (response.statusCode != 200) {
    // Never include response text, headers, URL, credentials or edit payload.
    throw StateError(
      'Synthetic external edit returned HTTP ${response.statusCode}.',
    );
  }
  final receipt = WorkOrder.fromJson(
    jsonDecode(utf8.decode(response.bodyBytes)) as Json,
  );
  expect(receipt.version, initialVersion + 1);
  expect(receipt.id, orderId);
  return _EditAck(receipt.version!, acknowledgedMicros, response.statusCode);
}

Future<Map<String, Object?>> _measurePhase({
  required String name,
  required PollingMetricsRecorder recorder,
  required AppController controller,
  required _CompletedFrames frames,
  required bool Function() renderedTargetVersion,
  required Future<_EditAck> Function() edit,
}) async {
  await recorder.waitForIdle();
  final phase = recorder.beginPhase(name);
  final startFrameCount = frames.count;
  Future<void>? editFuture;
  _EditAck? ack;
  Object? editFailure;
  int? editStartedMicros;
  int? lastAbsentMicros;
  int? firstPresentMicros;
  int? firstPresentFrameMicros;
  int? previousSampleMicros;
  var maxSampleGapMicros = 0;
  var samples = 0;
  var offlineSamples = 0;
  var errorSamples = 0;
  var offlineTransitions = 0;
  final initialOffline = controller.offline;
  final initialHasError = controller.error != null;
  var wasOffline = controller.offline;
  var observedUpdated = controller.lastUpdated;
  final refreshObservations = <double>[];
  final initialOutboxCount = controller.outbox.length;
  var outboxCountChanged = false;

  // Arm the known requested marker/version BEFORE PATCH. A polling response
  // can paint the new state before the external PATCH ACK reaches this client.
  void sample() {
    final now = recorder.clock.elapsedMicroseconds;
    if (previousSampleMicros != null) {
      maxSampleGapMicros = math.max(
        maxSampleGapMicros,
        now - previousSampleMicros!,
      );
    }
    previousSampleMicros = now;
    samples++;
    if (controller.offline) offlineSamples++;
    if (controller.error != null) errorSamples++;
    if (controller.offline != wasOffline) {
      offlineTransitions++;
      wasOffline = controller.offline;
    }
    if (controller.lastUpdated != observedUpdated) {
      observedUpdated = controller.lastUpdated;
      if (observedUpdated != null) {
        refreshObservations.add((now - phase.startMicros) / 1000);
      }
    }
    if (controller.outbox.length != initialOutboxCount) {
      outboxCountChanged = true;
    }
    if (firstPresentMicros != null) return;
    if (renderedTargetVersion()) {
      firstPresentMicros = now;
      firstPresentFrameMicros = frames.lastMicros;
    } else {
      lastAbsentMicros = now;
    }
  }

  sample();
  while (recorder.clock.elapsedMicroseconds - phase.startMicros <
      _phaseDuration.inMicroseconds) {
    final elapsed = recorder.clock.elapsedMicroseconds - phase.startMicros;
    if (editFuture == null && elapsed >= _editAt.inMicroseconds) {
      editStartedMicros = recorder.clock.elapsedMicroseconds;
      editFuture = () async {
        try {
          ack = await edit();
        } catch (failure) {
          editFailure = failure;
        }
      }();
    }
    await Future<void>.delayed(_samplePeriod);
    sample();
  }
  final endFrameCount = frames.count;
  final finalOffline = controller.offline;
  final finalHasError = controller.error != null;
  final finalOutboxCount = controller.outbox.length;
  recorder.endPhase(phase);
  await editFuture;
  // Drain requests enrolled BEFORE the boundary; their late completions stay
  // in that phase. New post-boundary traffic is excluded from both phases.
  await recorder.waitForIdle();
  if (editFailure != null) {
    throw StateError('The isolated external edit failed.');
  }
  expect(ack, isNotNull);
  expect(
    firstPresentMicros,
    isNotNull,
    reason: 'The target version never became visibly rendered.',
  );
  expect(lastAbsentMicros, isNotNull);
  expect(frames.count, greaterThan(startFrameCount));
  final actualAck = ack!;
  final firstPresent = firstPresentMicros!;
  return {
    ...phase.toJson(),
    'live_frames_completed': endFrameCount - startFrameCount,
    'render_samples': samples,
    'max_sample_gap_ms': maxSampleGapMicros / 1000,
    'application': {
      'initial_offline': initialOffline,
      'initial_has_error': initialHasError,
      'offline_samples': offlineSamples,
      'error_samples': errorSamples,
      'sampled_offline_transitions': offlineTransitions,
      'successful_global_refresh_observations': refreshObservations.length,
      'refresh_last_updated_change_observed_at_phase_ms': refreshObservations,
      'final_offline': finalOffline,
      'final_has_error': finalHasError,
      'initial_outbox_count': initialOutboxCount,
      'final_outbox_count': finalOutboxCount,
      'outbox_count_changed': outboxCountChanged,
      'nominal_application_healthy':
          offlineSamples == 0 &&
          errorSamples == 0 &&
          !finalOffline &&
          !finalHasError &&
          !outboxCountChanged &&
          refreshObservations.isNotEmpty,
    },
    'external_edit': {
      'started_at_phase_ms': (editStartedMicros! - phase.startMicros) / 1000,
      'ack_at_phase_ms': (actualAck.micros - phase.startMicros) / 1000,
      'ack_status': actualAck.status,
      'ack_version': actualAck.version,
      'last_absent_sample_at_phase_ms':
          (lastAbsentMicros! - phase.startMicros) / 1000,
      'first_present_sample_at_phase_ms':
          (firstPresent - phase.startMicros) / 1000,
      'first_present_last_completed_frame_at_phase_ms':
          (firstPresentFrameMicros! - phase.startMicros) / 1000,
      'observed_present_at_or_before_ack': firstPresent <= actualAck.micros,
      'ack_to_first_observation_ms_signed':
          (firstPresent - actualAck.micros) / 1000,
      'ack_to_render_interval_ms': {
        'lower': math.max(0, lastAbsentMicros! - actualAck.micros) / 1000,
        'upper': math.max(0, firstPresent - actualAck.micros) / 1000,
      },
    },
  };
}

Future<void> _liveMeasurement(
  WidgetTester tester,
  LiveTestWidgetsFlutterBinding binding,
) async {
  final manifestFile = File(_manifestPath).absolute;
  final manifest = jsonDecode(await manifestFile.readAsString()) as Json;
  expect(manifest['schema'], 1);
  expect(manifest['kind'], 'naryad-live-polling-measurement-fixture');
  expect(manifest['fresh'], isTrue);
  final marker = manifest['run_marker'] as String;
  expect(RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(marker), isTrue);
  final uri = Uri.parse(manifest['api_url'] as String);
  expect(isLoopbackHttpUri(uri), isTrue);
  expect(uri.path, '/api');
  final resultFile = File(manifest['result_file'] as String).absolute;
  expect(
    await resultFile.parent.resolveSymbolicLinks(),
    await manifestFile.parent.resolveSymbolicLinks(),
  );
  expect(
    await resultFile.exists(),
    isFalse,
    reason: 'Prepare a fresh fixture for each baseline.',
  );
  final master = manifest['master'] as Json;
  final overviewId = manifest['overview_order_id'] as int;
  final detailId = manifest['detail_order_id'] as int;
  final clock = Stopwatch()..start();
  final recorder = PollingMetricsRecorder(clock);
  final frames = _CompletedFrames(binding, clock);
  final store = PollingMetricsMemoryStore(recorder);
  NaryadApi meteredApi(String url) => _ObservedApi(
    url,
    client: PollingMetricsClient(IOClient(HttpClient()), recorder),
    recorder: recorder,
  );
  final controller = AppController(
    api: meteredApi(uri.toString()),
    apiFactory: meteredApi,
    localStore: store,
  );
  final externalClient = IOClient(HttpClient());
  final externalApi = NaryadApi(uri.toString(), client: externalClient);
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues({});
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = _viewport;
  await binding.setSurfaceSize(_viewport);
  try {
    // Mount the production app BEFORE login so its real empty-session restore
    // completes normally. login's real apiFactory starts the unchanged timer.
    await tester.pumpWidget(NaryadApp(controller: controller));
    await _waitUntil(() => !controller.loading && !controller.restoring);
    await controller.login(
      uri.toString(),
      master['login'] as String,
      master['pin'] as String,
    );
    await externalApi.login(master['login'] as String, master['pin'] as String);
    expect(controller.user?.id, master['id']);
    expect(controller.user?.isMaster, isTrue);
    expect(controller.offline, isFalse);
    expect(controller.error, isNull);
    expect(controller.orders.length, manifest['order_count']);
    expect(controller.orders.length, 500);
    final distribution = <String, int>{};
    for (final order in controller.orders) {
      distribution[order.status] = (distribution[order.status] ?? 0) + 1;
    }
    expect(distribution, manifest['status_distribution']);
    final actualReferenceCounts = <String, int>{
      for (final key in (manifest['reference_counts'] as Json).keys)
        key: (controller.reference[key] as List).length,
    };
    expect(actualReferenceCounts, manifest['reference_counts']);
    expect(controller.employees.length, manifest['worker_count']);
    final equipment = (controller.reference['equipment'] as List)
        .cast<Json>()
        .singleWhere((row) => row['id'] == manifest['equipment_id']);
    expect(equipment['inventory_number'], 'SYN-POLL-$marker');
    final overview = controller.orders.singleWhere((o) => o.id == overviewId);
    final detail = controller.orders.singleWhere((o) => o.id == detailId);
    expect(overview.title, '$marker-overview');
    expect(detail.title, '$marker-detail');
    expect(overview.status, 'issued');
    expect(detail.status, 'issued');
    expect(overview.version, manifest['overview_initial_version']);
    expect(detail.version, manifest['detail_initial_version']);
    expect(overview.priority, 'emergency');
    expect(
      controller.orders
          .where((o) => !terminal(o) && o.priority == 'emergency')
          .length,
      1,
    );
    expect(
      overview.deadline.toUtc(),
      DateTime.parse(manifest['overview_initial_deadline'] as String).toUtc(),
    );
    expect(detail.description, manifest['detail_initial_description']);

    await _waitUntil(() => _card(overviewId).evaluate().isNotEmpty);
    await tester.ensureVisible(_card(overviewId));
    await tester.pump(); // one real warmup frame, no duration/fake-time advance
    final oldDeadlineFinder = find.descendant(
      of: _card(overviewId),
      matching: find.text('До ${dateLabel(overview.deadline)}'),
    );
    await _waitUntil(() => _visibleRenderedText(oldDeadlineFinder, frames));
    final newDeadline = overview.deadline.toUtc().add(const Duration(days: 1));
    final newDeadlineText = 'До ${dateLabel(newDeadline)}';
    expect(newDeadlineText == 'До ${dateLabel(overview.deadline)}', isFalse);
    final newDeadlineFinder = find.descendant(
      of: _card(overviewId),
      matching: find.text(newDeadlineText),
    );
    final commandTag = marker.substring(0, math.min(marker.length, 32));
    final overviewResult = await _measurePhase(
      name: 'master_overview',
      recorder: recorder,
      controller: controller,
      frames: frames,
      renderedTargetVersion: () =>
          _card(overviewId).evaluate().any(
            (e) =>
                (e.widget as OrderCard).order.version == overview.version! + 1,
          ) &&
          controller.orders.any(
            (o) => o.id == overviewId && o.version == overview.version! + 1,
          ) &&
          _visibleRenderedText(newDeadlineFinder, frames),
      edit: () => _externalEdit(
        client: externalClient,
        externalApi: externalApi,
        orderId: overviewId,
        initialVersion: overview.version!,
        commandId: 'poll-$commandTag-overview',
        changes: {'deadline': newDeadline.toIso8601String()},
        clock: clock,
      ),
    );

    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) =>
              OrderDetailScreen(controller: controller, orderId: detailId),
        ),
      ),
    );
    await _waitUntil(
      () => _visibleRenderedText(find.text(detail.description), frames),
    );
    // Let the normal route animation and initial detail read finish outside the
    // window. AppController polling remains active behind the detail route.
    await Future<void>.delayed(const Duration(seconds: 1));
    await recorder.waitForIdle();
    final newDescription = 'Синтетический polling $marker: карточка обновлена.';
    final detailResult = await _measurePhase(
      name: 'master_open_order_detail',
      recorder: recorder,
      controller: controller,
      frames: frames,
      renderedTargetVersion: () =>
          controller.orders.any(
            (o) => o.id == detailId && o.version == detail.version! + 1,
          ) &&
          _visibleRenderedText(find.text(newDescription), frames),
      edit: () => _externalEdit(
        client: externalClient,
        externalApi: externalApi,
        orderId: detailId,
        initialVersion: detail.version!,
        commandId: 'poll-$commandTag-detail',
        changes: {'description': newDescription},
        clock: clock,
      ),
    );
    final result = <String, Object?>{
      'schema': 1,
      'kind': 'naryad-live-polling-baseline',
      'run_marker': marker,
      'complete': true,
      'nominal_transport_healthy':
          overviewResult['transport_failures'] == 0 &&
          detailResult['transport_failures'] == 0,
      'nominal_application_healthy':
          (overviewResult['application']
                  as Map<String, Object?>)['nominal_application_healthy'] ==
              true &&
          (detailResult['application']
                  as Map<String, Object?>)['nominal_application_healthy'] ==
              true,
      'method': {
        'binding': 'LiveTestWidgetsFlutterBinding.fullyLive',
        'time': 'monotonic Stopwatch, real Timer/Future.delayed; no FakeAsync or timed pump',
        'phase_boundary': 'requests enrolled at send; late full responses retained in originating phase; drain excluded',
        'network': 'genuine loopback HTTP through injected IOClient; external authenticated PATCH excluded',
        'conditional_orders': 'only /orders?limit=5000 uses per-API/current-authority immutable ETag body; actual 304 bytes counted as received, cached bytes not network bytes; five-second cadence unchanged',
        'orders_return_evidence': 'test-only API subclass counts successful full orders() returns and list lengths; together with consumed 304 and global refresh observations, not an independently correlated per-request cache-use counter',
        'bytes': 'logical received response body bytes after IOClient decompression; not wire/TLS/request bytes',
        'latency': 'send entry to complete response stream consumption; excludes JSON decode and controller apply',
        'display': '50ms real sampling of version-bound RenderParagraph after live frame, no pending layout/paint, inside view/scroll clips',
        'lag': 'client full-body 200 ACK to sampled first visible scene; last-absent/first-present interval, signed early observation retained',
        'snapshot': 'MemoryLocalStore.putSnapshot call counts only; no physical I/O/fsync/durability claims',
        'application': '50ms sampled offline/error/outbox state; successful global refresh observed from lastUpdated changes inside phase, not individual GET success',
        'warmup_excluded': true,
        'target_phase_seconds': 60,
        'target_edit_second': 31,
        'target_sampling_ms': 50,
      },
      'environment': {
        'platform': Platform.operatingSystem,
        'dart_version': Platform.version.split(' ').first,
        'viewport_logical_width': _viewport.width,
        'viewport_logical_height': _viewport.height,
        'device_pixel_ratio': 1,
        'role': 'master',
        'local_store': 'counted memory platform double',
        'secure_storage': 'platform double',
        'shared_preferences': 'platform double',
        'push': 'NoopPushService',
        'overview_position':
            'scrolled to existing emergency order card before phase',
        'detail_background_overview_polling': true,
      },
      'fixture': {
        'orders': controller.orders.length,
        'status_distribution': distribution,
        'reference_counts': actualReferenceCounts,
        'worker_count': controller.employees.length,
      },
      'limitations': [
        'One isolated synthetic master and two phases; not load testing or a worst-case freshness SLA.',
        'Flutter scene/layout/paint witness, not physical screen pixels, GPU presentation or Android device proof.',
        'Loopback HTTP logical body bytes do not measure mobile radio, wire traffic or battery.',
        'Local storage/session plugins and push are platform doubles; snapshot counts are controller calls only.',
      ],
      'phases': [overviewResult, detailResult],
    };
    expect(tester.takeException(), isNull);
    await resultFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(result)}\n',
      flush: true,
    );
    // Retried GETs may keep failed transport attempts visible while the app
    // remains healthy. Preserve both facts; accept application health only.
    expect(
      result['nominal_application_healthy'],
      isTrue,
      reason: 'Evidence was saved, but sampled offline/error/queue changes prevent accepting a nominal application baseline.',
    );
  } finally {
    recorder.activePhase = null;
    await tester.pumpWidget(const SizedBox.shrink());
    frames.dispose();
    controller.dispose();
    externalApi.close();
    await store.close();
    await binding.setSurfaceSize(null);
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  }
}

void main() {
  if (_manifestPath.isEmpty) {
    // Do not install a live binding into the ordinary unit-test suite.
    test(
      'live polling baseline',
      () {},
      skip: 'Set LIVE_POLLING_FIXTURE_FILE for a fresh synthetic loopback fixture.',
    );
    return;
  }
  final binding = LiveTestWidgetsFlutterBinding.ensureInitialized()
    ..framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  testWidgets(
    'real 60-second overview and visible detail polling baseline',
    (tester) => HttpOverrides.runWithHttpOverrides(
      () => _liveMeasurement(tester, binding),
      _RealHttpOverrides(),
    ),
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
