import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_controller.dart';
import '../data/models.dart';
import '../domain/reference_edit.dart';
import '../ui.dart';

String _collectionLabel(ReferenceCollection collection) =>
    collection == ReferenceCollection.equipment ? 'Оборудование' : 'Материалы';
String _collectionKey(ReferenceCollection collection) =>
    collection == ReferenceCollection.equipment ? 'equipment' : 'materials';

bool _validRow(String key, Object? row) {
  if (row is! Json || row['id'] is! int || (row['id'] as int) <= 0) {
    return false;
  }
  if (key == 'equipment') {
    return isCompleteReferenceRow(ReferenceCollection.equipment, row);
  }
  if (key == 'materials') {
    return isCompleteReferenceRow(ReferenceCollection.materials, row);
  }
  return row['name'] is String && (row['name'] as String).trim().isNotEmpty;
}

List<Json> _rows(AppController controller, String key) {
  final raw = controller.reference[key];
  if (raw is! List) return [];
  final ids = <int>{};
  return [
    for (final row in raw)
      if (_validRow(key, row) && ids.add((row as Json)['id'] as int))
        Map<String, dynamic>.from(row),
  ];
}

bool _invalidSection(AppController controller, String key) {
  final raw = controller.reference[key];
  if (raw is! List) return true;
  final ids = <int>{};
  return raw.any(
    (row) => !_validRow(key, row) || !ids.add((row as Json)['id'] as int),
  );
}

Json _copy(Json values) => jsonDecode(jsonEncode(values)) as Json;

// Remove only this view; descendants also observe the same captured scope.
// removeRoute deliberately bypasses dirty/busy Back guards on scope revocation.
void _closeProtectedRoute(BuildContext context, Route<dynamic>? route) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!context.mounted || route?.isActive != true || route!.isFirst) return;
    Navigator.of(context).removeRoute(route);
  });
}

class ReferenceCatalogScreen extends StatefulWidget {
  const ReferenceCatalogScreen({required this.controller, super.key});
  final AppController controller;

  @override
  State<ReferenceCatalogScreen> createState() => _ReferenceCatalogScreenState();
}

class _ReferenceCatalogScreenState extends State<ReferenceCatalogScreen> {
  late final ReferenceEditScope _scope;
  final _search = TextEditingController();
  ReferenceCollection _collection = ReferenceCollection.equipment;
  ModalRoute<dynamic>? _route;
  bool _revoked = false, _refreshing = false;
  String? _error;

  AppController get _controller => widget.controller;
  bool get _current => !_revoked && _scope.isCurrent;
  bool get _busy =>
      _refreshing || _controller.referenceWriteBusy || _controller.restoring;

