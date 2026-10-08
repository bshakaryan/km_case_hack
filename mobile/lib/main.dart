import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'data/app_controller.dart';
import 'data/push_service.dart';
import 'domain/navigation_scope.dart';
import 'screens/login_screen.dart';
import 'screens/order_detail_screen.dart';
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
  final orderRoutes = _OrderRouteObserver();
  PushService? push;
  StreamSubscription<int>? pushTaps;
  NavigationScope? displayedScope;
  int navigationRevision = 0;
  Object? scheduledPush;

  void sessionChanged() {
    final active = controller.user != null;
    final previous = displayedScope;
    if (previous == null ? active : !previous.isCurrent) {
      displayedScope = active ? controller.captureNavigationScope() : null;
      scheduledPush = null;
      final revision = ++navigationRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // An old logout callback must not pop a newer account's routes.
        if (mounted && revision == navigationRevision) {
          navigatorKey.currentState?.popUntil((route) => route.isFirst);
        }
      });
    }
    if (active) _openPushOrderIfAny();
  }

  // Opens a notification tapped before the session was ready; consumed once.
  void _openPushOrderIfAny() {
    final scope = displayedScope;
    if (scheduledPush != null ||
        scope == null ||
        !scope.isCurrent ||
        controller.referenceWriteBusy) {
      return;
    }
    final orderId = controller.consumePendingPushOrder();
    if (orderId == null) return;
    final ticket = Object();
    scheduledPush = ticket;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(scheduledPush, ticket)) return;
      scheduledPush = null;
      if (!scope.isCurrent) return;
      if (controller.referenceWriteBusy) {
        // A write began after scheduling: retain this target in the same scope.
        controller.openOrderFromPush(orderId);
        return;
      }
      if (orderRoutes.hasOrder(orderId)) {
        _openPushOrderIfAny();
        return;
      }
      navigatorKey.currentState?.push<void>(
        MaterialPageRoute(
          settings: RouteSettings(name: 'order:$orderId'),
          builder: (_) => OrderDetailScreen(
            controller: controller,
            orderId: orderId,
            notificationEntry: true,
          ),
        ),
      );
      // A second, different tap can arrive while the first callback is pending.
      _openPushOrderIfAny();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void initState() {
    super.initState();
    // Firebase only for the real entry point: widget.controller (tests and
    // embedded runs) keeps the plugin-free NoopPushService path.
    if (widget.controller == null && !kIsWeb) {
      push = FirebasePushService();
    }
    controller = widget.controller ?? AppController(pushService: push);
    if (push != null) {
      pushTaps = push!.orderTaps.listen(controller.openOrderFromPush);
      unawaited(
        push!.init().catchError((Object failure) {
          debugPrint('[naryad.push] init failed: $failure');
        }),
      );
    }
    displayedScope = controller.user == null
        ? null
        : controller.captureNavigationScope();
    controller.addListener(sessionChanged);
    controller.restoreSession();
    if (displayedScope != null) _openPushOrderIfAny();
  }

  @override
  void dispose() {
    unawaited(pushTaps?.cancel());
    controller.removeListener(sessionChanged);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorKey: navigatorKey,
    navigatorObservers: [orderRoutes],
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

/// Includes detail routes opened inside the workspace as well as push routes.
class _OrderRouteObserver extends NavigatorObserver {
  final Set<Route<dynamic>> _routes = {};

  bool hasOrder(int id) =>
      _routes.any((route) => route.settings.name == 'order:$id');

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _routes.remove(oldRoute);
    if (newRoute != null) _routes.add(newRoute);
  }
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
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(color: colors.primary),
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
