import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/app_controller.dart';
import 'package:naryad_ai/data/local_store.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/data/order_journal.dart';
import 'package:naryad_ai/data/order_journal_controller.dart';
import 'package:naryad_ai/screens/order_journal_screen.dart';

Json _order(int id, {String title = 'Ремонт насоса'}) => {
  'id': id,
  'version': 3,
  'number': 'ЖУРНАЛ-$id',
  'title': title,
  'description': 'Ремонт',
  'status': 'closed',
  'priority': 'normal',
  'work_type': 'planned',
  'normal_hours': 2,
  'deadline': '2026-10-08T18:00:00Z',
  'assignee_id': 7,
  'assignee_name': 'Ответственный',
  'equipment_id': 11,
  'equipment_name': 'Насос',
  'area_name': 'Цех',
};
Json _page(List<int> ids, {String? cursor, int? total}) => {
  'items': ids.map(_order).toList(),
  'next_cursor': cursor,
  'total': total ?? ids.length,
};
Json get _equipment => {
  'id': 11,
  'name': 'Насос НС-11',
  'inventory_number': 'КМ-11',
  'area_id': 2,
  'area_name': 'Цех',
  'type': 'Насос',
  'criticality': 'high',
};
http.Response _response(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
AppController _app(
  Future<http.Response> Function(http.Request) handler, {
  String role = 'master',
}) {
  final api = NaryadApi('http://journal.test', client: MockClient(handler))
    ..token = 'synthetic-journal-session';
  return AppController(api: api, localStore: MemoryLocalStore())
    ..user = User(id: 7, name: 'Пользователь', role: role)
    ..orders = [WorkOrder.fromJson(_order(99, title: 'Сохранённый наряд'))];
}

void main() {
  test(
    'Typed page sends all filters with literal search and encoded cursor',
    () async {
      http.Request? sent;
      final api = NaryadApi(
        'http://journal.test',
        client: MockClient((request) async {
          sent = request;
          return _response(_page([1], cursor: 'next-page', total: 3));
        }),
      )..token = 'synthetic-token';
      final result = await api.ordersPage(
        const OrderJournalQuery(
          scope: 'closed',
          focus: 'rejected',
          sort: 'priority',
          search: 'Насос_%  Иван',
          equipmentId: 11,
          areaId: 2,
          assigneeId: 7,
          brigadeId: 4,
          priority: 'high',
          status: 'rejected',
          fromDate: '2026-01-01',
          toDate: '2026-10-08',
        ),
        cursor: 'opaque+/=cursor',
        limit: 200,
      );
      expect(sent!.url.path, '/api/orders/page');
      expect(sent!.url.queryParameters, {
        'limit': '200',
        'scope': 'closed',
        'focus': 'rejected',
        'sort': 'priority',
        'search': 'Насос_%  Иван',
        'equipment_id': '11',
        'area_id': '2',
        'assignee_id': '7',
        'brigade_id': '4',
        'priority': 'high',
        'status': 'rejected',
        'from_date': '2026-01-01',
        'to_date': '2026-10-08',
        'cursor': 'opaque+/=cursor',
      });
      expect(result.items.single.id, 1);
      expect(result.nextCursor, 'next-page');
      expect(result.total, 3);
    },
  );

  test(
    'Malformed pagination and mismatched equipment are visible protocol errors',
    () async {
      final api = NaryadApi(
        'http://journal.test',
        client: MockClient(
          (request) async => _response(
            request.url.path.contains('equipment')
                ? {..._equipment, 'id': 12}
                : {
                    ..._page([1]),
                    'total': '1',
                  },
          ),
        ),
      );
      await expectLater(
        api.ordersPage(const OrderJournalQuery()),
        throwsA(isA<ApiException>()),
      );
      await expectLater(api.equipmentDetails(11), throwsA(isA<ApiException>()));
      await expectLater(
        api.ordersPage(const OrderJournalQuery(), limit: 201),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 422)),
      );
    },
  );

  test(
    'Multiple pages deduplicate IDs and do not replace the operative cache',
    () async {
      final requests = <http.Request>[];
      final app = _app((request) async {
        requests.add(request);
        return _response(
          request.url.queryParameters['cursor'] == null
              ? _page([3, 2], cursor: 'page-two', total: 3)
              : {
                  'items': [
                    {..._order(2, title: 'Устаревший дубль'), 'version': 1},
                    _order(1),
                  ],
                  'next_cursor': null,
                  'total': 3,
                },
        );
      });
      final journal = OrderJournalController(app);
      addTearDown(journal.dispose);
      addTearDown(app.dispose);
      final cached = app.orders;
      await journal.refresh();
      await journal.loadMore();
      expect(journal.items.map((o) => o.id), [3, 2, 1]);
      expect(journal.items[1].version, 3);
      expect(journal.items[1].title, 'Ремонт насоса');
      expect(journal.nextCursor, isNull);
      expect(journal.total, 3);
      expect(identical(app.orders, cached), true);
      expect(app.orders.single.title, 'Сохранённый наряд');
      expect(app.outbox, isEmpty);
      expect(requests.last.url.queryParameters['cursor'], 'page-two');
      expect(
        requests.first.url.queryParameters.containsKey('from_date'),
        false,
      );
    },
  );

  test('Changing filters resets cursor and late old pages cannot replace new results', () async {
    final latePage = Completer<http.Response>();
    final started = Completer<void>();
    final requests = <http.Request>[];
    final app = _app((request) async {
      requests.add(request);
      if (request.url.queryParameters['cursor'] == 'old-page-two') {
        started.complete();
        return latePage.future;
      }
      return _response(
        request.url.queryParameters['search'] == 'новый'
            ? _page([8])
            : _page([3], cursor: 'old-page-two', total: 2),
      );
    });
    final journal = OrderJournalController(app);
    addTearDown(journal.dispose);
    addTearDown(app.dispose);
    await journal.refresh();
    final old = journal.loadMore();
    await started.future;
    await journal.replaceQuery(
      const OrderJournalQuery(search: 'новый', scope: 'active'),
    );
    latePage.complete(_response(_page([2])));
    await old;
    expect(journal.items.single.id, 8);
    expect(journal.nextCursor, isNull);
    expect(requests.last.url.queryParameters.containsKey('cursor'), false);
    expect(journal.loading, false);
  });

  test(
    'Token or user change clears pages and discards an in-flight response',
    () async {
      final latePage = Completer<http.Response>();
      final started = Completer<void>();
      var calls = 0;
      final app = _app((request) async {
        if (++calls == 1) {
          return _response(_page([3], cursor: 'old-session-cursor', total: 2));
        }
        started.complete();
        return latePage.future;
      });
      final journal = OrderJournalController(app);
      addTearDown(journal.dispose);
      addTearDown(app.dispose);
      await journal.refresh();
      final loading = journal.loadMore();
      await started.future;
      app.api.token = 'synthetic-new-session';
      app.user = const User(id: 8, name: 'Другой аккаунт', role: 'worker');
      app.notifyListeners();
      latePage.complete(_response(_page([2])));
      await loading;
      expect(journal.items, isEmpty);
      expect(journal.nextCursor, isNull);
      expect(journal.total, isNull);
      expect(journal.loading, false);
      expect(app.user!.id, 8);
    },
  );

  test(
    'Same-session polling keeps cursor; failures keep already loaded rows',
    () async {
      var fail = false;
      final requests = <http.Request>[];
      final app = _app((request) async {
        requests.add(request);
        if (fail) throw http.ClientException('Synthetic offline');
        return _response(_page([3], cursor: 'stable-cursor', total: 2));
      });
      final journal = OrderJournalController(app);
      addTearDown(journal.dispose);
      addTearDown(app.dispose);
      await journal.refresh();
      app.notifyListeners();
      fail = true;
      await journal.loadMore();
      expect(requests.last.url.queryParameters['cursor'], 'stable-cursor');
      expect(journal.items.single.id, 3);
      expect(journal.nextCursor, 'stable-cursor');
      expect(journal.error, isNotNull);
      await journal.refresh();
      expect(requests.last.url.queryParameters.containsKey('cursor'), false);
      expect(journal.items.single.id, 3);
    },
  );

  test('Offline journal does not invent uncached server history', () async {
    var calls = 0;
    final app = _app((request) async {
      calls++;
      return _response(_page([3]));
    })..offline = true;
    final journal = OrderJournalController(app);
    addTearDown(journal.dispose);
    addTearDown(app.dispose);
    await journal.refresh();
    expect(calls, 0);
    expect(journal.items, isEmpty);
    expect(journal.total, isNull);
    expect(journal.error, contains('Полная серверная история недоступна'));
    expect(app.orders.single.id, 99);
  });

  test(
    'Changing filters while offline cancels an old load and clears the spinner',
    () async {
      final latePage = Completer<http.Response>();
      final started = Completer<void>();
      var calls = 0;
      final app = _app((request) async {
        calls++;
        started.complete();
        return latePage.future;
      });
      final journal = OrderJournalController(app);
      addTearDown(journal.dispose);
      addTearDown(app.dispose);
      final oldLoad = journal.refresh();
      await started.future;
      expect(journal.loading, true);
      app.offline = true;
      await journal.replaceQuery(
        const OrderJournalQuery(search: 'Другой фильтр'),
      );
      expect(journal.loading, false);
      expect(journal.error, contains('Полная серверная история недоступна'));
      expect(calls, 1);
      latePage.complete(
        _response(_page([1], cursor: 'stale-cursor', total: 2)),
      );
      await oldLoad;
      expect(journal.loading, false);
      expect(journal.items, isEmpty);
      expect(journal.nextCursor, isNull);
      expect(journal.total, isNull);
      expect(app.orders.single.id, 99);
    },
  );

  test('Equipment history fetches metadata without imposing a period; worker is blocked locally', () async {
    for (final role in ['master', 'manager', 'admin', 'worker']) {
      final requests = <http.Request>[];
      final app = _app((request) async {
        requests.add(request);
        return _response(
          request.url.path == '/api/equipment/11' ? _equipment : _page([3]),
        );
      }, role: role);
      final journal = OrderJournalController(
        app,
        equipmentHistory: true,
        query: const OrderJournalQuery(equipmentId: 11),
      );
      await journal.refresh();
      if (role == 'worker') {
        expect(requests, isEmpty);
        expect(journal.equipment, isNull);
        expect(journal.allowed, false);
      } else {
        expect(journal.equipment!.inventoryNumber, 'КМ-11');
        expect(journal.items.single.id, 3);
        expect(requests.last.url.queryParameters['equipment_id'], '11');
        expect(
          requests.last.url.queryParameters.containsKey('from_date'),
          false,
        );
        expect(requests.last.url.queryParameters['scope'], 'all');
      }
      journal.dispose();
      app.dispose();
    }
  });

  testWidgets(
    'Journal shows first page and load-more, while worker metadata route stays closed',
    (tester) async {
      final app = _app(
        (request) async => _response(
          request.url.queryParameters['cursor'] == null
              ? _page([3], cursor: 'widget-next', total: 2)
              : _page([2], total: 2),
        ),
        role: 'worker',
      );
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(home: OrderJournalScreen(controller: app)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Полный журнал'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Загрузить ещё'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Загрузить ещё'));
      await tester.tap(find.text('Загрузить ещё'));
      await tester.pumpAndSettle();
      expect(find.text('Загружено: 2 · найдено: 2'), findsOneWidget);
      expect(app.orders.single.id, 99);
      await tester.pumpWidget(
        MaterialApp(
          home: OrderJournalScreen(
            controller: app,
            equipmentId: 11,
            key: const ValueKey('protected'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Недостаточно прав для этого журнала.'), findsOneWidget);
      expect(find.text('Насос НС-11'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
}
