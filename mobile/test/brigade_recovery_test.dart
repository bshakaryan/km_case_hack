import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as imaging;
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/form_draft.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/screens/completion_screen.dart';

class _DraftStore extends MemoryLocalStore {
  Completer<void>? writeGate;
  bool failWrites = false;

  @override
  Future<void> putFormDraft(String key, Json data) async {
    final gate = writeGate;
    if (gate != null) await gate.future;
    if (failWrites) throw StateError('simulated draft write failure');
    await super.putFormDraft(key, data);
  }
}

WorkOrder _order({int responsible = 6, int version = 3}) => WorkOrder.fromJson({
  'id': 12,
  'version': version,
  'number': 'Н-БРИГАДА-12',
  'title': 'Ремонт привода',
  'description': 'Осмотр и ремонт привода насоса.',
  'status': 'in_progress',
  'priority': 'normal',
  'work_type': 'planned',
  'deadline': '2026-10-08T18:00:00Z',
  'normal_hours': 2,
  'assignee_id': responsible,
  'assignee_name': responsible == 6 ? 'Иван' : 'Анна',
  'brigade_id': 2,
  'photos': <Json>[],
  'participants_source': 'live',
  'participants': [
    for (final id in [6, 7])
      {
        'employee_id': id,
        'name': id == 6 ? 'Иван' : 'Анна',
        'is_responsible': responsible == id,
        'source': 'live',
      },
  ],
});

class _Controller extends AppController {
  _Controller(_DraftStore store)
    : super(
        localStore: store,
        api: NaryadApi('http://recovery.test/api')..token = 'draft-session',
      ) {
    user = const User(id: 6, name: 'Иван', role: 'worker');
    orders = [_order()];
    reference = {
      'fault_codes': [
        {'id': 3, 'code': 'ПР', 'name': 'Привод'},
      ],
    };
  }

  int openedDrafts = 0;
  int submissions = 0;

  void revokeResponsibility() {
    orders = [_order(responsible: 7, version: 4)];
    notifyListeners();
  }

  void restoreResponsibility() {
    orders = [_order()];
    notifyListeners();
  }

  void switchAccount() {
    user = const User(id: 7, name: 'Анна', role: 'worker');
    notifyListeners();
  }

  @override
  Future<FormDraftSession> openFormDraft(String kind, {int? orderId}) {
    openedDrafts++;
    return super.openFormDraft(kind, orderId: orderId);
  }

  @override
  Future<WorkOrder> complete(
    int id,
    Json data, {
    OrderWriteBasis? basis,
  }) async {
    submissions++;
    return super.complete(id, data, basis: basis);
  }
}

String _draftKey(_Controller controller) => localScopeKey(
  controller.api.baseUrl,
  6,
  'draft:${FormDraftKind.completion}:12',
);

Future<FormDraft> _seed(_DraftStore store, _Controller controller) async {
  final photo = base64Encode(
    Uint8List.fromList(imaging.encodePng(imaging.Image(width: 2, height: 2))),
  );
  final order = _order();
  final draft = FormDraft(
    kind: FormDraftKind.completion,
    orderId: 12,
    basis: const OrderWriteBasis(expectedVersion: 3),
    data: {
      'form_schema': 1,
      'work': 'Привод отремонтирован и проверен',
      'comment': 'Сохранённое пояснение',
      'fault_id': 3,
      'dirty': true,
      'uncertain': false,
      'stale': false,
      'done': false,
      'error': null,
      'operation': null,
      'assignment_snapshot': {
        'id': 12,
        'assignee_id': 6,
        'assignee_name': 'Иван',
        'brigade_id': 2,
        'participants': order.data['participants'],
        'participants_source': 'live',
      },
      'materials': [
        {
          'material': {'id': 4, 'name': 'Смазка', 'unit': 'кг'},
          'quantity': '1,5',
        },
      ],
      'photos': [
        {
          'bytes': photo,
          'filename': 'repair.png',
          'uploading': false,
          'uploaded': true,
          'queued': false,
          'uncertain': false,
          'error': null,
        },
      ],
    },
  );
  await store.putFormDraft(_draftKey(controller), draft.toJson());
  return draft;
}

Future<GlobalKey<NavigatorState>> _mount(
  WidgetTester tester,
  _Controller controller,
) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('Карточка наряда')),
    ),
  );
  _open(navigator, controller);
  await tester.pumpAndSettle();
  return navigator;
}

void _open(GlobalKey<NavigatorState> navigator, _Controller controller) {
  unawaited(
    navigator.currentState!.push<void>(
      MaterialPageRoute(
        builder: (_) =>
            CompletionScreen(controller: controller, order: _order()),
      ),
    ),
  );
}

