import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

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

http.Response snapshotResponse(http.Request request, {int id = 7}) =>
    switch (request.url.path) {
      '/api/reference' => jsonResponse({'areas': []}),
      '/api/employees' => jsonResponse(<Json>[]),
      '/api/orders' => jsonResponse(<Json>[orderJson(id)]),
      '/api/dashboard' => jsonResponse({'issued': id}),
      '/api/notifications' => jsonResponse(<Json>[]),
      '/api/analytics' => jsonResponse({
        'summary': {'total': id},
      }),
      _ => jsonResponse({'ok': true}),
    };

MockClient mockApi({required int id}) => MockClient((request) async {
  if (request.url.path.endsWith('/auth/me')) {
    return jsonResponse({'id': id, 'name': 'Мастер', 'role': 'master'});
  }
  if (request.url.path.endsWith('/login')) {
    return jsonResponse({
      'token': 'tok-$id',
      'user': {'id': id, 'name': 'Мастер', 'role': 'master'},
    });
  }
  return snapshotResponse(request, id: id);
});

class _ThrowingStorage extends FlutterSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw StateError('secure storage unavailable');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('session saved at login restores on a fresh controller', () async {
    final first = AppController(
      localStore: MemoryLocalStore(),
      apiFactory: (_) =>
          NaryadApi('http://restore.test', client: mockApi(id: 7)),
    );
    addTearDown(first.dispose);
    await first.login('http://restore.test', 'master', '1234');
    expect(first.user!.id, 7);

    final second = AppController(
      localStore: MemoryLocalStore(),
      apiFactory: (_) =>
          NaryadApi('http://restore.test', client: mockApi(id: 7)),
    );
    addTearDown(second.dispose);
    await second.restoreSession();
    expect(second.user!.id, 7);
    expect(second.offline, isFalse);
    expect(second.error, isNull);
  });

  test('restore with no saved session stays silent (fresh install)', () async {
    final controller = AppController(
      localStore: MemoryLocalStore(),
      apiFactory: (_) =>
          NaryadApi('http://restore.test', client: mockApi(id: 7)),
    );
    addTearDown(controller.dispose);
    final restoring = controller.restoreSession();
    await restoring;
    expect(controller.restoring, isFalse);
    expect(controller.user, isNull);
    expect(controller.error, isNull);
  });

  test('restore restores the user and clears restoring on success', () async {
    final first = AppController(
      localStore: MemoryLocalStore(),
      apiFactory: (_) =>
          NaryadApi('http://restore.test', client: mockApi(id: 7)),
    );
    addTearDown(first.dispose);
    await first.login('http://restore.test', 'master', '1234');

    final second = AppController(
      localStore: MemoryLocalStore(),
      apiFactory: (_) =>
          NaryadApi('http://restore.test', client: mockApi(id: 7)),
    );
    addTearDown(second.dispose);
    bool sawRestoring = false;
    second.addListener(() {
      if (second.restoring && second.user == null) sawRestoring = true;
    });
    final restoring = second.restoreSession();
    await restoring;
    expect(second.restoring, isFalse);
    expect(second.user!.id, 7);
    expect(sawRestoring, isTrue);
  });

  test('restore warns when secure storage lost a prior login', () async {
    SharedPreferences.setMockInitialValues({
      'naryad.native.ever_logged_in.v1': true,
    });
    final controller = AppController(
      localStore: MemoryLocalStore(),
      apiFactory: (_) =>
          NaryadApi('http://restore.test', client: mockApi(id: 7)),
    );
    addTearDown(controller.dispose);
    final restoring = controller.restoreSession();
    await restoring;
    expect(controller.restoring, isFalse);
    expect(controller.user, isNull);
    expect(
      controller.error,
      'Сохранённая сессия недоступна на этом устройстве. Войдите снова.',
    );
  });

  test('logout clears the ever-logged-in marker', () async {
    SharedPreferences.setMockInitialValues({
      'naryad.native.ever_logged_in.v1': true,
    });
    final controller = AppController(
      localStore: MemoryLocalStore(),
      apiFactory: (_) =>
          NaryadApi('http://restore.test', client: mockApi(id: 7)),
    )..user = const User(id: 7, name: 'Мастер', role: 'master');
    addTearDown(controller.dispose);
    await controller.logout();
    await controller.restoreSession();
    expect(controller.user, isNull);
    expect(controller.error, isNull);
  });

  test('login stays successful when secure storage write fails', () async {
    final controller = AppController(
      localStore: MemoryLocalStore(),
      storage: _ThrowingStorage(),
      apiFactory: (_) =>
          NaryadApi('http://restore.test', client: mockApi(id: 7)),
    );
    addTearDown(controller.dispose);
    await controller.login('http://restore.test', 'master', '1234');
    expect(controller.user!.id, 7);
    expect(
      controller.error,
      'Вход выполнен, но сессия не сохранена на устройстве.',
    );
  });

  test(
    'restart without connection keeps the user from the profile snapshot',
    () async {
      final store = MemoryLocalStore();
      final online = AppController(
        localStore: store,
        apiFactory: (_) =>
            NaryadApi('http://restore.test', client: mockApi(id: 7)),
      );
      addTearDown(online.dispose);
      await online.login('http://restore.test', 'master', '1234');

      int meChecks = 0;
      final offline = AppController(
        localStore: store,
        apiFactory: (_) => NaryadApi(
          'http://restore.test',
          client: MockClient((request) async {
            if (request.url.path.endsWith('/auth/me')) meChecks++;
            throw http.ClientException('no network');
          }),
        ),
      );
      addTearDown(offline.dispose);
      await offline.restoreSession();
      expect(offline.user!.id, 7);
      expect(offline.offline, isTrue);
      expect(offline.error, isNull);
      expect(meChecks, 1);
    },
  );

  test(
    'restart offline without a saved snapshot cannot restore the user',
    () async {
      final first = AppController(
        localStore: MemoryLocalStore(),
        apiFactory: (_) =>
            NaryadApi('http://restore.test', client: mockApi(id: 7)),
      );
      addTearDown(first.dispose);
      await first.login('http://restore.test', 'master', '1234');

      final offline = AppController(
        localStore: MemoryLocalStore(),
        apiFactory: (_) => NaryadApi(
          'http://restore.test',
          client: MockClient((request) async {
            throw http.ClientException('no network');
          }),
        ),
      );
      addTearDown(offline.dispose);
      await offline.restoreSession();
      expect(offline.user, isNull);
      expect(offline.restoring, isFalse);
      expect(offline.error, contains('Нет связи'));
    },
  );

  test(
    'offline restore cannot read another server or account snapshot',
    () async {
      final store = MemoryLocalStore();
      for (final entry in [
        ('http://server-a.test/api', 7),
        ('http://server-b.test/api', 8),
      ]) {
        await store.putSnapshot(
          localScopeKey(entry.$1, entry.$2, SnapshotKeys.profile),
          {'id': entry.$2, 'name': 'Foreign cached profile', 'role': 'master'},
          updatedAt: DateTime.now(),
        );
      }
      FlutterSecureStorage.setMockInitialValues({
        'naryad.native.session.v1': jsonEncode({
          'base_url': 'http://server-b.test/api',
          'owner_id': 7,
          'token': 'test-session',
        }),
      });
      final controller = AppController(
        localStore: store,
        apiFactory: (url) => NaryadApi(
          url,
          client: MockClient((_) async {
            throw http.ClientException('no network');
          }),
        ),
      );
      addTearDown(controller.dispose);
      await controller.restoreSession();
      expect(controller.user, isNull);
      expect(controller.orders, isEmpty);
      expect(controller.error, contains('Нет связи'));
    },
  );

  test(
    'legacy session and unscoped profile require online ownership check',
    () async {
      final store = MemoryLocalStore();
      await store.putSnapshot(SnapshotKeys.profile, {
        'id': 7,
        'name': 'Legacy cached profile',
        'role': 'master',
      }, updatedAt: DateTime.now());
      FlutterSecureStorage.setMockInitialValues({
        'naryad.native.session.v1': jsonEncode({
          'base_url': 'http://restore.test/api',
          'token': 'legacy-session',
        }),
      });
      final controller = AppController(
        localStore: store,
        apiFactory: (url) => NaryadApi(
          url,
          client: MockClient((_) async {
            throw http.ClientException('no network');
          }),
        ),
      );
      addTearDown(controller.dispose);
      await controller.restoreSession();
      expect(controller.user, isNull);
      expect(controller.error, contains('Старый офлайн-кэш'));
      expect(
        await store.getSnapshot(SnapshotKeys.profile),
        isNotNull,
        reason: 'Unscoped legacy data is preserved but never guessed or read.',
      );
    },
  );

  test(
    'protected photo cache is separated by server and numeric user ID',
    () async {
      final store = MemoryLocalStore();
      var reads = 0;
      Future<void> view(String url, int ownerId, int expectedByte) async {
        final controller = AppController(
          localStore: store,
          api: NaryadApi(
            url,
            client: MockClient((_) async {
              reads++;
              return http.Response.bytes([expectedByte], 200);
            }),
          ),
        )..user = User(id: ownerId, name: 'Worker', role: 'worker');
        addTearDown(controller.dispose);
        expect(await controller.photoBytes(1), [expectedByte]);
        expect(await controller.photoBytes(1), [expectedByte]);
      }

      await view('http://server-a.test', 7, 1);
      await view('http://server-b.test', 7, 2);
      await view('http://server-a.test', 8, 3);
      expect(reads, 3);
    },
  );
}
