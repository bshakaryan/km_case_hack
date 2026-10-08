import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:naryad_ai/data/api.dart';
import 'package:naryad_ai/data/models.dart';
import 'package:naryad_ai/data/order_journal.dart';

const _firstTag = '"synthetic-orders-first"';
const _nextTag = '"synthetic-orders-next"';
const _closedHeader = 'Connection closed before full header was received';

List<Json> _body([int version = 1]) => [
  {
    'id': 1,
    'version': version,
    'title': 'Synthetic work',
    'participants': [
      {'employee_id': 6, 'name': 'Synthetic participant'},
    ],
    'report': {
      'materials': [
        {'material_id': 1, 'quantity': 2},
      ],
    },
  },
];

http.StreamedResponse _response(
  Object? body, {
  int status = 200,
  String? etag = _firstTag,
}) => http.StreamedResponse(
  Stream.value(body == null ? <int>[] : utf8.encode(jsonEncode(body))),
  status,
  headers: {'content-type': 'application/json; charset=utf-8', 'etag': ?etag},
);

class _Transport extends http.BaseClient {
  _Transport(this.handler);
  final FutureOr<http.StreamedResponse> Function(http.BaseRequest, int) handler;
  final List<http.BaseRequest> requests = [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return handler(request, requests.length);
  }

  @override
  void close() {}
}

TypeMatcher<ApiException> _apiError(int status) => isA<ApiException>()
    .having((e) => e.statusCode, 'status', status)
    .having((e) => e.requestMayHaveSucceeded, 'read outcome', false);

Matcher _staleRead() => _apiError(
  409,
).having((e) => e.code, 'client context cancellation', 'read_context_changed');

