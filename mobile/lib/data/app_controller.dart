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
import 'push_service.dart';

class AppController extends ChangeNotifier {
  AppController({
    NaryadApi? api,
    FlutterSecureStorage? storage,
    NaryadApi Function(String)? apiFactory,
    LocalStore? localStore,
    PushService? pushService,
  }) : api = api ?? NaryadApi(defaultBaseUrl),
       _storage = storage ?? const FlutterSecureStorage(),
       _apiFactory = apiFactory ?? ((url) => NaryadApi(url)),
       _providedStore = localStore,
       // Default stays plugin-free: main.dart injects the real push service,
       // so unit tests and injected controllers never touch Firebase.
       _push = pushService ?? const NoopPushService();

  static const defaultBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:8000',
  );
  static const _sessionKey = 'naryad.native.session.v1';
  static const _everLoggedInKey = 'naryad.native.ever_logged_in.v1';
  final FlutterSecureStorage _storage;
  final NaryadApi Function(String) _apiFactory;
  final LocalStore? _providedStore;
  final PushService _push;
  NaryadApi api;
  User? user;
  // Order id from a tapped push that could not be opened yet (no session).
  int? pendingPushOrderId;
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
  DateTime? _lastSnapshotWrite;
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
    offline = false;
    restoring = false;
    _lastSnapshotWrite = null;
    _refreshFuture = null;
    _outboxCache.clear();
    _poll?.cancel();
    _poll = null;
  }

  Future<LocalStore> _local() => _localFuture ??= () async {
    final store = _providedStore ?? await openLocalStore();
    await store.open();
    return store;
  }();

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

  Future<void> _persistProfile(int session, Json profile) async {
    if (kIsWeb) return;
    try {
      final store = await _local();
      if (!_current(session)) return;
      await store.putSnapshot(
        SnapshotKeys.profile,
        profile,
        updatedAt: DateTime.now(),
      );
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
    final now = DateTime.now();
    if (!force &&
        _lastSnapshotWrite != null &&
        now.difference(_lastSnapshotWrite!) < const Duration(seconds: 30)) {
      return;
    }
    _lastSnapshotWrite = now;
    try {
      final store = await _local();
      if (!_current(session)) return;
      await store.putSnapshot(
        SnapshotKeys.orders,
        orders.map((order) => order.data).toList(),
        updatedAt: now,
      );
      await store.putSnapshot(
        SnapshotKeys.reference,
        reference,
        updatedAt: now,
      );
      await store.putSnapshot(
        SnapshotKeys.employees,
        employees,
        updatedAt: now,
      );
      await store.putSnapshot(
        SnapshotKeys.dashboard,
        dashboard,
        updatedAt: now,
      );
      await store.putSnapshot(
        SnapshotKeys.notifications,
        notifications,
        updatedAt: now,
      );
      await store.putSnapshot(
        SnapshotKeys.analytics,
        analytics,
        updatedAt: now,
      );
    } catch (_) {
      // Best effort: a failed snapshot write never breaks the online flow.
    }
  }

  Future<void> flushSnapshot() => _persistSnapshot(_session, force: true);

  Future<void> _hydrateSnapshot() async {
    try {
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
        final entry = await store.getSnapshot(key);
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
      if (profile != null) user = User.fromJson(profile);
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

  Future<void> _clearLocalData() async {
    if (kIsWeb) return;
    try {
      final store = await _local();
      await store.clearSnapshots();
      await store.clearPhotos();
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

  // Push registration is best effort: a missing token or a rejected device
  // record must never break login, restore or logout. The cap keeps a
  // black-holed network from stalling the screen for the full HTTP timeout.
  Future<void> _registerDevice(int session, NaryadApi source) async {
    if (!_current(session)) return;
    try {
      await _push.registerWith(source).timeout(const Duration(seconds: 10));
    } catch (failure) {
      debugPrint('[naryad.push] device register skipped: $failure');
    }
  }

  Future<void> _unregisterDevice() async {
    try {
      await _push.unregister().timeout(const Duration(seconds: 10));
    } catch (failure) {
      debugPrint('[naryad.push] device unregister skipped: $failure');
    }
  }

  /// Records a tapped notification; opens once a session is available.
  void openOrderFromPush(int orderId) {
    if (orderId <= 0) return;
    pendingPushOrderId = orderId;
    if (user != null) _notify();
  }

  /// Returns the stored push target once and clears it.
  int? consumePendingPushOrder() {
    final orderId = pendingPushOrderId;
    pendingPushOrderId = null;
    return orderId;
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
      await _registerDevice(session, next);
      unawaited(_reloadOutbox());
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
    try {
      await _storageTail;
      final saved = await _storage.read(key: _sessionKey);
      debugPrint(
        '[naryad.restore] secure storage read='
        '${saved == null ? 'null' : '${saved.length} bytes'}',
      );
      if (saved == null) {
        if (_current(session) && await _readEverLoggedIn()) {
          error =
              'Сохранённая сессия недоступна на этом устройстве. Войдите снова.';
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
      await _hydrateSnapshot();
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
      unawaited(
        _persistProfile(session, {
          'id': restoredUser.id,
          'name': restoredUser.name,
          'role': restoredUser.role,
        }),
      );
      _startPolling();
      try {
        await refresh(silent: true);
      } catch (_) {
        // _refresh records offline/error state itself.
      }
      await _registerDevice(session, next);
      await _reloadOutbox();
    } catch (failure) {
      if (_current(session)) {
        if (failure is ApiException && failure.statusCode == 401) {
          debugPrint('[naryad.restore] 401 -> expire saved session');
          _expireSession();
        } else {
          error = failure is FormatException
              ? 'Сохранённая сессия недоступна. Войдите снова.'
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
        debugPrint('[naryad.restore] validation unreachable; offline dashboard');
        return;
      }
      error = failure.toString();
      return;
    }
    if (!_current(session)) return;
    offline = false;
    user = fresh;
    unawaited(_persistProfile(session, {
      'id': fresh.id,
      'name': fresh.name,
      'role': fresh.role,
    }));
    try {
      await refresh(silent: true);
    } catch (_) {
      // _refresh records offline/error state itself.
    }
    await _registerDevice(session, next);
  }

  Future<void> logout() async {
    final previous = api;
    // Start while the bearer token is still attached to the client.
    final pushUnregister = _unregisterDevice();
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
    pendingPushOrderId = null;
    error = null;
    _notify();
    unawaited(_clearLocalData());
    await _clearEverLoggedIn();
    try {
      await _store(() => _storage.delete(key: _sessionKey));
    } catch (_) {
      if (_current(session)) {
        error = 'Не удалось удалить сохранённую сессию устройства.';
      }
    }
    await revokeResult;
    await pushUnregister;
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
    // Best effort, started before the bearer token is dropped.
    unawaited(_unregisterDevice());
    ++_session;
    api.token = null;
    _resetData();
    pendingPushOrderId = null;
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
      return result;
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
    final url = '${api.baseUrl}/photos/$id';
    try {
      final cached = await (await _local()).getPhoto(url);
      if (cached != null) return cached;
    } catch (_) {
      // Cache failures fall through to the network load.
    }
    final bytes = await api.photo(id);
    try {
      await (await _local()).putPhoto(url, bytes);
    } catch (_) {
      // A failed cache write must not break viewing the photo.
    }
    return bytes;
  }

  static const maxSendAttempts = 12;

  final List<OutboxCommand> _outboxCache = [];
  List<OutboxCommand> get outbox => List.unmodifiable(_outboxCache);
  bool get hasPendingWrites =>
      _outboxCache.any((command) => command.state != OutboxState.conflict);
  List<OutboxCommand> get conflictCommands =>
      _outboxCache.where((command) => command.state == OutboxState.conflict).toList();

  String _newCommandId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  Future<void> _reloadOutbox() async {
    try {
      final store = await _local();
      final commands = await store.outbox();
      final relevant = commands
          .where((command) =>
              command.ownerId == null || command.ownerId == user?.id)
          .toList();
      if (_disposed) return;
      _outboxCache
        ..clear()
        ..addAll(relevant);
      final activeRefs = relevant
          .map((command) => command.localRef)
          .whereType<String>()
          .toSet();
      final mapped = <String>{};
      for (final ref in activeRefs) {
        final serverId = await store.serverId(ref);
        if (serverId != null) mapped.add(ref);
      }
      final kept = orders.where((order) {
        if (order.id >= 0) return true;
        final ref = '${order.id}';
        return activeRefs.contains(ref) && !mapped.contains(ref);
      }).toList();
      if (kept.length != orders.length) {
        orders = kept;
      }
      _notify();
    } catch (_) {
      // The outbox cache is a UI convenience; reload failures are tolerated.
    }
  }

  Future<void> retryCommand(String commandId) async {
    if (kIsWeb || user == null || saving) return;
    final session = _session;
    try {
      final store = await _local();
      if (!_current(session)) return;
      final commands = await store.outbox();
      OutboxCommand? command;
      for (final item in commands) {
        if (item.commandId == commandId) {
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
    if (kIsWeb || user == null) return;
    final session = _session;
    try {
      final store = await _local();
      if (!_current(session)) return;
      final commands = await store.outbox();
      OutboxCommand? command;
      for (final item in commands) {
        if (item.commandId == commandId) {
          command = item;
          break;
        }
      }
      if (command == null) {
        await _reloadOutbox();
        return;
      }
      final target = command;
      final dependents = commands
          .where((item) =>
              item.commandId != commandId &&
              item.localRef != null &&
              item.localRef == target.localRef)
          .toList();
      await store.removeOutbox(commandId);
      for (final dependent in dependents) {
        await store.removeOutbox(dependent.commandId);
      }
      for (final localRef in [
        target.localRef,
        ...dependents.map((item) => item.localRef),
      ]) {
        if (localRef == null) continue;
        await store.removeServerId(localRef);
      }
      await _reloadOutbox();
    } catch (_) {
      // Discard is best effort; the command stays visible for a second try.
    }
  }

  Future<void> syncOutbox() async {
    if (kIsWeb || user == null || saving) return;
    final session = _session;
    final source = api;
    try {
      final store = await _local();
      if (!_current(session)) return;
      final commands = await store.outbox();
      final relevant = commands
          .where((command) =>
              command.ownerId == null || command.ownerId == user!.id)
          .where((command) =>
              command.state != OutboxState.conflict &&
              command.state != OutboxState.running)
          .toList();
      if (relevant.isEmpty) return;
      var sent = false;
      final blocked = <String>{};
      for (final command in relevant) {
        var orderId = command.orderId;
        if (command.kind != OutboxKind.createOrder) {
          if (command.localRef != null && blocked.contains(command.localRef)) {
            continue;
          }
          if (orderId == null && command.localRef != null) {
            final resolved = await store.serverId(command.localRef!);
            if (resolved == null) {
              blocked.add(command.localRef!);
              continue;
            }
            orderId = resolved;
          }
          if (orderId == null) continue;
        }
        final handled = await _sendCommand(
          store,
          source,
          session,
          command,
          orderId ?? 0,
        );
        if (handled) sent = true;
      }
      if (sent && _current(session)) {
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
    await store.updateOutbox(command.copyWith(state: OutboxState.running));
    try {
      switch (command.kind) {
        case OutboxKind.createOrder:
          final result = await source.createOrder(
            command.payload,
            commandId: command.commandId,
          );
          if (command.localRef != null) {
            await store.putServerId(command.localRef!, result.id);
          }
        case OutboxKind.transition:
          await source.transition(
            orderId,
            command.payload['action'] as String,
            reason: command.payload['reason'] as String?,
            score: (command.payload['score'] as num?)?.toDouble(),
            commandId: command.commandId,
          );
        case OutboxKind.complete:
          await source.complete(
            orderId,
            command.payload,
            commandId: command.commandId,
          );
        case OutboxKind.uploadPhoto:
          final bytes = await store.outboxPhoto(command.commandId);
          if (bytes == null) {
            await store.updateOutbox(
              command.copyWith(
                state: OutboxState.conflict,
                lastError: 'Локальная фотография недоступна.',
              ),
            );
            await _reloadOutbox();
            return false;
          }
          await source.uploadPhoto(
            orderId,
            bytes,
            command.photoFilename ?? 'photo.jpg',
            command.photoKind ?? 'before',
            commandId: command.commandId,
          );
        case OutboxKind.markRead:
          await source.markRead(orderId);
      }
      if (!_current(session)) {
        await store.updateOutbox(command.copyWith(state: OutboxState.pending));
        return false;
      }
      await store.removeOutbox(command.commandId);
      await _reloadOutbox();
      return true;
    } on ApiException catch (failure) {
      if (_current(session) && failure.statusCode == 401) {
        _expireSession();
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

  Future<dynamic> _save({
    required String kind,
    required Json payload,
    required Future<dynamic> Function(NaryadApi source, String commandId)
    action,
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
    final commandId = _newCommandId();
    saving = true;
    error = null;
    _notify();
    try {
      try {
        final result = await action(source, commandId);
        if (!_current(session)) {
          throw const ApiException(
            'Сессия изменилась. Проверьте результат действия перед повтором.',
            401,
            requestMayHaveSucceeded: true,
          );
        }
        ++_dataRevision;
        if (result is WorkOrder) _upsert(result);
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
        if (!_current(session)) rethrow;
        if (failure.statusCode != 0 && !failure.requestMayHaveSucceeded) {
          rethrow;
        }
        // The write may have reached the server: keep the keyed command for replay.
        final command = await (await _local()).enqueue(
          OutboxCommand(
            commandId: commandId,
            kind: kind,
            createdAt: DateTime.now().millisecondsSinceEpoch,
            ownerId: user!.id,
            orderId: orderId,
            localRef: localRef,
            payload: payload,
            photoFilename: photoFilename,
            photoKind: photoKind,
          ),
          photoBytes: photoBytes,
        );
        offline = true;
        await _reloadOutbox();
        final result = onOffline(command);
        ++_dataRevision;
        if (result is WorkOrder) _upsert(result);
        return result;
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
    final localRef = '-${DateTime.now().millisecondsSinceEpoch}';
    final result = await _save(
      kind: OutboxKind.createOrder,
      payload: data,
      localRef: localRef,
      action: (source, commandId) =>
          source.createOrder(data, commandId: commandId),
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
      action: (source, commandId) => source.transition(
        id,
        action,
        reason: reason,
        score: score,
        commandId: commandId,
      ),
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
      action: (source, commandId) =>
          source.complete(id, data, commandId: commandId),
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
    await _save(
      kind: OutboxKind.uploadPhoto,
      payload: {'order_id': id},
      orderId: id >= 0 ? id : null,
      localRef: id < 0 ? '$id' : null,
      photoBytes: bytes,
      photoFilename: filename,
      photoKind: kind,
      action: (source, commandId) => source.uploadPhoto(
        id,
        bytes,
        filename,
        kind,
        commandId: commandId,
      ),
      onOffline: (_) => null,
    );
  }

  Future<void> markRead(int id) async {
    await _save(
      kind: OutboxKind.markRead,
      payload: const {},
      orderId: id,
      action: (source, commandId) => source.markRead(id),
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
