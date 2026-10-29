/// Daily Score refresh — the founder's deliberate, user-initiated
/// exception to write-once scoring (founder direction, Oct 20,
/// 2026: "Let's add a refresh button on each score. When clicked
/// it will reload the score with updated numbers. That way we can
/// test if our updates are actually loading in HRV and heart rate
/// and sleep.").
///
/// Scores are write-once BY DESIGN for every automatic behavior,
/// and that stays: no capture, import, or engine run ever
/// rewrites a scored day. The morning freeze keeps catching a day
/// before its data fully arrives, though (today's score can freeze
/// sleep-only while Health Connect already holds the day's resting
/// HR; HRV lands a day behind). Only an explicit tap on the day
/// detail's refresh button re-scores a day, through this class.
///
/// SEMANTICS (in order):
/// (a) Snapshot the store's capture diagnostics.
/// (b) Run a capture with `force: true` — the ONLY caller allowed
///     to force a capture, bypassing the 6h throttle. Automatic
///     captures keep the throttle untouched, and the capture uses
///     its standard windows (no widening here). The forced
///     capture's own trailing engine run is the standard one: it
///     may first-score previously unscored days exactly as any
///     capture does, and it never rewrites a scored day.
/// (c) If the capture returns false (it threw), the refresh fails:
///     the viewed day's score is left untouched and the outcome is
///     [DailyScoreRefreshStatus.captureFailed].
/// (d) Re-read the store and recompute the viewed day with the
///     pure [computeDailyScore].
/// (e) If the computation is null (no component available), the
///     existing score is left untouched and the outcome is
///     [DailyScoreRefreshStatus.noChange] — defensive; not an
///     error.
/// (f) Otherwise the recomputation is written for THAT DAY ONLY
///     through [HealthHistoryStore.replaceScore] — no other day's
///     persisted score is touched by the rescore.
///
/// GATE EXEMPTION (founder amendment, Oct 20, 2026): automatic
/// scoring gates the CURRENT day on completeness (all three
/// components available — see the TODAY RULE in
/// `daily_score.dart`); an incomplete today stays pending. The
/// refresh is exempt: it scores the viewed day immediately from
/// its forced snapshot, complete or not — including today in its
/// pending state. After a manual refresh scores a day, write-once
/// resumes: automatic runs never re-score it.
///
/// Diagnostics: if the capture recorded NEW per-metric read
/// failures (bridge error codes in the store's capture
/// diagnostics that were not there — or not current — before this
/// capture), the outcome carries them in
/// [DailyScoreRefreshOutcome.newFailureCodes] so the UI can show
/// them plainly. The rescore still proceeds from store truth when
/// the capture returned true: per-read failures are chunk-isolated
/// by design, partial data is a designed outcome, and a failed
/// metric never fabricates data.
library;

import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/daily_score_sync.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';

/// The capture entry point a refresh runs, forced. Matches
/// [HealthHistorySync.capture]'s shape so tests can inject a fake
/// and production uses the real sync.
typedef ScoreCapture = Future<bool> Function({bool force});

/// Outcome code shown to the user when a refresh's capture fails.
/// The capture API reports failure as a plain `false` (it never
/// throws and carries no code of its own), so the refresh names
/// the failure itself — visible in the UI in the codebase's
/// bracketed `[CODE]` style.
const String dailyScoreRefreshCaptureFailedCode = 'CAPTURE_FAILED';

enum DailyScoreRefreshStatus {
  /// The viewed day was re-scored and the new computation
  /// persisted (it may be numerically identical to the old score
  /// when no new data landed — the persisted record is then
  /// byte-identical too).
  refreshed,

  /// No recomputation was possible (or the day vanished from the
  /// store mid-refresh): the existing score was left untouched.
  /// Not an error.
  noChange,

  /// The forced capture failed: the existing score was left
  /// untouched and the failure is surfaced to the user.
  captureFailed,
}

/// The result of one [DailyScoreRefresher.refresh] call.
class DailyScoreRefreshOutcome {
  final DailyScoreRefreshStatus status;

  /// The recomputation that was persisted; non-null exactly when
  /// [status] is [DailyScoreRefreshStatus.refreshed].
  final DailyScoreComputation? computation;

  /// Per-metric bridge error codes for read failures NEWLY
  /// recorded by this refresh's capture, keyed by the capture's
  /// metric names (`restingHr`, `calories`, `sleep`, `spikes`,
  /// `hrv`). Empty when the capture recorded no new failures.
  final Map<String, String> newFailureCodes;

  const DailyScoreRefreshOutcome({
    required this.status,
    this.computation,
    this.newFailureCodes = const {},
  });
}

/// Orchestrates one user-initiated Daily Score refresh for one
/// day. A dedicated class (rather than a method on
/// [DailyScoreEngine]) because the engine is deliberately
/// capture-free and write-once-only: keeping the forced capture
/// and the overwrite in a separate, single-purpose class keeps
/// that invariant legible — the engine never calls
/// [HealthHistoryStore.replaceScore], and this class is its only
/// caller.
class DailyScoreRefresher {
  final HealthHistoryStore store;
  final ScoreCapture _capture;