void main() {
  test('200 then matching empty 304 keeps complete list and sends only existing query', () async {
    final transport = _Transport((request, attempt) {
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'http://fixture.test/api/orders?limit=5000',
      );
      expect(request.headers['authorization'], 'Bearer synthetic-authority');
      expect(request.headers['if-none-match'], attempt == 1 ? null : _firstTag);
      return attempt == 1 ? _response(_body()) : _response(null, status: 304);
    });
    final api = NaryadApi('http://fixture.test', client: transport)
      ..token = 'synthetic-authority';
    addTearDown(api.close);
    expect(await api.orders(), _body());
    expect(await api.orders(), _body());
    expect(await api.orders(), _body());
    expect(transport.requests, hasLength(3));
  });

  test(
    'changed 200 replaces tag/body and later 304 returns the changed version',
    () async {
      final transport = _Transport((request, attempt) {
        if (attempt == 1) return _response(_body());
        expect(
          request.headers['if-none-match'],
          attempt == 2 ? _firstTag : _nextTag,
        );
        return attempt == 2
            ? _response(_body(2), etag: _nextTag)
            : _response(null, status: 304, etag: _nextTag);
      });
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      await api.orders();
      expect((await api.orders()).single['version'], 2);
      expect((await api.orders()).single['version'], 2);
    },
  );

  test(
    'caller mutation of 200 and 304 nested data never changes cached body',
    () async {
      final transport = _Transport(
        (_, attempt) =>
            attempt == 1 ? _response(_body()) : _response(null, status: 304),
      );
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      final first = await api.orders();
      ((first.single['participants'] as List).single as Json)['name'] =
          'Changed by caller';
      ((first.single['report'] as Json)['materials'] as List).clear();
      first.add({'id': 99});
      final second = await api.orders();
      expect(second, _body());
      second.single['title'] = 'Changed again';
      (second.single['participants'] as List).clear();
      expect(await api.orders(), _body());
    },
  );

  for (final invalidTag in <String?>[null, 'unquoted', 'W/invalid']) {
    test(
      'valid 200 with missing/malformed ETag clears preceding tag: $invalidTag',
      () async {
        final transport = _Transport((request, attempt) {
          if (attempt == 1) return _response(_body());
          expect(
            request.headers['if-none-match'],
            attempt == 2 ? _firstTag : null,
          );
          return _response(_body(2), etag: invalidTag);
        });
        final api = NaryadApi('http://fixture.test', client: transport);
        addTearDown(api.close);
        await api.orders();
        expect(await api.orders(), _body(2));
        expect(await api.orders(), _body(2));
      },
    );
  }

  test(
    'uncached unsolicited 304 is an explicit error with no refetch',
    () async {
      final transport = _Transport((request, _) {
        expect(request.headers['if-none-match'], isNull);
        return _response(null, status: 304);
      });
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      await expectLater(api.orders(), throwsA(_apiError(304)));
      expect(transport.requests, hasLength(1));
    },
  );

  for (final invalid304 in [
    'missing_tag',
    'different_tag',
    'unexpected_body',
  ]) {
    test(
      '304 $invalid304 rejects cache fallback and next call is unconditional',
      () async {
        final transport = _Transport((request, attempt) {
          if (attempt == 1) return _response(_body());
          if (attempt == 2) {
            return _response(
              invalid304 == 'unexpected_body' ? _body() : null,
              status: 304,
              etag: invalid304 == 'missing_tag'
                  ? null
                  : invalid304 == 'different_tag'
                  ? _nextTag
                  : _firstTag,
            );
          }
          expect(request.headers['if-none-match'], isNull);
          return _response(_body(2), etag: _nextTag);
        });
        final api = NaryadApi('http://fixture.test', client: transport);
        addTearDown(api.close);
        await api.orders();
        await expectLater(api.orders(), throwsA(_apiError(304)));
        expect(transport.requests, hasLength(2));
        expect(await api.orders(), _body(2));
      },
    );
  }

  for (final status in [401, 403, 404, 500]) {
    test(
      'conditional HTTP $status remains visible and never returns old cache',
      () async {
        final transport = _Transport((request, attempt) {
          if (attempt == 1) return _response(_body());
          if (attempt == 2) {
            expect(request.headers['if-none-match'], _firstTag);
            return _response({'detail': 'Synthetic rejection'}, status: status);
          }
          expect(request.headers['if-none-match'], isNull);
          return _response(_body(2), etag: _nextTag);
        });
        final api = NaryadApi('http://fixture.test', client: transport);
        addTearDown(api.close);
        await api.orders();
        await expectLater(api.orders(), throwsA(_apiError(status)));
        expect(transport.requests, hasLength(2));
        expect(await api.orders(), _body(2));
      },
    );
  }

  for (final malformed in ['json', 'shape']) {
    test(
      'malformed 200 $malformed is never replaced by preceding cached body',
      () async {
        final transport = _Transport((request, attempt) {
          if (attempt == 1) return _response(_body());
          if (attempt == 2) {
            return malformed == 'json'
                ? http.StreamedResponse(
                    Stream.value(utf8.encode('{')),
                    200,
                    headers: {'etag': _nextTag},
                  )
                : _response({'items': _body(2)}, etag: _nextTag);
          }
          expect(request.headers['if-none-match'], isNull);
          return _response(_body(2), etag: _nextTag);
        });
        final api = NaryadApi('http://fixture.test', client: transport);
        addTearDown(api.close);
        await api.orders();
        await expectLater(api.orders(), throwsA(_apiError(200)));
        expect(await api.orders(), _body(2));
      },
    );
  }

  test(
    'transport failure remains visible without stale cache recovery',
    () async {
      final transport = _Transport((request, attempt) {
        if (attempt == 1) return _response(_body());
        if (attempt == 2) throw http.ClientException('Synthetic disconnected');
        expect(request.headers['if-none-match'], isNull);
        return _response(_body(2), etag: _nextTag);
      });
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      await api.orders();
      await expectLater(api.orders(), throwsA(_apiError(0)));
      expect(transport.requests, hasLength(2));
      expect(await api.orders(), _body(2));
    },
  );

  test('bounded preheader retry preserves captured conditional header and cached body', () async {
    final transport = _Transport((request, attempt) async {
      if (attempt == 1) return _response(_body());
      expect(request.headers['if-none-match'], _firstTag);
      if (attempt == 2) {
        await request.finalize().drain<void>();
        throw http.ClientException(_closedHeader);
      }
      return _response(null, status: 304);
    });
    final api = NaryadApi('http://fixture.test', client: transport);
    addTearDown(api.close);
    await api.orders();
    expect(await api.orders(), _body());
    expect(transport.requests, hasLength(3));
  });

  test(
    'only orders uses conditional HTTP; generic reads still reject 304',
    () async {
      final transport = _Transport((request, attempt) {
        if (attempt == 1) return _response(_body());
        expect(request.headers['if-none-match'], isNull);
        return _response(null, status: 304);
      });
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      await api.orders();
      await expectLater(api.reference(), throwsA(_apiError(304)));
      await expectLater(api.order(1), throwsA(_apiError(304)));
      await expectLater(
        api.ordersPage(const OrderJournalQuery()),
        throwsA(_apiError(304)),
      );
      expect(transport.requests, hasLength(4));
    },
  );

  test(
    'token changes and same-value re-login assignment clear authority cache',
    () async {
      final transport = _Transport((request, _) {
        expect(request.headers['if-none-match'], isNull);
        return _response(_body());
      });
      final api = NaryadApi('http://fixture.test', client: transport)
        ..token = 'synthetic-a';
      addTearDown(api.close);
      await api.orders();
      api.token = 'synthetic-b';
      await api.orders();
      api.token = 'synthetic-b';
      await api.orders();
      expect(transport.requests.map((r) => r.headers['authorization']), [
        'Bearer synthetic-a',
        'Bearer synthetic-b',
        'Bearer synthetic-b',
      ]);
    },
  );

  for (final oldReply in ['200', '304', '401', 'preheader_close']) {
    test(
      'late $oldReply across token ABA cannot take new authority cache/auth',
      () async {
        final old = Completer<http.StreamedResponse>();
        final transport = _Transport((request, attempt) {
          if (attempt == 1) return _response(_body());
          if (attempt == 2) return old.future;
          if (attempt == 3) {
            expect(request.headers['if-none-match'], isNull);
            return _response(_body(2), etag: _nextTag);
          }
          expect(request.headers['if-none-match'], _nextTag);
          return _response(null, status: 304, etag: _nextTag);
        });
        final api = NaryadApi('http://fixture.test', client: transport)
          ..token = 'synthetic-a';
        addTearDown(api.close);
        await api.orders();
        final assertion = expectLater(api.orders(), throwsA(_staleRead()));
        await Future<void>.delayed(Duration.zero);
        api.token = 'synthetic-b';
        api.token = 'synthetic-a';
        expect(await api.orders(), _body(2));
        switch (oldReply) {
          case '200':
            old.complete(_response(_body()));
          case '304':
            old.complete(_response(null, status: 304));
          case '401':
            old.complete(
              _response({'detail': 'Old authority expired'}, status: 401),
            );
          case 'preheader_close':
            old.completeError(http.ClientException(_closedHeader));
        }
        await assertion;
        expect(api.token, 'synthetic-a');
        expect(await api.orders(), _body(2));
        expect(
          transport.requests,
          hasLength(4),
          reason: 'An old authority must not retry or poison the newer ETag.',
        );
      },
    );
  }

  test('API close fences a late 200 body', () async {
    final gate = Completer<http.StreamedResponse>();
    final transport = _Transport((_, _) => gate.future);
    final api = NaryadApi('http://fixture.test', client: transport);
    final assertion = expectLater(api.orders(), throwsA(_staleRead()));
    await Future<void>.delayed(Duration.zero);
    api.close();
    gate.complete(_response(_body()));
    await assertion;
    expect(transport.requests, hasLength(1));
  });

  test('cache belongs to API instance and complete URI, never another server prefix', () async {
    final sources = <_Transport>[];
    for (final base in [
      'http://fixture.test/api',
      'http://fixture.test/api',
      'http://fixture.test/tenant/api',
    ]) {
      final transport = _Transport((request, _) {
        expect(request.headers['if-none-match'], isNull);
        expect(request.url.toString(), '$base/orders?limit=5000');
        return _response(_body());
      });
      final api = NaryadApi(base, client: transport)
        ..token = 'synthetic-authority';
      addTearDown(api.close);
      expect(await api.orders(), _body());
      sources.add(transport);
    }
    expect(sources.map((t) => t.requests.length), [1, 1, 1]);
  });

  test(
    'late older same-authority 200 does not replace a newer request cache',
    () async {
      final old = Completer<http.StreamedResponse>();
      final transport = _Transport((request, attempt) {
        if (attempt == 1) return old.future;
        if (attempt == 2) return _response(_body(2), etag: _nextTag);
        expect(request.headers['if-none-match'], _nextTag);
        return _response(null, status: 304, etag: _nextTag);
      });
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      final previous = api.orders();
      expect(await api.orders(), _body(2));
      old.complete(_response(_body()));
      expect(await previous, _body());
      expect(await api.orders(), _body(2));
    },
  );

  for (final invalidated in [false, true]) {
    test(
      'late 304 cannot reuse a ${invalidated ? 'removed' : 'replaced'} representation',
      () async {
        final old = Completer<http.StreamedResponse>();
        final transport = _Transport((request, attempt) {
          if (attempt == 1) return _response(_body());
          if (attempt == 2) return old.future;
          if (attempt == 3) {
            return invalidated
                ? _response({
                    'detail': 'Synthetic access rejection',
                  }, status: 403)
                : _response(_body(2), etag: _nextTag);
          }
          expect(
            request.headers['if-none-match'],
            invalidated ? null : _nextTag,
          );
          return invalidated
              ? _response(_body(2), etag: _nextTag)
              : _response(null, status: 304, etag: _nextTag);
        });
        final api = NaryadApi('http://fixture.test', client: transport);
        addTearDown(api.close);
        await api.orders();
        final previous = expectLater(api.orders(), throwsA(_apiError(304)));
        await Future<void>.delayed(Duration.zero);
        if (invalidated) {
          await expectLater(api.orders(), throwsA(_apiError(403)));
        } else {
          expect(await api.orders(), _body(2));
        }
        old.complete(_response(null, status: 304));
        await previous;
        expect(await api.orders(), _body(2));
        expect(transport.requests, hasLength(4));
      },
    );
  }
}
