import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:naryad_ai/data/api.dart';

const _closedHeader = 'Connection closed before full header was received';

class _Transport extends http.BaseClient {
  _Transport(this.handler);
  final FutureOr<http.StreamedResponse> Function(http.BaseRequest, int) handler;
  final List<http.BaseRequest> requests = [];
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return handler(request, requests.length);
  }

  @override
  void close() => closed = true;
}

http.StreamedResponse _json(Object value, [int status = 200]) =>
    http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(value))),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

Matcher _apiError(int status, {bool uncertain = false}) => isA<ApiException>()
    .having((e) => e.statusCode, 'status', status)
    .having(
      (e) => e.requestMayHaveSucceeded,
      'unknown write outcome',
      uncertain,
    );

void main() {
  for (final message in [
    _closedHeader,
    'Connection closed before response was received',
    'Connection closed before data was received',
  ]) {
    test('bodyless GET retries known preheader close: $message', () async {
      final transport = _Transport((request, attempt) async {
        if (attempt == 1) {
          // An interceptor's mutable source is deliberately corrupted after
          // capture. A replay must use the pre-send authority/options snapshot.
          request
            ..followRedirects = false
            ..maxRedirects = 1
            ..persistentConnection = false;
          await request.finalize().drain<void>();
          request.headers['accept'] = 'changed-after-send';
          request.headers['authorization'] = 'changed-after-send';
          throw http.ClientException(message, request.url);
        }
        expect(request.method, 'GET');
        expect(request.url.toString(), 'http://fixture.test/api/reference');
        expect(request.headers['accept'], 'application/json');
        expect(request.headers['authorization'], 'Bearer synthetic-original');
        expect(request.followRedirects, isTrue);
        expect(request.maxRedirects, 5);
        expect(request.persistentConnection, isTrue);
        expect(request.contentLength, 0);
        expect(request.finalized, isFalse);
        return _json({'areas': <Object>[]});
      });
      final api = NaryadApi('http://fixture.test', client: transport)
        ..token = 'synthetic-original';
      addTearDown(api.close);
      expect(await api.reference(), {'areas': <Object>[]});
      expect(transport.requests, hasLength(2));
      expect(
        identical(transport.requests.first, transport.requests.last),
        isFalse,
      );
      expect(transport.requests.first.finalized, isTrue);
    });
  }

  test('a second preheader failure ends the single read retry', () async {
    final transport = _Transport((request, _) async {
      await request.finalize().drain<void>();
      throw http.ClientException(_closedHeader, request.url);
    });
    final api = NaryadApi('http://fixture.test', client: transport);
    addTearDown(api.close);
    await expectLater(api.reference(), throwsA(_apiError(0)));
    expect(transport.requests, hasLength(2));
  });

  for (final status in [401, 403, 404, 500]) {
    test('HTTP $status is never retried', () async {
      final transport = _Transport(
        (_, _) => _json({'detail': 'Synthetic rejection'}, status),
      );
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      await expectLater(api.reference(), throwsA(_apiError(status)));
      expect(transport.requests, hasLength(1));
    });
  }

  for (final status in [401, 403]) {
    test(
      'single transport retry surfaces HTTP $status without a third attempt',
      () async {
        final transport = _Transport((_, attempt) {
          if (attempt == 1) throw http.ClientException(_closedHeader);
          return _json({'detail': 'Synthetic rejection'}, status);
        });
        final api = NaryadApi('http://fixture.test', client: transport);
        addTearDown(api.close);
        await expectLater(api.reference(), throwsA(_apiError(status)));
        expect(transport.requests, hasLength(2));
      },
    );
  }

  for (final message in [
    'Disconnected',
    'HTTP request failed. Client is already closed.',
  ]) {
    test('other ClientException is not a keepalive retry: $message', () async {
      final transport = _Transport(
        (_, _) => throw http.ClientException(message),
      );
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      await expectLater(api.reference(), throwsA(_apiError(0)));
      expect(transport.requests, hasLength(1));
    });
  }

  test('transport timeout never retries', () async {
    final transport = _Transport(
      (_, _) => throw TimeoutException('Synthetic timeout'),
    );
    final api = NaryadApi('http://fixture.test', client: transport);
    addTearDown(api.close);
    await expectLater(api.reference(), throwsA(_apiError(0)));
    expect(transport.requests, hasLength(1));
  });

  test('a body error after HTTP 200 headers never retries even with a known message', () async {
    final transport = _Transport(
      (_, _) => http.StreamedResponse(
        Stream<List<int>>.error(http.ClientException(_closedHeader)),
        200,
      ),
    );
    final api = NaryadApi('http://fixture.test', client: transport);
    addTearDown(api.close);
    await expectLater(api.reference(), throwsA(_apiError(0)));
    expect(transport.requests, hasLength(1));
  });

  test(
    'source GET acquiring a body cannot be replaced by an empty replay',
    () async {
      final transport = _Transport((request, _) async {
        (request as http.Request).body = 'synthetic source body';
        await request.finalize().drain<void>();
        throw http.ClientException(_closedHeader);
      });
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      await expectLater(api.reference(), throwsA(_apiError(0)));
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'lost completion headers never repeat POST or change key/basis/report',
    () async {
      final completion = {
        'work_done': 'Synthetic retained repair',
        'materials': [
          {'material_id': 1, 'quantity': 2},
        ],
        'fault_code_id': 1,
      };
      final transport = _Transport((request, _) async {
        expect(request.method, 'POST');
        expect(
          request.headers['x-client-command-id'],
          'synthetic-completion-key',
        );
        expect(request.headers['x-expected-order-version'], '7');
        expect(jsonDecode((request as http.Request).body), completion);
        await request.finalize().drain<void>();
        throw http.ClientException(_closedHeader);
      });
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      await expectLater(
        api.complete(
          1,
          completion,
          commandId: 'synthetic-completion-key',
          expectedVersion: 7,
        ),
        throwsA(_apiError(0, uncertain: true)),
      );
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'lost multipart upload headers keep unknown outcome without resend',
    () async {
      final transport = _Transport((request, _) async {
        expect(request, isA<http.MultipartRequest>());
        expect(request.method, 'POST');
        expect(request.headers['x-client-command-id'], 'synthetic-photo-key');
        expect(
          request.headers['x-previous-client-command-id'],
          'synthetic-start-key',
        );
        final bytes = await request.finalize().toBytes();
        expect(bytes, isNotEmpty);
        throw http.ClientException(_closedHeader);
      });
      final api = NaryadApi('http://fixture.test', client: transport);
      addTearDown(api.close);
      await expectLater(
        api.uploadPhoto(
          1,
          Uint8List.fromList([1, 2, 3]),
          'synthetic.png',
          'after',
          commandId: 'synthetic-photo-key',
          previousCommandId: 'synthetic-start-key',
        ),
        throwsA(_apiError(0, uncertain: true)),
      );
      expect(transport.requests, hasLength(1));
    },
  );

  for (final closeApi in [false, true]) {
    test(
      'late preheader failure does not retry after ${closeApi ? 'API close' : 'token change'}',
      () async {
        final gate = Completer<http.StreamedResponse>();
        final transport = _Transport((_, _) => gate.future);
        final api = NaryadApi('http://fixture.test', client: transport)
          ..token = 'synthetic-original';
        addTearDown(api.close);
        final assertion = expectLater(api.reference(), throwsA(_apiError(0)));
        await Future<void>.delayed(Duration.zero);
        if (closeApi) {
          api.close();
        } else {
          api.token = 'synthetic-new-session';
        }
        gate.completeError(http.ClientException(_closedHeader));
        await assertion;
        expect(transport.requests, hasLength(1));
      },
    );
  }

  test('two read attempts share eight seconds and late original failure cannot spawn retry', () async {
    // One real eight-second boundary covers both the aggregate deadline and
    // Future.timeout's non-cancellation edge. No production test-only budget.
    final lateOriginal = Completer<http.StreamedResponse>();
    final blockedRetry = Completer<http.StreamedResponse>();
    final attempts = <String, int>{};
    final transport = _Transport((request, _) async {
      final path = request.url.path;
      attempts[path] = (attempts[path] ?? 0) + 1;
      if (path.endsWith('/reference')) return lateOriginal.future;
      if (attempts[path] == 1) {
        await Future<void>.delayed(const Duration(seconds: 5));
        throw http.ClientException(_closedHeader);
      }
      return blockedRetry.future;
    });
    final api = NaryadApi('http://fixture.test', client: transport);
    addTearDown(api.close);
    final reference = api.reference();
    final dashboard = api.dashboard();
    await Future.wait([
      expectLater(
        reference.timeout(const Duration(seconds: 10)),
        throwsA(_apiError(0)),
      ),
      expectLater(
        dashboard.timeout(const Duration(seconds: 10)),
        throwsA(_apiError(0)),
      ),
    ]);
    // The abandoned first read now fails after its original eight-second cap.
    // A retry here would be an extra background request after caller timeout.
    lateOriginal.completeError(http.ClientException(_closedHeader));
    blockedRetry.complete(_json({'issued': 1}));
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(attempts['/api/reference'], 1);
    expect(attempts['/api/dashboard'], 2);
    expect(transport.requests, hasLength(3));
  });
}
