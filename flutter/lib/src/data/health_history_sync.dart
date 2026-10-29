import 'dart:async';

import 'package:tabs_lab/src/data/crash_reporting.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/daily_score_sync.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';

/// R70 WS1b — Health Connect → [HealthHistoryStore] capture.
///
/// Every capture merges through `mergeRefresh`: Health Connect is
/// the source of truth inside its retention window, and everything
/// older than the window survives untouched (the store never
/// shrinks — the Sep 30, 2026 lesson).
///
/// Throttle: captures are skipped when the last successful capture
/// was < [throttle] ago, unless forced — or unless the capture is
/// an app-open capture ([captureOnAppOpen], founder directive,
/// Oct 22, 2026: "we sync every time the app is opened and every
/// 30 minutes in the background"). The throttle relaxation is
/// SCOPED to that foreground entry point: every other non-forced
/// caller — the background runner included — stays governed by
/// the shared [throttle] stamp exactly as before (Juno ruling,
/// Oct 22, 2026, C1/C2). The first-ever capture (empty store) is
/// a forced full backfill. Capture NEVER throws — a failure must
/// never break a screen.
///
/// Per-metric read failures are never swallowed either: each
/// read's `lastReadErrorCode` is snapshotted and persisted to the
/// store's capture diagnostics (see
/// [HealthHistoryStore.recordCaptureDiagnostics]) — a failed HRV
/// read leaves a visible trace instead of looking like no HRV.
/// The HRV leg also records its outcome numbers there (partial
/// code, raw sample count, attributed day count).
class HealthHistorySync {
  static const Duration throttle = Duration(hours: 6);

  static final HealthHistorySync instance = HealthHistorySync._internal();
  HealthHistorySync._internal()
      : _hc = HealthConnectService(),
        _store = HealthHistoryStore.instance,
        _now = DateTime.now,
        _scoreSync = DailyScoreSync.instance,
        _readTimeout = HealthConnectService.readTimeout;

  /// Injectable for tests / WS2 wiring. [readTimeoutOverride]
  /// shortens the per-read bound (see [captureFromHealthConnect])
  /// so a wedged-read test does not wait the production 30 s —
  /// the same pattern as the HC service's probe timeout override.
  /// [scoreSync] wires the post-capture engine's Daily Score
  /// server-sync hook (Oct 28, 2026): the shared [instance] and
  /// the screens' explicit wiring pass it; test constructions
  /// leave it null and scoring stays exactly pre-sync.
  factory HealthHistorySync.withDeps({
    HealthConnectService? hc,
    HealthHistoryStore? store,
    DateTime Function()? now,
    Duration? readTimeoutOverride,
    DailyScoreSync? scoreSync,
  }) =>
      HealthHistorySync._(
          hc ?? HealthConnectService(),
          store ?? HealthHistoryStore.instance,
          now ?? DateTime.now,
          readTimeoutOverride ?? HealthConnectService.readTimeout,
          scoreSync);

  HealthHistorySync._(this._hc, this._store, this._now, this._readTimeout,
      this._scoreSync);

  HealthConnectService _hc;
  HealthHistoryStore _store;
  DateTime Function() _now;

  /// The Daily Score server-sync hook handed to the post-capture
  /// engine run (see the factory doc). Null = sync off.
  final DailyScoreSync? _scoreSync;

  /// The bound applied to every Health Connect read inside a
  /// capture (V-2): [HealthConnectService.readTimeout] in
  /// production.
  final Duration _readTimeout;

  /// Test hook: swap the dependencies of the shared instance.
  void debugSetDeps({
    HealthConnectService? hc,
    HealthHistoryStore? store,
    DateTime Function()? now,
  }) {
    if (hc != null) _hc = hc;
    if (store != null) _store = store;
    if (now != null) _now = now;
  }

