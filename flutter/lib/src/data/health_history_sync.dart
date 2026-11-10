import 'dart:async';

import 'package:tabs_lab/src/data/crash_reporting.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/daily_score_sync.dart';
import 'package:tabs_lab/src/data/hc_availability.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart'
    show HistoryMetric;
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/progress_report.dart'
    show DataSourceStatus, deriveMetricStatus;

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
/// read's outcome object (Phase 2 §1 — `HcReadOutcome`) carries
/// its own failure code, which is persisted to the store's
/// capture diagnostics (see
/// [HealthHistoryStore.recordCaptureDiagnostics]) — a failed HRV
/// read leaves a visible trace instead of looking like no HRV.
/// The HRV leg also records its outcome numbers there (partial
/// code, raw sample count, attributed day count). Since PR-3 the
/// capture path claims NOTHING from the service's legacy
/// error-slot fields: attribution rides on the outcome objects
/// alone, exactly as the union's does.
/// Phase 2 PR-3 — one capture leg's read evidence, claimed from
/// THAT leg's own `HcReadOutcome` object (never from the service's
/// legacy slot fields). This is the capture path's input surface
/// for the ONE shared per-metric derivation
/// ([deriveMetricStatus]): the booleans below are exactly that
/// function's `readFailed` / `partialRead` /
/// `readSecurityException` inputs, recorded per capture metric
/// (`restingHr`, `sleep`, `hrv`, `calories`, `spikes` — the
/// capture's own names) so the P2 identity fixtures can derive
/// the capture path's per-metric availability states from the
/// capture's OWN recorded evidence and assert them identical to
/// the report collector's, instead of restaging the reads.
class CaptureMetricEvidence {
  /// The leg's outcome carried a non-empty failure code.
  final bool readFailed;

  /// The leg's outcome carried a non-empty partial code (real
  /// data, some chunks missing — not a failure).
  final bool partialRead;

  /// The leg failed AND its outcome's detail names a
  /// SecurityException — the stale/wedged grant signature for
  /// that metric (mirrors `HcReadOutcome.failedWithSecurityException`).
  final bool readSecurityException;

  /// The leg's failure code (null unless [readFailed]).
  final String? errorCode;

  /// The leg's partial code (null unless [partialRead]).
  final String? partialCode;

