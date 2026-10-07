import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'local_store.dart';
import 'local_store_open.dart';
import 'models.dart';

class AppController extends ChangeNotifier {
  AppController({
    NaryadApi? api,
    FlutterSecureStorage? storage,
    NaryadApi Function(String)? apiFactory,
    LocalStore? localStore,
  }) : api = api ?? NaryadApi(defaultBaseUrl),
       _storage = storage ?? const FlutterSecureStorage(),
       _apiFactory = apiFactory ?? ((url) => NaryadApi(url)),
       _providedStore = localStore;

  static const defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );
  static const _sessionKey = 'naryad.native.session.v1';
  static const _everLoggedInKey = 'naryad.native.ever_logged_in.v1';
  final FlutterSecureStorage _storage;
  final NaryadApi Function(String) _apiFactory;
  final LocalStore? _providedStore;
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
  bool offline = false;
  bool restoring = false;
  String? error;
  DateTime? lastUpdated;

  Timer? _poll;
  Future<void>? _refreshFuture;
  Future<void> _storageTail = Future.value();
  Future<LocalStore>? _localFuture;
  Future<void> _cacheTail = Future.value();
  Future<void>? _syncFuture;
  DateTime? _lastSnapshotWrite;
  int _session = 0;
  int _dataRevision = 0;
  int _outboxReloadRevision = 0;
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
    offline = false;
    restoring = false;
    _lastSnapshotWrite = null;
    _refreshFuture = null;
    _outboxCache.clear();
    _resolvedIds.clear();
    _poll?.cancel();
    _poll = null;
  }

  Future<LocalStore> _local() {
    if (_localFuture != null) return _localFuture!;
    final pending = () async {
      final store = _providedStore;
      if (store == null) return openLocalStore();
      await store.open();
      return store;
    }();
    _localFuture = pending;
    pending.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {
        if (identical(_localFuture, pending)) _localFuture = null;
      },
    );
    return pending;
  }

  String _scope(String key, {NaryadApi? source, int? ownerId}) =>
      localScopeKey((source ?? api).baseUrl, ownerId ?? user!.id, key);

  bool _owns(OutboxCommand command, NaryadApi source, int ownerId) =>
      command.serverUrl == source.baseUrl && command.ownerId == ownerId;

  Future<void> _cacheWrite(Future<void> Function() action) {
    final next = _cacheTail.then((_) => action());
    _cacheTail = next.catchError((Object _) {});
    return next;
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
        value: jsonEncode({
          'base_url': source.baseUrl,
          'token': source.token,
          'owner_id': user!.id,
        }),
      );
    }
  });

  Future<void> _persistProfile(int session, Json profile) async {
    if (kIsWeb) return;
    final key = _scope(
      SnapshotKeys.profile,
      ownerId: (profile['id'] as num).toInt(),
    );
    try {
      await _cacheWrite(() async {
        final store = await _local();
        if (!_current(session)) return;
        await store.putSnapshot(key, profile, updatedAt: DateTime.now());
      });
    } catch (_) {
      // Local storage is best effort: login must not fail with it.
    }
  }

  // Non-secret marker so startup can tell a fresh install from a lost session.
  // SharedPreferences (not the Keystore) survives on devices where
  // flutter_secure_storage cannot persist between processes.
  Future<void> _flagEverLoggedIn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_everLoggedInKey, true);
    } catch (_) {
      // Best effort: the marker only improves diagnostics.
    }
  }

  Future<bool> _readEverLoggedIn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_everLoggedInKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearEverLoggedIn() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_everLoggedInKey);
    } catch (_) {
      // Best effort.
    }
  }

  Future<void> _persistSnapshot(int session, {bool force = false}) async {
    if (kIsWeb || user == null) return;
    final source = api;
    final ownerId = user!.id;
    final now = DateTime.now();
    if (!force &&
        _lastSnapshotWrite != null &&
        now.difference(_lastSnapshotWrite!) < const Duration(seconds: 30)) {
      return;
    }
    _lastSnapshotWrite = now;
    final values = <String, Object?>{
      SnapshotKeys.orders: orders.map((order) => order.data).toList(),
      SnapshotKeys.reference: reference,
      SnapshotKeys.employees: employees,
      SnapshotKeys.dashboard: dashboard,
      SnapshotKeys.notifications: notifications,
      SnapshotKeys.analytics: analytics,
    };
    try {
      await _cacheWrite(() async {
        final store = await _local();
        for (final entry in values.entries) {
          if (!_current(session)) return;
          await store.putSnapshot(
            _scope(entry.key, source: source, ownerId: ownerId),
            entry.value,
            updatedAt: now,
          );
        }
      });
    } catch (_) {
      // Best effort: a failed snapshot write never breaks the online flow.
    }
  }

  Future<void> flushSnapshot() => _persistSnapshot(_session, force: true);

  Future<void> _hydrateSnapshot(
    int session,
    NaryadApi source,
    int ownerId,
  ) async {
    try {
      await _cacheTail;
      final store = await _local();
      Json? profile;
      Object? rawOrders;
      Object? rawReference;
      Object? rawEmployees;
      Object? rawDashboard;
      Object? rawNotifications;
      Object? rawAnalytics;
      DateTime? stamped;
      for (final key in SnapshotKeys.all) {
        final entry = await store.getSnapshot(
          _scope(key, source: source, ownerId: ownerId),
        );
        if (entry == null) continue;
        if (stamped == null || entry.updatedAt.isAfter(stamped)) {
          stamped = entry.updatedAt;
        }
        switch (key) {
          case SnapshotKeys.profile:
            profile = entry.data is Json ? entry.data as Json : null;
          case SnapshotKeys.orders:
            rawOrders = entry.data;
          case SnapshotKeys.reference:
            rawReference = entry.data;
          case SnapshotKeys.employees:
            rawEmployees = entry.data;
          case SnapshotKeys.dashboard:
            rawDashboard = entry.data;
          case SnapshotKeys.notifications:
            rawNotifications = entry.data;
          case SnapshotKeys.analytics:
            rawAnalytics = entry.data;
        }
      }
      if (!_current(session) || profile == null || profile['id'] != ownerId) {
        return;
      }
      user = User.fromJson(profile);
      if (rawReference is Json) reference = rawReference;
      if (rawEmployees is List) {
        employees = rawEmployees.whereType<Json>().toList();
      }
      if (rawOrders is List) {
        orders = rawOrders.whereType<Json>().map(WorkOrder.fromJson).toList();
      }
      if (rawDashboard is Json) dashboard = rawDashboard;
      if (rawNotifications is List) {
        notifications = rawNotifications.whereType<Json>().toList();
      }
      if (rawAnalytics is Json) analytics = rawAnalytics;
      lastUpdated = stamped;
    } catch (_) {
      // A corrupt snapshot must not block the session; refresh rebuilds it.
    }
  }

  Future<void> _clearLocalData(String prefix) async {
    if (kIsWeb) return;
    try {
      await _cacheWrite(() async {
        final store = await _local();
        await store.clearSnapshots(prefix: prefix);
        await store.clearPhotos(prefix: prefix);
      });
    } catch (_) {
      // Local cleanup is best effort.
    }
  }

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
    debugPrint('[naryad.login] start baseUrl=$baseUrl');
    try {
      final result = await next.login(login, pin);
      if (!_current(session)) return;
      user = User.fromJson(result['user'] as Json);
      final authenticated = user!;
      await _syncFuture;
      if (!_current(session)) return;
      try {
        await (await _local()).resetRunningOutbox();
        await _hydrateSnapshot(session, next, authenticated.id);
      } catch (_) {
        // Authentication is usable for reading even if durable writes are not.
      }
      if (!_current(session)) return;
      user = authenticated;
      debugPrint(
        '[naryad.login] authenticated user=#${user!.id} tokenLength=${next.token?.length}',
      );
      await _persistProfile(session, result['user'] as Json);
      String? storageWarning;
      try {
        await _persist(session, next);
        final readback = await _storage.read(key: _sessionKey);
        debugPrint(
          '[naryad.login] secure storage roundtrip readback='
          '${readback == null ? 'null' : '${readback.length} bytes'}',
        );
      } catch (failure) {
        storageWarning = 'Вход выполнен, но сессия не сохранена на устройстве.';
        debugPrint('[naryad.login] session persist failed: $failure');
      }
      if (!_current(session)) return;
      await _flagEverLoggedIn();
      _startPolling();
      try {
        await refresh(silent: true);
      } catch (_) {
        // Authentication succeeded; the dashboard displays its own load error.
      }
      if (_current(session) && storageWarning != null) error = storageWarning;
      await _reloadOutbox();
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
    debugPrint(
      '[naryad.restore] start platform=$defaultTargetPlatform '
      'runtimeToken=${api.token == null ? 'none' : 'present'}',
    );
    final session = ++_session;
    _resetData();
    error = null;
    loading = true;
    _notify();
    var legacySession = false;
    try {
      await _storageTail;
      final saved = await _storage.read(key: _sessionKey);
      debugPrint(
        '[naryad.restore] secure storage read='
        '${saved == null ? 'null' : '${saved.length} bytes'}',
      );
      if (saved == null) {
        if (_current(session) && await _readEverLoggedIn()) {
          error = 'Сохранённая сессия недоступна на этом устройстве. Войдите снова.';
          debugPrint(
            '[naryad.restore] prior login seen but secure storage lost the key',
          );
        }
        return;
      }
      if (!_current(session)) return;
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
      // A saved session exists: keep a splash, never flash the login form.
      restoring = true;
      _notify();
      final savedOwner = value['owner_id'];
      final ownerId = savedOwner is num ? savedOwner.toInt() : null;
      legacySession = ownerId == null;
      if (ownerId != null) await _hydrateSnapshot(session, next, ownerId);
      debugPrint('[naryad.restore] snapshot user=#${user?.id}');
      if (!_current(session)) return;
      if (user != null) {
        // Cache-first start: the snapshot dashboard is ready now; the network
        // token is validated in the background.
        offline = false;
        loading = false;
        restoring = false;
        _notify();
        _startPolling();
        await _validateRestoredSession(session, next);
        await _reloadOutbox();
        return;
      }
      final restoredUser = User.fromJson(await next.meData());
      debugPrint('[naryad.restore] meData ok user=#${restoredUser.id}');
      if (!_current(session)) return;
      user = restoredUser;
      offline = false;
      await _hydrateSnapshot(session, next, restoredUser.id);
      if (!_current(session)) return;
      user = restoredUser;
      await _persist(session, next);
      await _persistProfile(session, {
        'id': restoredUser.id,
        'name': restoredUser.name,
        'role': restoredUser.role,
      });
      _startPolling();
      try {
        await refresh(silent: true);
      } catch (_) {
        // _refresh records offline/error state itself.
      }
      await _reloadOutbox();
    } catch (failure) {
      if (_current(session)) {
        if (failure is ApiException && failure.statusCode == 401) {
          debugPrint('[naryad.restore] 401 -> expire saved session');
          _expireSession();
        } else {
          error = failure is FormatException
              ? 'Сохранённая сессия недоступна. Войдите снова.'
              : legacySession &&
                    failure is ApiException &&
                    failure.statusCode == 0
              ? 'Нет связи с сервером. Старый офлайн-кэш нельзя безопасно связать с аккаунтом. Подключитесь к сети и войдите снова.'
              : failure.toString();
          debugPrint('[naryad.restore] error: $failure');
        }
      }
    } finally {
      if (_current(session)) {
        loading = false;
        restoring = false;
        _notify();
      }
    }
  }

  Future<void> _validateRestoredSession(int session, NaryadApi next) async {
    if (!_current(session)) return;
    User? fresh;
    try {
      fresh = User.fromJson(await next.meData());
      debugPrint('[naryad.restore] validated user=#${fresh.id}');
    } catch (failure) {
      if (!_current(session)) return;
      if (failure is ApiException && failure.statusCode == 401) {
        debugPrint('[naryad.restore] 401 -> expire saved session');
        _expireSession();
        return;
      }
      if (failure is ApiException && failure.statusCode == 0) {
        // No connection: the amber offline banner replaces the dashboard error.
        offline = true;
        debugPrint(
          '[naryad.restore] validation unreachable; offline dashboard',
        );
        return;
      }
      error = failure.toString();
      return;
    }
    if (!_current(session)) return;
    if (user != null && user!.id != fresh.id) {
      _expireSession();
      return;
    }
    offline = false;
    user = fresh;
    unawaited(
      _persistProfile(session, {
        'id': fresh.id,
        'name': fresh.name,
        'role': fresh.role,
      }),
    );
    try {
      await refresh(silent: true);
    } catch (_) {
      // _refresh records offline/error state itself.
    }
  }

  Future<void> logout() async {
    final previous = api;
    final cachePrefix = user == null ? null : _scope('');
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
    if (cachePrefix != null) unawaited(_clearLocalData(cachePrefix));
    await _clearEverLoggedIn();
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
    unawaited(_clearEverLoggedIn());
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
      offline = false;
      error = null;
      await _reloadOutbox();
      if (!_current(session)) return;
      unawaited(_persistSnapshot(session));
      unawaited(syncOutbox());
    } catch (failure) {
      if (_current(session)) {
        if (failure is ApiException && failure.statusCode == 401) {
          _expireSession();
        } else if (failure is ApiException && failure.statusCode == 0) {
          // The amber offline banner communicates it; no red panel over stale data.
          offline = true;
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
    if (id < 0) {
      if (user != null) {
        final session = _session;
        final mappingKey = _scope('$id');
        final mapped = await (await _local()).serverId(mappingKey);
        if (!_current(session)) {
          throw const ApiException('Сессия изменилась.', 401);
        }
        if (mapped != null) return loadOrder(mapped);
      }
      final cached = orders.where((item) => item.id == id);
      if (cached.isEmpty) {
        throw const ApiException('Наряд не найден локально.', 404);
      }
      return cached.first;
    }
    final session = _session;
    try {
      final result = await api.order(id);
      if (!_current(session)) {
        throw const ApiException('Сессия изменилась.', 401);
      }
      _upsert(result);
      await _reloadOutbox();
      if (!_current(session)) {
        throw const ApiException('Сессия изменилась.', 401);
      }
      return orders.firstWhere((order) => order.id == id);
    } catch (failure) {
      if (_current(session) &&
          failure is ApiException &&
          failure.statusCode == 0) {
        final cached = orders.where((item) => item.id == id);
        if (cached.isNotEmpty) {
          offline = true;
          return cached.first;
        }
      }
      if (_current(session) &&
          failure is ApiException &&
          failure.statusCode == 401) {
        _expireSession();
      }
      rethrow;
    }
  }

  Future<Uint8List> photoBytes(int id) async {
    if (user == null) throw const ApiException('Войдите в приложение.', 401);
    final session = _session;
    final source = api;
    final key = _scope('photo:$id');
    try {
      final cached = await (await _local()).getPhoto(key);
      if (cached != null && _current(session)) return cached;
    } catch (_) {
      // Cache failures fall through to the network load.
    }
    if (!_current(session)) throw const ApiException('Сессия изменилась.', 401);
    Uint8List bytes;
    try {
      bytes = await source.photo(id);
    } on ApiException catch (failure) {
      if (_current(session) && failure.statusCode == 401) _expireSession();
      rethrow;
    }
    if (!_current(session)) throw const ApiException('Сессия изменилась.', 401);
    try {
      await _cacheWrite(() async {
        if (_current(session)) await (await _local()).putPhoto(key, bytes);
      });
    } catch (_) {
      // A failed cache write must not break viewing the photo.
    }
    return bytes;
  }

  static const maxSendAttempts = 12;

  final List<OutboxCommand> _outboxCache = [];
  final Map<String, int> _resolvedIds = {};
  List<OutboxCommand> get outbox => List.unmodifiable(_outboxCache);
  bool get syncing => _syncFuture != null;
  bool hasQueuedWritesForOrder(int id) => _outboxCache.any(
    (command) =>
        command.kind != OutboxKind.markRead &&
        (command.orderId == id ||
            command.localRef == '$id' ||
            _resolvedIds[command.localRef] == id),
  );
  bool isOrderPending(int id) => hasQueuedWritesForOrder(id);
  bool get hasPendingWrites =>
      _outboxCache.any((command) => command.state != OutboxState.conflict);
  List<OutboxCommand> get conflictCommands => _outboxCache
      .where((command) => command.state == OutboxState.conflict)
      .toList();

  String _newCommandId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _reloadOutbox() async {
    if (user == null) return;
    final reloadRevision = ++_outboxReloadRevision;
    final session = _session;
    final source = api;
    final ownerId = user!.id;
    try {
      final store = await _local();
      final commands = await store.outbox();
      final relevant = commands
          .where((command) => _owns(command, source, ownerId))
          .toList();
      if (!_current(session) || reloadRevision != _outboxReloadRevision) return;
      final activeRefs = relevant
          .map((command) => command.localRef)
          .whereType<String>()
          .toSet();
      final mapped = <String>{};
      final resolvedIds = <String, int>{};
      for (final ref in activeRefs) {
        final serverId = await store.serverId(
          _scope(ref, source: source, ownerId: ownerId),
        );
        if (serverId != null) {
          mapped.add(ref);
          resolvedIds[ref] = serverId;
        }
      }
      if (!_current(session) || reloadRevision != _outboxReloadRevision) return;
      _outboxCache
        ..clear()
        ..addAll(relevant);
      _resolvedIds
        ..clear()
        ..addAll(resolvedIds);
      final kept = orders.where((order) {
        if (order.id >= 0) return true;
        final ref = '${order.id}';
        return activeRefs.contains(ref) && !mapped.contains(ref);
      }).toList();
      orders = kept.map((order) {
        final data = Map<String, dynamic>.from(order.data);
        final confirmed = data.remove('_server_status');
        if (confirmed is String) data['status'] = confirmed;
        data.remove('_queued_status');
        data.remove('_pending_sync');
        return WorkOrder.fromJson(data);
      }).toList();
      for (final command in relevant) {
        if (command.kind == OutboxKind.markRead) continue;
        final id =
            command.orderId ??
            resolvedIds[command.localRef] ??
            int.tryParse(command.localRef ?? '');
        if (id == null) continue;
        if (command.kind == OutboxKind.createOrder &&
            id < 0 &&
            !orders.any((order) => order.id == id)) {
          _upsert(_offlineCreated(command.payload, '$id'));
        }
        final existing = orders.where((order) => order.id == id).firstOrNull;
        if (existing == null) continue;
        final data = Map<String, dynamic>.from(existing.data);
        data['_pending_sync'] = true;
        data['_server_status'] ??= data['status'];
        if (command.state != OutboxState.conflict) {
          if (command.kind == OutboxKind.transition) {
            data['status'] = _transitionedStatus(
              command.payload['action'] as String,
            );
          } else if (command.kind == OutboxKind.complete) {
            data['status'] = 'ai_review';
          }
        }
        data['_queued_status'] = data['status'];
        _upsert(WorkOrder.fromJson(data));
      }
      _notify();
    } catch (_) {
      // The outbox cache is a UI convenience; reload failures are tolerated.
    }
  }

  Future<void> retryCommand(String commandId) async {
    if (user == null || saving) return;
    final session = _session;
    try {
      final store = await _local();
      if (!_current(session)) return;
      final commands = await store.outbox();
      OutboxCommand? command;
      for (final item in commands) {
        if (item.commandId == commandId && _owns(item, api, user!.id)) {
          command = item;
          break;
        }
      }
      if (command == null) return;
      await store.updateOutbox(
        command.copyWith(
          state: OutboxState.pending,
          attempts: 0,
          responseStatus: null,
          response: null,
          lastError: null,
        ),
      );
      await _reloadOutbox();
      unawaited(syncOutbox());
    } catch (_) {
      // Retry is best effort; the same action is available again.
    }
  }

  Future<void> discardCommand(String commandId) async {
    if (user == null) return;
    final session = _session;
    try {
      final store = await _local();
      if (!_current(session)) return;
      final commands = await store.outbox();
      OutboxCommand? command;
      for (final item in commands) {
        if (item.commandId == commandId && _owns(item, api, user!.id)) {
          command = item;
          break;
        }
      }
      if (command == null) {
        await _reloadOutbox();
        return;
      }
      final target = command;
      final targetLane = await _lane(store, target);
      final dependents = <OutboxCommand>[];
      var afterTarget = false;
      for (final item in commands) {
        if (item.commandId == commandId) {
          afterTarget = true;
          continue;
        }
        if (afterTarget &&
            _owns(item, api, user!.id) &&
            await _lane(store, item) == targetLane) {
          dependents.add(item);
        }
      }
      await store.removeOutbox(commandId);
      for (final dependent in dependents) {
        await store.removeOutbox(dependent.commandId);
      }
      for (final localRef in [
        target.localRef,
        ...dependents.map((item) => item.localRef),
      ]) {
        if (localRef == null) continue;
        if (target.kind == OutboxKind.createOrder) {
          await store.removeServerId(_scope(localRef));
        }
      }
      await _reloadOutbox();
    } catch (_) {
      // Discard is best effort; the command stays visible for a second try.
    }
  }

  Future<void> syncOutbox() {
    if (_syncFuture != null) return _syncFuture!;
    if (user == null || saving || _disposed) return Future.value();
    final pending = _syncOutbox(_session, api, user!.id);
    _syncFuture = pending;
    pending.whenComplete(() {
      if (identical(_syncFuture, pending)) _syncFuture = null;
      _notify();
    });
    return pending;
  }

  Future<String> _lane(LocalStore store, OutboxCommand command) async {
    if (command.kind == OutboxKind.markRead) {
      return 'notification:${command.orderId}';
    }
    final ref = command.localRef;
    var id = command.orderId;
    if (id == null &&
        ref != null &&
        command.serverUrl != null &&
        command.ownerId != null) {
      id = await store.serverId(
        localScopeKey(command.serverUrl!, command.ownerId!, ref),
      );
    }
    return id == null ? 'local:$ref' : 'order:$id';
  }

  Future<void> _syncOutbox(int session, NaryadApi source, int ownerId) async {
    try {
      final store = await _local();
      if (!_current(session)) return;
      final commands = await store.outbox();
      final relevant = commands
          .where((command) => _owns(command, source, ownerId))
          .toList();
      if (relevant.isEmpty) return;
      var sent = false;
      final blocked = <String>{};
      for (final command in relevant) {
        if (!_current(session)) break;
        final lane = await _lane(store, command);
        if (blocked.contains(lane)) continue;
        if (command.state == OutboxState.conflict ||
            command.state == OutboxState.running) {
          blocked.add(lane);
          continue;
        }
        var orderId = command.orderId;
        if (command.kind != OutboxKind.createOrder) {
          if (orderId == null && command.localRef != null) {
            final resolved = await store.serverId(
              _scope(command.localRef!, source: source, ownerId: ownerId),
            );
            if (resolved == null) {
              blocked.add(lane);
              continue;
            }
            orderId = resolved;
          }
          if (orderId == null) {
            blocked.add(lane);
            continue;
          }
        }
        final handled = await _sendCommand(
          store,
          source,
          session,
          command,
          orderId ?? 0,
        );
        if (handled) {
          sent = true;
        } else {
          blocked.add(lane);
        }
      }
      if (sent && _current(session)) {
        // Drain the read started before the queued write, then fetch a new
        // snapshot instead of coalescing with a stale in-flight refresh.
        try {
          await _refreshFuture;
        } catch (_) {}
        if (!_current(session)) return;
        try {
          await refresh(silent: true);
        } catch (_) {
          // The queue was processed; a failed refresh is shown in state.
        }
      }
    } catch (_) {
      // Sync is best effort and retried on the next online refresh.
    }
  }

  Future<bool> _sendCommand(
    LocalStore store,
    NaryadApi source,
    int session,
    OutboxCommand command,
    int orderId,
  ) async {
    if (!_current(session)) return false;
    await store.updateOutbox(command.copyWith(state: OutboxState.running));
    if (!_current(session)) {
      await store.updateOutbox(command.copyWith(state: OutboxState.pending));
      return false;
    }
    try {
      final result = await _executeCommand(store, source, command, orderId);
      if (!_current(session)) {
        await store.updateOutbox(command.copyWith(state: OutboxState.pending));
        return false;
      }
      await store.removeOutbox(command.commandId);
      if (!_current(session)) return true;
      ++_dataRevision;
      if (result is WorkOrder) _upsert(result);
      await _reloadOutbox();
      return true;
    } on ApiException catch (failure) {
      if (failure.statusCode == 401) {
        await store.updateOutbox(
          command.copyWith(
            state: OutboxState.pending,
            responseStatus: 401,
            lastError: failure.message,
          ),
        );
        if (_current(session)) _expireSession();
        return false;
      }
      final retryable =
          failure.statusCode == 0 || failure.requestMayHaveSucceeded;
      final exhausted = retryable && command.attempts >= maxSendAttempts;
      final state = retryable && !exhausted
          ? OutboxState.pending
          : OutboxState.conflict;
      final message = exhausted
          ? 'Не удалось отправить после повторных попыток: ${failure.toString()}'
          : failure.toString();
      await store.updateOutbox(
        command.copyWith(
          state: state,
          attempts: command.attempts + 1,
          responseStatus: failure.statusCode,
          lastError: message,
        ),
      );
      await _reloadOutbox();
      return false;
    } catch (failure) {
      await store.updateOutbox(
        command.copyWith(
          state: OutboxState.pending,
          attempts: command.attempts + 1,
          lastError: failure.toString(),
        ),
      );
      return false;
    }
  }

  Future<dynamic> _executeCommand(
    LocalStore store,
    NaryadApi source,
    OutboxCommand command,
    int orderId,
  ) async {
    switch (command.kind) {
      case OutboxKind.createOrder:
        final result = await source.createOrder(
          command.payload,
          commandId: command.commandId,
        );
        if (command.localRef != null) {
          await store.putServerId(
            localScopeKey(source.baseUrl, command.ownerId!, command.localRef!),
            result.id,
          );
        }
        return result;
      case OutboxKind.transition:
        return source.transition(
          orderId,
          command.payload['action'] as String,
          reason: command.payload['reason'] as String?,
          score: (command.payload['score'] as num?)?.toDouble(),
          commandId: command.commandId,
        );
      case OutboxKind.complete:
        return source.complete(
          orderId,
          command.payload,
          commandId: command.commandId,
        );
      case OutboxKind.uploadPhoto:
        final bytes = await store.outboxPhoto(command.commandId);
        if (bytes == null) {
          throw const ApiException('Локальная фотография недоступна.', 422);
        }
        await source.uploadPhoto(
          orderId,
          bytes,
          command.photoFilename ?? 'photo.jpg',
          command.photoKind ?? 'before',
          commandId: command.commandId,
        );
        return null;
      case OutboxKind.markRead:
        await source.markRead(orderId);
        return null;
      default:
        throw const ApiException('Неизвестная локальная команда.', 422);
    }
  }

  Future<dynamic> _save({
    required String kind,
    required Json payload,
    required dynamic Function(OutboxCommand command) onOffline,
    Uint8List? photoBytes,
    String? photoFilename,
    String? photoKind,
    int? orderId,
    String? localRef,
  }) async {
    if (user == null) throw const ApiException('Войдите в приложение.', 401);
    if (saving) {
      throw const ApiException(
        'Дождитесь завершения предыдущего действия.',
        409,
      );
    }
    final session = _session;
    final source = api;
    final ownerId = user!.id;
    final commandId = _newCommandId();
    saving = true;
    error = null;
    _notify();
    try {
      await _syncFuture;
      if (!_current(session)) {
        throw const ApiException('Сессия изменилась.', 401);
      }
      LocalStore store;
      try {
        store = await _local();
      } catch (_) {
        throw const ApiException(
          'Не удалось сохранить действие на устройстве. Оно не отправлено. Проверьте свободное место и повторите.',
          507,
        );
      }
      if (!_current(session)) {
        throw const ApiException('Сессия изменилась.', 401);
      }
      final previous = (await store.outbox())
          .where((item) => _owns(item, source, ownerId))
          .toList();
      var createdAt = DateTime.now().millisecondsSinceEpoch;
      for (final item in previous) {
        if (item.createdAt >= createdAt) createdAt = item.createdAt + 1;
      }
      // Both the key and media must exist on disk BEFORE any HTTP write.
      // A killed process can then replay the exact same command safely.
      late OutboxCommand command;
      try {
        command = await store.enqueue(
          OutboxCommand(
            commandId: commandId,
            kind: kind,
            createdAt: createdAt,
            serverUrl: source.baseUrl,
            ownerId: ownerId,
            orderId: orderId,
            localRef: localRef,
            payload: jsonDecode(jsonEncode(payload)) as Json,
            photoFilename: photoFilename,
            photoKind: photoKind,
          ),
          photoBytes: photoBytes,
        );
      } catch (_) {
        throw const ApiException(
          'Не удалось сохранить действие на устройстве. Оно не отправлено. Проверьте свободное место и повторите.',
          507,
        );
      }
      Future<dynamic> queuedResult() async {
        if (!_current(session)) {
          throw const ApiException('Сессия изменилась.', 401);
        }
        final result = onOffline(command);
        ++_dataRevision;
        if (result is WorkOrder) _upsert(result);
        await _reloadOutbox();
        await _persistSnapshot(session, force: true);
        return result is WorkOrder
            ? orders.firstWhere(
                (order) => order.id == result.id,
                orElse: () => result,
              )
            : result;
      }

      var resolvedId = orderId;
      if (resolvedId == null &&
          localRef != null &&
          kind != OutboxKind.createOrder) {
        resolvedId = await store.serverId(
          _scope(localRef, source: source, ownerId: ownerId),
        );
      }
      final lane = await _lane(store, command);
      var hasPredecessor = false;
      for (final item in previous) {
        if (await _lane(store, item) == lane) {
          hasPredecessor = true;
          break;
        }
      }
      if (offline ||
          hasPredecessor ||
          (kind != OutboxKind.createOrder && resolvedId == null)) {
        return await queuedResult();
      }
      await store.updateOutbox(command.copyWith(state: OutboxState.running));
      try {
        if (!_current(session)) {
          throw const ApiException('Сессия изменилась.', 401);
        }
        final result = await _executeCommand(
          store,
          source,
          command,
          resolvedId ?? 0,
        );
        if (!_current(session)) {
          throw const ApiException(
            'Сессия изменилась. Проверьте результат действия перед повтором.',
            401,
            requestMayHaveSucceeded: true,
          );
        }
        await store.removeOutbox(commandId);
        if (!_current(session)) {
          throw const ApiException(
            'Сессия изменилась. Проверьте результат действия перед повтором.',
            401,
            requestMayHaveSucceeded: true,
          );
        }
        ++_dataRevision;
        if (result is WorkOrder) _upsert(result);
        await _reloadOutbox();
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
            error =
                'Действие сохранено, но обновить данные не удалось: $failure';
          }
        }
        if (!_current(session)) {
          throw const ApiException(
            'Сессия изменилась. Проверьте результат действия перед повтором.',
            401,
            requestMayHaveSucceeded: true,
          );
        }
        return result;
      } on ApiException catch (failure) {
        if (!_current(session) || failure.statusCode == 401) {
          await store.updateOutbox(
            command.copyWith(
              state: OutboxState.pending,
              responseStatus: failure.statusCode,
              lastError: failure.message,
            ),
          );
          rethrow;
        }
        if (failure.statusCode != 0 && !failure.requestMayHaveSucceeded) {
          await store.removeOutbox(commandId);
          await _reloadOutbox();
          rethrow;
        }
        await store.updateOutbox(
          command.copyWith(
            state: OutboxState.pending,
            responseStatus: failure.statusCode,
            lastError: failure.message,
          ),
        );
        offline = true;
        return await queuedResult();
      } catch (failure) {
        await store.updateOutbox(
          command.copyWith(
            state: OutboxState.pending,
            lastError: failure.toString(),
          ),
        );
        rethrow;
      }
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

  WorkOrder _offlineCreated(Json data, String localRef) {
    String nameFrom(String collection, Object? id) {
      if (id == null || reference[collection] is! List) return '';
      for (final item in reference[collection] as List) {
        if (item is Json && item['id'] == id) {
          return item['name']?.toString() ?? '';
        }
      }
      return '';
    }

    String assigneeName(Object? id) {
      if (id == null) return '';
      for (final person in employees) {
        if (person['id'] == id) return person['name']?.toString() ?? '';
      }
      return '';
    }

    final rawDeadline = data['deadline'];
    final deadline = rawDeadline is DateTime
        ? rawDeadline.toIso8601String()
        : rawDeadline?.toString() ?? DateTime.now().toIso8601String();
    return WorkOrder.fromJson(<String, dynamic>{
      'id': int.parse(localRef),
      'number': '—',
      'title': data['title'],
      'description': data['description'] ?? '',
      'work_type': data['work_type'],
      'area_id': data['area_id'],
      'area_name': nameFrom('areas', data['area_id']),
      'equipment_id': data['equipment_id'],
      'equipment_name': nameFrom('equipment', data['equipment_id']),
      'assignee_id': data['assignee_id'],
      'assignee_name': assigneeName(data['assignee_id']),
      'priority': data['priority'] ?? 'normal',
      'status': 'issued',
      'comment': data['comment'] ?? '',
      'normal_hours': data['normal_hours'] ?? 2,
      'deadline': deadline,
      'created_at': DateTime.now().toIso8601String(),
      'is_overdue': false,
    });
  }

  static String _transitionedStatus(String action) => switch (action) {
    'accept' => 'accepted',
    'queue' => 'queued',
    'reject' => 'rejected',
    'start' => 'in_progress',
    'pause' => 'paused',
    'resume' => 'in_progress',
    'close' => 'closed',
    'rework' => 'rework',
    'cancel' => 'cancelled',
    _ => 'issued',
  };

  WorkOrder _offlineOrderState(int id, {double? score}) {
    final existing = orders.where((order) => order.id == id).toList();
    if (existing.isNotEmpty) {
      final data = Map<String, dynamic>.from(existing.first.data);
      data['_server_status'] ??= data['status'];
      data['_queued_status'] = data['status'];
      return WorkOrder.fromJson(data);
    }
    return WorkOrder.fromJson(<String, dynamic>{
      'id': id,
      'number': '—',
      'title': '',
      'description': '',
      'work_type': 'planned',
      'area_name': '',
      'equipment_name': '',
      'assignee_name': '',
      'priority': 'normal',
      'status': 'issued',
      'normal_hours': 0,
      'deadline': DateTime.now().toIso8601String(),
      'created_at': DateTime.now().toIso8601String(),
      'is_overdue': false,
    });
  }

  Future<WorkOrder> createOrder(Json data) async {
    final localRef =
        '-${int.parse(_newCommandId().replaceAll('-', '').substring(0, 13), radix: 16)}';
    final result = await _save(
      kind: OutboxKind.createOrder,
      payload: data,
      localRef: localRef,
      onOffline: (_) => _offlineCreated(data, localRef),
    );
    return result as WorkOrder;
  }

  Future<WorkOrder> transition(
    int id,
    String action, {
    String? reason,
    double? score,
  }) async {
    final result = await _save(
      kind: OutboxKind.transition,
      payload: {'action': action, 'reason': reason, 'score': score},
      orderId: id >= 0 ? id : null,
      localRef: id < 0 ? '$id' : null,
      onOffline: (command) {
        final updated = _offlineOrderState(id, score: score);
        final data = Map<String, dynamic>.from(updated.data);
        final status = _transitionedStatus(action);
        data['status'] = status;
        data['_queued_status'] = updated.data['status'];
        if (action == 'start' || action == 'resume') {
          data['started_at'] ??= DateTime.now().toIso8601String();
        }
        if (action == 'close') {
          data['score'] = score;
          data['closed_at'] = DateTime.now().toIso8601String();
        }
        if (action == 'cancel') {
          data['closed_at'] = DateTime.now().toIso8601String();
        }
        return WorkOrder.fromJson(data);
      },
    );
    return result as WorkOrder;
  }

  Future<WorkOrder> complete(int id, Json data) async {
    final result = await _save(
      kind: OutboxKind.complete,
      payload: data,
      orderId: id >= 0 ? id : null,
      localRef: id < 0 ? '$id' : null,
      onOffline: (command) {
        final updated = _offlineOrderState(id);
        final updatedData = Map<String, dynamic>.from(updated.data);
        updatedData['status'] = 'ai_review';
        updatedData['_queued_status'] = updated.data['status'];
        updatedData['completed_at'] = DateTime.now().toIso8601String();
        return WorkOrder.fromJson(updatedData);
      },
    );
    return result as WorkOrder;
  }

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
    await _save(
      kind: OutboxKind.uploadPhoto,
      payload: {'order_id': id},
      orderId: id >= 0 ? id : null,
      localRef: id < 0 ? '$id' : null,
      photoBytes: bytes,
      photoFilename: filename,
      photoKind: kind,
      onOffline: (_) => null,
    );
  }

  Future<void> markRead(int id) async {
    await _save(
      kind: OutboxKind.markRead,
      payload: const {},
      orderId: id,
      onOffline: (_) => null,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    ++_session;
    _poll?.cancel();
    api.close();
    super.dispose();
  }
}