Future<void> _confirmBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(find.text('Закрыть отчёт?'), findsOneWidget);
  await tester.tap(find.widgetWithText(OutlinedButton, 'Закрыть форму'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void _expectRetained(FormDraft draft, FormDraft original, String work) {
  expect(draft.data['work'], work);
  expect(draft.data['comment'], original.data['comment']);
  expect(draft.data['materials'], original.data['materials']);
  expect(draft.data['photos'], original.data['photos']);
  expect(
    draft.data['assignment_snapshot'],
    original.data['assignment_snapshot'],
  );
  expect(draft.basis!.expectedVersion, 3);
  expect(draft.basis!.previousCommandId, isNull);
}

void main() {
  testWidgets('revoked responsibility keeps Back behind pending draft save', (
    tester,
  ) async {
    final store = _DraftStore();
    final controller = _Controller(store);
    addTearDown(controller.dispose);
    final original = await _seed(store, controller);
    await _mount(tester, controller);
    final submit = tester
        .widget<FilledButton>(
          find.widgetWithText(FilledButton, 'Отправить на приёмку'),
        )
        .onPressed;
    expect(submit, isNotNull);
    final gate = Completer<void>();
    store.writeGate = gate;
    const work = 'Последний ввод перед сменой ответственного';
    await tester.ensureVisible(find.byType(TextFormField).first);
    await tester.enterText(find.byType(TextFormField).first, work);
    await tester.pump();
    controller.revokeResponsibility();
    await tester.pump();
    submit!.call();
    await tester.pump();
    expect(find.text('Отправить на приёмку'), findsNothing);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField).first).enabled,
      isFalse,
    );
    expect(controller.submissions, 0);
    expect(await store.outbox(), isEmpty);

    await _confirmBack(tester);
    expect(find.byType(CompletionScreen), findsOneWidget);
    expect(
      FormDraft.fromJson((await store.getFormDraft(_draftKey(controller)))!)
          .data['work'],
      original.data['work'],
    );
    store.writeGate = null;
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(CompletionScreen), findsNothing);
    final saved = FormDraft.fromJson(
      (await store.getFormDraft(_draftKey(controller)))!,
    );
    _expectRetained(saved, original, work);
    expect(controller.outbox, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('revoked form keeps failed save and hides it from a new account', (
    tester,
  ) async {
    final store = _DraftStore();
    final controller = _Controller(store);
    addTearDown(controller.dispose);
    final original = await _seed(store, controller);
    final navigator = await _mount(tester, controller);
    final workController = tester
        .widget<TextFormField>(find.byType(TextFormField).first)
        .controller!;
    expect(workController.text, original.data['work']);
    const work = 'Ввод остаётся до подтверждённого сохранения';
    store.failWrites = true;
    await tester.ensureVisible(find.byType(TextFormField).first);
    await tester.enterText(find.byType(TextFormField).first, work);
    await tester.pumpAndSettle();
    expect(workController.text, work);
    controller.revokeResponsibility();
    await tester.pump();
    await _confirmBack(tester);
    await tester.pumpAndSettle();
    expect(find.byType(CompletionScreen), findsOneWidget);
    expect(find.textContaining('Черновик не сохранён'), findsOneWidget);
    expect(find.text('Черновик сохранён на устройстве'), findsNothing);
    expect(find.text('Отправить на приёмку'), findsNothing);
    expect(workController.text, work);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField).first).controller,
      same(workController),
    );
    final key = _draftKey(controller);
    expect(await store.getFormDraft(key), original.toJson());
    expect(controller.submissions, 0);
    expect(await store.outbox(), isEmpty);

    store.failWrites = false;
    final retrySave = find.widgetWithText(
      TextButton,
      'Повторить сохранение черновика',
    );
    await tester.ensureVisible(retrySave);
    await tester.tap(retrySave);
    await tester.pumpAndSettle();
    expect(workController.text, work);
    expect(find.textContaining('Черновик не сохранён'), findsNothing);
    final retried = FormDraft.fromJson((await store.getFormDraft(key))!);
    _expectRetained(retried, original, work);
    await _confirmBack(tester);
    await tester.pumpAndSettle();
    expect(find.byType(CompletionScreen), findsNothing);
    final saved = FormDraft.fromJson((await store.getFormDraft(key))!);
    _expectRetained(saved, original, work);

    // Initial unauthorized navigation must not open/read an existing draft.
    final opened = controller.openedDrafts;
    _open(navigator, controller);
    await tester.pumpAndSettle();
    expect(controller.openedDrafts, opened);
    expect(find.byType(TextFormField), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // A form already restored by its owner must become opaque across accounts.
    controller.restoreResponsibility();
    _open(navigator, controller);
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsWidgets);
    controller.switchAccount();
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text(work), findsNothing);
    expect(find.textContaining('Контекст формы изменился'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(await store.getFormDraft(key), saved.toJson());
    expect(await store.outbox(), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
