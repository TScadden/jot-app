import 'package:flutter/foundation.dart';

import 'health_connect_service.dart';
import 'health_history_store.dart';
import 'session_store.dart';
import 'tabs_backend.dart';
import 'weekly_automation.dart';
import 'weekly_generation_claim.dart';
import 'weekly_notification.dart';
import 'weekly_production.dart';
import 'weekly_report.dart';

/// Weekly Report background generation (Background Generation
/// package, 2026-11-24) — the page-free runner the existing
/// WorkManager dispatcher piggybacks (see
/// daily_score_background.dart; the CorrelationRefresher
/// precedent). NO new task registration, NO exact alarms: each
/// wake of the existing 30-minute periodic task re-projects
/// [weeklyDueWeek] and the first wake after Sunday 21:00 local
/// generates the just-closed Mon–Sun week. First-open generation
/// remains the permanent fallback, untouched.
///
/// Run order (recon + Vera ruling):
/// 1. Resolve the stored session email FIRST; warm the history
///    store owner-bound; owner unverified ⇒ abort, write nothing
///    (the H1-04 discipline — the Daily Score runner's
///    SessionStore pattern). Headless auth resolution: the
///    session lives in flutter_secure_storage ([SessionStore]),
///    and [TabsBackend] reads its token from that same store on
///    EVERY authenticated call, so a headless isolate with the
///    plugin registered (the WorkManager background engine
///    registers every plugin, per daily_score_background.dart's
///    channel-reality note) resolves the session exactly as the
///    foreground does. When the email cannot be resolved, this
///    runner fails closed and first-open covers.
/// 2. Grant gate BEFORE any Health Connect read: channel probe →
///    [HealthConnectService.hasBackgroundAccess]. Known-absent ⇒
///    silent stop. Probe or grant failure ⇒ UNKNOWN ⇒ do NOT
///    read HC (no partial report; the week stays due).
/// 3. Construct the coordinator with the extracted production
///    seams ([WeeklyGenerationExecutor] + the file claim +
///    [LocalWeeklyNotifier], already background-safe) and run
///    `maybeGenerate` inside a never-throws top level (which also
///    absorbs PKG2 MINOR 2's escaping upsert throw on this path).
///
/// The generation wall-time is logged on every run that reaches
/// generation (the Daily Score runner's diagnostic pattern —
/// outcome fields plus a debug line). Vera's assumed bound:
/// a healthy weekly generation completes in under 2 minutes;
/// [WeeklyReportBackgroundOutcome.exceededAssumedBound] flags
/// any run past it (TTL re-derivation is Vera's, not the
/// runner's — the runner only reports).

class WeeklyReportBackgroundOutcome {
  /// Why the run stopped before the coordinator, when it did:
  /// 'owner-unverified', 'grant-absent', 'grant-unknown', or
  /// 'error'. Null when the coordinator ran.
  final String? skippedReason;

  /// The coordinator's outcome, when it ran.
  final WeeklyAutoOutcome? coordinatorOutcome;

  /// Wall-time of the coordinator run (generation included),
  /// when it ran.
  final Duration? duration;

  /// True when the coordinator run exceeded Vera's assumed
  /// 2-minute generation bound (see the file header).
  final bool exceededAssumedBound;

  const WeeklyReportBackgroundOutcome({
    this.skippedReason,
    this.coordinatorOutcome,
    this.duration,
    this.exceededAssumedBound = false,
  });
}

class WeeklyReportBackgroundRunner {
  WeeklyReportBackgroundRunner({
    required this._readSessionEmail,
    required this._warmHistoryStore,
    required this._probeChannel,
    required this._hasBackgroundAccess,
    required this._buildCoordinator,
    DateTime Function()? now,
    void Function(String message)? log,
  }) : _now = now ?? DateTime.now,
       _log = log ?? debugPrint;

  final Future<String?> Function() _readSessionEmail;
  final Future<void> Function(String? email) _warmHistoryStore;
  final Future<bool> Function() _probeChannel;
  final Future<bool> Function() _hasBackgroundAccess;
  final Future<WeeklyAutomationCoordinator> Function() _buildCoordinator;
  final DateTime Function() _now;
  final void Function(String message) _log;

