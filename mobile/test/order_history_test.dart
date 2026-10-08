import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/widgets/order_history.dart';
import 'package:shared_preferences/shared_preferences.dart';

Json summary() => {
  'id': 9,
  'number': 'HISTORY-9',
  'title': 'Проверить насос',
  'description': 'Осмотреть насос',
  'status': 'ai_review',
  'priority': 'normal',
  'work_type': 'planned',
  'assignee_id': 7,
  'assignee_name': 'Исполнитель',
  'deadline': '2026-10-08T18:00:00Z',
  'normal_hours': 2,
};
Json assignment({bool legacy = false}) => {
  'id': 10,
  'number': 1,
  'source': legacy ? 'legacy_snapshot' : 'live',
  'assignee_name': 'Первый работник',
  'assigned_by_name': legacy ? null : 'Мастер',
  'assigned_at': '2026-10-01T10:00:00Z',
  'ended_at': null,
};
Json attempt(int number, {bool legacy = false}) => {
  'id': number,
  'number': number,
  'source': legacy ? 'legacy_snapshot' : 'live',
  'assignment_id': legacy ? null : 10,
  'submitted_at': legacy ? null : '2026-10-01T11:00:00Z',
  'author_name': legacy ? null : 'Первый работник',
  'completion': {
    'work_done': 'Самостоятельный отчёт $number',
    'fault_code_id': 1,
    if (legacy)
      'materials': [
        {
          'material_id': 1,
          'name': 'Прежний общий расход',
          'quantity': 8,
          'unit': 'шт',
        },
      ],
  },
  'materials': legacy
      ? <Json>[]
      : [
          {
            'id': number,
            'name': 'Дополнительная деталь $number',
            'quantity': number,
            'unit': 'шт',
            'author_name': 'Первый работник',
            'created_at': '2026-10-01T11:00:00Z',
          },
        ],
  'photos': legacy
      ? <Json>[]
      : [
          {
            'id': 90,
            'kind': 'after',
            'url': '/api/photos/90',
            'author_name': 'Первый работник',
            'created_at': '2026-10-01T10:30:00Z',
          },
        ],
  'ai_review': legacy
      ? null
      : {
          'verdict': 'needs_attention',
          'score': 4,
          'explanation': 'Оценка попытки $number',
          'is_stub': true,
        },
  'decisions': legacy
      ? <Json>[]
      : [
          {
            'id': number,
            'action': number == 1 ? 'rework' : 'close',
            'actor_name': 'Мастер',
            'score': number == 1 ? null : 5,
            'comment': 'Решение по попытке $number',
            'created_at': '2026-10-01T12:00:00Z',
          },
        ],
};
Json detail({bool legacy = false}) => {
  ...summary(),
  'assignment_history': [assignment(legacy: legacy)],
  'submission_attempts': [attempt(1, legacy: legacy), if (!legacy) attempt(2)],
};

class PhotoController extends AppController {
  final reads = <int>[];

  @override
  Future<Uint8List> photoBytes(int id) async {
    reads.add(id);
    return Uint8List.fromList(
      image.encodePng(image.Image(width: 1, height: 1)),
    );
  }
}

class DelayedHistoryStore extends MemoryLocalStore {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> putSnapshot(
    String key,
    Object? data, {
    required DateTime updatedAt,
  }) async {
    if (key.endsWith(':orders') && !started.isCompleted) {
      started.complete();
      await release.future;
    }
    await super.putSnapshot(key, data, updatedAt: updatedAt);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('missing detail history defaults empty; JSON round trip preserves snapshots', () {
    expect(WorkOrder.fromJson(summary()).assignmentHistory, isEmpty);
    expect(WorkOrder.fromJson(summary()).submissionAttempts, isEmpty);
    final original = WorkOrder.fromJson(detail());
    final restored = WorkOrder.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Json,
    );
    expect(restored.assignmentHistory, original.assignmentHistory);
    expect(restored.submissionAttempts, original.submissionAttempts);
  });

  test(
    'old replay preserves history while explicit empty history replaces it',
    () {
      final cached = WorkOrder.fromJson(detail());
      final replay = WorkOrder.fromJson({
        ...summary(),
        'status': 'closed',
        'title': 'Свежий заголовок',
      }).withCachedHistory(cached);
      expect(replay.status, 'closed');
      expect(replay.title, 'Свежий заголовок');
      expect(replay.submissionAttempts, cached.submissionAttempts);
      final cleared = WorkOrder.fromJson({
        ...summary(),
        'submission_attempts': <Json>[],
      }).withCachedHistory(replay);
      expect(cleared.submissionAttempts, isEmpty);
      expect(cleared.assignmentHistory, cached.assignmentHistory);
    },
  );

