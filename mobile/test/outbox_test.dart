import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';

Json orderJson(int id) => {
  'id': id,
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
  test(
    'offline creation enqueues into outbox and sync delivers an idempotent command',
    () async {
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
      expect(writes.single.headers['x-client-command-id'], matches(commandIdHeader));
      expect(writes.single.headers['x-client-command-id'], stored.commandId);
      expect(controller.outbox, isEmpty);
      expect(await store.outbox(), isEmpty);
      expect(await store.serverId('${order.id}'), 42);
      expect(controller.orders.single.id, 42);
      expect(controller.offline, isFalse);
    },
  );

  test(
    'dependent photo waits for its offline order to be resolved',
    () async {
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
              return jsonResponse({'ok': true}, 201);
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
    },
  );

  test(
    'server rejection during sync marks the command as conflict and retry heals it',
    () async {
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
    },
  );

  test(
    'explicit server rejection before enqueue keeps the write out of the outbox',
    () async {
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
        throwsA(isA<ApiException>().having(
          (e) => e.statusCode,
          'status',
          422,
        )),
      );
      expect(controller.outbox, isEmpty);
      expect(await store.outbox(), isEmpty);
    },
  );

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

      final order = await controller.createOrder({'title': 'Смазать подшипник'});
      expect(order.id, isNegative,
          reason: 'uncertain writes return a local placeholder for retry');
      expect(controller.hasPendingWrites, isTrue);
      expect((await store.outbox()).single.kind, OutboxKind.createOrder);

      failing = false;
      await controller.syncOutbox();

      expect(controller.outbox, isEmpty);
      expect(postedIds.length, 2);
      expect(postedIds[0], isNotNull);
      expect(postedIds[1], postedIds[0],
          reason: 'replay must reuse the same idempotency key');
    },
  );

  test(
    'sync never sends commands belonging to another account',
    () async {
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
          orderId: 3,
          payload: const {'action': 'close'},
        ),
      );

      await controller.syncOutbox();

      expect(posted, 0);
      expect((await store.outbox()).single.ownerId, 5);
    },
  );
}