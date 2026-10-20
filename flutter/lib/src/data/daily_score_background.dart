// Daily Score background snapshot + scoring (founder amendment #2,
// Oct 20, 2026): "I think we make it so that it can just do it in the
// background. And then send a notification when the score is updated."
//
// ─────────────────────────────────────────────────────────────────────
// DESIGN
//
// A periodic WorkManager task (platform-deferred, Doze-aware — NOT
// clockwork) runs [DailyScoreBackgroundRunner] a few times a day in a
// headless background isolate, with the app never opened:
//
// 1. GRANT GATE. Background Health Connect reads are a SEPARATE grant
//    (READ_HEALTH_DATA_IN_BACKGROUND), given in Health Connect
//    settings, never in the runtime permission request set
//    (HealthConnectService.requiredPermissions excludes it — team
//    rule). When the grant is KNOWN absent, the pipeline is OFF:
//    no capture, no scoring, no notification, no error surface —
//    foreground behavior is untouched.
// 2. SNAPSHOT. With the grant present, the runner runs the SHARED
//    capture NON-forced: the 6h throttle stamp lives in the history
//    store, so foreground and background captures share it and never
//    double-run. The capture's own post-capture engine run carries
//    the Amendment-#1 gate (today scores only when complete).
// 3. PAST-DAY FALLBACK. When the capture does not run (throttled
//    out, failed, or the HC channel unreachable from this isolate),
//    the runner may still score PAST days only (beforeDate: today)
//    from current store state — this is what lets a CSV import that
//    filled the store outside any capture produce its scores in the
//    background. It NEVER scores today without a snapshot that ran.
// 4. NOTIFICATION. If the run created any scores, exactly ONE
//    notification is posted, for the MOST RECENT newly scored day
//    (Otto's one-per-run ruling — no catch-up floods). An existing
//    score is never re-notified; the foreground refresh button path
//    has no notifier at all, so a manual refresh never notifies.
//
// ─────────────────────────────────────────────────────────────────────
// THE CHANNEL REALITY (read before assuming background reads work)
//
// The Health Connect MethodChannel handlers are registered in
// MainActivity.configureFlutterEngine — for the MAIN engine only.
// WorkManager's background engine registers the pub plugins (secure
// storage, local notifications) via GeneratedPluginRegistrant, but
// NOT this app-defined channel: HC calls from the background isolate
// fail with NO_CHANNEL. The runner therefore PROBES availability
// first and treats an unreachable channel exactly like a throttled
// capture (past-day fallback from store state; NO capture attempt,
// so the shared throttle is never poisoned by a capture that could
// not read). Store-only past-day scoring, the diff, and the
// notification all work end-to-end today; background TODAY scoring
// activates automatically the moment the HC bridge is registered on
// the background engine (a FlutterPlugin extraction of the
// MainActivity bridge — tracked as follow-up native work; it is NOT
// claimed working on a device by this package).
//
// Battery honesty: periodic WorkManager work is opportunistic.
// With an 8h requested period, Android may batch or defer runs
// under Doze/app standby; "a few times a day" is the design intent,
// not a schedule guarantee. No exact alarms, no wake locks.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import 'daily_score.dart';
import 'health_connect_service.dart';
import 'health_history_store.dart';
import 'health_history_sync.dart';

/// yyyy-MM-dd in local time — the store's date format (same shape
/// as health_history_sync's private formatter).
String _dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Workmanager registration + the background isolate entry point.
class DailyScoreBackgroundScheduler {
  static const String uniqueName = 'tabs-daily-score-background';
  static const String taskName = 'dailyScoreSnapshotAndScore';

  /// Nominal cadence: every 8 hours ("a few times a day"). See the
  /// battery-honesty note in the file header — actual runs are
  /// platform-deferred.
  static const Duration period = Duration(hours: 8);

  /// Registers the periodic task (foreground call; `keep` policy
  /// makes repeat calls across launches a no-op). Best-effort and
  /// silent: background scoring is an enhancement, and a scheduling
  /// failure must never surface in the foreground. Returns whether
  /// registration was issued without an error.
  static Future<bool> register() async {
    try {
      await Workmanager().initialize(dailyScoreBackgroundDispatcher);
      await Workmanager().registerPeriodicTask(
        uniqueName,
        taskName,
        frequency: period,
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// The workmanager callback dispatcher. Top-level + vm:entry-point
/// so the background isolate can resolve it through the callback
/// cache; it must stay a tear-off of THIS function (passed to
/// [DailyScoreBackgroundScheduler.register]).
@pragma('vm:entry-point')
void dailyScoreBackgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (task == DailyScoreBackgroundScheduler.taskName) {
      await DailyScoreBackgroundRunner.production().run();
    }
    return true;
  });
}

/// What one background run did — returned for tests and diagnostics;
/// the runner never throws, so a failed run is a value, not an error.
class DailyScoreBackgroundOutcome {
  /// Background grant state as far as this run could determine it.
  final bool? grantPresent;

