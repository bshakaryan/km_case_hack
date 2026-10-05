import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/app_controller.dart';
import '../ui.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({required this.controller, super.key});
  final AppController controller;
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final login = TextEditingController();
  final pin = TextEditingController();
  final server = TextEditingController(
    text: const String.fromEnvironment(
      'API_BASE_URL',
      defaultValue: kIsWeb ? 'http://localhost:8000' : 'http://10.0.2.2:8000',
    ),
  );
  final form = GlobalKey<FormState>();
  String? error;
  bool sending = false;
  bool obscure = true;
  @override
  void dispose() {
    login.dispose();
    pin.dispose();
    server.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (sending || !form.currentState!.validate()) return;
    setState(() {
      sending = true;
      error = null;
    });
    try {
      await widget.controller.login(
        server.text.trim(),
        login.text.trim(),
        pin.text.trim(),
      );
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Form(
              key: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      color: navy,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.assignment_turned_in_outlined,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'НарядAI',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Работы под контролем',
                    style: TextStyle(fontSize: 20, color: muted),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Задания, выполнение и приёмка\nв одном рабочем пространстве.',
                    style: TextStyle(color: muted, height: 1.5),
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: login,
                    enabled: !sending,
                    decoration: const InputDecoration(
                      labelText: 'Логин',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    autofillHints: const [AutofillHints.username],
                    textInputAction: TextInputAction.next,
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Введите логин' : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: pin,
                    enabled: !sending,
                    obscureText: obscure,
                    keyboardType: TextInputType.number,
                    autofillHints: const [AutofillHints.password],
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => submit(),
                    decoration: InputDecoration(
                      labelText: 'ПИН-код',
                      prefixIcon: const Icon(Icons.lock_outline),
                      suffixIcon: IconButton(
                        tooltip: obscure ? 'Показать ПИН' : 'Скрыть ПИН',
                        onPressed: () => setState(() => obscure = !obscure),
                        icon: Icon(
                          obscure
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                      ),
                    ),
                    validator: (v) => v == null || v.trim().length < 4
                        ? 'Не менее 4 символов'
                        : null,
                  ),
                  if (error != null || widget.controller.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: InfoPanel(
                        error ?? widget.controller.error!,
                        color: danger,
                      ),
                    ),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: sending || widget.controller.loading
                          ? null
                          : submit,
                      child: sending
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Войти'),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Divider(),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text(
                      'Подключение к серверу',
                      style: TextStyle(fontSize: 15),
                    ),
                    children: [
                      TextFormField(
                        controller: server,
                        enabled: !sending,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Адрес сервера',
                          helperText:
                              'На телефоне укажите адрес сервера в вашей сети.',
                          helperMaxLines: 3,
                        ),
                        validator: (v) {
                          final uri = Uri.tryParse(v?.trim() ?? '');
                          return uri == null ||
                                  !{'http', 'https'}.contains(uri.scheme) ||
                                  uri.host.isEmpty
                              ? 'Укажите полный адрес http:// или https://'
                              : null;
                        },
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const InfoPanel(
                    'Демо: master или worker2 · ПИН 1234.\nДанные учебные. Проверка ИИ пока имитируется сервером.',
                    icon: Icons.science_outlined,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
