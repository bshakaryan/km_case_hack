import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/main.dart';
import 'package:naryad_ai/screens/create_order_screen.dart';
import 'package:naryad_ai/screens/login_screen.dart';
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:naryad_ai/screens/reference_catalog_screen.dart';
import 'package:naryad_ai/screens/workspace_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = User(id: 7, name: 'Мастер', role: 'master');

Json _orderJson(int id) => {
  'id': id,
  'version': 4,
  'number': 'АВ-$id',
  'title': 'Аварийный насос $id',
  'description': 'Проверить насос и устранить течь.',
  'priority': 'emergency',
  'status': 'issued',
  'work_type': 'unplanned',
  'deadline': '2026-10-08T10:00:00Z',
  'normal_hours': 2,
  'equipment_name': 'Насос Н-1',
  'area_name': 'Цех',
  'assignee_id': 8,
  'assignee_name': 'Ответственный',
  'is_overdue': false,
};

Json _notice({int id = 19, int orderId = 12}) => {
  'id': id,
  'order_id': orderId,
  'kind': 'assigned',
  'read': false,
  'title': 'Аварийное назначение',
  'message': 'Нужен рабочий ответ по наряду.',
  'created_at': '2026-10-08T06:00:00Z',
};

http.Response _jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class _NavigationController extends AppController {
  _NavigationController({bool active = true, String role = 'master'})
    : this._(MemoryLocalStore(), active: active, role: role);

  _NavigationController._(
    this.store, {
    required bool active,
    required String role,
  }) : super(localStore: store) {
    api.close();
    api = _newApi('http://navigation.test')..token = 'session-token';
    if (active) user = User(id: 7, name: 'Мастер', role: role);
    orders = [
      for (final id in [12, 13]) WorkOrder.fromJson(_orderJson(id)),
    ];
    notifications = [_notice()];
    reference = {
      'areas': [
        {'id': 1, 'name': 'Цех'},
      ],
      'equipment': [
        {
          'id': 9,
          'name': 'Насос Н-1',
          'inventory_number': 'INV-9',
          'area_id': 1,
          'type': 'Насос',
          'criticality': 'legacy-critical',
        },
      ],
      'materials': [
        {'id': 6, 'name': 'Уплотнение', 'unit': 'шт'},
      ],
      'brigades': <Json>[],
      'work_types': <Json>[],
      'norms': <Json>[],
      'material_norms': <Json>[],
    };
  }

  final List<NaryadApi> _retired = [];
  final MemoryLocalStore store;
  final List<http.Request> writes = [];
  final List<int> detailReads = [];
  final List<int> readMarks = [];
  Future<void>? readResult;
  Completer<http.Response>? pendingWrite;
  final writeStarted = Completer<void>();
  ApiException? detailFailure;

  NaryadApi _newApi(String url) => NaryadApi(
    url,
    client: MockClient((request) async {
      if (request.method != 'GET') writes.add(request);
      if (request.url.path == '/api/notifications/19/read' &&
          pendingWrite != null) {
        if (!writeStarted.isCompleted) writeStarted.complete();
        return pendingWrite!.future;
      }
      return _jsonResponse({'ok': true});
    }),
  );

  @override
  Future<void> restoreSession() async {}

  @override
  Future<void> refresh({bool silent = false}) async {}

  @override
  Future<WorkOrder> loadOrder(int id) async {
    detailReads.add(id);
    if (detailFailure != null) throw detailFailure!;
    return orders.firstWhere((order) => order.id == id);
  }

  @override
  Future<void> markRead(int id) async {
    readMarks.add(id);
    await (readResult ?? Future<void>.value());
  }

  Future<void> beginDurableRead(int id) => super.markRead(id);

  void changeBoundary(String kind) {
    switch (kind) {
      case 'owner':
        user = const User(id: 9, name: 'Другой мастер', role: 'master');
      case 'role':
        user = const User(id: 7, name: 'Мастер', role: 'manager');
      case 'token':
        api.token = 'different-token';
      case 'same-token':
        api.token = api.token;
      case 'token-ABA':
        final previous = api.token;
        api.token = 'temporary-token';
        api.token = previous;
      case 'api':
        _retired.add(api);
        api = _newApi('http://another-api.test')..token = 'session-token';
      case 'closed':
        api.close();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final previous in _retired) {
      previous.close();
    }
    super.dispose();
  }
}

