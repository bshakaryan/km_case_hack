import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/screens/completion_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

Json order({int version = 7, String status = 'in_progress'}) => {
  'id': 9,
  'version': version,
  'number': 'VERSION-9',
  'title': 'Проверить двигатель',
  'description': 'Проверить крепление.',
  'status': status,
  'priority': 'normal',
  'work_type': 'planned',
  'assignee_id': 7,
  'assignee_name': 'Исполнитель',
  'normal_hours': 2,
  'deadline': '2026-10-09T12:00:00Z',
  'created_at': '2026-10-08T10:00:00Z',
  'photos': <Json>[],
  'events': <Json>[],
  'is_overdue': false,
  'completion': {
    'work_done': 'Крепление проверено',
    'fault_code_id': 1,
    'comment': '',
    'materials': <Json>[],
  },
};

http.Response response(Object value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json'},
);

http.Response snapshot(http.Request request, {int version = 7}) =>
    switch (request.url.path) {
      '/api/orders' => response([order(version: version)]),
      '/api/orders/9' => response(order(version: version)),
      '/api/notifications' || '/api/employees' => response(<Json>[]),
      _ => response(<String, dynamic>{}),
    };

AppController controller(MemoryLocalStore store, MockClient client) =>
    AppController(
        localStore: store,
        api: NaryadApi('http://versions.test', client: client),
      )
      ..user = const User(id: 7, name: 'Исполнитель', role: 'worker')
      ..orders = [WorkOrder.fromJson(order())];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'a frozen old form never borrows a newer unrelated queued predecessor',
    () async {
      final store = MemoryLocalStore();
      final c = controller(store, MockClient((_) async => response({})))
        ..offline = true;
      addTearDown(c.dispose);
      final frozen = c.captureOrderBasis(c.orders.single);
      c.orders = [WorkOrder.fromJson(order(version: 8))];
      await c.transition(9, 'pause', reason: 'new action');
      final newCommand = (await store.outbox()).single;
      expect(newCommand.expectedVersion, 8);
      await c.complete(9, {'work_done': 'old form report'}, basis: frozen);
      final oldFormCommand = (await store.outbox()).last;
      expect(oldFormCommand.expectedVersion, 7);
      expect(oldFormCommand.previousCommandId, isNull);
      expect(oldFormCommand.payload['work_done'], 'old form report');
    },
  );

  test(
    'a form opened after its own queued start captures that exact predecessor',
    () async {
      final store = MemoryLocalStore();
      final c = controller(store, MockClient((_) async => response({})))
        ..offline = true;
      addTearDown(c.dispose);
      await c.transition(9, 'start');
      final start = (await store.outbox()).single;
      final frozen = c.captureOrderBasis(c.orders.single);
      expect(frozen.previousCommandId, start.commandId);
      c.orders = [WorkOrder.fromJson(order(version: 99))];
      await c.complete(9, {'work_done': 'own chain report'}, basis: frozen);
      final report = (await store.outbox()).last;
      expect(report.previousCommandId, start.commandId);
      expect(report.expectedVersion, isNull);
    },
  );

  test(
    'a versionless legacy replay preserves a known newer order snapshot',
    () {
      final known = WorkOrder.fromJson(order(version: 12, status: 'completed'));
      final old = WorkOrder.fromJson(
        {...order(status: 'issued')}..remove('version'),
      );
      final merged = old.withCachedHistory(known);
      expect(merged.version, 12);
      expect(merged.status, 'completed');
      expect(identical(merged, known), isTrue);
    },
  );

  test('an unusable successful write receipt keeps its original key and version for reconciliation', () async {
    final store = MemoryLocalStore();
    String? postedKey;
    final c = controller(
      store,
      MockClient((request) async {
        postedKey = request.headers['x-client-command-id'];
        return response({...order(status: 'paused')}..remove('version'));
      }),
    );
    addTearDown(c.dispose);
    final projected = await c.transition(9, 'pause', reason: 'keep original');
    expect(projected.pendingSync, isTrue);
    final command = (await store.outbox()).single;
    expect(command.commandId, postedKey);
    expect(command.expectedVersion, 7);
    expect(command.payload['reason'], 'keep original');
    expect(command.state, OutboxState.pending);
  });

  test(
    'persisted version and predecessor survive state changes without rebasing',
    () {
      const command = OutboxCommand(
        commandId: 'command-0001',
        kind: OutboxKind.complete,
        createdAt: 1,
        ownerId: 7,
        serverUrl: 'http://versions.test/api',
        orderId: 9,
        expectedVersion: 7,
        payload: {'work_done': 'original'},
      );
      final restored = OutboxCommand.fromJson(
        jsonDecode(jsonEncode(command.toJson())) as Json,
      );
      final retried = restored.copyWith(
        state: OutboxState.pending,
        attempts: 0,
      );
      expect(retried.expectedVersion, 7);
      expect(retried.previousCommandId, isNull);
      expect(retried.commandId, command.commandId);
      expect(retried.payload, command.payload);
      expect(retried.hasOrderPrecondition, isTrue);
      expect(
        const OutboxCommand(
          commandId: 'command-0002',
          kind: OutboxKind.complete,
          createdAt: 2,
          expectedVersion: 7,
          previousCommandId: 'command-0001',
        ).hasOrderPrecondition,
        isFalse,
      );
    },
  );

  test('offline own commands use immutable predecessor receipts after the first version', () async {
    final store = MemoryLocalStore();
    final writes = <http.Request>[];
    var serverVersion = 7;
    String? lastKey;
    final c = controller(
      store,
      MockClient((request) async {
        if (request.method == 'POST') {
          writes.add(request);
          if (writes.length == 1) {
            expect(request.headers['x-expected-order-version'], '7');
            expect(request.headers['x-previous-client-command-id'], isNull);
          } else {
            expect(request.headers['x-expected-order-version'], isNull);
            expect(request.headers['x-previous-client-command-id'], lastKey);
          }
          lastKey = request.headers['x-client-command-id'];
          serverVersion++;
          return request.url.path.endsWith('/photos')
              ? response({'id': 50, 'order_version': serverVersion}, 201)
              : response(order(version: serverVersion));
        }
        return snapshot(request, version: serverVersion);
      }),
    )..offline = true;
    addTearDown(c.dispose);
    await c.transition(9, 'accept');
    await c.transition(9, 'start');
    await c.uploadPhoto(9, Uint8List.fromList([1, 2, 3]), 'after.jpg', 'after');
    await c.complete(9, {'work_done': 'Done', 'fault_code_id': 1});
    final saved = await store.outbox();
    expect(saved.first.expectedVersion, 7);
    for (var i = 1; i < saved.length; i++) {
      expect(saved[i].expectedVersion, isNull);
      expect(saved[i].previousCommandId, saved[i - 1].commandId);
    }
    c.orders = [WorkOrder.fromJson(order(version: 99))];
    await c.syncOutbox();
    expect(writes, hasLength(4));
    expect(await store.outbox(), isEmpty);
  });

  test('unknown outcome replays exactly the old key payload and version after restart', () async {
    final store = MemoryLocalStore();
    late http.Request firstWrite;
    final first = controller(
      store,
      MockClient((request) async {
        firstWrite = request;
        return response({'detail': 'temporary failure'}, 503);
      }),
    );
    await first.transition(9, 'pause', reason: 'original reason');
    final pending = (await store.outbox()).single;
    expect(pending.expectedVersion, 7);
    first.dispose();
    final writes = <http.Request>[];
    final restored = controller(
      store,
      MockClient((request) async {
        if (request.method == 'POST') {
          writes.add(request);
          return response(order(version: 8, status: 'paused'));
        }
        return snapshot(request, version: 12);
      }),
    )..orders = [WorkOrder.fromJson(order(version: 12))];
    addTearDown(restored.dispose);
    await restored.syncOutbox();
    expect(
      writes.single.headers['x-client-command-id'],
      firstWrite.headers['x-client-command-id'],
    );
    expect(writes.single.headers['x-expected-order-version'], '7');
    expect(jsonDecode(writes.single.body), jsonDecode(firstWrite.body));
    expect(restored.orders.single.version, 12);
    expect(await store.outbox(), isEmpty);
  });

  test('stale conflict keeps media, blocks successors and cannot retry with a fresh version', () async {
    final store = MemoryLocalStore();
    var writes = 0;
    final bytes = Uint8List.fromList([8, 9, 10]);
    final c = controller(
      store,
      MockClient((request) async {
        if (request.method == 'POST') {
          writes++;
          return response({
            'detail': {
              'code': 'order_version_conflict',
              'message': 'Наряд изменён другим действием.',
              'expected_version': 7,
              'current_version': 8,
            },
          }, 409);
        }
        return snapshot(request, version: 8);
      }),
    )..offline = true;
    addTearDown(c.dispose);
    await c.uploadPhoto(9, bytes, 'after.jpg', 'after');
    await c.complete(9, {'work_done': 'Saved report', 'fault_code_id': 1});
    await c.syncOutbox();
    final commands = await store.outbox();
    expect(commands.first.state, OutboxState.conflict);
    expect(commands.first.response?['code'], 'order_version_conflict');
    expect(commands.first.canRetry, isFalse);
    expect(await store.outboxPhoto(commands.first.commandId), bytes);
    expect(commands.last.state, OutboxState.pending);
    expect(
      c.orders.single.status,
      'in_progress',
      reason: 'A blocked report must not project a submitted state.',
    );
    c.orders = [WorkOrder.fromJson(order(version: 8))];
    await c.retryCommand(commands.first.commandId);
    await c.syncOutbox();
    expect(writes, 1);
    expect((await store.outbox()).first.expectedVersion, 7);
    await c.discardCommand(commands.first.commandId);
    expect(await store.outbox(), isEmpty);
    expect(await store.outboxPhoto(commands.first.commandId), isNull);
  });

  test(
    'legacy bound-order queue is quarantined without losing text or media',
    () async {
      final store = MemoryLocalStore();
      final bytes = Uint8List.fromList([3, 4]);
      await store.enqueue(
        const OutboxCommand(
          commandId: 'legacy-command-0001',
          kind: OutboxKind.uploadPhoto,
          createdAt: 1,
          ownerId: 7,
          serverUrl: 'http://versions.test/api',
          orderId: 9,
          state: OutboxState.running,
          payload: {'description': 'keep this text'},
          photoKind: 'after',
        ),
        photoBytes: bytes,
      );
      var writes = 0;
      final c = controller(
        store,
        MockClient((request) async {
          if (request.method == 'POST') writes++;
          return snapshot(request);
        }),
      );
      addTearDown(c.dispose);
      await c.syncOutbox();
      final saved = (await store.outbox()).single;
      expect(writes, 0);
      expect(saved.state, OutboxState.conflict);
      expect(saved.canRetry, isFalse);
      expect(saved.commandId, 'legacy-command-0001');
      expect(saved.payload['description'], 'keep this text');
      expect(await store.outboxPhoto(saved.commandId), bytes);
    },
  );

  test(
    'versionless cached orders save a recoverable conflict and never POST',
    () async {
      final store = MemoryLocalStore();
      var writes = 0;
      final c =
          controller(
              store,
              MockClient((request) async {
                writes++;
                return response({});
              }),
            )
            ..orders = [
              WorkOrder.fromJson({...order()}..remove('version')),
            ];
      addTearDown(c.dispose);
      await expectLater(
        c.complete(9, {'work_done': 'keep report'}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 428)),
      );
      expect(writes, 0);
      final saved = (await store.outbox()).single;
      expect(saved.state, OutboxState.conflict);
      expect(saved.payload['work_done'], 'keep report');
    },
  );

  testWidgets(
    'an open report keeps its original version when the controller refreshes',
    (tester) async {
      final store = MemoryLocalStore();
      String? sentVersion;
      final c =
          controller(
              store,
              MockClient((request) async {
                sentVersion = request.headers['x-expected-order-version'];
                return response({
                  'detail': {
                    'code': 'order_version_conflict',
                    'message': 'Наряд изменён.',
                    'expected_version': 7,
                    'current_version': 8,
                  },
                }, 409);
              }),
            )
            ..reference = {
              'fault_codes': [
                {'id': 1, 'code': 'F01', 'name': 'Износ'},
              ],
              'materials': <Json>[],
            };
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: CompletionScreen(controller: c, order: c.orders.single),
        ),
      );
      await tester.pumpAndSettle();
      c.orders = [WorkOrder.fromJson(order(version: 8))];
      await tester.tap(find.text('Отправить на приёмку'));
      await tester.pumpAndSettle();
      expect(sentVersion, '7');
      final saved = (await store.outbox()).single;
      expect(saved.expectedVersion, 7);
      expect(saved.payload['work_done'], 'Крепление проверено');
      expect(find.text('Крепление проверено'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Отправить на приёмку'),
            )
            .onPressed,
        isNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
