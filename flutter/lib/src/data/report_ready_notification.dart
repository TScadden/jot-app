import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_service.dart';

/// The report-ready notification (founder request, Nov 9, 2026):
/// a Progress Reports generation can run for minutes, and when it
/// finished while the user was away from the screen nothing told
/// them — the share dialog was simply waiting on their return.
/// The Progress Reports page posts this notification when a
/// generation completes while the user is not watching it; the
/// share confirmation itself is then presented when the user
/// comes back (page lifecycle / notification tap).
///
/// Modeled on [LocalMigraineNotifier] / the Daily Score ready
/// notifier: a foreground instance registers its tap handler with
/// the app-level [NotificationBootstrap], which owns the ONE
/// plugin.initialize; a posting-only instance never installs a
/// callback of its own.
///
/// PRIVACY (Juno ruling 2026-11-09, report-ready notification):
/// visibility private with NO public-version notification; the
/// title/body are EXACTLY Juno's ruled §0 strings — generic
/// across both report types, naming no file, no storage
/// location, no health content — and there is no detail-bearing
/// variant anywhere in this file, live or dormant. Adding any
/// health detail to notification text requires a NEW Juno
/// review. Posting NEVER requests the POST_NOTIFICATIONS
/// permission; it posts only when notifications are enabled, and
/// a failed post is silent (the report is already saved and the
/// share confirmation still waits for the user's return).
abstract class ReportReadyNotifier {
  Future<void> initialize();

  /// Posts the report-ready notification. Returns whether a
  /// notification is actually posted — false when notifications
  /// are disabled for the app or the post fails.
  Future<bool> showReportReady();
}

class LocalReportReadyNotifier implements ReportReadyNotifier {
  static const String channelId = 'report_ready';
  static const String channelName = 'Progress reports';
  static const String channelDescription =
      'Shows when a report you requested has finished generating.';
  static const int notificationId = 7304;
  static const String payload = 'report_ready';

  // Juno ruling 2026-11-09, §0: the ONE title and body, verbatim.
  // No placeholders anywhere — no filename, no report type, no
  // storage location, on any code path.
  static const String title = 'Your report is ready';
  static const String body = 'Tap to return to the report and share it.';

  static bool isReportReadyPayload(String? payload) =>
      payload == LocalReportReadyNotifier.payload;

  final FlutterLocalNotificationsPlugin _plugin;
  final void Function()? _onTap;
  bool _initialized = false;

  factory LocalReportReadyNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    void Function()? onTap,
  }) =>
      LocalReportReadyNotifier._(
        plugin ?? FlutterLocalNotificationsPlugin(),
        onTap,
      );

  LocalReportReadyNotifier._(this._plugin, this._onTap);

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Idempotent. Mirrors the migraine/score notifiers: an
  /// instance WITH [_onTap] is a foreground notifier — it
  /// registers the handler with [NotificationBootstrap] and joins
  /// its initialization; an instance WITHOUT one (posting-only)
  /// joins the bootstrap when one has started and otherwise
  /// initializes callback-less.
  @override
  Future<void> initialize() async {
    if (_initialized) return;
    final onTap = _onTap;
    if (onTap != null) {
      NotificationBootstrap.registerReportReadyTapHandler(onTap);
    }
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDescription,
        importance: Importance.defaultImportance,
      ),
    );
    if (onTap != null || NotificationBootstrap.initializationStarted) {
      await NotificationBootstrap.initialize(_plugin);
    } else {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
    }
    _initialized = true;
  }

  @override
  Future<bool> showReportReady() async {
    try {
      await initialize();
      final enabled = await _android?.areNotificationsEnabled() ?? false;
      if (!enabled) return false;
      await _plugin.show(
        notificationId,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            // Juno ruling: title and body are hidden on a secure
            // lock screen.
            visibility: NotificationVisibility.private,
            icon: '@mipmap/ic_launcher',
          ),
        ),
        payload: payload,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