  test('list refresh and an offline restart retain previously loaded detail history', () async {
    final store = MemoryLocalStore();
    final api = NaryadApi(
      'http://history.test',
      client: MockClient((request) async {
        Object payload = <String, dynamic>{};
        if (request.url.path == '/api/orders/9') payload = detail();
        if (request.url.path == '/api/orders') {
          payload = [
            {...summary(), 'status': 'closed', 'title': 'Обновлённый список'},
          ];
        }
        if (request.url.path == '/api/employees' ||
            request.url.path == '/api/notifications') {
          payload = <Json>[];
        }
        return http.Response(
          jsonEncode(payload),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    )..token = 'synthetic-session';
    await store.putSnapshot(
      localScopeKey(api.baseUrl, 7, SnapshotKeys.profile),
      {'id': 7, 'name': 'Мастер', 'role': 'master'},
      updatedAt: DateTime.now(),
    );
    await const FlutterSecureStorage().write(
      key: 'naryad.native.session.v1',
      value: jsonEncode({
        'base_url': api.baseUrl,
        'token': api.token,
        'owner_id': 7,
      }),
    );
    final first = AppController(api: api, localStore: store)
      ..user = const User(id: 7, name: 'Мастер', role: 'master');
    addTearDown(first.dispose);
    await first.loadOrder(9);
    await first.refresh();
    expect(first.orders.single.title, 'Обновлённый список');
    expect(first.orders.single.submissionAttempts, hasLength(2));
    await first.flushSnapshot();
    final offline = AppController(
      localStore: store,
      apiFactory: (url) => NaryadApi(
        url,
        client: MockClient((request) async {
          throw http.ClientException('Synthetic offline');
        }),
      ),
    );
    addTearDown(offline.dispose);
    await offline.restoreSession();
    final restored = await offline.loadOrder(9);
    expect(restored.status, 'closed');
    expect(
      restored.submissionAttempts.first['completion']['work_done'],
      'Самостоятельный отчёт 1',
    );
    expect(restored.submissionAttempts.last['materials'].single['quantity'], 2);
    expect(offline.offline, isTrue);
  });

  test('logout and account switch during detail snapshot write discard the old result', () async {
    final store = DelayedHistoryStore();
    final api = NaryadApi(
      'http://history.test',
      client: MockClient(
        (request) async => http.Response(
          jsonEncode(detail()),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final controller = AppController(api: api, localStore: store)
      ..user = const User(id: 7, name: 'Мастер', role: 'master');
    addTearDown(controller.dispose);
    final loading = controller.loadOrder(9);
    final discarded = expectLater(
      loading,
      throwsA(
        isA<ApiException>().having(
          (failure) => failure.statusCode,
          'session error',
          401,
        ),
      ),
    );
    await store.started.future;
    await controller.logout();
    controller.user = const User(id: 8, name: 'Другой мастер', role: 'master');
    controller.orders = [
      WorkOrder.fromJson({...summary(), 'title': 'Наряд другого аккаунта'}),
    ];
    store.release.complete();
    await discarded;
    expect(controller.user?.id, 8);
    expect(controller.orders.single.title, 'Наряд другого аккаунта');
    expect(controller.orders.single.submissionAttempts, isEmpty);
  });

  testWidgets(
    'collapsed history opens separate immutable attempts and private photos',
    (tester) async {
      final controller = PhotoController()
        ..reference = {
          'fault_codes': [
            {'id': 1, 'code': 'F-01', 'name': 'Утечка'},
          ],
        };
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OrderHistory(
                order: WorkOrder.fromJson(detail()),
                controller: controller,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Самостоятельный отчёт 1'), findsNothing);
      await tester.tap(find.text('Сдачи и назначения'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Сдача №1'));
      await tester.pumpAndSettle();
      for (final text in [
        'Самостоятельный отчёт 1',
        'Дополнительная деталь 1 · 1 шт',
        'Оценка попытки 1',
        'Решение по попытке 1',
        'Возвращено на доработку',
        'Шифр неисправности: F-01 · Утечка',
      ]) {
        expect(find.text(text), findsOneWidget);
      }
      expect(controller.reads, [90]);
      await tester.ensureVisible(find.text('Сдача №2'));
      await tester.tap(find.text('Сдача №2'));
      await tester.pumpAndSettle();
      expect(find.text('Самостоятельный отчёт 2'), findsOneWidget);
      expect(find.text('Дополнительная деталь 2 · 2 шт'), findsOneWidget);
      expect(find.text('Решение по попытке 2'), findsOneWidget);
      expect(find.text('Принято мастером · 5 / 5'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'legacy snapshot does not imply current assignment or per-attempt cumulative expense',
    (tester) async {
      final controller = PhotoController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: OrderHistory(
                order: WorkOrder.fromJson({
                  ...detail(legacy: true),
                  'status': 'closed',
                }),
                controller: controller,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Сдачи и назначения'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Окончание неизвестно'), findsOneWidget);
      expect(find.textContaining('Текущее назначение'), findsNothing);
      await tester.tap(find.text('Сдача №1'));
      await tester.pumpAndSettle();
      expect(find.text('Время не зафиксировано'), findsOneWidget);
      expect(find.text('Связь с назначением не установлена'), findsOneWidget);
      expect(find.text('Общий расход из прежнего отчёта'), findsOneWidget);
      expect(
        find.text('Связь расхода с этой сдачей неизвестна.'),
        findsOneWidget,
      );
      expect(controller.reads, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
