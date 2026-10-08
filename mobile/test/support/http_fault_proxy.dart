// Test-only real transport: commit upstream, lose one downstream HTTP reply.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

bool isLoopbackHttpUri(Uri uri) =>
    uri.scheme == 'http' &&
    const {'127.0.0.1', 'localhost', '::1'}.contains(uri.host) &&
    uri.userInfo.isEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment &&
    uri.port > 0 &&
    uri.port <= 65535;

class CompleteHttpObservation {
  CompleteHttpObservation({
    required this.commandId,
    required this.expectedVersion,
    required this.previousCommandId,
    required Uint8List body,
    required this.upstreamStatus,
    required this.replyDropped,
    required Uint8List replyBody,
  }) : body = Uint8List.fromList(body).asUnmodifiableView(),
       bodySha256 = sha256.convert(body).toString(),
       replyBody = Uint8List.fromList(replyBody).asUnmodifiableView(),
       replySha256 = sha256.convert(replyBody).toString();

  final String? commandId;
  final String? expectedVersion;
  final String? previousCommandId;
  final Uint8List body;
  final String bodySha256;
  final Uint8List replyBody;
  final String replySha256;
  final int upstreamStatus;
  final bool replyDropped;
}

class HttpFaultProxy {
  HttpFaultProxy._(this._server, this._upstream)
    : _client = HttpClient()..autoUncompress = false {
    _server.listen(_accept);
  }

  static Future<HttpFaultProxy> start(Uri upstream) async {
    if (!isLoopbackHttpUri(upstream) || upstream.path != '/api') {
      throw ArgumentError('Fault proxy requires a loopback fixture /api URL.');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.autoCompress = false;
    return HttpFaultProxy._(server, upstream);
  }

  final HttpServer _server;
  final Uri _upstream;
  final HttpClient _client;
  final Set<Future<void>> _pending = {};
  final List<CompleteHttpObservation> _observations = [];
  final _firstCommit = Completer<CompleteHttpObservation>();
  final _release = Completer<void>();
  String? _targetPath;
  bool _closed = false;
  bool _holdingMutations = false;
  bool _dropped = false;
  bool _targetClaimed = false;
  int forwardedMutationCount = 0;
  int heldMutationCount = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}/api';
  List<CompleteHttpObservation> get observations =>
      List.unmodifiable(_observations);
  Future<CompleteHttpObservation> get lostReplyCommitted => _firstCommit.future;

  void armCompleteReplyLoss(int orderId) {
    if (_targetPath != null || orderId <= 0) {
      throw StateError('Arm exactly one positive fixture order.');
    }
    _targetPath = '/api/orders/$orderId/complete';
  }

  void releaseMutations() {
    if (_closed || !_dropped) {
      throw StateError('Release only after the committed reply was lost.');
    }
    _holdingMutations = false;
    if (!_release.isCompleted) _release.complete();
  }

  void _accept(HttpRequest request) {
    late final Future<void> pending;
    pending = _handle(request).whenComplete(() => _pending.remove(pending));
    _pending.add(pending);
  }

  static const _hopHeaders = {
    'host',
    'connection',
    'content-length',
    'transfer-encoding',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'te',
    'trailer',
    'upgrade',
  };

  Future<void> _drop(HttpRequest request) async {
    final socket = await request.response.detachSocket(writeHeaders: false);
    socket.destroy();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final bytes = Uint8List.fromList(
        await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
      );
      final mutates = !const {
        'GET',
        'HEAD',
        'OPTIONS',
      }.contains(request.method);
      final target =
          request.method == 'POST' && request.uri.path == _targetPath;
      final firstTarget = target && !_targetClaimed;
      if (firstTarget) {
        _targetClaimed = true;
        _holdingMutations = true;
      }
      if (mutates &&
          !firstTarget &&
          (_holdingMutations || (_targetPath != null && !_dropped))) {
        heldMutationCount++;
        await _release.future;
      }
      if (_closed) {
        await _drop(request);
        return;
      }
      if (mutates) forwardedMutationCount++;
      final uri = _upstream.replace(
        path: request.uri.path,
        query: request.uri.hasQuery ? request.uri.query : null,
      );
      final upstream = await _client.openUrl(request.method, uri);
      upstream.followRedirects = false;
      request.headers.forEach((name, values) {
        if (!_hopHeaders.contains(name.toLowerCase())) {
          upstream.headers.set(name, values);
        }
      });
      upstream.contentLength = bytes.length;
      upstream.add(bytes);
      final response = await upstream.close();
      // Read ALL of the upstream response before claiming an observed commit.
      final reply = await response.fold<List<int>>(
        [],
        (all, chunk) => all..addAll(chunk),
      );
      final loseReply =
          firstTarget &&
          response.statusCode >= 200 &&
          response.statusCode < 300;
      CompleteHttpObservation? observation;
      if (target) {
        observation = CompleteHttpObservation(
          commandId: request.headers.value('X-Client-Command-Id'),
          expectedVersion: request.headers.value('X-Expected-Order-Version'),
          previousCommandId: request.headers.value(
            'X-Previous-Client-Command-Id',
          ),
          body: bytes,
          upstreamStatus: response.statusCode,
          replyDropped: loseReply,
          replyBody: Uint8List.fromList(reply),
        );
        _observations.add(observation);
      }
      if (loseReply) {
        _dropped = true;
        _holdingMutations = true;
        // No response headers or response bytes have gone downstream yet.
        await _drop(request);
        _firstCommit.complete(observation!);
        return;
      }
      request.response.statusCode = response.statusCode;
      response.headers.forEach((name, values) {
        if (!_hopHeaders.contains(name.toLowerCase())) {
          request.response.headers.set(name, values);
        }
      });
      request.response.contentLength = reply.length;
      request.response.add(reply);
      await request.response.close();
    } catch (_) {
      // Never echo request headers, credentials, tokens or upstream errors.
      try {
        await _drop(request);
      } catch (_) {
        // A disconnected downstream has nothing left to close.
      }
    }
  }

  Future<void> close() async {
    _closed = true;
    if (!_release.isCompleted) _release.complete();
    _client.close(force: true);
    await _server.close(force: true);
    await Future.wait(_pending.toList());
  }
}
