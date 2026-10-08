import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/data/recovery_models.dart';
import 'package:naryad_ai/domain/reference_edit.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _server = 'http://reference.test/api';
const _admin = User(id: 9, name: 'Synthetic admin', role: 'admin');
Json _equipment({int id = 1, String name = 'Оборудование'}) => {
  'id': id,
  'name': name,
  'inventory_number': 'SYN-$id',
  'area_id': 1,
  'type': 'Насос',
  'criticality': 'custom-level',
};
Json _material({int id = 1, String name = 'Материал', String unit = 'шт'}) => {
  'id': id,
  'name': name,
  'unit': unit,
};
Json _reference() => {
  'areas': [
    {'id': 1, 'name': 'Участок'},
  ],
  'equipment': [_equipment()],
  'materials': [_material()],
  'employees': [],
  'brigades': [],
  'fault_codes': [],
  'time_norms': [],
};
http.Response _response(Object? data, {int status = 200}) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
NaryadApi _api(FutureOr<http.Response> Function(http.Request) handler) =>
    NaryadApi(
      _server,
      client: MockClient((request) async => await handler(request)),
    )..token = 'synthetic-session';
AppController _controller(
  FutureOr<http.Response> Function(http.Request) handler, {
  MemoryLocalStore? store,
  NaryadApi Function(String)? apiFactory,
}) =>
    AppController(
        api: _api(handler),
        localStore: store ?? MemoryLocalStore(),
        apiFactory: apiFactory,
      )
      ..user = _admin
      ..reference = _reference();
