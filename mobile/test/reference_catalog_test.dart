import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/domain/reference_edit.dart';
import 'package:naryad_ai/screens/reference_catalog_screen.dart';
import 'package:naryad_ai/screens/workspace_screen.dart';
import 'package:naryad_ai/ui.dart';

const _artifactDirectory = String.fromEnvironment('TEST_ARTIFACT_DIRECTORY');
const _captureKey = ValueKey('reference-artifact-boundary');

class _CatalogController extends AppController {
  _CatalogController({String role = 'admin'})
    : super(
        api: NaryadApi('http://catalog.test'),
        localStore: MemoryLocalStore(),
      ) {
    api.token = 'private-token';
    user = User(id: 4, name: 'Администратор', role: role);
    reference = {
      'areas': [
        {'id': 1, 'name': 'Цех'},
        {'id': 2, 'name': 'Склад'},
      ],
      'equipment': [
        {
          'id': 9,
          'name': 'Насос',
          'inventory_number': 'INV-9',
          'area_id': 1,
          'type': 'Насосное',
          'criticality': 'custom-important',
        },
      ],
      'materials': [
        {'id': 6, 'name': 'Уплотнение', 'unit': 'шт'},
      ],
    };
  }

  final List<ReferenceEditTicket> tickets = [];
  final List<Json> submitted = [];
  bool writeBusy = false, syncBusy = false, recoveryBusy = false;
  bool failOpen = false;
  int refreshCalls = 0;
  ReferenceMutationResult mutationResult = const ReferenceMutationResult(
    ReferenceMutationStatus.saved,
    row: {'id': 11, 'name': 'Новая запись'},
  );
  ReferenceRefreshResult refreshResult = const ReferenceRefreshResult(
    ReferenceRefreshStatus.refreshed,
  );
  Completer<ReferenceMutationResult>? delayedWrite;
  Completer<ReferenceRefreshResult>? delayedRefresh;

  @override
  bool get canManageReferences => user?.role == 'admin';
  @override
  bool get referenceWriteBusy =>
      writeBusy || syncBusy || recoveryBusy || saving || restoring;
  @override
  List<ReferenceEditTicket> get referenceEdits =>
      tickets.where((ticket) => ticket.isCurrent).toList();
  @override
  ReferenceEditScope captureReferenceScope() {
    if (!canManageReferences) {
      throw const ApiException('Нужна роль администратора.', 403);
    }
    final source = api, epoch = api.sessionEpoch, owner = user?.id;
    return ReferenceEditScope(
      () =>
          identical(api, source) &&
          !source.isClosed &&
          source.sessionEpoch == epoch &&
          user?.id == owner &&
          owner != null &&
          canManageReferences,
    );
  }

  @override
  ReferenceEditTicket openReferenceEdit(
    ReferenceCollection collection, {
    int? id,
    bool newOperation = false,
  }) {
    if (failOpen) throw StateError('Record disappeared before edit');
    final existing = tickets
        .where(
          (ticket) =>
              ticket.isCurrent &&
              ticket.collection == collection &&
              ticket.id == id,
        )
        .lastOrNull;
    if (existing != null &&
        (existing.state != ReferenceEditState.saved || !newOperation)) {
      return existing;
    }
    final scope = captureReferenceScope();
    final collectionKey = collection == ReferenceCollection.equipment
        ? 'equipment'
        : 'materials';
    final initial =
        (reference[collectionKey] as List)
            .cast<Json>()
            .where((row) => row['id'] == id)
            .firstOrNull ??
        <String, dynamic>{};
    final ticket = ReferenceEditTicket(
      collection: collection,
      id: id,
      scope: scope,
      initialValues: jsonDecode(jsonEncode(initial)) as Json,
      preflight: () => referenceWriteBusy
          ? const ReferenceMutationResult(ReferenceMutationStatus.busy)
          : offline
          ? const ReferenceMutationResult(ReferenceMutationStatus.offline)
          : null,
      send: (values) async {
        submitted.add(jsonDecode(jsonEncode(values)) as Json);
        writeBusy = true;
        notifyListeners();
        final result = delayedWrite == null
            ? mutationResult
            : await delayedWrite!.future;
        writeBusy = false;
        if (!scope.isCurrent) {
          return const ReferenceMutationResult(
            ReferenceMutationStatus.scopeChanged,
            mayHaveSucceeded: true,
          );
        }
        notifyListeners();
        return result;
      },
      changed: notifyListeners,
    );
    tickets.add(ticket);
    return ticket;
  }