  const CaptureMetricEvidence({
    required this.readFailed,
    required this.partialRead,
    required this.readSecurityException,
    this.errorCode,
    this.partialCode,
  });
}

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

  final Map<String, CaptureMetricEvidence> _lastCaptureEvidence = {};

  /// Phase 2 PR-3 — the most recent capture run's per-metric
  /// read evidence (see [CaptureMetricEvidence]), keyed by the
  /// capture's metric names. In-memory only: the PERSISTED trace
  /// of a capture stays the store's capture diagnostics (codes +
  /// HRV counts); this map additionally carries the
  /// SecurityException flag the diagnostics deliberately do not
  /// persist, so the shared derivation can run over the capture's
  /// own evidence. Replaced leg-by-leg as each capture runs.
  Map<String, CaptureMetricEvidence> get lastCaptureEvidence =>
      Map.unmodifiable(_lastCaptureEvidence);

  /// Phase 2 PR-3 — THE capture path's per-metric availability
  /// state for [metric]: the shared derivation
  /// ([deriveMetricStatus]) over the capture's recorded
  /// [evidence] for that leg, the metric's grant state, and
  /// whether the store holds data for the metric after the
  /// capture (the capture-side analogue of the report union's
  /// data presence: capture is merge-only, so a failed leg's
  /// surviving store data is exactly what a later union would
  /// surface from the store).
  ///
  /// Capture's own bookkeeping (the failures map, the succeeded
  /// set, partial suppression of the post-capture score compute)
  /// is NOT an availability derivation and does not go through
  /// this function: it answers a different question — did THIS
  /// run's read fail, partially return, or succeed — with no
  /// grant or data-presence inputs, and its rules (an HRV partial
  /// is recorded via the diagnostics' partial code, never as a
  /// failure; any partial leg suppresses scoring) are
  /// capture-local by design (design §5). What IS shared is the
  /// availability STATE vocabulary: any per-metric state claimed
  /// ABOUT a capture is derived here, through the same function
  /// the report collector uses, from the same-named inputs.
  static DataSourceStatus deriveCaptureMetricStatus({
    required HcMetricGrantState grant,
    required CaptureMetricEvidence evidence,
    required bool storeHasData,
  }) =>
      deriveMetricStatus(
        grant: grant,
        partialRead: evidence.partialRead,
        readFailed: evidence.readFailed,
        readSecurityException: evidence.readSecurityException,
        unionHasData: storeHasData,
      );

  /// The [HistoryMetric] a capture metric name feeds, for grant
  /// derivation via [hcMetricGrantState] (the capture's names are
  /// its diagnostics names; `sleep` covers deep sleep exactly as
  /// the report's deepSleep section mirrors its sleep section).
  static HistoryMetric? historyMetricForCaptureMetric(String metric) =>
      switch (metric) {
        'restingHr' => HistoryMetric.restingHr,
        'sleep' => HistoryMetric.sleep,
        'hrv' => HistoryMetric.hrv,
        'calories' => HistoryMetric.calories,
        'spikes' => HistoryMetric.spikes,
        _ => null,
      };

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
  /// - HRV: ONE range read (`readHrvSamples`) over 90 days until
  ///   the backfill completes, 31 days after (see
  ///   [HealthHistoryStore.hrvBackfillComplete]: the window is
  ///   keyed off that persisted flag — set only by a CLEAN HRV
  ///   read — not off the day count, B-02); raw samples
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
  /// and HRV windows are not gap-aware (fixed windows, above:
  /// spikes first/routine, HRV keyed off the backfill flag).
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
      // fails closed — a failed read returns [] — and the capture
      // used to never look, so e.g. an HRV read blocked by a
      // missing grant (HRV_SAMPLES_READ_FAILED) vanished without
      // a trace while markCaptured still stamped success. Since
      // PR-3 each leg is read through its outcome-carrying
      // variant (Phase 2 §1) and the leg's bookkeeping claims its
      // signals from THAT read's outcome object alone — the
      // reset-then-snapshot protocol over the service's legacy
      // slot fields is DELETED from the capture path, so no code
      // here reads the slots any more and attribution cannot
      // cross-talk with any other reader of the shared service
      // instance. The per-metric outcome is persisted to the
      // store (failures recorded, successes clear their metric's
      // entry), exactly as the slot protocol's snapshots were.
      final captureFailures = <String, String>{};
      final captureSucceeded = <String>{};
      // B-02 — set when ANY leg of this capture came back
      // partial (real data, some chunks missing). A partial
      // capture is not a clean capture: it must not complete
      // the HRV backfill, must not clear the affected metric's
      // recorded failure, and must not run the post-capture
      // score compute (write-once scores would lock past days
      // without the components the failed chunks held).
      var captureHadPartial = false;
      void noteRead(String metric, HcReadOutcome<dynamic> outcome) {
        // PR-3: the leg's evidence for the shared derivation is
        // recorded from the outcome object, in the derivation's
        // own input vocabulary (see [CaptureMetricEvidence]).
        final code = outcome.errorCode;
        final failed = code != null && code.isNotEmpty;
        final partialCode = outcome.partialCode;
        final partial = partialCode != null && partialCode.isNotEmpty;
        _lastCaptureEvidence[metric] = CaptureMetricEvidence(
          readFailed: failed,
          partialRead: !failed && partial,
          readSecurityException:
              failed && outcome.failedWithSecurityException,
          errorCode: failed ? code : null,
          partialCode: partial ? partialCode : null,
        );
        if (failed) {
          captureFailures[metric] = code;
          return;
        }
        if (partial) {
          captureHadPartial = true;
          if (metric == 'hrv') {
            // The HRV partial is already durably recorded via
            // the hrvPartialCode passed to
            // recordCaptureDiagnostics below (its entry is
            // rewritten with the partial code, never cleared) —
            // adding it to captureFailures here would rewrite
            // that entry's errorCode with the partial code and
            // regress that contract. It is in NEITHER set.
          } else {
            // A partial read is NOT a success for its metric:
            // recording the partial code as the metric's failure
            // keeps its earlier failure entry on record instead
            // of the succeeded-loop clearing it (B-02: a partial
            // sleep read used to clear sleep's recorded failure).
            captureFailures[metric] = partialCode;
          }
          return;
        }
        captureSucceeded.add(metric);
      }

      // V-2 — every read is bounded by the HC service's
      // readTimeout, per that service's contract ("callers bound
      // reads with readTimeout"): the sync is a caller and now
      // bounds its own reads. A timeout degrades EXACTLY like a
      // failed read — empty result, a `READ_TIMEOUT` outcome
      // recorded in the metric's diagnostics via noteRead below,
      // the capture completes, and the screens score from store
      // truth and render. Without the bound, one wedged bridge
      // read stalled the snapshot-first loads (Home face, score
      // history) indefinitely.
      Future<HcReadOutcome<List<T>>> boundedRead<T>(
          Future<HcReadOutcome<List<T>>> read) async {
        try {
          return await read.timeout(_readTimeout);
        } on TimeoutException {
          return HcReadOutcome<List<T>>(
              value: <T>[], errorCode: 'READ_TIMEOUT');
        }
      }

      // Critical-first order: resting HR → sleep → HRV, then
      // the sibling reads (calories, spikes). Each read's block
      // (bounded outcome read / note / put loop) moves intact.
      final hrOutcome = await boundedRead(
          _hc.readRestingHrHistoryWithOutcome(restingHrWindowDays));
      noteRead('restingHr', hrOutcome);
      for (final r in hrOutcome.value) {
        put(r.date, hr: r.bpm);
      }
      final sleepOutcome = await boundedRead(
          _hc.readSleepHistoryWithOutcome(sleepWindowDays));
      noteRead('sleep', sleepOutcome);
      // Snapshot the sleep leg's cleanliness NOW, from its own
      // outcome: the upgrade stamp below requires the sleep read
      // to have completed with NO error and NO partial. (Strict
      // null checks, exactly as the slot snapshot read them: an
      // empty-string code counted as not-clean for the stamp
      // even though noteRead treats it as no failure.)
      final sleepReadClean =
          sleepOutcome.errorCode == null && sleepOutcome.partialCode == null;
      for (final r in sleepOutcome.value) {
        put(r.date, sleep: r.mins, deep: r.deep);
      }

      // HRV — ONE range read of raw samples; day attribution +
      // the daily top-tier rule run in Dart (attributeDailyHrv).
      // The window retro-fills HRV onto days already in the store
      // from other metrics: it reaches back 90 days UNTIL the
      // backfill completes and 31 days after. B-02: the window is
      // keyed off the store's persisted backfill-complete flag —
      // NOT the dayCount-derived isFirst, which collapsed to
      // "routine" the moment any sibling metric merged data, so
      // HRV in chunks that failed during the first capture
      // (days 31–90) was never re-read.
      final hrvWindowDays = _store.hrvBackfillComplete ? 31 : 90;
      final today = DateTime(now.year, now.month, now.day);
      final hrvDates = <String>{
        for (var i = 0; i < hrvWindowDays; i++)
          _historyDateStr(today.subtract(Duration(days: i))),
      };
      final hrvOutcome =
          await boundedRead(_hc.readHrvSamplesWithOutcome(hrvWindowDays));
      noteRead('hrv', hrvOutcome);
      final hrvSamples = hrvOutcome.value;
      // Defect 1b — HRV outcome numbers: the partial code (the
      // read returned data with chunks missing — Defect 0's new
      // contract), the raw sample count the bridge returned, and
      // the attributed day count are recorded alongside any error
      // code, so a recurrence is diagnosable from the diagnostics
      // record alone. Counts are operational metadata, not values.
      final hrvPartialCode = hrvOutcome.partialCode;
      // Snapshot the HRV leg's cleanliness NOW, from its own
      // outcome: the backfill flag below may be set only by a
      // clean read (no error, no partial — strict null checks,
      // exactly as the slot snapshot read them).
      final hrvReadClean =
          hrvOutcome.errorCode == null && hrvPartialCode == null;
      final dailyHrv = attributeDailyHrv(hrvSamples, hrvDates);
      for (final entry in dailyHrv.entries) {
        put(entry.key, hrv: entry.value);
      }

      final calOutcome = await boundedRead(
          _hc.readCaloriesHistoryWithOutcome(caloriesWindowDays));
      noteRead('calories', calOutcome);
      for (final r in calOutcome.value) {
        put(r.date, kcal: r.kcal);
      }
      final spikeOutcome = await boundedRead(
          _hc.readSpikeCountsWithOutcome(isFirst ? 180 : 31));
      noteRead('spikes', spikeOutcome);
      for (final r in spikeOutcome.value) {
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
      // HRV backfill (B-02): the persisted flag is set ONLY by a
      // clean HRV read — a partial or failed read leaves it
      // unset, so the next capture still spans the full 90 days
      // and the chunks that failed get re-read.
      if (hrvReadClean) {
        await _store.markHrvBackfillComplete();
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
      //
      // B-02: the run is skipped ENTIRELY on a capture where any
      // leg was partial. Past days carry no completeness gate
      // (only today does), so scoring after a partial capture
      // would write-once-lock past days whose sleep/HRV is
      // missing BECAUSE a chunk failed. The merged partial data
      // stays in the store; the next clean capture scores those
      // days exactly as a clean capture always did.
      if (!captureHadPartial) {
        await DailyScoreEngine(store: _store, scoreSync: _scoreSync)
            .computeMissingScores(
          completeOnlyDate: _historyDateStr(now),
        );
      }
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
