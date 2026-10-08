import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';

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

http.Response snapshotResponse(http.Request request, {int id = 1}) =>
    switch (request.url.path) {
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('base URL accepts origin or API prefix without doubling api', () {
    expect(
      NaryadApi.normalizeBaseUrl(' http://localhost:8000/ '),
      'http://localhost:8000/api',
    );
    expect(
      NaryadApi.normalizeBaseUrl('https://example.test/app/api/'),
      'https://example.test/app/api',
    );
    for (final invalid in [
      'example.test',
      'file:///tmp',
      'https://a@b.test',
      'https://b.test?token=x',
    ]) {
      expect(
        () => NaryadApi.normalizeBaseUrl(invalid),
        throwsA(isA<ApiException>()),
      );
    }
  });

  test(
    'login clears old auth and subsequent requests use returned token',
    () async {
      final requests = <http.Request>[];
      final api = NaryadApi(
        'http://server.test',
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.path.endsWith('/login')) {
            return jsonResponse({
              'token': 'new-token',
              'user': {'id': 6, 'name': 'Работник', 'role': 'worker'},
            });
          }
          return jsonResponse({'id': 6, 'name': 'Работник', 'role': 'worker'});
        }),
      )..token = 'old-token';
      addTearDown(api.close);
      await api.login(' worker ', '1234');
      expect(requests.single.headers['authorization'], isNull);
      expect(jsonDecode(requests.single.body), {
        'login': 'worker',
        'pin': '1234',
      });
      expect((await api.me()).isWorker, isTrue);
      expect(requests.last.headers['authorization'], 'Bearer new-token');
    },
  );

  test(
    'transition sends reason and numeric score only when supplied',
    () async {
      late Json body;
      final api = NaryadApi(
        'http://server.test/api',
        client: MockClient((request) async {
          expect(request.url.path, '/api/orders/7/transition');
          body = jsonDecode(request.body) as Json;
          return jsonResponse(orderJson(7));
        }),
      );
      addTearDown(api.close);
      final result = await api.transition(7, 'accept');
      expect(body, {'action': 'accept'});
      expect(result.normalHours, 2.0);
      expect(result.score, isNull);
      await api.transition(7, 'close', score: 4.5);
      expect(body, {'action': 'close', 'score': 4.5});
    },
  );

  test(
    'protected photo download and multipart upload carry bearer token',
    () async {
      final requests = <http.Request>[];
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final api = NaryadApi(
        'http://server.test',
        client: MockClient((request) async {
          requests.add(request);
          if (request.method == 'GET') return http.Response.bytes(bytes, 200);
          return jsonResponse({'id': 9, 'order_version': 1}, 201);
        }),
      )..token = 'photo-token';
      addTearDown(api.close);
      expect(await api.photo(9), bytes);
      await api.uploadPhoto(7, bytes, 'repair.jpg', 'after');
      expect(
        requests.every(
          (r) => r.headers['authorization'] == 'Bearer photo-token',
        ),
        isTrue,
      );
      expect(
        requests.last.headers['content-type'],
        startsWith('multipart/form-data;'),
      );
      expect(requests.last.body, contains('name="kind"'));
      expect(requests.last.body, contains('after'));
      expect(requests.last.body, contains('filename="repair.jpg"'));
      expect(requests.last.url.path, '/api/orders/7/photos');
    },
  );

  test(
    'validation errors expose field details and have known rejection outcome',
    () async {
      final api = NaryadApi(
        'http://server.test',
        client: MockClient(
          (_) async => jsonResponse({
            'detail': [
              {
                'loc': ['body', 'deadline'],
                'msg': 'Укажите часовой пояс',
              },
            ],
          }, 422),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.createOrder({}),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'statusCode', 422)
              .having(
                (e) => e.message,
                'message',
                'deadline: Укажите часовой пояс',
              )
              .having((e) => e.requestMayHaveSucceeded, 'outcome', false),
        ),
      );
    },
  );

  test(
    'lost response never retries a write and marks its outcome unknown',
    () async {
      var writes = 0;
      final api = NaryadApi(
        'http://server.test',
        client: MockClient((request) async {
          if (request.method == 'POST') writes++;
          throw http.ClientException('Disconnected');
        }),
      );
      addTearDown(api.close);
      await expectLater(
        api.complete(7, {}),
        throwsA(
          isA<ApiException>().having(
            (e) => e.requestMayHaveSucceeded,
            'outcome',
            true,
          ),
        ),
      );
      expect(writes, 1);
      await expectLater(
        api.orders(),
        throwsA(
          isA<ApiException>().having(
            (e) => e.requestMayHaveSucceeded,
            'read outcome',
            false,
          ),
        ),
      );
    },
  );

  test('unreadable successful write response is not safe to repeat', () async {
    final api = NaryadApi(
      'http://server.test',
      client: MockClient((_) async => http.Response('<html>proxy</html>', 201)),
    );
    addTearDown(api.close);
    await expectLater(
      api.createOrder({}),
      throwsA(
        isA<ApiException>().having(
          (e) => e.requestMayHaveSucceeded,
          'outcome',
          true,
        ),
      ),
    );
  });

  test('refresh coalesces concurrent calls into one atomic snapshot', () async {
    final gate = Completer<void>();
    var reads = 0;
    final controller = AppController(
      localStore: MemoryLocalStore(),
      api: NaryadApi(
        'http://server.test',
        client: MockClient((request) async {
          reads++;
          await gate.future;
          return snapshotResponse(request);
        }),
      ),
    )..user = const User(id: 1, name: 'Мастер', role: 'master');
    addTearDown(controller.dispose);
    final first = controller.refresh();
    final second = controller.refresh();
    expect(identical(first, second), isTrue);
    gate.complete();
    await Future.wait([first, second]);
    expect(reads, 6);
    expect(controller.orders.single.id, 1);
    expect(controller.dashboard['issued'], 1);
    expect(controller.loading, isFalse);
    expect(controller.error, isNull);
  });

  test(
    'late previous-session refresh cannot overwrite a new user snapshot',
    () async {
      final gate = Completer<void>();
      final oldApi = NaryadApi(
        'http://old.test',
        client: MockClient((request) async {
          await gate.future;
          return snapshotResponse(request, id: 1);
        }),
      );
      final controller = AppController(
        localStore: MemoryLocalStore(),
        api: oldApi,
        apiFactory: (url) => NaryadApi(
          url,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/login')) {
              return jsonResponse({
                'token': 'next',
                'user': {'id': 2, 'name': 'Другой мастер', 'role': 'master'},
              });
            }
            return snapshotResponse(request, id: 2);
          }),
        ),
      )..user = const User(id: 1, name: 'Старый мастер', role: 'master');
      addTearDown(controller.dispose);
      final stale = controller.refresh();
      await controller.login('http://new.test', 'master2', '1234');
      gate.complete();
      await stale;
      expect(controller.user!.id, 2);
      expect(controller.orders.single.id, 2);
      expect(controller.dashboard['issued'], 2);
      expect(controller.error, isNull);
    },
  );

  test(
    'completed old-session write never returns private data after a new login',
    () async {
      final gate = Completer<void>();
      final refreshStarted = Completer<void>();
      final oldApi = NaryadApi(
        'http://old.test',
        client: MockClient((request) async {
          if (request.method == 'POST') return jsonResponse(orderJson(1), 201);
          if (!refreshStarted.isCompleted) refreshStarted.complete();
          await gate.future;
          return snapshotResponse(request, id: 1);
        }),
      );
      final controller = AppController(
        localStore: MemoryLocalStore(),
        api: oldApi,
        apiFactory: (url) => NaryadApi(
          url,
          client: MockClient((request) async {
            if (request.url.path.endsWith('/login')) {
              return jsonResponse({
                'token': 'next',
                'user': {'id': 2, 'name': 'Другой мастер', 'role': 'master'},
              });
            }
            return snapshotResponse(request, id: 2);
          }),
        ),
      )..user = const User(id: 1, name: 'Старый мастер', role: 'master');
      addTearDown(controller.dispose);
      final writing = controller.createOrder({});
      final rejected = expectLater(
        writing,
        throwsA(
          isA<ApiException>().having(
            (e) => e.requestMayHaveSucceeded,
            'do not repeat old write',
            true,
          ),
        ),
      );
      await refreshStarted.future;
      await controller.login('http://new.test', 'master2', '1234');
      gate.complete();
      await rejected;
      expect(controller.user!.id, 2);
      expect(controller.orders.single.id, 2);
      expect(controller.error, isNull);
    },
  );

  test('saved write stays successful when following refresh fails', () async {
    var writes = 0;
    final controller = AppController(
      localStore: MemoryLocalStore(),
      api: NaryadApi(
        'http://server.test',
        client: MockClient((request) async {
          if (request.method == 'POST') {
            writes++;
            return jsonResponse(orderJson(9), 201);
          }
          return jsonResponse({'detail': 'Сервис временно недоступен'}, 503);
        }),
      ),
    )..user = const User(id: 1, name: 'Мастер', role: 'master');
    addTearDown(controller.dispose);
    expect((await controller.createOrder({})).id, 9);
    expect(writes, 1);
    expect(controller.orders.single.id, 9);
    expect(controller.error, startsWith('Действие сохранено'));
    expect(controller.saving, isFalse);
  });

  test(
    'expired session clears private state and surfaces refresh failure',
    () async {
      final controller =
          AppController(
              localStore: MemoryLocalStore(),
              api: NaryadApi(
                'http://server.test',
                client: MockClient(
                  (_) async => jsonResponse({'detail': 'Session expired'}, 401),
                ),
              )..token = 'expired',
            )
            ..user = const User(id: 1, name: 'Мастер', role: 'master')
            ..orders = [WorkOrder.fromJson(orderJson(1))];
      addTearDown(controller.dispose);
      await expectLater(controller.refresh(), throwsA(isA<ApiException>()));
      expect(controller.user, isNull);
      expect(controller.api.token, isNull);
      expect(controller.orders, isEmpty);
      expect(controller.error, contains('Сессия истекла'));
    },
  );
}
