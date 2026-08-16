import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void> requestBrowserNotificationPermission() async {
  try {
    if (web.Notification.permission == 'default') {
      await web.Notification.requestPermission().toDart;
    }
  } catch (_) {
    // Browsers can disable this API or require a user gesture.
  }
}

Future<bool> showBrowserNotification({
  required String title,
  required String body,
  String? tag,
}) async {
  try {
    if (web.Notification.permission == 'default') {
      await requestBrowserNotificationPermission();
    }
    if (web.Notification.permission != 'granted') return false;
    web.Notification(
      title,
      tag == null
          ? web.NotificationOptions(body: body)
          : web.NotificationOptions(body: body, tag: tag),
    );
    return true;
  } catch (_) {
    return false;
  }
}
