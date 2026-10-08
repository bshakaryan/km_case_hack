// Opt-in, two-process acceptance on a disposable API and Android Emulator.
// Build once with a fresh OFFLINE_RUN and API_BASE_URL; drive the same APK twice
// with --keep-app-running so SDK teardown does not uninstall and erase storage.
// A: WAIT_API_OFF -> stop only the test API -> PHASE_A_PASS and SDK exit 0.
// Force-stop only the emulator app. B: WAIT_API_ON -> restart the same API/DB.
// This uses real HTTP, Android secure storage, sqflite and disk media. No mocks.
// Server unavailability is tested; camera, OS flight mode and push are not.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:integration_test/integration_test.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/local_store_io.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/main.dart';
import 'package:naryad_ai/screens/create_order_screen.dart'
    show prepareOrderPhoto;
import 'package:naryad_ai/screens/order_detail_screen.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../test/support/ai_review_wait.dart';

const _run = String.fromEnvironment('OFFLINE_RUN');
const _baseUrl = String.fromEnvironment(
  'API_BASE_URL',
  defaultValue: 'http://10.0.2.2:8017',
);
const _reportText =
    'Офлайн-проверка: крепление восстановлено, выполнен контрольный запуск.';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'disk queue survives Android process restart and synchronizes once',
    (tester) async {
      expect(
        RegExp(r'^[A-Za-z0-9_-]{1,48}$').hasMatch(_run),
        isTrue,
        reason: 'OFFLINE_RUN must be a fresh safe identifier.',
      );
      final preferences = await SharedPreferences.getInstance();
      final marker = 'naryad.integration.offline.$_run';
      final saved = preferences.getString(marker);
      final directory =
          '${(await getApplicationDocumentsDirectory()).path}/offline_test_$_run';
      final store = SqfliteLocalStore(directoryPath: directory);
      final controller = AppController(
        api: NaryadApi(_baseUrl),
        storage: const FlutterSecureStorage(),
        localStore: store,
      );
      final master = NaryadApi(_baseUrl);
      var preserveSession = false;
      try {
        if (saved == null) {
          await _verifyLegacyUpgrade('$directory-legacy');
          await _verifyLegacyUpgrade('$directory-legacy-v2', fromVersion: 2);
          await const FlutterSecureStorage().delete(
            key: 'naryad.native.session.v1',
          );
          await tester.pumpWidget(NaryadApp(controller: controller));
          await _until(
            tester,
            () => _field('Логин').evaluate().isNotEmpty,
            'login screen',
          );
          await _enter(tester, _field('Логин'), 'worker2');
          await _enter(tester, _field('ПИН-код'), '1234');
          await _tap(tester, find.widgetWithText(FilledButton, 'Войти'));
          await _until(
            tester,
            () => controller.user != null && !controller.loading,
            'real native login',
            diagnostics: () => controller.error,
          );
          await master.login('master', '1234');
          final reference = await master.reference();
          final equipment = _maps(reference['equipment']).first;
          final fault = _maps(reference['fault_codes']).first;
          final material = _maps(reference['materials']).first;
          expect(
            controller.orders.where((order) => order.status == 'in_progress'),
            isEmpty,
            reason: 'Use a new demo database with free worker2.',
          );
          final order = await master.createOrder({
            'title': 'Офлайн $_run',
            'description': 'Синтетический тест сохранения очереди. Производственные работы не выполняются.',
            'work_type': 'unplanned',
            'area_id': equipment['area_id'],
            'equipment_id': equipment['id'],
            'assignee_id': controller.user!.id,
            'priority': 'normal',
            'deadline': DateTime.now()
                .toUtc()
                .add(const Duration(hours: 2))
                .toIso8601String(),
            'normal_hours': 2,
            'comment': 'Автономная проверка на эмуляторе.',
          });
          // This auxiliary account only creates the fixture. Its cleanup must
          // not turn an unknown logout outcome into an offline-queue failure.
          try {
            await master.logout();
          } on ApiException {
            _step('MASTER_CLEANUP_UNCONFIRMED', {'run': _run});
          }
          master.token = null;
          master.close();
          await controller.refresh(silent: true);
          await controller.uploadPhoto(
            order.id,
            prepareOrderPhoto(_picture(150)),
            'offline-before.jpg',
            'before',
          );
          final detail = await controller.loadOrder(order.id);
          final beforeId = (_maps(detail.data['photos']).single['id'] as num)
              .toInt();
          final cachedJpeg = await controller.photoBytes(beforeId);
          expect(img.decodeJpg(cachedJpeg), isNotNull);
          _step('WAIT_API_OFF', {'orderId': order.id, 'run': _run});
          await _until(
            tester,
            () => controller.offline,
            'test API stopped',
            timeout: const Duration(minutes: 2),
            tick: () async {
              try {
                await controller.refresh(silent: true);
              } on ApiException {
                /* Actual unavailable socket. */
              }
            },
          );
          await tester.pumpWidget(
            MaterialApp(
              home: OrderDetailScreen(
                controller: controller,
                orderId: order.id,
              ),
            ),
          );
          await _tap(
            tester,
            find.widgetWithText(FilledButton, 'Принять задание'),
          );
          await _until(
            tester,
            () => find
                .text('Действие сохранено на устройстве. Ожидает отправки.')
                .evaluate()
                .isNotEmpty,
            'durable offline acceptance',
          );
          expect(
            find.text('Действие сохранено на устройстве. Ожидает отправки.'),
            findsOneWidget,
          );
          expect(find.text('Сервер подтвердил: Принят в работу'), findsNothing);
          await _tap(
            tester,
            find.widgetWithText(FilledButton, 'Начать исполнение'),
          );
          await _until(
            tester,
            () => find
                .widgetWithText(FilledButton, 'Исполнено · заполнить отчёт')
                .evaluate()
                .isNotEmpty,
            'durable offline work start',
          );
          await controller.uploadPhoto(
            order.id,
            prepareOrderPhoto(_picture(65)),
            'offline-after.jpg',
            'after',
          );
          await _tap(
            tester,
            find.widgetWithText(FilledButton, 'Исполнено · заполнить отчёт'),
          );
          await _enter(tester, _field('Что сделано'), _reportText);
          await _tap(tester, find.byType(DropdownButtonFormField<int>));
          await tester.pump(const Duration(milliseconds: 300));
          await _tap(
            tester,
            find.text('${fault['code']} · ${fault['name']}').last,
          );
          await _tap(tester, find.text('Найти и добавить материал'));
          await _enter(
            tester,
            _field('Поиск по справочнику'),
            material['name'] as String,
          );
          await _tap(
            tester,
            find.widgetWithText(ListTile, material['name'] as String),
          );
          await _enter(tester, _field('Количество'), '2');
          await _tap(tester, find.text('Отправить на приёмку'));
          await _until(
            tester,
            () => find
                .text('Отчёт сохранён на устройстве. Ожидает отправки.')
                .evaluate()
                .isNotEmpty,
            'queued report confirmation',
          );
          expect(controller.isOrderPending(order.id), isTrue);
          final queued = await store.outbox();
          expect(queued.map((command) => command.kind).toList(), [
            OutboxKind.transition,
            OutboxKind.transition,
            OutboxKind.uploadPhoto,
            OutboxKind.complete,
          ]);
          expect(
            queued.map((command) => command.commandId).toSet(),
            hasLength(4),
          );
          expect(
            queued.every(
              (command) =>
                  command.state == OutboxState.pending &&
                  command.ownerId == controller.user!.id &&
                  command.serverUrl == controller.api.baseUrl,
            ),
            isTrue,
          );
          final photo = queued.singleWhere(
            (command) => command.kind == OutboxKind.uploadPhoto,
          );
          expect(await File(photo.photoPath!).exists(), isTrue);
          expect(
            img.decodeJpg((await store.outboxPhoto(photo.commandId))!),
            isNotNull,
          );
          expect(await File('$directory/local_store.db').exists(), isTrue);
          expect(
            await controller.photoBytes(beforeId),
            orderedEquals(cachedJpeg),
          );
          await preferences.setString(
            marker,
            jsonEncode({
              'orderId': order.id,
              'beforeId': beforeId,
              'cachedJpegLength': cachedJpeg.length,
              'ownerId': controller.user!.id,
              'commandIds': queued.map((command) => command.commandId).toList(),
              'completion': queued.last.payload,
            }),
          );
          preserveSession = true;
          _step('PHASE_A_PASS', {
            'orderId': order.id,
            'queued': 4,
            'run': _run,
          });
        } else {
          final metadata = jsonDecode(saved) as Json;
          final orderId = (metadata['orderId'] as num).toInt();
          final beforeId = (metadata['beforeId'] as num).toInt();
          await controller.restoreSession();
          expect(controller.user?.id, metadata['ownerId']);
          expect(controller.orders.any((order) => order.id == orderId), isTrue);
          final queued = await store.outbox();
          expect(
            queued.map((command) => command.commandId).toList(),
            metadata['commandIds'],
          );
          expect(queued, hasLength(4));
          final photo = queued.singleWhere(
            (command) => command.kind == OutboxKind.uploadPhoto,
          );
          expect(await File(photo.photoPath!).exists(), isTrue);
          expect(
            img.decodeJpg((await store.outboxPhoto(photo.commandId))!),
            isNotNull,
          );
          final jpeg = await controller.photoBytes(beforeId);
          expect(jpeg.length, metadata['cachedJpegLength']);
          expect(img.decodeJpg(jpeg), isNotNull);
          await _until(
            tester,
            () => controller.offline,
            'offline restored session validation',
          );
          expect(controller.isOrderPending(orderId), isTrue);
          _step('RESTORED_OFFLINE', {
            'orderId': orderId,
            'queued': queued.length,
            'run': _run,
          });
          _step('WAIT_API_ON', {'orderId': orderId});
          await _until(
            tester,
            () => controller.outbox.isEmpty && !controller.offline,
            'real server reconnection and ordered queue synchronization',
            timeout: const Duration(minutes: 3),
            tick: () async {
              try {
                await controller.refresh(silent: true);
              } on ApiException {
                /* Waiting for owned test API. */
              }
            },
          );
          final submitted = await waitForAiReview(controller.api, orderId);
          expect(submitted.status, 'ai_review');
          expect(
            _maps(submitted.data['events'])
                .where((event) => event['action'] == 'complete'),
            hasLength(1),
          );
          expect(_maps(submitted.data['photos']), hasLength(2));
          expect(
            _maps((submitted.data['completion'] as Json)['materials'])
                .single['quantity'],
            2,
          );
          final completionKey = queued
              .singleWhere((command) => command.kind == OutboxKind.complete)
              .commandId;
          await controller.api.complete(
            orderId,
            metadata['completion'] as Json,
            commandId: completionKey,
          );
          final replayed = await controller.api.order(orderId);
          expect(
            _maps(replayed.data['events'])
                .where((event) => event['action'] == 'complete'),
            hasLength(1),
          );
          expect(
            _maps((replayed.data['completion'] as Json)['materials'])
                .single['quantity'],
            2,
          );
          await master.login('master', '1234');
          await master.transition(orderId, 'close', score: 5);
          await tester.pumpWidget(
            MaterialApp(
              home: OrderDetailScreen(controller: controller, orderId: orderId),
            ),
          );
          await _until(
            tester,
            () => find
                .text('Итоговая оценка мастера: 5 / 5')
                .evaluate()
                .isNotEmpty,
            'server close displayed after synchronization',
          );
          expect(find.text('Ожидает синхронизации'), findsNothing);
          final closed = await controller.api.order(orderId);
          expect(closed.status, 'closed');
          expect(closed.score, 5);
          expect(await store.outbox(), isEmpty);
          expect(await store.outboxPhoto(photo.commandId), isNull);
          await preferences.remove(marker);
          _step('PASS', {
            'orderId': orderId,
            'score': closed.score,
            'materialQuantity': 2,
            'run': _run,
          });
        }
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        if (!preserveSession) {
          try {
            await controller.logout();
          } catch (_) {
            /* Owned unavailable test session. */
          }
        }
        controller.dispose();
        if (master.token != null) {
          try {
            await master.logout();
          } on ApiException {
            /* Own session expires if test API is unavailable. */
          }
        }
        master.close();
        await store.close();
      }
    },
    skip: _run.isEmpty,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Uint8List _picture(int green) {
  final image = img.Image(width: 160, height: 120);
  img.fill(image, color: img.ColorRgb8(40, green, 75));
  return Uint8List.fromList(img.encodePng(image));
}

