import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'order_journal.dart';

class ApiException implements Exception {
  const ApiException(
    this.message,
    this.statusCode, {
    this.requestMayHaveSucceeded = false,
    this.detail,
  });

  final String message;
  // Zero means that no usable HTTP response was received.
  final int statusCode;
  final bool requestMayHaveSucceeded;
  final Json? detail;
  String? get code =>
      detail?['code'] is String ? detail!['code'] as String : null;

  @override
  String toString() => message;
}

class NaryadApi {
  NaryadApi(String baseUrl, {http.Client? client})
    : baseUrl = normalizeBaseUrl(baseUrl),
      _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  bool _closed = false;
  String? _token;
  int _tokenEpoch = 0;
  int _ordersReadId = 0;
  _OrdersSnapshot? _ordersSnapshot;
  String? get token => _token;
  set token(String? value) {
    // Every assignment is an authority boundary, including A -> B -> A and
    // re-login with an identical test token. Never retain another session's list.
    _token = value;
    _tokenEpoch++;
    _ordersSnapshot = null;
  }

  static const _timeout = Duration(seconds: 30);
  static const _readTimeout = Duration(seconds: 8);

  static String normalizeBaseUrl(String input) {
    final value = input.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const ApiException('Укажите адрес сервера: http://адрес:порт', 0);
    }
    return value.endsWith('/api') ? value : '$value/api';
  }

  Map<String, String> get _headers => {
    'Accept': 'application/json',
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<http.Response> _send(
    http.BaseRequest request, {
    bool allowOrdersNotModified = false,
  }) async {
    final changesData = request.method != 'GET';
    final timeout = changesData ? _timeout : _readTimeout;
    final clock = Stopwatch()..start();
    final capturedToken = token;
    final capturedEpoch = _tokenEpoch;
    // Capture a replayable bodyless read BEFORE send finalizes the source.
    // Writes and streamed/body-bearing requests never enter this path.
    final retryRequest =
        request is http.Request &&
            request.method == 'GET' &&
            request.bodyBytes.isEmpty
        ? (http.Request(request.method, request.url)
            ..headers.addAll(request.headers)
            ..followRedirects = request.followRedirects
            ..maxRedirects = request.maxRedirects
            ..persistentConnection = request.persistentConnection)
        : null;
    Future<http.Response> perform() async {
      http.StreamedResponse streamed;
      try {
        streamed = await _client.send(request);
      } on http.ClientException catch (failure) {
        // This catch covers send BEFORE any headers. Loss during body reading,
        // HTTP rejection, timeout and an unknown write outcome cannot retry.
        if (retryRequest == null ||
            _closed ||
            token != capturedToken ||
            _tokenEpoch != capturedEpoch ||
            clock.elapsed >= timeout ||
            request is! http.Request ||
            request.bodyBytes.isNotEmpty ||
            !const {
              'Connection closed before full header was received',
              'Connection closed before response was received',
              'Connection closed before data was received',
            }.contains(failure.message)) {
          rethrow;
        }
        streamed = await _client.send(retryRequest);
      }
      return http.Response.fromStream(streamed);
    }

    try {
      // The single timeout includes both attempts and body consumption. The
      // Stopwatch guard also prevents a late abandoned send from retrying.
      final response = await perform().timeout(timeout);
      if (!(allowOrdersNotModified && response.statusCode == 304) &&
          (response.statusCode < 200 || response.statusCode >= 300)) {
        throw ApiException(
          _errorMessage(response),
          response.statusCode,
          requestMayHaveSucceeded: changesData && response.statusCode >= 500,
          detail: _errorDetail(response),
        );
      }
      return response;
    } on ApiException {
      rethrow;
    } on TimeoutException {
      throw ApiException(
        changesData
            ? 'Сервер не ответил вовремя. Действие могло сохраниться: проверьте данные перед повтором.'
            : 'Сервер не ответил вовремя. Обновите данные позже.',
        0,
        requestMayHaveSucceeded: changesData,
      );
    } on http.ClientException {
      throw ApiException(
        changesData
            ? 'Связь с сервером прервалась. Проверьте результат перед повтором действия.'
            : 'Нет связи с сервером. Проверьте адрес и подключение.',
        0,
        requestMayHaveSucceeded: changesData,
      );
    }
  }

  static String _errorMessage(http.Response response) {
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final detail = body is Map ? body['detail'] : null;
      if (detail is String && detail.isNotEmpty) return detail;
      if (detail is Map && detail['message'] is String) {
        return detail['message'] as String;
      }
      if (detail is List) {
        final messages = detail
            .whereType<Map>()
            .map((item) {
              final location = item['loc'];
              final field = location is List
                  ? location.where((part) => part != 'body').join('.')
                  : '';
              final message =
                  item['msg']?.toString() ?? 'Некорректное значение';
              return field.isEmpty ? message : '$field: $message';
            })
            .join('\n');
        if (messages.isNotEmpty) return messages;
      }
    } on FormatException {
      // Do not show HTML proxy pages, which can contain private diagnostics.
    }
    return switch (response.statusCode) {
      401 => 'Сессия истекла. Войдите снова.',
      403 => 'Недостаточно прав для этого действия.',
      404 => 'Запись не найдена или больше недоступна.',
      413 => 'Фотография больше допустимых 10 МБ.',
      429 => 'Слишком много попыток. Повторите через минуту.',
      _ => 'Ошибка сервера: HTTP ${response.statusCode}.',
    };
  }

  static Json? _errorDetail(http.Response response) {
    try {
      final body = jsonDecode(utf8.decode(response.bodyBytes));
      final detail = body is Map ? body['detail'] : null;
      return detail is Map ? Map<String, dynamic>.from(detail) : null;
    } on FormatException {
      return null;
    }
  }

  static void _orderPrecondition(
    http.BaseRequest request, {
    int? expectedVersion,
    String? previousCommandId,
  }) {
    if (expectedVersion != null && previousCommandId != null) {
      throw const ApiException('У действия два несовместимых основания.', 422);
    }
    if (expectedVersion != null) {
      request.headers['X-Expected-Order-Version'] = '$expectedVersion';
    }
    if (previousCommandId != null) {
      request.headers['X-Previous-Client-Command-Id'] = previousCommandId;
    }
  }

  Future<dynamic> _json(
    String path, {
    String method = 'GET',
    Json? body,
    String? commandId,
    int? expectedVersion,
    String? previousCommandId,
  }) async {
    final request = http.Request(method, Uri.parse('$baseUrl$path'));
    request.headers.addAll(_headers);
    _orderPrecondition(
      request,
      expectedVersion: expectedVersion,
      previousCommandId: previousCommandId,
    );
    if (commandId != null) {
      request.headers['X-Client-Command-Id'] = commandId;
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json; charset=utf-8';
      request.body = jsonEncode(body);
    }
    final response = await _send(request);
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on FormatException {
      throw ApiException(
        'Сервер вернул некорректный ответ. Обновите данные перед повтором.',
        response.statusCode,
        requestMayHaveSucceeded: method != 'GET',
      );
    }
  }

  Future<Json> _object(
    String path, {
    String method = 'GET',
    Json? body,
    String? commandId,
    int? expectedVersion,
    String? previousCommandId,
  }) async {
    final result = await _json(
      path,
      method: method,
      body: body,
      commandId: commandId,
      expectedVersion: expectedVersion,
      previousCommandId: previousCommandId,
    );
    if (result is Map<String, dynamic>) return result;
    throw ApiException(
      'Неожиданный формат ответа сервера.',
      0,
      requestMayHaveSucceeded: method != 'GET',
    );
  }

  Future<List<Json>> _list(String path) async {
    final result = await _json(path);
    if (result is List && result.every((item) => item is Json)) {
      return result.cast<Json>();
    }
    throw const ApiException('Неожиданный формат списка сервера.', 0);
  }

  Future<Json> login(String login, String pin) async {
    token = null;
    final result = await _object(
      '/auth/login',
      method: 'POST',
      body: {'login': login.trim(), 'pin': pin},
    );
    if (result['token'] is! String || result['user'] is! Json) {
      throw const ApiException('Сервер не вернул данные сессии.', 0);
    }
    token = result['token'] as String;
    return result;
  }

  Future<Json> meData() => _object('/auth/me');
  Future<User> me() async => User.fromJson(await meData());
  Future<Json> reference() => _object('/reference');
  Future<List<Json>> employees() => _list('/employees');
  Future<List<Json>> orders() async {
    final uri = Uri.parse('$baseUrl/orders?limit=5000');
    final capturedToken = token;
    final epoch = _tokenEpoch;
    final readId = ++_ordersReadId;
    final previous = _ordersSnapshot;
    final cached =
        previous != null &&
            previous.uri == uri &&
            previous.token == capturedToken &&
            previous.epoch == epoch
        ? previous
        : null;
    bool current() =>
        !_closed && _tokenEpoch == epoch && token == capturedToken;
    ApiException staleContext() => const ApiException(
      'Контекст загрузки нарядов изменился. Повторите чтение в текущей сессии.',
      409,
      detail: {'code': 'read_context_changed'},
    );
    final request = http.Request('GET', uri)..headers.addAll(_headers);
    if (cached != null) request.headers['If-None-Match'] = cached.etag;
    try {
      final response = await _send(
        request,
        allowOrdersNotModified: cached != null,
      );
      if (!current()) throw staleContext();
      if (response.statusCode == 304) {
        if (cached == null ||
            !identical(_ordersSnapshot, cached) ||
            response.bodyBytes.isNotEmpty ||
            response.headers['etag'] != cached.etag) {
          throw const ApiException(
            'Сервер вернул 304 без подходящего сохранённого списка нарядов.',
            304,
          );
        }
        // Deserialize anew: callers may mutate all returned maps/nested lists.
        return _decodeOrders(cached.body, 304);
      }
      if (response.statusCode != 200) {
        throw ApiException(
          'Сервер вернул неожиданный статус списка нарядов.',
          response.statusCode,
        );
      }
      final body = utf8.decode(response.bodyBytes);
      final result = _decodeOrders(body, response.statusCode);
      final etag = response.headers['etag'];
      if (readId == _ordersReadId) {
        _ordersSnapshot = _validOrdersEtag(etag)
            ? _OrdersSnapshot(uri, capturedToken, epoch, etag!, body)
            : null;
      }
      return result;
    } on FormatException {
      if (!current()) throw staleContext();
      if (readId == _ordersReadId) _ordersSnapshot = null;
      throw const ApiException(
        'Сервер вернул некорректный список нарядов.',
        200,
      );
    } catch (_) {
      // A late 401 for an old authority must not expire the new login. The
      // stale read cannot publish a body or alter the current session cache.
      if (!current()) throw staleContext();
      if (readId == _ordersReadId) _ordersSnapshot = null;
      rethrow;
    }
  }

  static bool _validOrdersEtag(String? etag) =>
      etag != null &&
      etag.length <= 4096 &&
      RegExp(r'^(?:W/)?"[\x21\x23-\x7e]*"$').hasMatch(etag);

  static List<Json> _decodeOrders(String body, int status) {
    final result = jsonDecode(body);
    if (result is List && result.every((row) => row is Json)) {
      return result.cast<Json>();
    }
    throw ApiException('Сервер вернул некорректный список нарядов.', status);
  }

  Future<OrderPage> ordersPage(
    OrderJournalQuery query, {
    String? cursor,
    int limit = 100,
  }) async {
    if (limit < 1 || limit > 200) {
      throw const ApiException('Размер страницы должен быть от 1 до 200.', 422);
    }
    final parameters = Uri(
      queryParameters: query.parameters(limit: limit, cursor: cursor),
    ).query;
    try {
      return OrderPage.fromJson(await _object('/orders/page?$parameters'));
    } on FormatException {
      throw const ApiException(
        'Сервер вернул некорректную страницу журнала.',
        200,
      );
    }
  }

  Future<EquipmentDetails> equipmentDetails(int id) async {
    try {
      final result = EquipmentDetails.fromJson(await _object('/equipment/$id'));
      if (result.id != id) throw const FormatException('Другое оборудование.');
      return result;
    } on FormatException {
      throw const ApiException(
        'Сервер вернул некорректную карточку оборудования.',
        200,
      );
    }
  }

  Future<Json> dashboard() => _object('/dashboard');
  Future<List<Json>> notifications() => _list('/notifications');
  Future<Json> analytics() => _object('/analytics');
  Future<WorkOrder> order(int id) async =>
      WorkOrder.fromJson(await _object('/orders/$id'));

  static WorkOrder _orderReceipt(Json data, {int? expectedVersion}) {
    final result = WorkOrder.fromJson(data);
    if (result.version == null ||
        (expectedVersion != null && result.version! < expectedVersion)) {
      throw const ApiException(
        'Сервер не подтвердил версию сохранённого действия. Обновите карточку; действие могло сохраниться.',
        200,
        requestMayHaveSucceeded: true,
      );
    }
    return result;
  }

  Future<WorkOrder> createOrder(Json data, {String? commandId}) async =>
      _orderReceipt(
        await _object(
          '/orders',
          method: 'POST',
          body: data,
          commandId: commandId,
        ),
      );
  Future<WorkOrder> transition(
    int id,
    String action, {
    String? reason,
    double? score,
    String? commandId,
    int? expectedVersion,
    String? previousCommandId,
  }) async => _orderReceipt(
    await _object(
      '/orders/$id/transition',
      method: 'POST',
      body: {'action': action, 'reason': ?reason, 'score': ?score},
      commandId: commandId,
      expectedVersion: expectedVersion,
      previousCommandId: previousCommandId,
    ),
    expectedVersion: expectedVersion,
  );
  Future<WorkOrder> complete(
    int id,
    Json data, {
    String? commandId,
    int? expectedVersion,
    String? previousCommandId,
  }) async => _orderReceipt(
    await _object(
      '/orders/$id/complete',
      method: 'POST',
      body: data,
      commandId: commandId,
      expectedVersion: expectedVersion,
      previousCommandId: previousCommandId,
    ),
    expectedVersion: expectedVersion,
  );

  Future<Json> attemptAiReview(int orderId, int attemptId) =>
      _object('/orders/$orderId/submissions/$attemptId/ai-review');
  Future<Json> retryAiReview(
    int orderId,
    int attemptId, {
    int? expectedVersion,
  }) => _object(
    '/orders/$orderId/submissions/$attemptId/ai-review/retry',
    method: 'POST',
    body: <String, dynamic>{},
    expectedVersion: expectedVersion,
  );

  Future<Json> uploadPhoto(
    int id,
    Uint8List bytes,
    String filename,
    String kind, {
    String? commandId,
    int? expectedVersion,
    String? previousCommandId,
  }) async {
    if (!['before', 'after'].contains(kind)) {
      throw const ApiException('Неизвестный тип фотографии.', 422);
    }
    if (bytes.length > 10 * 1024 * 1024) {
      throw const ApiException('Фотография больше допустимых 10 МБ.', 413);
    }
    final request =
        http.MultipartRequest('POST', Uri.parse('$baseUrl/orders/$id/photos'))
          ..headers.addAll(_headers)
          ..fields['kind'] = kind
          ..files.add(
            http.MultipartFile.fromBytes('file', bytes, filename: filename),
          );
    if (commandId != null) {
      request.headers['X-Client-Command-Id'] = commandId;
    }
    _orderPrecondition(
      request,
      expectedVersion: expectedVersion,
      previousCommandId: previousCommandId,
    );
    final response = await _send(request);
    try {
      final result = jsonDecode(utf8.decode(response.bodyBytes));
      final version = result is Map ? result['order_version'] : null;
      if (result is Json &&
          version is int &&
          version >= 1 &&
          (expectedVersion == null || version >= expectedVersion)) {
        return result;
      }
    } on FormatException {
      // The upload may already have committed even when the reply is unusable.
    }
    throw const ApiException(
      'Сервер не подтвердил версию после загрузки. Фотография могла сохраниться; обновите карточку.',
      200,
      requestMayHaveSucceeded: true,
    );
  }

  Future<Uint8List> photo(int id) async {
    final request = http.Request('GET', Uri.parse('$baseUrl/photos/$id'))
      ..headers.addAll(_headers);
    return (await _send(request)).bodyBytes;
  }

  Future<void> markRead(int id) async {
    await _object('/notifications/$id/read', method: 'POST');
  }

  // Idempotent upsert of the device record for push delivery.
  Future<Json> registerDevice(String token, {String? appVersion}) => _object(
    '/devices',
    method: 'POST',
    body: {'token': token, 'platform': 'android', 'app_version': ?appVersion},
  );

  // Idempotent removal of the device record on logout or session expiry.
  Future<Json> unregisterDevice(String token) =>
      _object('/devices/unregister', method: 'POST', body: {'token': token});

  Future<void> logout() async {
    try {
      await _object('/auth/logout', method: 'POST');
    } finally {
      token = null;
    }
  }

  void close() {
    _closed = true;
    _tokenEpoch++;
    _ordersSnapshot = null;
    _client.close();
  }
}

// The cache belongs to ONE API instance/full URI/current authority epoch. A
// serialized body has no mutable references shared with application callers.
class _OrdersSnapshot {
  const _OrdersSnapshot(this.uri, this.token, this.epoch, this.etag, this.body);
  final Uri uri;
  final String? token;
  final int epoch;
  final String etag;
  final String body;
}
