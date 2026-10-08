import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imaging;
import 'package:image_picker/image_picker.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/form_draft.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/screens/create_order_screen.dart';
import 'package:naryad_ai/ui.dart';

class _CreateController extends AppController {
  _CreateController({MemoryLocalStore? store})
    : super(localStore: store ?? MemoryLocalStore()) {
    user = const User(id: 1, name: 'Мастер', role: 'master');
    reference = {
      'areas': [
        {'id': 1, 'name': 'Обогащение'},
      ],
      'equipment': [
        {
          'id': 8,
          'name': 'Насос НС-01',
          'area_id': 1,
          'inventory_number': 'КМ-1008',
        },
      ],
      'brigades': [
        {'id': 3, 'name': 'Механики'},
      ],
    };
    employees = [
      {
        'id': 6,
        'name': 'Иван Тестовый',
        'specialty': 'Слесарь',
        'on_shift': true,
        'status': 'free',
        'current_order': null,
        'queue_count': 0,
      },
    ];
  }

  final List<Json> submissions = [];
  ApiException? failure;
  final List<String> uploads = [];
  ApiException? uploadFailure;

  @override
  Future<String> uploadPhoto(
    int id,
    Uint8List bytes,
    String filename,
    String kind, {
    OrderWriteBasis? basis,
  }) async {
    expect(id, 42);
    expect(kind, 'before');
    uploads.add(filename);
    if (uploadFailure != null && uploads.length == 2) throw uploadFailure!;
    return 'test-photo-${uploads.length}';
  }

  @override
  Future<WorkOrder> createOrder(Json data) async {
    submissions.add(Map<String, dynamic>.from(data));
    if (failure != null) throw failure!;
    return WorkOrder.fromJson({
      ...data,
      'id': 42,
      'version': 1,
      'number': 'Н-2026-42',
      'status': 'issued',
      'normal_hours': 2,
    });
  }
}

Json _savedDraftData(Json data) => {
  'form_schema': 1,
  'title': '',
  'description': '',
  'comment': '',
  'step': 0,
  'area_id': null,
  'equipment_id': null,
  'assignee_id': null,
  'brigade_id': null,
  'by_brigade': false,
  'work_type': 'unplanned',
  'priority': 'normal',
  'deadline': DateTime.now()
      .toUtc()
      .add(const Duration(hours: 2))
      .toIso8601String(),
  'created': null,
  'creation_uncertain': false,
  'operation': null,
  'error': null,
  'photos': [],
  ...data,
};

class _SwitchDraftStore extends MemoryLocalStore {
  void Function()? onSubmitting;
  @override
  Future<void> putFormDraft(String key, Json value) async {
    await super.putFormDraft(key, value);
    if (value['state'] == FormDraftState.submitting) onSubmitting?.call();
  }
}

class _FailingDraftStore extends MemoryLocalStore {
  @override
  Future<void> putFormDraft(String key, Json value) async {
    throw StateError('Диск недоступен');
  }
}

class _PhotoPicker extends ImagePicker {
  @override
  Future<XFile?> pickImage({
    required ImageSource source,
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    CameraDevice preferredCameraDevice = CameraDevice.rear,
    bool requestFullMetadata = true,
  }) async => XFile.fromData(
    Uint8List.fromList(imaging.encodePng(imaging.Image(width: 32, height: 24))),
    mimeType: 'image/png',
    name: 'photo.png',
  );
}

Future<void> _open(
  WidgetTester tester,
  _CreateController controller, {
  int? assigneeId = 6,
  ImagePicker? imagePicker,
  void Function(WorkOrder?)? onResult,
}) async {
  await tester.binding.setSurfaceSize(const Size(412, 850));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(),
      locale: const Locale('ru'),
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('ru')],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                final result = await Navigator.of(context).push<WorkOrder>(
                  MaterialPageRoute(
                    builder: (_) => CreateOrderScreen(
                      controller: controller,
                      equipmentId: 8,
                      assigneeId: assigneeId,
                      imagePicker: imagePicker,
                      photoPreparer: (bytes) async => prepareOrderPhoto(bytes),
                    ),
                  ),
                );
                onResult?.call(result);
              },
              child: const Text('Открыть форму'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть форму'));
  await tester.pumpAndSettle();
}