  /// Vera's assumed generation bound (ruling §4): a run past
  /// 2 minutes is reported, never silently absorbed.
  static const Duration assumedGenerationBound = Duration(minutes: 2);

  factory WeeklyReportBackgroundRunner.production() {
    final backend = TabsBackend();
    final hc = HealthConnectService();
    final store = WeeklyReportStore();
    return WeeklyReportBackgroundRunner(
      readSessionEmail: () => SessionStore().readEmail(),
      warmHistoryStore: (email) =>
          HealthHistoryStore.instance.warmFromDisk(currentEmail: email),
      probeChannel: () async {
        try {
          return await hc.isAvailable();
        } catch (_) {
          return false;
        }
      },
      hasBackgroundAccess: hc.hasBackgroundAccess,
      buildCoordinator: () async {
        final weeklyService = buildWeeklyGenerationService();
        final executor = WeeklyGenerationExecutor(
          weeklyService: weeklyService,
          pipelineBuilder: () => buildWeeklyPipeline(
            backend: backend,
            weeklyService: weeklyService,
            hc: hc,
          ),
          categoriesLoader: backend.fetchLogCategories,
          profileLoader: () => loadWeeklyProfileFromPull(backend),
          recordsLoader: store.readAll,
          savePdf: defaultWeeklySavePdf,
          saveToDownloads: defaultWeeklySaveToDownloads,
          fallbackCategories: (all) => all,
        );
        return WeeklyAutomationCoordinator(
          checkEntitlement: () => resolveWeeklyEntitlement(
            isUnlimitedCheck: () async =>
                (await backend.fetchMembership()).isUnlimited,
            hasArchiveRecords: () async => (await store.readAll()).isNotEmpty,
          ),
          store: store,
          generate: executor.runAutoGeneration,
          notifier: LocalWeeklyNotifier(),
          claim: await WeeklyGenerationClaim.production(),
        );
      },
    );
  }

  /// Runs the weekly check once. Never throws: background work
  /// fails silently by design (the foreground first-open path is
  /// the retry surface for every degraded outcome).
  Future<WeeklyReportBackgroundOutcome> run() async {
    try {
      // 1 — session / owner binding FIRST (H1-04).
      String? sessionEmail;
      try {
        sessionEmail = await _readSessionEmail();
      } catch (_) {
        sessionEmail = null;
      }
      if (sessionEmail == null || sessionEmail.trim().isEmpty) {
        // Owner unverified: write nothing. (No warm either —
        // an unbound warm is the first link of the H1-04 wipe
        // chain, and this runner has no store-only fallback
        // that could justify one: generation reads the backend
        // and HC, both owner/grant gated below.)
        return const WeeklyReportBackgroundOutcome(
          skippedReason: 'owner-unverified',
        );
      }
      await _warmHistoryStore(sessionEmail);

      // 2 — grant gate BEFORE any HC read.
      final channelAvailable = await _probeChannel();
      if (!channelAvailable) {
        return const WeeklyReportBackgroundOutcome(
          skippedReason: 'grant-unknown',
        );
      }
      bool grant;
      try {
        grant = await _hasBackgroundAccess();
      } catch (_) {
        return const WeeklyReportBackgroundOutcome(
          skippedReason: 'grant-unknown',
        );
      }
      if (!grant) {
        return const WeeklyReportBackgroundOutcome(
          skippedReason: 'grant-absent',
        );
      }

      // 3 — the coordinator, never-throws at this top level.
      final coordinator = await _buildCoordinator();
      final stopwatch = Stopwatch()..start();
      final outcome = await coordinator.maybeGenerate(now: _now());
      stopwatch.stop();
      final duration = stopwatch.elapsed;
      _log(
        '[WeeklyReportBackground] coordinator run '
        '${duration.inMilliseconds} ms, outcome ${outcome.kind.name}',
      );
      return WeeklyReportBackgroundOutcome(
        coordinatorOutcome: outcome,
        duration: duration,
        exceededAssumedBound: duration > assumedGenerationBound,
      );
    } catch (_) {
      return const WeeklyReportBackgroundOutcome(skippedReason: 'error');
    }
  }
}
