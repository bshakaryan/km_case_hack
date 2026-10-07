import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imaging;
import 'package:image_picker/image_picker.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/screens/create_order_screen.dart';
import 'package:naryad_ai/ui.dart';

class _CreateController extends AppController {
  _CreateController() : super(localStore: MemoryLocalStore()) {
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
  Future<void> uploadPhoto(
    int id,
    Uint8List bytes,
    String filename,
    String kind,
  ) async {
    expect(id, 42);
    expect(kind, 'before');
    uploads.add(filename);
    if (uploadFailure != null && uploads.length == 2) throw uploadFailure!;
  }

  @override
  Future<WorkOrder> createOrder(Json data) async {
    submissions.add(Map<String, dynamic>.from(data));
    if (failure != null) throw failure!;
    return WorkOrder.fromJson({
      ...data,
      'id': 42,
      'number': 'Н-2026-42',
      'status': 'issued',
      'normal_hours': 2,
    });
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
      final controller = _CreateController()
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
        // Await the actual asynchronous UI callback, including image preparation.
        final dynamic pick = tester.widget<OutlinedButton>(gallery).onPressed;
        await tester.runAsync(() async => await pick());
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
