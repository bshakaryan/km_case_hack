// Opt-in test for a disposable seeded API and a real Android emulator.
// flutter test integration_test/web_bridge_test.dart -d emulator-5556 \
//   --dart-define=API_BASE_URL=http://10.0.2.2:8000 \
//   --dart-define=BRIDGE_TITLE=<same unique title as the web coordinator>
//
// The coordinator creates an unplanned order for worker2, requests rework after
// BRIDGE_FIRST, then closes BRIDGE_REWORK with score 5. WEB milestones mean the
// external web API client; they do not claim browser UI coverage. Leave each
// ai_review state visible for 10 seconds so the mobile UI can observe it.
// All worker lifecycle writes use real UI. Only synthetic photo preparation /
// upload and negative permission probes use the real API directly. There are
// no HTTP or platform mocks. Native camera / gallery selection is NOT tested.
// This test never cancels or edits unrelated seeded orders; completed data stays
// on the disposable server as evidence. Use a new BRIDGE_TITLE for each run.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/main.dart';
import 'package:naryad_ai/screens/completion_screen.dart';
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:naryad_ai/screens/workspace_screen.dart';
import 'package:naryad_ai/widgets/order_photo.dart';

const _title = String.fromEnvironment('BRIDGE_TITLE');
const _baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8000',
);
const _pause = bool.fromEnvironment('BRIDGE_PAUSE', defaultValue: true);
const _externalSeconds = int.fromEnvironment(
  'BRIDGE_WAIT_SECONDS',
  defaultValue: 120,
);
const _firstReport =
    'BRIDGE_FIRST: заменён узел, выполнен контрольный запуск оборудования. '
    'Синтетическая проверка интеграции.';