  // ── Single-flight (V-2 correction, delta-2) ─────────────────
  //
  // Repeated snapshot triggers (Home's _loadDailyScore fires from
  // several lifecycle points) used to stack CONCURRENT captures:
  // the throttle stamps only at the END of a run, so parallel
  // callers all passed the check and all read Health Connect.
  // Now one run is shared:
  // - a non-forced call while a run is in flight JOINS that run
  //   (same future, no second read);
  // - an app-open call ([captureOnAppOpen]) while a run is in
  //   flight joins it too — it never chains;
  // - a forced call while a FORCED run is in flight joins it;
  // - a forced call while a NON-forced run is in flight waits for
  //   that run to finish, then starts its own forced run (the
  //   refresh button's semantics are preserved: its capture is
  //   never silently downgraded to the in-flight throttled run).
  //
  // The flight state is STATIC — shared across ALL instances in
  // the isolate (delta-2): production defaults construct a FRESH
  // [HealthHistorySync.withDeps] per call (Home's
  // _loadDailyScore, DailyScoreScreen, DailyScoreRefresher),
  // while HealthRepository and the background runner use
  // [instance] — as instance fields those were four separate
  // flight domains and the dedupe never engaged in production.
  // Shared state makes any instance's in-flight run the one run
  // every other instance joins or chains behind. The chained
  // forced run is started by the instance that received the
  // forced call, exactly as before.
  static Future<bool>? _inFlightCapture;
  static bool _inFlightForced = false;

  /// Test hook (the [debugSetDeps] pattern): clear the shared
  /// single-flight state so tests that pend a capture cannot
  /// leak an in-flight run into the next test. Production code
  /// never calls this — a live run's own identity cleanup in
  /// [_trackFlight] is the only clearing path there.
  static void debugResetFlight() {
    _inFlightCapture = null;
    _inFlightForced = false;
  }

  /// The WS2-facing entry point: fire-and-forget safe, never throws.
  /// Returns true when a capture actually ran.
  Future<bool> capture({bool force = false}) {
    final inFlight = _inFlightCapture;
    if (inFlight != null) {
      if (!force || _inFlightForced) return inFlight;
      // Forced call arriving mid-flight of a non-forced run:
      // chain a fresh forced run behind it.
      final chained = inFlight.then((_) => _startCapture(force: true));
      _trackFlight(chained, forced: true);
      return chained;
    }
    return _startCapture(force: force);
  }

  /// The app-open entry point (founder directive, Oct 22, 2026):
  /// every app open — cold start and return-from-background —
  /// syncs, so an open-triggered capture is NOT skipped by the
  /// [throttle]. It is deliberately a DISTINCT intent from
  /// `force`:
  /// - it runs the identical capture (same five reads, same
  ///   merge-only store writes, same post-capture engine run,
  ///   same TODAY RULE, same diagnostics, same end-of-run stamp);
  /// - while ANY run is in flight it JOINS that run — it never
  ///   chains a second run behind it (force's chain-a-second-run
  ///   behavior belongs to the day-detail refresh button alone),
  ///   so one app open produces exactly one capture attempt even
  ///   when Home, the score history, and the health repository
  ///   all attempt one in the same open (they use the plain
  ///   throttled [capture]: they join this run in flight, or are
  ///   throttled by the stamp this run leaves behind);
  /// - an open run counts as NON-forced for flight purposes: a
  ///   forced refresh arriving during it still chains behind it,
  ///   exactly as it does behind any non-forced run.
  ///
  /// FOREGROUND ONLY (Juno ruling, Oct 22, 2026, F1/F2): callers
  /// invoke this synchronously at cold start / resume, while the
  /// app is actually foregrounded, and the read executes in that
  /// foreground window — it is never scheduled for later, and no
  /// background path may call it.
  Future<bool> captureOnAppOpen() {
    final inFlight = _inFlightCapture;
    if (inFlight != null) return inFlight;
    return _startCapture(force: false, bypassThrottle: true);
  }

  Future<bool> _startCapture(
      {required bool force, bool bypassThrottle = false}) {
    final run =
        captureFromHealthConnect(force: force, bypassThrottle: bypassThrottle);
    _trackFlight(run, forced: force);
    return run;
  }

