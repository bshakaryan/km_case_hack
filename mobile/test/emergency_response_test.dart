import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:naryad_ai/ui.dart';

WorkOrder _order({
  int id = 12,
  String status = 'issued',
  int responsible = 6,
  bool pending = false,
}) => WorkOrder.fromJson({
  'id': id,
  'version': 3,
  'number': 'АВ-$id',
  'title': 'Аварийный ремонт насоса',
  'description': 'Проверить привод и устранить течь.',
  'priority': 'emergency',
  'status': status,
  'work_type': 'unplanned',
  'deadline': '2026-10-08T18:00:00Z',
  'normal_hours': 2,
  'assignee_id': responsible,
  'assignee_name': responsible == 6
      ? 'Ответственный Иван'
      : 'Ответственный Олег',
  'brigade_id': 2,
  'participants_source': 'live',
  'participants': [
    {
      'employee_id': 6,
      'name': 'Иван',
      'is_responsible': responsible == 6,
      'source': 'live',
    },
    {
      'employee_id': 7,
      'name': 'Анна',
      'is_responsible': false,
      'source': 'live',
    },
    if (responsible != 6)
      {
        'employee_id': responsible,
        'name': 'Олег',
        'is_responsible': true,
        'source': 'live',
      },
  ],
  'photos': <Json>[],
  if (pending) '_pending_sync': true,
});

class _Controller extends AppController {
  _Controller({int userId = 6}) : super(localStore: MemoryLocalStore()) {
    user = User(id: userId, name: 'Работник', role: 'worker');
    orders = [_order()];
  }

  Object? loadFailure;
  Completer<WorkOrder>? delayedLoad;
  Completer<WorkOrder>? delayedTransition;
  final List<String> transitions = [];
  final List<OrderWriteBasis?> bases = [];
  List<OutboxCommand> commands = [];

  @override
  List<OutboxCommand> get outbox => List.unmodifiable(commands);

  @override
  bool isOrderPending(int id) =>
      commands.any((command) => command.orderId == id);

  @override
  Future<WorkOrder> loadOrder(int id) async {
    if (delayedLoad != null) return delayedLoad!.future;
    if (loadFailure != null) throw loadFailure!;
    return orders.firstWhere((order) => order.id == id);
  }

  @override
  Future<WorkOrder> transition(
    int id,
    String action, {
    String? reason,
    double? score,
    OrderWriteBasis? basis,
  }) async {
    transitions.add(action);
    bases.add(basis);
    if (delayedTransition != null) return delayedTransition!.future;
    final status = switch (action) {
      'accept' => 'accepted',
      'queue' => 'queued',
      'reject' => 'rejected',
      _ => action,
    };
    final result = _order(status: status, pending: offline);
    if (offline) {
      commands = [
        OutboxCommand(
          commandId: 'emergency-response-1',
          kind: OutboxKind.transition,
          createdAt: 1,
          orderId: id,
          payload: {'action': action},
          expectedVersion: basis?.expectedVersion,
        ),
      ];
    }
    orders = [result];
    return result;
  }
}

Future<void> _open(
  WidgetTester tester,
  _Controller controller, {
  bool notificationEntry = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(),
      home: OrderDetailScreen(
        controller: controller,
        orderId: 12,
        notificationEntry: notificationEntry,
      ),
    ),
  );
  await tester.pump();
}