const _secondReport =
    'BRIDGE_REWORK: повторно проверено крепление, результат проверен под нагрузкой. '
    'Синтетическая проверка интеграции.';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'web API master and Android worker share one complete order lifecycle',
    (tester) async {
      const storage = FlutterSecureStorage();
      // Clear this app's test session only; do not erase other secure storage.
      await storage.delete(key: 'naryad.native.session.v1');
      final controller = AppController(storage: storage);
      final foreign = NaryadApi(_baseUrl, client: _TraceTransport());
      final anonymous = NaryadApi(_baseUrl, client: _TraceTransport());
      int? orderId;
      try {
        await tester.pumpWidget(NaryadApp(controller: controller));
        await _waitUntil(
          tester,
          () => !controller.loading && _field('Логин').evaluate().isNotEmpty,
          'login screen and secure storage restoration',
        );
        await _enter(tester, _field('Логин'), 'worker2');
        await _enter(tester, _field('ПИН-код'), '1234');
        await _tap(tester, find.widgetWithText(FilledButton, 'Войти'));
        await _waitUntil(
          tester,
          () => controller.user != null && !controller.loading,
          'worker UI login',
          diagnostics: () => controller.error,
        );
        expect(controller.user!.isWorker, isTrue);
        expect(find.byType(WorkspaceScreen), findsOneWidget);
        await foreign.login('worker', '1234');
        expect((await foreign.me()).id, isNot(controller.user!.id));
        expect(
          controller.orders.where(
            (order) =>
                order.status == 'in_progress' &&
                order.data['assignee_id'] == controller.user!.id,
          ),
          isEmpty,
          reason:
              'worker2 must have no running work. Prepare an isolated demo '
              'server; this test does not alter existing assignments.',
        );
        _step('WAIT_WEB_CREATE', {'title': _title});
        await _waitUntil(
          tester,
          () => controller.orders.any((order) => order.title == _title),
          'web-created order to arrive through native polling',
          timeout: const Duration(seconds: 90),
          diagnostics: () => controller.error,
        );
        final order = controller.orders
            .where((order) => order.title == _title)
            .single;
        orderId = order.id;
        expect(order.status, 'issued');
        expect(order.workType, 'unplanned');
        expect(order.data['assignee_id'], controller.user!.id);
        final fault = _maps(controller.reference['fault_codes']).first;
        final material = _maps(controller.reference['materials']).first;

        await _tap(
          tester,
          find.descendant(
            of: find.byType(NavigationBar),
            matching: find.text('Наряды'),
          ),
        );
        await _enter(
          tester,
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.hintText == 'Номер, оборудование, проблема',
          ),
          _title,
        );
        await _tap(
          tester,
          find.byWidgetPredicate(
            (widget) => widget is Text && widget.data == _title,
          ),
        );
        await _waitUntil(
          tester,
          () => find.text('Принять задание').evaluate().isNotEmpty,
          'order details',
        );
        expect(find.byType(OrderDetailScreen), findsOneWidget);
        await _tap(
          tester,
          find.widgetWithText(FilledButton, 'Принять задание'),
        );
        await _waitUntil(
          tester,
          () => find.text('Начать исполнение').evaluate().isNotEmpty,
          'accepted assignment',
        );
        await _tap(
          tester,
          find.widgetWithText(FilledButton, 'Начать исполнение'),
        );
        await _waitUntil(
          tester,
          () => find.text('Исполнено · заполнить отчёт').evaluate().isNotEmpty,
          'running work',
        );
        if (_pause) {
          await _tap(
            tester,
            find.widgetWithText(OutlinedButton, 'Приостановить'),
          );
          await _waitUntil(
            tester,
            () => find.byType(AlertDialog).evaluate().isNotEmpty,
            'pause reason dialog',
          );
          await _enter(
            tester,
            _field('Причина'),
            'Синтетическая проверка: ожидание контрольного инструмента.',
          );
          await _tap(
            tester,
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.widgetWithText(FilledButton, 'Приостановить'),
            ),
          );
          await _waitUntil(
            tester,
            () => find.text('Продолжить работу').evaluate().isNotEmpty,
            'paused work',
          );
          await _tap(
            tester,
            find.widgetWithText(FilledButton, 'Продолжить работу'),
          );
          await _waitUntil(
            tester,
            () =>
                find.text('Исполнено · заполнить отчёт').evaluate().isNotEmpty,
            'resumed work',
          );
        }
        _step('WORKER_RUNNING', {'orderId': orderId});

        for (final kind in ['before', 'after']) {
          final picture = img.Image(width: 160, height: 120);
          img.fill(
            picture,
            color: kind == 'before'
                ? img.ColorRgb8(170, 85, 30)
                : img.ColorRgb8(35, 145, 80),
          );
          await controller.uploadPhoto(
            order.id,
            Uint8List.fromList(img.encodePng(picture)),
            'bridge-synthetic-$kind.png',
            kind,
          );
        }
        final photographed = await controller.loadOrder(order.id);
        final photos = _maps(photographed.data['photos']);
        expect(
          photos.where((photo) => photo['kind'] == 'before'),
          hasLength(1),
        );
        expect(photos.where((photo) => photo['kind'] == 'after'), hasLength(1));
        final afterId =
            (photos.singleWhere((p) => p['kind'] == 'after')['id'] as num)
                .toInt();
        final jpeg = await controller.api.photo(afterId);
        expect(jpeg.take(2).toList(), [0xff, 0xd8]);
        expect(img.decodeJpg(jpeg), isNotNull);
        await expectLater(foreign.order(order.id), throwsA(_httpStatus(403)));
        await expectLater(foreign.photo(afterId), throwsA(_httpStatus(403)));
        await expectLater(anonymous.photo(afterId), throwsA(_httpStatus(401)));

        // Detail state is separate from the controller's list snapshot.
        // Explicitly refresh it before CompletionScreen captures existing photos.
        await _tap(tester, find.byTooltip('Обновить наряд'));
        final afterWidget = find.byWidgetPredicate(
          (widget) => widget is OrderPhoto && widget.photo['id'] == afterId,
        );
        await _reveal(tester, find.text('Фотографии до и после'));
        await _waitUntil(
          tester,
          () => afterWidget.evaluate().isNotEmpty,
          'server photo visible in native order detail',
        );
        await _reveal(tester, afterWidget);
        await _waitUntil(
          tester,
          () => find
              .descendant(of: afterWidget, matching: find.byType(Image))
              .evaluate()
              .isNotEmpty,
          'authenticated JPEG rendering',
        );
        _step('PHOTOS_AND_PERMISSIONS_OK', {'orderId': orderId});

        await _submitReport(tester, fault, material, _firstReport, '2');
        var submitted = await controller.loadOrder(order.id);
        expect(
          (submitted.data['completion'] as Json)['work_done'],
          _firstReport,
        );
        expect(_materialTotal(submitted, material['id']), 2);
        expect((submitted.data['ai_review'] as Json)['is_stub'], isTrue);
        await expectLater(
          controller.api.transition(order.id, 'close', score: 5),
          throwsA(_httpStatus(403)),
        );
        _step('WAIT_WEB_REWORK', {'orderId': orderId, 'title': _title});
        await _waitUntil(
          tester,
          () => find.text('Начать доработку').evaluate().isNotEmpty,
          'external master rework to reach native UI',
          timeout: Duration(seconds: _externalSeconds),
        );
        final rework = await controller.loadOrder(order.id);
        expect(rework.status, 'rework');
        expect(
          _maps(rework.data['events']).any((e) => e['action'] == 'rework'),
          isTrue,
        );
        await _tap(
          tester,
          find.widgetWithText(FilledButton, 'Начать доработку'),
        );
        await _waitUntil(
          tester,
          () => find.text('Исполнено · заполнить отчёт').evaluate().isNotEmpty,
          'rework started through native UI',
        );
        await _submitReport(
          tester,
          fault,
          material,
          _secondReport,
          '1',
          rework: true,
        );
        submitted = await controller.loadOrder(order.id);
        expect(
          (submitted.data['completion'] as Json)['work_done'],
          _secondReport,
        );
        expect(_materialTotal(submitted, material['id']), 3);
        _step('WAIT_WEB_CLOSE', {'orderId': orderId, 'title': _title});
        // Returning from completion keeps the detail list's old scroll offset.
        // Its overview is the first lazy child: reveal it by scrolling this
        // route's list to the top, never by searching farther down the page.
        final detailList = find
            .descendant(
              of: find.byType(OrderDetailScreen),
              matching: find.byType(ListView),
            )
            .first;
        final detailScrollable = find
            .descendant(of: detailList, matching: find.byType(Scrollable))
            .first;
        await _waitUntil(
          tester,
          () =>
              detailList.evaluate().isNotEmpty &&
              detailScrollable.evaluate().isNotEmpty,
          'active order detail list after completion',
        );
        tester.state<ScrollableState>(detailScrollable).position.jumpTo(0);
        await tester.pump(const Duration(milliseconds: 300));
        final overviewTitle = find.descendant(
          of: detailList,
          matching: find.text(_title),
        );
        final closedStatus = find.descendant(
          of: detailList,
          matching: find.text('Закрыт'),
        );
        final finalScore = find.descendant(
          of: detailList,
          matching: find.text('Итоговая оценка мастера: 5 / 5'),
        );
        await _waitUntil(
          tester,
          () =>
              overviewTitle.evaluate().isNotEmpty &&
              closedStatus.evaluate().isNotEmpty &&
              finalScore.evaluate().isNotEmpty,
          'external master close and score in native order overview',
          timeout: Duration(seconds: _externalSeconds),
        );
        expect(overviewTitle, findsOneWidget);
        expect(closedStatus, findsOneWidget);
        expect(finalScore, findsOneWidget);
        final closed = await controller.loadOrder(order.id);
        expect(closed.status, 'closed');
        expect(closed.score, 5);
        expect(_materialTotal(closed, material['id']), 3);
        final actions = _maps(closed.data['events'])
            .map((e) => e['action'])
            .toList();
        expect(
          actions,
          containsAllInOrder([
            'issue',
            'accept',
            'start',
            if (_pause) ...['pause', 'resume'],
            'photo',
            'photo',
            'complete',
            'ai_review',
            'rework',
            'start',
            'complete',
            'ai_review',
            'close',
          ]),
        );
        expect(actions.where((action) => action == 'complete'), hasLength(2));
        expect(actions.where((action) => action == 'close'), hasLength(1));
        expect(find.text('Исполнено · заполнить отчёт'), findsNothing);
        _step('PASS', {
          'orderId': orderId,
          'score': closed.score,
          'materialTotal': 3,
        });
      } finally {
        // Dispose routes first to stop their own pollers, then revoke only the
        // sessions opened by this test. Never close/cancel a partially run order.
        _step('TEARDOWN', {'orderId': orderId});
        await tester.pumpWidget(const SizedBox.shrink());
        try {
          await controller.logout();
        } finally {
          controller.dispose();
          try {
            if (foreign.token != null) await foreign.logout();
          } on ApiException {
            // A stopped disposable server cannot acknowledge revocation.
          } finally {
            foreign.close();
            anonymous.close();
          }
        }
      }
    },
    skip: _title.isEmpty,
    timeout: Timeout(Duration(seconds: 420 + 2 * _externalSeconds)),
  );
}

