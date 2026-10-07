import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/data/push_service.dart';
import 'package:naryad_ai/main.dart';
import 'package:naryad_ai/screens/login_screen.dart';
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:naryad_ai/screens/workspace_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// Fake push service: no Firebase, records what AppController asks for.
class FakePushService implements PushService {
  FakePushService({this.token = 'fcm-token-42'});

  final String? token;
  final StreamController<int> taps = StreamController<int>.broadcast();
  int initCalls = 0;
  int unregisterCalls = 0;
  NaryadApi? registeredWith;
  bool failRegistration = false;
  bool failUnregister = false;

  @override
  Future<void> init() async {
    initCalls++;
    if (failRegistration) {
      throw StateError('push init unavailable');
    }
  }

  @override
  Future<String?> requestToken() async => token;

  @override
  Future<void> registerWith(NaryadApi api) async {
    if (failRegistration) {
      throw StateError('push init unavailable');
    }
    registeredWith = api;
    final current = await requestToken();
    if (current != null) await api.registerDevice(current);
  }

  @override
  Future<void> unregister() async {
    unregisterCalls++;
    if (failUnregister) throw StateError('push unavailable');
    final api = registeredWith;
    final current = token;
    if (api == null || current == null) return;
    await api.unregisterDevice(current);
  }

  @override
  Stream<int> get orderTaps => taps.stream;
}

/// Exercises the production session guards without calling Firebase.
class ControlledTokenPushService extends FirebasePushService {
  ControlledTokenPushService(this.tokenRequest);

  final Future<String?> Function() tokenRequest;

  @override
  Future<String?> requestToken() => tokenRequest();
}

/// Server double that records every write for assertions.
MockClient serverMock(List<http.Request> posted, {int id = 7}) =>
    MockClient((request) async {
      if (request.method == 'POST') {
        posted.add(request);
      }
      return switch (request.url.path) {
        '/api/auth/login' => jsonResponse({
          'token': 'tok-$id',
          'user': {'id': id, 'name': 'Мастер', 'role': 'master'},
        }),
        '/api/auth/me' => jsonResponse({
          'id': id,
          'name': 'Мастер',
          'role': 'master',
        }),
        '/api/devices' => jsonResponse({
          'id': 1,
          'token': 'fcm-token-42',
          'platform': 'android',
        }, 201),
        '/api/devices/unregister' => jsonResponse({'ok': true}),
        _ => snapshotResponse(request, id: id),
      };
    });

List<http.Request> pathPosts(List<http.Request> posted, String path) =>
    posted.where((request) => request.url.path == path).toList();

class _StubController extends AppController {
  @override
  Future<void> restoreSession() async {}

  @override
  Future<void> login(String baseUrl, String login, String pin) async {
    user = const User(id: 7, name: 'Мастер', role: 'master');
    notifyListeners();
  }

  @override
  Future<void> refresh({bool silent = false}) async {}

