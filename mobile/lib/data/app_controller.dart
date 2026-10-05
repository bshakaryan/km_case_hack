import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'models.dart';

class AppController extends ChangeNotifier {
  AppController({
    NaryadApi? api,
    FlutterSecureStorage? storage,
    NaryadApi Function(String)? apiFactory,
  }) : api = api ?? NaryadApi(defaultBaseUrl),
       _storage = storage ?? const FlutterSecureStorage(),
       _apiFactory = apiFactory ?? ((url) => NaryadApi(url));

  static const defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );
  static const _sessionKey = 'naryad.native.session.v1';
  final FlutterSecureStorage _storage;
  final NaryadApi Function(String) _apiFactory;
  NaryadApi api;
  User? user;
  Json reference = {};
  List<Json> employees = [];
  List<WorkOrder> orders = [];
  Json dashboard = {};
  List<Json> notifications = [];
  Json analytics = {};
  bool loading = false;
  bool saving = false;
  String? error;
  DateTime? lastUpdated;

  Timer? _poll;
  Future<void>? _refreshFuture;
  Future<void> _storageTail = Future.value();
  int _session = 0;
  int _dataRevision = 0;
  bool _disposed = false;

  bool _current(int session) => !_disposed && session == _session;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void clearError() {
    error = null;
    _notify();
  }

  void _resetData() {
    user = null;
    reference = {};
    employees = [];
    orders = [];
    dashboard = {};
    notifications = [];
    analytics = {};
    lastUpdated = null;
    loading = false;
    saving = false;
    _refreshFuture = null;
    _poll?.cancel();
    _poll = null;
  }

  // Serialize storage writes so a delayed login cannot restore a logged-out token.
  Future<void> _store(Future<void> Function() action) {
    if (kIsWeb) {
      return Future.value(); // Web sessions deliberately stay in memory.
    }
    final next = _storageTail.then((_) => action());
    _storageTail = next.catchError((Object _) {});
    return next;
  }

  Future<void> _persist(int session, NaryadApi source) => _store(() async {
    if (_current(session)) {
      await _storage.write(
        key: _sessionKey,
        value: jsonEncode({'base_url': source.baseUrl, 'token': source.token}),
      );
    }
  });

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (user != null && !saving && _refreshFuture == null) {
        // refresh already exposes the error in state; timers must not throw it.
        unawaited(refresh(silent: true).catchError((Object _) {}));
      }
    });
  }

  Future<void> login(String baseUrl, String login, String pin) async {
    // Validate before replacing a still-valid client.
    final next = _apiFactory(baseUrl);
    final session = ++_session;
    final previous = api;
    api = next;
    _resetData();
    error = null;
    loading = true;
    previous.close();
    _notify();
    try {
      final result = await next.login(login, pin);
      if (!_current(session)) return;
      user = User.fromJson(result['user'] as Json);
      String? storageWarning;
      try {
        await _persist(session, next);
      } catch (_) {
        storageWarning = 'Вход выполнен, но сессия не сохранена на устройстве.';
      }
      if (!_current(session)) return;
      _startPolling();
      try {
        await refresh(silent: true);
      } catch (_) {
        // Authentication succeeded; the dashboard displays its own load error.
      }
      if (_current(session) && storageWarning != null) error = storageWarning;
    } catch (failure) {
      if (_current(session)) error = failure.toString();
      rethrow;
    } finally {
      if (_current(session)) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> restoreSession() async {
    if (kIsWeb) return;
    final session = ++_session;
    _resetData();
    error = null;
    loading = true;
    _notify();
    try {
      await _storageTail;
      final saved = await _storage.read(key: _sessionKey);
      if (!_current(session) || saved == null) return;
      final value = jsonDecode(saved);
      if (value is! Json ||
          value['token'] is! String ||
          value['base_url'] is! String) {
        throw const FormatException('Invalid stored session');
      }
      final next = _apiFactory(value['base_url'] as String)
        ..token = value['token'] as String;
      api.close();
      api = next;
      final restoredUser = await next.me();
      if (!_current(session)) return;
      user = restoredUser;
      _startPolling();
      await refresh(silent: true);
    } catch (failure) {
      if (_current(session)) {
        if (failure is ApiException && failure.statusCode == 401) {
          _expireSession();
        } else {
          error = failure is FormatException
              ? 'Сохранённая сессия недоступна. Войдите снова.'
              : failure.toString();
        }
      }
    } finally {
      if (_current(session)) {
        loading = false;
        _notify();
      }
    }
  }

  Future<void> logout() async {
    final previous = api;
    final revocation = previous.token == null
        ? Future<void>.value()
        : previous.logout();
    // Listen immediately: network failure may precede secure storage completion.
    Object? revokeFailure;
    final revokeResult = revocation.catchError((Object e) {
      revokeFailure = e;
    });
    final session = ++_session;
    api = _apiFactory(previous.baseUrl);
    _resetData();
    error = null;
    _notify();
    try {
      await _store(() => _storage.delete(key: _sessionKey));
    } catch (_) {
      if (_current(session)) {
        error = 'Не удалось удалить сохранённую сессию устройства.';
      }
    }
    await revokeResult;
    previous.close();
    if (_current(session)) {
      if (revokeFailure != null) {
        error =
            'Выход выполнен на устройстве. Сервер не подтвердил отзыв сессии.';
      }
      _notify();
    }
  }

  void _expireSession() {
    ++_session;
    api.token = null;
    _resetData();
    error = 'Сессия истекла. Войдите снова.';
    unawaited(
      _store(() => _storage.delete(key: _sessionKey)).catchError((Object _) {}),
    );
    _notify();
  }

  Future<void> refresh({bool silent = false}) {
    if (_disposed || user == null) return Future.value();
    return _refreshFuture ??= _refresh(_session, api, silent);
  }

  Future<void> _refresh(int session, NaryadApi source, bool silent) async {
    final revision = _dataRevision;
    if (!silent) {
      loading = true;
      error = null;
      _notify();
    }
    try {
      final results = await Future.wait<Object>([
        source.reference(),
        source.employees(),
        source.orders(),
        source.dashboard(),
        source.notifications(),
        source.analytics(),
      ]);
      if (!_current(session) || revision != _dataRevision) return;
      reference = results[0] as Json;
      employees = results[1] as List<Json>;
      orders = (results[2] as List<Json>).map(WorkOrder.fromJson).toList();
      dashboard = results[3] as Json;
      notifications = results[4] as List<Json>;
      analytics = results[5] as Json;
      lastUpdated = DateTime.now();
      error = null;
    } catch (failure) {
      if (_current(session)) {
        if (failure is ApiException && failure.statusCode == 401) {
          _expireSession();
        } else {
          error = failure.toString();
        }
      }
      rethrow;
    } finally {
      if (_current(session)) {
        _refreshFuture = null;
        loading = false;
        _notify();
      }
    }
  }

  void _upsert(WorkOrder order) {
    final index = orders.indexWhere((item) => item.id == order.id);
    orders = [...orders];
    if (index < 0) {
      orders.insert(0, order);
    } else {
      orders[index] = order;
    }
  }

  Future<WorkOrder> loadOrder(int id) async {
    final session = _session;
    try {
      final result = await api.order(id);
      if (!_current(session)) {
        throw const ApiException('Сессия изменилась.', 401);
      }
      return result;
    } catch (failure) {
      if (_current(session) &&
          failure is ApiException &&
          failure.statusCode == 401) {
        _expireSession();
      }
      rethrow;
    }
  }

  Future<T> _save<T>(Future<T> Function(NaryadApi) action) async {
    if (user == null) throw const ApiException('Войдите в приложение.', 401);
    if (saving) {
      throw const ApiException(
        'Дождитесь завершения предыдущего действия.',
        409,
      );
    }
    final session = _session;
    final source = api;
    saving = true;
    error = null;
    _notify();
    try {
      final result = await action(source);
      if (!_current(session)) {
        throw const ApiException(
          'Сессия изменилась. Проверьте результат действия перед повтором.',
          401,
          requestMayHaveSucceeded: true,
        );
      }
      ++_dataRevision;
      if (result is WorkOrder) _upsert(result);
      // Discard any snapshot started before the write, then fetch fresh state.
      try {
        await _refreshFuture;
      } catch (_) {}
      if (!_current(session)) {
        throw const ApiException(
          'Сессия изменилась. Проверьте результат действия перед повтором.',
          401,
          requestMayHaveSucceeded: true,
        );
      }
      try {
        await refresh(silent: true);
      } catch (failure) {
        if (_current(session)) {
          error = 'Действие сохранено, но обновить данные не удалось: $failure';
        }
        // The write succeeded: do not invite a duplicate by reporting it failed.
      }
      if (!_current(session)) {
        throw const ApiException(
          'Сессия изменилась. Проверьте результат действия перед повтором.',
          401,
          requestMayHaveSucceeded: true,
        );
      }
      return result;
    } catch (failure) {
      if (_current(session)) {
        if (failure is ApiException && failure.statusCode == 401) {
          _expireSession();
        } else {
          error = failure.toString();
        }
      }
      rethrow;
    } finally {
      if (_current(session)) {
        saving = false;
        _notify();
      }
    }
  }

  Future<WorkOrder> createOrder(Json data) =>
      _save((api) => api.createOrder(data));
  Future<WorkOrder> transition(
    int id,
    String action, {
    String? reason,
    double? score,
  }) =>
      _save((api) => api.transition(id, action, reason: reason, score: score));
  Future<WorkOrder> complete(int id, Json data) =>
      _save((api) => api.complete(id, data));
  Future<void> uploadPhoto(
    int id,
    Uint8List bytes,
    String filename,
    String kind,
  ) => _save((api) => api.uploadPhoto(id, bytes, filename, kind));
  Future<void> markRead(int id) => _save((api) => api.markRead(id));

  @override
  void dispose() {
    _disposed = true;
    ++_session;
    _poll?.cancel();
    api.close();
    super.dispose();
  }
}
