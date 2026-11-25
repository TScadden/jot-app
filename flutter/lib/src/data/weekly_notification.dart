import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_service.dart';

/// The automatic Weekly Report notification — Package 2 (Team
/// Session #2 decision, 2026-11-09; Juno ruling 2026-11-19,
/// JUNO-RULING.md §c rows 2.1–2.4 + §d Flag 5).
///
/// This is the notification for an UNREQUESTED report: the weekly
/// automation generates it on the Sunday 21:00 first-open trigger
/// and — only when the completeness bar passes — posts exactly
/// this notification. It is modeled on PR #55's
/// [LocalReportReadyNotifier] machinery (same initialize pattern:
/// the channel is created here, plugin initialization joins the
/// app-level [NotificationBootstrap], posting never requests the
/// POST_NOTIFICATIONS permission, a failed post is silent), but
/// it posts ONLY on its own channel:
///
/// - The `report_ready` channel's description and its
///   title/body describe a REQUESTED report (see
///   report_ready_notification.dart for those strings). Using
///   any of them for this unrequested send would be false
///   (Juno §d Flag 5 — channel separation is a truth issue, not
///   a naming preference), so none of those strings appear here.
///
/// PRIVACY (Juno §c, banned constructions): title/body are
/// EXACTLY Juno's ruled rows 2.3–2.4 — no health content of any
/// kind (no scores, no sleep figures, no section names), and the
/// visibility is private, so both are hidden on a secure lock
/// screen. Bearable's health-change sentence (quoted in the
/// Session #2 decision record) and any paraphrase of it are
/// banned anywhere in this package; there is deliberately no
/// other title/body variant in this file, live or dormant.
abstract class WeeklyNotifier {
  Future<void> initialize();

  /// Posts the weekly-report-ready notification on the
  /// `Weekly reports` channel. Returns whether a notification
  /// was actually posted — false when notifications are disabled
  /// for the app or the post fails. The caller (the automation)
  /// invokes this ONLY when the completeness bar passes; blocked
  /// and low-data weeks never reach this method.
  Future<bool> showWeeklyReady();
}

class LocalWeeklyNotifier implements WeeklyNotifier {
  static const String channelId = 'weekly_reports';
  static const String channelName = 'Weekly reports';
  static const String channelDescription =
      'Shows when your automatic weekly report has finished generating.';

  /// Disjoint from every other notification id owner in the app
  /// (verified by grep over lib/): 7301 Daily Score, 7303
  /// migraine, 7304 report-ready, 770001 check-in, 770002
  /// appointment, 1003 habit, 1004 project, the event-counter
  /// block 700000–799998 and the projected blocks 800000+.
  static const int notificationId = 7305;
  static const String payload = 'weekly_report';

  // Juno ruling 2026-11-19, §c rows 2.3–2.4: the ONE title and
  // body, verbatim. No placeholders anywhere — no week, no
  // score, no health content, on any code path.
  static const String title = 'Your weekly report is ready';
  static const String body = 'Tap to open Tabs to view it.';

  static bool isWeeklyPayload(String? payload) =>
      payload == LocalWeeklyNotifier.payload;

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  factory LocalWeeklyNotifier({
    FlutterLocalNotificationsPlugin? plugin,
  }) =>
      LocalWeeklyNotifier._(
        plugin ?? FlutterLocalNotificationsPlugin(),
      );

  LocalWeeklyNotifier._(this._plugin);

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Idempotent. Mirrors [LocalReportReadyNotifier.initialize]:
  /// the `Weekly reports` channel is created here (Android
  /// channels are user-muteable in system settings once created,
  /// and default-importance channels are ON by default — Juno:
  /// default ON for Premium, independently muteable; this
  /// notifier is only ever invoked on the Premium automation
  /// path, so the channel is never created for a free user),
  /// and plugin initialization joins the app-level bootstrap
  /// when one has started, otherwise initializes callback-less
  /// (a posting-only instance installs no callback of its own —
  /// a weekly tap simply foregrounds the app, where the report
  /// waits in the archive; there is no held share to present).
  @override
  Future<void> initialize() async {
    if (_initialized) return;
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDescription,
        importance: Importance.defaultImportance,
      ),
    );
    if (NotificationBootstrap.initializationStarted) {
      await NotificationBootstrap.initialize(_plugin);
    } else {
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('ic_stat_tabs'),
        ),
      );
    }
    _initialized = true;
  }

  @override
  Future<bool> showWeeklyReady() async {
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
            // Juno §c: title and body are hidden on a secure
            // lock screen (no health content exists to leak, and
            // the visibility stays private per the PR #55
            // precedent).
            visibility: NotificationVisibility.private,
            icon: 'ic_stat_tabs',
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