  /// Whether the HC channel answered the availability probe from
  /// this isolate (false = background engine has no HC handlers;
  /// see the header's channel reality note).
  final bool channelAvailable;

  /// Whether a capture was attempted, and whether it ran (a false
  /// return means throttled or failed — either way the past-day
  /// fallback ran instead).
  final bool captureAttempted;
  final bool captureRan;

  /// Days whose scores THIS run created, ascending.
  final List<String> newlyScoredDates;

  /// The day the single notification named, when one was posted.
  final String? notifiedDate;

  /// Why the run stopped early, when it did: 'grant-absent' or
  /// 'error'. Null for a full run.
  final String? skippedReason;

  const DailyScoreBackgroundOutcome({
    this.grantPresent,
    this.channelAvailable = false,
    this.captureAttempted = false,
    this.captureRan = false,
    this.newlyScoredDates = const [],
    this.notifiedDate,
    this.skippedReason,
  });
}

/// Posts the "your Daily Score is ready" notification. Abstract so
/// tests can record calls without the platform plugin.
abstract class DailyScoreReadyNotifier {
  Future<void> showScoreReady(String date, {int? score});
}

/// The production notifier (flutter_local_notifications).
///
/// PRIVACY DEFAULT (Juno rules on the final wording): the score
/// NUMBER is not in the notification text — lock-screen visible
/// text says a score is ready and names the day; the number is
/// tap-to-view in the app. Including the number is a one-line
/// change: flip [includeScoreInBody] (the score is already plumbed
/// into [showScoreReady]).
class LocalDailyScoreReadyNotifier implements DailyScoreReadyNotifier {
  static const String channelId = 'daily_score_ready';
  static const String channelName = 'Daily Score';
  static const int notificationId = 7301;
  static const bool includeScoreInBody = false;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  final FlutterLocalNotificationsPlugin _plugin;
  final void Function(String date)? _onTap;
  bool _initialized = false;

  factory LocalDailyScoreReadyNotifier({
    FlutterLocalNotificationsPlugin? plugin,
    void Function(String date)? onTap,
  }) =>
      LocalDailyScoreReadyNotifier._(
        plugin ?? FlutterLocalNotificationsPlugin(),
        onTap,
      );

  LocalDailyScoreReadyNotifier._(this._plugin, this._onTap);

  /// A score notification's payload is exactly its date
  /// (yyyy-MM-dd) — anything else is not ours.
  static bool isScorePayload(String? payload) =>
      payload != null &&
      RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(payload);

  static String friendlyDate(String date) {
    final parsed = DateTime.tryParse(date);
    if (parsed == null) return date;
    return '${_months[parsed.month - 1]} ${parsed.day}';
  }

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  /// Idempotent. In the foreground, pass [onTap] at construction to
  /// receive score-notification taps; the background isolate
  /// constructs without one (it only posts).
  Future<void> initialize() async {
    if (_initialized) return;
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: 'Lets you know when a new Daily Score is ready.',
        importance: Importance.defaultImportance,
      ),
    );
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (isScorePayload(payload)) _onTap?.call(payload!);
      },
    );
    _initialized = true;
  }

  /// The score payload the app was LAUNCHED with (terminated-state
  /// tap), or null. Foreground routing consumes this once at start.
  Future<String?> launchScorePayload() async {
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      if (details?.didNotificationLaunchApp != true) return null;
      final payload = details?.notificationResponse?.payload;
      return isScorePayload(payload) ? payload : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> showScoreReady(String date, {int? score}) async {
    await initialize();
    final body = includeScoreInBody && score != null
        ? 'Your Daily Score for ${friendlyDate(date)} is $score. Tap to see it.'
        : 'Tap to see your Daily Score for ${friendlyDate(date)}.';
    await _plugin.show(
      notificationId,
      'Your Daily Score is ready',
      body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription:
              'Lets you know when a new Daily Score is ready.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
        ),
      ),
      payload: date,
    );
  }
}