Future<void> _fillTask(WidgetTester tester) async {
  final title = find.widgetWithText(TextFormField, 'Кратко о задаче *');
  final description = find.widgetWithText(
    TextFormField,
    'Проблема и необходимые работы *',
  );
  await tester.ensureVisible(title);
  await tester.enterText(title, 'Течь масла на насосе');
  await tester.ensureVisible(description);
  await tester.enterText(
    description,
    'Проверить уплотнение и устранить течь масла.',
  );
  await tester.tap(find.text('Далее · назначение'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Retrying a rejected photo never repeats creation or confirmed photos',
    (tester) async {
      final store = MemoryLocalStore();
      final controller = _CreateController(store: store)
        ..uploadFailure = const ApiException('Фото отклонено сервером', 422);
      addTearDown(controller.dispose);
      WorkOrder? result;
      await _open(
        tester,
        controller,
        imagePicker: _PhotoPicker(),
        onResult: (value) => result = value,
      );
      for (var i = 0; i < 2; i++) {
        final gallery = find.widgetWithText(OutlinedButton, 'Галерея');
        await tester.ensureVisible(gallery);
        await tester.tap(gallery);

        await tester.pumpAndSettle();
      }
      await _fillTask(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Выдать наряд'));
      await tester.pumpAndSettle();
      expect(controller.submissions, hasLength(1));
      expect(controller.uploads, hasLength(2));
      expect(result, isNull);
      expect(find.text('Фото подтверждено сервером'), findsOneWidget);
      expect(find.text('Фото отклонено сервером'), findsOneWidget);

      await tester.tap(find.text('Повторить неотправленные фото'));
      await tester.pumpAndSettle();
      expect(controller.submissions, hasLength(1));
      expect(controller.uploads, hasLength(3));
      expect(controller.uploads[0], isNot(controller.uploads[1]));
      expect(controller.uploads[1], controller.uploads[2]);
      expect(result?.id, 42);
    },
  );

  testWidgets('Required text is validated before any POST', (tester) async {
    final controller = _CreateController();
    addTearDown(controller.dispose);
    await _open(tester, controller);

    await tester.tap(find.text('Далее · назначение'));
    await tester.pumpAndSettle();

    expect(find.text('Опишите задачу — минимум 3 символа.'), findsOneWidget);
    expect(find.text('Заполните описание проблемы и работ.'), findsOneWidget);
    expect(controller.submissions, isEmpty);
  });

  testWidgets('A worker is never selected silently', (tester) async {
    final controller = _CreateController();
    addTearDown(controller.dispose);
    await _open(tester, controller, assigneeId: null);
    await _fillTask(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Выдать наряд'));
    await tester.pumpAndSettle();

    expect(find.text('Выберите исполнителя или бригаду.'), findsOneWidget);
    expect(controller.submissions, isEmpty);
  });

  testWidgets(
    'Server-confirmed creation returns WorkOrder and sends a UTC deadline',
    (tester) async {
      final controller = _CreateController();
      addTearDown(controller.dispose);
      WorkOrder? created;
      final before = DateTime.now().toUtc();
      await _open(tester, controller, onResult: (value) => created = value);
      await _fillTask(tester);

      expect(find.textContaining('Иван Тестовый'), findsOneWidget);
      expect(
        find.textContaining('Свободен · ожидают начала: 0'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Выдать наряд'));
      await tester.pumpAndSettle();

      expect(created?.id, 42);
      expect(find.text('Открыть форму'), findsOneWidget);
      expect(controller.submissions, hasLength(1));
      final payload = controller.submissions.single;
      expect(payload['assignee_id'], 6);
      expect(payload.containsKey('brigade_id'), false);
      expect(payload['area_id'], 1);
      expect(payload['equipment_id'], 8);
      expect(
        payload['description'],
        'Проверить уплотнение и устранить течь масла.',
      );
      expect(payload['priority'], 'normal');
      final deadline = DateTime.parse(payload['deadline'] as String);
      expect(deadline.isUtc, true);
      expect(
        deadline.isAfter(before.add(const Duration(hours: 1, minutes: 59))),
        true,
      );
      expect(
        deadline.isBefore(
          DateTime.now().toUtc().add(const Duration(hours: 2, minutes: 1)),
        ),
        true,
      );
    },
  );

  testWidgets('A worker who goes off shift is rejected before POST', (
    tester,
  ) async {
    final controller = _CreateController();
    addTearDown(controller.dispose);
    await _open(tester, controller);
    await _fillTask(tester);
    controller.employees.single['on_shift'] = false;

    await tester.tap(find.widgetWithText(FilledButton, 'Выдать наряд'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Выбранный исполнитель не на смене. Выберите другого работника.',
      ),
      findsOneWidget,
    );
    expect(controller.submissions, isEmpty);
  });

  testWidgets('An uncertain POST outcome blocks another creation', (
    tester,
  ) async {
    final controller = _CreateController()
      ..failure = const ApiException(
        'Нет ответа',
        0,
        requestMayHaveSucceeded: true,
      );
    addTearDown(controller.dispose);
    await _open(tester, controller);
    await _fillTask(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Выдать наряд'));
    await tester.pumpAndSettle();

    expect(controller.submissions, hasLength(1));
    expect(find.widgetWithText(FilledButton, 'Выдать наряд'), findsNothing);
    expect(find.text('Течь масла на насосе'), findsOneWidget);
    expect(find.text('Проверить список нарядов'), findsOneWidget);
    await tester.tap(find.text('Проверить список нарядов'));
    await tester.pumpAndSettle();
    expect(controller.submissions, hasLength(1));
  });

  testWidgets(
    'An explicit server rejection keeps input for an intentional retry',
    (tester) async {
      final controller = _CreateController()
        ..failure = const ApiException('Срок должен быть в будущем', 422);
      addTearDown(controller.dispose);
      await _open(tester, controller);
      await _fillTask(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Выдать наряд'));
      await tester.pumpAndSettle();
      expect(find.text('Срок должен быть в будущем'), findsOneWidget);
      expect(controller.submissions, hasLength(1));

      controller.failure = null;
      await tester.tap(find.widgetWithText(FilledButton, 'Выдать наряд'));
      await tester.pumpAndSettle();
      expect(controller.submissions, hasLength(2));
      expect(
        controller.submissions[1]['description'],
        controller.submissions[0]['description'],
      );
      expect(find.text('Открыть форму'), findsOneWidget);
    },
  );

  testWidgets(
    'Unsent creation draft survives screen restart with photo bytes and step',
    (tester) async {
      final store = MemoryLocalStore();
      final first = _CreateController(store: store);
      await _open(tester, first, imagePicker: _PhotoPicker());
      final gallery = find.widgetWithText(OutlinedButton, 'Галерея');
      await tester.ensureVisible(gallery);
      await tester.tap(gallery);
      await tester.pumpAndSettle();
      await _fillTask(tester);

      // Simulate process/screen removal after the disk acknowledgement.
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      final reopened = _CreateController(store: store);
      addTearDown(reopened.dispose);
      await _open(tester, reopened);
      expect(find.text('Шаг 2 из 2'), findsOneWidget);
      expect(find.textContaining('Иван Тестовый'), findsOneWidget);
      expect(find.text('Будет выдано: Течь масла на насосе'), findsOneWidget);
      expect(find.text('Фото перед отправкой: 1'), findsOneWidget);
      final session = await reopened.openFormDraft(FormDraftKind.create);
      final draft = (await session.read())!;
      final photo = (draft.data['photos'] as List).single;
      expect(
        imaging.decodeJpg(base64Decode(photo['bytes'] as String)),
        isNotNull,
      );
      expect(
        draft.data['description'],
        'Проверить уплотнение и устранить течь масла.',
      );
      expect(reopened.submissions, isEmpty);
      expect(reopened.uploads, isEmpty);
    },
  );

  testWidgets(
    'Interrupted creation marker restores locked without another create',
    (tester) async {
      final store = MemoryLocalStore();
      final seed = _CreateController(store: store);
      final session = await seed.openFormDraft(FormDraftKind.create);
      await session.save(
        FormDraft(
          kind: FormDraftKind.create,
          state: FormDraftState.submitting,
          data: _savedDraftData({
            'title': 'Течь масла на насосе',
            'description': 'Проверить уплотнение и устранить течь масла.',
            'step': 1,
            'area_id': 1,
            'equipment_id': 8,
            'assignee_id': 6,
            'deadline': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 2))
                .toIso8601String(),
            'operation': 'create',
            'photos': [],
          }),
        ),
      );
      seed.dispose();
      final controller = _CreateController(store: store);
      addTearDown(controller.dispose);
      await _open(tester, controller);
      expect(
        find.textContaining('Предыдущая отправка прервалась'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Выдать наряд'), findsNothing);
      await tester.tap(find.text('Проверить список нарядов'));
      await tester.pumpAndSettle();
      expect(controller.submissions, isEmpty);
      expect(controller.uploads, isEmpty);
      expect(find.text('Открыть форму'), findsOneWidget);
    },
  );

  testWidgets(
    'A draft disk failure blocks creation before the controller write',
    (tester) async {
      final controller = _CreateController(store: _FailingDraftStore());
      addTearDown(controller.dispose);
      await _open(tester, controller);
      await _fillTask(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Выдать наряд'));
      await tester.pumpAndSettle();
      expect(controller.submissions, isEmpty);
      expect(find.textContaining('Черновик не сохранён'), findsOneWidget);
      expect(find.text('Черновик сохранён на устройстве'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Owner switch while saving the preflight marker cannot send the old form',
    (tester) async {
      final store = _SwitchDraftStore();
      final controller = _CreateController(store: store);
      addTearDown(controller.dispose);
      store.onSubmitting = () => controller.user = const User(
        id: 99,
        name: 'Другой мастер',
        role: 'master',
      );
      await _open(tester, controller);
      await _fillTask(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Выдать наряд'));
      await tester.pumpAndSettle();
      expect(controller.submissions, isEmpty);
      expect(controller.uploads, isEmpty);
      expect(controller.outbox, isEmpty);
      expect(find.textContaining('Черновик не сохранён'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'A malformed partial create draft stays unavailable and is never submitted',
    (tester) async {
      final store = MemoryLocalStore();
      final seed = _CreateController(store: store);
      final session = await seed.openFormDraft(FormDraftKind.create);
      final truncated = _savedDraftData({'title': 'Ранее выданный наряд'})
        ..remove('created');
      await session.save(
        FormDraft(kind: FormDraftKind.create, data: truncated),
      );
      seed.dispose();
      final controller = _CreateController(store: store);
      addTearDown(controller.dispose);
      await _open(tester, controller);
      expect(
        find.textContaining('Не удалось открыть черновик'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Далее · назначение'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Назад'));
      await tester.pumpAndSettle();
      expect(find.text('Черновик недоступен'), findsOneWidget);
      await tester.tap(find.text('Закрыть форму'));
      await tester.pumpAndSettle();
      expect(controller.submissions, isEmpty);
      expect(find.text('Открыть форму'), findsOneWidget);
    },
  );

  testWidgets(
    'Partial confirmed create restart retries only the unconfirmed photo',
    (tester) async {
      final store = MemoryLocalStore();
      final seed = _CreateController(store: store);
      final bytes = base64Encode(
        imaging.encodeJpg(imaging.Image(width: 24, height: 20)),
      );
      final session = await seed.openFormDraft(FormDraftKind.create);
      await session.save(
        FormDraft(
          kind: FormDraftKind.create,
          basis: const OrderWriteBasis(
            previousCommandId: 'confirmed-photo-001',
          ),
          data: _savedDraftData({
            'title': 'Течь масла на насосе',
            'created': {
              'id': 42,
              'version': 2,
              'status': 'issued',
              'number': 'Н-2026-42',
              'title': 'Течь масла на насосе',
            },
            'photos': [
              {
                'bytes': bytes,
                'filename': 'before-confirmed.jpg',
                'state': 'uploaded',
                'queued': false,
                'error': null,
              },
              {
                'bytes': bytes,
                'filename': 'before-rejected.jpg',
                'state': 'failed',
                'queued': false,
                'error': 'Фото отклонено',
              },
            ],
          }),
        ),
      );
      seed.dispose();
      final controller = _CreateController(store: store);
      addTearDown(controller.dispose);
      await _open(tester, controller);
      expect(find.text('Наряд выдан'), findsOneWidget);
      expect(controller.submissions, isEmpty);
      await tester.tap(find.text('Повторить неотправленные фото'));
      await tester.pumpAndSettle();
      expect(controller.submissions, isEmpty);
      expect(controller.uploads, ['before-rejected.jpg']);
      expect(find.text('Открыть форму'), findsOneWidget);
    },
  );

  test('Photo preparation resizes while preserving aspect ratio and rejects nonimages', () {
    final source = imaging.Image(width: 3000, height: 1000);
    final prepared = prepareOrderPhoto(
      Uint8List.fromList(imaging.encodePng(source)),
    );
    final image = imaging.decodeJpg(prepared)!;
    expect(image.width, 1920);
    expect(image.height, 640);
    expect(prepared.length, lessThan(10 * 1024 * 1024));
    expect(
      () => prepareOrderPhoto(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
  });
}
