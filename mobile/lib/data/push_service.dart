import 'dart:async';
import 'dart:ui';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'api.dart';

/// Notification channels fixed by the server contract.
const String kDefaultNotificationChannelId = 'naryad_default';
const String kEmergencyNotificationChannelId = 'naryad_emergency';

const Color kEmergencyNotificationColor = Color(0xFFC62828);

const AndroidNotificationChannel naryadDefaultChannel =
    AndroidNotificationChannel(
      kDefaultNotificationChannelId,
      'Основные уведомления',
      description: 'Новые наряды и события смены.',
      importance: Importance.high,
      playSound: true,
      enableVibration: true,
    );

const AndroidNotificationChannel naryadEmergencyChannel =
    AndroidNotificationChannel(
      kEmergencyNotificationChannelId,
      'Аварийные уведомления',
      description: 'Аварийные наряды, требующие немедленного ответа.',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );

const InitializationSettings naryadNotificationSettings =
    InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: false,
        requestSoundPermission: false,
        requestBadgePermission: false,
      ),
    );

/// Abstraction over platform push so tests and web never touch Firebase.
abstract class PushService {
  /// Prepares channels, message listeners and the FCM token plumbing.
  Future<void> init();

  /// Asks for notification permission and returns the current FCM token.
  Future<String?> requestToken();

  /// Stores [api] as the registration target and uploads the token.
  Future<void> registerWith(NaryadApi api);

  /// Removes the last registered token from the server (best effort).
  Future<void> unregister();

  /// Order ids of notifications the user tapped, in delivery order.
  Stream<int> get orderTaps;
}

/// Safe fallback for unit tests, web and unavailable Firebase setups.
class NoopPushService implements PushService {
  const NoopPushService();

  static const Stream<int> _empty = Stream<int>.empty();

  @override
  Future<void> init() async {}

  @override
  Future<String?> requestToken() async => null;

  @override
  Future<void> registerWith(NaryadApi api) async {}

  @override
  Future<void> unregister() async {}

  @override
  Stream<int> get orderTaps => _empty;
}

bool _isEmergency(Map<dynamic, dynamic> data) {
  if ('${data['emergency'] ?? ''}'.toLowerCase() == 'true') return true;
  final kind = '${data['kind'] ?? ''}'.toLowerCase();
  return kind.contains('emergency') || kind.contains('critical');
}

int? _orderIdOf(RemoteMessage message) {
  final id = int.tryParse('${message.data['order_id'] ?? ''}');
  return id != null && id > 0 ? id : null;
}

int _displayIdOf(RemoteMessage message) {
  final declared = int.tryParse('${message.data['notification_id'] ?? ''}');
  if (declared != null) return declared;
  return message.messageId?.hashCode.abs() ?? 0;
}

/// Background entry point: top level only, never touches AppController.
///
/// FCM notification messages are drawn by the system tray; data-only
/// messages are displayed here through flutter_local_notifications.
@pragma('vm:entry-point')
Future<void> naryadBackgroundMessageHandler(RemoteMessage message) async {
  try {
    await Firebase.initializeApp();
  } catch (failure) {
    debugPrint('[naryad.push] background firebase init failed: $failure');
    return;
  }
  if (message.notification != null) return;
  try {
    final notifications = FlutterLocalNotificationsPlugin();
    await notifications.initialize(settings: naryadNotificationSettings);
    final android = notifications
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await android?.createNotificationChannel(naryadDefaultChannel);
    await android?.createNotificationChannel(naryadEmergencyChannel);
    final emergency = _isEmergency(message.data);
    // Data-only payloads carry no title/body in the frozen contract.
    final title = emergency ? 'Аварийное уведомление' : 'НарядAI';
    final body = '${message.data['body'] ?? message.data['message'] ?? ''}';
    await notifications.show(
      id: _displayIdOf(message),
      title: title,
      body: body.isEmpty ? 'Открыть наряд' : body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          emergency
              ? kEmergencyNotificationChannelId
              : kDefaultNotificationChannelId,
          emergency ? 'Аварийные уведомления' : 'Основные уведомления',
          channelDescription: emergency
              ? 'Аварийные наряды, требующие немедленного ответа.'
              : 'Новые наряды и события смены.',
          importance: emergency ? Importance.max : Importance.high,
          priority: emergency ? Priority.high : Priority.defaultPriority,
          color: emergency ? kEmergencyNotificationColor : null,
          colorized: emergency,
          styleInformation: BigTextStyleInformation(
            body.isEmpty ? 'Открыть наряд' : body,
            contentTitle: title,
          ),
        ),
      ),
      payload: '${message.data['order_id'] ?? ''}',
    );
  } catch (failure) {
    debugPrint('[naryad.push] background display failed: $failure');
  }
}

/// Production implementation backed by Firebase Cloud Messaging.
///
/// Every platform call is guarded: a missing `google-services.json`,
/// a desktop run or a denied permission degrades to a logged no-op
/// instead of crashing the app.
class FirebasePushService implements PushService {
  final StreamController<int> _taps = StreamController<int>.broadcast();
  Future<void>? _initFuture;
  FirebaseMessaging? _messaging;
  FlutterLocalNotificationsPlugin? _notifications;
  NaryadApi? _api;
  String? _token;
  bool _available = false;

