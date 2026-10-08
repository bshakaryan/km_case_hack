import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:naryad_ai/ui.dart';

WorkOrder cachedOrder(String status) => WorkOrder.fromJson({
  'id': 9,
  'version': 1,
  'number': 'AUDIT-9',
  'title': 'Проверить крепление двигателя',
  'description': 'Проверить крепление и выполнить контрольный запуск.',
  'status': status,
  'priority': 'normal',
  'work_type': 'planned',
  'assignee_id': 7,
  'assignee_name': 'Исполнитель',
  'normal_hours': 2,
  'deadline': '2026-10-07T18:00:00Z',
  'created_at': '2026-10-07T10:00:00Z',
  'is_overdue': false,
});

AppController offlineController(MemoryLocalStore store, String status) =>
    AppController(
        localStore: store,
        api: NaryadApi(
          'http://offline.test',
          client: MockClient((request) async {
            throw http.ClientException('Synthetic disconnected transport');
          }),
        ),
      )
      ..user = const User(id: 7, name: 'Исполнитель', role: 'worker')
      ..orders = [cachedOrder(status)];

void main() {
  testWidgets('order list distinguishes a local projected status', (
    tester,
  ) async {
    final order = WorkOrder.fromJson({
      ...cachedOrder('accepted').data,
      '_pending_sync': true,
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrderCard(order: order, onTap: () {}),
        ),
      ),
    );
    expect(find.text('Принят · ожидает начала'), findsOneWidget);
    expect(find.text('Ожидает синхронизации'), findsOneWidget);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: OrderCard(order: cachedOrder('accepted'), onTap: () {}),
        ),
      ),
    );
    expect(find.text('Ожидает синхронизации'), findsNothing);
  });

  testWidgets(
    'queued close score is selected locally, not a final server score',
    (tester) async {
      final store = MemoryLocalStore();
      final controller = offlineController(store, 'ai_review')
        ..user = const User(id: 7, name: 'Мастер', role: 'master');
      addTearDown(controller.dispose);
      await controller.transition(9, 'close', score: 5);
      await tester.pumpWidget(
        MaterialApp(
          home: OrderDetailScreen(controller: controller, orderId: 9),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Ожидает синхронизации'), findsOneWidget);
      expect(find.text('Итоговая оценка мастера: 5 / 5'), findsNothing);
      expect(
        find.text('Выбранная оценка: 5 / 5 · ожидает подтверждения сервера'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('offline acceptance never claims server confirmation', (
    tester,
  ) async {
    final store = MemoryLocalStore();
    final controller = offlineController(store, 'issued');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: OrderDetailScreen(controller: controller, orderId: 9)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Принять задание'));
    await tester.pumpAndSettle();

    expect((await store.outbox()).single.state, OutboxState.pending);
    expect(controller.orders.single.status, 'accepted');
    expect(
      find.text('Задание принято. Это ваше единственное текущее задание.'),
      findsNothing,
    );
    expect(
      find.text('Действие сохранено на устройстве. Ожидает отправки.'),
      findsOneWidget,
    );
    expect(find.text('Ожидает синхронизации'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('queued report overview does not claim work was received', (
    tester,
  ) async {
    final store = MemoryLocalStore();
    final controller = offlineController(store, 'in_progress');
    addTearDown(controller.dispose);
    await controller.complete(9, {
      'work_done': 'Крепление проверено, выполнен контрольный запуск.',
      'fault_code_id': 1,
      'materials': <Json>[],
      'comment': '',
    });
    await tester.pumpWidget(
      MaterialApp(home: OrderDetailScreen(controller: controller, orderId: 9)),
    );
    await tester.pumpAndSettle();

    expect(controller.isOrderPending(9), isTrue);
    expect(
      find.text('Работы сданы. Окончательное решение принимает мастер.'),
      findsNothing,
    );
    expect(
      find.text(
        'Отчёт сохранён на устройстве. Сервер ещё не подтвердил сдачу.',
      ),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('online acceptance retains server confirmation', (tester) async {
    final store = MemoryLocalStore();
    final controller =
        AppController(
            localStore: store,
            api: NaryadApi(
              'http://online.test',
              client: MockClient((request) async {
                Object response;
                if (request.url.path == '/api/orders/9') {
                  response = cachedOrder('issued').data;
                } else if (request.url.path.endsWith('/transition')) {
                  response = cachedOrder('accepted').data;
                } else if (request.url.path == '/api/orders') {
                  response = [cachedOrder('accepted').data];
                } else if (request.url.path == '/api/notifications' ||
                    request.url.path == '/api/employees') {
                  response = <Json>[];
                } else {
                  response = <String, dynamic>{};
                }
                return http.Response(
                  jsonEncode(response),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
            ),
          )
          ..user = const User(id: 7, name: 'Исполнитель', role: 'worker')
          ..orders = [cachedOrder('issued')];
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: OrderDetailScreen(controller: controller, orderId: 9)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Принять задание'));
    await tester.pumpAndSettle();

    expect(await store.outbox(), isEmpty);
    expect(
      find.text('Задание принято. Это ваше единственное текущее задание.'),
      findsOneWidget,
    );
    expect(find.text('Ожидает синхронизации'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
