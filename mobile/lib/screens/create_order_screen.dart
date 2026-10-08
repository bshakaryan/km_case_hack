import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as imaging;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/api.dart';
import '../data/app_controller.dart';
import '../data/form_draft.dart';
import '../data/local_store.dart';
import '../data/models.dart';
import '../ui.dart' show plantTime;

/// Resizing is done before upload, outside the UI isolate on native devices.
Uint8List prepareOrderPhoto(Uint8List bytes) {
  imaging.Image? photo;
  try {
    photo = imaging.decodeImage(bytes);
  } catch (_) {
    throw const FormatException('Не удалось прочитать снимок.');
  }
  if (photo == null) {
    throw const FormatException('Не удалось прочитать снимок.');
  }
  photo = imaging.bakeOrientation(photo);
  if (photo.width > 1920 || photo.height > 1920) {
    photo = photo.width >= photo.height
        ? imaging.copyResize(photo, width: 1920)
        : imaging.copyResize(photo, height: 1920);
  }
  return Uint8List.fromList(imaging.encodeJpg(photo, quality: 82));
}

class CreateOrderScreen extends StatefulWidget {
  const CreateOrderScreen({
    super.key,
    required this.controller,
    this.assigneeId,
    this.equipmentId,
    this.imagePicker,
    this.photoPreparer,
  });

  final AppController controller;
  final int? assigneeId;
  final int? equipmentId;
  final ImagePicker? imagePicker;
  final Future<Uint8List> Function(Uint8List)? photoPreparer;

  @override
  State<CreateOrderScreen> createState() => _CreateOrderScreenState();
}

enum _PhotoState { ready, uploading, uploaded, failed, uncertain }

class _DraftPhoto {
  _DraftPhoto(this.bytes, this.filename) : encodedBytes = base64Encode(bytes);
  final Uint8List bytes;
  final String encodedBytes;
  final String filename;
  _PhotoState state = _PhotoState.ready;
  bool queued = false;
  String? error;
}

