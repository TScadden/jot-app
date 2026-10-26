import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'migraine_time_format.dart';
import 'notification_service.dart';

/// The ongoing migraine-timer notification (Juno ruling 2026-10-26
/// §B). Modeled on [LocalDailyScoreReadyNotifier]: same initialize
/// pattern (foreground instances register their tap handler with the
/// app-level [NotificationBootstrap], which owns the ONE
/// plugin.initialize; the posting-only branch never installs a
/// callback of its own).
///
/// PRIVACY (Juno condition 1): visibility private; title/body are
/// EXACTLY Juno's template — the elapsed time is the only variable,
/// and there is deliberately NO detail-bearing variant anywhere in
/// this file (no pain, meds, aura, or pressure in any code path,
/// live or dormant). Adding any health detail to notification text
/// requires a NEW Juno review.
///
/// Behavior: ongoing (not swipe-dismissible), silent — no sound, no
/// vibration, low importance so it never heads-up on post or on
/// elapsed updates. Tap payload is the constant [payload]; the tap
/// ENDS the attack first and opens the details form second (the
/// controller owns that ordering).
abstract class MigraineNotifier {
  Future<void> initialize();

  /// Posts (or refreshes) the ongoing notification for an attack
  /// that has been running [elapsedMin] minutes. Returns whether a
  /// notification is actually posted — false when notifications are
  /// disabled for the app or the post fails. NEVER requests the
  /// POST_NOTIFICATIONS permission (Juno §F: starting an attack
  /// never fires a system prompt).
  Future<bool> showAttack(int elapsedMin);

  Future<void> cancel();

  /// Whether the system currently allows this app's notifications,
  /// without requesting anything.
  Future<bool> areNotificationsEnabled();

  /// The migraine payload the app was LAUNCHED with (terminated-state
  /// tap), or null — the cold-start equivalent of
  /// `LocalDailyScoreReadyNotifier.launchScorePayload`.
  Future<bool> launchMigrainePayload();
}

class LocalMigraineNotifier implements MigraineNotifier {
  static const String channelId = 'migraine_attack';
  static const String channelName = 'Migraine attack';
  static const String channelDescription =
      'Shows while a migraine attack is being timed. Tap the notification to end the attack.';
  static const int notificationId = 7303;
  static const String payload = 'migraine_attack';
  static const String title = 'Migraine attack in progress';

  /// Juno §B body template: `{elapsed} so far. Tap to end the attack.`
  /// with the Lab elapsed format. This is the ONLY body builder.
  static String bodyForElapsed(int elapsedMin) =>
      '${formatElapsedDuration(elapsedMin)} so far. Tap to end the attack.';

  static bool isMigrainePayload(String? payload) => payload == LocalMigraineNotifier.payload;

  final FlutterLocalNotificationsPlugin _plugin;
  final void Function()? _onTap;
  bool _initialized = false;

  factory LocalMigraineNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    void Function()? onTap,
  }) =>
      LocalMigraineNotifier._(
        plugin ?? FlutterLocalNotificationsPlugin(),
        onTap,
      );

  LocalMigraineNotifier._(this._plugin, this._onTap);

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Idempotent. Mirrors [LocalDailyScoreReadyNotifier.initialize]:
  /// a notifier WITH [_onTap] is a foreground notifier — it
  /// registers the handler with [NotificationBootstrap] and joins
  /// its initialization; a notifier WITHOUT one (posting-only) joins
  /// the bootstrap when one has started and otherwise initializes
  /// callback-less, exactly like the score notifier.
  @override
  Future<void> initialize() async {
    if (_initialized) return;
    final onTap = _onTap;
    if (onTap != null) {
      NotificationBootstrap.registerMigraineTapHandler(onTap);
    }
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDescription,
        importance: Importance.low,
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
  Future<bool> areNotificationsEnabled() async {
    try {
      await initialize();
      return await _android?.areNotificationsEnabled() ?? false;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> showAttack(int elapsedMin) async {
    try {
      await initialize();
      final enabled = await _android?.areNotificationsEnabled() ?? false;
      if (!enabled) return false;
      await _plugin.show(
        notificationId,
        title,
        bodyForElapsed(elapsedMin),
        const NotificationDetails(
          android: AndroidNotificationDetails(
            channelId,
            channelName,
            channelDescription: channelDescription,
            importance: Importance.low,
            priority: Priority.low,
            // Juno §B: private — title and body hidden on a secure
            // lock screen.
            visibility: NotificationVisibility.private,
            ongoing: true,
            autoCancel: false,
            playSound: false,
            enableVibration: false,
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

  @override
  Future<void> cancel() async {
    try {
      await initialize();
      await _plugin.cancel(notificationId);
    } catch (_) {
      // Best-effort: a failed cancel must never block an end path.
    }
  }

  @override
  Future<bool> launchMigrainePayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return false;
      return isMigrainePayload(details?.notificationResponse?.payload);
    } catch (_) {
      return false;
    }
  }
}
