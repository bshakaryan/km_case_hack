import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'form_draft.dart';
import 'local_store.dart';
import 'local_store_open.dart';
import 'models.dart';
import 'order_journal.dart';
import 'push_service.dart';
import 'recovery_models.dart';
import '../domain/reference_edit.dart';
import '../domain/navigation_scope.dart';

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
  NavigationScope? _pendingPushScope;
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
  Future<void> _draftTail = Future.value();
  final Map<String, Object> _draftHandles = {};
  Future<void>? _syncFuture;
  // Unlike UI saving, this survives _resetData until the original write drains.
  Completer<void>? _writeLease;
  bool _recoveringQueue = false;
  DateTime? _lastSnapshotWrite;
  int _session = 0;
  int _dataRevision = 0;
  int _outboxReloadRevision = 0;
  bool _disposed = false;
  int? _referenceDeniedSession;
  int _referenceReadId = 0;
  final Map<ReferenceEditScope, _ReferenceEditContext> _referenceScopes = {};
  final Map<String, ReferenceEditTicket> _referenceTickets = {};
  final Map<int, NavigationScope> _orderAccessDenials = {};

  bool get canManageReferences =>
      !_disposed &&
      user?.role == 'admin' &&
      api.token != null &&
      !api.isClosed &&
      _referenceDeniedSession != _session;
  bool get referenceWriteBusy =>
      saving ||
      _writeLease != null ||
      _syncFuture != null ||
      _recoveringQueue ||
      outbox.any((command) => command.state == OutboxState.running);

  /// Fences UI callbacks and reads to the authority that initiated them.
  /// Authentication/visibility still belongs to the API; this grants no rights.
  NavigationScope captureNavigationScope() {
    final session = _session;
    final source = api;
    final epoch = source.sessionEpoch;
    final owner = user?.id;
    final role = user?.role;
    return NavigationScope(
      () =>
          owner != null &&
          _current(session) &&
          identical(api, source) &&
          !source.isClosed &&
          source.sessionEpoch == epoch &&
          user?.id == owner &&
          user?.role == role,
    );
  }

  bool canUseCachedOrder(int id) => _orderAccessDenials[id]?.isCurrent != true;

  List<ReferenceEditTicket> get referenceEdits => List.unmodifiable(
    _referenceTickets.values.where((ticket) => ticket.isCurrent),
  );

  ReferenceEditScope captureReferenceScope() {
    if (!canManageReferences || api.token == null || api.isClosed) {
      throw const ApiException(
        'Для изменения справочников войдите как администратор.',
        403,
      );
    }
    _referenceScopes.removeWhere((scope, _) => !scope.isCurrent);
    _referenceTickets.removeWhere((_, ticket) => !ticket.isCurrent);
    if (_referenceScopes.isNotEmpty) {
      return _referenceScopes.keys.first;
    }
    final session = _session;
    final source = api;
    final epoch = source.sessionEpoch;
    final owner = user!.id;
    bool authorityCurrent() =>
        _current(session) &&
        identical(api, source) &&
        !source.isClosed &&
        source.sessionEpoch == epoch &&
        user?.id == owner &&
        user?.role == 'admin';
    final scope = ReferenceEditScope(
      () => authorityCurrent() && _referenceDeniedSession != session,
    );
    _referenceScopes[scope] = _ReferenceEditContext(
      session,
      source,
      scope,
      authorityCurrent,
    );
    return scope;
  }

  ReferenceMutationResult? _referencePreflight(ReferenceEditScope scope) {
    if (!scope.isCurrent) {
      return const ReferenceMutationResult(
        ReferenceMutationStatus.scopeChanged,
      );
    }
    if (offline) {
      return const ReferenceMutationResult(
        ReferenceMutationStatus.offline,
        error: ReferenceEditError(
          'Справочники сохраняются только при подключении к серверу.',
        ),
      );
    }
    if (referenceWriteBusy) {
      return const ReferenceMutationResult(
        ReferenceMutationStatus.busy,
        error: ReferenceEditError(
          'Дождитесь завершения текущей отправки или работы с очередью.',
        ),
      );
    }
    return null;
  }

  ReferenceEditTicket openReferenceEdit(
    ReferenceCollection collection, {
    int? id,
    bool newOperation = false,
  }) {
    if (id != null && id <= 0) {
      throw const ApiException('Некорректный id записи.', 422);
    }
    final key = '${collection.name}:${id ?? 'new'}';
    final previous = _referenceTickets[key];
    if (previous?.isCurrent == true &&
        (previous!.state != ReferenceEditState.saved || !newOperation)) {
      return previous;
    }
    final scope = captureReferenceScope();
    final initial = id == null
        ? <String, dynamic>{}
        : (reference[collection.name] as List? ?? const [])
              .whereType<Json>()
              .where((row) => row['id'] == id)
              .firstOrNull;
    if (initial == null) {
      throw const ApiException(
        'Запись отсутствует в текущем справочнике. Обновите список.',
        404,
      );
    }
    final context = _referenceScopes[scope]!;
    final ticket = ReferenceEditTicket(
      collection: collection,
      id: id,
      scope: scope,
      initialValues: initial,
      preflight: () => _referencePreflight(scope),
      send: (values) => _submitReference(context, collection, id, values),
      changed: () {
        if (scope.isCurrent) {
          _notify();
        }
      },
    );
    _referenceTickets[key] = ticket;
    return ticket;
  }

  Future<ReferenceMutationResult> _submitReference(
    _ReferenceEditContext context,
    ReferenceCollection collection,
    int? id,
    Json values,
  ) async {
    final blocked = _referencePreflight(context.scope);
    if (blocked != null) {
      return blocked;
    }
    final lease = Completer<void>();
    _writeLease = lease;
    saving = true;
    ++_dataRevision;
    _notify();
    var sent = false;
    try {
      if (!context.scope.isCurrent) {
        return const ReferenceMutationResult(
          ReferenceMutationStatus.scopeChanged,
        );
      }
      sent = true;
      final row = await switch (collection) {
        ReferenceCollection.equipment =>
          id == null
              ? context.source.createEquipment(values)
              : context.source.updateEquipment(id, values),
        ReferenceCollection.materials =>
          id == null
              ? context.source.createMaterial(values)
              : context.source.updateMaterial(id, values),
      };
      if (!context.scope.isCurrent) {
        return const ReferenceMutationResult(
          ReferenceMutationStatus.scopeChanged,
          mayHaveSucceeded: true,
        );
      }
      ++_dataRevision;
      ++_referenceReadId;
      final existing = (reference[collection.name] as List? ?? const [])
          .whereType<Json>()
          .toList();
      final index = existing.indexWhere((item) => item['id'] == row['id']);
      if (index < 0) {
        existing.add(Map<String, dynamic>.from(row));
      } else {
        existing[index] = Map<String, dynamic>.from(row);
      }
      reference = {...reference, collection.name: existing};
      unawaited(_persistSnapshot(context.session, force: true));
      return ReferenceMutationResult(ReferenceMutationStatus.saved, row: row);
    } on ApiException catch (failure) {
      if (!context.scope.isCurrent) {
        return ReferenceMutationResult(
          ReferenceMutationStatus.scopeChanged,
          mayHaveSucceeded: sent,
        );
      }
      if (failure.statusCode == 403) {
        _referenceDeniedSession = context.session;
        error = 'Доступ к справочникам отозван. Войдите снова.';
      } else if (failure.statusCode == 401) {
        _expireSession();
      }
      final uncertain =
          failure.requestMayHaveSucceeded ||
          failure.statusCode == 0 ||
          failure.statusCode == 408 ||
          failure.statusCode >= 500;
      return ReferenceMutationResult(
        uncertain
            ? ReferenceMutationStatus.uncertain
            : ReferenceMutationStatus.rejected,
        error: ReferenceEditError(
          failure.message,
          statusCode: failure.statusCode,
        ),
        mayHaveSucceeded: uncertain,
      );
    } catch (_) {
      return ReferenceMutationResult(
        context.scope.isCurrent
            ? ReferenceMutationStatus.uncertain
            : ReferenceMutationStatus.scopeChanged,
        error: const ReferenceEditError(
          'Ответ сохранения недоступен. Результат отправки неизвестен; повтор не выполнен.',
        ),
        mayHaveSucceeded: sent,
      );
    } finally {
      if (identical(_writeLease, lease)) {
        _writeLease = null;
        saving = false;
      }
      lease.complete();
      if (context.authorityCurrent()) {
        _notify();
      }
    }
  }

  Future<ReferenceRefreshResult> refreshReferences(
    ReferenceEditScope scope,
  ) async {
    final context = _referenceScopes[scope];
    if (context == null || !scope.isCurrent) {
      return const ReferenceRefreshResult(ReferenceRefreshStatus.scopeChanged);
    }
    if (offline) {
      return const ReferenceRefreshResult(
        ReferenceRefreshStatus.failed,
        error: ReferenceEditError(
          'Нет подключения. Показан сохранённый справочник.',
        ),
      );
    }
    final revision = _dataRevision;
    final readId = ++_referenceReadId;
    try {
      final result = await context.source.reference();
      if (!scope.isCurrent) {
        return const ReferenceRefreshResult(
          ReferenceRefreshStatus.scopeChanged,
        );
      }
      if (revision != _dataRevision || readId != _referenceReadId) {
        return const ReferenceRefreshResult(
          ReferenceRefreshStatus.failed,
          error: ReferenceEditError(
            'Данные изменились во время чтения. Обновите список ещё раз.',
          ),
        );
      }
      if ([
            'areas',
            'equipment',
            'materials',
            'employees',
            'brigades',
            'fault_codes',
            'time_norms',
          ].any(
            (key) =>
                result[key] is! List ||
                !(result[key] as List).every((row) => row is Json),
          ) ||
          !(result['areas'] as List).every(
            (row) =>
                row['id'] is int &&
                row['id'] > 0 &&
                row['name'] is String &&
                (row['name'] as String).trim().isNotEmpty,
          ) ||
          !(result['equipment'] as List).every(
            (row) => isCompleteReferenceRow(ReferenceCollection.equipment, row),
          ) ||
          !(result['materials'] as List).every(
            (row) => isCompleteReferenceRow(ReferenceCollection.materials, row),
          )) {
        return const ReferenceRefreshResult(
          ReferenceRefreshStatus.failed,
          error: ReferenceEditError('Сервер вернул некорректный справочник.'),
        );
      }
      ++_dataRevision;
      reference = result;
      await _persistSnapshot(context.session, force: true);
      if (!scope.isCurrent) {
        return const ReferenceRefreshResult(
          ReferenceRefreshStatus.scopeChanged,
        );
      }
      _notify();
      return const ReferenceRefreshResult(ReferenceRefreshStatus.refreshed);
    } on ApiException catch (failure) {
      if (!scope.isCurrent) {
        return const ReferenceRefreshResult(
          ReferenceRefreshStatus.scopeChanged,
        );
      }
      if (failure.statusCode == 403) {
        _referenceDeniedSession = context.session;
        error = 'Доступ к справочникам отозван. Войдите снова.';
      } else if (failure.statusCode == 401) {
        _expireSession();
      }
      _notify();
      return ReferenceRefreshResult(
        ReferenceRefreshStatus.failed,
        error: ReferenceEditError(
          failure.message,
          statusCode: failure.statusCode,
        ),
      );
    } catch (_) {
      if (!scope.isCurrent) {
        return const ReferenceRefreshResult(
          ReferenceRefreshStatus.scopeChanged,
        );
      }
      return const ReferenceRefreshResult(
        ReferenceRefreshStatus.failed,
        error: ReferenceEditError(
          'Не удалось обновить список. Подтверждённое сохранение не отменено.',
        ),
      );
    }
  }

  bool _current(int session) => !_disposed && session == _session;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void clearError() {
    error = null;
    _notify();
  }

  void _resetData() {
    _orderAccessDenials.clear();
    // Preserve only an unscoped cold-start ID. A tapped authenticated route
    // cannot move to a different login, even if the next token is identical.
    if (_pendingPushScope != null) {
      pendingPushOrderId = null;
      _pendingPushScope = null;
    }
    _referenceScopes.clear();
    _referenceTickets.clear();
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

  Future<T> _draftOperation<T>(Future<T> Function() action) {
    final next = _draftTail.then((_) => action());
    _draftTail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<FormDraftSession> openFormDraft(String kind, {int? orderId}) async {
    if (user == null) throw const ApiException('Войдите в приложение.', 401);
    // Validate context before opening a handle or touching a stored draft.
    FormDraft(kind: kind, orderId: orderId, data: const {});
    final session = _session;
    final source = api;
    final ownerId = user!.id;
    final key = _scope('draft:$kind:${orderId ?? 'new'}');
    final handle = Object();
    _draftHandles[key] = handle;

    void ensureCurrent() {
      if (!_current(session) ||
          !identical(api, source) ||
          user?.id != ownerId ||
          !identical(_draftHandles[key], handle)) {
        throw const ApiException(
          'Контекст формы изменился. Черновик сохранён для исходного аккаунта и сервера.',
          401,
        );
      }
    }

    Future<LocalStore> storeForHandle() async {
      ensureCurrent();
      final store = await _local();
      ensureCurrent();
      return store;
    }

    FormDraft? decode(Json? raw) {
      if (raw == null) return null;
      final draft = FormDraft.fromJson(raw);
      if (draft.kind != kind || draft.orderId != orderId) {
        throw const FormatException(
          'Сохранённый черновик имеет другой контекст.',
        );
      }
      return draft;
    }

    return FormDraftSession(
      () => _draftOperation(() async {
        final store = await storeForHandle();
        final draft = decode(await store.getFormDraft(key));
        ensureCurrent();
        // A killed process may have stopped before or after the server effect.
        // Reads cannot clear this fence or turn it into another submit.
        return draft?.state == FormDraftState.submitting
            ? draft!.copyWith(state: FormDraftState.uncertain)
            : draft;
      }),
      (draft, acknowledgeSubmission) => _draftOperation(() async {
        final store = await storeForHandle();
        if (draft.kind != kind || draft.orderId != orderId) {
          throw const ApiException(
            'Нельзя перенести черновик в другую форму.',
            422,
          );
        }
        final previous = decode(await store.getFormDraft(key));
        ensureCurrent();
        if (previous?.submissionUncertain == true &&
            draft.state == FormDraftState.editing &&
            !acknowledgeSubmission) {
          throw const ApiException(
            'Результат отправки неизвестен. Сначала проверьте очередь и сервер.',
            409,
          );
        }
        final oldBasis = previous?.basis;
        final nextBasis = draft.basis;
        if (oldBasis != null &&
            (nextBasis == null ||
                (nextBasis.expectedVersion != oldBasis.expectedVersion &&
                    nextBasis.previousCommandId == null) ||
                (nextBasis.expectedVersion != null &&
                    oldBasis.expectedVersion == null))) {
          throw const ApiException(
            'Нельзя заменить исходную версию черновика новой карточкой наряда.',
            409,
          );
        }
        await store.putFormDraft(key, draft.toJson());
        ensureCurrent();
      }),
      () => _draftOperation(() async {
        final store = await storeForHandle();
        await store.removeFormDraft(key);
        ensureCurrent();
      }),
    );
  }

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
      SnapshotKeys.orders: orders.map((order) => order.toJson()).toList(),
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
      if (rawReference is Json) {
        reference = user!.isWorker
            ? {
                'areas': <Json>[],
                'equipment': <Json>[],
                'employees': <Json>[],
                'brigades': <Json>[],
                'fault_codes': rawReference['fault_codes'] ?? <Json>[],
                'materials': rawReference['materials'] ?? <Json>[],
                'time_norms': <Json>[],
              }
            : rawReference;
      }
      if (user!.isWorker) {
        employees = [];
      } else if (rawEmployees is List) {
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
    // A cold-start ID has no recipient/server identity; only defer routing.
    _pendingPushScope = user == null ? null : captureNavigationScope();
    if (user != null) _notify();
  }

  /// Returns the stored push target once and clears it.
  int? consumePendingPushOrder() {
    if (user == null) return null;
    final orderId = pendingPushOrderId;
    pendingPushOrderId = null;
    final scope = _pendingPushScope;
    _pendingPushScope = null;
    return scope == null || scope.isCurrent ? orderId : null;
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
      final authenticated = User.fromJson(result['user'] as Json);
      await _syncFuture;
      if (!_current(session)) return;
      await _writeLease?.future;
      if (!_current(session)) return;
      try {
        final store = await _local();
        if (!_current(session)) return;
        await store.resetRunningOutbox();
        if (!_current(session)) return;
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
      await _registerDevice(session, next);
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
    await _registerDevice(session, next);
  }

  Future<void> logout() async {
    final previous = api;
    // Unregister while the bearer is valid, before server logout revokes it.
    // Local state is cleared below immediately, without waiting for the network.
    final pushUnregister = _unregisterDevice();
    final cachePrefix = user == null ? null : _scope('');
    final revocation = () async {
      await pushUnregister;
      if (previous.token != null) await previous.logout();
    }();
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
    final authority = captureNavigationScope();
    final revision = _dataRevision;
    if (!silent) {
      loading = true;
      error = null;
      _notify();
    }
    try {
      final results = await Future.wait<Object>([
        source.reference(),
        user?.isWorker == true ? Future.value(<Json>[]) : source.employees(),
        source.orders(),
        source.dashboard(),
        source.notifications(),
        source.analytics(),
      ]);
      if (!authority.isCurrent || revision != _dataRevision) return;
      reference = results[0] as Json;
      employees = results[1] as List<Json>;
      final cachedOrders = {for (final order in orders) order.id: order};
      orders = (results[2] as List<Json>)
          .map((json) => WorkOrder.fromJson(json))
          .map((order) => order.withCachedHistory(cachedOrders[order.id]))
          .toList();
      dashboard = results[3] as Json;
      notifications = results[4] as List<Json>;
      analytics = results[5] as Json;
      lastUpdated = DateTime.now();
      offline = false;
      error = null;
      await _reloadOutbox();
      if (!authority.isCurrent) return;
      unawaited(_persistSnapshot(session));
      unawaited(syncOutbox());
    } catch (failure) {
      // A refresh belongs to its captured session. A cancelled old read is
      // discarded just like its old successful response after another login.
      if (!authority.isCurrent) return;
      if (authority.isCurrent) {
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
      orders[index] = order.withCachedHistory(orders[index]);
    }
  }

  /// Server journal reads never replace the operative cache or write basis.
  Future<OrderPage> loadOrderPage(
    OrderJournalQuery query, {
    String? cursor,
    int limit = 100,
  }) => _readJournal(
    (source) => source.ordersPage(query, cursor: cursor, limit: limit),
  );

  Future<EquipmentDetails> loadEquipmentDetails(int id) {
    if (!const {'master', 'manager', 'admin'}.contains(user?.role)) {
      throw const ApiException(
        'История оборудования доступна мастеру и руководителю.',
        403,
      );
    }
    return _readJournal((source) => source.equipmentDetails(id));
  }

  Future<T> _readJournal<T>(Future<T> Function(NaryadApi) read) async {
    if (user == null) throw const ApiException('Войдите в приложение.', 401);
    final session = _session;
    final source = api;
    final token = source.token;
    final ownerId = user!.id;
    final role = user!.role;
    bool current() =>
        _current(session) &&
        identical(api, source) &&
        source.token == token &&
        user?.id == ownerId &&
        user?.role == role;
    try {
      final result = await read(source);
      if (!current()) throw const ApiException('Сессия изменилась.', 401);
      return result;
    } on ApiException catch (error) {
      if (current() && error.statusCode == 401) _expireSession();
      rethrow;
    }
  }

  Future<WorkOrder> loadOrder(int id) async {
    final authority = captureNavigationScope();
    _orderAccessDenials.removeWhere((_, scope) => !scope.isCurrent);
    if (id < 0) {
      if (user != null) {
        final session = _session;
        final mappingKey = _scope('$id');
        final mapped = await (await _local()).serverId(mappingKey);
        if (!_current(session) || !authority.isCurrent) {
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
      if (!_current(session) || !authority.isCurrent) {
        throw const ApiException('Сессия изменилась.', 401);
      }
      // Only this authorized HTTP result clears a denial. An offline snapshot
      // may not restore denied access when the user reopens the same route.
      _orderAccessDenials.remove(id);
      _upsert(result);
      await _reloadOutbox();
      if (!_current(session) || !authority.isCurrent) {
        throw const ApiException('Сессия изменилась.', 401);
      }
      await _persistSnapshot(session, force: true);
      if (!_current(session) || !authority.isCurrent) {
        throw const ApiException('Сессия изменилась.', 401);
      }
      return orders.firstWhere((order) => order.id == id);
    } catch (failure) {
      if (authority.isCurrent &&
          failure is ApiException &&
          {403, 404}.contains(failure.statusCode)) {
        _orderAccessDenials[id] = authority;
        _notify();
      }
      if (authority.isCurrent &&
          failure is ApiException &&
          failure.statusCode == 0) {
        if (_orderAccessDenials[id]?.isCurrent == true) {
          throw const ApiException(
            'Доступ к наряду ранее был отклонён. Подключитесь к серверу для проверки; сохранённые данные и команды не удалены.',
            403,
          );
        }
        final cached = orders.where((item) => item.id == id);
        if (cached.isNotEmpty) {
          offline = true;
          return cached.first;
        }
      }
      if (authority.isCurrent &&
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
  bool get recoveringQueue => _recoveringQueue;
  bool hasQueuedWritesForOrder(int id) => _outboxCache.any(
    (command) =>
        command.kind != OutboxKind.markRead &&
        (command.orderId == id ||
            command.localRef == '$id' ||
            _resolvedIds[command.localRef] == id),
  );
  bool isOrderPending(int id) => hasQueuedWritesForOrder(id);
  OrderWriteBasis captureOrderBasis(WorkOrder order) {
    OutboxCommand? predecessor;
    for (final command in _outboxCache) {
      if (command.kind != OutboxKind.markRead &&
          (command.orderId == order.id ||
              command.localRef == '${order.id}' ||
              _resolvedIds[command.localRef] == order.id)) {
        predecessor = command;
      }
    }
    return predecessor == null
        ? OrderWriteBasis(expectedVersion: order.version)
        : OrderWriteBasis(previousCommandId: predecessor.commandId);
  }

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
    final token = source.token;
    final ownerId = user!.id;
    final role = user!.role;
    bool current() =>
        _current(session) &&
        reloadRevision == _outboxReloadRevision &&
        identical(api, source) &&
        source.token == token &&
        user?.id == ownerId &&
        user?.role == role;
    try {
      final store = await _local();
      if (!current()) return;
      final commands = await store.outbox();
      final relevant = commands
          .where((command) => _owns(command, source, ownerId))
          .toList();
      if (!current()) return;
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
        if (!current()) return;
        if (serverId != null) {
          mapped.add(ref);
          resolvedIds[ref] = serverId;
        }
      }
      if (!current()) return;
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
      final blockedOrders = <int>{};
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
        if (command.state == OutboxState.conflict) blockedOrders.add(id);
        if (!blockedOrders.contains(id)) {
          if (command.kind == OutboxKind.transition) {
            data['status'] = _transitionedStatus(
              command.payload['action'] as String,
            );
          } else if (command.kind == OutboxKind.complete) {
            data['status'] = 'completed';
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

  _QueueRecoveryScope _beginQueueRecovery() {
    if (user == null || _disposed) {
      throw const _QueueRecoveryFailure(
        QueueRecoveryStatus.scopeChanged,
        'Войдите в исходный аккаунт для просмотра очереди.',
      );
    }
    if (_recoveringQueue ||
        saving ||
        _writeLease != null ||
        _syncFuture != null) {
      throw const _QueueRecoveryFailure(
        QueueRecoveryStatus.busy,
        'Дождитесь завершения отправки или другого действия с очередью.',
      );
    }
    final session = _session;
    final source = api;
    final token = source.token;
    final ownerId = user!.id;
    final role = user!.role;
    final scope = _QueueRecoveryScope(source, ownerId, () {
      if (!_current(session) ||
          !identical(api, source) ||
          source.token != token ||
          user?.id != ownerId ||
          user?.role != role) {
        throw const _QueueRecoveryFailure(
          QueueRecoveryStatus.scopeChanged,
          'Контекст очереди изменился. Данные исходного аккаунта не перенесены.',
        );
      }
    });
    // Claim synchronously, before any storage await. New enqueue/sync cannot
    // sneak between this busy check and the durable recovery transaction.
    _recoveringQueue = true;
    _notify();
    return scope;
  }

  Future<_QueueRecoverySelection> _queueRecoverySelection(
    LocalStore store,
    _QueueRecoveryScope scope,
    String commandId,
  ) async {
    scope.ensureCurrent();
    final commands = await store.outbox();
    scope.ensureCurrent();
    final owned = commands
        .where((command) => _owns(command, scope.source, scope.ownerId))
        .map(
          (command) =>
              OutboxCommand.fromJson(freezeRecoveryJson(command.toJson())),
        )
        .toList();
    final index = owned.indexWhere((command) => command.commandId == commandId);
    if (index == -1) {
      throw const _QueueRecoveryFailure(
        QueueRecoveryStatus.notFound,
        'Команда отсутствует в очереди этого аккаунта и сервера.',
      );
    }
    final target = owned[index];
    final lane = await _lane(store, target);
    scope.ensureCurrent();
    final selected = <OutboxCommand>[];
    final retainedPhotos = <OutboxCommand>[];
    final laneCommands = <OutboxCommand>[];
    for (var i = 0; i < owned.length; i++) {
      final item = owned[i];
      final itemLane = await _lane(store, item);
      scope.ensureCurrent();
      if (itemLane != lane) continue;
      laneCommands.add(item);
      if (i >= index) selected.add(item);
      if (item.kind == OutboxKind.uploadPhoto) retainedPhotos.add(item);
    }
    if (laneCommands.any((command) => command.state == OutboxState.running)) {
      throw const _QueueRecoveryFailure(
        QueueRecoveryStatus.busy,
        'Команда этой цепочки сейчас отправляется. Дождитесь результата.',
      );
    }
    return _QueueRecoverySelection(selected, lane, retainedPhotos);
  }

  Future<QueueCommandInspectionResult> inspectCommand(String commandId) async {
    var claimed = false;
    _QueueRecoveryScope? scope;
    try {
      scope = _beginQueueRecovery();
      claimed = true;
      scope.ensureCurrent();
      final store = await _local();
      scope.ensureCurrent();
      final selection = await _queueRecoverySelection(store, scope, commandId);
      scope.ensureCurrent();
      final photos = <String, Uint8List>{};
      final warnings = <String, String>{};
      for (final command in selection.retainedPhotos) {
        try {
          final bytes = await store.outboxPhoto(command.commandId);
          scope.ensureCurrent();
          if (bytes == null) {
            warnings[command.commandId] =
                'Файл фото недоступен. Метаданные команды сохранены.';
          } else {
            photos[command.commandId] = bytes;
          }
        } on _QueueRecoveryFailure {
          rethrow;
        } catch (_) {
          scope.ensureCurrent();
          warnings[command.commandId] = 'Не удалось прочитать локальное фото. Метаданные команды сохранены.';
        }
      }
      final id = selection.lane.startsWith('order:')
          ? int.tryParse(selection.lane.substring('order:'.length))
          : null;
      final cached = orders.where((order) => order.id == id).firstOrNull;
      WorkOrder? cachedOrder;
      if (cached != null && cached.id > 0) {
        final data = cached.toJson();
        final serverStatus = data.remove('_server_status');
        if (serverStatus is String) data['status'] = serverStatus;
        data.remove('_pending_sync');
        data.remove('_queued_status');
        cachedOrder = WorkOrder.fromJson(data);
      }
      scope.ensureCurrent();
      return QueueCommandInspectionResult(
        QueueRecoveryStatus.success,
        'Сохранённые данные команды. Текущее состояние сервера не проверялось.',
        inspection: QueueCommandInspection(
          command: selection.commands.first,
          dependentCommands: selection.commands.skip(1).toList(),
          preparedPhotoBytesByCommandId: photos,
          mediaWarnings: warnings,
          retainedPhotoCommands: selection.retainedPhotos,
          cachedOrder: cachedOrder,
        ),
      );
    } on _QueueRecoveryFailure catch (failure) {
      return QueueCommandInspectionResult(failure.status, failure.message);
    } catch (_) {
      try {
        scope?.ensureCurrent();
      } on _QueueRecoveryFailure catch (failure) {
        return QueueCommandInspectionResult(failure.status, failure.message);
      }
      return const QueueCommandInspectionResult(
        QueueRecoveryStatus.storageFailure,
        'Не удалось прочитать очередь на устройстве. Данные не изменены.',
      );
    } finally {
      if (claimed) {
        _recoveringQueue = false;
        _notify();
      }
    }
  }

  Future<QueueActionResult> retryCommand(String commandId) =>
      _mutateQueueCommand(commandId, discard: false);

  Future<QueueActionResult> discardCommand(
    String commandId, {
    List<String>? expectedCommandIds,
    List<OutboxCommand>? expectedCommands,
  }) => _mutateQueueCommand(
    commandId,
    discard: true,
    expectedCommandIds: expectedCommandIds == null
        ? null
        : List.unmodifiable(expectedCommandIds),
    expectedCommands: expectedCommands == null
        ? null
        : List.unmodifiable(
            expectedCommands.map(
              (command) =>
                  OutboxCommand.fromJson(freezeRecoveryJson(command.toJson())),
            ),
          ),
  );

  Future<QueueActionResult> _mutateQueueCommand(
    String commandId, {
    required bool discard,
    List<String>? expectedCommandIds,
    List<OutboxCommand>? expectedCommands,
  }) async {
    var claimed = false;
    var committed = false;
    var resume = false;
    var ids = <String>[];
    String? warning;
    _QueueRecoveryScope? scope;
    try {
      scope = _beginQueueRecovery();
      claimed = true;
      scope.ensureCurrent();
      final store = await _local();
      scope.ensureCurrent();
      final selection = await _queueRecoverySelection(store, scope, commandId);
      scope.ensureCurrent();
      ids = selection.commands.map((command) => command.commandId).toList();
      if (discard &&
          ((expectedCommandIds != null &&
                  !listEquals(expectedCommandIds, ids)) ||
              (expectedCommands != null &&
                  jsonEncode(
                        expectedCommands
                            .map((command) => command.toJson())
                            .toList(),
                      ) !=
                      jsonEncode(
                        selection.commands
                            .map((command) => command.toJson())
                            .toList(),
                      )))) {
        throw const _QueueRecoveryFailure(
          QueueRecoveryStatus.changed,
          'Данные или состав цепочки изменились. Откройте её заново перед удалением.',
        );
      }
      final command = selection.commands.first;
      if (!discard && !command.canRetry) {
        throw const _QueueRecoveryFailure(
          QueueRecoveryStatus.notRetryable,
          'Нельзя повторить действие с неизвестным или конфликтующим основанием. Сохранённые данные не изменены.',
        );
      }
      final activeScope = scope;
      final mappingKeys = discard && command.kind == OutboxKind.createOrder
          ? selection.commands
                .map((command) => command.localRef)
                .whereType<String>()
                .map(
                  (ref) => localScopeKey(
                    activeScope.source.baseUrl,
                    activeScope.ownerId,
                    ref,
                  ),
                )
                .toSet()
                .toList()
          : <String>[];
      final result = await store.recoverOutbox(
        selection.commands,
        // Keep the previous response: a local retry does not prove that an
        // unknown previous server result disappeared or that rights returned.
        replacement: discard
            ? null
            : command.copyWith(state: OutboxState.pending, attempts: 0),
        serverIdKeys: mappingKeys,
        ensureCurrent: scope.ensureCurrent,
      );
      committed = result.committed;
      warning = result.cleanupWarning;
      scope.ensureCurrent();
      if (result.status == OutboxRecoveryCommitStatus.busy) {
        throw const _QueueRecoveryFailure(
          QueueRecoveryStatus.busy,
          'Команда сейчас отправляется. Дождитесь результата.',
        );
      }
      if (!committed) {
        throw const _QueueRecoveryFailure(
          QueueRecoveryStatus.changed,
          'Сохранённая цепочка изменилась. Откройте её заново.',
        );
      }
      if (!discard) ids = [commandId];
      await _reloadOutbox();
      scope.ensureCurrent();
      final cacheUpdated = discard
          ? !_outboxCache.any((command) => ids.contains(command.commandId))
          : _outboxCache.any(
              (command) =>
                  command.commandId == commandId &&
                  command.state == OutboxState.pending &&
                  command.attempts == 0,
            );
      if (!cacheUpdated) {
        warning ??= 'Данные очереди сохранены. Не удалось обновить её список.';
      }
      resume = !discard && !offline;
      return QueueActionResult(
        QueueRecoveryStatus.success,
        discard
            ? 'Цепочка удалена только из локальной очереди. Серверные действия не отменены.'
            : 'Та же команда снова готова к отправке. Результат сервера пока не подтверждён.',
        changed: true,
        warning: warning,
        commandIds: ids,
      );
    } on _QueueRecoveryFailure catch (failure) {
      return QueueActionResult(
        failure.status,
        failure.message,
        changed: committed,
        warning: warning,
        commandIds: committed ? ids : const [],
      );
    } catch (_) {
      try {
        scope?.ensureCurrent();
      } on _QueueRecoveryFailure catch (failure) {
        return QueueActionResult(
          failure.status,
          failure.message,
          changed: committed,
          warning: warning,
          commandIds: committed ? ids : const [],
        );
      }
      return QueueActionResult(
        QueueRecoveryStatus.storageFailure,
        committed
            ? 'Очередь изменена на устройстве, но её список не удалось обновить.'
            : 'Не удалось изменить очередь на устройстве. Цепочка сохранена.',
        changed: committed,
        warning: warning,
        commandIds: committed ? ids : const [],
      );
    } finally {
      if (claimed) {
        _recoveringQueue = false;
        _notify();
        if (resume && scope != null) {
          try {
            scope.ensureCurrent();
            unawaited(syncOutbox());
          } on _QueueRecoveryFailure {
            // A changed session never resumes another owner's exact command.
          }
        }
      }
    }
  }

  Future<void> syncOutbox() {
    if (_syncFuture != null) return _syncFuture!;
    if (user == null ||
        saving ||
        _writeLease != null ||
        _recoveringQueue ||
        _disposed) {
      return Future.value();
    }
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
    final authority = captureNavigationScope();
    try {
      final store = await _local();
      if (!_current(session) || !authority.isCurrent) return;
      final commands = await store.outbox();
      final relevant = commands
          .where((command) => _owns(command, source, ownerId))
          .toList();
      if (relevant.isEmpty) return;
      var sent = false;
      final blocked = <String>{};
      for (final command in relevant) {
        if (!_current(session) || !authority.isCurrent) break;
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
          authority,
        );
        if (handled) {
          sent = true;
        } else {
          blocked.add(lane);
        }
      }
      if (sent && _current(session) && authority.isCurrent) {
        // Drain the read started before the queued write, then fetch a new
        // snapshot instead of coalescing with a stale in-flight refresh.
        try {
          await _refreshFuture;
        } catch (_) {}
        if (!_current(session) || !authority.isCurrent) return;
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
    NavigationScope authority,
  ) async {
    if (!_current(session) || !authority.isCurrent) return false;
    await store.updateOutbox(command.copyWith(state: OutboxState.running));
    if (!_current(session) || !authority.isCurrent) {
      await store.updateOutbox(command.copyWith(state: OutboxState.pending));
      return false;
    }
    try {
      final result = await _executeCommand(
        store,
        source,
        command,
        orderId,
        ensureCurrent: () {
          if (!_current(session) || !authority.isCurrent) {
            throw const ApiException('Сессия или права изменились.', 401);
          }
        },
      );
      if (!_current(session) || !authority.isCurrent) {
        await store.updateOutbox(command.copyWith(state: OutboxState.pending));
        return false;
      }
      await store.removeOutbox(command.commandId);
      if (!_current(session) || !authority.isCurrent) return true;
      ++_dataRevision;
      if (result is WorkOrder) _upsert(result);
      await _reloadOutbox();
      return true;
    } on ApiException catch (failure) {
      if (!_current(session) || !authority.isCurrent) {
        await store.updateOutbox(command.copyWith(state: OutboxState.pending));
        return false;
      }
      if (failure.statusCode == 401) {
        await store.updateOutbox(
          command.copyWith(
            state: OutboxState.pending,
            responseStatus: 401,
            lastError: failure.message,
          ),
        );
        if (_current(session) && authority.isCurrent) _expireSession();
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
          : failure.code == 'order_version_conflict' ||
                failure.code == 'order_precondition_unavailable'
          ? '${failure.message} Текст и фото сохранены. Удалите эту цепочку из очереди, обновите наряд и создайте нужное действие заново.'
          : failure.toString();
      await store.updateOutbox(
        command.copyWith(
          state: state,
          attempts: command.attempts + 1,
          responseStatus: failure.statusCode,
          response: failure.detail,
          lastError: message,
        ),
      );
      await _reloadOutbox();
      return false;
    } catch (failure) {
      if (!_current(session) || !authority.isCurrent) {
        await store.updateOutbox(command.copyWith(state: OutboxState.pending));
        return false;
      }
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
    int orderId, {
    void Function()? ensureCurrent,
  }) async {
    ensureCurrent?.call();
    if (!command.hasOrderPrecondition) {
      throw const ApiException(
        'Версия наряда неизвестна. Текст и фото сохранены. Обновите наряд и создайте действие заново.',
        428,
        detail: {'code': 'local_order_precondition_unavailable'},
      );
    }
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
          expectedVersion: command.expectedVersion,
          previousCommandId: command.previousCommandId,
        );
      case OutboxKind.complete:
        return source.complete(
          orderId,
          command.payload,
          commandId: command.commandId,
          expectedVersion: command.expectedVersion,
          previousCommandId: command.previousCommandId,
        );
      case OutboxKind.uploadPhoto:
        final bytes = await store.outboxPhoto(command.commandId);
        ensureCurrent?.call();
        if (bytes == null) {
          throw const ApiException('Локальная фотография недоступна.', 422);
        }
        await source.uploadPhoto(
          orderId,
          bytes,
          command.photoFilename ?? 'photo.jpg',
          command.photoKind ?? 'before',
          commandId: command.commandId,
          expectedVersion: command.expectedVersion,
          previousCommandId: command.previousCommandId,
        );
        return command.commandId;
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
    OrderWriteBasis? basis,
  }) async {
    if (user == null) throw const ApiException('Войдите в приложение.', 401);
    if (saving || _writeLease != null || _recoveringQueue) {
      throw const ApiException(
        'Дождитесь завершения предыдущего действия.',
        409,
      );
    }
    final session = _session;
    final source = api;
    final ownerId = user!.id;
    final token = source.token;
    final role = user!.role;
    final authority = captureNavigationScope();
    final commandId = _newCommandId();
    final lease = Completer<void>();
    _writeLease = lease;
    bool currentWrite() =>
        authority.isCurrent &&
        _current(session) &&
        identical(api, source) &&
        source.token == token &&
        user?.id == ownerId &&
        user?.role == role &&
        identical(_writeLease, lease);
    void ensureCurrent() {
      if (!currentWrite()) {
        throw const ApiException('Сессия или права изменились.', 401);
      }
    }

    saving = true;
    error = null;
    _notify();
    try {
      await _syncFuture;
      ensureCurrent();
      LocalStore store;
      try {
        store = await _local();
      } catch (_) {
        ensureCurrent();
        throw const ApiException(
          'Не удалось сохранить действие на устройстве. Оно не отправлено. Проверьте свободное место и повторите.',
          507,
        );
      }
      ensureCurrent();
      final previous = (await store.outbox())
          .where((item) => _owns(item, source, ownerId))
          .toList();
      ensureCurrent();
      var createdAt = DateTime.now().millisecondsSinceEpoch;
      for (final item in previous) {
        if (item.createdAt >= createdAt) createdAt = item.createdAt + 1;
      }
      final probe = OutboxCommand(
        commandId: commandId,
        kind: kind,
        createdAt: createdAt,
        ownerId: ownerId,
        serverUrl: source.baseUrl,
        orderId: orderId,
        localRef: localRef,
      );
      final lane = await _lane(store, probe);
      ensureCurrent();
      OutboxCommand? predecessor;
      if (basis == null &&
          kind != OutboxKind.createOrder &&
          kind != OutboxKind.markRead) {
        for (final item in previous) {
          final itemLane = await _lane(store, item);
          ensureCurrent();
          if (itemLane == lane) predecessor = item;
        }
      }
      final cachedId = orderId ?? int.tryParse(localRef ?? '');
      final cached = orders.where((order) => order.id == cachedId).firstOrNull;
      final capturedBasis =
          basis ?? OrderWriteBasis(expectedVersion: cached?.version);
      // Both the key and media must exist on disk BEFORE any HTTP write.
      // A killed process can then replay the exact same command safely.
      late OutboxCommand command;
      ensureCurrent();
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
            expectedVersion: predecessor == null
                ? capturedBasis.expectedVersion
                : null,
            previousCommandId:
                predecessor?.commandId ?? capturedBasis.previousCommandId,
            payload: jsonDecode(jsonEncode(payload)) as Json,
            photoFilename: photoFilename,
            photoKind: photoKind,
          ),
          photoBytes: photoBytes,
        );
      } catch (_) {
        ensureCurrent();
        throw const ApiException(
          'Не удалось сохранить действие на устройстве. Оно не отправлено. Проверьте свободное место и повторите.',
          507,
        );
      }
      ensureCurrent();
      Future<dynamic> queuedResult() async {
        ensureCurrent();
        final result = onOffline(command);
        ++_dataRevision;
        if (result is WorkOrder) _upsert(result);
        await _reloadOutbox();
        ensureCurrent();
        await _persistSnapshot(session, force: true);
        ensureCurrent();
        return result is WorkOrder
            ? orders.firstWhere(
                (order) => order.id == result.id,
                orElse: () => result,
              )
            : result;
      }

      if (!command.hasOrderPrecondition) {
        await store.updateOutbox(
          command.copyWith(
            state: OutboxState.conflict,
            response: {'code': 'local_order_precondition_unavailable'},
            lastError: 'Версия наряда неизвестна. Текст и фото сохранены. Обновите наряд и создайте действие заново.',
          ),
        );
        ensureCurrent();
        await _reloadOutbox();
        ensureCurrent();
        await _persistSnapshot(session, force: true);
        ensureCurrent();
        throw const ApiException(
          'Версия наряда неизвестна. Действие сохранено в очереди как конфликт. Обновите наряд и создайте действие заново.',
          428,
          detail: {'code': 'local_order_precondition_unavailable'},
        );
      }

      var resolvedId = orderId;
      if (resolvedId == null &&
          localRef != null &&
          kind != OutboxKind.createOrder) {
        resolvedId = await store.serverId(
          _scope(localRef, source: source, ownerId: ownerId),
        );
        ensureCurrent();
      }
      var hasPredecessor = false;
      for (final item in previous) {
        final itemLane = await _lane(store, item);
        ensureCurrent();
        if (itemLane == lane) {
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
        ensureCurrent();
        final result = await _executeCommand(
          store,
          source,
          command,
          resolvedId ?? 0,
          ensureCurrent: ensureCurrent,
        );
        if (!currentWrite()) {
          throw const ApiException(
            'Сессия изменилась. Проверьте результат действия перед повтором.',
            401,
            requestMayHaveSucceeded: true,
          );
        }
        await store.removeOutbox(commandId);
        if (!currentWrite()) {
          throw const ApiException(
            'Сессия изменилась. Проверьте результат действия перед повтором.',
            401,
            requestMayHaveSucceeded: true,
          );
        }
        ++_dataRevision;
        if (result is WorkOrder) _upsert(result);
        await _reloadOutbox();
        ensureCurrent();
        try {
          await _refreshFuture;
        } catch (_) {}
        if (!currentWrite()) {
          throw const ApiException(
            'Сессия изменилась. Проверьте результат действия перед повтором.',
            401,
            requestMayHaveSucceeded: true,
          );
        }
        try {
          await refresh(silent: true);
        } catch (failure) {
          if (currentWrite()) {
            error =
                'Действие сохранено, но обновить данные не удалось: $failure';
          }
        }
        if (!currentWrite()) {
          throw const ApiException(
            'Сессия изменилась. Проверьте результат действия перед повтором.',
            401,
            requestMayHaveSucceeded: true,
          );
        }
        return result;
      } on ApiException catch (failure) {
        if (!currentWrite() || failure.statusCode == 401) {
          await store.updateOutbox(
            command.copyWith(
              state: OutboxState.pending,
              responseStatus:
                  failure.statusCode == 401 && failure.requestMayHaveSucceeded
                  ? 0
                  : failure.statusCode,
              lastError: failure.message,
            ),
          );
          rethrow;
        }
        if (failure.statusCode != 0 && !failure.requestMayHaveSucceeded) {
          if (failure.code == 'order_version_conflict' ||
              failure.code == 'order_precondition_unavailable') {
            await store.updateOutbox(
              command.copyWith(
                state: OutboxState.conflict,
                responseStatus: failure.statusCode,
                response: failure.detail,
                lastError:
                    '${failure.message} Текст и фото сохранены. Удалите эту цепочку из очереди, обновите наряд и создайте нужное действие заново.',
              ),
            );
            await _reloadOutbox();
            await _persistSnapshot(session, force: true);
            rethrow;
          }
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
      if (currentWrite()) {
        if (failure is ApiException && failure.statusCode == 401) {
          _expireSession();
        } else {
          error = failure.toString();
        }
      }
      rethrow;
    } finally {
      if (identical(_writeLease, lease)) _writeLease = null;
      lease.complete();
      if (_current(session)) {
        saving = false;
      }
      _notify();
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
      'brigade_id': data['brigade_id'],
      // Requested responsible and current roster are not a server receipt.
      'participants': <Json>[],
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
    OrderWriteBasis? basis,
  }) async {
    if (const {
      'accept',
      'queue',
      'reject',
      'start',
      'pause',
      'resume',
    }.contains(action)) {
      _requireResponsibleForKnownOrder(id);
    }
    final result = await _save(
      kind: OutboxKind.transition,
      payload: {'action': action, 'reason': reason, 'score': score},
      orderId: id >= 0 ? id : null,
      localRef: id < 0 ? '$id' : null,
      basis: basis,
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

  Future<WorkOrder> complete(
    int id,
    Json data, {
    OrderWriteBasis? basis,
  }) async {
    _requireResponsibleForKnownOrder(id);
    final result = await _save(
      kind: OutboxKind.complete,
      payload: data,
      orderId: id >= 0 ? id : null,
      localRef: id < 0 ? '$id' : null,
      basis: basis,
      onOffline: (command) {
        final updated = _offlineOrderState(id);
        final updatedData = Map<String, dynamic>.from(updated.data);
        updatedData['status'] = 'completed';
        updatedData['_queued_status'] = updated.data['status'];
        updatedData['completed_at'] = DateTime.now().toIso8601String();
        return WorkOrder.fromJson(updatedData);
      },
    );
    return result as WorkOrder;
  }

  void _requireResponsibleForKnownOrder(int id) {
    final current = orders.where((order) => order.id == id).firstOrNull;
    if (user?.isWorker == true &&
        current != null &&
        !current.isResponsible(user!.id)) {
      throw const ApiException(
        'Действие доступно только ответственному за наряд.',
        403,
      );
    }
  }

  Future<String> uploadPhoto(
    int id,
    Uint8List bytes,
    String filename,
    String kind, {
    OrderWriteBasis? basis,
  }) async {
    if (!['before', 'after'].contains(kind)) {
      throw const ApiException('Неизвестный тип фотографии.', 422);
    }
    if (bytes.length > 10 * 1024 * 1024) {
      throw const ApiException('Фотография больше допустимых 10 МБ.', 413);
    }
    final result = await _save(
      kind: OutboxKind.uploadPhoto,
      payload: {'order_id': id},
      orderId: id >= 0 ? id : null,
      localRef: id < 0 ? '$id' : null,
      basis: basis,
      photoBytes: bytes,
      photoFilename: filename,
      photoKind: kind,
      onOffline: (command) => command.commandId,
    );
    return result as String;
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

class _ReferenceEditContext {
  const _ReferenceEditContext(
    this.session,
    this.source,
    this.scope,
    this.authorityCurrent,
  );
  final int session;
  final NaryadApi source;
  final ReferenceEditScope scope;
  final bool Function() authorityCurrent;
}

class _QueueRecoveryScope {
  const _QueueRecoveryScope(this.source, this.ownerId, this.ensureCurrent);

  final NaryadApi source;
  final int ownerId;
  final void Function() ensureCurrent;
}

class _QueueRecoverySelection {
  const _QueueRecoverySelection(this.commands, this.lane, this.retainedPhotos);

  final List<OutboxCommand> commands;
  final String lane;
  final List<OutboxCommand> retainedPhotos;
}

class _QueueRecoveryFailure implements Exception {
  const _QueueRecoveryFailure(this.status, this.message);

  final QueueRecoveryStatus status;
  final String message;
}
