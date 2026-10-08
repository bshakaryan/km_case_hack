// Opt-in two-process acceptance using real Android sqflite and real HTTP.
// Build once with a fresh DRAFT_RUN; drive the same APK with
// --keep-app-running, force-stop the app, then drive it again. Do not uninstall.
// Compressed photo bytes are seeded; camera/gallery are deliberately not tested.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/form_draft.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/local_store_io.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/screens/completion_screen.dart';
import 'package:naryad_ai/screens/create_order_screen.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:timezone/data/latest.dart' as tzdata;

const _run = String.fromEnvironment('DRAFT_RUN');
const _baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8017',
);
const _work =
    'Проверка черновика: крепление восстановлено, контрольный запуск.';
const _rawQuantity = '1,';

// This records requests while forwarding every byte to a real http.Client.
// No response, authentication or network success is simulated.
class _Requests {
  final mutations = <String>[];
  NaryadApi api(String url) => NaryadApi(url, client: _RecordingClient(this));
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.requests);
  final _Requests requests;
  final http.Client inner = http.Client();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.method != 'GET' && request.url.path.contains('/orders')) {
      requests.mutations.add('${request.method} ${request.url.path}');
    }
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  testWidgets(
    'Android drafts survive process restart without resubmission',
    (tester) async {
      expect(RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(_run), isTrue);
      final preferences = await SharedPreferences.getInstance();
      final marker = 'naryad.integration.drafts.$_run';
      final saved = preferences.getString(marker);
      final directory =
          '${(await getApplicationDocumentsDirectory()).path}/draft_test_$_run';
      final store = SqfliteLocalStore(directoryPath: directory);
      final requests = _Requests();
      final master = AppController(
        api: requests.api(_baseUrl),
        apiFactory: requests.api,
        localStore: store,
      );
      final worker = AppController(
        api: requests.api(_baseUrl),
        apiFactory: requests.api,
        localStore: store,
      );
      try {
        await store.open();
        await master.login(_baseUrl, 'master', '1234');
        await worker.login(_baseUrl, 'worker2', '1234');
        expect(master.user?.isMaster, isTrue);
        expect(worker.user?.isWorker, isTrue);
        if (saved == null) {
          for (final version in [1, 2, 3]) {
            await _verifyLegacyUpgrade('$directory-v$version', version);
          }
          final equipment = _maps(master.reference['equipment']).first;
          final material = _maps(worker.reference['materials']).first;
          final fault = _maps(worker.reference['fault_codes']).first;
          expect(
            worker.orders.where((order) => order.status == 'in_progress'),
            isEmpty,
            reason: 'Use a disposable demo database with free worker2.',
          );
          await _mount(
            tester,
            CreateOrderScreen(
              controller: master,
              equipmentId: equipment['id'] as int,
              assigneeId: worker.user!.id,
            ),
          );
          await _enter(tester, 'Кратко о задаче *', 'Черновик $_run');
          await _enter(
            tester,
            'Проблема и необходимые работы *',
            'Синтетическая проверка сохранения. Производственных работ нет.',
          );
          await _until(
            tester,
            () => find
                .text('Черновик сохранён на устройстве')
                .evaluate()
                .isNotEmpty,
            'awaited create UI autosave',
          );
          await _unmount(tester);
          final create = await master.openFormDraft(FormDraftKind.create);
          final originalCreate = (await create.read())!;
          expect(originalCreate.data['title'], 'Черновик $_run');
          expect(await store.outbox(), isEmpty);
          final photo = prepareOrderPhoto(_picture());
          final partial = await master.api.createOrder(
            _orderData(equipment, worker.user!.id, 'Частичная выдача $_run'),
          );
          await master.api.uploadPhoto(
            partial.id,
            photo,
            'confirmed-before.jpg',
            'before',
            expectedVersion: partial.version,
          );
          final confirmed = await master.api.order(partial.id);
          final createData = {
            ...originalCreate.data,
            'created': confirmed.toJson(),
            'photos': [
              {
                'bytes': base64Encode(photo),
                'filename': 'confirmed-before.jpg',
                'state': 'uploaded',
                'queued': false,
                'error': null,
              },
            ],
          };
          await create.save(
            originalCreate.copyWith(
              data: createData,
              basis: OrderWriteBasis(expectedVersion: confirmed.version),
            ),
          );
          var order = await master.api.createOrder(
            _orderData(equipment, worker.user!.id, 'Отчёт $_run'),
          );
          order = await worker.api.transition(
            order.id,
            'accept',
            expectedVersion: order.version,
          );
          order = await worker.api.transition(
            order.id,
            'start',
            expectedVersion: order.version,
          );
          await worker.refresh(silent: true);
          order = await worker.api.order(order.id);
          await _mount(
            tester,
            CompletionScreen(controller: worker, order: order),
          );
          await _enter(tester, 'Что сделано', _work);
          await _tap(tester, find.text('Найти и добавить материал'));
          await _enter(
            tester,
            'Поиск по справочнику',
            material['name'] as String,
          );
          await _tap(
            tester,
            find.widgetWithText(ListTile, material['name'] as String),
          );
          await _enter(tester, 'Количество', _rawQuantity);
          // The status banner is above this lazy ListView's material fields.
          // Return to it before checking the storage acknowledgement.
          final formScroll = find
              .descendant(
                of: find.byType(ListView).first,
                matching: find.byType(Scrollable),
              )
              .first;
          tester.state<ScrollableState>(formScroll).position.jumpTo(0);
          await tester.pump(const Duration(milliseconds: 150));
          await _until(
            tester,
            () => find
                .text('Черновик сохранён на устройстве')
                .evaluate()
                .isNotEmpty,
            'awaited completion UI autosave',
          );
          await _unmount(tester);
          final completion = await worker.openFormDraft(
            FormDraftKind.completion,
            orderId: order.id,
          );
          final originalCompletion = (await completion.read())!;
          expect(originalCompletion.data['work'], _work);
          expect(
            _maps(originalCompletion.data['materials']).single['quantity'],
            _rawQuantity,
          );
          final completionData = {
            ...originalCompletion.data,
            'fault_id': fault['id'],
            'photos': [
              {
                'bytes': base64Encode(photo),
                'filename': 'unsubmitted-after.jpg',
                'uploading': false,
                'uploaded': false,
                'queued': false,
                'uncertain': false,
                'error': null,
              },
            ],
          };
          await completion.save(
            originalCompletion.copyWith(data: completionData),
          );
          final uncertainOrder = await master.api.createOrder(
            _orderData(
              equipment,
              worker.user!.id,
              'Неизвестная отправка $_run',
            ),
          );
          final uncertain = await worker.openFormDraft(
            FormDraftKind.completion,
            orderId: uncertainOrder.id,
          );
          await uncertain.save(
            FormDraft(
              kind: FormDraftKind.completion,
              orderId: uncertainOrder.id,
              basis: OrderWriteBasis(expectedVersion: uncertainOrder.version),
              state: FormDraftState.submitting,
              data: {
                ...completionData,
                'operation': 'complete',
                'work': 'Неизвестный результат $_run',
              },
            ),
          );
          await store.close();
          await store.open();
          expect((await completion.read())!.data, completionData);
          expect((await create.read())!.data, createData);
          expect((await uncertain.read())!.state, FormDraftState.uncertain);
          expect(await store.outbox(), isEmpty);
          await preferences.setString(
            marker,
            jsonEncode({
              'order': order.toJson(),
              'uncertain_order': uncertainOrder.toJson(),
              'partial_id': confirmed.id,
              'owner_id': worker.user!.id,
              'create_data': createData,
              'completion_data': completionData,
              'photo_hash': base64Encode(photo),
            }),
          );
          _step('PHASE_A_PASS', {
            'run': _run,
            'orderId': order.id,
            'partialId': confirmed.id,
            'migrationVersions': [1, 2, 3],
            'seededMedia': true,
            'realHttp': true,
          });
        } else {
          final metadata = jsonDecode(saved) as Json;
          final order = await worker.api.order(
            (metadata['order'] as Map)['id'] as int,
          );
          final uncertainOrder = await worker.api.order(
            (metadata['uncertain_order'] as Map)['id'] as int,
          );
          expect(worker.user!.id, metadata['owner_id']);
          final completion = await worker.openFormDraft(
            FormDraftKind.completion,
            orderId: order.id,
          );
          final restored = (await completion.read())!;
          expect(restored.data, metadata['completion_data']);
          expect(
            restored.basis!.expectedVersion,
            (metadata['order'] as Map)['version'],
          );
          final media = _maps(restored.data['photos']).single;
          expect(media['bytes'], metadata['photo_hash']);
          expect(
            img.decodeJpg(base64Decode(media['bytes'] as String)),
            isNotNull,
          );
          await expectLater(
            completion.save(
              restored.copyWith(
                basis: OrderWriteBasis(expectedVersion: order.version! + 1),
              ),
            ),
            throwsA(isA<ApiException>()),
            reason: 'A newly fetched version cannot rebase the disk draft.',
          );
          final beforeUi = requests.mutations.length;
          await _mount(
            tester,
            CompletionScreen(controller: worker, order: order),
          );
          await _reveal(tester, _field('Что сделано'));
          expect(_text(tester, 'Что сделано'), _work);
          await _reveal(tester, _field('Количество'));
          expect(_text(tester, 'Количество'), _rawQuantity);
          await _reveal(tester, find.text('Фото не отправлено'));
          expect(find.text('Фото не отправлено'), findsOneWidget);
          await _unmount(tester);
          expect(requests.mutations.length, beforeUi);
          // A real second actor changes the server version. The refreshed card
          // must restore the text, but leave the original draft basis frozen.
          await master.api.uploadPhoto(
            order.id,
            base64Decode(metadata['photo_hash'] as String),
            'concurrent-master-before.jpg',
            'before',
            expectedVersion: order.version,
          );
          final changed = await worker.api.order(order.id);
          expect(changed.version, greaterThan(order.version!));
          final afterFixtureChange = requests.mutations.length;
          await _mount(
            tester,
            CompletionScreen(controller: worker, order: changed),
          );
          await _reveal(tester, _field('Что сделано'));
          expect(_text(tester, 'Что сделано'), _work);
          await _reveal(
            tester,
            find.widgetWithText(FilledButton, 'Отправить на приёмку'),
          );
          expect(
            tester
                .widget<FilledButton>(
                  find.widgetWithText(FilledButton, 'Отправить на приёмку'),
                )
                .onPressed,
            isNull,
          );
          await _unmount(tester);
          final unknown = await worker.openFormDraft(
            FormDraftKind.completion,
            orderId: uncertainOrder.id,
          );
          final unknownDraft = (await unknown.read())!;
          expect(unknownDraft.state, FormDraftState.uncertain);
          await expectLater(
            unknown.save(unknownDraft.copyWith(state: FormDraftState.editing)),
            throwsA(isA<ApiException>()),
          );
          await _mount(
            tester,
            CompletionScreen(controller: worker, order: uncertainOrder),
          );
          await _reveal(tester, _field('Что сделано'));
          expect(_text(tester, 'Что сделано'), 'Неизвестный результат $_run');
          expect(
            tester.widget<TextField>(_field('Что сделано')).enabled,
            isFalse,
          );
          expect(find.text('Отправить на приёмку'), findsNothing);
          await _tap(
            tester,
            find.widgetWithText(FilledButton, 'Проверить отправку'),
          );
          await _until(
            tester,
            () => find.text('Проверить отправку').evaluate().isNotEmpty,
            'real GET after unknown submission',
          );
          expect(find.text('Отправить на приёмку'), findsNothing);
          await _unmount(tester);
          final create = await master.openFormDraft(FormDraftKind.create);
          final partialDraft = (await create.read())!;
          expect(partialDraft.data, metadata['create_data']);
          expect(
            (partialDraft.data['created'] as Map)['id'],
            metadata['partial_id'],
          );
          expect(
            _maps(partialDraft.data['photos']).single['state'],
            'uploaded',
          );
          await _mount(tester, CreateOrderScreen(controller: master));
          expect(find.text('Наряд выдан'), findsOneWidget);
          expect(find.text('Фото подтверждено сервером'), findsOneWidget);
          expect(find.text('Повторить неотправленные фото'), findsNothing);
          expect(
            find.widgetWithText(FilledButton, 'Выдать наряд'),
            findsNothing,
          );
          await _unmount(tester);
          expect(
            requests.mutations.length,
            afterFixtureChange,
            reason: 'Restore/check UI must not recreate, reupload or resubmit.',
          );
          expect(await store.outbox(), isEmpty);
          expect(
            await (await master.openFormDraft(
              FormDraftKind.completion,
              orderId: order.id,
            )).read(),
            isNull,
            reason: 'The genuinely authenticated other account sees no draft.',
          );
          final otherApi = AppController(
            api: NaryadApi('$_baseUrl/isolated'),
            localStore: store,
          )..user = worker.user;
          try {
            expect(
              await (await otherApi.openFormDraft(
                FormDraftKind.completion,
                orderId: order.id,
              )).read(),
              isNull,
              reason: 'Local namespace check only; no second API is simulated.',
            );
          } finally {
            otherApi.dispose();
          }
          final serverPartial = await master.api.order(
            metadata['partial_id'] as int,
          );
          expect(_maps(serverPartial.data['photos']), hasLength(1));
          final serverReport = await worker.api.order(order.id);
          expect(serverReport.status, 'in_progress');
          expect(serverReport.submissionAttempts, isEmpty);
          await preferences.remove(marker);
          _step('PASS', {
            'run': _run,
            'forceStopRestored': true,
            'nativeDisk': true,
            'duplicateWrites': 0,
            'rawQuantity': _rawQuantity,
            'ownerApiIsolated': true,
            'seededMedia': true,
          });
        }
      } finally {
        await _unmount(tester);
        // Leave sessions/drafts installed between phases; no test DB is removed.
        master.dispose();
        worker.dispose();
        await store.close();
      }
    },
    skip: _run.isEmpty,
    timeout: const Timeout(Duration(minutes: 7)),
  );
}