  @override
  void initState() {
    super.initState();
    try {
      _scope = _controller.captureReferenceScope();
    } catch (_) {
      _scope = ReferenceEditScope(() => false);
    }
    _controller.addListener(_changed);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(ReferenceCatalogScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, _controller)) {
      oldWidget.controller.removeListener(_changed);
      _controller.addListener(_changed);
      _revoke();
    }
  }

  void _revoke() {
    _revoked = true;
    _closeProtectedRoute(context, _route);
  }

  void _changed() {
    if (!mounted) return;
    if (!_current) _revoke();
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _search.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!_current || _busy) return;
    setState(() {
      _refreshing = true;
      _error = null;
    });
    try {
      final result = await _controller.refreshReferences(_scope);
      if (!mounted || !_current) return;
      if (result.status == ReferenceRefreshStatus.scopeChanged) {
        setState(_revoke);
      } else if (result.status != ReferenceRefreshStatus.refreshed) {
        setState(
          () => _error = result.error?.message ?? 'Не удалось обновить справочники. Показаны последние полученные данные.',
        );
      }
    } catch (_) {
      if (mounted && _current) {
        setState(
          () => _error = 'Не удалось обновить справочники. Показаны последние полученные данные.',
        );
      }
    } finally {
      if (mounted && _current) setState(() => _refreshing = false);
    }
  }

  Future<void> _open({int? id, ReferenceEditTicket? retained}) async {
    if (!_current || _busy) return;
    try {
      final ticket =
          retained ??
          _controller.openReferenceEdit(
            _collection,
            id: id,
            newOperation: true,
          );
      if (!ticket.isCurrent) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) =>
              ReferenceEditorScreen(controller: _controller, ticket: ticket),
        ),
      );
    } catch (_) {
      if (mounted && _current) {
        setState(
          () => _error =
              'Не удалось открыть запись. Обновите справочник и повторите.',
        );
      }
    }
    if (mounted && _current) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!_current || !_controller.canManageReferences) {
      return Scaffold(
        appBar: AppBar(title: const Text('Справочники')),
        body: const Padding(
          padding: EdgeInsets.all(20),
          child: Text('Справочники доступны администратору.'),
        ),
      );
    }
    final search = _search.text.trim().toLowerCase();
    final invalidCatalog =
        _invalidSection(_controller, _collectionKey(_collection)) ||
        (_collection == ReferenceCollection.equipment &&
            _invalidSection(_controller, 'areas'));
    final areas = {
      for (final area in _rows(_controller, 'areas'))
        area['id']: '${area['name']}',
    };
    final tickets = _controller.referenceEdits
        .where(
          (ticket) =>
              ticket.isCurrent &&
              ticket.collection == _collection &&
              ticket.state == ReferenceEditState.uncertain,
        )
        .toList();
    final rows = _rows(_controller, _collectionKey(_collection))
        .where(
          (row) =>
              [
                row['name'],
                row['inventory_number'],
                row['unit'],
                row['type'],
                row['criticality'],
                areas[row['area_id']],
              ].whereType<String>().any(
                (value) => value.toLowerCase().contains(search),
              ),
        )
        .toList();
    final uncertainCreate = tickets
        .where((ticket) => ticket.id == null)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Справочники'),
        actions: [
          IconButton(
            tooltip: 'Обновить справочники',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(20),
              children: [
                const Text(
                  'Оборудование и материалы',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Изменения сохраняются на сервере. Для сохранения требуется соединение.',
                  style: TextStyle(color: muted),
                ),
                const SizedBox(height: 20),
                SegmentedButton<ReferenceCollection>(
                  segments: const [
                    ButtonSegment(
                      value: ReferenceCollection.equipment,
                      label: Text('Оборудование'),
                    ),
                    ButtonSegment(
                      value: ReferenceCollection.materials,
                      label: Text('Материалы'),
                    ),
                  ],
                  selected: {_collection},
                  onSelectionChanged: (values) => setState(() {
                    _collection = values.single;
                    _search.clear();
                  }),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    labelText: 'Поиск в справочнике',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed:
                      _busy ||
                          _controller.offline ||
                          (invalidCatalog && uncertainCreate == null)
                      ? null
                      : () => _open(retained: uncertainCreate),
                  icon: Icon(
                    uncertainCreate == null
                        ? Icons.add
                        : Icons.description_outlined,
                  ),
                  label: Text(
                    uncertainCreate == null
                        ? 'Добавить'
                        : 'Посмотреть неподтверждённый ввод',
                  ),
                ),
                if (_controller.offline)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: InfoPanel(
                      'Нет соединения. Справочники доступны для просмотра, новые изменения не отправляются.',
                      icon: Icons.cloud_off_outlined,
                    ),
                  ),
                if (_busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: InfoPanel(
                      'Дождитесь завершения текущей операции.',
                      icon: Icons.hourglass_top,
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: InfoPanel(_error!, color: danger),
                  ),
                if (invalidCatalog)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: InfoPanel(
                      'Не удалось прочитать часть справочника. Обновите данные.',
                      color: danger,
                    ),
                  ),
                for (final ticket in tickets)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: InfoPanel(
                      'Результат отправки не подтверждён. Повторная отправка этого ввода заблокирована.',
                      color: const Color(0xff8c5a00),
                      action: TextButton(
                        onPressed: _busy ? null : () => _open(retained: ticket),
                        child: const Text('Посмотреть ввод'),
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                Text(
                  'Найдено: ${rows.length}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (rows.isEmpty && !invalidCatalog)
                  const InfoPanel(
                    'Записей не найдено.',
                    icon: Icons.inventory_2_outlined,
                  ),
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Card(
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(16),
                        title: Text(
                          '${row['name']}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        subtitle: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _collection == ReferenceCollection.equipment
                                ? 'Инв. № ${row['inventory_number']}\n${areas[row['area_id']] ?? 'Участок #${row['area_id']}'} · ${row['type']}\nКритичность: ${row['criticality']}'
                                : 'Единица измерения: ${row['unit']}',
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: 'Изменить ${row['name']}',
                          onPressed:
                              _busy || _controller.offline || invalidCatalog
                              ? null
                              : () => _open(id: row['id'] as int),
                          icon: const Icon(Icons.edit_outlined),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class ReferenceEditorScreen extends StatefulWidget {
  const ReferenceEditorScreen({
    required this.controller,
    required this.ticket,
    super.key,
  });
  final AppController controller;
  final ReferenceEditTicket ticket;

  @override
  State<ReferenceEditorScreen> createState() => _ReferenceEditorScreenState();
}

class _ReferenceEditorScreenState extends State<ReferenceEditorScreen> {
  final _form = GlobalKey<FormState>();
  final Map<String, TextEditingController> _fields = {};
  late final Json _initial;
  late final ReferenceEditScope _scope;
  int? _area;
  ModalRoute<dynamic>? _route;
  DialogRoute<bool>? _confirmation;
  bool _revoked = false,
      _working = false,
      _refreshing = false,
      _allowPop = false;
  String? _error;
  bool _refreshFailed = false;
  Map<String, String> _fieldErrors = {};

  AppController get _controller => widget.controller;
  ReferenceEditTicket get _ticket => widget.ticket;
  bool get _current => !_revoked && _scope.isCurrent && _ticket.isCurrent;
  bool get _equipment => _ticket.collection == ReferenceCollection.equipment;
  bool get _frozen =>
      _ticket.state == ReferenceEditState.saved ||
      _ticket.state == ReferenceEditState.uncertain;
  bool get _busy =>
      _working ||
      _refreshing ||
      _controller.referenceWriteBusy ||
      _controller.restoring;
  Json get _values => {
    for (final entry in _fields.entries) entry.key: entry.value.text,
    if (_equipment) 'area_id': _area,
  };
  bool get _dirty => jsonEncode(_values) != jsonEncode(_initial);

  @override
  void initState() {
    super.initState();
    _scope = _ticket.scope;
    final initial = _copy(_ticket.initialValues);
    final fieldNames = _equipment
        ? ['name', 'inventory_number', 'type', 'criticality']
        : ['name', 'unit'];
    _initial = {
      for (final key in fieldNames)
        key: '${initial[key] ?? (key == 'criticality' ? 'medium' : '')}',
      if (_equipment) 'area_id': initial['area_id'],
    };
    final retained = {..._initial, ...?_ticket.submittedValues};
    for (final key in fieldNames) {
      _fields[key] = TextEditingController(text: '${retained[key] ?? ''}')
        ..addListener(_inputChanged);
    }
    _area = retained['area_id'] as int?;
    if (_ticket.lastResult?.status == ReferenceMutationStatus.rejected) {
      _error = _ticket.lastResult?.error?.message;
      _fieldErrors = _ticket.lastResult?.error?.fieldErrors ?? {};
    }
    _controller.addListener(_changed);
  }

  void _inputChanged() {
    if (mounted) setState(() => _fieldErrors = {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
  }

  @override
  void didUpdateWidget(ReferenceEditorScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, _controller) ||
        !identical(oldWidget.ticket, _ticket)) {
      oldWidget.controller.removeListener(_changed);
      _controller.addListener(_changed);
      _revoke();
    }
  }

  void _revoke() {
    _revoked = true;
    _closeProtectedRoute(context, _confirmation);
    _closeProtectedRoute(context, _route);
  }

  void _changed() {
    if (!mounted) return;
    if (!_current) _revoke();
    setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    for (final field in _fields.values) {
      field.removeListener(_inputChanged);
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _leave() async {
    if (!_current || _busy || _confirmation != null) return;
    if (_ticket.state == ReferenceEditState.uncertain || (!_frozen && _dirty)) {
      final unknown = _ticket.state == ReferenceEditState.uncertain;
      final route = _confirmation = DialogRoute<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AnimatedBuilder(
          animation: _controller,
          builder: (_, _) => !_current
              ? const SizedBox.shrink()
              : AlertDialog(
                  title: Text(
                    unknown
                        ? 'Закрыть неподтверждённый ввод?'
                        : 'Закрыть без сохранения?',
                  ),
                  content: Text(
                    unknown
                        ? 'Результат отправки неизвестен. Ввод останется доступен только в памяти текущей сессии. После закрытия приложения он может быть потерян. Обновление справочника не подтверждает сохранение и не разрешает повторную отправку.'
                        : 'Введённые изменения будут потеряны. Черновик справочника на устройстве не сохраняется.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Остаться'),
                    ),
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () => Navigator.pop(dialogContext, true),
                      child: const Text('Закрыть'),
                    ),
                  ],
                ),
        ),
      );
      final leave = await Navigator.of(context).push<bool>(route);
      _confirmation = null;
      if (!mounted || !_current || _busy || leave != true) return;
    }
    if (!mounted || !_current) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _current) Navigator.of(context).pop();
    });
  }

  Future<void> _save() async {
    if (!_current ||
        _busy ||
        _frozen ||
        _controller.offline ||
        !_form.currentState!.validate()) {
      return;
    }
    final all = _values;
    final values = _ticket.id == null
        ? all
        : referenceChangedValues(_ticket.collection, _initial, all);
    if (values.isEmpty) return;
    setState(() {
      _working = true;
      _error = null;
      _fieldErrors = {};
    });
    try {
      final result = await _ticket.submit(_copy(values));
      if (!mounted || !_current) return;
      if (result.status == ReferenceMutationStatus.scopeChanged) {
        setState(_revoke);
      } else {
        setState(() {
          _fieldErrors = result.error?.fieldErrors ?? {};
          _error =
              result.status == ReferenceMutationStatus.saved ||
                  result.status == ReferenceMutationStatus.uncertain
              ? null
              : result.error?.message ?? 'Не удалось сохранить изменения.';
        });
        if (result.status == ReferenceMutationStatus.saved) {
          // ACK is shown before a separate GET; a failed GET cannot turn this
          // into an editable/retryable create form.
          setState(() => _working = false);
          await _refresh();
        }
      }
    } catch (_) {
      if (mounted && _current) {
        setState(
          () => _error = 'Не удалось подтвердить результат. Проверьте состояние отправки перед дальнейшими действиями.',
        );
      }
    } finally {
      if (mounted && _current) setState(() => _working = false);
    }
  }

  Future<void> _refresh() async {
    if (!_current || _busy) return;
    setState(() {
      _refreshing = true;
      _error = null;
      _refreshFailed = false;
    });
    try {
      final result = await _controller.refreshReferences(_scope);
      if (!mounted || !_current) return;
      if (result.status == ReferenceRefreshStatus.scopeChanged) {
        setState(_revoke);
        return;
      }
      setState(() {
        _refreshFailed = result.status != ReferenceRefreshStatus.refreshed;
        _error = result.status == ReferenceRefreshStatus.refreshed
            ? null
            : result.error?.message ?? 'Не удалось обновить справочники.';
      });
    } catch (_) {
      if (mounted && _current) {
        setState(() {
          _refreshFailed = true;
          _error = 'Не удалось обновить справочники.';
        });
      }
    } finally {
      if (mounted && _current) setState(() => _refreshing = false);
    }
  }

  Widget _field(String key, String label, int limit) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextFormField(
      key: ValueKey('reference-field-$key'),
      controller: _fields[key],
      readOnly: _frozen || _busy,
      maxLength: limit,
      maxLengthEnforcement: MaxLengthEnforcement.none,
      decoration: InputDecoration(
        labelText: label,
        errorText: _fieldErrors[key],
      ),
      validator: (value) {
        if (_ticket.id != null && value == _initial[key]) return null;
        final text = value?.trim() ?? '';
        if (text.isEmpty) return 'Заполните поле';
        if (text.runes.length > limit) return 'Не более $limit символов';
        return null;
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_current) return const SizedBox.shrink();
    final areas = _rows(_controller, 'areas');
    final invalidAreas = _equipment && _invalidSection(_controller, 'areas');
    if (_area != null && !areas.any((area) => area['id'] == _area)) {
      areas.add({'id': _area, 'name': 'Участок #$_area'});
    }
    final saved = _ticket.state == ReferenceEditState.saved;
    final unknown = _ticket.state == ReferenceEditState.uncertain;
    final refreshFailed = _refreshFailed;
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: 'Закрыть редактор',
            onPressed: _busy ? null : _leave,
            icon: const Icon(Icons.arrow_back),
          ),
          title: Text(
            _ticket.id == null
                ? 'Добавить: ${_collectionLabel(_ticket.collection).toLowerCase()}'
                : 'Изменить запись',
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: LinearProgressIndicator(),
                    ),
                  if (saved)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: InfoPanel(
                        refreshFailed
                            ? 'Запись сохранена. Обновить список пока не удалось.'
                            : 'Запись сохранена.',
                        color: const Color(0xff267044),
                        icon: Icons.check_circle_outline,
                        action: refreshFailed
                            ? TextButton(
                                onPressed: _busy ? null : _refresh,
                                child: const Text('Обновить список'),
                              )
                            : null,
                      ),
                    ),
                  if (unknown)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: InfoPanel(
                        'Результат отправки не подтверждён. Ввод сохранён только в памяти этой сессии. Повторная отправка заблокирована. Обновление списка не подтверждает эту запись.',
                        color: const Color(0xff8c5a00),
                        icon: Icons.warning_amber_outlined,
                        action: TextButton(
                          onPressed: _busy ? null : _refresh,
                          child: const Text('Обновить список для просмотра'),
                        ),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: InfoPanel(_error!, color: danger),
                    ),
                  if (invalidAreas)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: InfoPanel(
                        'Не удалось прочитать список участков. Исходный выбранный участок сохранён; обновите справочник перед изменением участка.',
                        color: danger,
                      ),
                    ),
                  if (_controller.offline && !saved && !unknown)
                    const Padding(
                      padding: EdgeInsets.only(bottom: 16),
                      child: InfoPanel(
                        'Нет соединения. Сохранение справочника доступно только онлайн.',
                        icon: Icons.cloud_off_outlined,
                      ),
                    ),
                  _field('name', 'Название', _equipment ? 120 : 180),
                  if (_equipment) ...[
                    _field('inventory_number', 'Инвентарный номер', 80),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: DropdownButtonFormField<int>(
                        key: ValueKey('reference-area-$_area'),
                        initialValue: _area,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Участок'),
                        items: areas
                            .map(
                              (area) => DropdownMenuItem<int>(
                                value: area['id'] as int,
                                child: Text(
                                  '${area['name']}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: _frozen || _busy
                            ? null
                            : (value) => setState(() => _area = value),
                        validator: (value) =>
                            value == null ? 'Выберите участок' : null,
                      ),
                    ),
                    _field('type', 'Тип оборудования', 80),
                    _field('criticality', 'Критичность', 40),
                  ] else
                    _field('unit', 'Единица измерения', 30),
                  if (!_frozen)
                    FilledButton(
                      onPressed:
                          _busy ||
                              _controller.offline ||
                              (_ticket.id != null && !_dirty)
                          ? null
                          : _save,
                      child: const Text('Сохранить'),
                    ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: _busy ? null : _leave,
                    child: Text(saved || unknown ? 'Закрыть' : 'Отмена'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Черновик этой формы не сохраняется на устройстве.',
                    style: TextStyle(color: muted, fontSize: 14),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
