import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../data/models.dart';

/// Loads private media through the authenticated API; the URL is not public.
class OrderPhoto extends StatefulWidget {
  const OrderPhoto({
    super.key,
    required this.controller,
    required this.photo,
    this.height = 170,
  });

  final AppController controller;
  final Json photo;
  final double height;

  @override
  State<OrderPhoto> createState() => _OrderPhotoState();
}

class _OrderPhotoState extends State<OrderPhoto> {
  late Future<Uint8List> _bytes;

  @override
  void initState() {
    super.initState();
    _bytes = _load();
  }

  Future<Uint8List> _load() => widget.controller.photoBytes(
    (widget.photo['id'] as num).toInt(),
  );

  @override
  void didUpdateWidget(covariant OrderPhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.photo['id'] != widget.photo['id'] ||
        oldWidget.controller != widget.controller) {
      _bytes = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.photo['kind'] == 'before'
        ? 'До ремонта'
        : 'После ремонта';
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox(
        height: widget.height,
        width: double.infinity,
        child: ColoredBox(
          color: const Color(0xFFE9EDF2),
          child: FutureBuilder<Uint8List>(
            future: _bytes,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Фото не загрузилось'),
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 52),
                        ),
                        onPressed: () => setState(() => _bytes = _load()),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Повторить'),
                      ),
                    ],
                  ),
                );
              }
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final bytes = snapshot.data!;
              return Semantics(
                button: true,
                label: '$label. Открыть фотографию',
                child: InkWell(
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (context) => Dialog.fullscreen(
                      child: Scaffold(
                        appBar: AppBar(title: Text(label)),
                        body: Center(
                          child: InteractiveViewer(
                            minScale: 0.5,
                            maxScale: 5,
                            child: Image.memory(bytes, fit: BoxFit.contain),
                          ),
                        ),
                      ),
                    ),
                  ),
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    semanticLabel: label,
                    errorBuilder: (_, _, _) =>
                        const Center(child: Text('Не удалось прочитать фото')),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
