import 'browser_notifications_stub.dart'
    if (dart.library.html) 'browser_notifications_web.dart' as platform;

Future<void> requestBrowserNotificationPermission() =>
    platform.requestBrowserNotificationPermission();

/// [tag] groups repeats of the same alert. The browser replaces a notification
/// that carries a tag it is already showing, so an alert that also arrives via
/// the push service worker (which tags its own notifications) collapses into a
/// single visible notification instead of stacking.
Future<bool> showBrowserNotification({
  required String title,
  required String body,
  String? tag,
}) =>
    platform.showBrowserNotification(title: title, body: body, tag: tag);
