import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/app_controller.dart';
import 'screens/login_screen.dart';
import 'screens/workspace_screen.dart';
import 'ui.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const NaryadApp());
}

class NaryadApp extends StatefulWidget {
  const NaryadApp({super.key, this.controller});
  final AppController? controller;
  @override
  State<NaryadApp> createState() => _NaryadAppState();
}

class _NaryadAppState extends State<NaryadApp> {
  late final AppController controller;
  final navigatorKey = GlobalKey<NavigatorState>();
  bool hadSession = false;
  void sessionChanged() {
    final active = controller.user != null;
    if (hadSession && !active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          navigatorKey.currentState?.popUntil((route) => route.isFirst);
        }
      });
    }
    hadSession = active;
  }

  @override
  void initState() {
    super.initState();
    controller = widget.controller ?? AppController();
    hadSession = controller.user != null;
    controller.addListener(sessionChanged);
    controller.restoreSession();
  }

  @override
  void dispose() {
    controller.removeListener(sessionChanged);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    title: 'НарядAI',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    home: ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.restoring && controller.user == null) {
          return const _RestoringScreen();
        }
        return controller.user == null
            ? LoginScreen(controller: controller)
            : WorkspaceScreen(controller: controller);
      },
    ),
  );
}

class _RestoringScreen extends StatelessWidget {
  const _RestoringScreen();
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.surface,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.construction, size: 72, color: colors.primary),
            const SizedBox(height: 16),
            Text(
              'НарядAI',
              style: Theme.of(
                context,
              ).textTheme.headlineMedium?.copyWith(color: colors.primary),
            ),
            const SizedBox(height: 24),
            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
          ],
        ),
      ),
    );
  }
}