  @override
  Future<WorkOrder> loadOrder(int id) async {
    for (final order in orders) {
      if (order.id == id) return order;
    }
    throw const ApiException('Нет связи с сервером', 0);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('login registers the FCM token with the device endpoint', () async {
    final posted = <http.Request>[];
    final store = MemoryLocalStore();
    await store.open();
    final push = FakePushService();
    final controller = AppController(
      apiFactory: (url) => NaryadApi(url, client: serverMock(posted)),
      localStore: store,
      pushService: push,
    );
    addTearDown(controller.dispose);

    await controller.login('http://push.test', 'master', '1234');

    expect(controller.user!.id, 7);
    expect(controller.error, isNull);
    expect(push.registeredWith, isNotNull);
    final devices = pathPosts(posted, '/api/devices');
    expect(devices, hasLength(1));
    final body = jsonDecode(devices.single.body) as Json;
    expect(body['token'], 'fcm-token-42');
    expect(body['platform'], 'android');
  });

  test(
    'logout unregisters the device record before the session is dropped',
    () async {
      final posted = <http.Request>[];
      final store = MemoryLocalStore();
      await store.open();
      final push = FakePushService();
      final controller = AppController(
        apiFactory: (url) => NaryadApi(url, client: serverMock(posted)),
        localStore: store,
        pushService: push,
      );
      addTearDown(controller.dispose);

      await controller.login('http://push.test', 'master', '1234');
      await controller.logout();

      expect(controller.user, isNull);
      expect(controller.error, isNull);
      expect(push.unregisterCalls, greaterThanOrEqualTo(1));
      final unregister = pathPosts(posted, '/api/devices/unregister');
      expect(unregister, hasLength(1));
      final body = jsonDecode(unregister.single.body) as Json;
      expect(body['token'], 'fcm-token-42');
    },
  );

  test(
    'logout clears local state while waiting for unregister before revocation',
    () async {
      final posted = <http.Request>[];
      final unregisterResponse = Completer<http.Response>();
      final store = MemoryLocalStore();
      final push = FakePushService();
      final controller = AppController(
        apiFactory: (url) => NaryadApi(
          url,
          client: MockClient((request) async {
            if (request.method == 'POST') posted.add(request);
            if (request.url.path == '/api/auth/login') {
              return jsonResponse({
                'token': 'tok-7',
                'user': {'id': 7, 'name': 'Мастер', 'role': 'master'},
              });
            }
            if (request.url.path == '/api/devices/unregister') {
              return unregisterResponse.future;
            }
            return snapshotResponse(request);
          }),
        ),
        localStore: store,
        pushService: push,
      );
      addTearDown(controller.dispose);
      await controller.login('http://push.test', 'master', '1234');
      final authenticatedApi = controller.api;
      controller.openOrderFromPush(7);

      final logout = controller.logout();
      expect(controller.user, isNull);
      expect(controller.api.token, isNull);
      expect(controller.orders, isEmpty);
      expect(controller.pendingPushOrderId, isNull);
      await pumpEventQueue();

      final unregister = pathPosts(posted, '/api/devices/unregister').single;
      expect(unregister.headers['authorization'], 'Bearer tok-7');
      expect(authenticatedApi.token, 'tok-7');
      expect(pathPosts(posted, '/api/auth/logout'), isEmpty);
      expect(
        await const FlutterSecureStorage().read(
          key: 'naryad.native.session.v1',
        ),
        isNull,
      );

      unregisterResponse.complete(jsonResponse({'ok': true}));
      await logout;
      final revocation = pathPosts(posted, '/api/auth/logout').single;
      expect(revocation.headers['authorization'], 'Bearer tok-7');
      expect(posted.indexOf(unregister), lessThan(posted.indexOf(revocation)));
      expect(controller.error, isNull);
    },
  );

  testWidgets(
    'unregister timeout still allows server logout after ten seconds',
    (tester) async {
      final posted = <http.Request>[];
      final unregisterResponse = Completer<http.Response>();
      final authenticatedApi = NaryadApi(
        'http://push.test',
        client: MockClient((request) async {
          posted.add(request);
          if (request.url.path == '/api/devices/unregister') {
            return unregisterResponse.future;
          }
          return jsonResponse({'ok': true});
        }),
      )..token = 'tok-7';
      final push = FakePushService()..registeredWith = authenticatedApi;
      final controller = AppController(
        api: authenticatedApi,
        localStore: MemoryLocalStore(),
        pushService: push,
      )..user = const User(id: 7, name: 'Мастер', role: 'master');
      addTearDown(controller.dispose);

      final logout = controller.logout();
      await tester.pump();
      expect(controller.user, isNull);
      expect(pathPosts(posted, '/api/auth/logout'), isEmpty);
      await tester.pump(const Duration(seconds: 9));
      expect(pathPosts(posted, '/api/auth/logout'), isEmpty);
      await tester.pump(const Duration(seconds: 1));
      await logout;

      expect(pathPosts(posted, '/api/auth/logout'), hasLength(1));
      expect(controller.error, isNull);
      unregisterResponse.complete(jsonResponse({'ok': true}));
      await tester.pump();
    },
  );

  test('a late token request cannot register a logged-out session', () async {
    final posted = <http.Request>[];
    final token = Completer<String?>();
    final push = ControlledTokenPushService(() => token.future);
    final api = NaryadApi('http://push.test', client: serverMock(posted))
      ..token = 'old-session';
    addTearDown(api.close);

    final registration = push.registerWith(api);
    await push.unregister();
    token.complete('late-fcm-token');
    await registration;

    expect(pathPosts(posted, '/api/devices'), isEmpty);
  });

  test(
    'a late token request cannot replace the next account registration',
    () async {
      final posted = <http.Request>[];
      final oldToken = Completer<String?>();
      var requestCount = 0;
      final push = ControlledTokenPushService(
        () => requestCount++ == 0
            ? oldToken.future
            : Future.value('current-fcm-token'),
      );
      final previous = NaryadApi('http://push.test', client: serverMock(posted))
        ..token = 'old-session';
      final next = NaryadApi('http://push.test', client: serverMock(posted))
        ..token = 'new-session';
      addTearDown(previous.close);
      addTearDown(next.close);

      final oldRegistration = push.registerWith(previous);
      await push.registerWith(next);
      oldToken.complete('late-fcm-token');
      await oldRegistration;

      final registration = pathPosts(posted, '/api/devices').single;
      expect(registration.headers['authorization'], 'Bearer new-session');
      expect(
        (jsonDecode(registration.body) as Json)['token'],
        'current-fcm-token',
      );
      await push.unregister();
      final unregister = pathPosts(posted, '/api/devices/unregister').single;
      expect(unregister.headers['authorization'], 'Bearer new-session');
      expect(
        (jsonDecode(unregister.body) as Json)['token'],
        'current-fcm-token',
      );
    },
  );

  test('restored session re-registers the device', () async {
    final posted = <http.Request>[];
    final store = MemoryLocalStore();
    await store.open();
    final first = AppController(
      apiFactory: (url) => NaryadApi(url, client: serverMock(posted)),
      localStore: store,
      pushService: FakePushService(),
    );
    addTearDown(first.dispose);
    await first.login('http://push.test', 'master', '1234');
    expect(pathPosts(posted, '/api/devices'), hasLength(1));

    final second = AppController(
      apiFactory: (url) => NaryadApi(url, client: serverMock(posted)),
      localStore: store,
      pushService: FakePushService(),
    );
    addTearDown(second.dispose);
    await second.restoreSession();

    expect(second.user!.id, 7);
    expect(second.error, isNull);
    expect(pathPosts(posted, '/api/devices'), hasLength(2));
  });

  test('push failures never break login, restore or logout', () async {
    final posted = <http.Request>[];
    final store = MemoryLocalStore();
    await store.open();
    final push = FakePushService()
      ..failRegistration = true
      ..failUnregister = true;
    final controller = AppController(
      apiFactory: (url) => NaryadApi(url, client: serverMock(posted)),
      localStore: store,
      pushService: push,
    );
    addTearDown(controller.dispose);

    await controller.login('http://push.test', 'master', '1234');
    expect(controller.user!.id, 7);
    expect(controller.error, isNull);
    expect(pathPosts(posted, '/api/devices'), isEmpty);

    await controller.logout();
    expect(controller.user, isNull);
    expect(controller.error, isNull);
    expect(pathPosts(posted, '/api/devices/unregister'), isEmpty);
  });

  test(
    'default controller without injection works with the no-op service',
    () async {
      final posted = <http.Request>[];
      final store = MemoryLocalStore();
      await store.open();
      final controller = AppController(
        apiFactory: (url) => NaryadApi(url, client: serverMock(posted)),
        localStore: store,
      );
      addTearDown(controller.dispose);

      await controller.login('http://push.test', 'master', '1234');

      expect(controller.user!.id, 7);
      expect(controller.error, isNull);
      expect(pathPosts(posted, '/api/devices'), isEmpty);
    },
  );

  test('no-op push service performs no platform work', () async {
    const push = NoopPushService();
    await push.init();
    expect(await push.requestToken(), isNull);
    await push.registerWith(NaryadApi('http://push.test'));
    await push.unregister();
    expect(await push.orderTaps.toList(), isEmpty);
  });

  test(
    'a tapped order id waits for the session and is consumed once',
    () async {
      final posted = <http.Request>[];
      final store = MemoryLocalStore();
      await store.open();
      final push = FakePushService();
      final controller = AppController(
        apiFactory: (url) => NaryadApi(url, client: serverMock(posted)),
        localStore: store,
        pushService: push,
      );
      addTearDown(controller.dispose);
      final subscription = push.taps.stream.listen(
        controller.openOrderFromPush,
      );
      addTearDown(subscription.cancel);

      push.taps.add(12);
      await pumpEventQueue();
      expect(controller.pendingPushOrderId, 12);

      await controller.login('http://push.test', 'master', '1234');
      expect(controller.user!.id, 7);
      expect(controller.pendingPushOrderId, 12);
      expect(controller.consumePendingPushOrder(), 12);
      expect(controller.consumePendingPushOrder(), isNull);

      controller.openOrderFromPush(31);
      expect(controller.pendingPushOrderId, 31);
      await controller.logout();
      expect(controller.pendingPushOrderId, isNull);
    },
  );

  testWidgets('a push tap before login opens the order after the session', (
    tester,
  ) async {
    final c = _StubController()..orders = [WorkOrder.fromJson(orderJson(12))];
    addTearDown(c.dispose);
    await tester.pumpWidget(NaryadApp(controller: c));
    expect(find.byType(LoginScreen), findsOneWidget);

    c.openOrderFromPush(12);
    await tester.pump();
    expect(c.pendingPushOrderId, 12);
    expect(find.byType(OrderDetailScreen), findsNothing);

    c.user = const User(id: 7, name: 'Мастер', role: 'master');
    c.notifyListeners();
    await tester.pumpAndSettle();

    // The pushed order route sits on top; the workspace replaced the login.
    expect(find.byType(OrderDetailScreen), findsOneWidget);
    expect(find.byType(WorkspaceScreen, skipOffstage: false), findsOneWidget);
    expect(find.byType(LoginScreen, skipOffstage: false), findsNothing);
    expect(find.text('Н-12'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a push tap with an active session opens the order immediately', (
    tester,
  ) async {
    final c = _StubController()
      ..user = const User(id: 7, name: 'Мастер', role: 'master')
      ..orders = [WorkOrder.fromJson(orderJson(42))];
    addTearDown(c.dispose);
    await tester.pumpWidget(NaryadApp(controller: c));
    await tester.pump();
    expect(find.byType(WorkspaceScreen), findsOneWidget);

    c.openOrderFromPush(42);
    await tester.pumpAndSettle();

    expect(find.byType(OrderDetailScreen), findsOneWidget);
    expect(find.text('Н-42'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
