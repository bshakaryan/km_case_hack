import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imaging;
import 'package:image_picker/image_picker.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/form_draft.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/screens/completion_screen.dart';
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:naryad_ai/screens/overview_screen.dart';
import 'package:naryad_ai/screens/orders_screen.dart';

WorkOrder _order({
  int id = 12,
  String status = 'in_progress',
  bool legacy = false,
}) => WorkOrder.fromJson({
  'id': id,
  'version': 3,
  'number': 'Н-БРИГАДА-$id',
  'title': 'Общий ремонт насоса',
  'description': 'Осмотр и ремонт привода.',
  'status': status,
  'priority': 'normal',
  'work_type': 'planned',
  'deadline': '2026-10-08T18:00:00Z',
  'normal_hours': 2,
  'assignee_id': 6,
  'assignee_name': 'Ответственный Иван',
  'brigade_id': 2,
  'photos': [],
  if (!legacy) 'participants_source': 'live',
  if (!legacy)
    'participants': [
      {
        'employee_id': 6,
        'name': 'Ответственный Иван',
        'is_responsible': true,
        'source': 'live',
      },
      {
        'employee_id': 7,
        'name': 'Участник Анна',
        'is_responsible': false,
        'source': 'live',
      },
    ],
});

class _Controller extends AppController {
  _Controller({String role = 'worker', int id = 7})
    : super(localStore: MemoryLocalStore()) {
    user = User(id: id, name: 'Участник Анна', role: role);
    orders = [_order()];
  }
  int openedDrafts = 0;
  int photos = 0;
  OrderWriteBasis? photoBasis;
  String? photoKind;
  final original = _order();

  @override
  Future<WorkOrder> loadOrder(int id) async =>
      orders.where((o) => o.id == id).first;

  @override
  Future<FormDraftSession> openFormDraft(String kind, {int? orderId}) {
    openedDrafts++;
    return super.openFormDraft(kind, orderId: orderId);
  }

  Future<FormDraftSession> seedSession() =>
      super.openFormDraft(FormDraftKind.completion, orderId: 12);

  @override
  Future<String> uploadPhoto(
    int id,
    Uint8List bytes,
    String filename,
    String kind, {
    OrderWriteBasis? basis,
  }) async {
    expect(id, 12);
    expect(imaging.decodeImage(bytes), isNotNull);
    photos++;
    photoBasis = basis;
    photoKind = kind;
    return 'brigade-photo-command';
  }
}

class _Picker extends ImagePicker {
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => XFile.fromData(
    Uint8List.fromList(imaging.encodePng(imaging.Image(width: 2, height: 2))),
    name: 'crew.png',
  );
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  test('Only the confirmed assignment grants participant access', () {
    final order = _order();
    expect(order.isResponsible(6), true);
    expect(order.isResponsible(7), false);
    expect(order.hasParticipant(7), true);
    expect(order.hasParticipant(8), false);
    final legacy = _order(legacy: true);
    expect(legacy.participants.single.employeeId, 6);
    expect(legacy.participantsSource, 'legacy_snapshot');
    expect(legacy.hasParticipant(7), false);
    expect(_order(id: -12).participants, isEmpty);
    expect(_order(id: -12).isResponsible(6), false);
    expect(
      WorkOrder.fromJson(order.toJson()).participants.map((p) => p.employeeId),
      [6, 7],
    );
  });

  testWidgets('Crew participation is separate from personal work and queue', (
    tester,
  ) async {
    final controller = _Controller()..orders = [_order(status: 'queued')];
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OverviewScreen(
              controller: controller,
              onOrder: (_) {},
              onCreate: ({int? assigneeId}) {},
              onFilter: (_) {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('Моя очередь к началу · 0'), findsOneWidget);
    expect(find.text('Участие в бригаде · 1'), findsOneWidget);
    expect(find.text('Открыть общий наряд'), findsOneWidget);
    expect(find.text('Открыть и выполнить'), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OrdersScreen(
              controller: controller,
              initialFilter: 'queue',
              onOrder: (_) {},
              onCreate: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('Найдено · 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Assistant direct completion does not open or mutate an existing draft',
    (tester) async {
      final controller = _Controller();
      addTearDown(controller.dispose);
      final session = await controller.seedSession();
      await session.save(
        FormDraft(
          kind: FormDraftKind.completion,
          orderId: 12,
          data: {'untouched': 'Черновик до смены ответственного'},
          basis: const OrderWriteBasis(expectedVersion: 2),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: CompletionScreen(
            controller: controller,
            order: controller.original,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(controller.openedDrafts, 0);
      expect(find.byType(TextFormField), findsNothing);
      expect(find.text('Отправить на приёмку'), findsNothing);
      expect(
        find.textContaining('Общий результат сдаёт только ответственный'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox());
      expect(
        (await session.read())!.data['untouched'],
        'Черновик до смены ответственного',
      );
    },
  );

  testWidgets(
    'Assistant cannot enqueue responsible transitions or completion',
    (tester) async {
      final controller = _Controller();
      addTearDown(controller.dispose);
      await expectLater(
        controller.transition(12, 'pause'),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
      );
      await expectLater(
        controller.complete(12, {'work_done': 'Недопустимая сдача'}),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
      );
      expect(controller.outbox, isEmpty);
    },
  );

  testWidgets(
    'An unconfirmed brigade placeholder cannot enqueue worker actions',
    (tester) async {
      final controller = _Controller();
      addTearDown(controller.dispose);
      final placeholder = _order(id: -12).toJson()
        ..remove('version')
        ..['assignee_id'] = null
        ..['assignee_name'] = ''
        ..['participants'] = <Json>[];
      controller.orders = [WorkOrder.fromJson(placeholder)];
      await expectLater(
        controller.transition(-12, 'start'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'status',
            403,
          ),
        ),
      );
      await expectLater(
        controller.complete(-12, {
          'work_done': 'Сдача без подтверждённого ответственного',
        }),
        throwsA(
          isA<ApiException>().having(
            (error) => error.statusCode,
            'status',
            403,
          ),
        ),
      );
      expect(controller.outbox, isEmpty);
      expect(controller.orders.single.toJson(), placeholder);
    },
  );

  testWidgets('Participant photo keeps the basis frozen before compression', (
    tester,
  ) async {
    final controller = _Controller();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: OrderDetailScreen(
          controller: controller,
          orderId: 12,
          imagePicker: _Picker(),
          photoPreparer: (bytes) async {
            controller.orders = [
              WorkOrder.fromJson({
                ...controller.original.toJson(),
                'version': 9,
              }),
            ];
            return bytes;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Исполнено · заполнить отчёт'), findsNothing);
    expect(find.text('Приостановить'), findsNothing);
    await _reveal(tester, find.text('Добавить фото после'));
    await tester.tap(find.text('Добавить фото после'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Выбрать из галереи'));
    await tester.pumpAndSettle();
    expect(controller.photos, 1);
    expect(controller.photoKind, 'after');
    expect(controller.photoBasis!.expectedVersion, 3);
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  for (final role in ['manager', 'worker']) {
    testWidgets('$role has no upload controls for forbidden access or status', (
      tester,
    ) async {
      final controller = _Controller(role: role)
        ..orders = [
          _order(status: role == 'manager' ? 'in_progress' : 'completed'),
        ];
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: OrderDetailScreen(controller: controller, orderId: 12),
        ),
      );
      await tester.pumpAndSettle();
      await _reveal(tester, find.text('Фотографии до и после'));
      expect(find.text('Добавить фото после'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
