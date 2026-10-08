import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/form_draft.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/data/recovery_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

const server = 'http://recovery.test/api';
const worker = User(id: 7, name: 'Ответственный', role: 'worker');

Json order({int assignee = 7, int version = 7}) => {
  'id': 9,
  'version': version,
  'number': 'RECOVERY-9',
  'title': 'Проверить насос',
  'description': 'Осмотр и ремонт',
  'status': 'in_progress',
  'priority': 'normal',
  'work_type': 'planned',
  'assignee_id': assignee,
  'participants_source': 'live',
  'participants': [
    {'employee_id': 7, 'name': 'Работник', 'is_responsible': assignee == 7},
    {'employee_id': 8, 'name': 'Коллега', 'is_responsible': assignee == 8},
  ],
  'normal_hours': 2,
  'deadline': '2026-10-09T12:00:00Z',
  'created_at': '2026-10-08T10:00:00Z',
  'photos': <Json>[],
  'is_overdue': false,
};

OutboxCommand command(
  String id, {
  int time = 1,
  String kind = OutboxKind.complete,
  int owner = 7,
  String source = server,
  int? orderId = 9,
  String? localRef,
  int? expectedVersion = 7,
  String? previousCommandId,
  String state = OutboxState.conflict,
  int attempts = 0,
  int? responseStatus,
  Json? response,
  String? lastError,
  Json payload = const {
    'work_done': 'Заменил уплотнение. Проверил давление.',
    'comment': 'Оставить исходный текст',
    'materials': [
      {'material_id': 3, 'quantity': 2},
    ],
  },
}) => OutboxCommand(
  commandId: id,
  kind: kind,
  createdAt: time,
  ownerId: owner,
  serverUrl: source,
  orderId: orderId,
  localRef: localRef,
  expectedVersion: expectedVersion,
  previousCommandId: previousCommandId,
  state: state,
  attempts: attempts,
  responseStatus: responseStatus,
  response: response,
  lastError: lastError,
  payload: payload,
  photoFilename: kind == OutboxKind.uploadPhoto ? 'retained.jpg' : null,
  photoKind: kind == OutboxKind.uploadPhoto ? 'after' : null,
);