Future<void> _submitReport(
  WidgetTester tester,
  Json fault,
  Json material,
  String report,
  String quantity, {
  bool rework = false,
}) async {
  await _tap(
    tester,
    find.widgetWithText(FilledButton, 'Исполнено · заполнить отчёт'),
  );
  await _waitUntil(
    tester,
    () => find.byType(CompletionScreen).evaluate().isNotEmpty,
    'completion form',
  );
  await _enter(tester, _field('Что сделано'), report);
  if (rework) {
    await _reveal(tester, find.text('Найти и добавить материал'));
    expect(
      _field('Количество'),
      findsNothing,
      reason: 'Rework must not prefill previously written-off materials.',
    );
    expect(
      find.text('Материалы не добавлены. Можно отправить отчёт без расхода.'),
      findsOneWidget,
    );
  } else {
    final dropdown = find.byType(DropdownButtonFormField<int>);
    await _tap(tester, dropdown);
    await tester.pump(const Duration(milliseconds: 350));
    await _tap(tester, find.text('${fault['code']} · ${fault['name']}').last);
  }
  await _tap(tester, find.text('Найти и добавить материал'));
  await _waitUntil(
    tester,
    () => _field('Поиск по справочнику').evaluate().isNotEmpty,
    'material search sheet',
  );
  await _enter(
    tester,
    _field('Поиск по справочнику'),
    material['name'] as String,
  );
  await _tap(tester, find.widgetWithText(ListTile, material['name'] as String));
  await _waitUntil(
    tester,
    () => _field('Поиск по справочнику').evaluate().isEmpty,
    'selected material',
  );
  await _enter(tester, _field('Количество'), quantity);
  await _tap(tester, find.text('Отправить на приёмку'));
  await _waitUntil(
    tester,
    () =>
        find.byType(CompletionScreen).evaluate().isEmpty &&
        find.byType(OrderDetailScreen).evaluate().isNotEmpty &&
        find.text('Исполнено · заполнить отчёт').evaluate().isEmpty,
    'report accepted by server and detail screen restored',
  );
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'editable field "$label"',
);