  @override
  Future<ReferenceRefreshResult> refreshReferences(
    ReferenceEditScope scope,
  ) async {
    refreshCalls++;
    final result = delayedRefresh == null
        ? refreshResult
        : await delayedRefresh!.future;
    if (!scope.isCurrent) {
      return const ReferenceRefreshResult(ReferenceRefreshStatus.scopeChanged);
    }
    notifyListeners();
    return result;
  }

  void boundary(String kind) {
    switch (kind) {
      case 'token':
        api.token = 'next-token';
      case 'same-token':
        api.token = api.token;
      case 'api':
        api = NaryadApi('http://other.test')..token = 'private-token';
      case 'owner':
        user = const User(id: 5, name: 'Другой администратор', role: 'admin');
      case 'role':
        user = const User(id: 4, name: 'Администратор', role: 'master');
    }
    notifyListeners();
  }
}

Future<void> _host(
  WidgetTester tester,
  _CatalogController controller, {
  bool workspace = false,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: _captureKey,
      child: MaterialApp(
        theme: appTheme(),
        home: workspace
            ? WorkspaceScreen(controller: controller)
            : Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            ReferenceCatalogScreen(controller: controller),
                      ),
                    ),
                    child: const Text('Открыть каталог'),
                  ),
                ),
              ),
      ),
    ),
  );
  if (!workspace) {
    await tester.tap(find.text('Открыть каталог'));
    await tester.pumpAndSettle();
  }
}

Finder _field(String key) => find.byKey(ValueKey('reference-field-$key'));
bool _readOnly(WidgetTester tester, String key) => tester
    .widget<EditableText>(
      find.descendant(of: _field(key), matching: find.byType(EditableText)),
    )
    .readOnly;
Finder get _editorScroll => find
    .descendant(
      of: find.byType(ReferenceEditorScreen),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _tap(WidgetTester tester, Finder finder) async {
  // Finish input/caret-driven layout before deciding how far to scroll.
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder.hitTestable());
  await tester.pumpAndSettle();
}

Future<void> _materialCreate(WidgetTester tester) async {
  await _tap(tester, find.text('Материалы'));
  await _tap(tester, find.text('Добавить'));
}

Future<void> _materialValues(
  WidgetTester tester, {
  String name = 'Масло',
  String unit = 'л',
}) async {
  await tester.enterText(_field('name'), name);
  await tester.enterText(_field('unit'), unit);
}

Future<void> _snapshot(WidgetTester tester, String name) async {
  if (_artifactDirectory.isEmpty) return;
  await tester.pump();
  await tester.runAsync(() async {
    final directory = Directory(_artifactDirectory);
    final absolute = Platform.isWindows
        ? RegExp(r'^[A-Za-z]:[\\/]').hasMatch(directory.path)
        : directory.path.startsWith('/');
    if (!absolute) {
      throw StateError('Artifact directory must be absolute and outside Git.');
    }
    await directory.create(recursive: true);
    var ancestor = Directory(await directory.resolveSymbolicLinks());
    while (true) {
      if (await FileSystemEntity.type(
            '${ancestor.path}/.git',
            followLinks: false,
          ) !=
          FileSystemEntityType.notFound) {
        throw StateError('Refusing artifacts inside a Git checkout.');
      }
      if (ancestor.parent.path == ancestor.path) break;
      ancestor = ancestor.parent;
    }
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(_captureKey),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${directory.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
    } finally {
      image.dispose();
    }
  });
}

