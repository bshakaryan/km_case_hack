import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/data/recovery_models.dart';
import 'package:naryad_ai/screens/command_inspector_screen.dart';
import 'package:naryad_ai/screens/workspace_screen.dart';
import 'package:naryad_ai/ui.dart';

class _RecoveryController extends AppController {
  _RecoveryController()
    : super(
        api: NaryadApi('http://recovery.test'),
        localStore: MemoryLocalStore(),
      ) {
    user = const User(id: 6, name: 'Автор отчёта', role: 'worker');
    api.token = 'private-session-token';
  }

  final List<OutboxCommand> commands = [];
  final Map<String, Uint8List> photos = {};
  final Map<String, String> photoWarnings = {};
  List<OutboxCommand> earlierPhotos = [];
  bool recoveryBusy = false, syncBusy = false;
  int retryCalls = 0, deleteCalls = 0;
  List<String>? reviewedIds;
  List<OutboxCommand>? reviewedCommands;
  Completer<QueueActionResult>? delayedRetry;
  Completer<QueueCommandInspectionResult>? delayedInspection;
  QueueActionResult retryResult = QueueActionResult(
    QueueRecoveryStatus.storageFailure,
    'Не удалось сохранить очередь. Данные не изменены.',
  );
  QueueActionResult deleteResult = QueueActionResult(
    QueueRecoveryStatus.storageFailure,
    'Удаление не сохранено. Цепь остаётся в очереди.',
  );

  @override
  List<OutboxCommand> get outbox => List.unmodifiable(commands);
  @override
  List<OutboxCommand> get conflictCommands =>
      commands.where((c) => c.state == OutboxState.conflict).toList();
  @override
  bool get recoveringQueue => recoveryBusy;
  @override
  bool get syncing => syncBusy;

  QueueCommandInspection inspection(String id) {
    final index = commands.indexWhere((command) => command.commandId == id);
    return QueueCommandInspection(
      command: commands[index],
      dependentCommands: commands.skip(index + 1).toList(),
      preparedPhotoBytesByCommandId: photos,
      mediaWarnings: photoWarnings,
      retainedPhotoCommands: earlierPhotos,
    );
  }

  @override
  Future<QueueCommandInspectionResult> inspectCommand(String id) async {
    if (delayedInspection != null) return delayedInspection!.future;
    return QueueCommandInspectionResult(
      QueueRecoveryStatus.success,
      'Локальные данные прочитаны.',
      inspection: inspection(id),
    );
  }

  @override
  Future<QueueActionResult> retryCommand(String id) async {
    retryCalls++;
    final result = delayedRetry == null
        ? retryResult
        : await delayedRetry!.future;
    if (result.status == QueueRecoveryStatus.success && result.changed) {
      final index = commands.indexWhere((command) => command.commandId == id);
      commands[index] = commands[index].copyWith(
        state: OutboxState.pending,
        attempts: 0,
      );
      notifyListeners();
    }
    return result;
  }

  @override
  Future<QueueActionResult> discardCommand(
    String id, {
    List<String>? expectedCommandIds,
    List<OutboxCommand>? expectedCommands,
  }) async {
    deleteCalls++;
    reviewedIds = expectedCommandIds;
    reviewedCommands = expectedCommands;
    if (deleteResult.status == QueueRecoveryStatus.success &&
        deleteResult.changed) {
      commands.removeWhere(
        (command) => expectedCommandIds!.contains(command.commandId),
      );
      notifyListeners();
    }
    return deleteResult;
  }

  void changeBoundary(String boundary) {
    switch (boundary) {
      case 'token':
        api.token = 'new-session-token';
      case 'api':
        api = NaryadApi('http://other.test')..token = 'private-session-token';
      case 'owner':
        user = const User(id: 7, name: 'Другой', role: 'worker');
      case 'role':
        user = const User(id: 6, name: 'Автор отчёта', role: 'manager');
    }
    notifyListeners();
  }
}

OutboxCommand _command(
  _RecoveryController c, {
  String id = 'complete-0001',
  String kind = OutboxKind.complete,
  String state = OutboxState.conflict,
  int? responseStatus = 0,
  Json? response,
  Json payload = const {
    'work_done': 'Заменено уплотнение',
    'comment': 'Течь устранена',
  },
}) => OutboxCommand(
  commandId: id,
  kind: kind,
  createdAt: 1791356400000,
  ownerId: 6,
  serverUrl: c.api.baseUrl,
  orderId: 12,
  expectedVersion: 8,
  state: state,
  responseStatus: responseStatus,
  response: response,
  lastError: responseStatus == 0 ? 'Нет подтверждения' : null,
  photoFilename: kind == OutboxKind.uploadPhoto ? '$id.png' : null,
  photoKind: kind == OutboxKind.uploadPhoto ? 'before' : null,
  payload: payload,
);