  void _trackFlight(Future<bool> run, {required bool forced}) {
    _inFlightCapture = run;
    _inFlightForced = forced;
    unawaited(run.then((_) {
      if (identical(_inFlightCapture, run)) {
        _inFlightCapture = null;
        _inFlightForced = false;
      }
    }, onError: (_) {
      if (identical(_inFlightCapture, run)) {
        _inFlightCapture = null;
        _inFlightForced = false;
      }
    }));
  }

  /// Reads the Health Connect windows and merge-refreshes them into
  /// the history store. The reads run CRITICAL-FIRST — resting HR,
  /// sleep, HRV, then the sibling reads (calories, spikes) — so the
  /// score-critical reads are never delayed behind the siblings,
  /// and never contend with zombie native reads a sibling's Dart
  /// timeout left behind (a Dart timeout does not cancel the
  /// native read):
  /// - resting HR: full window 180 days (`readRestingHrHistory`)
  /// - sleep + deep: full window 90 days (`readSleepHistory`)
  /// - HRV: ONE range read (`readHrvSamples`) over 90 days on the
  ///   first-ever capture, 31 days on routine captures; raw samples
  ///   are attributed to local calendar days and reduced to the
  ///   daily top-tier average in Dart (`attributeDailyHrv`). The
  ///   range window retro-fills HRV for days the store already
  ///   holds from other metrics (merge-only: stored values are
  ///   never erased, only refreshed/filled).
  /// - calories: full window 180 days (`readCaloriesHistory`)
  /// - spikes: 180 days on the first-ever backfill only,
  ///   31 days on routine captures (`readSpikeCounts` is the
  ///   expensive raw-sample compute)
  ///
  /// Resting HR / calories / sleep windows are GAP-AWARE on
  /// routine captures: the full window above applies on the
  /// first-ever capture and whenever the store carries no
  /// last-capture stamp; a routine capture instead reads
  /// `clamp(ceil(gapDays) + 2, 31, fullCap)` days, where gapDays
  /// is the time since the last capture — only the gap plus
  /// margin needs re-reading, floored at 31 days so the score's
  /// 28-day baseline window is always fully re-read. The spikes
  /// and HRV windows are not gap-aware (fixed first/routine
  /// windows, above).
  ///
  /// Sleep-totals upgrade (Oct 28, 2026): when the store's
  /// sleep-totals rule version is stale (see
  /// [HealthHistoryStore.currentSleepTotalsRuleVersion]), the
  /// sleep read ignores the gap-aware window and re-reads the
  /// FULL 90 days once — stored nights inside Health Connect's
  /// window were computed under the legacy single-best-bout rule
  /// and would otherwise keep those stale totals indefinitely,
  /// since routine captures only re-read the gap-aware window.
  /// The store is stamped to the current version only when that
  /// full sleep read completes cleanly (no error, no partial);
  /// a failed or partial sleep read leaves the version stale so
  /// the next capture retries the full window.
  /// [bypassThrottle] is the app-open intent (see
  /// [captureOnAppOpen]): it skips ONLY the throttle check below —
  /// nothing else about the run changes. Direct callers outside
  /// the sync's own entry points should not pass it; [force] keeps
  /// its exact prior meaning for its existing callers.
  Future<bool> captureFromHealthConnect(
      {bool force = false, bool bypassThrottle = false}) async {
    try {
      await _store.warmFromDisk();
      final sleepRuleUpgradePending = _store.sleepTotalsRuleVersion <
          HealthHistoryStore.currentSleepTotalsRuleVersion;
      final now = _now();
      final isFirst = (await _store.dayCount()) == 0;
      final last = _store.lastCaptureMs;
      if (!force && !bypassThrottle && !isFirst && last != null) {
        final age = now.millisecondsSinceEpoch - last;
        if (age >= 0 && age < throttle.inMilliseconds) return false;
      }

      // Gap-aware routine windows (resting HR / calories /
      // sleep only — spikes and HRV keep their fixed
      // first/routine windows): routine captures only need to
      // cover the gap since the last capture plus margin,
      // floored at 31 days so the score's 28-day baseline window
      // is always fully re-read; first/absent-stamp captures
      // keep the full backfill.
      int windowDays(int fullCap) {
        final lastCaptureMs = last;
        if (isFirst || lastCaptureMs == null) return fullCap;
        final gapDays =
            ((now.millisecondsSinceEpoch - lastCaptureMs) / 86400000)
                .ceil();
        final days = gapDays + 2;
        if (days < 31) return 31;
        if (days > fullCap) return fullCap;
        return days;
      }

      final restingHrWindowDays = windowDays(180);
      final caloriesWindowDays = windowDays(180);
      // A stale sleep-totals rule version forces the full
      // 90-day sleep backfill (like a first capture) regardless
      // of the gap-aware window; the other windows are unchanged.
      final sleepWindowDays = sleepRuleUpgradePending ? 90 : windowDays(90);

      final byDate = <String, DailyBiometrics>{};
      void put(String date,
          {int? hr, int? sleep, int? deep, int? spikes, int? kcal, double? hrv}) {
        final prev = byDate[date];
        byDate[date] = DailyBiometrics(
          date: date,
          restingHrBpm: hr ?? prev?.restingHrBpm,
          sleepMinutes: sleep ?? prev?.sleepMinutes,
          deepSleepMinutes: deep ?? prev?.deepSleepMinutes,
          spikeCount: spikes ?? prev?.spikeCount,
          caloriesKcal: kcal ?? prev?.caloriesKcal,
          hrvRmssdMs: hrv ?? prev?.hrvRmssdMs,
        );
      }

      // Capture diagnostics (HRV visibility fix): the HC service
      // fails closed — a failed read returns [] and records its
      // code in `lastReadErrorCode` — and the capture used to
      // never look, so e.g. an HRV read blocked by a missing grant
      // (HRV_SAMPLES_READ_FAILED) vanished without a trace while
      // markCaptured still stamped success. Mirror the queries
      // layer: reset the code around each read, snapshot it right
      // after, and persist the per-metric outcome to the store
      // (failures recorded, successes clear their metric's entry).
      final captureFailures = <String, String>{};
      final captureSucceeded = <String>{};
      void noteRead(String metric) {
        final code = _hc.lastReadErrorCode;
        if (code != null && code.isNotEmpty) {
          captureFailures[metric] = code;
        } else {
          captureSucceeded.add(metric);
        }
      }

      void resetReadCodes() {
        _hc.lastReadErrorCode = null;
        _hc.lastPartialErrorCode = null;
      }

      // V-2 — every read is bounded by the HC service's
      // readTimeout, per that service's contract ("callers bound
      // reads with readTimeout"): the sync is a caller and now
      // bounds its own reads. A timeout degrades EXACTLY like a
      // failed read — empty result, `READ_TIMEOUT` recorded in
      // the metric's diagnostics via noteRead below, the capture
      // completes, and the screens score from store truth and
      // render. Without the bound, one wedged bridge read stalled
      // the snapshot-first loads (Home face, score history)
      // indefinitely.
      Future<List<T>> boundedRead<T>(Future<List<T>> read) async {
        try {
          return await read.timeout(_readTimeout);
        } on TimeoutException {
          _hc.lastReadErrorCode = 'READ_TIMEOUT';
          return <T>[];
        }
      }

      // Critical-first order: resting HR → sleep → HRV, then
      // the sibling reads (calories, spikes). Each read's block
      // (reset / bounded read / note / put loop) moves intact.
      resetReadCodes();
      final hrHist =
          await boundedRead(_hc.readRestingHrHistory(restingHrWindowDays));
      noteRead('restingHr');
      for (final r in hrHist) {
        put(r.date, hr: r.bpm);
      }
      resetReadCodes();
      final sleepHist =
          await boundedRead(_hc.readSleepHistory(sleepWindowDays));
      noteRead('sleep');
      // Snapshot the sleep leg's cleanliness NOW, before the
      // HRV leg's resetReadCodes() wipes both codes: the partial
      // code is set by the service during the sleep read, and
      // noteRead only snapshots the error code. The upgrade
      // stamp below requires BOTH codes clear.
      final sleepReadClean =
          _hc.lastReadErrorCode == null && _hc.lastPartialErrorCode == null;
      for (final r in sleepHist) {
        put(r.date, sleep: r.mins, deep: r.deep);
      }

      // HRV — ONE range read of raw samples; day attribution +
      // the daily top-tier rule run in Dart (attributeDailyHrv).
      // The window retro-fills HRV onto days already in the store
      // from other metrics: the first capture reaches back 90
      // days, routine captures 31.
      final hrvWindowDays = isFirst ? 90 : 31;
      final today = DateTime(now.year, now.month, now.day);
      final hrvDates = <String>{
        for (var i = 0; i < hrvWindowDays; i++)
          _historyDateStr(today.subtract(Duration(days: i))),
      };
      resetReadCodes();
      final hrvSamples =
          await boundedRead(_hc.readHrvSamples(hrvWindowDays));
      noteRead('hrv');
      // Defect 1b — HRV outcome numbers: the partial code (the
      // read returned data with chunks missing — Defect 0's new
      // contract), the raw sample count the bridge returned, and
      // the attributed day count are recorded alongside any error
      // code, so a recurrence is diagnosable from the diagnostics
      // record alone. Counts are operational metadata, not values.
      final hrvPartialCode = _hc.lastPartialErrorCode;
      final dailyHrv = attributeDailyHrv(hrvSamples, hrvDates);
      for (final entry in dailyHrv.entries) {
        put(entry.key, hrv: entry.value);
      }

      resetReadCodes();
      final calHist =
          await boundedRead(_hc.readCaloriesHistory(caloriesWindowDays));
      noteRead('calories');
      for (final r in calHist) {
        put(r.date, kcal: r.kcal);
      }
      resetReadCodes();
      final spikeHist =
          await boundedRead(_hc.readSpikeCounts(isFirst ? 180 : 31));
      noteRead('spikes');
      for (final r in spikeHist) {
        put(r.date, spikes: r.count);
      }

      await _store.mergeRefresh(byDate.values);
      // A failed read leaves a visible trace even though the
      // capture itself still completes (merge + throttle stamp
      // unchanged): the diagnostics record is on the store.
      await _store.recordCaptureDiagnostics(
        failures: captureFailures,
        succeeded: captureSucceeded,
        atMs: now.millisecondsSinceEpoch,
        hrvPartialCode: hrvPartialCode,
        hrvSampleCount: hrvSamples.length,
        hrvDayCount: dailyHrv.length,
      );
      // Sleep-totals upgrade: stamp the current rule version
      // only when the pending full-window sleep re-read above
      // completed cleanly. A failed or partial sleep read does
      // NOT stamp — the version stays stale and the next
      // capture retries the full 90-day window.
      if (sleepRuleUpgradePending && sleepReadClean) {
        await _store.markSleepTotalsRuleVersion(
            HealthHistoryStore.currentSleepTotalsRuleVersion);
      }
      await _store.markCaptured(now.millisecondsSinceEpoch);
      // R70 Daily Score — after-capture compute trigger: any day
      // whose inputs now exist gets its (write-once) score. The
      // engine never throws and never rewrites a scored day.
      // TODAY RULE (see daily_score.dart header, amended Oct 20,
      // 2026): this post-capture run is the ONLY trigger allowed
      // to score the current day — it runs after the capture merge
      // (the snapshot), on the day's freshest data — so it
      // deliberately passes NO beforeDate cutoff; every other
      // trigger passes beforeDate: today. But it now names today
      // as the completeness-gated date: today is scored only when
      // ALL THREE components are available, otherwise it stays
      // pending for a later capture to retry. Past days in the
      // same run score under the day-boundary fallback.
      await DailyScoreEngine(store: _store, scoreSync: _scoreSync)
          .computeMissingScores(
        completeOnlyDate: _historyDateStr(now),
      );
      return true;
    } catch (e, st) {
      // Capture failure must never break a screen. C7 allowlisted
      // call site (CRASH_REPORTING_CALLSITES.md #3): type + static
      // message only — a Health Connect read error can embed health
      // values, which never leave the device.
      CrashReporting.captureError(e,
          stackTrace: st, staticMessage: 'health history capture failed');
      return false;
    }
  }

}

String _historyDateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';
