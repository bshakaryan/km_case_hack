import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:http/http.dart' as http;
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/form_draft.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FailingDraftStore extends MemoryLocalStore {
  bool failNext = true;
  @override
  Future<void> putFormDraft(String key, Json data) async {
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    await super.putFormDraft(key, data);
  }
}

AppController controllerFor(
  MemoryLocalStore store, {
  String url = 'http://server.test/api',
  int owner = 7,
}) => AppController(
  api: NaryadApi(
    url,
    client: MockClient((_) async => http.Response('{}', 200)),
  ),
  localStore: store,
)..user = User(id: owner, name: 'Работник', role: 'worker');

FormDraft report({
  String text = 'Ремонт выполнен',
  int version = 3,
  String state = FormDraftState.editing,
}) => FormDraft(
  kind: FormDraftKind.completion,
  orderId: 9,
  data: {
    'text': text,
    'materials': [
      {'id': 4, 'quantity': '1,5'},
    ],
    'photo': base64Encode(Uint8List.fromList([1, 2, 3])),
  },
  basis: OrderWriteBasis(expectedVersion: version),
  state: state,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'draft JSON/media/basis survive controller recreation and cache cleanup',
    () async {
      final store = MemoryLocalStore();
      final first = controllerFor(store);
      final session = await first.openFormDraft(
        FormDraftKind.completion,
        orderId: 9,
      );
      final original = report();
      await session.save(original);
      original.data['text'] = 'Changed after save';
      await store.clearSnapshots();
      await store.clearPhotos();
      first.dispose();
      final next = controllerFor(store);
      addTearDown(next.dispose);
      final restored = await (await next.openFormDraft(
        FormDraftKind.completion,
        orderId: 9,
      )).read();
      expect(restored!.data['text'], 'Ремонт выполнен');
      expect(base64Decode(restored.data['photo'] as String), [1, 2, 3]);
      expect(restored.data['materials'], [
        {'id': 4, 'quantity': '1,5'},
      ]);
      expect(restored.basis!.expectedVersion, 3);
      expect(await store.outbox(), isEmpty);
    },
  );

  test('drafts separate owner, full API path, form and order', () async {
    final store = MemoryLocalStore();
    final own = controllerFor(store);
    addTearDown(own.dispose);
    await (await own.openFormDraft(
      FormDraftKind.completion,
      orderId: 9,
    )).save(report());
    for (final other in [
      controllerFor(store, owner: 8),
      controllerFor(store, url: 'http://server.test/other'),
    ]) {
      expect(
        await (await other.openFormDraft(
          FormDraftKind.completion,
          orderId: 9,
        )).read(),
        isNull,
      );
      other.dispose();
    }
    expect(
      await (await own.openFormDraft(FormDraftKind.create)).read(),
      isNull,
    );
    expect(
      await (await own.openFormDraft(
        FormDraftKind.completion,
        orderId: 10,
      )).read(),
      isNull,
    );
  });

  test('persisted preflight marker survives restart and rejects stale autosave unlock', () async {
    final store = MemoryLocalStore();
    final first = controllerFor(store);
    final session = await first.openFormDraft(
      FormDraftKind.completion,
      orderId: 9,
    );
    await session.save(report(state: FormDraftState.submitting));
    await expectLater(
      session.save(report(text: 'Late autosave')),
      throwsA(isA<ApiException>()),
    );
    first.dispose();
    final next = controllerFor(store);
    addTearDown(next.dispose);
    final handle = await next.openFormDraft(
      FormDraftKind.completion,
      orderId: 9,
    );
    expect((await handle.read())!.state, FormDraftState.uncertain);
    expect(
      await store.outbox(),
      isEmpty,
      reason: 'A marker can conservatively precede the first HTTP/queue call.',
    );
    await expectLater(handle.save(report()), throwsA(isA<ApiException>()));
    await handle.save(report(), acknowledgeSubmission: true);
    expect((await handle.read())!.state, FormDraftState.editing);
  });

  test(
    'session owner/API change and replacement handle cannot write/delete draft',
    () async {
      final store = MemoryLocalStore();
      final own = controllerFor(store);
      addTearDown(own.dispose);
      final old = await own.openFormDraft(FormDraftKind.completion, orderId: 9);
      await old.save(report());
      final replacement = await own.openFormDraft(
        FormDraftKind.completion,
        orderId: 9,
      );
      await expectLater(
        old.save(report(text: 'obsolete')),
        throwsA(isA<ApiException>()),
      );
      await expectLater(old.delete(), throwsA(isA<ApiException>()));
      own.user = const User(id: 8, name: 'Другой', role: 'worker');
      await expectLater(
        replacement.save(report()),
        throwsA(isA<ApiException>()),
      );
      await expectLater(replacement.delete(), throwsA(isA<ApiException>()));
      own.user = const User(id: 7, name: 'Исходный', role: 'worker');
      final otherApi = own.api;
      own.api = NaryadApi('http://server.test/other');
      await expectLater(
        replacement.save(report()),
        throwsA(isA<ApiException>()),
      );
      own.api.close();
      own.api = otherApi;
      expect((await replacement.read())!.data['text'], 'Ремонт выполнен');
    },
  );

  test('delete prevents delayed autosave resurrection', () async {
    final store = MemoryLocalStore();
    final own = controllerFor(store);
    addTearDown(own.dispose);
    final session = await own.openFormDraft(
      FormDraftKind.completion,
      orderId: 9,
    );
    await session.save(report());
    final deleted = session.delete();
    expect(() => session.save(report()), throwsStateError);
    await deleted;
    expect(
      await (await own.openFormDraft(
        FormDraftKind.completion,
        orderId: 9,
      )).read(),
      isNull,
    );
  });

  test('write failures remain visible and serialization recovers', () async {
    final own = controllerFor(_FailingDraftStore());
    addTearDown(own.dispose);
    final session = await own.openFormDraft(
      FormDraftKind.completion,
      orderId: 9,
    );
    await expectLater(session.save(report()), throwsStateError);
    await session.save(report(text: 'Recovery'));
    expect((await session.read())!.data['text'], 'Recovery');
  });

  test(
    'malformed stored payload stays visible and is not treated as no draft',
    () async {
      final store = MemoryLocalStore();
      final own = controllerFor(store);
      addTearDown(own.dispose);
      final key = localScopeKey(own.api.baseUrl, 7, 'draft:completion:9');
      await store.putFormDraft(key, {'schema': 999, 'data': {}});
      final session = await own.openFormDraft(
        FormDraftKind.completion,
        orderId: 9,
      );
      await expectLater(session.read(), throwsFormatException);
      expect((await store.getFormDraft(key))!['schema'], 999);
    },
  );

  test('GET version cannot rebase draft; confirmed own photo can advance predecessor', () async {
    final own = controllerFor(MemoryLocalStore());
    addTearDown(own.dispose);
    final session = await own.openFormDraft(
      FormDraftKind.completion,
      orderId: 9,
    );
    await session.save(report());
    await expectLater(
      session.save(report(version: 4)),
      throwsA(isA<ApiException>()),
    );
    await session.save(
      report().copyWith(
        basis: const OrderWriteBasis(previousCommandId: 'photo-command-1'),
      ),
    );
    expect((await session.read())!.basis!.previousCommandId, 'photo-command-1');
    await expectLater(
      session.save(report(version: 5)),
      throwsA(isA<ApiException>()),
    );
  });

  test('logout keeps draft but invalidates prior handle', () async {
    final store = MemoryLocalStore();
    final own = controllerFor(store);
    addTearDown(own.dispose);
    final session = await own.openFormDraft(
      FormDraftKind.completion,
      orderId: 9,
    );
    await session.save(report());
    await own.logout();
    await expectLater(session.read(), throwsA(isA<ApiException>()));
    own.user = const User(id: 7, name: 'Работник', role: 'worker');
    expect(
      (await (await own.openFormDraft(
        FormDraftKind.completion,
        orderId: 9,
      )).read())!.data['text'],
      'Ремонт выполнен',
    );
  });
}