/// Retains the production durable markRead path; only its follow-up refresh is
/// counted so a late reply cannot hide an unauthorized current-cache refresh.
class _ReadController extends AppController {
  _ReadController(NaryadApi source, MemoryLocalStore store)
    : super(api: source, localStore: store) {
    user = _owner;
    notifications = [_notice()];
  }

  int refreshes = 0;

  @override
  Future<void> refresh({bool silent = false}) async {
    refreshes++;
  }
}

Future<void> _showApp(
  WidgetTester tester,
  _NavigationController controller,
) async {
  await tester.pumpWidget(NaryadApp(controller: controller));
  await tester.pumpAndSettle();
}

Finder _field(String label) => find.widgetWithText(TextFormField, label);

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder.hitTestable());
  await tester.pumpAndSettle();
}

Future<void> _openNotice(WidgetTester tester) async {
  await _tap(tester, find.text('События'));
  await _tap(tester, find.text('Аварийное назначение'));
}

void _replaceTokenEpoch(NaryadApi api, String boundary) {
  final token = api.token;
  if (boundary == 'token-ABA') api.token = 'temporary-session';
  api.token = token;
}

Json _failedAiOrder() => {
  ..._orderJson(12),
  'status': 'completed',
  'ai_review_job': {
    'id': 8,
    'attempt_id': 2,
    'status': 'failed',
    'retry_allowed': true,
  },
  'submission_attempts': [
    {'id': 2, 'number': 1, 'ai_review': null, 'assessment_id': null},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  for (final boundary in ['same-token', 'token-ABA']) {
    test(
      'late detail read cannot alter current order or snapshot after $boundary',
      () async {
        final started = Completer<void>();
        final reply = Completer<http.Response>();
        var requests = 0;
        final source = NaryadApi(
          'http://detail.test',
          client: MockClient((request) async {
            requests++;
            expect(request.method, 'GET');
            expect(request.url.path, '/api/orders/12');
            started.complete();
            return reply.future;
          }),
        )..token = 'current-session';
        final store = MemoryLocalStore();
        final current = _orderJson(12);
        final stamp = DateTime.utc(2026, 10, 8, 6);
        final key = localScopeKey(
          source.baseUrl,
          _owner.id,
          SnapshotKeys.orders,
        );
        await store.putSnapshot(key, [current], updatedAt: stamp);
        final controller = AppController(api: source, localStore: store)
          ..user = _owner
          ..orders = [WorkOrder.fromJson(current)];
        addTearDown(controller.dispose);
        final read = controller.loadOrder(12);
        final rejected = expectLater(read, throwsA(isA<ApiException>()));
        await started.future;
        _replaceTokenEpoch(source, boundary);
        controller.error = 'Сообщение нового контекста';
        reply.complete(
          boundary == 'same-token'
              ? _jsonResponse({
                  ...current,
                  'version': 5,
                  'title': 'Старый ответ',
                })
              : _jsonResponse({'detail': 'Истекла старая сессия'}, 401),
        );
        await rejected;

        expect(controller.user, same(_owner));
        expect(controller.api.token, 'current-session');
        expect(controller.orders.single.toJson(), current);
        expect(controller.error, 'Сообщение нового контекста');
        expect(controller.offline, false);
        expect((await store.getSnapshot(key))!.data, [current]);
        expect((await store.getSnapshot(key))!.updatedAt, stamp);
        expect(requests, 1);
      },
    );

    test(
      'late AI retry ACK cannot install a pending job after $boundary',
      () async {
        final started = Completer<void>();
        final reply = Completer<http.Response>();
        final requests = <http.Request>[];
        final source = NaryadApi(
          'http://retry.test',
          client: MockClient((request) async {
            requests.add(request);
            expect(request.method, 'POST');
            expect(
              request.url.path,
              '/api/orders/12/submissions/2/ai-review/retry',
            );
            started.complete();
            return reply.future;
          }),
        )..token = 'current-session';
        final store = MemoryLocalStore();
        final current = _failedAiOrder();
        final stamp = DateTime.utc(2026, 10, 8, 6);
        final key = localScopeKey(
          source.baseUrl,
          _owner.id,
          SnapshotKeys.orders,
        );
        await store.putSnapshot(key, [current], updatedAt: stamp);
        final controller = AppController(api: source, localStore: store)
          ..user = _owner
          ..orders = [WorkOrder.fromJson(current)];
        addTearDown(controller.dispose);
        final retry = controller.retryAiReview(12, 2);
        final rejected = expectLater(
          retry,
          throwsA(
            isA<ApiException>().having(
              (failure) => failure.requestMayHaveSucceeded,
              'uncertain old retry ACK',
              true,
            ),
          ),
        );
        await started.future;
        _replaceTokenEpoch(source, boundary);
        controller.error = 'Сообщение нового контекста';
        reply.complete(
          _jsonResponse({
            'attempt_id': 2,
            'order_version': 5,
            'ai_review': null,
            'job': {'id': 8, 'attempt_id': 2, 'status': 'pending'},
          }),
        );
        await rejected;

        expect(controller.user, same(_owner));
        expect(controller.orders.single.toJson(), current);
        expect(controller.orders.single.aiReviewJob?['status'], 'failed');
        expect(controller.orders.single.version, 4);
        expect(controller.error, 'Сообщение нового контекста');
        expect((await store.getSnapshot(key))!.data, [current]);
        expect((await store.getSnapshot(key))!.updatedAt, stamp);
        expect(await store.outbox(), isEmpty);
        expect(requests, hasLength(1));
        expect(requests.single.headers['x-expected-order-version'], '4');
      },
    );
  }

  test(
    'late polling 401 after token ABA cannot expire or replace current data',
    () async {
      final started = Completer<void>();
      final reply = Completer<http.Response>();
      final source = NaryadApi(
        'http://poll.test',
        client: MockClient((request) async {
          if (request.url.path == '/api/orders') {
            started.complete();
            return reply.future;
          }
          return switch (request.url.path) {
            '/api/employees' || '/api/notifications' => _jsonResponse(<Json>[]),
            _ => _jsonResponse(<String, dynamic>{}),
          };
        }),
      )..token = 'current-session';
      final controller =
          AppController(api: source, localStore: MemoryLocalStore())
            ..user = _owner
            ..orders = [WorkOrder.fromJson(_orderJson(12))]
            ..dashboard = {'issued': 7}
            ..notifications = [_notice()];
      addTearDown(controller.dispose);
      final refresh = controller.refresh(silent: true);
      await started.future;
      _replaceTokenEpoch(source, 'token-ABA');
      controller.error = 'Сообщение нового контекста';
      reply.complete(_jsonResponse({'detail': 'Истекла старая сессия'}, 401));
      await refresh;

      expect(controller.user, same(_owner));
      expect(controller.api.token, 'current-session');
      expect(controller.orders.single.toJson(), _orderJson(12));
      expect(controller.dashboard, {'issued': 7});
      expect(controller.notifications, [_notice()]);
      expect(controller.error, 'Сообщение нового контекста');
      expect(controller.lastUpdated, isNull);
      expect(controller.offline, false);
    },
  );

  for (final boundary in ['same-token', 'token-ABA', 'api']) {
    test(
      'late durable read ACK retains its original command after $boundary',
      () async {
        final reply = Completer<http.Response>();
        final started = Completer<void>();
        final writes = <http.Request>[];
        final source = NaryadApi(
          'http://read.test',
          client: MockClient((request) async {
            writes.add(request);
            expect(request.url.path, '/api/notifications/19/read');
            expect(request.method, 'POST');
            started.complete();
            return reply.future;
          }),
        )..token = 'original-session';
        addTearDown(source.close);
        final store = MemoryLocalStore();
        final controller = _ReadController(source, store);
        addTearDown(controller.dispose);
        final response = controller.markRead(19);
        final rejected = expectLater(
          response,
          throwsA(
            isA<ApiException>().having(
              (error) => error.requestMayHaveSucceeded,
              'uncertain old ACK',
              isTrue,
            ),
          ),
        );
        await started.future;
        final original = (await store.outbox()).single;
        expect(original.state, OutboxState.running);

        if (boundary == 'api') {
          controller.api = NaryadApi('http://new-read.test')
            ..token = 'new-session';
        } else if (boundary == 'same-token') {
          source.token = source.token;
        } else {
          source.token = 'temporary-session';
          source.token = 'original-session';
        }
        controller
          ..notifications = [_notice(id: 99, orderId: 13)]
          ..error = 'Состояние текущего контекста';
        reply.complete(_jsonResponse({'ok': true}));
        await rejected;

        final retained = (await store.outbox()).single;
        expect(retained.commandId, original.commandId);
        expect(retained.payload, original.payload);
        expect(retained.ownerId, original.ownerId);
        expect(retained.serverUrl, original.serverUrl);
        expect(retained.orderId, 19);
        expect(retained.state, OutboxState.pending);
        expect(retained.responseStatus, 0);
        expect(controller.notifications, [_notice(id: 99, orderId: 13)]);
        expect(controller.error, 'Состояние текущего контекста');
        expect(controller.refreshes, 0);
        expect(writes, hasLength(1));
      },
    );
  }

  test(
    'current durable read ACK drains its command without a work transition',
    () async {
      final writes = <http.Request>[];
      final source = NaryadApi(
        'http://read.test',
        client: MockClient((request) async {
          writes.add(request);
          return _jsonResponse({'ok': true});
        }),
      )..token = 'current-session';
      final store = MemoryLocalStore();
      final controller = _ReadController(source, store);
      addTearDown(controller.dispose);

      await controller.markRead(19);

      expect(await store.outbox(), isEmpty);
      expect(controller.refreshes, 1);
      expect(controller.notifications.single['read'], false);
      expect(writes.single.method, 'POST');
      expect(writes.single.url.path, '/api/notifications/19/read');
    },
  );

  test(
    'queued transition ACK after token ABA retains the original replay command',
    () async {
      final started = Completer<void>();
      final reply = Completer<http.Response>();
      final writes = <http.Request>[];
      final source = NaryadApi(
        'http://replay.test',
        client: MockClient((request) async {
          writes.add(request);
          expect(request.method, 'POST');
          expect(request.url.path, '/api/orders/12/transition');
          started.complete();
          return reply.future;
        }),
      )..token = 'current-session';
      final store = MemoryLocalStore();
      final original = OutboxCommand(
        commandId: 'replay-epoch-0001',
        kind: OutboxKind.transition,
        createdAt: 1,
        ownerId: _owner.id,
        serverUrl: source.baseUrl,
        orderId: 12,
        expectedVersion: 4,
        payload: const {'action': 'accept', 'reason': 'Исходный рабочий ответ'},
        attempts: 2,
      );
      await store.enqueue(original);
      final controller = _ReadController(source, store)
        ..orders = [WorkOrder.fromJson(_orderJson(12))];
      addTearDown(controller.dispose);
      final sync = controller.syncOutbox();
      await started.future;
      _replaceTokenEpoch(source, 'token-ABA');
      final current = {
        ..._orderJson(12),
        'version': 9,
        'title': 'Текущая карточка',
      };
      controller
        ..orders = [WorkOrder.fromJson(current)]
        ..error = 'Сообщение нового контекста';
      reply.complete(
        _jsonResponse({..._orderJson(12), 'version': 5, 'status': 'accepted'}),
      );
      await sync;

      final retained = (await store.outbox()).single;
      expect(retained.commandId, original.commandId);
      expect(retained.expectedVersion, original.expectedVersion);
      expect(retained.previousCommandId, original.previousCommandId);
      expect(retained.payload, original.payload);
      expect(retained.attempts, original.attempts);
      expect(retained.state, OutboxState.pending);
      expect(controller.orders.single.toJson(), current);
      expect(controller.user, same(_owner));
      expect(controller.error, 'Сообщение нового контекста');
      expect(controller.refreshes, 0);
      expect(writes, hasLength(1));
      expect(writes.single.headers['x-client-command-id'], original.commandId);
      expect(writes.single.headers['x-expected-order-version'], '4');
      expect(jsonDecode(writes.single.body), original.payload);
    },
  );

  testWidgets(
    'current denial survives offline reopen until a successful detail GET',
    (tester) async {
      var responsePhase = 0;
      final requests = <http.Request>[];
      final source = NaryadApi(
        'http://denial.test',
        client: MockClient((request) async {
          requests.add(request);
          expect(request.method, 'GET');
          expect(request.url.path, '/api/orders/12');
          if (responsePhase == 0) {
            return _jsonResponse({'detail': 'Нет доступа к наряду'}, 403);
          }
          if (responsePhase == 1) {
            throw http.ClientException('offline');
          }
          return _jsonResponse({..._orderJson(12), 'version': 5});
        }),
      )..token = 'current-session';
      final controller = _ReadController(source, MemoryLocalStore())
        ..user = const User(id: 8, name: 'Ответственный', role: 'worker')
        ..orders = [WorkOrder.fromJson(_orderJson(12))];
      addTearDown(controller.dispose);

      Future<void> reopen() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          MaterialApp(
            home: OrderDetailScreen(
              controller: controller,
              orderId: 12,
              notificationEntry: true,
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      await reopen();
      expect(find.textContaining('Нет доступа к наряду'), findsOneWidget);
      expect(find.text('Аварийный насос 12'), findsNothing);
      expect(find.text('Принять задание'), findsNothing);
      expect(controller.orders.single.toJson(), _orderJson(12));

      responsePhase = 1;
      controller.offline = true;
      await expectLater(controller.loadOrder(12), throwsA(isA<ApiException>()));
      await reopen();
      expect(find.text('Аварийный насос 12'), findsNothing);
      expect(find.text('Принять задание'), findsNothing);
      expect(controller.orders.single.toJson(), _orderJson(12));

      responsePhase = 2;
      controller.offline = false;
      final confirmed = await controller.loadOrder(12);
      expect(confirmed.version, 5);
      await reopen();
      expect(find.text('Аварийный насос 12'), findsOneWidget);
      expect(find.text('Принять задание'), findsOneWidget);
      expect(requests.every((request) => request.method == 'GET'), true);
      expect(tester.takeException(), isNull);
    },
  );

  for (final boundary in [
    'owner',
    'role',
    'token',
    'same-token',
    'token-ABA',
    'api',
    'closed',
  ]) {
    testWidgets('consumed push cannot open after $boundary boundary', (
      tester,
    ) async {
      final controller = _NavigationController();
      addTearDown(controller.dispose);
      await _showApp(tester, controller);

      controller.openOrderFromPush(12);
      // The ID was delivered in this session, but no routing frame ran yet.
      controller.changeBoundary(boundary);
      await tester.pumpAndSettle();

      expect(find.byType(OrderDetailScreen, skipOffstage: false), findsNothing);
      expect(controller.detailReads, isEmpty);
      expect(controller.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('logout and same-owner return discard the old routing callback', (
    tester,
  ) async {
    final controller = _NavigationController();
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    controller.openOrderFromPush(12);

    final logout = controller.logout();
    controller
      ..user = _owner
      ..orders = [WorkOrder.fromJson(_orderJson(12))];
    controller.api.token = 'new-login-token';
    controller.notifyListeners();
    await tester.pumpAndSettle();
    await logout;
    await tester.pumpAndSettle();

    expect(find.byType(WorkspaceScreen), findsOneWidget);
    expect(find.byType(OrderDetailScreen, skipOffstage: false), findsNothing);
    expect(controller.detailReads, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cold-start ID opens once after login without automatic action', (
    tester,
  ) async {
    final controller = _NavigationController(active: false);
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    expect(find.byType(LoginScreen), findsOneWidget);

    controller.openOrderFromPush(12);
    await tester.pump();
    expect(find.byType(OrderDetailScreen), findsNothing);
    controller.user = _owner;
    controller.notifyListeners();
    await tester.pumpAndSettle();

    expect(find.byType(OrderDetailScreen), findsOneWidget);
    expect(find.text('АВ-12'), findsOneWidget);
    expect(controller.detailReads, [12]);
    expect(controller.writes, isEmpty);
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(OrderDetailScreen, skipOffstage: false), findsOneWidget);
    expect(controller.detailReads, [12]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeated pending and visible push taps create a single card', (
    tester,
  ) async {
    final controller = _NavigationController();
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    controller.openOrderFromPush(12);
    controller.openOrderFromPush(12);
    controller.openOrderFromPush(12);
    await tester.pumpAndSettle();
    controller.openOrderFromPush(12);
    await tester.pumpAndSettle();

    expect(find.byType(OrderDetailScreen, skipOffstage: false), findsOneWidget);
    expect(controller.detailReads, [12]);
    expect(controller.writes, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceScreen), findsOneWidget);
    controller.openOrderFromPush(12);
    await tester.pumpAndSettle();
    expect(find.byType(OrderDetailScreen, skipOffstage: false), findsOneWidget);
    expect(controller.detailReads, [12, 12]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid push IDs never navigate or send a command', (
    tester,
  ) async {
    final controller = _NavigationController();
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    controller.openOrderFromPush(0);
    controller.openOrderFromPush(-12);
    await tester.pumpAndSettle();
    expect(find.byType(OrderDetailScreen, skipOffstage: false), findsNothing);
    expect(controller.detailReads, isEmpty);
    expect(controller.writes, isEmpty);
  });

  testWidgets('busy write defers push until the current write has drained', (
    tester,
  ) async {
    final controller = _NavigationController()..saving = true;
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    controller.openOrderFromPush(12);
    await tester.pumpAndSettle();
    expect(find.byType(OrderDetailScreen), findsNothing);
    expect(controller.detailReads, isEmpty);

    controller.saving = false;
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(OrderDetailScreen), findsOneWidget);
    expect(controller.detailReads, [12]);
    expect(controller.writes, isEmpty);
  });

  testWidgets('busy deferred push is discarded when its API changes', (
    tester,
  ) async {
    final controller = _NavigationController()..saving = true;
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    controller.openOrderFromPush(12);
    await tester.pump();
    controller.changeBoundary('api');
    controller.saving = false;
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(OrderDetailScreen, skipOffstage: false), findsNothing);
    expect(controller.detailReads, isEmpty);
    expect(controller.writes, isEmpty);
  });

  testWidgets('push waits for the actual shared durable write lease to drain', (
    tester,
  ) async {
    final reply = Completer<http.Response>();
    final controller = _NavigationController()..pendingWrite = reply;
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    final read = controller.beginDurableRead(19);
    await tester.pumpAndSettle();
    await controller.writeStarted.future;
    controller.openOrderFromPush(12);
    await tester.pumpAndSettle();

    expect(find.byType(OrderDetailScreen), findsNothing);
    expect(controller.detailReads, isEmpty);
    expect(controller.writes, hasLength(1));
    reply.complete(_jsonResponse({'ok': true}));
    await read;
    await tester.pumpAndSettle();

    expect(find.byType(OrderDetailScreen), findsOneWidget);
    expect(controller.detailReads, [12]);
    expect(controller.writes, hasLength(1));
    expect(controller.writes.single.url.path, '/api/notifications/19/read');
    expect(tester.takeException(), isNull);
  });

  testWidgets('push overlays and preserves an unsent real order draft', (
    tester,
  ) async {
    final controller = _NavigationController();
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    await _tap(tester, find.text('Выдать наряд'));
    expect(find.byType(CreateOrderScreen), findsOneWidget);
    await tester.ensureVisible(_field('Кратко о задаче *'));
    await tester.enterText(
      _field('Кратко о задаче *'),
      'Неотправленная задача',
    );
    await tester.pump(const Duration(milliseconds: 700));

    controller.openOrderFromPush(12);
    await tester.pumpAndSettle();
    expect(find.byType(OrderDetailScreen), findsOneWidget);
    expect(find.byType(CreateOrderScreen, skipOffstage: false), findsOneWidget);
    expect(controller.writes, isEmpty);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(CreateOrderScreen), findsOneWidget);
    expect(find.text('Неотправленная задача'), findsOneWidget);
    final draft = await controller.store.getFormDraft(
      localScopeKey(controller.api.baseUrl, _owner.id, 'draft:create:new'),
    );
    expect((draft?['data'] as Json?)?['title'], 'Неотправленная задача');
    expect(controller.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'push preserves admin catalog input while an active write delays it',
    (tester) async {
      final controller = _NavigationController(role: 'admin');
      addTearDown(controller.dispose);
      await _showApp(tester, controller);
      await _tap(tester, find.byTooltip('Справочники'));
      await _tap(tester, find.text('Материалы'));
      await _tap(tester, find.text('Добавить'));
      await tester.enterText(_field('Название'), 'Несохранённое уплотнение');
      await tester.enterText(_field('Единица измерения'), 'шт');

      controller.saving = true;
      controller.notifyListeners();
      controller.openOrderFromPush(12);
      // The real editor deliberately animates a spinner for an active write.
      // Inspect the busy frame without asking that animation to stop.
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(OrderDetailScreen), findsNothing);
      expect(find.text('Несохранённое уплотнение'), findsOneWidget);
      controller.saving = false;
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.byType(OrderDetailScreen), findsOneWidget);
      expect(
        find.byType(ReferenceCatalogScreen, skipOffstage: false),
        findsOneWidget,
      );
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Несохранённое уплотнение'), findsOneWidget);
      expect(controller.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending read acknowledgement does not delay authorized viewing',
    (tester) async {
      final read = Completer<void>();
      final controller = _NavigationController()..readResult = read.future;
      addTearDown(controller.dispose);
      await _showApp(tester, controller);
      await _openNotice(tester);

      expect(find.byType(OrderDetailScreen), findsOneWidget);
      expect(find.text('АВ-12'), findsOneWidget);
      expect(controller.detailReads, [12]);
      expect(controller.readMarks, [19]);
      expect(controller.writes, isEmpty);
      read.complete();
      await tester.pumpAndSettle();
      expect(
        find.byType(OrderDetailScreen, skipOffstage: false),
        findsOneWidget,
      );
      expect(controller.detailReads, [12]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('read error is shown separately from the available order card', (
    tester,
  ) async {
    final read = Completer<void>();
    final controller = _NavigationController()..readResult = read.future;
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    await _openNotice(tester);
    read.completeError(const ApiException('Сбой отметки прочтения', 503));
    await tester.pumpAndSettle();

    expect(find.byType(OrderDetailScreen), findsOneWidget);
    expect(find.text('АВ-12'), findsOneWidget);
    expect(find.textContaining('Сбой отметки прочтения'), findsOneWidget);
    expect(controller.detailReads, [12]);
    expect(controller.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final boundary in ['owner', 'same-token', 'api']) {
    testWidgets('late read failure is invisible after $boundary boundary', (
      tester,
    ) async {
      final read = Completer<void>();
      final controller = _NavigationController()..readResult = read.future;
      addTearDown(controller.dispose);
      await _showApp(tester, controller);
      await _openNotice(tester);
      controller.changeBoundary(boundary);
      await tester.pumpAndSettle();
      read.completeError(const ApiException('Ошибка прежней сессии', 503));
      await tester.pumpAndSettle();

      expect(find.textContaining('Ошибка прежней сессии'), findsNothing);
      expect(controller.readMarks, [19]);
      expect(controller.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('rapid repeated notification taps open once and mark once', (
    tester,
  ) async {
    final read = Completer<void>();
    final controller = _NavigationController()..readResult = read.future;
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    await _tap(tester, find.text('События'));
    final tile = tester.widget<ListTile>(
      find.ancestor(
        of: find.text('Аварийное назначение'),
        matching: find.byType(ListTile),
      ),
    );
    tile.onTap!();
    tile.onTap!();
    await tester.pumpAndSettle();
    expect(find.byType(OrderDetailScreen, skipOffstage: false), findsOneWidget);
    expect(controller.detailReads, [12]);
    expect(controller.readMarks, [19]);
    read.complete();
    await tester.pumpAndSettle();
    expect(controller.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fresh forbidden detail replaces cached emergency with denial', (
    tester,
  ) async {
    final controller = _NavigationController()
      ..detailFailure = const ApiException('Нет доступа к наряду', 403);
    addTearDown(controller.dispose);
    await _showApp(tester, controller);
    controller.openOrderFromPush(12);
    await tester.pumpAndSettle();

    expect(find.byType(OrderDetailScreen), findsOneWidget);
    expect(find.textContaining('Нет доступа к наряду'), findsOneWidget);
    expect(find.text('Аварийный насос 12'), findsNothing);
    expect(find.text('Принять задание'), findsNothing);
    expect(controller.orders.any((order) => order.id == 12), isTrue);
    expect(controller.writes, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