Future<void> _enter(WidgetTester tester, Finder target, String text) async {
  await _reveal(tester, target);
  await tester.enterText(target, text);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await _reveal(tester, target);
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    // Lazy ListView children may not exist yet. Start at the top of the active
    // list, then perform bounded user-like scrolling to materialize the target.
    final list = find.byType(ListView).last;
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 300));
    if (target.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        target,
        220,
        scrollable: scrollable,
        maxScrolls: 35,
        duration: const Duration(milliseconds: 100),
      );
    }
  }
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 150));
}

Future<void> _waitUntil(
  WidgetTester tester,
  bool Function() ready,
  String description, {
  Duration timeout = const Duration(seconds: 60),
  String? Function()? diagnostics,
}) async {
  // IntegrationTest uses a live binding: network, native plugins and periodic
  // pollers continue in real time. pumpAndSettle is unsuitable for these screens.
  final clock = Stopwatch()..start();
  while (!ready()) {
    if (clock.elapsed >= timeout) {
      fail(
        'Timed out after ${timeout.inSeconds}s waiting for $description. '
        '${diagnostics?.call() ?? ''}',
      );
    }
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      tester.takeException(),
      isNull,
      reason: 'While waiting for $description',
    );
  }
}

List<Json> _maps(dynamic value) => (value as List)
    .map((item) => Map<String, dynamic>.from(item as Map))
    .toList();

double _materialTotal(WorkOrder order, dynamic materialId) =>
    _maps((order.data['completion'] as Json)['materials'])
        .where((item) => item['material_id'] == materialId)
        .fold<double>(
          0,
          (sum, item) => sum + (item['quantity'] as num).toDouble(),
        );

Matcher _httpStatus(int status) => isA<ApiException>().having(
  (error) => error.statusCode,
  'HTTP status',
  status,
);

void _step(String name, Json data) {
  // Deliberate machine-readable rendezvous. Never print credentials or tokens.
  // ignore: avoid_print
  print('BRIDGE_STEP $name ${jsonEncode(data)}');
}

// A real transport with diagnostics for emulator networking. Never print an
// authorization header, request body, PIN or token, and never retry a write.
class _TraceTransport extends http.BaseClient {
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    try {
      return await _inner.send(request);
    } on http.ClientException catch (error) {
      _step('TRANSPORT_FAILURE', {
        'host': request.url.host,
        'path': request.url.path,
        'cause': error.message,
      });
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}
