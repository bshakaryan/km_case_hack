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
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:naryad_ai/widgets/ai_job_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/ai_review_wait.dart';

Json job(String status, {int attemptId = 2}) => {
  'id': 8,
  'attempt_id': attemptId,
  'status': status,
  'provider': 'stub',
  'attempts': 3,
  'max_attempts': 3,
  'retry_allowed': status == 'failed',
  'last_error_code': 'PRIVATE_PROVIDER_DIAGNOSTIC',
};
Json review(String explanation) => {
  'verdict': 'passed',
  'score': 4.5,
  'is_stub': true,
  'explanation': explanation,
};
Json detail(String status, {String orderStatus = 'completed'}) => {
  'id': 9,
  'version': 1,
  'number': 'AI-JOB-9',
  'title': 'Проверить насос',
  'description': 'Осмотреть насос и проверить крепление.',
  'status': orderStatus,
  'priority': 'normal',
  'work_type': 'planned',
  'assignee_id': 7,
  'assignee_name': 'Исполнитель',
  'normal_hours': 2,
  'deadline': '2026-10-08T18:00:00Z',
  'created_at': '2026-10-08T10:00:00Z',
  'is_overdue': false,
  'photos': <Json>[],
  'events': <Json>[],
  'completion': {
    'work_done': 'Последний отчёт сохранён',
    'materials': <Json>[],
  },
  'ai_review': status == 'succeeded'
      ? review('NEW_RESULT')
      : review('STALE_AGGREGATE'),
  'ai_review_job': job(status),
  'assignment_history': <Json>[],
  'submission_attempts': [
    {
      'id': 1,
      'number': 1,
      'completion': {'work_done': 'Первый отчёт'},
      'ai_review': review('FIRST_RESULT'),
      'materials': <Json>[],
      'photos': <Json>[],
      'decisions': <Json>[],
    },
    {
      'id': 2,
      'number': 2,
      'completion': {'work_done': 'Последний отчёт сохранён'},
      'ai_review': status == 'succeeded' ? review('NEW_RESULT') : null,
      'ai_job': job(status),
      'materials': <Json>[],
      'photos': <Json>[],
      'decisions': <Json>[],
    },
  ],
};
http.Response jsonResponse(Object payload) => http.Response(
  jsonEncode(
    payload is Json &&
            payload.containsKey('attempt_id') &&
            payload.containsKey('job') &&
            !payload.containsKey('order_version')
        ? {'order_version': 2, ...payload}
        : payload,
  ),
  200,
  headers: {'content-type': 'application/json'},
);
AppController controllerFor(
  MemoryLocalStore store,
  MockClient client, {
  String role = 'master',
  String status = 'failed',
  String orderStatus = 'completed',
}) =>
    AppController(
        localStore: store,
        api: NaryadApi('http://jobs.test', client: client)
          ..token = 'synthetic-bearer',
      )
      ..user = User(id: 7, name: 'Мастер', role: role)
      ..orders = [WorkOrder.fromJson(detail(status, orderStatus: orderStatus))];

