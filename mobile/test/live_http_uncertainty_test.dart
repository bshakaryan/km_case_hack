// Desktop opt-in, isolated synthetic fixture only. The proxy drops a REAL HTTP
// reply after observing upstream commit; SQLite is real (dev-only native FFI).
// flutter test test/live_http_uncertainty_test.dart \
//   --dart-define=LIVE_HTTP_FIXTURE_FILE=<fresh manifest from backend fixture CLI>
// Controller reconstruction is deliberate: this does not claim Android process
// death, physical network loss, camera use or secure-session restoration.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/local_store_io.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/data/recovery_models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/http_fault_proxy.dart';

const _manifestPath = String.fromEnvironment('LIVE_HTTP_FIXTURE_FILE');

// Flutter's widget-test binding normally intercepts HTTP. This override uses
// dart:io's genuine transport, never a MockClient or a fabricated 503 response.
class _RealHttpOverrides extends HttpOverrides {}

Future<void> _liveScenario() async {
  final manifestFile = File(_manifestPath).absolute;
  final manifest = jsonDecode(await manifestFile.readAsString()) as Json;
  expect(manifest['schema'], 1);
  expect(manifest['kind'], 'naryad-live-http-uncertainty-fixture');
  expect(manifest['fresh'], isTrue);
  final marker = manifest['run_marker'] as String;
  expect(RegExp(r'^[A-Za-z0-9_-]{8,64}$').hasMatch(marker), isTrue);
  final upstream = Uri.parse(manifest['api_url'] as String);
  expect(
    isLoopbackHttpUri(upstream),
    isTrue,
    reason: 'The opt-in scenario must never contact a remote API.',
  );
  expect(upstream.path, '/api');
  final baseline = manifest['baseline'] as Json;
  for (final key in [
    'orders',
    'submission_attempts',
    'material_writeoffs',
    'complete_events',
    'ai_review_jobs',
    'complete_receipts',
  ]) {
    expect(baseline[key], 0, reason: 'Fixture baseline must be fresh: $key');
  }
  final resultFile = File(manifest['result_file'] as String).absolute;
  expect(
    await resultFile.parent.resolveSymbolicLinks(),
    await manifestFile.parent.resolveSymbolicLinks(),
  );
  expect(
    await resultFile.exists(),
    isFalse,
    reason: 'Use a fresh fixture and a fresh evidence file for each run.',
  );
  final masterConfig = manifest['master'] as Json;
  final workerConfig = manifest['worker'] as Json;
  final master = NaryadApi(upstream.toString());
  final worker = NaryadApi(upstream.toString());
  HttpFaultProxy? proxy;
  AppController? first;
  AppController? restored;
  SqfliteLocalStore? firstStore;
  SqfliteLocalStore? reopenedStore;
  Directory? localFolder;
  try {
    await master.login(
      masterConfig['login'] as String,
      masterConfig['pin'] as String,
    );
    await worker.login(
      workerConfig['login'] as String,
      workerConfig['pin'] as String,
    );
    expect((await master.me()).isMaster, isTrue);
    final actualWorker = await worker.me();
    expect(actualWorker.id, workerConfig['id']);
    expect(actualWorker.isWorker, isTrue);
    final reference = await master.reference();
    final equipment = (reference['equipment'] as List).cast<Json>().singleWhere(
      (row) => row['id'] == manifest['equipment_id'],
    );
    // Cross-check the manifest against the running API before ANY work-order
    // mutation. A loopback URL alone is not proof of a fresh synthetic database.
    expect(equipment['inventory_number'], 'SYN-$marker');
    expect(equipment['area_id'], manifest['area_id']);
    expect(await master.orders(), isEmpty);
    expect(
      (reference['materials'] as List).cast<Json>().any(
        (row) => row['id'] == manifest['material_id'],
      ),
      isTrue,
    );
    expect(
      (reference['fault_codes'] as List).cast<Json>().any(
        (row) => row['id'] == manifest['fault_code_id'],
      ),
      isTrue,
    );

    final tag = sha256.convert(utf8.encode(marker)).toString().substring(0, 24);
    var current = await master.createOrder({
      'title': marker,
      'description':
          'Синтетическая приёмка потерянного HTTP-ответа и офлайн-очереди.',
      'work_type': 'unplanned',
      'area_id': manifest['area_id'],
      'equipment_id': manifest['equipment_id'],
      'assignee_id': actualWorker.id,
      'priority': 'normal',
      'deadline': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 2))
          .toIso8601String(),
      'normal_hours': 1.5,
      'comment': 'Только синтетическая фикстура $marker.',
    }, commandId: 'live-create-$tag');
    expect(current.status, 'issued');
    current = await worker.transition(
      current.id,
      'accept',
      commandId: 'live-accept-$tag',
      expectedVersion: current.version,
    );
    current = await worker.transition(
      current.id,
      'start',
      commandId: 'live-start-$tag',
      expectedVersion: current.version,
    );
    expect(current.status, 'in_progress');
    final picture = img.Image(width: 32, height: 24);
    img.fill(picture, color: img.ColorRgb8(30, 140, 80));
    final photoReceipt = await worker.uploadPhoto(
      current.id,
      Uint8List.fromList(img.encodePng(picture)),
      'synthetic-after.png',
      'after',
      commandId: 'live-photo-$tag',
      expectedVersion: current.version,
    );
    final photoId = (photoReceipt['id'] as num).toInt();
    final beforeSubmit = await worker.order(current.id);
    expect(beforeSubmit.status, 'in_progress');
    expect(beforeSubmit.isResponsible(actualWorker.id), isTrue);
    final expectedVersion = beforeSubmit.version!;
    final completion = <String, dynamic>{
      'work_done':
          'Синтетический ремонт $marker: заменён узел, проверено давление и работа насоса.',
      'fault_code_id': manifest['fault_code_id'],
      'materials': [
        {
          'material_id': manifest['material_id'],
          'quantity': manifest['material_quantity'],
        },
      ],
      'comment':
          'Обрыв ответа после commit; повторяется только исходная команда.',
    };

    proxy = await HttpFaultProxy.start(upstream);
    proxy.armCompleteReplyLoss(beforeSubmit.id);
    sqfliteFfiInit();
    localFolder = await Directory.systemTemp.createTemp(
      'naryad-http-uncertainty-',
    );
    firstStore = SqfliteLocalStore(
      directoryPath: localFolder.path,
      dbFactory: databaseFactoryFfi,
    );
    await firstStore.open();
    final firstSource = NaryadApi(proxy.baseUrl)..token = worker.token;
    final firstAuthenticated = await firstSource.me();
    expect(firstAuthenticated.id, actualWorker.id);
    first = AppController(api: firstSource, localStore: firstStore)
      ..user = firstAuthenticated
      ..orders = [beforeSubmit];
    final pendingView = await first.complete(
      beforeSubmit.id,
      completion,
      basis: OrderWriteBasis(expectedVersion: expectedVersion),
    );
    final lost = await proxy.lostReplyCommitted.timeout(
      const Duration(seconds: 10),
    );
    expect(lost.replyDropped, isTrue);
    expect(lost.upstreamStatus, 200);
    expect(pendingView.pendingSync, isTrue);
    expect(first.offline, isTrue);
    final original = (await firstStore.outbox()).single;
    expect(original.state, OutboxState.pending);
    expect(
      original.responseStatus,
      0,
      reason: 'Real lost HTTP reply, not a fabricated error status.',
    );
    expect(original.commandId, lost.commandId);
    expect(original.expectedVersion, expectedVersion);
    expect(original.previousCommandId, isNull);
    expect(original.payload, completion);
    expect(original.serverUrl, proxy.baseUrl);
    expect(original.ownerId, actualWorker.id);
    expect(lost.expectedVersion, '$expectedVersion');
    expect(lost.previousCommandId, isNull);
    expect(jsonDecode(utf8.decode(lost.body)), completion);
    final originalSnapshot = jsonEncode(original.toJson());
    final evidence = <String, dynamic>{
      'run_marker': marker,
      'order_id': beforeSubmit.id,
      'command_id': original.commandId,
      'photo_id': photoId,
      'completion': completion,
      'expected_version': expectedVersion,
      'body_sha256': lost.bodySha256,
      'original_response_sha256': lost.replySha256,
      'lost_reply_upstream_status': lost.upstreamStatus,
      'lost_reply_local_status': original.responseStatus,
      'controller_reconstructed': false,
      'secure_session_restoration': false,
      'android_process_death': false,
      'acknowledged': false,
    };
    await resultFile.writeAsString('${jsonEncode(evidence)}\n', flush: true);

    final fresh = await first.loadOrder(beforeSubmit.id);
    expect(fresh.version, greaterThan(expectedVersion));
    expect(fresh.pendingSync, isTrue);
    expect(
      jsonEncode((await firstStore.outbox()).single.toJson()),
      originalSnapshot,
    );
    final inspected = await first.inspectCommand(original.commandId);
    expect(inspected.status, QueueRecoveryStatus.success);
    expect(inspected.inspection!.command.payload, completion);
    expect(inspected.inspection!.command.expectedVersion, expectedVersion);
    expect(proxy.forwardedMutationCount, 1);
    expect(proxy.heldMutationCount, 0);
    final cachedFreshVersion = fresh.version!;
    first.dispose();
    first = null;
    await firstStore.close();
    firstStore = null;

    // Keep the SAME proxy endpoint and owner namespace. The bearer came from
    // real login; /me revalidates it. No controller init/login/polling starts.
    reopenedStore = SqfliteLocalStore(
      directoryPath: localFolder.path,
      dbFactory: databaseFactoryFfi,
    );
    await reopenedStore.open();
    expect(
      jsonEncode((await reopenedStore.outbox()).single.toJson()),
      originalSnapshot,
    );
    final reopenedSource = NaryadApi(proxy.baseUrl)..token = worker.token;
    final reopenedAuthenticated = await reopenedSource.me();
    restored = AppController(api: reopenedSource, localStore: reopenedStore)
      ..user = reopenedAuthenticated
      ..orders = [fresh]
      ..offline = true;
    final reopenedInspection = await restored.inspectCommand(
      original.commandId,
    );
    expect(reopenedInspection.status, QueueRecoveryStatus.success);
    expect(
      jsonEncode(reopenedInspection.inspection!.command.toJson()),
      originalSnapshot,
    );
    await restored.loadOrder(beforeSubmit.id);
    expect(
      jsonEncode((await reopenedStore.outbox()).single.toJson()),
      originalSnapshot,
    );
    expect(restored.orders.single.pendingSync, isTrue);
    expect(proxy.observations.length, 1);
    expect(proxy.forwardedMutationCount, 1);
    expect(
      proxy.heldMutationCount,
      0,
      reason: 'Unexpected automatic writes must fail this controlled scenario.',
    );

    proxy.releaseMutations();
    restored.offline = false;
    await restored.syncOutbox();
    expect(proxy.heldMutationCount, 0);
    expect(proxy.forwardedMutationCount, 2);
    expect(proxy.observations.length, 2);
    final replay = proxy.observations.last;
    expect(replay.replyDropped, isFalse);
    expect(replay.upstreamStatus, 200);
    expect(replay.commandId, original.commandId);
    expect(replay.expectedVersion, lost.expectedVersion);
    expect(replay.previousCommandId, lost.previousCommandId);
    expect(replay.body, orderedEquals(lost.body));
    expect(replay.bodySha256, lost.bodySha256);
    expect(
      jsonDecode(utf8.decode(replay.replyBody)),
      jsonDecode(utf8.decode(lost.replyBody)),
    );
    expect(await reopenedStore.outbox(), isEmpty);
    expect(restored.outbox, isEmpty);
    expect(restored.orders.single.pendingSync, isFalse);
    expect(
      restored.orders.single.version,
      greaterThanOrEqualTo(cachedFreshVersion),
    );
    evidence.addAll({
      'controller_reconstructed': true,
      'acknowledged': true,
      'fresh_get_version': cachedFreshVersion,
      'final_cached_version': restored.orders.single.version,
      'forwarded_complete_posts': proxy.observations.length,
      'held_mutations': proxy.heldMutationCount,
      'replay_body_sha256': replay.bodySha256,
      'replay_response_sha256': replay.replySha256,
      'local_outbox_empty_after_ack': true,
    });
    await resultFile.writeAsString('${jsonEncode(evidence)}\n', flush: true);
    // Database-side attempt/material/event/job/receipt counts are independently
    // verified by the backend fixture CLI using this synthetic result file.
  } finally {
    first?.dispose();
    restored?.dispose();
    await firstStore?.close();
    await reopenedStore?.close();
    await proxy?.close();
    master.close();
    worker.close();
    if (localFolder != null && await localFolder.exists()) {
      final canonicalRoot = await Directory.systemTemp.resolveSymbolicLinks();
      final canonicalFolder = await localFolder.resolveSymbolicLinks();
      final folder = Directory(canonicalFolder);
      if (folder.parent.path != canonicalRoot ||
          !folder.path
              .split(Platform.pathSeparator)
              .last
              .startsWith('naryad-http-uncertainty-')) {
        throw StateError('Refuse unexpected local test directory cleanup.');
      }
      await folder.delete(recursive: true);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'live HTTP commit with lost reply preserves durable SQLite command and exact replay',
    () =>
        HttpOverrides.runWithHttpOverrides(_liveScenario, _RealHttpOverrides()),
    skip: _manifestPath.isEmpty
        ? 'Set LIVE_HTTP_FIXTURE_FILE for a fresh isolated synthetic loopback fixture.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