http.Response response(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class _RecoveryStore extends MemoryLocalStore {
  int resetRunningCount = 0;
  String? gateOperation;
  final started = Completer<void>();
  final release = Completer<void>();
  bool failRecovery = false;
  String? cleanupWarning;
  void Function()? afterCommit;

  @override
  Future<void> resetRunningOutbox() async {
    resetRunningCount++;
    await super.resetRunningOutbox();
  }

  Future<void> _gate(String operation) async {
    if (gateOperation != operation) return;
    gateOperation = null;
    started.complete();
    await release.future;
  }

  @override
  Future<List<OutboxCommand>> outbox() async {
    await _gate('read');
    return super.outbox();
  }

  @override
  Future<Uint8List?> outboxPhoto(String commandId) async {
    await _gate('photo');
    return super.outboxPhoto(commandId);
  }

  @override
  Future<OutboxRecoveryCommit> recoverOutbox(
    List<OutboxCommand> expectedCommands, {
    OutboxCommand? replacement,
    List<String> serverIdKeys = const [],
    required void Function() ensureCurrent,
  }) async {
    await _gate('commit');
    if (failRecovery) throw StateError('disk full');
    final result = await super.recoverOutbox(
      expectedCommands,
      replacement: replacement,
      serverIdKeys: serverIdKeys,
      ensureCurrent: ensureCurrent,
    );
    if (result.committed) {
      afterCommit?.call();
      return OutboxRecoveryCommit(
        result.status,
        cleanupWarning: cleanupWarning,
      );
    }
    return result;
  }
}

AppController controller(
  MemoryLocalStore store, {
  Future<http.Response> Function(http.Request)? handler,
}) =>
    AppController(
        localStore: store,
        api: NaryadApi(
          server,
          client: MockClient(handler ?? (_) async => response({})),
        )..token = 'session-original',
      )
      ..user = worker
      ..orders = [WorkOrder.fromJson(order())]
      ..offline = true;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'inspection freezes report, materials, basis and all retained lane media',
    () async {
      final store = MemoryLocalStore();
      await store.enqueue(
        command('before-photo-0001', time: 1, kind: OutboxKind.uploadPhoto),
        photoBytes: Uint8List.fromList([1, 2, 3]),
      );
      final report = command(
        'report-command-0002',
        time: 2,
        responseStatus: 409,
        response: {'code': 'order_version_conflict'},
      );
      await store.enqueue(report);
      await store.enqueue(
        command('after-photo-0003', time: 3, kind: OutboxKind.uploadPhoto),
      );
      await store.enqueue(command('foreign-command-0004', time: 4, owner: 8));
      final c = controller(store);
      addTearDown(c.dispose);
      c.orders = [
        WorkOrder.fromJson({
          ...order(),
          'status': 'completed',
          '_server_status': 'in_progress',
          '_pending_sync': true,
          '_queued_status': 'completed',
        }),
      ];
      final original = jsonEncode(
        (await store.outbox()).map((item) => item.toJson()).toList(),
      );

      final result = await c.inspectCommand(report.commandId);
      expect(result.status, QueueRecoveryStatus.success);
      final detail = result.inspection!;
      expect(detail.command.payload, report.payload);
      expect(detail.command.expectedVersion, 7);
      expect(detail.commandIds, ['report-command-0002', 'after-photo-0003']);
      expect(detail.retainedPhotoCommands.map((item) => item.commandId), [
        'before-photo-0001',
        'after-photo-0003',
      ]);
      expect(detail.preparedPhotoBytesByCommandId['before-photo-0001'], [
        1,
        2,
        3,
      ]);
      expect(detail.mediaWarnings['after-photo-0003'], contains('недоступен'));
      expect(detail.cachedOrder!.status, 'in_progress');
      expect(detail.cachedOrder!.pendingSync, isFalse);
      expect(
        () => detail.command.payload['work_done'] = 'overwritten',
        throwsUnsupportedError,
      );
      expect(
        () => (detail.command.payload['materials'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () =>
            detail.preparedPhotoBytesByCommandId['before-photo-0001']![0] = 99,
        throwsUnsupportedError,
      );
      expect(
        jsonEncode(
          (await store.outbox()).map((item) => item.toJson()).toList(),
        ),
        original,
      );
    },
  );

  test(
    'foreign and legacy ownership cannot be guessed by inspection or recovery',
    () async {
      final store = MemoryLocalStore();
      await store.enqueue(command('foreign-owner-0001', owner: 8));
      await store.enqueue(
        command('foreign-server-0002', source: 'http://other.test/api'),
      );
      await store.enqueue(
        const OutboxCommand(
          commandId: 'legacy-command-0003',
          kind: OutboxKind.complete,
          createdAt: 3,
          payload: {'work_done': 'secret'},
        ),
      );
      final c = controller(store);
      addTearDown(c.dispose);
      for (final id in [
        'foreign-owner-0001',
        'foreign-server-0002',
        'legacy-command-0003',
      ]) {
        final inspected = await c.inspectCommand(id);
        expect(inspected.status, QueueRecoveryStatus.notFound);
        expect(inspected.inspection, isNull);
        expect((await c.retryCommand(id)).changed, isFalse);
        expect((await c.discardCommand(id)).changed, isFalse);
      }
      expect((await store.outbox()).length, 3);
    },
  );

  test('version conflict cannot retry and leaves retained report and photo untouched', () async {
    final store = MemoryLocalStore();
    await store.enqueue(
      command(
        'version-conflict-0001',
        responseStatus: 409,
        response: {'code': 'order_version_conflict'},
      ),
    );
    await store.enqueue(
      command(
        'dependent-photo-0002',
        time: 2,
        kind: OutboxKind.uploadPhoto,
        expectedVersion: null,
        previousCommandId: 'version-conflict-0001',
      ),
      photoBytes: Uint8List.fromList([4, 5]),
    );
    var writes = 0;
    final c = controller(
      store,
      handler: (_) async {
        writes++;
        return response({});
      },
    );
    addTearDown(c.dispose);
    final result = await c.retryCommand('version-conflict-0001');
    expect(result.status, QueueRecoveryStatus.notRetryable);
    expect(result.changed, isFalse);
    expect((await store.outbox()).first.expectedVersion, 7);
    expect(
      (await store.outbox()).last.previousCommandId,
      'version-conflict-0001',
    );
    expect(await store.outboxPhoto('dependent-photo-0002'), [4, 5]);
    expect(writes, 0);
  });

  test(
    'retry acknowledges only same durable command and retains unknown outcome',
    () async {
      final store = MemoryLocalStore();
      final original = command(
        'unknown-command-0001',
        attempts: 12,
        responseStatus: 503,
        lastError: 'Сервер мог сохранить действие',
      );
      await store.enqueue(original);
      final c = controller(store);
      addTearDown(c.dispose);
      c.orders = [WorkOrder.fromJson(order(version: 99))];
      final result = await c.retryCommand(original.commandId);
      expect(result.status, QueueRecoveryStatus.success);
      expect(result.changed, isTrue);
      final retained = (await store.outbox()).single;
      expect(retained.state, OutboxState.pending);
      expect(retained.attempts, 0);
      expect(retained.commandId, original.commandId);
      expect(retained.expectedVersion, 7);
      expect(retained.payload, original.payload);
      expect(retained.responseStatus, 503);
      expect(retained.lastError, original.lastError);
    },
  );

  test(
    'storage failure does not falsely acknowledge retry or chain deletion',
    () async {
      final store = _RecoveryStore()..failRecovery = true;
      final head = command('failed-head-0001');
      final tail = command(
        'failed-photo-0002',
        time: 2,
        kind: OutboxKind.uploadPhoto,
      );
      await store.enqueue(head);
      await store.enqueue(tail, photoBytes: Uint8List.fromList([6, 7]));
      final c = controller(store);
      addTearDown(c.dispose);
      for (final result in [
        await c.retryCommand(head.commandId),
        await c.discardCommand(
          head.commandId,
          expectedCommandIds: [head.commandId, tail.commandId],
        ),
      ]) {
        expect(result.status, QueueRecoveryStatus.storageFailure);
        expect(result.changed, isFalse);
      }
      expect((await store.outbox()).map((item) => item.commandId), [
        head.commandId,
        tail.commandId,
      ]);
      expect(await store.outboxPhoto(tail.commandId), [6, 7]);
      expect(c.recoveringQueue, isFalse);
    },
  );

  test(
    'discard refuses newly unreviewed successor and removes only chosen suffix',
    () async {
      final store = MemoryLocalStore();
      await store.enqueue(
        command('earlier-photo-0001', time: 1, kind: OutboxKind.uploadPhoto),
        photoBytes: Uint8List.fromList([1]),
      );
      await store.enqueue(command('selected-report-0002', time: 2));
      await store.enqueue(command('other-order-0003', time: 3, orderId: 10));
      await store.enqueue(
        command(
          'same-number-notification-0004',
          time: 4,
          kind: OutboxKind.markRead,
        ),
      );
      await store.enqueue(command('foreign-lane-0005', time: 5, owner: 8));
      final c = controller(store);
      addTearDown(c.dispose);
      final reviewed = (await c.inspectCommand('selected-report-0002'))
          .inspection!;
      await store.enqueue(
        command(
          'new-dependent-photo-0006',
          time: 6,
          kind: OutboxKind.uploadPhoto,
        ),
        photoBytes: Uint8List.fromList([2]),
      );
      final stale = await c.discardCommand(
        'selected-report-0002',
        expectedCommandIds: reviewed.commandIds,
      );
      expect(stale.status, QueueRecoveryStatus.changed);
      expect(stale.changed, isFalse);
      expect((await store.outbox()).length, 6);
      final fresh = (await c.inspectCommand('selected-report-0002'))
          .inspection!;
      final done = await c.discardCommand(
        'selected-report-0002',
        expectedCommandIds: fresh.commandIds,
      );
      expect(done.changed, isTrue);
      expect(done.commandIds, [
        'selected-report-0002',
        'new-dependent-photo-0006',
      ]);
      expect((await store.outbox()).map((item) => item.commandId), [
        'earlier-photo-0001',
        'other-order-0003',
        'same-number-notification-0004',
        'foreign-lane-0005',
      ]);
      expect(await store.outboxPhoto('earlier-photo-0001'), [1]);
      expect(await store.outboxPhoto('new-dependent-photo-0006'), isNull);
    },
  );

  test(
    'discard cannot silently accept same IDs with a changed reviewed response',
    () async {
      final store = MemoryLocalStore();
      final original = command(
        'reviewed-response-0001',
        responseStatus: 503,
        lastError: 'Результат неизвестен',
      );
      await store.enqueue(original);
      final c = controller(store);
      addTearDown(c.dispose);
      final reviewed = (await c.inspectCommand(original.commandId)).inspection!;
      final changed = original.copyWith(
        responseStatus: 409,
        response: {'code': 'order_version_conflict'},
        lastError: 'Версия изменилась',
      );
      await store.updateOutbox(changed);
      final result = await c.discardCommand(
        original.commandId,
        expectedCommandIds: reviewed.commandIds,
        expectedCommands: [reviewed.command, ...reviewed.dependentCommands],
      );
      expect(result.status, QueueRecoveryStatus.changed);
      expect(result.changed, isFalse);
      expect((await store.outbox()).single.toJson(), changed.toJson());
    },
  );

  for (final change in ['owner', 'server', 'token', 'role']) {
    test(
      '$change change while reading does not expose old command or mutate either scope',
      () async {
        final store = _RecoveryStore()..gateOperation = 'read';
        await store.enqueue(command('scoped-report-0001'));
        await store.enqueue(command('other-owner-0002', owner: 8));
        final c = controller(store);
        addTearDown(c.dispose);
        final inspecting = c.inspectCommand('scoped-report-0001');
        await store.started.future;
        switch (change) {
          case 'owner':
            c.user = const User(id: 8, name: 'Другой', role: 'worker');
          case 'server':
            c.api = NaryadApi(
              'http://other.test',
              client: MockClient((_) async => response({})),
            );
          case 'token':
            c.api.token = 'session-next';
          case 'role':
            c.user = const User(id: 7, name: 'Тот же', role: 'manager');
        }
        store.release.complete();
        final result = await inspecting;
        expect(result.status, QueueRecoveryStatus.scopeChanged);
        expect(result.inspection, isNull);
        expect((await store.outbox()).length, 2);
        expect(c.recoveringQueue, isFalse);
      },
    );
  }

  test(
    'photo-read session change does not leak prepared bytes or delete media',
    () async {
      final store = _RecoveryStore()..gateOperation = 'photo';
      await store.enqueue(
        command('photo-context-0001', kind: OutboxKind.uploadPhoto),
        photoBytes: Uint8List.fromList([11, 12]),
      );
      final c = controller(store);
      addTearDown(c.dispose);
      final pending = c.inspectCommand('photo-context-0001');
      await store.started.future;
      c.api.token = 'new-session';
      store.release.complete();
      final result = await pending;
      expect(result.status, QueueRecoveryStatus.scopeChanged);
      expect(result.inspection, isNull);
      expect(await store.outboxPhoto('photo-context-0001'), [11, 12]);
    },
  );

  test('recovery blocks enqueue, sync and another recovery; role loss before commit preserves rows', () async {
    final store = _RecoveryStore()..gateOperation = 'commit';
    await store.enqueue(command('locked-command-0001'));
    var requests = 0;
    final c = controller(
      store,
      handler: (_) async {
        requests++;
        return response({});
      },
    );
    addTearDown(c.dispose);
    final pending = c.discardCommand('locked-command-0001');
    await store.started.future;
    expect(c.recoveringQueue, isTrue);
    expect(
      (await c.retryCommand('locked-command-0001')).status,
      QueueRecoveryStatus.busy,
    );
    await expectLater(
      c.transition(9, 'pause', reason: 'cannot enqueue'),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'busy', 409)),
    );
    await c.syncOutbox();
    expect(requests, 0);
    c.user = const User(id: 7, name: 'Роль изменилась', role: 'manager');
    store.release.complete();
    final result = await pending;
    expect(result.status, QueueRecoveryStatus.scopeChanged);
    expect(result.changed, isFalse);
    expect((await store.outbox()).single.commandId, 'locked-command-0001');
    expect(c.recoveringQueue, isFalse);
  });

  test(
    'recovery cannot delete active sending command or its cached sync chain',
    () async {
      final store = MemoryLocalStore();
      await store.enqueue(
        command(
          'sending-command-0001',
          kind: OutboxKind.transition,
          state: OutboxState.pending,
          payload: {'action': 'start'},
        ),
      );
      await store.enqueue(
        command(
          'sending-photo-0002',
          time: 2,
          kind: OutboxKind.uploadPhoto,
          state: OutboxState.pending,
          expectedVersion: null,
          previousCommandId: 'sending-command-0001',
        ),
        photoBytes: Uint8List.fromList([8, 9]),
      );
      final started = Completer<void>();
      final reply = Completer<http.Response>();
      final c = controller(
        store,
        handler: (_) async {
          started.complete();
          return reply.future;
        },
      );
      addTearDown(c.dispose);
      final syncing = c.syncOutbox();
      await started.future;
      expect(
        (await c.discardCommand('sending-command-0001')).status,
        QueueRecoveryStatus.busy,
      );
      expect((await c.retryCommand('sending-command-0001')).changed, isFalse);
      reply.complete(response({'detail': 'Недостаточно прав'}, 403));
      await syncing;
      expect((await store.outbox()).length, 2);
      expect(await store.outboxPhoto('sending-photo-0002'), [8, 9]);
    },
  );

  test('D04 loss of responsibility retains report, draft, media and blocked exact replay', () async {
    final store = MemoryLocalStore();
    final head = command(
      'brigade-start-0001',
      kind: OutboxKind.transition,
      state: OutboxState.pending,
      payload: {'action': 'start'},
    );
    await store.enqueue(head);
    await store.enqueue(
      command(
        'brigade-photo-0002',
        time: 2,
        kind: OutboxKind.uploadPhoto,
        state: OutboxState.pending,
        expectedVersion: null,
        previousCommandId: head.commandId,
      ),
      photoBytes: Uint8List.fromList([10, 20]),
    );
    await store.enqueue(
      command(
        'brigade-report-0003',
        time: 3,
        state: OutboxState.pending,
        expectedVersion: null,
        previousCommandId: 'brigade-photo-0002',
      ),
    );
    final posts = <http.Request>[];
    final c = controller(
      store,
      handler: (request) async {
        posts.add(request);
        return response({
          'detail': 'Только ответственный может менять статус',
        }, 403);
      },
    );
    addTearDown(c.dispose);
    final draft = await c.openFormDraft(FormDraftKind.completion, orderId: 9);
    await draft.save(
      FormDraft(
        kind: FormDraftKind.completion,
        orderId: 9,
        data: {'work_done': 'Мой сохранённый отчёт'},
        basis: const OrderWriteBasis(expectedVersion: 7),
      ),
    );
    c.orders = [WorkOrder.fromJson(order(assignee: 8, version: 99))];
    await c.syncOutbox();
    await c.syncOutbox();
    expect(posts.length, 1);
    expect(posts.single.headers['x-client-command-id'], head.commandId);
    expect(posts.single.headers['x-expected-order-version'], '7');
    final retained = await store.outbox();
    expect(retained.first.state, OutboxState.conflict);
    expect(retained.first.responseStatus, 403);
    expect(retained.last.payload['work_done'], contains('уплотнение'));
    expect(retained.last.previousCommandId, 'brigade-photo-0002');
    expect(await store.outboxPhoto('brigade-photo-0002'), [10, 20]);
    expect((await draft.read())!.data['work_done'], 'Мой сохранённый отчёт');
    final retried = await c.retryCommand(head.commandId);
    expect(retried.changed, isTrue);
    expect((await store.outbox()).first.expectedVersion, 7);
    await c.syncOutbox();
    expect(posts.length, 2);
    expect(posts.last.headers['x-client-command-id'], head.commandId);
    expect((await store.outbox()).length, 3);
    expect(await store.outboxPhoto('brigade-photo-0002'), [10, 20]);
  });

  test('same-account relogin cannot reset or recover a live write and later replays its exact key', () async {
    final store = _RecoveryStore();
    final firstStarted = Completer<void>();
    final firstReply = Completer<http.Response>();
    final loginAnswered = Completer<void>();
    final replayStarted = Completer<void>();
    final replayReply = Completer<http.Response>();
    final initialPosts = <http.Request>[];
    final replayPosts = <http.Request>[];
    final report = {
      'work_done': 'Не потерять исходный отчёт',
      'materials': <Json>[],
    };
    final c =
        AppController(
            localStore: store,
            api: NaryadApi(
              server,
              client: MockClient((request) async {
                initialPosts.add(request);
                firstStarted.complete();
                return firstReply.future;
              }),
            )..token = 'old-session',
            apiFactory: (_) => NaryadApi(
              server,
              client: MockClient((request) async {
                if (request.url.path == '/api/auth/login') {
                  loginAnswered.complete();
                  return response({
                    'token': 'new-session',
                    'user': {
                      'id': worker.id,
                      'name': worker.name,
                      'role': worker.role,
                    },
                  });
                }
                if (request.method == 'POST') {
                  replayPosts.add(request);
                  replayStarted.complete();
                  return replayReply.future;
                }
                return switch (request.url.path) {
                  '/api/orders' => response([order(version: 99)]),
                  '/api/notifications' ||
                  '/api/employees' => response(<Json>[]),
                  _ => response(<String, dynamic>{}),
                };
              }),
            ),
          )
          ..user = worker
          ..orders = [WorkOrder.fromJson(order())];
    addTearDown(c.dispose);
    final originalWrite = c
        .complete(9, report, basis: const OrderWriteBasis(expectedVersion: 7))
        .then<Object>((value) => value, onError: (Object failure) => failure);
    await firstStarted.future;
    final retained = (await store.outbox()).single;
    expect(retained.state, OutboxState.running);
    expect(store.resetRunningCount, 1);
    final loggingIn = c.login(server, 'worker', '1234');
    await loginAnswered.future;
    await Future<void>.delayed(Duration.zero);
    expect(c.api.token, 'new-session');
    expect(c.user, isNull);
    expect(c.saving, isFalse);
    expect(store.resetRunningCount, 1);
    expect((await store.outbox()).single.state, OutboxState.running);
    // The live-write lock also protects a same-owner cached session that becomes
    // visible before login initialization finishes; UI saving was already reset.
    c.user = worker;
    expect(
      (await c.discardCommand(retained.commandId)).status,
      QueueRecoveryStatus.busy,
    );
    expect((await c.retryCommand(retained.commandId)).changed, isFalse);
    await expectLater(
      c.complete(9, report, basis: const OrderWriteBasis(expectedVersion: 99)),
      throwsA(
        isA<ApiException>().having(
          (error) => error.statusCode,
          'live write',
          409,
        ),
      ),
    );
    await c.syncOutbox();
    expect(replayPosts, isEmpty);
    expect((await store.outbox()).single.commandId, retained.commandId);
    c.user = null;
    firstReply.complete(response({'detail': 'Ответ потерян'}, 503));
    expect(await originalWrite, isA<ApiException>());
    await loggingIn;
    await replayStarted.future;
    expect(store.resetRunningCount, 2);
    expect(initialPosts.length, 1);
    expect(replayPosts.length, 1);
    expect(
      replayPosts.single.headers['x-client-command-id'],
      retained.commandId,
    );
    expect(replayPosts.single.headers['x-expected-order-version'], '7');
    expect(jsonDecode(replayPosts.single.body), report);
    expect(
      (await c.discardCommand(retained.commandId)).status,
      QueueRecoveryStatus.busy,
    );
    final draining = c.syncOutbox();
    replayReply.complete(response({'detail': 'Результат ещё неизвестен'}, 503));
    await draining;
    final saved = (await store.outbox()).single;
    expect(saved.commandId, retained.commandId);
    expect(saved.expectedVersion, 7);
    expect(saved.payload, report);
    expect(saved.responseStatus, 503);
  });

  test('scope change after commit is reported truthfully as committed to original scope', () async {
    final store = _RecoveryStore();
    await store.enqueue(command('commit-before-switch-0001'));
    await store.enqueue(command('keep-foreign-scope-0002', owner: 8));
    final c = controller(store);
    addTearDown(c.dispose);
    store.afterCommit = () {
      c.user = const User(id: 8, name: 'Другой', role: 'worker');
    };
    final result = await c.discardCommand('commit-before-switch-0001');
    expect(result.status, QueueRecoveryStatus.scopeChanged);
    expect(result.changed, isTrue);
    expect((await store.outbox()).single.commandId, 'keep-foreign-scope-0002');
  });

  test(
    'postcommit media warning never pretends durable deletion failed',
    () async {
      final store = _RecoveryStore()
        ..cleanupWarning = 'Фото не удалось очистить';
      await store.enqueue(command('warning-command-0001'));
      final c = controller(store);
      addTearDown(c.dispose);
      final result = await c.discardCommand('warning-command-0001');
      expect(result.status, QueueRecoveryStatus.success);
      expect(result.changed, isTrue);
      expect(result.warning, contains('Фото'));
      expect(await store.outbox(), isEmpty);
    },
  );
}
