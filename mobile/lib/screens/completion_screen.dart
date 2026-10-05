import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as imaging;
import 'package:image_picker/image_picker.dart';

import '../data/api.dart';
import '../data/app_controller.dart';
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

class _CompletionScreenState extends State<CompletionScreen> {
  final _form = GlobalKey<FormState>();
  final _work = TextEditingController();
  final _comment = TextEditingController();
  final _materials = <_MaterialLine>[];
  final _photos = <_PendingPhoto>[];
  List<Json> _serverPhotos = [];
  int? _faultId;
  bool _sending = false;
  bool _picking = false;
  bool _checking = false;
  bool _dirty = false;
  bool _uncertain = false;
  bool _done = false;
  String? _error;

  @override
  void initState() {
    super.initState();
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
  }

  void _changed() {
    if (!_dirty && mounted) {
      // System Back reads PopScope.canPop, so the first edit must rebuild it.
      setState(() => _dirty = true);
    }
  }

  @override
  void dispose() {
    _work.dispose();
    _comment.dispose();
    for (final line in _materials) {
      line.quantity.dispose();
    }
    super.dispose();
  }

  bool get _uploading => _photos.any((photo) => photo.uploading);
  bool get _locked => _sending || _picking || _uploading || _checking;
  bool get _hasAfter =>
      _serverPhotos.isNotEmpty || _photos.any((photo) => photo.uploaded);

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
      setState(() {
        _materials.add(_MaterialLine(selected));
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
          setState(() {
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
    if (photo.uploading || photo.uploaded || photo.uncertain || _sending) {
      return;
    }
    setState(() {
      photo.uploading = true;
      photo.error = null;
    });
    try {
      await widget.controller.uploadPhoto(
        widget.order.id,
        photo.bytes,
        photo.filename,
        'after',
      );
      if (!mounted) return;
      setState(() => photo.uploaded = true);
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
        });
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
      final fresh = await widget.controller.loadOrder(widget.order.id);
      if (!mounted) return;
      setState(
        () =>
            _serverPhotos = _maps(fresh.data['photos'])
                .where((row) => row['kind'] == 'after')
                .toList(),
      );
      if (_uncertain) {
        if ({
          'ai_review',
          'closed',
          'rework',
          'completed',
        }.contains(fresh.status)) {
          setState(() => _done = true);
          setState(
            () => _error = 'На сервере уже есть сданный отчёт. Откройте карточку и проверьте результат. Повторная отправка отключена.',
          );
        } else {
          setState(
            () => _error = 'Сервер пока не подтвердил сдачу. Повторная отправка заблокирована, чтобы не списать материалы дважды. Проверьте состояние позже. Форма остаётся открытой.',
          );
        }
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
    if (_locked || _uncertain || _done || !_form.currentState!.validate()) {
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
      });
      if (!mounted) return;
      if (result.status != 'ai_review' && result.status != 'completed') {
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
          _error = '$error\nЗаполненные поля остаются в этой форме.';
          _uncertain = error is ApiException
              ? error.requestMayHaveSucceeded
              : true;
        });
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _leave() async {
    if (_locked) return;
    if (_done || (!_dirty && !_uncertain)) {
      await _exit();
      return;
    }
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Закрыть отчёт?'),
        content: Text(
          _uncertain
              ? 'Результат отправки ещё не подтверждён. Сначала проверьте карточку наряда перед новым отчётом, чтобы не списать материалы дважды. Текст этой формы после закрытия не сохранится.'
              : 'Текст и материалы ещё не сохранены на устройстве и будут потеряны. Уже загруженные фотографии останутся у наряда на сервере.',
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
    if (leave == true && mounted) await _exit();
  }

  Future<void> _exit([bool? submitted]) async {
    setState(() => _done = true);
    // PopScope must rebuild before a programmatic pop of a dirty form.
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop(submitted);
  }

  @override
  Widget build(BuildContext context) {
    final faults = _maps(widget.controller.reference['fault_codes']);
    final hasPrevious = widget.order.data['completion'] is Map;
    return PopScope(
      canPop: _done || (!_dirty && !_uncertain && !_locked),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFFF3F5F8),
        appBar: AppBar(
          title: const Text('Отчёт о выполнении'),
          leading: IconButton(
            tooltip: 'Назад',
            onPressed: _locked ? null : _leave,
            icon: const Icon(Icons.arrow_back),
          ),
        ),
        body: Form(
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
              const SizedBox(height: 4),
              Text(widget.order.equipmentName),
              const SizedBox(height: 16),
              _notice(
                'После отправки отчёт поступит мастеру на приёмку. Фото загружаются сразу; текст и материалы — при отправке отчёта.',
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                _notice(_error!, error: true),
              ],
              const SizedBox(height: 24),
              _title('Выполненные работы'),
              TextFormField(
                controller: _work,
                enabled: !_sending && !_done && !_uncertain,
                minLines: 4,
                maxLines: 9,
                maxLength: 5000,
                decoration: const InputDecoration(
                  labelText: 'Что сделано',
                  hintText: 'Какие работы выполнены и как проверен результат',
                ),
                validator: (value) => (value?.trim().length ?? 0) < 10
                    ? 'Опишите результат: не менее 10 символов'
                    : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
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
                onChanged: _sending || _done || _uncertain
                    ? null
                    : (value) => setState(() {
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
                onPressed: _locked || _done || _uncertain ? null : _addMaterial,
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
                  style: TextStyle(fontSize: 14, color: Color(0xFF64748B)),
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
                onPressed: _locked || _done || _uncertain ? null : _pickPhoto,
                icon: const Icon(Icons.add_a_photo_outlined),
                label: Text(_picking ? 'Подготовка снимка…' : 'Добавить фото'),
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
                controller: _comment,
                enabled: !_sending && !_done && !_uncertain,
                minLines: 2,
                maxLines: 5,
                maxLength: 3000,
                decoration: const InputDecoration(
                  labelText: 'Дополнительные сведения',
                  hintText: 'Например, что проверить при следующем осмотре',
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Форма хранится только пока открыт этот экран. Офлайн-отправка пока недоступна.',
                style: TextStyle(fontSize: 13, color: Color(0xFF64748B)),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
        bottomNavigationBar: SafeArea(
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
              onPressed: _locked
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
                  : () => setState(() {
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
          enabled: !_sending && !_done && !_uncertain,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Количество',
            suffixText: line.material['unit'].toString(),
          ),
          onChanged: (_) => _dirty = true,
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
                        ? 'Фото получено сервером'
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
                    : () => setState(() => _photos.remove(photo)),
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
  _PendingPhoto(this.bytes, this.filename);
  final Uint8List bytes;
  final String filename;
  bool uploading = false;
  bool uploaded = false;
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
