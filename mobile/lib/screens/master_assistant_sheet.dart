import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../domain/navigation_scope.dart';

class MasterAssistantSheet extends StatefulWidget {
  const MasterAssistantSheet({required this.controller, super.key});
  final AppController controller;

  @override
  State<MasterAssistantSheet> createState() => _MasterAssistantSheetState();
}

class _MasterAssistantSheetState extends State<MasterAssistantSheet> {
  final input = TextEditingController();
  final entries = <(String, String)>[];
  bool busy = false;
  late final NavigationScope scope;

  @override
  void initState() {
    super.initState();
    scope = widget.controller.captureNavigationScope();
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  Future<void> send() async {
    final question = input.text.trim();
    if (busy || question.length < 2 || !scope.isCurrent) return;
    setState(() { busy = true; input.clear(); });
    try {
      final result = await widget.controller.api.askMasterAssistant(question);
      if (mounted && scope.isCurrent) {
        setState(() => entries.add((question, result['answer'] as String)));
      }
    } catch (_) {
      if (mounted && scope.isCurrent) {
        setState(() => entries.add((question, 'Не удалось получить ответ. Проверьте сеть и попробуйте ещё раз.')));
      }
    } finally {
      if (mounted && scope.isCurrent) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .65,
        child: Column(children: [
          const ListTile(title: Text('Ассистент мастера'), subtitle: Text('Ответы по актуальным данным сервера')),
          Expanded(child: ListView(padding: const EdgeInsets.all(16), children: [
            if (entries.isEmpty) const Text('Спросите, кто свободен из электриков, что просрочено или попросите отчёт за неделю по участку.'),
            for (final entry in entries) ...[
              Align(alignment: Alignment.centerRight, child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(entry.$1)))),
              Align(alignment: Alignment.centerLeft, child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(entry.$2)))),
            ],
            if (busy) const LinearProgressIndicator(),
          ])),
          Padding(padding: const EdgeInsets.all(12), child: Row(children: [
            Expanded(child: TextField(controller: input, maxLength: 500, textInputAction: TextInputAction.send, onSubmitted: (_) => send(), decoration: const InputDecoration(hintText: 'Задайте вопрос', counterText: ''))),
            IconButton(tooltip: 'Отправить', onPressed: busy ? null : send, icon: const Icon(Icons.send)),
          ])),
        ]),
      ),
    ),
  );
}