Future<void> _revealCue(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const ValueKey('emergency-response')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Notification entry waits for authorized detail without accepting',
    (tester) async {
      final controller = _Controller()..delayedLoad = Completer<WorkOrder>();
      addTearDown(controller.dispose);
      await _open(tester, controller);
      expect(find.text('Принять задание'), findsNothing);
      await _revealCue(tester);
      expect(find.textContaining('Проверяем доступ'), findsOneWidget);
      expect(controller.transitions, isEmpty);

      controller.delayedLoad!.complete(_order());
      await tester.pumpAndSettle();
      expect(find.text('Принять задание'), findsOneWidget);
      expect(find.text('В очередь'), findsOneWidget);
      expect(find.text('Отклонить'), findsOneWidget);
      expect(
        find.textContaining('Требуется ваш рабочий ответ:'),
        findsOneWidget,
      );
      expect(controller.transitions, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Busy responsible worker gets existing queue and rejection choices',
    (tester) async {
      final controller = _Controller()
        ..orders = [_order(), _order(id: 13, status: 'in_progress')];
      addTearDown(controller.dispose);
      await _open(tester, controller);
      await tester.pumpAndSettle();
      await _revealCue(tester);
      expect(find.text('Принять задание'), findsNothing);
      expect(find.text('В очередь'), findsOneWidget);
      expect(find.text('Отклонить'), findsOneWidget);
      expect(
        find.textContaining('уже есть незавершённое задание'),
        findsOneWidget,
      );
      expect(controller.transitions, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Participant reads emergency without responsible work responses',
    (tester) async {
      final controller = _Controller(userId: 7);
      addTearDown(controller.dispose);
      await _open(tester, controller);
      await tester.pumpAndSettle();
      await _revealCue(tester);
      expect(find.textContaining('Вы участник бригады.'), findsOneWidget);
      expect(find.text('Принять задание'), findsNothing);
      expect(find.text('В очередь'), findsNothing);
      expect(find.text('Отклонить'), findsNothing);
      expect(controller.transitions, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final busy in [false, true]) {
    testWidgets('Rework response preserves existing choices when busy=$busy', (
      tester,
    ) async {
      final controller = _Controller()
        ..orders = [
          _order(status: 'rework'),
          if (busy) _order(id: 13, status: 'in_progress'),
        ];
      addTearDown(controller.dispose);
      await _open(tester, controller);
      await tester.pumpAndSettle();
      await _revealCue(tester);
      expect(
        find.text('Принять доработку'),
        busy ? findsNothing : findsOneWidget,
      );
      expect(find.text('В очередь'), findsOneWidget);
      expect(find.text('Отклонить'), findsNothing);
      expect(find.textContaining('отклоните с причиной'), findsNothing);
      expect(
        find.textContaining(
          busy ? 'поставьте доработку в очередь.' : 'примите доработку',
        ),
        findsOneWidget,
      );
      expect(controller.transitions, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('Current reassignment immediately removes responsible controls', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await _open(tester, controller);
    await tester.pumpAndSettle();
    expect(find.text('Принять задание'), findsOneWidget);
    controller.orders = [_order(responsible: 9)];
    controller.notifyListeners();
    await tester.pumpAndSettle();
    await _revealCue(tester);
    expect(find.text('Принять задание'), findsNothing);
    expect(find.textContaining('Ответственный Олег.'), findsOneWidget);
    expect(controller.transitions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final code in [403, 404]) {
    testWidgets(
      'Definitive $code does not expose cached emergency or actions',
      (tester) async {
        final controller = _Controller()
          ..loadFailure = ApiException('Наряд недоступен ($code)', code);
        addTearDown(controller.dispose);
        await _open(tester, controller);
        await tester.pumpAndSettle();
        expect(find.text('Аварийный ремонт насоса'), findsNothing);
        expect(find.text('Принять задание'), findsNothing);
        expect(find.text('Повторить загрузку'), findsOneWidget);
        expect(controller.orders.single.title, 'Аварийный ремонт насоса');
        expect(controller.commands, isEmpty);
        expect(controller.transitions, isEmpty);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('Denied detail is not restored by offline cache fallback', (
    tester,
  ) async {
    final controller = _Controller()
      ..loadFailure = const ApiException('Доступ отклонён сервером', 403);
    addTearDown(controller.dispose);
    await _open(tester, controller);
    await tester.pumpAndSettle();
    expect(find.text('Аварийный ремонт насоса'), findsNothing);
    controller
      ..loadFailure = null
      ..offline = true;
    await tester.tap(find.text('Повторить загрузку'));
    await tester.pumpAndSettle();
    expect(find.text('Аварийный ремонт насоса'), findsNothing);
    expect(find.text('Принять задание'), findsNothing);
    expect(
      find.textContaining('повторная проверка доступа не выполнена'),
      findsOneWidget,
    );
    expect(controller.orders.single.title, 'Аварийный ремонт насоса');
    expect(controller.commands, isEmpty);

    controller.offline = false;
    await tester.tap(find.text('Повторить загрузку'));
    await tester.pumpAndSettle();
    expect(find.text('Аварийный ремонт насоса'), findsOneWidget);
    expect(find.text('Принять задание'), findsOneWidget);
    expect(controller.transitions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Closed current emergency is visible without response or start', (
    tester,
  ) async {
    final controller = _Controller()..orders = [_order(status: 'closed')];
    addTearDown(controller.dispose);
    await _open(tester, controller);
    await tester.pumpAndSettle();
    await _revealCue(tester);
    expect(find.textContaining('Принять или начать его'), findsOneWidget);
    expect(find.text('Принять задание'), findsNothing);
    expect(find.text('Начать исполнение'), findsNothing);
    expect(controller.transitions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Offline response remains explicitly unconfirmed and keeps basis',
    (tester) async {
      final controller = _Controller()..offline = true;
      addTearDown(controller.dispose);
      await _open(tester, controller);
      await tester.pumpAndSettle();
      await _revealCue(tester);
      expect(
        find.textContaining('не считается принятым сервером'),
        findsOneWidget,
      );
      await tester.tap(find.text('Принять задание'));
      await tester.pumpAndSettle();
      expect(controller.transitions, ['accept']);
      expect(controller.bases.single!.expectedVersion, 3);
      expect(controller.commands.single.expectedVersion, 3);
      expect(
        find.textContaining('Рабочий ответ сохранён на устройстве.'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Последнее подтверждённое состояние:'),
        findsNothing,
      );
      expect(
        find.text('Задание принято. Это ваше единственное текущее задание.'),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Photo pending is not labelled as an unconfirmed work response', (
    tester,
  ) async {
    final controller = _Controller()
      ..orders = [_order(status: 'accepted', pending: true)]
      ..commands = [
        const OutboxCommand(
          commandId: 'emergency-photo-1',
          kind: OutboxKind.uploadPhoto,
          createdAt: 1,
          orderId: 12,
          expectedVersion: 3,
        ),
      ];
    addTearDown(controller.dispose);
    await _open(tester, controller);
    await tester.pumpAndSettle();
    await _revealCue(tester);
    expect(
      find.textContaining('Есть изменения без подтверждения сервера.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Рабочий ответ сохранён на устройстве.'),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Confirmed accept remains explicit and double tap sends once', (
    tester,
  ) async {
    final controller = _Controller()
      ..delayedTransition = Completer<WorkOrder>();
    addTearDown(controller.dispose);
    await _open(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Принять задание'));
    await tester.tap(find.text('Принять задание'));
    expect(controller.transitions, ['accept']);
    controller.delayedTransition!.complete(_order(status: 'accepted'));
    await tester.pumpAndSettle();
    await _revealCue(tester);
    expect(
      find.textContaining('Последнее подтверждённое состояние:'),
      findsOneWidget,
    );
    expect(
      find.text('Задание принято. Это ваше единственное текущее задание.'),
      findsOneWidget,
    );
    expect(controller.bases.single!.expectedVersion, 3);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Other active write disables every emergency response choice', (
    tester,
  ) async {
    final controller = _Controller()..saving = true;
    addTearDown(controller.dispose);
    await _open(tester, controller);
    await tester.pumpAndSettle();
    final accept = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Принять задание'),
    );
    final queue = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'В очередь'),
    );
    final reject = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Отклонить'),
    );
    expect(accept.onPressed, isNull);
    expect(queue.onPressed, isNull);
    expect(reject.onPressed, isNull);
    expect(controller.transitions, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Late prior-token detail cannot restore protected content', (
    tester,
  ) async {
    final controller = _Controller()..delayedLoad = Completer<WorkOrder>();
    addTearDown(controller.dispose);
    await _open(tester, controller);
    controller.api.token = 'changed-synthetic-token';
    controller.notifyListeners();
    await tester.pumpAndSettle();
    controller.delayedLoad!.complete(_order());
    await tester.pumpAndSettle();
    expect(find.text('Аварийный ремонт насоса'), findsNothing);
    expect(find.text('Принять задание'), findsNothing);
    expect(
      find.textContaining('Сессия или сервер изменились.'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Late accept ACK does not notify a changed session', (
    tester,
  ) async {
    final controller = _Controller()
      ..delayedTransition = Completer<WorkOrder>();
    addTearDown(controller.dispose);
    await _open(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Принять задание'));
    controller.api.token = 'changed-synthetic-token';
    controller.notifyListeners();
    await tester.pumpAndSettle();
    controller.delayedTransition!.complete(_order(status: 'accepted'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Задание принято.'), findsNothing);
    expect(find.text('Аварийный ремонт насоса'), findsNothing);
    expect(controller.transitions, ['accept']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Prior-session rejection dialog closes without sending reason', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await _open(tester, controller);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Отклонить'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Смена закончилась');
    controller.api.token = 'changed-synthetic-token';
    controller.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(controller.transitions, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Prior-session photo source sheet closes without selecting media',
    (tester) async {
      final controller = _Controller();
      addTearDown(controller.dispose);
      await _open(tester, controller);
      await tester.pumpAndSettle();
      final photoButton = find.text('Добавить фото до');
      await tester.scrollUntilVisible(
        photoButton,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(photoButton);
      await tester.pumpAndSettle();
      await tester.tap(photoButton);
      // The parent intentionally stays busy until media selection completes.
      // Advance only the sheet entrance; its parent spinner cannot settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Сделать снимок'), findsOneWidget);
      controller.api.token = 'changed-synthetic-token';
      controller.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Сделать снимок'), findsNothing);
      expect(controller.commands, isEmpty);
      expect(controller.transitions, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Emergency response card and three choices fit a 360 px viewport',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = _Controller();
      addTearDown(controller.dispose);
      await _open(tester, controller);
      await tester.pumpAndSettle();
      await _revealCue(tester);
      expect(find.text('Аварийный наряд'), findsOneWidget);
      expect(find.text('Принять задание'), findsOneWidget);
      expect(find.text('В очередь'), findsOneWidget);
      expect(find.text('Отклонить'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
