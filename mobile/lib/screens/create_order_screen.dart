import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as imaging;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../data/api.dart';
import '../data/app_controller.dart';
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
  });

  final AppController controller;
  final int? assigneeId;
  final int? equipmentId;
  final ImagePicker? imagePicker;

  @override
  State<CreateOrderScreen> createState() => _CreateOrderScreenState();
}

enum _PhotoState { ready, uploading, uploaded, failed, uncertain }

class _DraftPhoto {
  _DraftPhoto(this.bytes, this.filename);
  final Uint8List bytes;
  final String filename;
  _PhotoState state = _PhotoState.ready;
  bool queued = false;
  String? error;
}

class _CreateOrderScreenState extends State<CreateOrderScreen> {
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
  bool _byBrigade = false;
  String _workType = 'unplanned';
  String _priority = 'normal';
  DateTime _deadline = DateTime.now().toUtc().add(const Duration(hours: 2));
  bool _busy = false;
  bool _picking = false;
  bool _creationUncertain = false;
  String? _error;
  WorkOrder? _created;

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
    _picker = widget.imagePicker ?? ImagePicker();
    _assigneeId = widget.assigneeId;
    _equipmentId = widget.equipmentId;
    final equipment = _find(_reference('equipment'), _equipmentId);
    _areaId = equipment?['area_id'] as int?;
    widget.controller.addListener(_controllerChanged);
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
  void dispose() {
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
    setState(() {
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
    if (mounted && row != null) setState(() => _equipmentId = row['id'] as int);
  }

  Future<void> _chooseAssignee() async {
    final row = await _choose(
      title: _byBrigade ? 'Бригада' : 'Исполнитель',
      rows: _byBrigade ? _reference('brigades') : widget.controller.employees,
      employees: !_byBrigade,
      subtitle: _byBrigade ? null : _employeeDetail,
    );
    if (!mounted || row == null) return;
    setState(() {
      if (_byBrigade) {
        _brigadeId = row['id'] as int;
        _assigneeId = null;
      } else {
        _assigneeId = row['id'] as int;
        _brigadeId = null;
      }
      _error = null;
    });
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
    setState(() {
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
      final bytes = await compute(
        prepareOrderPhoto,
        await picked.readAsBytes(),
      );
      if (bytes.length > 10 * 1024 * 1024) {
        throw const FormatException(
          'Фото слишком большое. Выберите другой снимок.',
        );
      }
      if (mounted) {
        setState(
          () => _photos.add(
            _DraftPhoto(
              bytes,
              'before-${DateTime.now().microsecondsSinceEpoch}.jpg',
            ),
          ),
        );
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
      setState(() {
        _step = 1;
        _error = null;
      });
    }
  }

  Future<void> _submit() async {
    if (_busy || _picking || _creationUncertain) return;
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
          'priority': _priority,
          'deadline': _deadline.toUtc().toIso8601String(),
          'comment': _comment.text.trim(),
        };
        try {
          final created = await widget.controller.createOrder(payload);
          if (!mounted) return;
          setState(() => _created = created);
        } on ApiException catch (error) {
          if (!mounted) return;
          setState(() {
            _creationUncertain = error.requestMayHaveSucceeded;
            _error = _creationUncertain
                ? 'Ответ о выдаче не получен. Наряд мог сохраниться. Вернитесь к списку и проверьте его перед новой выдачей.'
                : error.message;
          });
          return;
        } catch (_) {
          if (mounted) {
            setState(() {
              _creationUncertain = true;
              _error = 'Не удалось подтвердить выдачу. Проверьте список нарядов перед новой попыткой.';
            });
          }
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
          await widget.controller.uploadPhoto(
            _created!.id,
            photo.bytes,
            photo.filename,
            'before',
          );
          if (!mounted) return;
          setState(() {
            photo.state = _PhotoState.uploaded;
            photo.queued = widget.controller.isOrderPending(_created!.id);
          });
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
          // An uncertain upload must never be replayed without server deduplication.
          if (error.requestMayHaveSucceeded) break;
        } catch (_) {
          if (!mounted) return;
          setState(() {
            photo.state = _PhotoState.uncertain;
            photo.error = 'Нет подтверждения. Проверьте фото в наряде.';
          });
          break;
        }
      }
      if (!mounted) return;
      if (_photos.every((photo) => photo.state == _PhotoState.uploaded)) {
        Navigator.pop(context, _created);
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
                  onPressed: () => setState(() => _photos.remove(photo)),
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
                setState(() => _workType = selected.first),
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
          onSelectionChanged: (selected) => setState(() {
            _byBrigade = selected.first;
            _assigneeId = null;
            _brigadeId = null;
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
        if (_byBrigade)
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'В текущей версии сервер назначит одного доступного работника бригады. Ответственный появится в выданном наряде.',
              style: TextStyle(fontSize: 14, color: Color(0xFF536275)),
            ),
          ),
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
                onPressed: () => setState(() {
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
                onSelected: (_) => setState(() => _priority = item.key),
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
      canPop: !_busy && !_picking,
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
            onPressed: _busy || _picking
                ? null
                : () {
                    if (_step == 1 && !partial && !_creationUncertain) {
                      setState(() {
                        _step = 0;
                        _error = null;
                      });
                    } else {
                      Navigator.pop(context, _created);
                    }
                  },
          ),
        ),
        body: SafeArea(
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
                            border: Border.all(color: const Color(0xFFE8BCB8)),
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
                          style: Theme.of(context).textTheme.headlineSmall,
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
                          'Повторная отправка заблокирована, чтобы не создать второй наряд. Черновик находится только на этом экране и не сохраняется после его закрытия.',
                        ),
                      ] else
                        AbsorbPointer(
                          absorbing: _busy,
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
                      if (hasRetryablePhotos)
                        OutlinedButton.icon(
                          onPressed: _submit,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Повторить неотправленные фото'),
                        ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, _created),
                        child: const Text('Открыть выданный наряд'),
                      ),
                    ] else
                      FilledButton(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(54),
                        ),
                        onPressed: _busy || _picking
                            ? null
                            : _creationUncertain
                            ? () => Navigator.pop(context)
                            : _step == 0
                            ? _next
                            : _submit,
                        child: _busy
                            ? const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
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
