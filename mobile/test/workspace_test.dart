import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/main.dart';
import 'package:naryad_ai/screens/login_screen.dart';
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:naryad_ai/screens/workspace_screen.dart';

class TestController extends AppController {
  TestController() : super(localStore: MemoryLocalStore());
  int logins = 0;
  @override
  Future<void> restoreSession() async {}
  @override
  Future<void> login(String baseUrl, String login, String pin) async {
    logins++;
  }

  @override
  Future<void> refresh({bool silent = false}) async {}

  @override
  Future<WorkOrder> loadOrder(int id) async {
    for (final o in orders) {
      if (o.id == id) return o;
    }
    throw const ApiException('Нет связи с сервером', 0);
  }

  void expire() {
    user = null;
    notifyListeners();
  }
}

WorkOrder order(String status) => WorkOrder.fromJson({
  'id': 12,
  'number': 'НР-123',
  'title': 'Течь масла на насосе',
  'description': 'Проверить уплотнение и устранить течь масла.',
  'priority': 'emergency',
  'status': status,
  'work_type': 'unplanned',
  'deadline': '2026-10-05T15:00:00Z',
  'normal_hours': 2,
  'equipment_name': 'Насос Н-1',
  'area_name': 'Дробильный участок',
  'assignee_id': 6,
  'assignee_name': 'Исполнитель демо',
  'is_overdue': false,
});

void main() {
  testWidgets('Session restore shows a splash instead of flashing login', (
    tester,
  ) async {
    final c = TestController()..restoring = true;
    addTearDown(c.dispose);
    await tester.pumpWidget(NaryadApp(controller: c));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(LoginScreen), findsNothing);

    c
      ..user = const User(id: 1, name: 'Мастер', role: 'master')
      ..restoring = false;
    c.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceScreen), findsOneWidget);
  });

  testWidgets('Fresh start without a session lands on login, not splash', (
    tester,
  ) async {
    final c = TestController();
    addTearDown(c.dispose);
    await tester.pumpWidget(NaryadApp(controller: c));
    expect(find.byType(LoginScreen), findsOneWidget);
  });

  testWidgets('Rating drilldown includes the closed work behind the score', (
    tester,
  ) async {
    final c = TestController()
      ..user = const User(id: 1, name: 'Мастер', role: 'master')
      ..orders = [order('closed')]
      ..analytics = {
        'rankings': [
          {
            'id': 6,
            'name': 'Исполнитель демо',
            'specialty': 'Слесарь',
            'brigade': 'Бригада 1',
            'score': 90,
            'quality': 4,
            'on_time': 100,
            'closed_count': 1,
            'rework_rate': 0,
          },
        ],
      };
    addTearDown(c.dispose);
    await tester.pumpWidget(NaryadApp(controller: c));
    await tester.tap(find.text('Отчёты'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Посмотреть наряды →'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Посмотреть наряды →'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Посмотреть наряды →'));
    await tester.pumpAndSettle();
    expect(find.text('Найдено · 1'), findsOneWidget);
    expect(find.text('Течь масла на насосе'), findsOneWidget);
  });

  testWidgets('Empty login is rejected before a request is sent', (
    tester,
  ) async {
    final c = TestController();
    addTearDown(c.dispose);
    await tester.pumpWidget(NaryadApp(controller: c));
    await tester.tap(find.text('Войти'));
    await tester.pump();
    expect(c.logins, 0);
    expect(find.text('Введите логин'), findsOneWidget);
    expect(find.text('Не менее 4 символов'), findsOneWidget);
  });

  testWidgets(
    'Worker sees current work, no master assignment and no overflow at 360 px',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = TestController()
        ..user = const User(id: 6, name: 'Исполнитель демо', role: 'worker')
        ..orders = [order('in_progress')];
      addTearDown(c.dispose);
      await tester.pumpWidget(NaryadApp(controller: c));
      expect(find.text('Течь масла на насосе'), findsOneWidget);
      expect(find.text('Открыть и выполнить'), findsOneWidget);
      expect(find.text('Выдать наряд'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Master attention counters use real order state and open matching list',
    (tester) async {
      final c = TestController()
        ..user = const User(id: 1, name: 'Мастер демо', role: 'master')
        ..orders = [order('ai_review')];
      addTearDown(c.dispose);
      await tester.pumpWidget(NaryadApp(controller: c));
      await tester.tap(find.text('Ожидают приёмки'));
      await tester.pumpAndSettle();
      expect(find.text('Найдено · 1'), findsOneWidget);
      expect(find.text('Течь масла на насосе'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Offline banner builds without a color/decoration conflict', (
    tester,
  ) async {
    final c = TestController()
      ..user = const User(id: 1, name: 'Мастер', role: 'master')
      ..offline = true;
    addTearDown(c.dispose);
    await tester.pumpWidget(NaryadApp(controller: c));
    expect(
      find.text(
        'Нет соединения. Действия сохраняются на устройстве и отправятся после восстановления связи.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Order detail opens instantly from cache while offline', (
    tester,
  ) async {
    final c = TestController()
      ..user = const User(id: 1, name: 'Мастер', role: 'master')
      ..offline = true
      ..orders = [order('issued')];
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(home: OrderDetailScreen(controller: c, orderId: 12)),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('НР-123'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Expired session returns to login without retaining a protected route',
    (tester) async {
      final c = TestController()
        ..user = const User(id: 1, name: 'Мастер', role: 'master');
      addTearDown(c.dispose);
      await tester.pumpWidget(NaryadApp(controller: c));
      final context = tester.element(find.text('Рабочая смена'));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Protected')),
        ),
      );
      await tester.pumpAndSettle();
      c.expire();
      await tester.pumpAndSettle();
      expect(find.text('Protected'), findsNothing);
      expect(find.text('Войти'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
