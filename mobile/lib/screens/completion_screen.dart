import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as imaging;
import 'package:image_picker/image_picker.dart';

import '../data/api.dart';
import '../data/app_controller.dart';
import '../data/form_draft.dart';
import '../data/local_store.dart';
import '../data/models.dart';
import '../widgets/order_photo.dart';

class CompletionScreen extends StatefulWidget {
  const CompletionScreen({
    super.key,
    required this.controller,
    required this.order,
  });
  final AppController controller;
  final WorkOrder order;

  @override
  State<CompletionScreen> createState() => _CompletionScreenState();
}

class _CompletionScreenState extends State<CompletionScreen>
    with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  final _work = TextEditingController();
  final _comment = TextEditingController();
  final _materials = <_MaterialLine>[];
  final _photos = <_PendingPhoto>[];
  List<Json> _serverPhotos = [];
  int? _faultId;
  bool _sending = false;
  bool _leaving = false;
  bool _picking = false;
  bool _checking = false;
  bool _dirty = false;
  bool _uncertain = false;
  bool _stale = false;
  bool _done = false;
  String? _error;
  late OrderWriteBasis _basis;
  FormDraftSession? _draftSession;
  late final NaryadApi _draftApi;
  late final int? _draftOwnerId;
  late final String? _draftToken;
  bool _openedAsResponsible = false;
  bool _draftLoading = true;
  bool _draftSaving = false;
  bool _draftSaved = false;
  bool _draftClosed = false;
  bool _acknowledgedMutation = false;
  bool _autosaveRunning = false;
  bool _autosaveRequested = false;
  bool _disposing = false;
  int _draftRevision = 0;
  String? _draftError;
  String _draftState = FormDraftState.editing;
  String? _operation;
  Json? _assignmentSnapshot;

  bool get _draftContextCurrent =>
      identical(widget.controller.api, _draftApi) &&
      widget.controller.api.token == _draftToken &&
      widget.controller.user?.id == _draftOwnerId &&
      widget.controller.user?.isWorker == true;

  bool get _canComplete {
    final user = widget.controller.user;
    if (!_draftContextCurrent || !widget.order.isResponsible(user?.id)) {
      return false;
    }
    final current = widget.controller.orders
        .where((order) => order.id == widget.order.id)
        .firstOrNull;
    return current == null || current.isResponsible(user?.id);
  }

  void _ensureResponsible() {
    if (!_canComplete) {
      throw const ApiException(
        'Общий результат сдаёт только ответственный. Черновик сохранён.',
        403,
      );
    }
  }

  void _controllerChanged() {
    if (mounted) setState(() {});
  }

  Json _draftData() => {
    'form_schema': 1,
    'work': _work.text,
    'comment': _comment.text,
    'fault_id': _faultId,
    'dirty': _dirty,
    'uncertain': _uncertain,
    'stale': _stale,
    'done': _done,
    'error': _error,
    'operation': _operation,
    'assignment_snapshot': _assignmentSnapshot,
    'materials': _materials
        .map(
          (line) => {'material': line.material, 'quantity': line.quantity.text},
        )
        .toList(),
    'photos': _photos
        .map(
          (photo) => {
            'bytes': photo.encodedBytes,
            'filename': photo.filename,
            'uploading': photo.uploading,
            'uploaded': photo.uploaded,
            'queued': photo.queued,
            'uncertain': photo.uncertain,
            'error': photo.error,
          },
        )
        .toList(),
  };

  void _ensureDraftContext() {
    if (!_draftContextCurrent) {
      throw const ApiException(
        'Контекст формы изменился. Черновик принадлежит исходному аккаунту и серверу.',
        401,
      );
    }
  }

  void _validateDraftData(Json data) {
    final requiredKeys = {
      'form_schema',
      'work',
      'comment',
      'fault_id',
      'dirty',
      'uncertain',
      'stale',
      'done',
      'error',
      'operation',
      'materials',
      'photos',
    };
    if (!data.keys.toSet().containsAll(requiredKeys) ||
        data['form_schema'] != 1 ||
        data['work'] is! String ||
        data['comment'] is! String ||
        (data['fault_id'] != null && data['fault_id'] is! int) ||
        [
          'dirty',
          'uncertain',
          'stale',
          'done',
        ].any((key) => data[key] is! bool) ||
        (data['error'] != null && data['error'] is! String) ||
        (data['assignment_snapshot'] != null &&
            data['assignment_snapshot'] is! Map) ||
        !const {null, 'photo', 'complete'}.contains(data['operation']) ||
        data['materials'] is! List ||
        data['photos'] is! List ||
        (data['photos'] as List).length > 5) {
      throw const FormatException(
        'Сохранённая форма повреждена. Исходный черновик оставлен без изменений.',
      );
    }
    final snapshot = data['assignment_snapshot'];
    if (snapshot is Map) {
      final participants = snapshot['participants'];
      if (snapshot['id'] is! int ||
          (snapshot['id'] as int) < 1 ||
          snapshot['assignee_id'] is! int ||
          snapshot['assignee_name'] is! String ||
          (snapshot['brigade_id'] != null && snapshot['brigade_id'] is! int) ||
          (participants != null && participants is! List) ||
          !const {
            'live',
            'legacy_snapshot',
          }.contains(snapshot['participants_source'])) {
        throw const FormatException('Состав назначения в черновике повреждён.');
      }
      if (participants is List &&
          participants.any(
            (row) =>
                row is! Map ||
                row['employee_id'] is! int ||
                row['name'] is! String ||
                row['is_responsible'] is! bool ||
                !const {'live', 'legacy_snapshot'}.contains(row['source']),
          )) {
        throw const FormatException(
          'Участник назначения в черновике повреждён.',
        );
      }
    }
    for (final row in data['materials'] as List) {
      if (row is! Map ||
          row['quantity'] is! String ||
          row['material'] is! Map ||
          row['material']['id'] is! int ||
          row['material']['name'] is! String ||
          row['material']['unit'] is! String) {
        throw const FormatException('Строка материала в черновике повреждена.');
      }
    }
    for (final row in data['photos'] as List) {
      if (row is! Map ||
          row['bytes'] is! String ||
          row['filename'] is! String ||
          [
            'uploading',
            'uploaded',
            'queued',
            'uncertain',
          ].any((key) => row[key] is! bool) ||
          !row.containsKey('error') ||
          (row['error'] != null && row['error'] is! String)) {
        throw const FormatException('Снимок в черновике повреждён.');
      }
    }
  }

  Future<void> _restoreDraft() async {
    try {
      final session = await widget.controller.openFormDraft(
        FormDraftKind.completion,
        orderId: widget.order.id,
      );
      final draft = await session.read();
      _ensureDraftContext();
      if (!mounted) return;
      if (draft != null) {
        final data = draft.data;
        _validateDraftData(data);
        final restoredPhotos = (data['photos'] as List).map((row) {
          final bytes = base64Decode(row['bytes'] as String);
          if (bytes.length > 10 * 1024 * 1024 ||
              imaging.decodeImage(bytes) == null) {
            throw const FormatException(
              'Снимок в черновике невозможно прочитать.',
            );
          }
          final photo = _PendingPhoto(bytes, row['filename'] as String);
          photo.uploaded = row['uploaded'] as bool;
          photo.queued = row['queued'] as bool;
          photo.uncertain =
              row['uncertain'] == true || row['uploading'] == true;
          photo.error = row['error'] as String?;
          return photo;
        }).toList();
        final restoredMaterials = (data['materials'] as List).map((row) {
          final line = _MaterialLine(
            Map<String, dynamic>.from(row['material'] as Map),
          );
          line.quantity.text = row['quantity'] as String;
          return line;
        }).toList();
        _work.text = data['work'] as String? ?? '';
        _comment.text = data['comment'] as String? ?? '';
        _faultId = data['fault_id'] as int?;
        _dirty = data['dirty'] == true;
        _uncertain =
            data['uncertain'] == true ||
            draft.state != FormDraftState.editing ||
            restoredPhotos.any((photo) => photo.uncertain);
        _stale = data['stale'] == true;
        _done = data['done'] == true;
        _operation = data['operation'] as String?;
        _error = data['error'] as String?;
        _assignmentSnapshot = data['assignment_snapshot'] is Map
            ? Map<String, dynamic>.from(data['assignment_snapshot'] as Map)
            : null;
        _draftState = _uncertain ? FormDraftState.uncertain : draft.state;
        // A restored draft never takes the newer order's basis.
        _basis = draft.basis ?? const OrderWriteBasis();
        if (_basis.previousCommandId == null &&
            _basis.expectedVersion != widget.order.version) {
          _stale = true;
          _error = 'Наряд изменился после начала черновика. Ввод сохранён, но отправка заблокирована. Проверьте карточку и создайте новый отчёт после явного удаления старого черновика.';
        }
        for (final line in _materials) {
          line.quantity.dispose();
        }
        _materials
          ..clear()
          ..addAll(restoredMaterials);
        for (final line in _materials) {
          line.quantity.addListener(_changed);
        }
        _photos
          ..clear()
          ..addAll(restoredPhotos);
        if (_uncertain) _error = 'Предыдущая отправка прервалась. Отчёт или фото могли попасть на сервер либо в очередь. Черновик сохранён; проверьте карточку и очередь. Повторная отправка заблокирована.';
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
        kind: FormDraftKind.completion,
        orderId: widget.order.id,
        data: _draftData(),
        basis:
            _basis.expectedVersion == null && _basis.previousCommandId == null
            ? null
            : _basis,
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
    _changed();
  }

  Future<void> _deleteDraft() async {
    if (_locked || _draftSession == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Удалить черновик?'),
        content: Text(
          _uncertain ||
                  _stale ||
                  _photos.any((photo) => photo.uploaded || photo.uncertain)
              ? 'Сначала проверьте карточку наряда и очередь отправки. Удаление черновика не отменяет отчёт, списание материалов, загруженные фотографии или команды в очереди. После удаления форма закроется.'
              : 'Текст, материалы и неотправленные снимки будут удалены с устройства. Уже загруженные фотографии и команды в очереди сохранятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              _uncertain || _stale
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
      await _exit();
    } catch (error) {
      if (mounted) {
        setState(() => _draftError = 'Не удалось удалить черновик: $error');
      }
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_controllerChanged);
    _draftApi = widget.controller.api;
    _draftOwnerId = widget.controller.user?.id;
    _draftToken = widget.controller.api.token;
    _basis = widget.controller.captureOrderBasis(widget.order);
    _assignmentSnapshot = {
      'id': widget.order.id,
      'assignee_id': widget.order.assigneeId,
      'assignee_name': widget.order.assigneeName,
      'brigade_id': widget.order.data['brigade_id'],
      if (widget.order.data.containsKey('participants'))
        'participants': widget.order.data['participants'],
      'participants_source': widget.order.participantsSource,
    };
    _serverPhotos = _maps(widget.order.data['photos'])
        .where((photo) => photo['kind'] == 'after')
        .toList();
    final previous = widget.order.data['completion'];
    if (previous is Map) {
      _work.text = (previous['work_done'] ?? '').toString();
      _comment.text = (previous['comment'] ?? '').toString();
      _faultId = (previous['fault_code_id'] as num?)?.toInt();
      // Materials are incremental on resubmission: never prefill previous totals.
    }
    _work.addListener(_changed);
    _comment.addListener(_changed);
    _openedAsResponsible = _canComplete;
    if (_openedAsResponsible) {
      unawaited(_restoreDraft());
    } else {
      _draftLoading = false;
    }
  }

  void _changed() {
    if (_draftLoading || _draftClosed || _disposing) return;
    if (!_dirty && mounted) {
      // System Back reads PopScope.canPop, so the first edit must rebuild it.
      setState(() => _dirty = true);
    }
    _autosaveRequested = true;
    if (!_autosaveRunning) unawaited(_autosave());
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
    widget.controller.removeListener(_controllerChanged);
    _disposing = true;
    _autosaveRequested = false;
    // Capture the latest edit while text controllers still exist. The frozen
    // session prevents a late write from moving to another account or reviving
    // a deleted draft. Navigation itself already awaits its final write.
    if (!_draftClosed && !_draftLoading && _draftSession != null) {
      unawaited(_saveDraft(updateUi: false));
    }
    _work.dispose();
    _comment.dispose();
    for (final line in _materials) {
      line.quantity.dispose();
    }
    super.dispose();
  }

  bool get _uploading => _photos.any((photo) => photo.uploading);
  bool get _locked =>
      !_canComplete ||
      _draftLoading ||
      _leaving ||
      _draftSession == null ||
      _sending ||
      _picking ||
      _uploading ||
      _checking;
  bool get _hasAfter =>
      _serverPhotos.isNotEmpty ||
      _photos.any((photo) => photo.uploaded) ||
      widget.controller.outbox.any(
        (command) =>
            command.kind == OutboxKind.uploadPhoto &&
            command.photoKind == 'after' &&
            (command.orderId == widget.order.id ||
                command.localRef == '${widget.order.id}'),
      );

  Future<void> _addMaterial() async {
    final rows = _maps(widget.controller.reference['materials']);
    final selected = await showModalBottomSheet<Json>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => _MaterialPicker(
        materials: rows,
        selectedIds: _materials.map((line) => line.material['id']).toSet(),
      ),
    );
    if (selected != null && mounted) {
      _edit(() {
        final line = _MaterialLine(selected);
        line.quantity.addListener(_changed);
        _materials.add(line);
        _dirty = true;
      });
    }
  }

  Future<void> _pickPhoto() async {
    if (_locked || _uncertain) return;
    if (_serverPhotos.length +
            _photos.where((photo) => !photo.uploaded).length >=
        5) {
      setState(
        () => _error = 'Допускается до 5 фотографий «после» на наряд, включая предыдущие сдачи.',
      );
      return;
    }
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      useSafeArea: true,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Добавить фото после ремонта',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => Navigator.pop(context, ImageSource.camera),
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Сделать снимок'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(context, ImageSource.gallery),
              icon: const Icon(Icons.photo_library_outlined),
              label: const Text('Выбрать из галереи'),
            ),
          ],
        ),
      ),
    );
    if (source == null || !mounted) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    _PendingPhoto? pending;
    try {
      final file = await ImagePicker().pickImage(
        source: source,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 88,
      );
      if (file != null) {
        final original = await file.readAsBytes();
        if (original.length > 30 * 1024 * 1024) {
          throw Exception(
            'Снимок слишком большой. Выберите изображение до 30 МБ.',
          );
        }
        final compressed = await compute(_compress, original);
        pending = _PendingPhoto(
          compressed,
          'after-${DateTime.now().microsecondsSinceEpoch}.jpg',
        );
        if (mounted) {
          _edit(() {
            _photos.add(pending!);
            _dirty = true;
          });
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Не удалось подготовить фото: $error');
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
    if (pending != null && mounted) await _upload(pending);
  }

  Future<void> _upload(_PendingPhoto photo) async {
    if (!_canComplete ||
        photo.uploading ||
        photo.uploaded ||
        photo.uncertain ||
        _sending ||
        _uncertain ||
        _stale ||
        _draftLoading ||
        _draftSession == null) {
      return;
    }
    setState(() {
      photo.uploading = true;
      photo.error = null;
    });
    try {
      _operation = 'photo';
      if (!await _saveDraft(state: FormDraftState.submitting)) return;
      _ensureDraftContext();
      _ensureResponsible();
      final commandId = await widget.controller.uploadPhoto(
        widget.order.id,
        photo.bytes,
        photo.filename,
        'after',
        basis: _basis,
      );
      _basis = OrderWriteBasis(previousCommandId: commandId);
      if (!mounted) return;
      setState(() {
        photo.uploaded = true;
        photo.queued = widget.controller.isOrderPending(widget.order.id);
        photo.uploading = false;
      });
      _operation = null;
      if (!await _saveDraft(
        state: FormDraftState.editing,
        acknowledgeSubmission: true,
      )) {
        return;
      }
      // A failed refresh must not turn an acknowledged upload into a retry.
      try {
        final fresh = await widget.controller.loadOrder(widget.order.id);
        if (mounted) {
          setState(
            () =>
                _serverPhotos = _maps(fresh.data['photos'])
                    .where((row) => row['kind'] == 'after')
                    .toList(),
          );
        }
      } catch (_) {
        /* The upload itself was acknowledged. */
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          photo.error = error.toString();
          photo.uncertain = error is ApiException
              ? error.requestMayHaveSucceeded
              : true;
          _uncertain = photo.uncertain;
          photo.uploading = false;
        });
        _operation = photo.uncertain ? 'photo' : null;
        await _saveDraft(
          state: photo.uncertain
              ? FormDraftState.uncertain
              : FormDraftState.editing,
          acknowledgeSubmission: !photo.uncertain,
        );
      }
    } finally {
      if (mounted) setState(() => photo.uploading = false);
    }
  }

  Future<void> _checkServer() async {
    if (_locked) return;
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      _ensureDraftContext();
      final fresh = await widget.controller.loadOrder(widget.order.id);
      _ensureDraftContext();
      if (!mounted) return;
      setState(
        () =>
            _serverPhotos = _maps(fresh.data['photos'])
                .where((row) => row['kind'] == 'after')
                .toList(),
      );
      if (_uncertain && _operation == 'complete') {
        if ({'closed', 'rework', 'completed'}.contains(fresh.status)) {
          setState(() => _done = true);
          setState(
            () => _error = 'На сервере уже есть сданный отчёт. Откройте карточку и проверьте результат. Повторная отправка отключена.',
          );
        } else {
          setState(
            () => _error = 'Сервер пока не подтвердил сдачу. Повторная отправка заблокирована, чтобы не списать материалы дважды. Проверьте состояние позже. Форма остаётся открытой.',
          );
        }
      } else if (_uncertain) {
        setState(
          () => _error = 'Снимки на сервере обновлены. Проверьте карточку и очередь: повторная загрузка из этого черновика заблокирована.',
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Фотографии на сервере обновлены. Проверьте, появился ли ваш снимок.',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _submit() async {
    if (_locked ||
        _uncertain ||
        _stale ||
        _done ||
        !_form.currentState!.validate()) {
      return;
    }
    if (_photos.any((photo) => !photo.uploaded)) {
      setState(
        () => _error = 'Сначала завершите загрузку фотографий или уберите неотправленные снимки из формы.',
      );
      return;
    }
    if (widget.order.workType == 'unplanned' && !_hasAfter) {
      setState(
        () => _error = 'Для внепланового ремонта необходимо фото «после». Добавьте снимок перед отправкой отчёта.',
      );
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      _operation = 'complete';
      if (!await _saveDraft(state: FormDraftState.submitting)) return;
      _ensureDraftContext();
      _ensureResponsible();
      final result = await widget.controller.complete(widget.order.id, {
        'work_done': _work.text.trim(),
        'fault_code_id': _faultId,
        'materials': _materials
            .map(
              (line) => {
                'material_id': line.material['id'],
                'quantity': double.parse(
                  line.quantity.text.trim().replaceAll(',', '.'),
                ),
              },
            )
            .toList(),
        'comment': _comment.text.trim(),
      }, basis: _basis);
      if (!mounted) return;
      _operation = null;
      _done = true;
      // The controller durably owns the command before this form is removed.
      if (!await _saveDraft(
        state: FormDraftState.editing,
        acknowledgeSubmission: true,
      )) {
        return;
      }
      try {
        await _draftSession!.delete();
        _draftClosed = true;
      } catch (error) {
        if (mounted) {
          setState(
            () => _draftError =
                'Отчёт обработан, но не удалось удалить черновик: $error',
          );
        }
        return;
      }
      if (!mounted) return;
      if (result.status != 'completed') {
        setState(() {
          _done = true;
          _error = 'Сервер обработал отчёт. Откройте карточку, чтобы проверить текущее состояние.';
        });
      } else {
        await _exit(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error\nЗаполненные поля сохраняются в черновике.';
          _stale =
              error is ApiException &&
              const {
                'order_version_conflict',
                'order_precondition_unavailable',
                'local_order_precondition_unavailable',
              }.contains(error.code);
          _uncertain = error is ApiException
              ? error.requestMayHaveSucceeded
              : true;
        });
        _operation = _uncertain ? 'complete' : null;
        await _saveDraft(
          state: _uncertain ? FormDraftState.uncertain : FormDraftState.editing,
          acknowledgeSubmission: !_uncertain,
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
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

  Future<void> _leave() async {
    if (_leaving ||
        _draftLoading ||
        _sending ||
        _picking ||
        _uploading ||
        _checking) {
      return;
    }
    if (_draftSession == null) {
      await _closeUnavailable();
      return;
    }
    if (_done || (!_dirty && !_uncertain)) {
      setState(() => _leaving = true);
      if (!_draftClosed && !await _saveDraft()) {
        if (mounted) setState(() => _leaving = false);
        return;
      }
      await _exit();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Закрыть отчёт?'),
        content: Text(
          _uncertain
              ? 'Результат отправки ещё не подтверждён. Черновик останется на устройстве. Проверьте карточку наряда и очередь перед новым отчётом, чтобы не списать материалы дважды.'
              : 'Черновик с текстом, материалами и снимками останется на устройстве. Загруженные фотографии сохранятся у наряда, ожидающие отправки — в очереди.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Продолжить заполнение'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Закрыть форму'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      setState(() => _leaving = true);
      if (await _saveDraft()) {
        await _exit();
      } else if (mounted) {
        setState(() => _leaving = false);
      }
    }
  }

  Future<void> _exit([bool? submitted]) async {
    setState(() {
      _done = true;
      _draftClosed = true;
    });
    // PopScope must rebuild before a programmatic pop of a dirty form.
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop(submitted);
  }

  @override
  Widget build(BuildContext context) {
    if (!_draftContextCurrent || (!_canComplete && !_openedAsResponsible)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Отчёт о выполнении')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _draftContextCurrent
                ? 'Общий результат сдаёт только ответственный. Для участника доступны карточка и фотографии. Существующий черновик сохранён без изменений.'
                : 'Контекст формы изменился. Черновик принадлежит исходному аккаунту и серверу.',
          ),
        ),
      );
    }
    final faults = _maps(widget.controller.reference['fault_codes']);
    final hasPrevious = widget.order.data['completion'] is Map;
    return PopScope(
      canPop: _draftClosed,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF3F5F8),
        appBar: AppBar(
          title: const Text('Отчёт о выполнении'),
          leading: IconButton(
            tooltip: 'Назад',
            onPressed:
                _leaving ||
                    _draftLoading ||
                    _sending ||
                    _picking ||
                    _uploading ||
                    _checking
                ? null
                : _leave,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: _draftLoading
            ? const Center(child: CircularProgressIndicator())
            : Form(
                key: _form,
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Text(
                      widget.order.number,
                      style: const TextStyle(color: Color(0xFF64748B)),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.order.title,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (_assignmentSnapshot?['brigade_id'] != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        'Ответственный при открытии: ${_assignmentSnapshot?['assignee_name'] ?? 'Не зафиксирован'}',
                      ),
                      for (final participant in assignmentParticipants(
                        _assignmentSnapshot!,
                      ))
                        Text(
                          '${participant.isResponsible ? 'Ответственный' : 'Участник'}: ${participant.name}',
                        ),
                      if (_assignmentSnapshot?['participants_source'] != 'live')
                        const Text('Полный прежний состав бригады неизвестен.'),
                    ] else if (_assignmentSnapshot == null &&
                        widget.order.isBrigade)
                      const Text(
                        'Состав назначения в этом старом черновике не зафиксирован.',
                      ),
                    const SizedBox(height: 4),
                    Text(widget.order.equipmentName),
                    const SizedBox(height: 16),
                    _notice(
                      _canComplete
                          ? 'После отправки отчёт поступит мастеру на приёмку. Фото загружаются сразу; текст и материалы — при отправке отчёта.'
                          : 'Ответственный изменился. Отправка отчёта заблокирована. Ввод доступен только для просмотра; перед выходом дождитесь сохранения черновика.',
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      _notice(_error!, error: true),
                    ],
                    const SizedBox(height: 12),
                    Text(
                      _draftSaving
                          ? 'Сохранение черновика…'
                          : _draftSaved
                          ? 'Черновик сохранён на устройстве'
                          : 'Черновик ещё не сохранён',
                      style: const TextStyle(
                        fontSize: 13,
                        color: Color(0xFF64748B),
                      ),
                    ),
                    // Keep this slot stable: inserting error children into the
                    // lazy list must not recreate the focused form fields.
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (_draftError != null) ...[
                          const SizedBox(height: 8),
                          _notice(_draftError!, error: true),
                          TextButton(
                            onPressed: () => _draftSession == null
                                ? _restoreDraft()
                                : _saveDraft(),
                            child: const Text('Повторить сохранение черновика'),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 24),
                    _title('Выполненные работы'),
                    TextFormField(
                      key: const ValueKey('completion-work'),
                      controller: _work,
                      enabled: !_locked && !_done && !_uncertain,
                      minLines: 4,
                      maxLines: 9,
                      maxLength: 5000,
                      decoration: const InputDecoration(
                        labelText: 'Что сделано',
                        hintText:
                            'Какие работы выполнены и как проверен результат',
                      ),
                      validator: (value) => (value?.trim().length ?? 0) < 10
                          ? 'Опишите результат: не менее 10 символов'
                          : null,
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int>(
                      key: const ValueKey('completion-fault'),
                      initialValue: faults.any((row) => row['id'] == _faultId)
                          ? _faultId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Шифр неисправности',
                      ),
                      items: faults
                          .map(
                            (row) => DropdownMenuItem<int>(
                              value: (row['id'] as num).toInt(),
                              child: Text(
                                '${row['code']} · ${row['name']}',
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: _locked || _done || _uncertain
                          ? null
                          : (value) => _edit(() {
                              _faultId = value;
                              _dirty = true;
                            }),
                      validator: (value) =>
                          value == null ? 'Выберите шифр неисправности' : null,
                    ),
                    if (faults.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Справочник не загружен. Вернитесь в карточку и обновите данные.',
                          style: TextStyle(color: Color(0xFFB4232D)),
                        ),
                      ),
                    const SizedBox(height: 24),
                    _title('Материалы и запчасти'),
                    if (hasPrevious) ...[
                      _notice(
                        'Укажите только дополнительный расход при доработке. Материалы предыдущей сдачи уже списаны.',
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_materials.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'Материалы не добавлены. Можно отправить отчёт без расхода.',
                          style: TextStyle(color: Color(0xFF64748B)),
                        ),
                      ),
                    ..._materials.map(_materialRow),
                    OutlinedButton.icon(
                      onPressed: _locked || _done || _uncertain
                          ? null
                          : _addMaterial,
                      icon: const Icon(Icons.add),
                      label: const Text('Найти и добавить материал'),
                    ),
                    const SizedBox(height: 24),
                    _title(
                      widget.order.workType == 'unplanned'
                          ? 'Фото после ремонта · обязательно'
                          : 'Фото после ремонта',
                    ),
                    if (_serverPhotos.isNotEmpty) ...[
                      const Text(
                        'Уже на сервере',
                        style: TextStyle(
                          fontSize: 14,
                          color: Color(0xFF64748B),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: _serverPhotos
                            .map(
                              (photo) => SizedBox(
                                width: 145,
                                child: OrderPhoto(
                                  key: ValueKey(photo['id']),
                                  controller: widget.controller,
                                  photo: photo,
                                  height: 135,
                                ),
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(height: 12),
                    ],
                    ..._photos.map(_photoRow),
                    OutlinedButton.icon(
                      onPressed: _locked || _done || _uncertain
                          ? null
                          : _pickPhoto,
                      icon: const Icon(Icons.add_a_photo_outlined),
                      label: Text(
                        _picking ? 'Подготовка снимка…' : 'Добавить фото',
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'До 5 снимков «после» на наряд. Фото сжимаются перед отправкой.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                    ),
                    if (_photos.any((photo) => photo.uncertain))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: OutlinedButton.icon(
                          onPressed: _locked ? null : _checkServer,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Проверить фотографии на сервере'),
                        ),
                      ),
                    const SizedBox(height: 24),
                    _title('Комментарий'),
                    TextFormField(
                      key: const ValueKey('completion-comment'),
                      controller: _comment,
                      enabled: !_locked && !_done && !_uncertain,
                      minLines: 2,
                      maxLines: 5,
                      maxLength: 3000,
                      decoration: const InputDecoration(
                        labelText: 'Дополнительные сведения',
                        hintText:
                            'Например, что проверить при следующем осмотре',
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Черновик с текстом, материалами и снимками сохраняется на устройстве. Отправленный без связи отчёт хранится отдельно в очереди и ожидает синхронизации.',
                      style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _locked ? null : _deleteDraft,
                      child: const Text('Удалить черновик'),
                    ),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
        bottomNavigationBar: !_canComplete
            ? null
            : SafeArea(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Colors.white,
                    border: Border(top: BorderSide(color: Color(0xFFDDE3EB))),
                  ),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(double.infinity, 56),
                      backgroundColor: const Color(0xFF173E68),
                    ),
                    onPressed: _locked || _stale
                        ? null
                        : _done
                        ? _exit
                        : _uncertain
                        ? _checkServer
                        : _submit,
                    icon: _locked
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _done
                                ? Icons.assignment_outlined
                                : _uncertain
                                ? Icons.refresh
                                : Icons.send_outlined,
                          ),
                    label: Text(
                      _sending
                          ? 'Отправка отчёта…'
                          : _checking
                          ? 'Проверка…'
                          : _done
                          ? 'Открыть карточку наряда'
                          : _uncertain
                          ? 'Проверить отправку'
                          : 'Отправить на приёмку',
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _title(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
    ),
  );
  Widget _notice(String text, {bool error = false}) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: error ? const Color(0xFFFFF1F1) : const Color(0xFFEAF0F8),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 14,
        height: 1.4,
        color: error ? const Color(0xFFB4232D) : const Color(0xFF244A71),
      ),
    ),
  );

  Widget _materialRow(_MaterialLine line) => Container(
    key: ValueKey(line.material['id']),
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFDDE3EB)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                line.material['name'].toString(),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Убрать материал',
              onPressed: _locked || _done || _uncertain
                  ? null
                  : () => _edit(() {
                      _materials.remove(line);
                      _dirty = true;
                    }),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 8),
        TextFormField(
          controller: line.quantity,
          enabled: !_locked && !_done && !_uncertain,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Количество',
            suffixText: line.material['unit'].toString(),
          ),

          validator: (value) {
            final quantity = double.tryParse(
              (value ?? '').trim().replaceAll(',', '.'),
            );
            return quantity == null ||
                    !quantity.isFinite ||
                    quantity <= 0 ||
                    quantity > 1000000
                ? 'Введите количество больше 0, до 1 000 000'
                : null;
          },
        ),
      ],
    ),
  );

  Widget _photoRow(_PendingPhoto photo) => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: const Color(0xFFDDE3EB)),
      borderRadius: BorderRadius.circular(10),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                photo.bytes,
                width: 82,
                height: 82,
                fit: BoxFit.cover,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    photo.uploaded
                        ? photo.queued
                              ? 'Фото сохранено на устройстве. Ожидает отправки.'
                              : 'Фото получено сервером'
                        : photo.uploading
                        ? 'Фото отправляется…'
                        : photo.uncertain
                        ? 'Результат загрузки неизвестен'
                        : 'Фото не отправлено',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(
                    '${(photo.bytes.length / 1024).round()} КБ · JPEG',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF64748B),
                    ),
                  ),
                  if (photo.uploading)
                    const Padding(
                      padding: EdgeInsets.only(top: 12),
                      child: LinearProgressIndicator(),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (photo.error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(
              photo.error!,
              style: const TextStyle(fontSize: 14, color: Color(0xFFB4232D)),
            ),
          ),
        if (photo.uncertain)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'Сначала проверьте снимки на сервере. Если фото уже есть, уберите этот снимок из очереди: повторная загрузка создаст копию.',
              style: TextStyle(fontSize: 14),
            ),
          ),
        if (!photo.uploaded && !photo.uploading)
          Wrap(
            spacing: 8,
            children: [
              if (!photo.uncertain)
                TextButton.icon(
                  onPressed: _locked ? null : () => _upload(photo),
                  icon: const Icon(Icons.refresh),
                  label: const Text('Повторить загрузку'),
                ),
              TextButton(
                onPressed: _locked
                    ? null
                    : () => _edit(() => _photos.remove(photo)),
                child: Text(
                  photo.uncertain ? 'Убрать из очереди' : 'Убрать снимок',
                ),
              ),
            ],
          ),
      ],
    ),
  );
}