void main() {
  testWidgets('Admin workspace exposes catalog navigation', (tester) async {
    final controller = _CatalogController();
    addTearDown(controller.dispose);
    await _host(tester, controller, workspace: true);
    await tester.tap(find.byTooltip('Справочники'));
    await tester.pumpAndSettle();
    expect(find.byType(ReferenceCatalogScreen), findsOneWidget);
    expect(find.text('Насос'), findsOneWidget);
  });

  for (final role in ['master', 'manager', 'worker']) {
    testWidgets('$role cannot enter catalog or expose admin editing controls', (
      tester,
    ) async {
      final controller = _CatalogController(role: role);
      addTearDown(controller.dispose);
      await _host(tester, controller, workspace: true);
      expect(find.byTooltip('Справочники'), findsNothing);
      await _host(tester, controller);
      expect(find.text('Справочники доступны администратору.'), findsOneWidget);
      expect(find.text('Добавить'), findsNothing);
      expect(find.text('Насос'), findsNothing);
      expect(controller.tickets, isEmpty);
      expect(controller.refreshCalls, 0);
    });
  }

  testWidgets(
    'Browse searches equipment area and materials without changing operational data',
    (tester) async {
      final controller = _CatalogController();
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await tester.enterText(find.byType(TextField), 'цЕх');
      await tester.pump();
      expect(find.text('Насос'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'отсутствует');
      await tester.pump();
      expect(find.text('Записей не найдено.'), findsOneWidget);
      await _tap(tester, find.text('Материалы'));
      expect(find.text('Уплотнение'), findsOneWidget);
      expect(controller.orders, isEmpty);
      expect(controller.outbox, isEmpty);
    },
  );

  testWidgets(
    'Malformed cached sections and duplicate/nonpositive IDs show an error without dropdown assertions',
    (tester) async {
      final controller = _CatalogController();
      addTearDown(controller.dispose);
      final ticket = controller.openReferenceEdit(
        ReferenceCollection.equipment,
        id: 9,
      );
      final equipment = Map<String, dynamic>.from(
        (controller.reference['equipment'] as List).single as Json,
      );
      controller.reference['equipment'] = 'invalid cached section';
      await _host(tester, controller);
      expect(
        find.text('Не удалось прочитать часть справочника. Обновите данные.'),
        findsOneWidget,
      );
      expect(find.text('Записей не найдено.'), findsNothing);
      expect(tester.takeException(), isNull);
      controller.reference['equipment'] = [
        equipment,
        {...equipment, 'name': 'Повтор'},
        {'id': -1},
        null,
      ];
      controller.reference['areas'] = [
        {'id': 1, 'name': 'Цех'},
        {'id': 1, 'name': 'Повтор участка'},
        {'id': 0, 'name': 'Некорректный'},
        {'id': true, 'name': 'Некорректный'},
        null,
      ];
      controller.notifyListeners();
      await tester.pump();
      expect(find.text('Насос'), findsOneWidget);
      expect(find.text('Повтор'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: ReferenceEditorScreen(controller: controller, ticket: ticket),
        ),
      );
      await tester.pumpAndSettle();
      final dropdown = tester.widget<DropdownButton<int>>(
        find.byType(DropdownButton<int>),
      );
      expect(dropdown.items!.map((item) => item.value).toList(), [1]);
      expect(
        find.textContaining('Не удалось прочитать список участков.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Material create validates required and server-length fields then sends normalized input once',
    (tester) async {
      final controller = _CatalogController();
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _materialCreate(tester);
      await _tap(tester, find.text('Сохранить'));
      expect(find.text('Заполните поле'), findsNWidgets(2));
      expect(controller.submitted, isEmpty);
      await _materialValues(tester, unit: 'x' * 31);
      await _tap(tester, find.text('Сохранить'));
      expect(find.text('Не более 30 символов'), findsOneWidget);
      expect(controller.submitted, isEmpty);
      await _materialValues(tester, name: '  Масло  ', unit: ' л ');
      await _tap(tester, find.text('Сохранить'));
      expect(controller.submitted, [
        {'name': 'Масло', 'unit': 'л'},
      ]);
      expect(find.text('Запись сохранена.'), findsOneWidget);
      expect(find.text('Сохранить'), findsNothing);
      expect(controller.refreshCalls, 1);
    },
  );

  testWidgets(
    'Equipment edit sends only changed fields and preserves arbitrary criticality',
    (tester) async {
      final controller = _CatalogController();
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _tap(tester, find.byTooltip('Изменить Насос'));
      expect(
        tester.widget<TextFormField>(_field('criticality')).controller!.text,
        'custom-important',
      );
      await tester.enterText(_field('name'), 'Насос 2');
      await _tap(tester, find.text('Сохранить'));
      expect(controller.submitted, [
        {'name': 'Насос 2'},
      ]);
      expect(controller.tickets.single.id, 9);
      expect(find.text('Сохранить'), findsNothing);
    },
  );

  testWidgets(
    'Legacy surrounding whitespace is unchanged until that exact field is edited',
    (tester) async {
      final controller = _CatalogController();
      (controller.reference['equipment'] as List).single['criticality'] =
          '  custom-important  ';
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _tap(tester, find.byTooltip('Изменить Насос'));
      final save = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Сохранить'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(save.onPressed, isNull);
      await tester.enterText(_field('name'), 'Другое название');
      await _tap(tester, find.text('Сохранить'));
      expect(controller.submitted, [
        {'name': 'Другое название'},
      ]);
    },
  );

  testWidgets(
    'Missing catalog record at click shows a scoped error without an unhandled callback',
    (tester) async {
      final controller = _CatalogController();
      addTearDown(controller.dispose);
      await _host(tester, controller);
      controller.failOpen = true;
      await _tap(tester, find.byTooltip('Изменить Насос'));
      expect(
        find.text(
          'Не удалось открыть запись. Обновите справочник и повторите.',
        ),
        findsOneWidget,
      );
      expect(find.byType(ReferenceEditorScreen), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Captured missing Area remains readable and untouched PATCH omits its ID',
    (tester) async {
      final controller = _CatalogController();
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _tap(tester, find.byTooltip('Изменить Насос'));
      controller.reference['areas'] = <Json>[];
      controller.notifyListeners();
      await tester.pump();
      expect(find.text('Участок #1'), findsOneWidget);
      await tester.enterText(_field('name'), 'Сохранённый насос');
      await _tap(tester, find.text('Сохранить'));
      expect(controller.submitted, [
        {'name': 'Сохранённый насос'},
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Equipment create uses read-only area picker and existing medium default',
    (tester) async {
      final controller = _CatalogController();
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _tap(tester, find.text('Добавить'));
      await tester.enterText(_field('name'), 'Двигатель');
      await tester.enterText(_field('inventory_number'), 'INV-12');
      await _tap(tester, find.byType(DropdownButtonFormField<int>));
      await _tap(tester, find.text('Склад').last);
      await tester.scrollUntilVisible(
        _field('type'),
        160,
        scrollable: _editorScroll,
      );
      await tester.enterText(_field('type'), 'Электрическое');
      await _tap(tester, find.text('Сохранить'));
      expect(controller.submitted.single, {
        'name': 'Двигатель',
        'inventory_number': 'INV-12',
        'area_id': 2,
        'type': 'Электрическое',
        'criticality': 'medium',
      });
      expect(find.text('Создать участок'), findsNothing);
    },
  );

  testWidgets(
    'Known rejection preserves editable fields and shows collision message',
    (tester) async {
      final controller = _CatalogController()
        ..mutationResult = const ReferenceMutationResult(
          ReferenceMutationStatus.rejected,
          error: ReferenceEditError(
            'Запись с таким значением уже существует',
            statusCode: 409,
          ),
        );
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _materialCreate(tester);
      await _materialValues(tester);
      await _tap(tester, find.text('Сохранить'));
      expect(
        find.text('Запись с таким значением уже существует'),
        findsOneWidget,
      );
      expect(
        tester.widget<TextFormField>(_field('name')).controller!.text,
        'Масло',
      );
      expect(_readOnly(tester, 'name'), isFalse);
      expect(find.text('Сохранить'), findsOneWidget);
      expect(controller.refreshCalls, 0);
    },
  );

  testWidgets('Busy send prevents duplicate clicks, input edits and exit', (
    tester,
  ) async {
    final controller = _CatalogController()
      ..delayedWrite = Completer<ReferenceMutationResult>();
    addTearDown(controller.dispose);
    await _host(tester, controller);
    await _materialCreate(tester);
    await _materialValues(tester);
    await tester.tap(find.text('Сохранить'));
    await tester.pump();
    final save = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Сохранить'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(save.onPressed, isNull);
    expect(_readOnly(tester, 'name'), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byType(ReferenceEditorScreen), findsOneWidget);
    expect(controller.submitted.length, 1);
    controller.delayedWrite!.complete(controller.mutationResult);
    await tester.pumpAndSettle();
    expect(find.text('Запись сохранена.'), findsOneWidget);
  });

  testWidgets('Offline and shared sync/recovery lanes block catalog writes', (
    tester,
  ) async {
    final controller = _CatalogController();
    addTearDown(controller.dispose);
    await _host(tester, controller);
    await _materialCreate(tester);
    await _materialValues(tester);
    for (final lane in ['offline', 'sync', 'recovery', 'saving']) {
      controller.offline = lane == 'offline';
      controller.syncBusy = lane == 'sync';
      controller.recoveryBusy = lane == 'recovery';
      controller.saving = lane == 'saving';
      controller.notifyListeners();
      await tester.pump();
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Сохранить'),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull, reason: lane);
    }
    expect(controller.submitted, isEmpty);
    expect(controller.outbox, isEmpty);
  });

  testWidgets(
    'Unknown write stays frozen across GET and reopen; exit explains memory-only retention',
    (tester) async {
      final controller = _CatalogController()
        ..mutationResult = const ReferenceMutationResult(
          ReferenceMutationStatus.uncertain,
          mayHaveSucceeded: true,
        );
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _materialCreate(tester);
      await _materialValues(tester);
      await _tap(tester, find.text('Сохранить'));
      expect(find.text('Сохранить'), findsNothing);
      expect(_readOnly(tester, 'name'), isTrue);
      await _tap(tester, find.text('Обновить список для просмотра'));
      expect(controller.refreshCalls, 1);
      expect(find.text('Сохранить'), findsNothing);
      await _tap(tester, find.text('Закрыть'));
      expect(find.text('Закрыть неподтверждённый ввод?'), findsOneWidget);
      expect(
        find.textContaining('После закрытия приложения он может быть потерян'),
        findsOneWidget,
      );
      await _tap(tester, find.widgetWithText(FilledButton, 'Закрыть'));
      await _tap(tester, find.text('Посмотреть неподтверждённый ввод'));
      expect(
        tester.widget<TextFormField>(_field('name')).controller!.text,
        'Масло',
      );
      expect(find.text('Сохранить'), findsNothing);
      expect(controller.tickets.length, 1);
      expect(controller.submitted.length, 1);
    },
  );

  testWidgets(
    'Unknown PATCH reopens against original captured fields after polling replaces catalog',
    (tester) async {
      final controller = _CatalogController()
        ..mutationResult = const ReferenceMutationResult(
          ReferenceMutationStatus.uncertain,
          mayHaveSucceeded: true,
        );
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _tap(tester, find.byTooltip('Изменить Насос'));
      await tester.enterText(_field('name'), 'Мой насос');
      await _tap(tester, find.text('Сохранить'));
      await tester.scrollUntilVisible(
        find.text('Закрыть'),
        200,
        scrollable: _editorScroll,
      );
      await _tap(tester, find.text('Закрыть'));
      await _tap(tester, find.widgetWithText(FilledButton, 'Закрыть'));
      controller.reference['equipment'] = [
        {
          'id': 9,
          'name': 'Чужой насос',
          'inventory_number': 'CHANGED',
          'area_id': 2,
          'type': 'Другой тип',
          'criticality': 'high',
        },
      ];
      controller.notifyListeners();
      await tester.pump();
      await _tap(tester, find.text('Посмотреть ввод'));
      expect(
        tester.widget<TextFormField>(_field('name')).controller!.text,
        'Мой насос',
      );
      expect(
        tester
            .widget<TextFormField>(_field('inventory_number'))
            .controller!
            .text,
        'INV-9',
      );
      await tester.scrollUntilVisible(
        _field('criticality'),
        200,
        scrollable: _editorScroll,
      );
      expect(
        tester.widget<TextFormField>(_field('criticality')).controller!.text,
        'custom-important',
      );
      expect(controller.submitted, [
        {'name': 'Мой насос'},
      ]);
    },
  );

  testWidgets(
    'ACK remains saved when subsequent refresh fails and refresh retry never resubmits',
    (tester) async {
      final controller = _CatalogController()
        ..refreshResult = const ReferenceRefreshResult(
          ReferenceRefreshStatus.failed,
          error: ReferenceEditError('Не удалось обновить список.'),
        );
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _materialCreate(tester);
      await _materialValues(tester);
      await _tap(tester, find.text('Сохранить'));
      expect(
        find.text('Запись сохранена. Обновить список пока не удалось.'),
        findsOneWidget,
      );
      expect(find.text('Не удалось обновить список.'), findsOneWidget);
      expect(find.text('Сохранить'), findsNothing);
      await _tap(tester, find.text('Обновить список'));
      expect(controller.refreshCalls, 2);
      expect(controller.submitted.length, 1);
    },
  );

  testWidgets(
    'Acknowledgement appears while independent refresh is still in flight',
    (tester) async {
      final controller = _CatalogController()
        ..delayedRefresh = Completer<ReferenceRefreshResult>();
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _materialCreate(tester);
      await _materialValues(tester);
      await tester.tap(find.text('Сохранить'));
      await tester.pump();
      expect(find.text('Запись сохранена.'), findsOneWidget);
      expect(find.text('Сохранить'), findsNothing);
      expect(controller.submitted.length, 1);
      controller.delayedRefresh!.complete(controller.refreshResult);
      await tester.pumpAndSettle();
      expect(controller.refreshCalls, 1);
    },
  );

  testWidgets(
    'Dirty Back confirmation retains input on Stay and requires explicit discard',
    (tester) async {
      final controller = _CatalogController();
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _materialCreate(tester);
      await _materialValues(tester);
      await _tap(tester, find.text('Отмена'));
      expect(find.text('Закрыть без сохранения?'), findsOneWidget);
      await _tap(tester, find.text('Остаться'));
      expect(
        tester.widget<TextFormField>(_field('name')).controller!.text,
        'Масло',
      );
      await _tap(tester, find.text('Отмена'));
      await _tap(tester, find.widgetWithText(FilledButton, 'Закрыть'));
      expect(find.byType(ReferenceEditorScreen), findsNothing);
      expect(controller.submitted, isEmpty);
    },
  );

  for (final kind in ['token', 'same-token', 'api', 'owner', 'role']) {
    testWidgets(
      '$kind boundary closes protected page, editor and dirty confirmation',
      (tester) async {
        final controller = _CatalogController();
        addTearDown(controller.dispose);
        await _host(tester, controller);
        await _materialCreate(tester);
        await _materialValues(tester, name: 'Приватный ввод');
        await _tap(tester, find.text('Отмена'));
        controller.boundary(kind);
        await tester.pumpAndSettle();
        expect(find.byType(ReferenceCatalogScreen), findsNothing);
        expect(find.byType(ReferenceEditorScreen), findsNothing);
        expect(find.text('Закрыть без сохранения?'), findsNothing);
        expect(find.text('Приватный ввод'), findsNothing);
        expect(find.text('Открыть каталог'), findsOneWidget);
        expect(controller.submitted, isEmpty);
      },
    );
  }

  testWidgets(
    'Late old-session ACK cannot close new UI, show success or trigger refresh',
    (tester) async {
      final controller = _CatalogController()
        ..delayedWrite = Completer<ReferenceMutationResult>();
      addTearDown(controller.dispose);
      await _host(tester, controller);
      await _materialCreate(tester);
      await _materialValues(tester);
      await tester.tap(find.text('Сохранить'));
      await tester.pump();
      controller.boundary('owner');
      await tester.pumpAndSettle();
      controller.delayedWrite!.complete(controller.mutationResult);
      await tester.pumpAndSettle();
      expect(find.text('Запись сохранена.'), findsNothing);
      expect(find.byType(ReferenceEditorScreen), findsNothing);
      expect(controller.refreshCalls, 0);
      expect(controller.submitted.length, 1);
    },
  );

  testWidgets(
    '360px catalog and editor keep controls, errors and content usable without overflow',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 800);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      final controller = _CatalogController()
        ..mutationResult = const ReferenceMutationResult(
          ReferenceMutationStatus.rejected,
          error: ReferenceEditError(
            'Не удалось сохранить. Проверьте введённые значения.',
            statusCode: 422,
          ),
        );
      addTearDown(controller.dispose);
      await _host(tester, controller);
      expect(find.text('Насос'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _snapshot(tester, 'reference-catalog-360');
      await _tap(tester, find.byTooltip('Изменить Насос'));
      await tester.enterText(_field('name'), 'Насос с обновлённым названием');
      await _tap(tester, find.text('Сохранить'));
      await tester.scrollUntilVisible(
        find.text('Не удалось сохранить. Проверьте введённые значения.'),
        -200,
        scrollable: _editorScroll,
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Не удалось сохранить. Проверьте введённые значения.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _snapshot(tester, 'reference-editor-360');
    },
  );
}