  /// Server-sync hook (Oct 28, 2026): when wired, a successful
  /// [HealthHistoryStore.replaceScore] queues the recomputation
  /// for upload as a [dailyScoreSourceManualRefresh] record.
  /// Queueing is fire-and-forget — it never delays or fails the
  /// refresh. The production factory wires
  /// [DailyScoreSync.instance] when no explicit sync is given
  /// through [DailyScoreRefreshOwner]'s production path — see
  /// the factories below; the test factory leaves it null unless
  /// a test injects one.
  final DailyScoreSync? scoreSync;

  /// Clock for the persisted score's `computedAt` stamp (the
  /// same value the sync payload carries). Injectable for tests.
  final DateTime Function() _now;

  DailyScoreRefresher._(this.store, this._capture,
      {this.scoreSync, DateTime Function()? now})
      : _now = now ?? DateTime.now;

  /// Production wiring: the capture runs through a
  /// [HealthHistorySync] bound to [store], so the forced capture,
  /// its diagnostics, and the rescore all act on the same store
  /// the screen is showing. Sync defaults to
  /// [DailyScoreSync.instance] — the refresh button is a
  /// production surface, and its manual_refresh records are
  /// exactly what sync exists to push.
  factory DailyScoreRefresher({
    required HealthHistoryStore store,
    HealthHistorySync? sync,
    DailyScoreSync? scoreSync,
    DateTime Function()? now,
  }) =>
      DailyScoreRefresher._(
        store,
        (sync ?? HealthHistorySync.withDeps(store: store)).capture,
        scoreSync: scoreSync ?? DailyScoreSync.instance,
        now: now,
      );

  /// Test wiring: inject the capture directly (a fake that lands
  /// new data in the store, fails, or stalls, as the case needs).
  /// Sync stays OFF unless [scoreSync] is injected, so the
  /// pre-sync test suite's behavior is unchanged.
  factory DailyScoreRefresher.withCapture({
    required HealthHistoryStore store,
    required ScoreCapture capture,
    DailyScoreSync? scoreSync,
    DateTime Function()? now,
  }) =>
      DailyScoreRefresher._(store, capture,
          scoreSync: scoreSync, now: now);

  /// Re-scores [date] per the semantics in the file header. Never
  /// throws — a refresh failure must never break the detail
  /// screen; it is reported as an outcome instead.
  Future<DailyScoreRefreshOutcome> refresh(String date) async {
    // (a) Snapshot the capture diagnostics. Reading the store
    // first also warms it, so the snapshot reflects the persisted
    // diagnostics even on a cold refresher.
    await store.readAll();
    final before = Map<String, CaptureDiagnostic>.of(
        store.lastCaptureDiagnostics);

    // (b) Forced capture — the button is the only forcer.
    bool captured;
    try {
      captured = await _capture(force: true);
    } catch (_) {
      captured = false;
    }

    // (c) A failed capture leaves the score untouched.
    if (!captured) {
      return const DailyScoreRefreshOutcome(
        status: DailyScoreRefreshStatus.captureFailed,
      );
    }

    // New failures: a metric whose diagnostics entry CHANGED
    // during this capture and now carries an error code. (The
    // entry carries the capture's timestamp, so a repeated failure
    // of the same metric still registers as new for THIS capture;
    // an unchanged entry is an older capture's leftover.)
    final after = store.lastCaptureDiagnostics;
    final newFailureCodes = <String, String>{};
    for (final entry in after.entries) {
      final code = entry.value.errorCode;
      if (code == null || code.isEmpty) continue;
      if (before[entry.key] == entry.value) continue;
      newFailureCodes[entry.key] = code;
    }

    // (d) Recompute the viewed day from the store's truth.
    final days = await store.readAll();
    final computation = computeDailyScore(days, date);

    // (e) Nothing computable: leave the existing score untouched.
    if (computation == null) {
      return DailyScoreRefreshOutcome(
        status: DailyScoreRefreshStatus.noChange,
        newFailureCodes: newFailureCodes,
      );
    }

    // (f) Replace THAT DAY ONLY, through the store's explicit
    // user-initiated overwrite path. One computedAt stamps both
    // the store's score metadata and the sync payload (see the
    // engine's identical rule in daily_score.dart).
    final computedAt = _now().millisecondsSinceEpoch;
    final replaced = await store.replaceScore(
      date,
      dailyScore: computation.dailyScore,
      scoreSleep: computation.sleepScoreRounded,
      scoreHrv: computation.hrvScoreRounded,
      scoreRestingHr: computation.restingHrScoreRounded,
      scoreSource: dailyScoreSourceManualRefresh,
      scoreComputedAt: computedAt,
      scoreAlgorithmVersion: dailyScoreAlgorithmVersion,
    );
    if (!replaced) {
      // The day is not in the store (any more) — nothing was
      // written; report no-change rather than a phantom refresh.
      return DailyScoreRefreshOutcome(
        status: DailyScoreRefreshStatus.noChange,
        newFailureCodes: newFailureCodes,
      );
    }
    // Sync hook: queue the JUST-REPLACED computation for upload
    // as a manual_refresh record. Fire-and-forget (see
    // [scoreSync]); even a byte-identical rescore queues — the
    // server's manual_refresh record is what lets another device
    // adopt this day's manual provenance.
    scoreSync?.queueComputation(
      computation,
      source: dailyScoreSourceManualRefresh,
      computedAt: computedAt,
    );
    return DailyScoreRefreshOutcome(
      status: DailyScoreRefreshStatus.refreshed,
      computation: computation,
      newFailureCodes: newFailureCodes,
    );
  }
}