class _CreateOrderScreenState extends State<CreateOrderScreen>
    with WidgetsBindingObserver {
  final _taskForm = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _comment = TextEditingController();
  late final ImagePicker _picker;
  final List<_DraftPhoto> _photos = [];
  int _step = 0;
  int? _areaId;
  int? _equipmentId;
  int? _assigneeId;
  int? _brigadeId;
  int? _responsibleId;
  bool _byBrigade = false;
  String _workType = 'unplanned';
  String _priority = 'normal';
  DateTime _deadline = DateTime.now().toUtc().add(const Duration(hours: 2));
  bool _busy = false;
  bool _leaving = false;
  bool _picking = false;
  bool _creationUncertain = false;
  String? _error;
  WorkOrder? _created;
  OrderWriteBasis? _photoBasis;
  FormDraftSession? _draftSession;
  late final NaryadApi _draftApi;
  late final int? _draftOwnerId;
  bool _draftLoading = true;
  bool _draftSaving = false;
  bool _draftSaved = false;
  bool _draftClosed = false;
  bool _acknowledgedMutation = false;
  bool _autosaveRunning = false;
  bool _autosaveRequested = false;
  bool _disposing = false;
  bool _draftUncertain = false;
  int _draftRevision = 0;
  String? _draftError;
  String _draftState = FormDraftState.editing;
  String? _operation;

  Json _draftData() => {
    'form_schema': 1,
    'title': _title.text,
    'description': _description.text,
    'comment': _comment.text,
    'step': _step,
    'area_id': _areaId,
    'equipment_id': _equipmentId,
    'assignee_id': _assigneeId,
    'brigade_id': _brigadeId,
    'responsible_id': _responsibleId,
    'by_brigade': _byBrigade,
    'work_type': _workType,
    'priority': _priority,
    'deadline': _deadline.toUtc().toIso8601String(),
    'created': _created?.toJson(),
    'creation_uncertain': _creationUncertain,
    'operation': _operation,
    'error': _error,
    'photos': _photos
        .map(
          (photo) => {
            'bytes': photo.encodedBytes,
            'filename': photo.filename,
            'state': photo.state.name,
            'queued': photo.queued,
            'error': photo.error,
          },
        )
        .toList(),
  };

  void _ensureDraftContext() {
    if (!identical(widget.controller.api, _draftApi) ||
        widget.controller.user?.id != _draftOwnerId) {
      throw const ApiException(
        'Контекст формы изменился. Черновик принадлежит исходному аккаунту и серверу.',
        401,
      );
    }
  }

  List<_DraftPhoto> _parsePhotos(Json data) {
    final requiredKeys = {
      'form_schema',
      'title',
      'description',
      'comment',
      'step',
      'area_id',
      'equipment_id',
      'assignee_id',
      'brigade_id',
      'by_brigade',
      'work_type',
      'priority',
      'deadline',
      'created',
      'creation_uncertain',
      'operation',
      'error',
      'photos',
    };
    if (!data.keys.toSet().containsAll(requiredKeys) ||
        data['form_schema'] != 1 ||
        data['title'] is! String ||
        data['description'] is! String ||
        data['comment'] is! String ||
        !const {0, 1}.contains(data['step']) ||
        data['by_brigade'] is! bool ||
        data['creation_uncertain'] is! bool ||
        !const {'planned', 'unplanned'}.contains(data['work_type']) ||
        !const {
          'normal',
          'high',
          'emergency',
          'planned',
        }.contains(data['priority']) ||
        data['deadline'] is! String ||
        DateTime.tryParse(data['deadline'] as String) == null ||
        !const {null, 'create', 'photo'}.contains(data['operation']) ||
        (data['error'] != null && data['error'] is! String) ||
        data['photos'] is! List ||
        (data['photos'] as List).length > 5) {
      throw const FormatException(
        'Сохранённая форма повреждена. Исходный черновик оставлен без изменений.',
      );
    }
    for (final key in [
      'area_id',
      'equipment_id',
      'assignee_id',
      'brigade_id',
      'responsible_id',
    ]) {
      if (data[key] != null && data[key] is! int) {
        throw const FormatException('Выбор в черновике повреждён.');
      }
    }
    final created = data['created'];
    if (created != null &&
        (created is! Map ||
            created['id'] is! int ||
            created['id'] == 0 ||
            created['status'] is! String)) {
      throw const FormatException(
        'Подтверждение выдачи в черновике повреждено.',
      );
    }
    return (data['photos'] as List).map((row) {
      if (row is! Map ||
          row['bytes'] is! String ||
          row['filename'] is! String ||
          row['queued'] is! bool ||
          !row.containsKey('error') ||
          (row['error'] != null && row['error'] is! String) ||
          !_PhotoState.values.any((value) => value.name == row['state'])) {
        throw const FormatException('Снимок в черновике повреждён.');
      }
      final bytes = base64Decode(row['bytes'] as String);
      if (bytes.length > 10 * 1024 * 1024 ||
          imaging.decodeImage(bytes) == null) {
        throw const FormatException('Снимок в черновике невозможно прочитать.');
      }
      final photo = _DraftPhoto(bytes, row['filename'] as String);
      photo.state = _PhotoState.values.firstWhere(
        (value) => value.name == row['state'],
      );
      if (photo.state == _PhotoState.uploading) {
        photo.state = _PhotoState.uncertain;
      }
      photo.queued = row['queued'] as bool;
      photo.error = row['error'] as String?;
      return photo;
    }).toList();
  }

  Future<void> _restoreDraft() async {
    try {
      final session = await widget.controller.openFormDraft(
        FormDraftKind.create,
      );
      final draft = await session.read();
      _ensureDraftContext();
      if (!mounted) return;
      if (draft != null) {
        final data = draft.data;
        final restoredPhotos = _parsePhotos(data);
        _title.text = data['title'] as String? ?? '';
        _description.text = data['description'] as String? ?? '';
        _comment.text = data['comment'] as String? ?? '';
        _step = data['step'] == 1 ? 1 : 0;
        _areaId = data['area_id'] as int?;
        _equipmentId = data['equipment_id'] as int?;
        _assigneeId = data['assignee_id'] as int?;
        _brigadeId = data['brigade_id'] as int?;
        _responsibleId = data['responsible_id'] as int?;
        _byBrigade = data['by_brigade'] == true;
        _workType = data['work_type'] as String? ?? 'unplanned';
        _priority = data['priority'] as String? ?? 'normal';
        _deadline = DateTime.parse(data['deadline'] as String);
        if (data['created'] is Map) {
          _created = WorkOrder.fromJson(
            Map<String, dynamic>.from(data['created'] as Map),
          );
        }
        _photoBasis = draft.basis;
        _creationUncertain = data['creation_uncertain'] == true;
        _operation = data['operation'] as String?;
        _error = data['error'] as String?;
        _draftState = draft.state;
        _draftUncertain =
            draft.state != FormDraftState.editing ||
            _creationUncertain ||
            restoredPhotos.any((photo) => photo.state == _PhotoState.uncertain);
        if (_draftUncertain) _draftState = FormDraftState.uncertain;
        _photos
          ..clear()
          ..addAll(restoredPhotos);
        if (_draftUncertain) {
          if (_created == null) _creationUncertain = true;
          _error = 'Предыдущая отправка прервалась. Наряд или фото могли попасть на сервер либо в очередь. Проверьте карточку и очередь; новая отправка из черновика заблокирована.';
        }
        _draftSaved = true;
      }
      _draftSession = session;
    } catch (error) {
      if (mounted) _draftError = 'Не удалось открыть черновик: $error';
    } finally {
      if (mounted) setState(() => _draftLoading = false);
    }
  }

  Future<bool> _saveDraft({
    String? state,
    bool acknowledgeSubmission = false,
    bool updateUi = true,
  }) async {
    if (_draftClosed || _draftLoading) return false;
    final session = _draftSession;
    if (session == null) return false;
    if (state != null) _draftState = state;
    final revision = ++_draftRevision;
    if (mounted && updateUi && !_disposing) {
      setState(() {
        _draftSaving = true;
        _draftSaved = false;
      });
    }
    try {
      final draft = FormDraft(
        kind: FormDraftKind.create,
        data: _draftData(),
        basis: _photoBasis,
        state: _draftState,
      );
      if (acknowledgeSubmission) _acknowledgedMutation = true;
      final acknowledged =
          _acknowledgedMutation && _draftState == FormDraftState.editing;
      await session.save(draft, acknowledgeSubmission: acknowledged);
      if (acknowledged) _acknowledgedMutation = false;
      if (mounted && updateUi && !_disposing && revision == _draftRevision) {
        setState(() {
          _draftSaving = false;
          _draftSaved = !_autosaveRequested;
          _draftError = null;
        });
      }
      return true;
    } catch (error) {
      if (mounted && updateUi && !_disposing && revision == _draftRevision) {
        setState(() {
          _draftSaving = false;
          _draftSaved = false;
          _draftError = 'Черновик не сохранён: $error';
        });
      }
      return false;
    }
  }

  void _draftChanged() {
    if (_draftLoading || _draftClosed || _disposing) return;
    _autosaveRequested = true;
    if (!_autosaveRunning) unawaited(_autosave());
  }

  Future<void> _autosave() async {
    _autosaveRunning = true;
    try {
      while (_autosaveRequested && mounted && !_disposing && !_draftClosed) {
        _autosaveRequested = false;
        await _saveDraft();
      }
    } finally {
      _autosaveRunning = false;
    }
  }

  void _edit(VoidCallback change) {
    setState(change);
    _draftChanged();
  }

  Future<void> _closeUnavailable() async {
    final close = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Черновик недоступен'),
        content: const Text(
          'Сохранённый черновик не изменён. Можно закрыть форму и повторить открытие позже.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Остаться'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Закрыть форму'),
          ),
        ],
      ),
    );
    if (close == true && mounted) {
      setState(() => _draftClosed = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _leave({bool delete = false}) async {
    if (_busy || _leaving || _picking || _draftLoading) return;
    if (_draftSession == null) {
      await _closeUnavailable();
      return;
    }
    if (delete) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Удалить черновик?'),
          content: Text(
            _draftUncertain || _creationUncertain || _created != null
                ? 'Сначала проверьте карточку наряда и очередь отправки. Удаление черновика не отменяет уже выданный наряд, загруженные фото или команды в очереди. После удаления форма закроется.'
                : 'Введённые поля и неотправленные снимки будут удалены с устройства.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Отмена'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(
                _draftUncertain || _creationUncertain
                    ? 'Проверил, удалить черновик'
                    : 'Удалить черновик',
              ),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      try {
        await _draftSession!.delete();
        _draftClosed = true;
      } catch (error) {
        if (mounted) {
          setState(() => _draftError = 'Не удалось удалить черновик: $error');
        }
        return;
      }
    } else {
      setState(() => _leaving = true);
      if (!await _saveDraft()) {
        if (mounted) setState(() => _leaving = false);
        return;
      }
    }
    if (!mounted) return;
    setState(() => _draftClosed = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context, _created);
  }

  List<Json> _reference(String key) =>
      (widget.controller.reference[key] as List? ?? [])
          .map((value) => Map<String, dynamic>.from(value as Map))
          .toList();

  Json? _find(List<Json> rows, int? id) {
    for (final row in rows) {
      if (row['id'] == id) return row;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _draftApi = widget.controller.api;
    _draftOwnerId = widget.controller.user?.id;
    _picker = widget.imagePicker ?? ImagePicker();
    _assigneeId = widget.assigneeId;
    _equipmentId = widget.equipmentId;
    final equipment = _find(_reference('equipment'), _equipmentId);
    _areaId = equipment?['area_id'] as int?;
    widget.controller.addListener(_controllerChanged);
    _title.addListener(_draftChanged);
    _description.addListener(_draftChanged);
    _comment.addListener(_draftChanged);
    unawaited(_restoreDraft());
  }

  void _controllerChanged() {
    if (mounted) {
      setState(() {
        if (_areaId == null && _equipmentId != null) {
          _areaId =
              _find(_reference('equipment'), _equipmentId)?['area_id'] as int?;
        }
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (!_draftClosed && !_draftLoading && _draftSession != null) {
        unawaited(_saveDraft());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposing = true;
    _autosaveRequested = false;
    // Capture the latest edit while text controllers still exist. The frozen
    // session prevents a late write from moving to another account or reviving
    // a deleted draft. Navigation itself already awaits its final write.
    if (!_draftClosed && !_draftLoading && _draftSession != null) {
      unawaited(_saveDraft(updateUi: false));
    }
    widget.controller.removeListener(_controllerChanged);
    _title.dispose();
    _description.dispose();
    _comment.dispose();
    super.dispose();
  }

  String _deadlineLabel() =>
      '${DateFormat('dd.MM, HH:mm').format(plantTime(_deadline))} · время предприятия';

  String _employeeDetail(Json employee) {
    final off =
        employee['on_shift'] == false || employee['status'] == 'off_shift';
    final current = employee['current_order'];
    final count = employee['queue_count'] ?? 0;
    final status = off
        ? 'Не на смене'
        : current != null
        ? 'В работе: $current'
        : employee['status'] == 'busy'
        ? 'В работе'
        : employee['status'] == 'queued'
        ? 'Есть задания'
        : 'Свободен';
    return '${employee['specialty'] ?? 'Специальность не указана'}\n$status · ожидают начала: $count';
  }

  Color _employeeColor(Json employee) {
    if (employee['on_shift'] == false || employee['status'] == 'off_shift') {
      return const Color(0xFF677484);
    }
    if (employee['current_order'] != null || employee['status'] == 'busy') {
      return const Color(0xFF9B6900);
    }
    if (employee['status'] == 'queued') return const Color(0xFF155DB0);
    return const Color(0xFF217346);
  }

  Future<Json?> _choose({
    required String title,
    required List<Json> rows,
    String Function(Json)? subtitle,
    bool employees = false,
  }) async {
    var query = '';
    return showModalBottomSheet<Json>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, update) {
          final filtered = rows.where((row) {
            final text =
                '${row['name']} ${row['inventory_number'] ?? ''} ${row['specialty'] ?? ''}';
            return text.toLowerCase().contains(query.toLowerCase());
          }).toList();
          return Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
            ),
            child: SizedBox(
              height: MediaQuery.sizeOf(sheetContext).height * .76,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 8, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Закрыть выбор',
                          onPressed: () => Navigator.pop(sheetContext),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                    child: TextField(
                      decoration: const InputDecoration(
                        labelText: 'Поиск',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (value) => update(() => query = value),
                    ),
                  ),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(24),
                              child: Text(
                                'Ничего не найдено. Измените запрос.',
                              ),
                            ),
                          )
                        : ListView.separated(
                            itemCount: filtered.length,
                            separatorBuilder: (_, index) =>
                                const Divider(height: 1),
                            itemBuilder: (_, index) {
                              final row = filtered[index];
                              final enabled =
                                  !employees ||
                                  (row['on_shift'] != false &&
                                      row['status'] != 'off_shift');
                              return ListTile(
                                minVerticalPadding: 14,
                                enabled: enabled,
                                leading: employees
                                    ? Icon(
                                        Icons.person_outline,
                                        color: _employeeColor(row),
                                      )
                                    : null,
                                title: Text(
                                  '${row['name']}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                subtitle: subtitle == null
                                    ? null
                                    : Text(
                                        subtitle(row),
                                        style: const TextStyle(
                                          fontSize: 15,
                                          height: 1.45,
                                        ),
                                      ),
                                onTap: enabled
                                    ? () => Navigator.pop(sheetContext, row)
                                    : null,
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _chooseArea() async {
    final row = await _choose(title: 'Участок', rows: _reference('areas'));
    if (!mounted || row == null) return;
    _edit(() {
      if (_areaId != row['id']) _equipmentId = null;
      _areaId = row['id'] as int;
      _error = null;
    });
  }

  Future<void> _chooseEquipment() async {
    final row = await _choose(
      title: 'Оборудование участка',
      rows: _reference('equipment')
          .where((row) => row['area_id'] == _areaId)
          .toList(),
      subtitle: (row) => 'Инв. № ${row['inventory_number'] ?? '—'}',
    );
    if (mounted && row != null) _edit(() => _equipmentId = row['id'] as int);
  }

  Future<void> _chooseAssignee() async {
    final row = await _choose(
      title: _byBrigade ? 'Бригада' : 'Исполнитель',
      rows: _byBrigade ? _reference('brigades') : widget.controller.employees,
      employees: !_byBrigade,
      subtitle: _byBrigade ? null : _employeeDetail,
    );
    if (!mounted || row == null) return;
    _edit(() {
      if (_byBrigade) {
        _brigadeId = row['id'] as int;
        _assigneeId = null;
        _responsibleId = null;
      } else {
        _assigneeId = row['id'] as int;
        _brigadeId = null;
        _responsibleId = null;
      }
      _error = null;
    });
  }

  List<Json> get _eligibleParticipants => widget.controller.employees
      .where(
        (row) =>
            row['brigade_id'] == _brigadeId &&
            row['role'] == 'worker' &&
            row['on_shift'] == true,
      )
      .toList();

  Future<void> _chooseResponsible() async {
    final row = await _choose(
      title: 'Ответственный за общий результат',
      rows: _eligibleParticipants,
      employees: true,
      subtitle: _employeeDetail,
    );
    if (mounted && row != null) {
      _edit(() {
        _responsibleId = row['id'] as int;
        _error = null;
      });
    }
  }

  Future<void> _chooseDeadline() async {
    final now = plantTime(DateTime.now());
    final current = plantTime(_deadline);
    final date = await showDatePicker(
      context: context,
      initialDate: current.isBefore(now) ? now : current,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: now.add(const Duration(days: 365)),
      helpText: 'Срок · время предприятия',
    );
    if (!mounted || date == null) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: current.hour, minute: current.minute),
      helpText: 'Время предприятия · Asia/Almaty',
    );
    if (!mounted || time == null) return;
    final deadline = tz.TZDateTime(
      tz.getLocation('Asia/Almaty'),
      date.year,
      date.month,
      date.day,
      time.hour,
      time.minute,
    ).toUtc();
    _edit(() {
      _deadline = deadline;
      _error = deadline.isAfter(DateTime.now().toUtc())
          ? null
          : 'Срок должен быть в будущем.';
    });
  }

  Future<void> _addPhoto(ImageSource source) async {
    if (_photos.length >= 5 || _busy || _picking) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final picked = await _picker.pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 90,
      );
      if (picked == null) return;
      final original = await picked.readAsBytes();
      final bytes =
          await (widget.photoPreparer?.call(original) ??
              compute(prepareOrderPhoto, original));
      if (bytes.length > 10 * 1024 * 1024) {
        throw const FormatException(
          'Фото слишком большое. Выберите другой снимок.',
        );
      }
      if (mounted) {
        _edit(
          () => _photos.add(
            _DraftPhoto(
              bytes,
              'before-${DateTime.now().microsecondsSinceEpoch}.jpg',
            ),
          ),
        );
        await _saveDraft();
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Не удалось добавить фото. Проверьте разрешение камеры или выберите другой снимок из галереи.',
        );
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  bool _validateAssignment() {
    if ((_byBrigade && _brigadeId == null) ||
        (!_byBrigade && _assigneeId == null)) {
      setState(() => _error = 'Выберите исполнителя или бригаду.');
      return false;
    }
    final employee = _find(widget.controller.employees, _assigneeId);
    if (_byBrigade &&
        (_eligibleParticipants.isEmpty ||
            (_responsibleId != null &&
                !_eligibleParticipants.any(
                  (row) => row['id'] == _responsibleId,
                )))) {
      setState(
        () => _error = 'В бригаде нет работников на смене либо выбранный ответственный недоступен. Проверьте назначение.',
      );
      return false;
    }
    if (!_byBrigade &&
        (employee == null ||
            employee['on_shift'] == false ||
            employee['status'] == 'off_shift')) {
      setState(
        () => _error =
            'Выбранный исполнитель не на смене. Выберите другого работника.',
      );
      return false;
    }
    if (!_deadline.isAfter(DateTime.now().toUtc())) {
      setState(() => _error = 'Срок должен быть в будущем.');
      return false;
    }
    return true;
  }

  void _next() {
    final valid = _taskForm.currentState?.validate() ?? false;
    if (_areaId == null || _equipmentId == null) {
      setState(() => _error = 'Выберите участок и оборудование.');
      return;
    }
    if (valid) {
      FocusScope.of(context).unfocus();
      _edit(() {
        _step = 1;
        _error = null;
      });
    }
  }

  Future<void> _submit() async {
    if (_busy ||
        _picking ||
        _creationUncertain ||
        _draftUncertain ||
        _draftLoading ||
        _draftSession == null) {
      return;
    }
    if (_created == null && !_validateAssignment()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_created == null) {
        final payload = <String, dynamic>{
          'title': _title.text.trim(),
          'description': _description.text.trim(),
          'work_type': _workType,
          'area_id': _areaId,
          'equipment_id': _equipmentId,
          if (_byBrigade)
            'brigade_id': _brigadeId
          else
            'assignee_id': _assigneeId,
          if (_byBrigade && _responsibleId != null)
            'responsible_id': _responsibleId,
          'priority': _priority,
          'deadline': _deadline.toUtc().toIso8601String(),
          'comment': _comment.text.trim(),
        };
        try {
          _operation = 'create';
          if (!await _saveDraft(state: FormDraftState.submitting)) return;
          _ensureDraftContext();
          final created = await widget.controller.createOrder(payload);
          if (!mounted) return;
          setState(() => _created = created);
          _photoBasis = widget.controller.captureOrderBasis(created);
          _operation = null;
          if (!await _saveDraft(
            state: FormDraftState.editing,
            acknowledgeSubmission: true,
          )) {
            return;
          }
        } on ApiException catch (error) {
          if (!mounted) return;
          setState(() {
            _creationUncertain = error.requestMayHaveSucceeded;
            _error = _creationUncertain
                ? 'Ответ о выдаче не получен. Наряд мог сохраниться. Вернитесь к списку и проверьте его перед новой выдачей.'
                : error.message;
          });
          _draftUncertain = _creationUncertain;
          _operation = _creationUncertain ? 'create' : null;
          await _saveDraft(
            state: _creationUncertain
                ? FormDraftState.uncertain
                : FormDraftState.editing,
            acknowledgeSubmission: !_creationUncertain,
          );
          return;
        } catch (_) {
          if (mounted) {
            setState(() {
              _creationUncertain = true;
              _error = 'Не удалось подтвердить выдачу. Проверьте список нарядов перед новой попыткой.';
            });
          }
          _draftUncertain = true;
          await _saveDraft(state: FormDraftState.uncertain);
          return;
        }
      }
      for (final photo in _photos) {
        if (photo.state == _PhotoState.uploaded ||
            photo.state == _PhotoState.uncertain) {
          continue;
        }
        if (!mounted) return;
        setState(() {
          photo.state = _PhotoState.uploading;
          photo.error = null;
        });
        try {
          _operation = 'photo';
          if (!await _saveDraft(state: FormDraftState.submitting)) {
            if (mounted) setState(() => photo.state = _PhotoState.failed);
            return;
          }
          _ensureDraftContext();
          final commandId = await widget.controller.uploadPhoto(
            _created!.id,
            photo.bytes,
            photo.filename,
            'before',
            basis: _photoBasis,
          );
          _photoBasis = OrderWriteBasis(previousCommandId: commandId);
          if (!mounted) return;
          setState(() {
            photo.state = _PhotoState.uploaded;
            photo.queued = widget.controller.isOrderPending(_created!.id);
          });
          _operation = null;
          if (!await _saveDraft(
            state: FormDraftState.editing,
            acknowledgeSubmission: true,
          )) {
            return;
          }
        } on ApiException catch (error) {
          if (!mounted) return;
          setState(() {
            photo.state = error.requestMayHaveSucceeded
                ? _PhotoState.uncertain
                : _PhotoState.failed;
            photo.error = error.requestMayHaveSucceeded
                ? 'Нет подтверждения. Проверьте фото в наряде.'
                : error.message;
          });
          _draftUncertain = error.requestMayHaveSucceeded;
          _operation = _draftUncertain ? 'photo' : null;
          await _saveDraft(
            state: _draftUncertain
                ? FormDraftState.uncertain
                : FormDraftState.editing,
            acknowledgeSubmission: !_draftUncertain,
          );
          // An uncertain upload must never be replayed without server deduplication.
          if (error.requestMayHaveSucceeded) break;
        } catch (_) {
          if (!mounted) return;
          setState(() {
            photo.state = _PhotoState.uncertain;
            photo.error = 'Нет подтверждения. Проверьте фото в наряде.';
          });
          _draftUncertain = true;
          await _saveDraft(state: FormDraftState.uncertain);
          break;
        }
      }
      if (!mounted) return;
      if (_photos.every((photo) => photo.state == _PhotoState.uploaded)) {
        try {
          await _draftSession!.delete();
          if (!mounted) return;
          setState(() => _draftClosed = true);
          await WidgetsBinding.instance.endOfFrame;
          if (mounted) Navigator.pop(context, _created);
        } catch (error) {
          if (mounted) {
            setState(
              () => _draftError =
                  'Наряд обработан, но не удалось удалить черновик: $error',
            );
          }
        }
      } else {
        setState(
          () => _error = _created!.pendingSync
              ? 'Наряд сохранён на устройстве. Не все фотографии сохранены для отправки. Повторная выдача не требуется.'
              : 'Наряд уже выдан. Не все фото подтверждены сервером. Повторная выдача не требуется.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _choice(
    String label,
    String value,
    VoidCallback? onTap, {
    String? detail,
    IconData icon = Icons.chevron_right,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFFCAD2DD)),
      ),
      child: ListTile(
        minVerticalPadding: 10,
        title: Text(
          label,
          style: const TextStyle(fontSize: 13, color: Color(0xFF536275)),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Color(0xFF192C43),
              ),
            ),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  detail,
                  style: const TextStyle(fontSize: 14, height: 1.4),
                ),
              ),
          ],
        ),
        trailing: Icon(icon),
        onTap: onTap,
      ),
    ),
  );

  Widget _photoList() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Фото неисправности · ${_photos.length}/5',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      const SizedBox(height: 4),
      const Text(
        'Необязательно. Снимки отправятся после выдачи наряда.',
        style: TextStyle(fontSize: 14, color: Color(0xFF536275)),
      ),
      const SizedBox(height: 10),
      for (final photo in _photos)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  photo.bytes,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Снимок ${_photos.indexOf(photo) + 1}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      switch (photo.state) {
                        _PhotoState.ready =>
                          '${(photo.bytes.length / 1024).round()} КБ · не отправлен',
                        _PhotoState.uploading => 'Отправка…',
                        _PhotoState.uploaded =>
                          photo.queued
                              ? 'Фото сохранено на устройстве. Ожидает отправки.'
                              : 'Фото подтверждено сервером',
                        _PhotoState.failed => photo.error ?? 'Ошибка отправки',
                        _PhotoState.uncertain =>
                          photo.error ?? 'Результат неизвестен',
                      },
                      style: TextStyle(
                        fontSize: 13,
                        color:
                            photo.state == _PhotoState.failed ||
                                photo.state == _PhotoState.uncertain
                            ? const Color(0xFFB3261E)
                            : const Color(0xFF536275),
                      ),
                    ),
                  ],
                ),
              ),
              if (photo.state == _PhotoState.uploading)
                const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (_created == null && !_busy && !_creationUncertain)
                IconButton(
                  tooltip: 'Убрать снимок ${_photos.indexOf(photo) + 1}',
                  onPressed: () => _edit(() => _photos.remove(photo)),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
      if (_created == null && !_creationUncertain)
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _photos.length < 5 && !_busy && !_picking
                  ? () => _addPhoto(ImageSource.camera)
                  : null,
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Камера'),
            ),
            OutlinedButton.icon(
              onPressed: _photos.length < 5 && !_busy && !_picking
                  ? () => _addPhoto(ImageSource.gallery)
                  : null,
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Галерея'),
            ),
          ],
        ),
      if (_picking)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: LinearProgressIndicator(),
        ),
    ],
  );

  Widget _task() {
    if (_reference('areas').isEmpty || _reference('equipment').isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Справочники недоступны',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'Для выдачи нужны участки и оборудование. Обновите данные или попросите администратора заполнить справочники.',
          ),
          const SizedBox(height: 16),
          if (widget.controller.loading)
            const LinearProgressIndicator()
          else
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  await widget.controller.refresh();
                } catch (_) {
                  if (mounted) {
                    setState(
                      () => _error = 'Не удалось загрузить справочники. Проверьте связь и повторите.',
                    );
                  }
                }
              },
              icon: const Icon(Icons.refresh),
              label: const Text('Обновить справочники'),
            ),
        ],
      );
    }
    final area = _find(_reference('areas'), _areaId);
    final equipment = _find(_reference('equipment'), _equipmentId);
    return Form(
      key: _taskForm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Что нужно сделать',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Обязательные поля отмечены *. Номер и время выдачи появятся автоматически.',
            style: TextStyle(fontSize: 14, color: Color(0xFF536275)),
          ),
          const SizedBox(height: 20),
          _choice(
            'Участок *',
            '${area?['name'] ?? 'Выберите участок'}',
            _chooseArea,
          ),
          _choice(
            'Оборудование *',
            '${equipment?['name'] ?? 'Выберите оборудование'}',
            _areaId == null ? null : _chooseEquipment,
            detail: equipment == null
                ? (_areaId == null ? 'Сначала выберите участок' : null)
                : 'Инв. № ${equipment['inventory_number']}',
          ),
          const Text(
            'Тип работ *',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'unplanned', label: Text('Внеплановый')),
              ButtonSegment(value: 'planned', label: Text('Плановый')),
            ],
            selected: {_workType},
            onSelectionChanged: (selected) =>
                _edit(() => _workType = selected.first),
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _title,
            maxLength: 200,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Кратко о задаче *',
              hintText: 'Течь масла на насосе',
              counterText: '',
            ),
            validator: (value) => (value?.trim().length ?? 0) < 3
                ? 'Опишите задачу — минимум 3 символа.'
                : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _description,
            minLines: 3,
            maxLines: 5,
            maxLength: 5000,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Проблема и необходимые работы *',
              hintText:
                  'Где обнаружена проблема и что нужно проверить или устранить',
              counterText: '',
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'Заполните описание проблемы и работ.'
                : null,
          ),
          const SizedBox(height: 24),
          _photoList(),
        ],
      ),
    );
  }

  Widget _assignment() {
    final employee = _find(widget.controller.employees, _assigneeId);
    final brigade = _find(_reference('brigades'), _brigadeId);
    final responsible = _find(widget.controller.employees, _responsibleId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Кому и к какому сроку',
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 16),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Исполнитель')),
            ButtonSegment(value: true, label: Text('Бригада')),
          ],
          selected: {_byBrigade},
          onSelectionChanged: (selected) => _edit(() {
            _byBrigade = selected.first;
            _assigneeId = null;
            _brigadeId = null;
            _responsibleId = null;
          }),
        ),
        const SizedBox(height: 16),
        _choice(
          _byBrigade ? 'Бригада *' : 'Исполнитель *',
          _byBrigade
              ? '${brigade?['name'] ?? 'Выберите бригаду'}'
              : '${employee?['name'] ?? 'Выберите исполнителя'}',
          _chooseAssignee,
          detail: employee == null || _byBrigade
              ? null
              : _employeeDetail(employee),
        ),
        if (_byBrigade) ...[
          _choice(
            'Ответственный за сдачу',
            _responsibleId == null
                ? 'Автоматический выбор сервера'
                : '${responsible?['name'] ?? 'Выбранный работник недоступен'}',
            _brigadeId == null ? null : _chooseResponsible,
            detail: 'Общий наряд читают все назначенные участники; принимает и сдаёт один ответственный.',
          ),
          if (_responsibleId != null)
            TextButton(
              onPressed: () => _edit(() => _responsibleId = null),
              child: const Text('Выбрать ответственного автоматически'),
            ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              'Сервер зафиксирует состав работников на смене при назначении. Без выбора ответственного назначит наименее загруженного. Состав и ответственный подтверждаются после отправки.',
              style: const TextStyle(fontSize: 14, color: Color(0xFF536275)),
            ),
          ),
        ],
        _choice(
          'Срок исполнения *',
          _deadlineLabel(),
          _chooseDeadline,
          icon: Icons.calendar_month_outlined,
        ),
        Wrap(
          spacing: 8,
          children: [
            for (final hours in [1, 2, 4])
              ActionChip(
                label: Text('Через $hours ч'),
                onPressed: () => _edit(() {
                  _deadline = DateTime.now().toUtc().add(
                    Duration(hours: hours),
                  );
                  _error = null;
                }),
              ),
          ],
        ),
        const SizedBox(height: 20),
        const Text(
          'Приоритет *',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final item in const {
              'normal': 'Обычный',
              'high': 'Высокий',
              'emergency': 'Аварийный',
              'planned': 'Плановый',
            }.entries)
              ChoiceChip(
                label: Text(item.value),
                selected: _priority == item.key,
                selectedColor: item.key == 'emergency'
                    ? const Color(0xFFFCE8E6)
                    : null,
                onSelected: (_) => _edit(() => _priority = item.key),
              ),
          ],
        ),
        if (_priority == 'emergency')
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Срочно в работу. Ожидаем принятия в течение 3 минут.',
              style: TextStyle(
                color: Color(0xFFB3261E),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        const SizedBox(height: 16),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text(
            'Комментарий мастера',
            style: TextStyle(fontSize: 16),
          ),
          children: [
            TextField(
              controller: _comment,
              minLines: 2,
              maxLines: 4,
              maxLength: 3000,
              decoration: const InputDecoration(
                labelText: 'Дополнительные условия',
                counterText: '',
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          'Будет выдано: ${_title.text.trim()}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (_photos.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Фото перед отправкой: ${_photos.length}',
              style: const TextStyle(fontSize: 14),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final partial = _created != null;
    final hasRetryablePhotos = _photos.any(
      (photo) =>
          photo.state == _PhotoState.ready || photo.state == _PhotoState.failed,
    );
    return PopScope(
      canPop: _draftClosed,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) unawaited(_leave());
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            partial
                ? (_created!.pendingSync
                      ? 'Наряд ожидает отправки'
                      : 'Наряд выдан')
                : 'Выдать наряд',
          ),
          leading: IconButton(
            tooltip: 'Назад',
            icon: const Icon(Icons.arrow_back),
            onPressed: _busy || _leaving || _picking || _draftLoading
                ? null
                : () {
                    if (_draftSession == null) {
                      unawaited(_closeUnavailable());
                      return;
                    }
                    if (_step == 1 &&
                        !partial &&
                        !_creationUncertain &&
                        !_draftLoading) {
                      _edit(() {
                        _step = 0;
                        _error = null;
                      });
                    } else {
                      unawaited(_leave());
                    }
                  },
          ),
        ),
        body: _draftLoading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: Column(
                  children: [
                    if (!partial && !_creationUncertain)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                        child: Row(
                          children: [
                            Text(
                              'Шаг ${_step + 1} из 2',
                              style: const TextStyle(
                                fontSize: 14,
                                color: Color(0xFF536275),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: LinearProgressIndicator(
                                value: (_step + 1) / 2,
                                minHeight: 3,
                              ),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        key: ValueKey((
                          _step,
                          _created?.id,
                          _creationUncertain,
                          _error,
                        )),
                        primary: false,
                        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              _draftSaving
                                  ? 'Сохранение черновика…'
                                  : _draftSaved
                                  ? 'Черновик сохранён на устройстве'
                                  : 'Черновик ещё не сохранён',
                              style: const TextStyle(
                                fontSize: 13,
                                color: Color(0xFF536275),
                              ),
                            ),
                            if (_draftError != null)
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 12,
                                ),
                                child: Text(
                                  _draftError!,
                                  style: const TextStyle(
                                    color: Color(0xFFB3261E),
                                  ),
                                ),
                              ),
                            if (_draftError != null)
                              TextButton(
                                onPressed: () => _draftSession == null
                                    ? _restoreDraft()
                                    : _saveDraft(),
                                child: const Text(
                                  'Повторить сохранение черновика',
                                ),
                              ),
                            if (!partial &&
                                !_creationUncertain &&
                                widget.controller.error != null)
                              const Padding(
                                padding: EdgeInsets.only(bottom: 12),
                                child: Text(
                                  'Не удалось обновить данные. Занятость исполнителей может измениться; сервер проверит назначение при выдаче.',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: Color(0xFF8E211B),
                                  ),
                                ),
                              ),
                            if (_error != null)
                              Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.all(14),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFFFF0EF),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: const Color(0xFFE8BCB8),
                                  ),
                                ),
                                child: Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    _error!,
                                    style: const TextStyle(
                                      color: Color(0xFF8E211B),
                                      height: 1.4,
                                    ),
                                  ),
                                ),
                              ),
                            if (partial) ...[
                              Text(
                                '№ ${_created!.data['number']}',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                              const SizedBox(height: 8),
                              Text(
                                _created!.pendingSync
                                    ? 'Наряд сохранён на устройстве и ожидает отправки. Ниже — состояние каждого снимка.'
                                    : 'Наряд сохранён на сервере. Ниже — состояние каждого снимка.',
                              ),
                              const SizedBox(height: 20),
                              _photoList(),
                            ] else if (_creationUncertain) ...[
                              Text(
                                _title.text,
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Повторная отправка заблокирована, чтобы не создать второй наряд. Черновик сохраняется на устройстве; проверьте список и очередь отправки.',
                              ),
                            ] else
                              AbsorbPointer(
                                absorbing:
                                    _busy || _leaving || _draftSession == null,
                                child: _step == 0 ? _task() : _assignment(),
                              ),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 20, 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (partial && !_busy) ...[
                            if (hasRetryablePhotos && !_draftUncertain)
                              OutlinedButton.icon(
                                onPressed: _submit,
                                icon: const Icon(Icons.refresh),
                                label: const Text(
                                  'Повторить неотправленные фото',
                                ),
                              ),
                            const SizedBox(height: 8),
                            FilledButton(
                              onPressed: _leave,
                              child: const Text('Открыть выданный наряд'),
                            ),
                          ] else
                            FilledButton(
                              style: FilledButton.styleFrom(
                                minimumSize: const Size.fromHeight(54),
                              ),
                              onPressed:
                                  _busy ||
                                      _picking ||
                                      _draftLoading ||
                                      _draftSession == null
                                  ? null
                                  : _creationUncertain
                                  ? _leave
                                  : _step == 0
                                  ? _next
                                  : _submit,
                              child: _busy
                                  ? const Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                        SizedBox(width: 12),
                                        Text('Отправка…'),
                                      ],
                                    )
                                  : Text(
                                      _creationUncertain
                                          ? 'Проверить список нарядов'
                                          : _step == 0
                                          ? 'Далее · назначение'
                                          : 'Выдать наряд',
                                    ),
                            ),
                          if (!_busy &&
                              !_picking &&
                              !_draftLoading &&
                              _draftSession != null)
                            TextButton(
                              onPressed: () => _leave(delete: true),
                              child: const Text('Удалить черновик'),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