class _MaterialLine {
  _MaterialLine(this.material);
  final Json material;
  final quantity = TextEditingController(text: '1');
}

class _PendingPhoto {
  _PendingPhoto(this.bytes, this.filename) : encodedBytes = base64Encode(bytes);
  final Uint8List bytes;
  final String encodedBytes;
  final String filename;
  bool uploading = false;
  bool uploaded = false;
  bool queued = false;
  bool uncertain = false;
  String? error;
}

class _MaterialPicker extends StatefulWidget {
  const _MaterialPicker({required this.materials, required this.selectedIds});
  final List<Json> materials;
  final Set<dynamic> selectedIds;
  @override
  State<_MaterialPicker> createState() => _MaterialPickerState();
}

class _MaterialPickerState extends State<_MaterialPicker> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final rows = widget.materials
        .where(
          (row) =>
              !widget.selectedIds.contains(row['id']) &&
              '${row['name']}'.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.viewInsetsOf(context).bottom + 12,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Материалы и запчасти',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Закрыть поиск',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Поиск по справочнику',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('Материалы не найдены'))
                  : ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) => ListTile(
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        title: Text(rows[index]['name'].toString()),
                        subtitle: Text('Единица: ${rows[index]['unit']}'),
                        trailing: const Icon(Icons.add),
                        onTap: () => Navigator.pop(context, rows[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

List<Json> _maps(dynamic value) => value is List
    ? value
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList()
    : [];

Uint8List _compress(Uint8List bytes) {
  var image = imaging.decodeImage(bytes);
  if (image == null) {
    throw const FormatException('Не удалось прочитать изображение');
  }
  image = imaging.bakeOrientation(image);
  if (image.width > 1920 || image.height > 1920) {
    image = image.width >= image.height
        ? imaging.copyResize(image, width: 1920)
        : imaging.copyResize(image, height: 1920);
  }
  return Uint8List.fromList(imaging.encodeJpg(image, quality: 82));
}