  @override
  Stream<int> get orderTaps => _taps.stream;

  @override
  Future<void> init() => _initFuture ??= _init();

  Future<void> _init() async {
    if (kIsWeb) return;
    try {
      await Firebase.initializeApp();
    } catch (failure) {
      debugPrint('[naryad.push] firebase unavailable, push disabled: $failure');
      return;
    }
    try {
      FirebaseMessaging.onBackgroundMessage(naryadBackgroundMessageHandler);
    } catch (failure) {
      debugPrint('[naryad.push] background handler rejected: $failure');
    }
    try {
      final notifications = FlutterLocalNotificationsPlugin();
      await notifications.initialize(
        settings: naryadNotificationSettings,
        onDidReceiveNotificationResponse: _onLocalNotificationTap,
      );
      final android = notifications
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await android?.createNotificationChannel(naryadDefaultChannel);
      await android?.createNotificationChannel(naryadEmergencyChannel);
      _notifications = notifications;
    } catch (failure) {
      debugPrint('[naryad.push] local notifications unavailable: $failure');
    }
    try {
      final messaging = FirebaseMessaging.instance;
      _messaging = messaging;
      FirebaseMessaging.onMessage.listen(_onForegroundMessage);
      FirebaseMessaging.onMessageOpenedApp.listen(_onSystemTap);
      final initial = await messaging.getInitialMessage();
      if (initial != null) _onSystemTap(initial);
      messaging.onTokenRefresh.listen((token) {
        _token = token;
        final api = _api;
        if (api != null) {
          unawaited(_registerToken(api, token));
        }
      });
      _available = true;
    } catch (failure) {
      debugPrint('[naryad.push] messaging unavailable: $failure');
    }
  }

  @override
  Future<String?> requestToken() async {
    await init();
    if (!_available) return null;
    try {
      // On Android this covers the POST_NOTIFICATIONS prompt for API 33+.
      await _messaging!.requestPermission();
      final token = await _messaging!.getToken();
      if (token != null) _token = token;
      return _token;
    } catch (failure) {
      debugPrint('[naryad.push] token request failed: $failure');
      return null;
    }
  }

  @override
  Future<void> registerWith(NaryadApi api) async {
    _api = api;
    if (kIsWeb) return;
    try {
      final token = await requestToken();
      if (token == null) return;
      await _registerToken(api, token);
    } catch (failure) {
      debugPrint('[naryad.push] device registration failed: $failure');
    }
  }

  Future<void> _registerToken(NaryadApi api, String token) async {
    try {
      await api.registerDevice(token);
    } catch (failure) {
      debugPrint('[naryad.push] device registration failed: $failure');
    }
  }

  @override
  Future<void> unregister() async {
    final api = _api;
    final token = _token;
    _api = null;
    if (api == null || token == null || kIsWeb) return;
    try {
      await api.unregisterDevice(token);
    } catch (failure) {
      debugPrint('[naryad.push] device unregister failed: $failure');
    }
  }

  void _onForegroundMessage(RemoteMessage message) {
    final notification = message.notification;
    if (notification == null) return;
    final emergency = _isEmergency(message.data);
    unawaited(
      _showLocal(
        id: _displayIdOf(message),
        title: notification.title ?? 'НарядAI',
        body: notification.body ?? '',
        emergency: emergency,
        orderId: '${message.data['order_id'] ?? ''}',
      ),
    );
  }

  Future<void> _showLocal({
    required int id,
    required String title,
    required String body,
    required bool emergency,
    required String orderId,
  }) async {
    final notifications = _notifications;
    if (notifications == null) return;
    try {
      await notifications.show(
        id: id,
        title: title,
        body: body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            emergency
                ? kEmergencyNotificationChannelId
                : kDefaultNotificationChannelId,
            emergency ? 'Аварийные уведомления' : 'Основные уведомления',
            channelDescription: emergency
                ? 'Аварийные наряды, требующие немедленного ответа.'
                : 'Новые наряды и события смены.',
            importance: emergency ? Importance.max : Importance.high,
            priority: emergency ? Priority.high : Priority.defaultPriority,
            color: emergency ? kEmergencyNotificationColor : null,
            colorized: emergency,
            styleInformation: BigTextStyleInformation(
              body,
              contentTitle: title,
            ),
          ),
        ),
        payload: orderId,
      );
    } catch (failure) {
      debugPrint('[naryad.push] foreground display failed: $failure');
    }
  }

  void _onSystemTap(RemoteMessage message) {
    final orderId = _orderIdOf(message);
    if (orderId != null) _taps.add(orderId);
  }

  void _onLocalNotificationTap(NotificationResponse response) {
    final orderId = int.tryParse(response.payload ?? '');
    if (orderId != null && orderId > 0) _taps.add(orderId);
  }
}
