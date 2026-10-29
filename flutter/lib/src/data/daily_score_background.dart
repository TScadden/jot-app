// Daily Score background snapshot + scoring (founder amendment #2,
// Oct 20, 2026): "I think we make it so that it can just do it in the
// background. And then send a notification when the score is updated."
//
// ─────────────────────────────────────────────────────────────────────
// DESIGN
//
// A periodic WorkManager task (platform-deferred, Doze-aware — NOT
// clockwork; a 30-minute period is REQUESTED, founder directive,
// Oct 22, 2026) runs [DailyScoreBackgroundRunner] in a headless
// background isolate, with the app never opened:
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
//    JUNO RULING (Oct 22, 2026, C1/C2/F2): the 30-minute wake
//    cadence does NOT relax this — background-originated captures
//    stay non-forced under the shared 6h throttle (the app-open
//    throttle bypass is foreground-only and is never borrowed
//    here), so between captures the wakes do only the probe, this
//    throttled invocation, the past-day fallback (3), and the
//    notification logic (4).
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
//    MF-9 GRANT GATE (Juno, correction round): the notification
//    additionally requires a VERIFIED granted state. When the
//    grant cannot be verified (channel unavailable, or the grant
//    read failed), the run may still compute scores from
//    already-stored data but posts NO notification.
//
// ─────────────────────────────────────────────────────────────────────
// THE CHANNEL REALITY (corrected Oct 22, 2026 — the NO_CHANNEL
// account this section used to carry is stale at this head)
//
// The Health Connect MethodChannel handlers now live in
// HealthConnectBridgePlugin (local plugin package
// flutter/plugins/health_connect_bridge): its onAttachedToEngine
// registers the channel on EVERY FlutterEngine in the process, and
// GeneratedPluginRegistrant registers the plugin on the WorkManager
// background engine as well as the main engine (see the plugin's
// header and flutter/pubspec.yaml's dependency note). HC calls
// from the background isolate therefore have a registered handler
// at this head. The runner STILL PROBES availability first and
// treats an unreachable channel exactly like a throttled capture
// (past-day fallback from store state; NO capture attempt, so the
// shared throttle is never poisoned by a capture that could not
// read) — the probe remains the guard for any engine where the
// handler does not answer. This is a documentation correction
// only: no background read behavior changed with it.
//
// Battery honesty: periodic WorkManager work is opportunistic.
// A 30-minute period is REQUESTED (founder directive, Oct 22,
// 2026); Android may batch or defer runs under Doze/app standby,
// so actual wakes may be far less frequent — the requested period
// is not a schedule guarantee and no run is promised every
// 30 minutes. No exact alarms, no wake locks.

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';

