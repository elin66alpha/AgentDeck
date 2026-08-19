import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'browser_notifications.dart';

/// Wraps the OS notification tray so alerts (e.g. quota resets) surface as native
/// system notifications instead of cluttering the chat message list.
///
/// Only immediate notifications are used (`show`); there is no scheduling, so the
/// `timezone` setup that flutter_local_notifications needs for zoned schedules is
/// intentionally skipped. Uses [defaultTargetPlatform] rather than `dart:io` so
/// the import stays web-compile-safe for the future Web shell.
class NotificationService {
  NotificationService._();

  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  bool _available = false;
  int _nextId = 0;

  static const String _channelId = 'quota_alerts';
  static const String _channelName = 'Quota alerts';
  static const String _channelDescription =
      'CLI agent quota resets and usage warnings';

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS ||
          defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  /// Initialise the plugin and (on Android) create the notification channel.
  /// Safe to call repeatedly and on unsupported platforms.
  Future<void> init() async {
    if (_initialized || !_supported) {
      _initialized = true;
      return;
    }
    try {
      const AndroidInitializationSettings android =
          AndroidInitializationSettings('@mipmap/ic_launcher');
      const DarwinInitializationSettings darwin = DarwinInitializationSettings(
        requestAlertPermission: false,
        requestBadgePermission: false,
        requestSoundPermission: false,
      );
      const WindowsInitializationSettings windows =
          WindowsInitializationSettings(
        appName: 'Relay',
        appUserModelId: 'Dev.Relay.App',
        guid: 'f9cc24b7-4b94-4a0f-a7bb-0f91d2cf3a55',
      );
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: android,
          iOS: darwin,
          macOS: darwin,
          windows: windows,
        ),
      );
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(
            const AndroidNotificationChannel(
              _channelId,
              _channelName,
              description: _channelDescription,
              importance: Importance.high,
            ),
          );
      _available = true;
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'relay notifications',
          context: ErrorDescription('initializing local notifications'),
        ),
      );
      _available = false;
    } finally {
      _initialized = true;
    }
  }

  /// Ask the user for notification permission (Android 13+ / iOS / macOS).
  Future<void> requestPermission() async {
    if (kIsWeb) {
      await requestBrowserNotificationPermission();
      return;
    }
    if (!_supported) return;
    await init();
    if (!_available) return;
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } else if (defaultTargetPlatform == TargetPlatform.macOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } else {
      // Windows toast notifications do not use the iOS/macOS permission API.
    }
  }

  /// Show an immediate system notification. Returns false when unsupported or
  /// denied so callers can show an in-page fallback.
  ///
  /// [tag] identifies the alert rather than this particular showing of it. Two
  /// notifications sharing a tag replace one another instead of stacking, so an
  /// alert that reaches the device twice (say over the event stream and again
  /// as a push) is only ever seen once. Untagged notifications always stack.
  Future<bool> show({
    required String title,
    required String body,
    String? tag,
  }) async {
    if (kIsWeb) {
      return showBrowserNotification(title: title, body: body, tag: tag);
    }
    if (!_supported) return false;
    await init();
    if (!_available) return false;
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
    );
    const DarwinNotificationDetails darwinDetails = DarwinNotificationDetails();
    const WindowsNotificationDetails windowsDetails =
        WindowsNotificationDetails();
    try {
      await _plugin.show(
        id: tag == null ? _nextId++ : _idForTag(tag),
        title: title,
        body: body,
        notificationDetails: const NotificationDetails(
          android: androidDetails,
          iOS: darwinDetails,
          macOS: darwinDetails,
          windows: windowsDetails,
        ),
      );
      return true;
    } catch (error, stackTrace) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'relay notifications',
          context: ErrorDescription('showing local notification'),
        ),
      );
      return false;
    }
  }

  /// A stable, non-negative 31-bit id for a tag. The platform plugins key
  /// replacement off this id, so it has to depend only on the tag — a counter
  /// would make every repeat a new notification.
  int _idForTag(String tag) {
    int hash = 0;
    for (final int unit in tag.codeUnits) {
      hash = (hash * 31 + unit) & 0x3fffffff;
    }
    return hash;
  }
}
