import 'package:flutter/foundation.dart';

import 'api.dart';
import 'app_controller.dart';
import 'models.dart';
import 'order_journal.dart';

/// This view owns only its loaded pages. The app's offline snapshot and command
/// queue are managed independently by AppController.
class OrderJournalController extends ChangeNotifier {
  OrderJournalController(
    AppController app, {
    OrderJournalQuery query = const OrderJournalQuery(),
    bool equipmentHistory = false,
  }) : this._(app, query, equipmentHistory);

  OrderJournalController._(this.app, this._query, this.equipmentHistory) {
    _captureSession();
    app.addListener(_appChanged);
  }

  final AppController app;
  final bool equipmentHistory;
  OrderJournalQuery _query;
  OrderJournalQuery get query => _query;
  List<WorkOrder> items = [];
  EquipmentDetails? equipment;
  String? nextCursor, error;
  int? total;
  bool loading = false;
  int _generation = 0;
  bool _disposed = false;
  late NaryadApi _api;
  String? _token, _role;
  int? _ownerId;
  bool get allowed =>
      app.user != null &&
      const {'master', 'admin', 'manager', 'worker'}.contains(app.user?.role) &&
      (!equipmentHistory ||
          const {'master', 'admin', 'manager'}.contains(app.user?.role));

  void _captureSession() {
    _api = app.api;
    _token = app.api.token;
    _ownerId = app.user?.id;
    _role = app.user?.role;
  }

  bool get _sameSession =>
      identical(app.api, _api) &&
      app.api.token == _token &&
      app.user?.id == _ownerId &&
      app.user?.role == _role;

  void _appChanged() {
    if (_disposed) return;
    if (!_sameSession) {
      _generation++;
      loading = false;
      items = [];
      equipment = null;
      nextCursor = null;
      total = null;
      error = 'Аккаунт или сервер изменился. Откройте журнал заново.';
      // Never carry the old cursor/data across this boundary.
      _captureSession();
    }
    notifyListeners();
  }

  Future<void> replaceQuery(OrderJournalQuery value) {
    if (query.equipmentId != value.equipmentId) equipment = null;
    _query = value;
    _generation++;
    loading = false;
    items = [];
    nextCursor = null;
    total = null;
    error = null;
    return refresh();
  }

  Future<void> refresh() => _load(append: false);
  Future<void> loadMore() async {
    if (loading || nextCursor == null) return;
    await _load(append: true);
  }

  Future<void> _load({required bool append}) async {
    if (_disposed) return;
    if (!_sameSession) _appChanged();
    if (!allowed) {
      _generation++;
      loading = false;
      error = 'Недостаточно прав для этого журнала.';
      notifyListeners();
      return;
    }
    if (app.offline) {
      _generation++;
      loading = false;
      error = 'Нет соединения. Полная серверная история недоступна. Сохранённые наряды можно открыть в обычном списке.';
      notifyListeners();
      return;
    }
    final generation = ++_generation;
    final requestQuery = query;
    final requestCursor = append ? nextCursor : null;
    loading = true;
    error = null;
    notifyListeners();
    bool current() => !_disposed && generation == _generation && _sameSession;
    try {
      EquipmentDetails? metadata = equipment;
      if (equipmentHistory && query.equipmentId != null && metadata == null) {
        metadata = await app.loadEquipmentDetails(query.equipmentId!);
        if (!current()) return;
      }
      final page = await app.loadOrderPage(requestQuery, cursor: requestCursor);
      if (!current()) return;
      final merged = <int, WorkOrder>{
        if (append)
          for (final order in items) order.id: order,
      };
      for (final order in page.items) {
        final previous = merged[order.id];
        if (previous?.version != null &&
            (order.version == null || previous!.version! > order.version!)) {
          continue;
        }
        // Updating an existing key preserves its first position in the window.
        merged[order.id] = order;
      }
      items = List.unmodifiable(merged.values);
      equipment = metadata;
      total = page.total;
      nextCursor = page.nextCursor;
    } catch (failure) {
      if (current()) error = '$failure';
    } finally {
      if (!_disposed && !_sameSession) {
        _appChanged();
      }
      if (current()) {
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    app.removeListener(_appChanged);
    super.dispose();
  }
}