TypeMatcher<ApiException> _error(int status, bool uncertain) =>
    isA<ApiException>()
        .having((error) => error.statusCode, 'status', status)
        .having(
          (error) => error.requestMayHaveSucceeded,
          'uncertain',
          uncertain,
        );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
  });

  test('four reference routes send supplied normalized fields once without order keys', () async {
    final requests = <http.Request>[];
    final api = _api((request) {
      requests.add(request);
      final payload = jsonDecode(request.body) as Json;
      final equipment = request.url.path.contains('/equipment');
      return _response({
        ...equipment ? _equipment(id: 7) : _material(id: 7),
        ...payload,
      }, status: request.method == 'POST' ? 201 : 200);
    });
    addTearDown(api.close);
    final name = List.filled(120, '😀').join();
    await api.createEquipment({
      'name': ' $name ',
      'inventory_number': ' SYN-new ',
      'area_id': 1,
      'type': ' Насос ',
    });
    await api.updateEquipment(7, {'criticality': ' arbitrary-level '});
    await api.createMaterial({
      'name': ' Материал ',
      'unit': ' свободная единица ',
    });
    await api.updateMaterial(7, {'unit': 'кг'});
    expect(requests.map((request) => '${request.method} ${request.url.path}'), [
      'POST /api/reference/equipment',
      'PATCH /api/reference/equipment/7',
      'POST /api/reference/materials',
      'PATCH /api/reference/materials/7',
    ]);
    expect(jsonDecode(requests[0].body)['name'], name);
    expect(jsonDecode(requests[1].body), {'criticality': 'arbitrary-level'});
    for (final request in requests) {
      expect(request.headers['authorization'], 'Bearer synthetic-session');
      expect(request.headers.containsKey('x-client-command-id'), false);
      expect(request.headers.containsKey('x-expected-order-version'), false);
      expect(
        request.headers.containsKey('x-previous-client-command-id'),
        false,
      );
    }
  });

  test(
    'invalid fields, empty patches and noninteger area stop before HTTP',
    () async {
      var calls = 0;
      final api = _api((_) {
        calls++;
        return _response({});
      });
      addTearDown(api.close);
      for (final invalid in [
        <String, dynamic>{},
        {'id': 1},
        {'area_id': true},
        {'area_id': 1.0},
        {'area_id': null},
        {'criticality': ''},
        {'type': List.filled(81, '😀').join()},
      ]) {
        await expectLater(
          api.updateEquipment(1, invalid),
          throwsA(_error(422, false)),
        );
      }
      await expectLater(
        api.createMaterial({'name': 'Материал'}),
        throwsA(_error(422, false)),
      );
      await expectLater(
        api.updateMaterial(0, {'unit': 'кг'}),
        throwsA(_error(422, false)),
      );
      expect(calls, 0);
    },
  );

  for (final scenario in [
    'wrong_post_status',
    'accepted_only',
    'empty',
    'missing_id',
    'missing_full_field',
    'wrong_patch_id',
    'wrong_echo',
    'bad_utf8',
  ]) {
    test(
      'unusable reference ACK $scenario is uncertain and never repeated',
      () async {
        var calls = 0;
        final api = _api((_) {
          calls++;
          return switch (scenario) {
            'wrong_post_status' => _response(
              _material(name: 'Новый'),
              status: 200,
            ),
            'accepted_only' => _response(_material(name: 'Новый'), status: 202),
            'empty' => http.Response('', 201),
            'missing_id' => _response({
              'name': 'Новый',
              'unit': 'шт',
            }, status: 201),
            'missing_full_field' => _response({
              'id': 1,
              'name': 'Новый',
            }, status: 201),
            'wrong_patch_id' => _response(_material(id: 2, unit: 'кг')),
            'wrong_echo' => _response(_material(name: 'Другой'), status: 201),
            _ => http.Response.bytes([0xff], 201),
          };
        });
        addTearDown(api.close);
        await expectLater(
          scenario == 'wrong_patch_id'
              ? api.updateMaterial(1, {'unit': 'кг'})
              : api.createMaterial({'name': 'Новый', 'unit': 'шт'}),
          throwsA(
            isA<ApiException>().having(
              (error) => error.requestMayHaveSucceeded,
              'uncertain',
              true,
            ),
          ),
        );
        expect(calls, 1);
      },
    );
  }

  for (final status in [303, 307, 401, 403, 404, 409, 422, 500]) {
    test('reference HTTP $status keeps its known or unknown outcome', () async {
      var calls = 0;
      final api = _api((_) {
        calls++;
        return _response({'detail': 'Synthetic rejection'}, status: status);
      });
      addTearDown(api.close);
      await expectLater(
        api.createMaterial({'name': 'Новый', 'unit': 'шт'}),
        throwsA(
          _error(status, status >= 500 || (status >= 300 && status < 400)),
        ),
      );
      expect(calls, 1);
    });
  }

  test('admin ACK updates only reference data and leaves drafts/outbox/order history intact', () async {
    final store = MemoryLocalStore();
    final command = OutboxCommand(
      commandId: 'retained-order-command',
      kind: OutboxKind.transition,
      createdAt: 1,
      ownerId: 9,
      serverUrl: _server,
      orderId: 3,
      expectedVersion: 5,
      payload: const {'action': 'start'},
      state: OutboxState.conflict,
    );
    await store.enqueue(command);
    await store.putFormDraft('retained-draft', {
      'state': 'uncertain',
      'text': 'Сохранённый отчёт',
      'expected_version': 5,
    });
    final app = _controller(
      (request) => _response(_material(id: 2, name: 'Новый'), status: 201),
      store: store,
    );
    app.orders = [
      WorkOrder.fromJson({
        'id': 3,
        'version': 5,
        'assignment_history': [
          {'id': 7},
        ],
        'submission_attempts': [],
        'ai_review_job': null,
      }),
    ];
    final order = app.orders.single;
    addTearDown(app.dispose);
    final ticket = app.openReferenceEdit(ReferenceCollection.materials);
    final result = await ticket.submit({'name': 'Новый', 'unit': 'шт'});
    expect(result.status, ReferenceMutationStatus.saved);
    expect(ticket.state, ReferenceEditState.saved);
    expect((app.reference['materials'] as List).last['id'], 2);
    expect(identical(app.orders.single, order), true);
    expect((await store.outbox()).single.toJson(), command.toJson());
    expect(await store.getFormDraft('retained-draft'), {
      'state': 'uncertain',
      'text': 'Сохранённый отчёт',
      'expected_version': 5,
    });
  });

  for (final role in ['master', 'manager', 'worker']) {
    test('$role cannot obtain or submit an admin catalog ticket', () {
      var calls = 0;
      final app = _controller((_) {
        calls++;
        return _response({});
      })..user = User(id: 9, name: 'Synthetic', role: role);
      addTearDown(app.dispose);
      expect(app.canManageReferences, false);
      expect(
        () => app.openReferenceEdit(ReferenceCollection.materials),
        throwsA(_error(403, false)),
      );
      expect(calls, 0);
    });
  }

  test(
    'offline submit preserves editable operation and never enters outbox',
    () async {
      var calls = 0;
      final store = MemoryLocalStore();
      final app = _controller((_) {
        calls++;
        return _response({});
      }, store: store)..offline = true;
      addTearDown(app.dispose);
      final ticket = app.openReferenceEdit(ReferenceCollection.materials);
      expect(
        (await ticket.submit({'name': 'Новый', 'unit': 'шт'})).status,
        ReferenceMutationStatus.offline,
      );
      expect(ticket.state, ReferenceEditState.editing);
      expect(ticket.submittedValues, isNull);
      expect(await store.outbox(), isEmpty);
      expect(calls, 0);
    },
  );

  test('unknown ticket retains immutable fields across GET/reopen and blocks only its operation', () async {
    var posts = 0;
    final app = _controller((request) {
      if (request.method == 'GET') {
        return _response(_reference());
      }
      posts++;
      if (posts == 1) {
        throw http.ClientException('Synthetic lost reply');
      }
      return _response({..._equipment(), ...jsonDecode(request.body) as Json});
    });
    addTearDown(app.dispose);
    final input = <String, dynamic>{'name': 'Новый', 'unit': 'шт'};
    final ticket = app.openReferenceEdit(ReferenceCollection.materials);
    expect(
      (await ticket.submit(input)).status,
      ReferenceMutationStatus.uncertain,
    );
    input['name'] = 'Изменённый ввод';
    expect(ticket.submittedValues!['name'], 'Новый');
    expect(
      () => ticket.submittedValues!['name'] = 'Bypass',
      throwsUnsupportedError,
    );
    expect(
      (await app.refreshReferences(ticket.scope)).status,
      ReferenceRefreshStatus.refreshed,
    );
    final reopened = app.openReferenceEdit(
      ReferenceCollection.materials,
      newOperation: true,
    );
    expect(identical(reopened, ticket), true);
    expect(
      (await reopened.submit({'name': 'Повтор', 'unit': 'шт'})).status,
      ReferenceMutationStatus.uncertain,
    );
    expect(posts, 1);
    final other = app.openReferenceEdit(ReferenceCollection.equipment, id: 1);
    expect(
      (await other.submit({'type': 'Другой тип'})).status,
      ReferenceMutationStatus.saved,
    );
    expect(posts, 2);
  });

  test(
    'unknown PATCH reopens original whole input despite fresh catalog values',
    () async {
      final app = _controller((request) {
        if (request.method == 'PATCH') {
          throw http.ClientException('Synthetic lost reply');
        }
        final current = _reference();
        current['materials'] = [_material(name: 'Другое имя', unit: 'л')];
        return _response(current);
      });
      addTearDown(app.dispose);
      final ticket = app.openReferenceEdit(
        ReferenceCollection.materials,
        id: 1,
      );
      await ticket.submit({'unit': 'кг'});
      await app.refreshReferences(ticket.scope);
      final reopened = app.openReferenceEdit(
        ReferenceCollection.materials,
        id: 1,
        newOperation: true,
      );
      expect({
        ...reopened.initialValues,
        ...reopened.submittedValues!,
      }, _material(unit: 'кг'));
      expect(reopened.state, ReferenceEditState.uncertain);
    },
  );

  test('known rejection permits correction, unlike unknown 5xx', () async {
    var posts = 0;
    final app = _controller((request) {
      posts++;
      if (posts == 1) {
        return _response({'detail': 'Некорректное поле: unit'}, status: 422);
      }
      return _response(_material(name: 'Новый', unit: 'кг'), status: 201);
    });
    addTearDown(app.dispose);
    final ticket = app.openReferenceEdit(ReferenceCollection.materials);
    expect(
      (await ticket.submit({'name': 'Новый', 'unit': 'шт'})).status,
      ReferenceMutationStatus.rejected,
    );
    expect(ticket.state, ReferenceEditState.editing);
    expect(
      (await ticket.submit({'name': 'Новый', 'unit': 'кг'})).status,
      ReferenceMutationStatus.saved,
    );
    expect(posts, 2);
  });

  test('ACK remains saved when subsequent refresh fails; only explicit new operation can create again', () async {
    var posts = 0;
    final app = _controller((request) {
      if (request.method == 'GET') {
        return _response({'detail': 'Synthetic read failure'}, status: 500);
      }
      posts++;
      return _response(_material(id: 2, name: 'Новый'), status: 201);
    });
    addTearDown(app.dispose);
    final ticket = app.openReferenceEdit(ReferenceCollection.materials);
    expect(
      (await ticket.submit({'name': 'Новый', 'unit': 'шт'})).status,
      ReferenceMutationStatus.saved,
    );
    expect(
      (await app.refreshReferences(ticket.scope)).status,
      ReferenceRefreshStatus.failed,
    );
    expect(
      (await ticket.submit({'name': 'Новый', 'unit': 'шт'})).status,
      ReferenceMutationStatus.saved,
    );
    expect(
      identical(app.openReferenceEdit(ReferenceCollection.materials), ticket),
      true,
    );
    expect(
      identical(
        app.openReferenceEdit(
          ReferenceCollection.materials,
          newOperation: true,
        ),
        ticket,
      ),
      false,
    );
    expect(posts, 1);
    expect((app.reference['materials'] as List).last['id'], 2);
  });

  test('double submit and other queue/write operations cannot race reference HTTP lease', () async {
    final gate = Completer<http.Response>();
    var posts = 0;
    final app = _controller((_) {
      posts++;
      return gate.future;
    });
    addTearDown(app.dispose);
    final ticket = app.openReferenceEdit(ReferenceCollection.materials);
    final first = ticket.submit({'name': 'Новый', 'unit': 'шт'});
    expect(
      (await ticket.submit({'name': 'Второй', 'unit': 'шт'})).status,
      ReferenceMutationStatus.busy,
    );
    final other = app.openReferenceEdit(ReferenceCollection.equipment, id: 1);
    expect(
      (await other.submit({'name': 'Изменённое'})).status,
      ReferenceMutationStatus.busy,
    );
    expect(other.submittedValues, isNull);
    expect(
      (await app.inspectCommand('unknown-command')).status,
      QueueRecoveryStatus.busy,
    );
    await expectLater(app.markRead(1), throwsA(_error(409, false)));
    expect(app.referenceWriteBusy, true);
    gate.complete(_response(_material(name: 'Новый'), status: 201));
    expect((await first).status, ReferenceMutationStatus.saved);
    expect(app.referenceWriteBusy, false);
    expect(posts, 1);
  });

  test(
    'current 403 denies catalog scope until login; GET cannot regrant admin',
    () async {
      var calls = 0;
      final app = _controller((_) {
        calls++;
        return _response({'detail': 'Denied'}, status: 403);
      });
      addTearDown(app.dispose);
      final ticket = app.openReferenceEdit(ReferenceCollection.materials);
      expect(
        (await ticket.submit({'name': 'Новый', 'unit': 'шт'})).status,
        ReferenceMutationStatus.rejected,
      );
      expect(app.user?.role, 'admin');
      expect(app.canManageReferences, false);
      expect(app.error, 'Доступ к справочникам отозван. Войдите снова.');
      expect(ticket.isCurrent, false);
      expect(
        (await app.refreshReferences(ticket.scope)).status,
        ReferenceRefreshStatus.scopeChanged,
      );
      expect(
        () => app.openReferenceEdit(ReferenceCollection.materials),
        throwsA(_error(403, false)),
      );
      expect(calls, 1);
    },
  );

  for (final change in ['ABA', 'close', 'role', 'api']) {
    test(
      'late $change response cannot apply ACK, deny a new scope or notify it',
      () async {
        final gate = Completer<http.Response>();
        final app = _controller((_) => gate.future);
        addTearDown(app.dispose);
        final ticket = app.openReferenceEdit(ReferenceCollection.materials);
        final future = ticket.submit({'name': 'Новый', 'unit': 'шт'});
        switch (change) {
          case 'ABA':
            app.api.token = 'other';
            app.api.token = 'synthetic-session';
          case 'close':
            app.api.close();
          case 'role':
            app.user = const User(id: 9, name: 'Synthetic', role: 'master');
          case 'api':
            app.api = _api((_) => _response(_reference()));
        }
        var notifications = 0;
        app.addListener(() => notifications++);
        app.reference = {'new_scope': true};
        gate.complete(_response({'detail': 'Old denied'}, status: 403));
        expect((await future).status, ReferenceMutationStatus.scopeChanged);
        expect(app.reference, {'new_scope': true});
        expect(notifications, 0);
        expect(app.saving, false);
        expect(app.referenceWriteBusy, false);
        if (change == 'ABA' || change == 'api') {
          expect(app.canManageReferences, true);
        }
      },
    );
  }

  test('read started before ACK cannot overwrite its new row', () async {
    final gate = Completer<http.Response>();
    final app = _controller(
      (request) => request.method == 'GET'
          ? gate.future
          : _response(_material(id: 2, name: 'Новый'), status: 201),
    );
    addTearDown(app.dispose);
    final scope = app.captureReferenceScope();
    final oldRead = app.refreshReferences(scope);
    final ticket = app.openReferenceEdit(ReferenceCollection.materials);
    expect(
      (await ticket.submit({'name': 'Новый', 'unit': 'шт'})).status,
      ReferenceMutationStatus.saved,
    );
    gate.complete(_response(_reference()));
    expect((await oldRead).status, ReferenceRefreshStatus.failed);
    expect((app.reference['materials'] as List).last['id'], 2);
  });

  test('malformed or partial catalog refresh keeps an acknowledged row and complete old cache', () async {
    final bodies = <Json>[
      {'areas': [], 'equipment': [], 'materials': []},
      {
        ..._reference(),
        'equipment': [{}],
      },
      {
        ..._reference(),
        'materials': [
          {'id': 'not-an-id', 'name': 'Broken', 'unit': 'шт'},
        ],
      },
      {
        ..._reference(),
        'areas': [
          {'id': 1},
        ],
      },
    ];
    final app = _controller(
      (request) => request.method == 'GET'
          ? _response(bodies.removeAt(0))
          : _response(_material(id: 2, name: 'Новый'), status: 201),
    );
    addTearDown(app.dispose);
    final ticket = app.openReferenceEdit(ReferenceCollection.materials);
    expect(
      (await ticket.submit({'name': 'Новый', 'unit': 'шт'})).status,
      ReferenceMutationStatus.saved,
    );
    final expected = jsonEncode(app.reference);
    for (var i = 0; i < 4; i++) {
      expect(
        (await app.refreshReferences(ticket.scope)).status,
        ReferenceRefreshStatus.failed,
      );
      expect(jsonEncode(app.reference), expected);
      expect(ticket.state, ReferenceEditState.saved);
    }
    expect(identical(app.captureReferenceScope(), ticket.scope), true);
  });
}