/// One background snapshot + scoring run. All dependencies are
/// injectable; [DailyScoreBackgroundRunner.production] wires the
/// real store / sync / service singletons of whichever isolate it
/// runs in (background isolates get their own instances over the
/// SAME persisted store, which is what shares the capture throttle).
class DailyScoreBackgroundRunner {
  final HealthHistoryStore _store;
  final Future<bool> Function() _hasBackgroundAccess;
  final Future<bool> Function() _probeChannel;
  final Future<bool> Function() _runCapture;
  final Future<int> Function(String beforeDate) _scorePastDays;
  final DailyScoreReadyNotifier _notifier;
  final DateTime Function() _now;

  factory DailyScoreBackgroundRunner({
    required HealthHistoryStore store,
    required Future<bool> Function() hasBackgroundAccess,
    required Future<bool> Function() probeChannel,
    required Future<bool> Function() runCapture,
    required Future<int> Function(String beforeDate) scorePastDays,
    required DailyScoreReadyNotifier notifier,
    DateTime Function()? now,
  }) =>
      DailyScoreBackgroundRunner._(
        store,
        hasBackgroundAccess,
        probeChannel,
        runCapture,
        scorePastDays,
        notifier,
        now ?? DateTime.now,
      );

  DailyScoreBackgroundRunner._(
    this._store,
    this._hasBackgroundAccess,
    this._probeChannel,
    this._runCapture,
    this._scorePastDays,
    this._notifier,
    this._now,
  );

  factory DailyScoreBackgroundRunner.production() {
    final store = HealthHistoryStore.instance;
    final hc = HealthConnectService();
    final sync = HealthHistorySync.instance;
    return DailyScoreBackgroundRunner(
      store: store,
      hasBackgroundAccess: hc.hasBackgroundAccess,
      probeChannel: () async {
        try {
          return await hc.isAvailable();
        } catch (_) {
          return false;
        }
      },
      runCapture: () => sync.capture(),
      scorePastDays: (beforeDate) => DailyScoreEngine(store: store)
          .computeMissingScores(beforeDate: beforeDate),
      notifier: LocalDailyScoreReadyNotifier(),
    );
  }

  Future<Set<String>> _scoredDates() async {
    final days = await _store.readAll();
    return {
      for (final e in days.entries)
        if (e.value.dailyScore != null) e.key,
    };
  }

  /// Runs the pipeline once. Never throws: background work fails
  /// silently by design (no nagging, no error states — the founder
  ///-facing surfaces stay foreground).
  Future<DailyScoreBackgroundOutcome> run() async {
    try {
      await _store.warmFromDisk();
      // An empty store (fresh install, post-logout) is NOT an
      // early exit: the first-ever capture is exactly what fills
      // it, and every other path over an empty store is a no-op.
      final before = await _scoredDates();

      // Channel probe FIRST: it decides what the grant answer can
      // mean. With no channel (today's background-engine reality)
      // the grant is UNKNOWABLE — and the store-only fallback below
      // reads no Health Connect data at all, so it does not exercise
      // the background read grant and may proceed. With a channel,
      // a known-absent grant turns the whole pipeline off.
      final channelAvailable = await _probeChannel();
      bool? grant;
      if (channelAvailable) {
        try {
          grant = await _hasBackgroundAccess();
        } catch (_) {
          grant = null; // unknowable — same treatment as no channel
        }
        if (grant == false) {
          return DailyScoreBackgroundOutcome(
            grantPresent: false,
            channelAvailable: true,
            skippedReason: 'grant-absent',
          );
        }
      }

      final today = _dateStr(_now());
      var captureAttempted = false;
      var captureRan = false;
      if (channelAvailable) {
        captureAttempted = true;
        captureRan = await _runCapture();
        if (!captureRan) {
          // Throttled (shared stamp) or failed: past days may still
          // score from store state; today may NOT (no snapshot ran).
          await _scorePastDays(today);
        }
        // captureRan: the capture's own post-capture run already
        // applied the gate (today) + fallback (past days).
      } else {
        await _scorePastDays(today);
      }

      final after = await _scoredDates();
      final newly = after.difference(before).toList()..sort();
      String? notifiedDate;
      if (newly.isNotEmpty) {
        notifiedDate = newly.last; // one notification, most recent
        final days = await _store.readAll();
        await _notifier.showScoreReady(
          notifiedDate,
          score: days[notifiedDate]?.dailyScore,
        );
      }
      return DailyScoreBackgroundOutcome(
        grantPresent: grant,
        channelAvailable: channelAvailable,
        captureAttempted: captureAttempted,
        captureRan: captureRan,
        newlyScoredDates: newly,
        notifiedDate: notifiedDate,
      );
    } catch (_) {
      return const DailyScoreBackgroundOutcome(skippedReason: 'error');
    }
  }
}
