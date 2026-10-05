import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'models.dart';

class ApiException implements Exception {
  const ApiException(
    this.message,
    this.statusCode, {
    this.requestMayHaveSucceeded = false,
  });

  final String message;
  // Zero means that no usable HTTP response was received.
  final int statusCode;
  final bool requestMayHaveSucceeded;

  @override
  String toString() => message;
}

class NaryadApi {
  NaryadApi(String baseUrl, {http.Client? client})
    : baseUrl = normalizeBaseUrl(baseUrl),
      _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;
  String? token;
  static const _timeout = Duration(seconds: 30);

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

  Future<http.Response> _send(http.BaseRequest request) async {
    final changesData = request.method != 'GET';
    try {
      final response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          _errorMessage(response),
          response.statusCode,
          requestMayHaveSucceeded: changesData && response.statusCode >= 500,
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

  Future<dynamic> _json(
    String path, {
    String method = 'GET',
    Json? body,
  }) async {
    final request = http.Request(method, Uri.parse('$baseUrl$path'));
    request.headers.addAll(_headers);
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

  Future<Json> _object(String path, {String method = 'GET', Json? body}) async {
    final result = await _json(path, method: method, body: body);
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

  Future<User> me() async => User.fromJson(await _object('/auth/me'));
  Future<Json> reference() => _object('/reference');
  Future<List<Json>> employees() => _list('/employees');
  Future<List<Json>> orders() => _list('/orders?limit=5000');
  Future<Json> dashboard() => _object('/dashboard');
  Future<List<Json>> notifications() => _list('/notifications');
  Future<Json> analytics() => _object('/analytics');
  Future<WorkOrder> order(int id) async =>
      WorkOrder.fromJson(await _object('/orders/$id'));
  Future<WorkOrder> createOrder(Json data) async =>
      WorkOrder.fromJson(await _object('/orders', method: 'POST', body: data));
  Future<WorkOrder> transition(
    int id,
    String action, {
    String? reason,
    double? score,
  }) async => WorkOrder.fromJson(
    await _object(
      '/orders/$id/transition',
      method: 'POST',
      body: {'action': action, 'reason': ?reason, 'score': ?score},
    ),
  );
  Future<WorkOrder> complete(int id, Json data) async => WorkOrder.fromJson(
    await _object('/orders/$id/complete', method: 'POST', body: data),
  );

  Future<void> uploadPhoto(
    int id,
    Uint8List bytes,
    String filename,
    String kind,
  ) async {
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
    await _send(request);
  }

  Future<Uint8List> photo(int id) async {
    final request = http.Request('GET', Uri.parse('$baseUrl/photos/$id'))
      ..headers.addAll(_headers);
    return (await _send(request)).bodyBytes;
  }

  Future<void> markRead(int id) async {
    await _object('/notifications/$id/read', method: 'POST');
  }

  Future<void> logout() async {
    try {
      await _object('/auth/logout', method: 'POST');
    } finally {
      token = null;
    }
  }

  void close() => _client.close();
}
