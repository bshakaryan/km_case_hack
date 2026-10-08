import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingEnqueueStore extends MemoryLocalStore {
  @override
  Future<OutboxCommand> enqueue(
    OutboxCommand command, {
    Uint8List? photoBytes,
  }) async {
    throw StateError('simulated disk full');
  }
}

OutboxCommand queuedCommand(
  String id, {
  String kind = OutboxKind.transition,
  int time = 1,
  int ownerId = 7,
  String? serverUrl = 'http://server.test/api',
  String state = OutboxState.pending,
  Json payload = const {'action': 'accept'},
}) => OutboxCommand(
  commandId: id,
  kind: kind,
  createdAt: time,
  ownerId: ownerId,
  serverUrl: serverUrl,
  orderId: 9,
  expectedVersion: 1,
  state: state,
  payload: payload,
);

Json orderJson(int id) => {
  'id': id,
  'version': 1,
  'number': 'Н-$id',
  'title': 'Проверить двигатель',
  'description': 'Перегрев двигателя',
  'status': 'issued',
  'priority': 'high',
  'work_type': 'unplanned',
  'area_name': 'Цех',
  'equipment_name': 'Двигатель',
  'assignee_name': 'Исполнитель',
  'deadline': '2026-10-06T10:00:00Z',
  'is_overdue': false,
  'normal_hours': 2,
  'score': null,
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

http.Response snapshotResponse(http.Request request, {int id = 1}) {
  if (request.method != 'GET') return jsonResponse({'ok': true});
  return switch (request.url.path) {
    '/api/reference' => jsonResponse({'areas': []}),
    '/api/employees' => jsonResponse(<Json>[]),
    '/api/orders' => jsonResponse([orderJson(id)]),
    '/api/dashboard' => jsonResponse({'issued': id}),
    '/api/notifications' => jsonResponse(<Json>[]),
    '/api/analytics' => jsonResponse({
      'summary': {'total': id},
    }),
    _ => jsonResponse({'ok': true}),
  };
}

final commandIdHeader = RegExp(r'^[A-Za-z0-9._:-]{8,64}$');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });
  test('offline creation enqueues into outbox and sync delivers an idempotent command', () async {
    final store = MemoryLocalStore();
    await store.open();
    final posted = <http.Request>[];
    var offline = true;
    final controller = AppController(
      api: NaryadApi(
        'http://server.test/api',
        client: MockClient((request) async {
          if (offline) throw http.ClientException('offline');
          posted.add(request);
          if (request.method == 'POST' &&
              request.url.path.endsWith('/orders')) {
            expect(
              request.headers['x-client-command-id'],
              matches(commandIdHeader),
            );
            return jsonResponse(orderJson(42), 201);
          }
          return snapshotResponse(request, id: 42);
        }),
      ),
      localStore: store,
    )..user = const User(id: 7, name: 'Исполнитель', role: 'worker');
    addTearDown(controller.dispose);

    final order = await controller.createOrder({'title': 'Проверить насос'});
    expect(order.id, isNegative);
    expect(controller.offline, isTrue);
    expect(controller.hasPendingWrites, isTrue);
    final stored = (await store.outbox()).single;
    expect(stored.kind, OutboxKind.createOrder);
    expect(stored.localRef, '${order.id}');

    offline = false;
    await controller.syncOutbox();

    final writes = posted.where((r) => r.method != 'GET').toList();
    expect(
      writes.single.headers['x-client-command-id'],
      matches(commandIdHeader),
    );
    expect(writes.single.headers['x-client-command-id'], stored.commandId);
    expect(controller.outbox, isEmpty);
    expect(await store.outbox(), isEmpty);
    expect(
      await store.serverId(
        localScopeKey('http://server.test/api', 7, '${order.id}'),
      ),
      42,
    );
    expect(controller.orders.single.id, 42);
    expect(controller.offline, isFalse);
  });

  test('dependent photo waits for its offline order to be resolved', () async {
    final store = MemoryLocalStore();
    await store.open();
    final photoPaths = <String>[];
    var offline = true;
    final controller = AppController(
      api: NaryadApi(
        'http://server.test/api',
        client: MockClient((request) async {
          if (offline) throw http.ClientException('offline');
          if (request.method == 'POST' &&
              request.url.path.endsWith('/orders')) {
            return jsonResponse(orderJson(42), 201);
          }
          if (request.method == 'PUT' ||
              (request.method == 'POST' &&
                  request.url.path.endsWith('/photos'))) {
            photoPaths.add(request.url.path);
            return jsonResponse({'ok': true, 'order_version': 1}, 201);
          }
          return snapshotResponse(request, id: 42);
        }),
      ),
      localStore: store,
    )..user = const User(id: 7, name: 'Исполнитель', role: 'worker');
    addTearDown(controller.dispose);

    final order = await controller.createOrder({'title': 'Заменить прокладку'});
    final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
    await controller.uploadPhoto(order.id, bytes, 'before.png', 'before');
    final photoCommand = controller.outbox
        .where((item) => item.kind == OutboxKind.uploadPhoto)
        .single;
    expect(photoCommand.orderId, isNull);
    expect(photoCommand.localRef, '${order.id}');
    expect(await store.outboxPhoto(photoCommand.commandId), bytes);

    offline = false;
    await controller.syncOutbox();

    expect(await store.outbox(), isEmpty);
    expect(photoPaths, ['/api/orders/42/photos']);
    expect(await store.outboxPhoto(photoCommand.commandId), isNull);
  });

  test('server rejection during sync marks the command as conflict and retry heals it', () async {
    final store = MemoryLocalStore();
    await store.open();
    var reject = true;
    var online = false;
    final posted = <http.Request>[];
    var transitions = 0;
    final controller = AppController(
      api: NaryadApi(
        'http://server.test/api',
        client: MockClient((request) async {
          if (!online) throw http.ClientException('offline');
          posted.add(request);
          if (request.method == 'POST' &&
              request.url.path.endsWith('/transition')) {
            transitions++;
            if (reject) {
              return jsonResponse({'detail': 'Наряд уже закрыт.'}, 409);
            }
            return jsonResponse(orderJson(9));
          }
          return snapshotResponse(request, id: 9);
        }),
      ),
      localStore: store,
    )..user = const User(id: 7, name: 'Исполнитель', role: 'worker');
    addTearDown(controller.dispose);

    controller.orders = [WorkOrder.fromJson(orderJson(9))];
    final queued = await controller.transition(9, 'close', score: 4);
    expect(queued.id, 9);
    expect(controller.hasPendingWrites, isTrue);

    online = true;
    await controller.syncOutbox();

    expect(controller.conflictCommands.single.kind, OutboxKind.transition);
    expect(controller.conflictCommands.single.lastError, contains('закрыт'));
    expect(controller.conflictCommands.single.attempts, 1);

    reject = false;
    await controller.retryCommand(controller.conflictCommands.single.commandId);
    await controller.syncOutbox();

    expect(controller.outbox, isEmpty);
    expect(transitions, greaterThanOrEqualTo(2));
    final transitionPosts = posted
        .where((r) => r.url.path.endsWith('/transition'))
        .toList();
    expect(
      transitionPosts.every(
        (r) => r.headers.containsKey('x-client-command-id'),
      ),
      isTrue,
    );
  });

  test('explicit server rejection before enqueue keeps the write out of the outbox', () async {
    final store = MemoryLocalStore();
    await store.open();
    final controller = AppController(
      api: NaryadApi(
        'http://server.test/api',
        client: MockClient((request) async {
          return jsonResponse({'detail': 'Описание обязательно'}, 422);
        }),
      ),
      localStore: store,
    )..user = const User(id: 7, name: 'Исполнитель', role: 'worker');
    addTearDown(controller.dispose);

    await expectLater(
      controller.createOrder({'title': ''}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 422)),
    );
    expect(controller.outbox, isEmpty);
    expect(await store.outbox(), isEmpty);
  });

  test(
    'an uncertain server outcome is kept once and replayed with the same key',
    () async {
      final store = MemoryLocalStore();
      await store.open();
      var failing = true;
      final postedIds = <String?>[];
      final controller = AppController(
        api: NaryadApi(
          'http://server.test/api',
          client: MockClient((request) async {
            if (request.method == 'POST' &&
                request.url.path.endsWith('/orders')) {
              postedIds.add(request.headers['x-client-command-id']);
              if (failing) {
                return jsonResponse({'detail': 'Внутренняя ошибка'}, 503);
              }
              return jsonResponse(orderJson(5), 201);
            }
            return snapshotResponse(request, id: 5);
          }),
        ),
        localStore: store,
      )..user = const User(id: 7, name: 'Исполнитель', role: 'worker');
      addTearDown(controller.dispose);

      final order = await controller.createOrder({
        'title': 'Смазать подшипник',
      });
      expect(
        order.id,
        isNegative,
        reason: 'uncertain writes return a local placeholder for retry',
      );
      expect(controller.hasPendingWrites, isTrue);
      expect((await store.outbox()).single.kind, OutboxKind.createOrder);

      failing = false;
      await controller.syncOutbox();

      expect(controller.outbox, isEmpty);
      expect(postedIds.length, 2);
      expect(postedIds[0], isNotNull);
      expect(
        postedIds[1],
        postedIds[0],
        reason: 'replay must reuse the same idempotency key',
      );
    },
  );

  test('sync never sends commands belonging to another account', () async {
    final store = MemoryLocalStore();
    await store.open();
    var posted = 0;
    final controller = AppController(
      api: NaryadApi(
        'http://server.test/api',
        client: MockClient((request) async {
          posted++;
          return snapshotResponse(request, id: 3);
        }),
      ),
      localStore: store,
    )..user = const User(id: 7, name: 'Исполнитель', role: 'worker');
    addTearDown(controller.dispose);

    await store.enqueue(
      OutboxCommand(
        commandId: 'foreign-command-0001',
        kind: OutboxKind.transition,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        ownerId: 5,
        serverUrl: 'http://server.test/api',
        orderId: 3,
        payload: const {'action': 'close'},
      ),
    );

    await controller.syncOutbox();

    expect(posted, 0);
    expect((await store.outbox()).single.ownerId, 5);
  });

  test(
    'server and account scopes isolate commands and legacy quarantine',
    () async {
      final store = MemoryLocalStore();
      await store.enqueue(queuedCommand('server-a-0001'));
      await store.enqueue(queuedCommand('legacy-0001', serverUrl: null));
      await store.enqueue(
        queuedCommand(
          'other-user-0001',
          ownerId: 8,
          serverUrl: 'http://server-b.test/api',
        ),
      );
      var writes = 0;
      final controller = AppController(
        localStore: store,
        api: NaryadApi(
          'http://server-b.test',
          client: MockClient((request) async {
            if (request.method != 'GET') writes++;
            return snapshotResponse(request);
          }),
        ),
      )..user = const User(id: 7, name: 'Worker', role: 'worker');
      addTearDown(controller.dispose);
      await controller.refresh();
      await controller.syncOutbox();
      expect(writes, 0);
      expect(
        controller.outbox,
        isEmpty,
        reason: 'Foreign metadata is not exposed.',
      );
      expect((await store.outbox()).length, 3);
      expect(
        (await store.outbox())
            .firstWhere((c) => c.commandId == 'legacy-0001')
            .state,
        OutboxState.conflict,
      );
      await controller.retryCommand('server-a-0001');
      await controller.discardCommand('server-a-0001');
      expect(
        (await store.outbox()).length,
        3,
        reason: 'A guessed foreign command ID cannot change its stored data.',
      );
    },
  );

  test(
    '401 preserves pending key and fresh login resumes without restart',
    () async {
      final store = MemoryLocalStore();
      await store.enqueue(queuedCommand('expire-command-0001'));
      final keys = <String?>[];
      final controller = AppController(
        localStore: store,
        api: NaryadApi(
          'http://server.test',
          client: MockClient((request) async {
            keys.add(request.headers['x-client-command-id']);
            return jsonResponse({'detail': 'Expired'}, 401);
          }),
        ),
        apiFactory: (url) => NaryadApi(
          url,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/auth/login')) {
              return jsonResponse({
                'token': 'test-session',
                'user': {'id': 7, 'name': 'Worker', 'role': 'worker'},
              });
            }
            if (request.url.path.endsWith('/transition')) {
              keys.add(request.headers['x-client-command-id']);
              return jsonResponse(orderJson(9));
            }
            return snapshotResponse(request, id: 9);
          }),
        ),
      )..user = const User(id: 7, name: 'Worker', role: 'worker');
      addTearDown(controller.dispose);
      await controller.syncOutbox();
      expect(controller.user, isNull);
      expect((await store.outbox()).single.state, OutboxState.pending);
      await controller.login('http://server.test', 'worker', '1234');
      await controller.syncOutbox();
      expect(await store.outbox(), isEmpty);
      expect(keys, ['expire-command-0001', 'expire-command-0001']);
    },
  );

  test(
    'key is durable before HTTP and survives interrupted controller',
    () async {
      final store = MemoryLocalStore();
      final started = Completer<void>();
      final response = Completer<http.Response>();
      String? originalKey;
      final first = AppController(
        localStore: store,
        api: NaryadApi(
          'http://server.test',
          client: MockClient((request) async {
            originalKey = request.headers['x-client-command-id'];
            final saved = (await store.outbox()).single;
            expect(saved.commandId, originalKey);
            expect(saved.state, OutboxState.running);
            started.complete();
            return response.future;
          }),
        ),
      )..user = const User(id: 7, name: 'Worker', role: 'worker');
      final pending = first.createOrder({'title': 'Durable order'});
      await started.future;
      first.dispose();
      response.complete(jsonResponse({'detail': 'Connection lost'}, 503));
      await expectLater(pending, throwsA(isA<ApiException>()));
      expect((await store.outbox()).single.commandId, originalKey);
      String? replayKey;
      final restored = AppController(
        localStore: store,
        api: NaryadApi(
          'http://server.test',
          client: MockClient((request) async {
            if (request.method == 'POST') {
              replayKey = request.headers['x-client-command-id'];
              return jsonResponse(orderJson(42), 201);
            }
            return snapshotResponse(request, id: 42);
          }),
        ),
      )..user = const User(id: 7, name: 'Worker', role: 'worker');
      addTearDown(restored.dispose);
      await restored.syncOutbox();
      expect(replayKey, originalKey);
      expect(await store.outbox(), isEmpty);
    },
  );

  test(
    'media is saved before HTTP; disk failure prevents any HTTP write',
    () async {
      final store = MemoryLocalStore();
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final controller = AppController(
        localStore: store,
        api: NaryadApi(
          'http://server.test',
          client: MockClient((request) async {
            final command = (await store.outbox()).single;
            expect(await store.outboxPhoto(command.commandId), bytes);
            throw http.ClientException('offline');
          }),
        ),
      )..user = const User(id: 7, name: 'Worker', role: 'worker');
      addTearDown(controller.dispose);
      controller.orders = [WorkOrder.fromJson(orderJson(9))];
      await controller.uploadPhoto(9, bytes, 'after.jpg', 'after');
      expect((await store.outbox()).single.state, OutboxState.pending);
      var calls = 0;
      final failed = AppController(
        localStore: _FailingEnqueueStore(),
        api: NaryadApi(
          'http://server.test',
          client: MockClient((request) async {
            calls++;
            return jsonResponse(orderJson(9));
          }),
        ),
      )..user = const User(id: 7, name: 'Worker', role: 'worker');
      addTearDown(failed.dispose);
      await expectLater(
        failed.createOrder({'title': 'Not sent'}),
        throwsA(
          isA<ApiException>().having((e) => e.statusCode, 'local failure', 507),
        ),
      );
      expect(calls, 0);
    },
  );

  test('concurrent sync calls share a pass and do not send twice', () async {
    final store = MemoryLocalStore();
    await store.enqueue(queuedCommand('concurrent-command-0001'));
    final started = Completer<void>();
    final release = Completer<void>();
    var writes = 0;
    final controller = AppController(
      localStore: store,
      api: NaryadApi(
        'http://server.test',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            writes++;
            started.complete();
            await release.future;
            return jsonResponse(orderJson(9));
          }
          return snapshotResponse(request, id: 9);
        }),
      ),
    )..user = const User(id: 7, name: 'Worker', role: 'worker');
    addTearDown(controller.dispose);
    final first = controller.syncOutbox();
    await started.future;
    final second = controller.syncOutbox();
    expect(identical(first, second), isTrue);
    release.complete();
    await Future.wait([first, second]);
    expect(writes, 1);
    expect(await store.outbox(), isEmpty);
  });

  test(
    'rejected predecessor blocks later photo and report on same order',
    () async {
      final store = MemoryLocalStore();
      await store.enqueue(
        queuedCommand('start-command-0001', payload: const {'action': 'start'}),
      );
      await store.enqueue(
        queuedCommand(
          'photo-command-0001',
          time: 2,
          kind: OutboxKind.uploadPhoto,
        ),
        photoBytes: Uint8List.fromList([1]),
      );
      await store.enqueue(
        queuedCommand(
          'report-command-0001',
          time: 3,
          kind: OutboxKind.complete,
          payload: const {'work_done': 'Done', 'materials': []},
        ),
      );
      final writes = <String>[];
      final controller = AppController(
        localStore: store,
        api: NaryadApi(
          'http://server.test',
          client: MockClient((request) async {
            if (request.method != 'GET') writes.add(request.url.path);
            return jsonResponse({'detail': 'Order already closed'}, 409);
          }),
        ),
      )..user = const User(id: 7, name: 'Worker', role: 'worker');
      addTearDown(controller.dispose);
      await controller.syncOutbox();
      await controller.syncOutbox();
      expect(writes, ['/api/orders/9/transition']);
      final commands = await store.outbox();
      expect(commands.map((c) => c.state), [
        OutboxState.conflict,
        OutboxState.pending,
        OutboxState.pending,
      ]);
      expect(await store.outboxPhoto('photo-command-0001'), isNotNull);
    },
  );

  test(
    'queued write drains an older refresh before fetching confirmed state',
    () async {
      final store = MemoryLocalStore();
      await store.enqueue(queuedCommand('stale-read-command-0001'));
      final readStarted = Completer<void>();
      final oldOrders = Completer<http.Response>();
      final writeFinished = Completer<void>();
      var orderReads = 0;
      final controller = AppController(
        localStore: store,
        api: NaryadApi(
          'http://server.test',
          client: MockClient((request) async {
            if (request.method == 'POST') {
              writeFinished.complete();
              return jsonResponse(orderJson(9)..['status'] = 'accepted');
            }
            if (request.url.path == '/api/orders') {
              orderReads++;
              if (orderReads == 1) {
                readStarted.complete();
                return oldOrders.future;
              }
              return jsonResponse([orderJson(9)..['status'] = 'accepted']);
            }
            return snapshotResponse(request, id: 9);
          }),
        ),
      )..user = const User(id: 7, name: 'Worker', role: 'worker');
      addTearDown(controller.dispose);
      final reading = controller.refresh();
      await readStarted.future;
      final syncing = controller.syncOutbox();
      await writeFinished.future;
      // Let the completed POST propagate into the controller before delivering
      // the older server response. This is deterministic, with no real HTTP.
      await Future<void>.delayed(Duration.zero);
      oldOrders.complete(jsonResponse([orderJson(9)]));
      await Future.wait([reading, syncing]);
      expect(orderReads, 2);
      expect(controller.orders.single.status, 'accepted');
      expect(controller.isOrderPending(9), isFalse);
    },
  );
}