Json _orderData(Json equipment, int owner, String title) => {
  'title': title,
  'description':
      'Синтетическая приёмка Android. Производственные работы не выполняются.',
  'work_type': 'unplanned',
  'area_id': equipment['area_id'],
  'equipment_id': equipment['id'],
  'assignee_id': owner,
  'priority': 'normal',
  'deadline': DateTime.now()
      .toUtc()
      .add(const Duration(hours: 2))
      .toIso8601String(),
  'normal_hours': 2,
  'comment': 'Disposable integration fixture $_run',
};

Uint8List _picture() {
  final image = img.Image(width: 160, height: 120);
  img.fill(image, color: img.ColorRgb8(40, 120, 75));
  return Uint8List.fromList(img.encodePng(image));
}

Future<void> _verifyLegacyUpgrade(String path, int version) async {
  await Directory(path).create(recursive: true);
  final bytes = _picture();
  final photoPath = '$path/legacy.photo';
  await File(photoPath).writeAsBytes(bytes, flush: true);
  final db = await openDatabase(
    '$path/local_store.db',
    version: version,
    onCreate: (db, _) async {
      await db.execute(
        'CREATE TABLE snapshot (key TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at INTEGER NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE outbox (command_id TEXT PRIMARY KEY, kind TEXT NOT NULL, created_at INTEGER NOT NULL, owner_id INTEGER, ${version >= 2 ? "server_url TEXT," : ""} order_id INTEGER, local_ref TEXT, ${version >= 3 ? "expected_version INTEGER, previous_command_id TEXT," : ""} payload TEXT NOT NULL, photo_path TEXT, photo_filename TEXT, photo_kind TEXT, attempts INTEGER NOT NULL, state TEXT NOT NULL, response_status INTEGER, response TEXT, last_error TEXT)',
      );
      await db.execute(
        'CREATE INDEX ix_outbox_state ON outbox (state, created_at)',
      );
      await db.execute(
        'CREATE TABLE id_map (local_ref TEXT PRIMARY KEY, server_id INTEGER NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE photo_cache (url TEXT PRIMARY KEY, path TEXT NOT NULL, size INTEGER NOT NULL, last_used_at INTEGER NOT NULL)',
      );
    },
  );
  await db.insert('snapshot', {
    'key': 'profile',
    'payload': jsonEncode({
      'id': 6,
      'role': 'worker',
      'name': 'Legacy synthetic',
    }),
    'updated_at': 1,
  });
  await db.insert('outbox', {
    'command_id': 'legacy-$_run',
    'kind': OutboxKind.uploadPhoto,
    'created_at': 1,
    'owner_id': 6,
    if (version >= 2) 'server_url': NaryadApi.normalizeBaseUrl(_baseUrl),
    if (version >= 3) 'expected_version': 2,
    'order_id': 9,
    'payload': jsonEncode({'work_done': 'Preserved legacy input'}),
    'photo_path': photoPath,
    'photo_filename': 'legacy.png',
    'photo_kind': 'after',
    'attempts': 0,
    'state': OutboxState.running,
  });
  await db.insert('id_map', {'local_ref': 'legacy-local', 'server_id': 9});
  await db.insert('photo_cache', {
    'url': 'legacy-photo',
    'path': photoPath,
    'size': bytes.length,
    'last_used_at': 1,
  });
  await db.close();
  final upgraded = SqfliteLocalStore(directoryPath: path);
  try {
    await upgraded.open();
    final command = (await upgraded.outbox()).single;
    expect(command.payload['work_done'], 'Preserved legacy input');
    expect(
      command.state,
      version < 3 ? OutboxState.conflict : OutboxState.pending,
    );
    expect(command.expectedVersion, version < 3 ? null : 2);
    expect(
      command.serverUrl,
      version == 1 ? null : NaryadApi.normalizeBaseUrl(_baseUrl),
    );
    expect(await upgraded.outboxPhoto(command.commandId), orderedEquals(bytes));
    expect((await upgraded.getSnapshot('profile'))!.data, {
      'id': 6,
      'role': 'worker',
      'name': 'Legacy synthetic',
    });
    expect(await upgraded.serverId('legacy-local'), 9);
    expect(await upgraded.getPhoto('legacy-photo'), orderedEquals(bytes));
    final draft = FormDraft(
      kind: FormDraftKind.completion,
      orderId: 9,
      basis: const OrderWriteBasis(expectedVersion: 2),
      data: {
        'work': 'Migrated draft',
        'raw_quantity': _rawQuantity,
        'photo': base64Encode(bytes),
      },
    );
    await upgraded.putFormDraft('migration-draft', draft.toJson());
    await upgraded.close();
    await upgraded.open();
    expect(await upgraded.getFormDraft('migration-draft'), draft.toJson());
    expect(
      (await upgraded.outbox()).single.state,
      version < 3 ? OutboxState.conflict : OutboxState.pending,
    );
    _step('STORE_UPGRADE_PASS', {
      'from': version,
      'to': 4,
      'filledDataPreserved': true,
    });
  } finally {
    await upgraded.close();
  }
}

Future<void> _mount(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: screen,
    ),
  );
  await _until(
    tester,
    () =>
        find.text('Черновик сохранён на устройстве').evaluate().isNotEmpty ||
        find.text('Черновик ещё не сохранён').evaluate().isNotEmpty,
    'native draft form initialized',
  );
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
}

List<Json> _maps(dynamic rows) =>
    (rows as List).map((row) => Map<String, dynamic>.from(row as Map)).toList();
Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);
String _text(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!.text;

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      250,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 35,
      duration: const Duration(milliseconds: 100),
    );
  }
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 150));
}

Future<void> _enter(WidgetTester tester, String label, String text) async {
  await _reveal(tester, _field(label));
  await tester.enterText(_field(label), text);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _reveal(tester, finder);
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String description,
) async {
  final timer = Stopwatch()..start();
  while (!ready()) {
    if (timer.elapsed > const Duration(seconds: 35)) {
      fail('Timed out: $description');
    }
    await tester.pump(const Duration(milliseconds: 150));
    expect(tester.takeException(), isNull, reason: description);
  }
}

void _step(String step, Json values) {
  // No tokens, PINs or HTTP headers are emitted.
  // ignore: avoid_print
  print('DRAFT_STEP $step ${jsonEncode(values)}');
}