Future<void> openDetail(WidgetTester tester, AppController controller) async {
  tester.view.physicalSize = const Size(390, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(home: OrderDetailScreen(controller: controller, orderId: 9)),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('an unusable AI retry version leaves the outcome uncertain and the previous order intact', () async {
    for (final invalidVersion in <Object?>[null, 0, -1, '8', 8.5, 6]) {
      final store = MemoryLocalStore();
      var requests = 0;
      final controller =
          controllerFor(
              store,
              MockClient((request) async {
                requests++;
                expect(request.headers['x-expected-order-version'], '7');
                return jsonResponse({
                  'attempt_id': 2,
                  'ai_review': null,
                  'job': job('pending'),
                  'order_version': invalidVersion,
                });
              }),
            )
            ..orders = [
              WorkOrder.fromJson({...detail('failed'), 'version': 7}),
            ];
      addTearDown(controller.dispose);
      await expectLater(
        controller.retryAiReview(9, 2),
        throwsA(
          isA<ApiException>().having(
            (error) => error.requestMayHaveSucceeded,
            'uncertain result',
            isTrue,
          ),
        ),
      );
      expect(requests, 1);
      expect(controller.orders.single.version, 7);
      expect(controller.orders.single.aiReviewJob?['status'], 'failed');
      expect(await store.outbox(), isEmpty);
    }
  });
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('optional job metadata survives cache merge and only the latest failed attempt can retry', () {
    final failed = WorkOrder.fromJson(detail('failed'));
    expect(failed.canRetryAiReview, isTrue);
    expect(failed.showAiReview, isFalse);
    final summary = Map<String, dynamic>.from(failed.data)
      ..remove('ai_review_job')
      ..remove('submission_attempts');
    final cached = WorkOrder.fromJson(summary).withCachedHistory(failed);
    expect(cached.aiReviewJob, failed.aiReviewJob);
    expect(
      jsonDecode(jsonEncode(cached.toJson()))['ai_review_job']['status'],
      'failed',
    );
    expect(
      WorkOrder.fromJson({
        ...failed.data,
        'ai_review_job': job('failed', attemptId: 1),
      }).canRetryAiReview,
      isFalse,
    );
    expect(
      WorkOrder.fromJson({...failed.data, '_pending_sync': true})
          .canRetryAiReview,
      isFalse,
    );
    expect(
      WorkOrder.fromJson({...failed.data, 'ai_review_job': null}).showAiReview,
      isTrue,
    );
    for (final status in ['pending', 'running', 'failed', 'superseded']) {
      expect(showAttemptAiReview(job(status)), isFalse);
    }
    expect(showAttemptAiReview(null), isTrue);
    expect(showAttemptAiReview(job('succeeded')), isTrue);
  });

  test('retry sends exactly one authenticated online POST and persists its pending metadata', () async {
    final store = MemoryLocalStore();
    final requests = <http.Request>[];
    final controller = controllerFor(
      store,
      MockClient((request) async {
        requests.add(request);
        return jsonResponse({
          'attempt_id': 2,
          'ai_review': null,
          'job': job('pending'),
        });
      }),
    );
    addTearDown(controller.dispose);
    final updated = await controller.retryAiReview(9, 2);
    expect(requests, hasLength(1));
    expect(requests.single.method, 'POST');
    expect(
      requests.single.url.path,
      '/api/orders/9/submissions/2/ai-review/retry',
    );
    expect(requests.single.headers['Authorization'], 'Bearer synthetic-bearer');
    expect(requests.single.headers['X-Client-Command-Id'], isNull);
    expect(jsonDecode(requests.single.body), <String, dynamic>{});
    expect(updated.aiReviewJob?['status'], 'pending');
    expect(updated.data['ai_review'], isNull);
    expect(
      updated.submissionAttempts.first['ai_review']['explanation'],
      'FIRST_RESULT',
    );
    expect(
      updated.submissionAttempts.last['completion']['work_done'],
      'Последний отчёт сохранён',
    );
    expect(await store.outbox(), isEmpty);
    final snapshot = await store.getSnapshot(
      localScopeKey(controller.api.baseUrl, 7, SnapshotKeys.orders),
    );
    expect(
      (snapshot!.data as List).single['ai_review_job']['status'],
      'pending',
    );
  });

  test(
    'unknown retry outcome is not replayed or placed in the offline outbox',
    () async {
      var requests = 0;
      final store = MemoryLocalStore();
      final controller = controllerFor(
        store,
        MockClient((request) async {
          requests++;
          throw http.ClientException('Synthetic disconnect');
        }),
      );
      addTearDown(controller.dispose);
      await expectLater(
        controller.retryAiReview(9, 2),
        throwsA(
          isA<ApiException>().having(
            (failure) => failure.requestMayHaveSucceeded,
            'unknown result',
            isTrue,
          ),
        ),
      );
      expect(requests, 1);
      expect(await store.outbox(), isEmpty);
      expect(controller.orders.single.aiReviewJob?['status'], 'failed');
    },
  );

  test('offline or worker retry is rejected locally without a POST or outbox command', () async {
    var requests = 0;
    final store = MemoryLocalStore();
    final controller = controllerFor(
      store,
      MockClient((request) async {
        requests++;
        return jsonResponse({});
      }),
    )..offline = true;
    addTearDown(controller.dispose);
    await expectLater(
      controller.retryAiReview(9, 2),
      throwsA(isA<ApiException>()),
    );
    controller.offline = false;
    controller.user = const User(id: 7, name: 'Исполнитель', role: 'worker');
    await expectLater(
      controller.retryAiReview(9, 2),
      throwsA(isA<ApiException>()),
    );
    expect(requests, 0);
    expect(await store.outbox(), isEmpty);
  });

  test('a delayed retry result cannot update a different session', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final controller = controllerFor(
      MemoryLocalStore(),
      MockClient((request) async {
        if (request.url.path.endsWith('/retry')) {
          started.complete();
          return response.future;
        }
        return jsonResponse({});
      }),
    );
    addTearDown(controller.dispose);
    final loading = controller.retryAiReview(9, 2);
    final rejected = expectLater(
      loading,
      throwsA(
        isA<ApiException>().having(
          (failure) => failure.statusCode,
          'session changed',
          401,
        ),
      ),
    );
    await started.future;
    await controller.logout();
    controller.user = const User(id: 8, name: 'Другой мастер', role: 'master');
    controller.orders = [
      WorkOrder.fromJson({...detail('failed'), 'title': 'Другой аккаунт'}),
    ];
    response.complete(
      jsonResponse({'attempt_id': 2, 'ai_review': null, 'job': job('pending')}),
    );
    await rejected;
    expect(controller.user?.id, 8);
    expect(controller.orders.single.title, 'Другой аккаунт');
    expect(controller.orders.single.aiReviewJob?['status'], 'failed');
  });

  test('a late retry reply refreshes a newer attempt instead of replacing its result', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final newer = detail('succeeded', orderStatus: 'ai_review');
    newer['ai_review_job'] = job('succeeded', attemptId: 3);
    newer['submission_attempts'] = [
      ...newer['submission_attempts'] as List,
      {
        'id': 3,
        'number': 3,
        'completion': {'work_done': 'Более новая сдача'},
        'ai_review': review('NEWER_RESULT'),
        'ai_job': job('succeeded', attemptId: 3),
      },
    ];
    newer['ai_review'] = review('NEWER_RESULT');
    var refreshes = 0;
    final controller = controllerFor(
      MemoryLocalStore(),
      MockClient((request) async {
        if (request.method == 'POST') {
          started.complete();
          return response.future;
        }
        refreshes++;
        return jsonResponse(newer);
      }),
    );
    addTearDown(controller.dispose);
    final loading = controller.retryAiReview(9, 2);
    await started.future;
    controller.orders = [WorkOrder.fromJson(newer)];
    response.complete(
      jsonResponse({'attempt_id': 2, 'ai_review': null, 'job': job('pending')}),
    );
    final updated = await loading;
    expect(refreshes, 1);
    expect(updated.aiReviewJob?['attempt_id'], 3);
    expect(updated.data['ai_review']['explanation'], 'NEWER_RESULT');
    expect(controller.orders.single.submissionAttempts.last['id'], 3);
  });

  test('a delayed retry reply preserves a succeeded read of the same submission in UI and cache', () async {
    final readStarted = Completer<void>();
    final retryStarted = Completer<void>();
    final readReply = Completer<http.Response>();
    final retryReply = Completer<http.Response>();
    final store = MemoryLocalStore();
    final controller = controllerFor(
      store,
      MockClient((request) async {
        if (request.method == 'POST') {
          retryStarted.complete();
          return retryReply.future;
        }
        readStarted.complete();
        return readReply.future;
      }),
    );
    addTearDown(controller.dispose);
    final reading = controller.loadOrder(9);
    await readStarted.future;
    final retrying = controller.retryAiReview(9, 2);
    await retryStarted.future;
    final succeeded = detail('succeeded', orderStatus: 'ai_review');
    (succeeded['submission_attempts'] as List).last['assessment_id'] = 33;
    readReply.complete(jsonResponse(succeeded));
    await reading;
    retryReply.complete(
      jsonResponse({'attempt_id': 2, 'ai_review': null, 'job': job('pending')}),
    );
    final returned = await retrying;
    expect(returned.status, 'ai_review');
    expect(returned.aiReviewJob?['status'], 'succeeded');
    expect(returned.data['ai_review']['explanation'], 'NEW_RESULT');
    expect(
      controller.orders.single.submissionAttempts.last['assessment_id'],
      33,
    );
    expect(
      controller.orders.single.submissionAttempts.last['ai_job']['status'],
      'succeeded',
    );
    final cached = await store.getSnapshot(
      localScopeKey(controller.api.baseUrl, 7, SnapshotKeys.orders),
    );
    expect(
      (cached!.data as List).single['ai_review']['explanation'],
      'NEW_RESULT',
    );
    expect(
      (cached.data as List).single['ai_review_job']['status'],
      'succeeded',
    );
    expect(await store.outbox(), isEmpty);
  });

  test('offline completion remains locally queued and clears the old aggregate review', () async {
    final store = MemoryLocalStore();
    final controller = controllerFor(
      store,
      MockClient((request) async => jsonResponse({})),
      role: 'worker',
      orderStatus: 'in_progress',
    )..offline = true;
    addTearDown(controller.dispose);
    final projected = await controller.complete(9, {
      'work_done': 'Новый отчёт',
      'fault_code_id': 1,
    });
    expect(projected.status, 'completed');
    expect(projected.pendingSync, isTrue);
    expect(projected.data['ai_review'], isNull);
    expect(projected.aiReviewJob, isNull);
    expect((await store.outbox()).single.kind, OutboxKind.complete);
  });

  testWidgets(
    'the open detail polls a pending job and shows only its new result',
    (tester) async {
      var reads = 0;
      final controller = controllerFor(
        MemoryLocalStore(),
        MockClient((request) async {
          reads++;
          return jsonResponse(
            reads == 1
                ? detail('pending')
                : detail('succeeded', orderStatus: 'ai_review'),
          );
        }),
        status: 'pending',
      );
      await openDetail(tester, controller);
      await tester.scrollUntilVisible(find.text('Проверка в очереди'), 300);
      expect(find.text('STALE_AGGREGATE'), findsNothing);
      expect(find.text('Принять работу'), findsNothing);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('NEW_RESULT'), 200);
      expect(find.text('NEW_RESULT'), findsOneWidget);
      expect(find.text('Проверка в очереди'), findsNothing);
      expect(reads, 2);
      expect(find.text('Принять работу'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'failed detail shows a friendly error and the master can explicitly queue a retry',
    (tester) async {
      var writes = 0;
      final controller = controllerFor(
        MemoryLocalStore(),
        MockClient((request) async {
          if (request.method == 'POST') {
            writes++;
            return jsonResponse({
              'attempt_id': 2,
              'ai_review': null,
              'job': job('pending'),
            });
          }
          return jsonResponse(detail('failed'));
        }),
      );
      await openDetail(tester, controller);
      await tester.scrollUntilVisible(find.text('Повторить проверку'), 300);
      await tester.ensureVisible(
        find.widgetWithText(OutlinedButton, 'Повторить проверку'),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('PRIVATE_PROVIDER_DIAGNOSTIC'), findsNothing);
      await tester.tap(find.text('Повторить проверку'));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(find.text('Проверка в очереди'), findsOneWidget);
      expect(find.text('Повторить проверку'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('bounded harness polling handles queued success and fails immediately on a failed job', () async {
    var reads = 0;
    final api = NaryadApi(
      'http://jobs.test',
      client: MockClient((request) async {
        reads++;
        return jsonResponse(
          reads == 1
              ? detail('pending')
              : detail('succeeded', orderStatus: 'ai_review'),
        );
      }),
    );
    addTearDown(api.close);
    expect(
      (await waitForAiReview(api, 9, interval: Duration.zero)).status,
      'ai_review',
    );
    expect(reads, 2);
    final failedApi = NaryadApi(
      'http://jobs.test',
      client: MockClient((request) async => jsonResponse(detail('failed'))),
    );
    addTearDown(failedApi.close);
    await expectLater(waitForAiReview(failedApi, 9), throwsStateError);
  });
}
