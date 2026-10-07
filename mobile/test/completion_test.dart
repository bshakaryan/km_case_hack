import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/screens/completion_screen.dart';
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:naryad_ai/ui.dart';

WorkOrder _order({
  String workType = 'planned',
  String status = 'in_progress',
  bool previous = true,
}) => WorkOrder.fromJson({
  'id': 1,
  'number': 'Н-2026-001',
  'title': 'Замена подшипника привода',
  'description': 'Заменить подшипник и проверить конвейер под нагрузкой.',
  'status': status,
  'priority': 'normal',
  'work_type': workType,
  'area_name': 'Дробильный участок',
  'equipment_name': 'Конвейер КЛ-01',
  'assignee_id': 6,
  'assignee_name': 'Алексей Ким',
  'deadline': '2026-10-06T12:00:00Z',
  'created_at': '2026-10-06T08:00:00Z',
  'normal_hours': 2,
  'is_overdue': false,
  'downtime_minutes': 0,
  'photos': [],
  'events': [],
  if (previous)
    'completion': {
      'work_done': 'Подшипник заменён, выполнен контрольный запуск.',
      'fault_code_id': 1,
      'comment': 'Проверить крепление.',
      'materials': [
        {
          'material_id': 1,
          'name': 'Подшипник 6205',
          'quantity': 2,
          'unit': 'шт',
        },
      ],
    },
});

class _Controller extends AppController {
  _Controller(
    this.order, {
    this.uncertain = false,
    String role = 'worker',
    int userId = 6,
  }) : super(localStore: MemoryLocalStore()) {
    user = User(id: userId, name: 'Алексей Ким', role: role);
    reference = {
      'fault_codes': [
        {'id': 1, 'code': 'F01', 'name': 'Износ подшипника'},
      ],
      'materials': [
        {'id': 1, 'name': 'Подшипник 6205', 'unit': 'шт'},
      ],
    };
  }
  final WorkOrder order;
  final bool uncertain;
  int submissions = 0;
  int reads = 0;
  Json? payload;

  @override
  Future<WorkOrder> complete(int id, Json data) async {
    submissions++;
    payload = data;
    if (uncertain) {
      throw const ApiException(
        'Связь прервалась. Результат неизвестен.',
        0,
        requestMayHaveSucceeded: true,
      );
    }
    return WorkOrder.fromJson({
      ...order.data,
      'status': 'ai_review',
      'completion': data,
    });
  }

  @override
  Future<WorkOrder> loadOrder(int id) async {
    reads++;
    return order;
  }
}

Future<void> _open(WidgetTester tester, _Controller controller) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => CompletionScreen(
                    controller: controller,
                    order: controller.order,
                  ),
                ),
              ),
              child: const Text('Открыть отчёт'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть отчёт'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Unplanned report without after photo never reaches the API', (
    tester,
  ) async {
    final controller = _Controller(_order(workType: 'unplanned'));
    await _open(tester, controller);
    await tester.tap(find.text('Отправить на приёмку'));
    await tester.pumpAndSettle();
    expect(controller.submissions, 0);
    expect(find.textContaining('необходимо фото «после»'), findsOneWidget);
    expect(find.text('Отправить на приёмку'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Resubmission preserves work text but does not resubmit old materials',
    (tester) async {
      final controller = _Controller(_order());
      await _open(tester, controller);
      expect(
        find.text('Подшипник заменён, выполнен контрольный запуск.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Отправить на приёмку'));
      await tester.pumpAndSettle();
      expect(controller.submissions, 1);
      expect(controller.payload?['materials'], isEmpty);
      expect(controller.payload?['fault_code_id'], 1);
      expect(
        controller.payload?['work_done'],
        'Подшипник заменён, выполнен контрольный запуск.',
      );
      expect(find.text('Открыть отчёт'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Unknown completion result is reconciled without a duplicate write',
    (tester) async {
      final controller = _Controller(_order(), uncertain: true);
      await _open(tester, controller);
      await tester.tap(find.text('Отправить на приёмку'));
      await tester.pumpAndSettle();
      expect(controller.submissions, 1);
      expect(find.text('Отправить на приёмку'), findsNothing);
      expect(find.text('Проверить отправку'), findsOneWidget);
      await tester.tap(find.text('Проверить отправку'));
      await tester.pumpAndSettle();
      expect(controller.reads, 1);
      expect(controller.submissions, 1);
      expect(
        find.textContaining('Повторная отправка заблокирована'),
        findsOneWidget,
      );
      expect(
        find.text('Подшипник заменён, выполнен контрольный запуск.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Dirty report stays open on cancel and exits on explicit discard',
    (tester) async {
      final controller = _Controller(_order());
      await _open(tester, controller);
      await tester.enterText(
        find.byType(TextFormField).first,
        'Крепление подтянуто, выполнен повторный контрольный запуск.',
      );
      await tester.tap(find.byTooltip('Назад').first);
      await tester.pumpAndSettle();
      expect(find.text('Закрыть отчёт?'), findsOneWidget);
      await tester.tap(find.text('Продолжить заполнение'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Крепление подтянуто, выполнен повторный контрольный запуск.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Назад').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Закрыть форму'));
      await tester.pumpAndSettle();
      expect(find.text('Открыть отчёт'), findsOneWidget);
      expect(controller.submissions, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('System Back warns after typing into a clean report', (
    tester,
  ) async {
    final controller = _Controller(_order(previous: false));
    await _open(tester, controller);
    const draft = 'Подшипник заменён, идёт проверка под нагрузкой.';
    await tester.enterText(find.byType(TextFormField).first, draft);
    await tester.pump();

    // Exercise Android/system navigation, not our explicit AppBar handler.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Закрыть отчёт?'), findsOneWidget);
    expect(find.byType(CompletionScreen), findsOneWidget);
    await tester.tap(find.text('Продолжить заполнение'));
    await tester.pumpAndSettle();
    expect(find.text(draft), findsOneWidget);
    expect(controller.submissions, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Only the master sees acceptance actions', (tester) async {
    for (final role in ['worker', 'master']) {
      final controller = _Controller(_order(status: 'ai_review'), role: role);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: OrderDetailScreen(controller: controller, orderId: 1),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Принять работу'),
        role == 'master' ? findsOneWidget : findsNothing,
      );
      expect(
        find.text('На доработку'),
        role == 'master' ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
    }
  });

  testWidgets('Worker cannot execute an order assigned to someone else', (
    tester,
  ) async {
    final controller = _Controller(_order(status: 'issued'), userId: 7);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: OrderDetailScreen(controller: controller, orderId: 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Принять задание'), findsNothing);
    expect(find.text('В очередь'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