String _label(OutboxCommand command) =>
    command.kind == OutboxKind.uploadPhoto ? 'Загрузка фото' : 'Сдача отчёта';

Future<void> _openQueue(WidgetTester tester, _RecoveryController c) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(),
      home: Scaffold(
        body: Builder(
          builder: (context) {
            return TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                barrierDismissible: false,
                builder: (_) =>
                    SyncQueueDialog(controller: c, commandLabel: _label),
              ),
              child: const Text('Открыть очередь'),
            );
          },
        ),
      ),
    ),
  );
  await tester.tap(find.text('Открыть очередь'));
  await tester.pumpAndSettle();
}

TextButton _button(WidgetTester tester, String label) =>
    tester.widget<TextButton>(
      find
          .ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((widget) => widget is TextButton),
          )
          .first,
    );

void main() {
  testWidgets(
    'Retry storage failure retains command and shows no success acknowledgement',
    (tester) async {
      final c = _RecoveryController();
      c.commands.add(_command(c));
      addTearDown(c.dispose);
      await _openQueue(tester, c);
      expect(
        find.textContaining('Результат отправки неизвестен'),
        findsOneWidget,
      );
      await tester.tap(find.text('Отправить снова'));
      await tester.pumpAndSettle();
      expect(c.retryCalls, 1);
      expect(c.commands.single.state, OutboxState.conflict);
      expect(
        find.text('Не удалось сохранить очередь. Данные не изменены.'),
        findsOneWidget,
      );
      expect(
        find.text('Повторная отправка поставлена в очередь'),
        findsNothing,
      );
      expect(find.text('Очередь отправки'), findsOneWidget);
    },
  );

  testWidgets(
    'Retry acknowledges local queue only and retains unknown outcome, key and basis',
    (tester) async {
      final c = _RecoveryController();
      c.commands.add(_command(c));
      c.retryResult = QueueActionResult(
        QueueRecoveryStatus.success,
        'Сохранено локально.',
        changed: true,
      );
      addTearDown(c.dispose);
      await _openQueue(tester, c);
      await tester.tap(find.text('Отправить снова'));
      await tester.pumpAndSettle();
      expect(c.commands.single.commandId, 'complete-0001');
      expect(c.commands.single.expectedVersion, 8);
      expect(
        find.text('Повторная отправка поставлена в очередь'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Результат предыдущей отправки не подтверждён'),
        findsOneWidget,
      );
      expect(find.text('Очередь отправки'), findsOneWidget);
    },
  );

  testWidgets(
    'Delete reviews exact dependent chain and rollback failure keeps its text and media',
    (tester) async {
      final c = _RecoveryController();
      c.commands.addAll([
        _command(c),
        _command(
          c,
          id: 'photo-later-0002',
          kind: OutboxKind.uploadPhoto,
          state: OutboxState.pending,
        ),
      ]);
      addTearDown(c.dispose);
      await _openQueue(tester, c);
      await tester.tap(find.text('Удалить команду'));
      await tester.pumpAndSettle();
      expect(find.text('Команд в выбранной цепи: 2'), findsOneWidget);
      expect(find.textContaining('Ключ: photo-later-0002'), findsOneWidget);
      expect(
        find.textContaining('удаление из очереди его не отменит'),
        findsOneWidget,
      );
      await tester.tap(find.text('Удалить цепь'));
      await tester.pumpAndSettle();
      expect(c.reviewedIds, ['complete-0001', 'photo-later-0002']);
      expect(
        c.reviewedCommands!.map((command) => command.toJson()).toList(),
        c.commands.map((command) => command.toJson()).toList(),
      );
      expect(c.commands.length, 2);
      expect(
        find.text('Удаление не сохранено. Цепь остаётся в очереди.'),
        findsOneWidget,
      );
      expect(
        find.text('Выбранная цепь удалена из локальной очереди'),
        findsNothing,
      );
    },
  );

  testWidgets(
    'Committed deletion shows media cleanup warning separately from local success',
    (tester) async {
      final c = _RecoveryController();
      c.commands.add(_command(c));
      c.deleteResult = QueueActionResult(
        QueueRecoveryStatus.success,
        'Удалено локально.',
        changed: true,
        warning: 'Команды удалены. Очистить файлы фото пока не удалось.',
      );
      addTearDown(c.dispose);
      await _openQueue(tester, c);
      await tester.tap(find.text('Удалить команду'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить цепь'));
      await tester.pumpAndSettle();
      expect(c.commands, isEmpty);
      expect(
        find.text('Выбранная цепь удалена из локальной очереди'),
        findsOneWidget,
      );
      expect(
        find.text('Команды удалены. Очистить файлы фото пока не удалось.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Inspector exposes retained report/materials and authored photo without disclosing credentials',
    (tester) async {
      final c = _RecoveryController();
      c.reference = {
        'materials': [
          {'id': 2, 'name': 'Уплотнение', 'unit': 'шт'},
        ],
      };
      c.commands.add(
        _command(
          c,
          payload: {
            'work_done': 'Заменено уплотнение',
            'materials': [
              {'material_id': 2, 'quantity': 1},
            ],
            'token': 'secret-payload-value',
          },
        ),
      );
      final earlier = _command(
        c,
        id: 'photo-earlier-0003',
        kind: OutboxKind.uploadPhoto,
        state: OutboxState.pending,
        payload: {},
      );
      c.earlierPhotos = [earlier];
      c.photos[earlier.commandId] = Uint8List.fromList(
        image.encodePng(image.Image(width: 2, height: 2)),
      );
      String? clipboard;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      addTearDown(c.dispose);
      await _openQueue(tester, c);
      await tester.tap(find.text('Посмотреть данные'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Выполненные работы: Заменено уплотнение'),
        findsOneWidget,
      );
      expect(find.textContaining('Уплотнение · 1 шт'), findsOneWidget);
      final author = find.text('Автор: Автор отчёта · #6');
      final reportCard = find
          .ancestor(
            of: find.textContaining('Выполненные работы: Заменено уплотнение'),
            matching: find.byType(Card),
          )
          .first;
      expect(find.descendant(of: reportCard, matching: author), findsOneWidget);
      expect(
        find.textContaining('не подтверждает результат действия на сервере'),
        findsOneWidget,
      );

      // ListView builds lower cards lazily. Inspect each author's card after
      // scrolling it into view instead of requiring two mounted authors.
      final inspectorScrollable = find
          .descendant(
            of: find.byType(CommandInspectorScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      final retainedPhotoLabel = find.textContaining(
        'не входят в выбранную цепь удаления',
      );
      await tester.scrollUntilVisible(
        retainedPhotoLabel,
        180,
        scrollable: inspectorScrollable,
      );
      expect(retainedPhotoLabel, findsOneWidget);
      final preparedPhoto = find.byKey(
        const ValueKey('prepared-photo-photo-earlier-0003'),
      );
      await tester.scrollUntilVisible(
        preparedPhoto,
        180,
        scrollable: inspectorScrollable,
      );
      await tester.pumpAndSettle();
      expect(preparedPhoto, findsOneWidget);
      final photoCard = find
          .ancestor(of: preparedPhoto, matching: find.byType(Card))
          .first;
      expect(find.descendant(of: photoCard, matching: author), findsOneWidget);
      await tester.tap(find.text('Скопировать текст'));
      await tester.pumpAndSettle();
      expect(clipboard, contains('Заменено уплотнение'));
      expect(clipboard, contains('Уплотнение · 1 шт'));
      expect(clipboard, isNot(contains('secret-payload-value')));
      expect(clipboard, isNot(contains('private-session-token')));
      expect(find.textContaining('private-session-token'), findsNothing);
    },
  );

  testWidgets(
    'Missing prepared photo leaves its metadata and report readable',
    (tester) async {
      final c = _RecoveryController();
      c.commands.addAll([
        _command(c),
        _command(
          c,
          id: 'missing-photo-0004',
          kind: OutboxKind.uploadPhoto,
          state: OutboxState.pending,
          payload: {},
        ),
      ]);
      addTearDown(c.dispose);
      await _openQueue(tester, c);
      await tester.tap(find.text('Посмотреть данные').first);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Выполненные работы: Заменено уплотнение'),
        findsOneWidget,
      );
      expect(
        find.text('Подготовленное фото: missing-photo-0004.png'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Подготовленное фото недоступно. Текст и сведения команды сохранены.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'Global sync/recovery/save blocks mutations and open inspection',
    (tester) async {
      final c = _RecoveryController()..syncBusy = true;
      c.commands.add(_command(c));
      addTearDown(c.dispose);
      await _openQueue(tester, c);
      for (final label in [
        'Отправить снова',
        'Удалить команду',
        'Посмотреть данные',
      ]) {
        expect(_button(tester, label).onPressed, isNull);
      }
      c.syncBusy = false;
      c.recoveryBusy = true;
      c.notifyListeners();
      await tester.pump();
      expect(_button(tester, 'Отправить снова').onPressed, isNull);
      c.recoveryBusy = false;
      c.saving = true;
      c.notifyListeners();
      await tester.pump();
      expect(_button(tester, 'Отправить снова').onPressed, isNull);
      expect(c.retryCalls, 0);
      expect(c.deleteCalls, 0);
    },
  );

  for (final boundary in ['token', 'api', 'owner', 'role']) {
    testWidgets(
      'Protected queue and inspector close on $boundary boundary; no late private content',
      (tester) async {
        final c = _RecoveryController();
        c.commands.add(_command(c));
        c.delayedInspection = Completer<QueueCommandInspectionResult>();
        final oldInspection = c.inspection('complete-0001');
        addTearDown(c.dispose);
        await _openQueue(tester, c);
        await tester.tap(find.text('Посмотреть данные'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        c.changeBoundary(boundary);
        await tester.pumpAndSettle();
        c.delayedInspection!.complete(
          QueueCommandInspectionResult(
            QueueRecoveryStatus.success,
            'Прочитано.',
            inspection: oldInspection,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(SyncQueueDialog), findsNothing);
        expect(find.byType(CommandInspectorScreen), findsNothing);
        expect(find.textContaining('Заменено уплотнение'), findsNothing);
        expect(find.text('Открыть очередь'), findsOneWidget);
      },
    );
  }

  testWidgets(
    'Session change during retry suppresses old-account success and blocks duplicate clicks',
    (tester) async {
      final c = _RecoveryController();
      c.commands.add(_command(c));
      c.delayedRetry = Completer<QueueActionResult>();
      addTearDown(c.dispose);
      await _openQueue(tester, c);
      await tester.tap(find.text('Отправить снова'));
      await tester.pump();
      expect(_button(tester, 'Отправить снова').onPressed, isNull);
      c.changeBoundary('token');
      await tester.pumpAndSettle();
      c.delayedRetry!.complete(
        QueueActionResult(
          QueueRecoveryStatus.scopeChanged,
          'Сессия изменена.',
          changed: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(c.retryCalls, 1);
      expect(
        find.text('Повторная отправка поставлена в очередь'),
        findsNothing,
      );
      expect(find.byType(SyncQueueDialog), findsNothing);
    },
  );

  testWidgets(
    'Session change during delete confirmation closes it without deleting old-account chain',
    (tester) async {
      final c = _RecoveryController();
      c.commands.add(_command(c));
      addTearDown(c.dispose);
      await _openQueue(tester, c);
      await tester.tap(find.text('Удалить команду'));
      await tester.pumpAndSettle();
      expect(find.text('Удалить выбранную цепь?'), findsOneWidget);
      c.changeBoundary('owner');
      await tester.pumpAndSettle();
      expect(find.text('Удалить выбранную цепь?'), findsNothing);
      expect(c.deleteCalls, 0);
      expect(c.commands.length, 1);
    },
  );

  testWidgets(
    'Stale deletion chain is an error requiring reinspection, never local success',
    (tester) async {
      final c = _RecoveryController();
      c.commands.add(_command(c));
      c.deleteResult = QueueActionResult(
        QueueRecoveryStatus.changed,
        'Цепь изменилась. Проверьте её снова.',
      );
      addTearDown(c.dispose);
      await _openQueue(tester, c);
      await tester.tap(find.text('Удалить команду'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Удалить цепь'));
      await tester.pumpAndSettle();
      expect(find.text('Цепь изменилась. Проверьте её снова.'), findsOneWidget);
      expect(c.commands.length, 1);
      expect(
        find.text('Выбранная цепь удалена из локальной очереди'),
        findsNothing,
      );
    },
  );

  test('Status labels separate version conflict, missing basis and unknown delivery after retry', () {
    final c = _RecoveryController();
    addTearDown(c.dispose);
    expect(
      recoveryCommandStatus(
        _command(
          c,
          responseStatus: 409,
          response: {'code': 'order_version_conflict'},
        ),
      ),
      'Конфликт версии',
    );
    expect(
      recoveryCommandStatus(
        _command(
          c,
          responseStatus: null,
          response: {'code': 'local_order_precondition_unavailable'},
        ),
      ),
      'Основание действия неизвестно',
    );
    expect(
      recoveryCommandStatus(_command(c, state: OutboxState.pending)),
      'Результат предыдущей отправки не подтверждён',
    );
    expect(
      recoveryCommandStatus(_command(c, state: OutboxState.running)),
      'Отправка выполняется',
    );
    expect(
      recoveryCommandStatus(_command(c, responseStatus: 403)),
      'Команда отклонена',
    );
  });
}