import 'correlation_refresh.dart';
import 'daily_score.dart';
import 'daily_score_sync.dart';
import 'health_connect_service.dart';
import 'health_history_store.dart';
import 'health_history_sync.dart';
import 'notification_service.dart';

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

  /// Requested cadence: every 30 minutes (founder directive,
  /// Oct 22, 2026). This is the period REQUESTED from the
  /// platform — see the battery-honesty note in the file header:
  /// actual runs are platform-deferred and are NOT guaranteed
  /// every 30 minutes.
  static const Duration period = Duration(minutes: 30);

  // Injectable bridge (unit tests): replaces the Workmanager
  // plugin calls so the requested frequency + existing-work
  // policy can be verified without a platform. Null in production.
  static Future<void> Function()? _initializeOverride;
  static Future<void> Function(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
  })? _registerPeriodicOverride;

  @visibleForTesting
  static void debugSetWorkmanagerBridge({
    required Future<void> Function() initialize,
    required Future<void> Function(
      String uniqueName,
      String taskName, {
      Duration? frequency,
      ExistingPeriodicWorkPolicy? existingWorkPolicy,
    }) registerPeriodic,
  }) {
    _initializeOverride = initialize;
    _registerPeriodicOverride = registerPeriodic;
  }

  @visibleForTesting
  static void debugResetWorkmanagerBridge() {
    _initializeOverride = null;
    _registerPeriodicOverride = null;
  }

  /// Registers the periodic task (foreground call). The policy is
  /// `update` (Juno ruling, Oct 22, 2026, C6 — migration-critical):
  /// repeat registrations REPLACE the existing schedule, so the
  /// 30-minute period supersedes the previously registered 8-hour
  /// schedule on existing installs; the old `keep` policy made
  /// repeat registrations no-ops and would have retained the 8h
  /// schedule forever. `ExistingPeriodicWorkPolicy.update` is
  /// offered by the workmanager version resolved in this tree
  /// (workmanager 0.10.10 / platform interface 0.10.5, per
  /// pubspec.lock). Best-effort and silent: background scoring is
  /// an enhancement, and a scheduling failure must never surface
  /// in the foreground. Returns whether registration was issued
  /// without an error.
  static Future<bool> register() async {
    try {
      final initializeOverride = _initializeOverride;
      if (initializeOverride != null) {
        await initializeOverride();
      } else {
        await Workmanager().initialize(dailyScoreBackgroundDispatcher);
      }
      final registerOverride = _registerPeriodicOverride;
      if (registerOverride != null) {
        await registerOverride(
          uniqueName,
          taskName,
          frequency: period,
          existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        );
      } else {
        await Workmanager().registerPeriodicTask(
          uniqueName,
          taskName,
          frequency: period,
          existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
        );
      }
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
      // Phase 1, item 5 (spec §6): the correlation refresh
      // piggybacks on this completion — after capture/scoring
      // settle — never on a new timer and never on screen open.
      // Failure-guarded: a correlation failure must never fail
      // the background task.
      try {
        await CorrelationRefresher.production().refreshIfStale();
      } catch (_) {}
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
/// PRIVACY (Juno Ruling 1, correction round): the score NUMBER is
/// never in the notification text — the notification is
/// tap-to-view only (the title plus "Tap to see your Daily Score
/// for {day}."). There is deliberately NO number-bearing body
/// variant in this class: a built number path must not ship as
/// one-flip dead code, so including the score in notification
/// text requires a NEW Juno review before any such code is
/// written. The Android notification visibility is private, so
/// the body is hidden on a secure lock screen.
class LocalDailyScoreReadyNotifier implements DailyScoreReadyNotifier {
  static const String channelId = 'daily_score_ready';
  static const String channelName = 'Daily Score';
  static const int notificationId = 7301;

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
  ///
  /// Tap routing (V-1 correction, delta-2): the notifier does
  /// NOT install its own plugin response callback in the
  /// foreground — the app-level [NotificationBootstrap] owns
  /// plugin.initialize with the one dispatching callback, and this
  /// initialize only REGISTERS [_onTap] as the score-payload
  /// handler with it.
  ///
  /// The branch discriminates on this isolate's ROLE, which the
  /// construction already encodes: a notifier WITH [_onTap] is a
  /// foreground notifier, so it ALWAYS starts/joins the bootstrap
  /// — even when no bootstrap attempt is currently recorded (a
  /// previous bootstrap attempt that failed fast clears the
  /// bootstrap's in-flight guard, and taking the callback-less
  /// branch then would leave the whole session with no
  /// dispatching callback). The callback-less own-initialize is
  /// reserved strictly for a notifier WITHOUT [_onTap] — the
  /// background posting isolate, which only posts — and only
  /// when no bootstrap has started in this isolate; a no-callback
  /// notifier that finds a bootstrap in flight still joins it
  /// rather than wiping its callback.
  Future<void> initialize() async {
    if (_initialized) return;
    final onTap = _onTap;
    if (onTap != null) {
      NotificationBootstrap.registerScoreTapHandler(onTap);
    }
    await _android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: 'Lets you know when a new Daily Score is ready.',
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
    // Tap-to-view only (Juno Ruling 1): the score number never
    // appears in notification text — [score] remains in the
    // interface for the runner's call and is intentionally not
    // rendered here. See the class doc before changing this.
    await _plugin.show(
      notificationId,
      'Your Daily Score is ready',
      'Tap to see your Daily Score for ${friendlyDate(date)}.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription:
              'Lets you know when a new Daily Score is ready.',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          // Juno hardening: the body is hidden on a secure lock
          // screen.
          visibility: NotificationVisibility.private,
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
      // Juno ruling (Oct 22, 2026, C1/C2/F2): deliberately the
      // PLAIN capture — non-forced and governed by the shared 6h
      // throttle. The background runner never calls the app-open
      // bypass (captureOnAppOpen) and never forces.
      runCapture: () => sync.capture(),
      // Daily Score server sync (Oct 28, 2026): past-day scores
      // computed in the background queue for upload exactly like
      // foreground ones. The queue is durable + owner-stamped, so
      // a background-computed record simply waits there for the
      // next flush trigger whose POST can land.
      scorePastDays: (beforeDate) =>
          DailyScoreEngine(store: store, scoreSync: DailyScoreSync.instance)
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
      // MF-9: notify ONLY on a verified granted state. `grant`
      // is true only when the channel answered AND the grant read
      // returned granted; it is null whenever the grant could not
      // be verified (no channel, or the read threw) — the scores
      // above still stand, but no notification is posted.
      if (newly.isNotEmpty && grant == true) {
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