Future<void> _verifyLegacyUpgrade(String path, {int fromVersion = 1}) async {
  await Directory(path).create(recursive: true);
  final bytes = _picture(120);
  final photoPath = '$path/legacy.photo';
  await File(photoPath).writeAsBytes(bytes, flush: true);
  final database = await openDatabase(
    '$path/local_store.db',
    version: fromVersion,
    onCreate: (db, version) async {
      await db.execute(
        'CREATE TABLE snapshot (key TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at INTEGER NOT NULL)',
      );
      await db.execute(
        'CREATE TABLE outbox (command_id TEXT PRIMARY KEY, kind TEXT NOT NULL, created_at INTEGER NOT NULL, owner_id INTEGER, ${fromVersion >= 2 ? "server_url TEXT," : ""} order_id INTEGER, local_ref TEXT, payload TEXT NOT NULL, photo_path TEXT, photo_filename TEXT, photo_kind TEXT, attempts INTEGER NOT NULL, state TEXT NOT NULL, response_status INTEGER, response TEXT, last_error TEXT)',
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
  await database.insert('snapshot', {
    'key': 'profile',
    'payload': jsonEncode({
      'id': 6,
      'name': 'Legacy synthetic profile',
      'role': 'worker',
    }),
    'updated_at': 1,
  });
  await database.insert('outbox', {
    'command_id': 'legacy-$_run',
    'kind': OutboxKind.uploadPhoto,
    'created_at': 1,
    'owner_id': 6,
    if (fromVersion >= 2) 'server_url': NaryadApi.normalizeBaseUrl(_baseUrl),
    'order_id': 9,
    'payload': jsonEncode({'work_done': 'Preserve the legacy draft text'}),
    'photo_path': photoPath,
    'photo_filename': 'legacy.png',
    'photo_kind': 'after',
    'attempts': 0,
    'state': OutboxState.running,
  });
  await database.close();
  final migrated = SqfliteLocalStore(directoryPath: path);
  try {
    await migrated.open();
    final legacy = (await migrated.outbox()).single;
    expect(
      legacy.serverUrl,
      fromVersion == 1 ? null : NaryadApi.normalizeBaseUrl(_baseUrl),
    );
    expect(legacy.state, OutboxState.conflict);
    expect(legacy.expectedVersion, isNull);
    expect(legacy.previousCommandId, isNull);
    expect(legacy.canRetry, isFalse);
    expect(legacy.payload['work_done'], 'Preserve the legacy draft text');
    expect(await migrated.outboxPhoto(legacy.commandId), orderedEquals(bytes));
    expect((await migrated.getSnapshot('profile'))?.data, isNotNull);
    await migrated.open();
    expect((await migrated.outbox()).single.state, OutboxState.conflict);
    _step('STORE_UPGRADE_PASS', {
      'from': fromVersion,
      'to': 3,
      'quarantined': 1,
      'mediaPreserved': true,
    });
  } finally {
    await migrated.close();
  }
}

List<Json> _maps(dynamic value) => (value as List)
    .map((item) => Map<String, dynamic>.from(item as Map))
    .toList();

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    final list = find.byType(ListView).last;
    final scrollable = find
        .descendant(of: list, matching: find.byType(Scrollable))
        .first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pump(const Duration(milliseconds: 250));
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

Future<void> _tap(WidgetTester tester, Finder target) async {
  await _reveal(tester, target);
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _enter(WidgetTester tester, Finder target, String value) async {
  await _reveal(tester, target);
  await tester.enterText(target, value);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 250));
}

Future<void> _until(
  WidgetTester tester,
  bool Function() ready,
  String description, {
  Duration timeout = const Duration(seconds: 60),
  Future<void> Function()? tick,
  String? Function()? diagnostics,
}) async {
  final elapsed = Stopwatch()..start();
  while (!ready()) {
    if (elapsed.elapsed >= timeout) {
      fail('Timed out waiting for $description. ${diagnostics?.call() ?? ''}');
    }
    if (tick != null) {
      await tick();
    }
    await tester.pump(const Duration(milliseconds: 250));
    expect(tester.takeException(), isNull, reason: description);
  }
}

void _step(String step, Json values) {
  // No sessions, PINs or HTTP authorization appear in rendezvous output.
  // ignore: avoid_print
  print('OFFLINE_STEP $step ${jsonEncode(values)}');
}
