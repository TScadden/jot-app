/// R70 Daily Score — one number 0–100 per day, computed from the
/// founder's OWN rolling baselines in the [HealthHistoryStore].
/// This revives the removed Body Load / Cup Load score properly:
/// that 2026 original failed because it had no grounded measurement
/// or calibration; this one has both, and the formula below is the
/// whole of it — transparent, deterministic, and documented here
/// as the single source of truth.
///
/// NO population norms are used anywhere in this feature. Every
/// component is measured against the founder's personal baseline:
/// the most recent [baselineWindowDays] days WITH DATA strictly
/// before the scored day (the same "windows count days with data"
/// convention as `sleep_need.dart`). A component is AVAILABLE for a
/// day only when at least [baselineMinDays] baseline days exist for
/// it; otherwise it contributes nothing that day.
///
/// COMPONENTS (exact values; the persisted record stores each
/// component and the daily score rounded to whole numbers):
///
/// - Sleep (weight [weightSleep] = 40): from `evaluateSleepNight`
///   for the night ending on the scored day —
///   `score = 100 × c²`, where `c = clamp(asleepRatio, 0, 1)` and
///   asleepRatio = asleep ÷ that night's personal need (Sleep
///   Need, itself built only from the nights before). Squared
///   below need, capped AT need: 100% of need scores 100, no
///   above-need / oversleep bonus. No floor/knee either — a night
///   at 50% of need scores 25; that is the honest read of the
///   squared fraction of personal need met. Unavailable when
///   the night has no sleep data or its prior history is too
///   sparse for a need estimate
///   (evaluateSleepNight's own ≥7-prior-nights rule).
/// - HRV (weight [weightHrv] = 35): today's `hrvRmssdMs` (RMSSD —
///   the literature's canonical short-term HRV metric; within-
///   person baseline interpretation is the research-standard
///   approach) vs the baseline MEDIAN, as a percent deviation
///   `dev = (today − median) / median × 100`, mapped piecewise-
///   linearly through the anchors
///       dev ≤ −40% → 0 · dev = 0% → 70 · dev ≥ +25% → 100
///   interpolating linearly between anchors, clamped outside.
///   Slopes: 1.75 points per % below baseline, 1.2 per % above.
///   Unavailable when today has no HRV value or the baseline has
///   fewer than [baselineMinDays] days.
/// - Resting HR (weight [weightRestingHr] = 25): today's
///   `restingHrBpm` vs the baseline median, INVERTED (below
///   baseline scores higher), same anchor style:
///       dev ≤ −10% → 100 · dev = 0% → 70 · dev ≥ +20% → 0
///   interpolating linearly between anchors, clamped outside.
///   Slopes: 3.0 points per % below baseline, 3.5 per % above.
///   The benefit SATURATES at −10%: for a POTS user on ivabradine,
///   an unusually low resting HR is not unboundedly "better" — the
///   cap keeps the score honest.
///
/// DAILY SCORE = weighted mean over the AVAILABLE components with
/// the weights renormalized to the available set (e.g. sleep alone
/// → the sleep score; sleep + HRV → (40·sleep + 35·hrv) / 75). If
/// NO component is available there is NO score (cold start — no
/// number is shown or persisted from nothing).
///
/// Scoring is deterministic given the store data ≤ the scored day:
/// the score for date D uses the sleep of the night ending on D,
/// D's HRV and resting HR, and baselines from days strictly
/// before D.
///
/// WRITE-ONCE (automatic paths): computed scores are persisted
/// through [HealthHistoryStore.persistScore] and are never
/// recomputed or rewritten by any automatic path — a day computed
/// from a partial component set stays as computed, and later
/// baseline drift never rewrites history. The ONE exception is
/// deliberate and user-initiated (founder direction, Oct 20,
/// 2026): tapping Refresh on a day's detail screen re-scores THAT
/// day through `DailyScoreRefresher`
/// ([HealthHistoryStore.replaceScore]), so the founder can verify
/// late-arriving data actually lands. Nothing automatic — no
/// capture, import, or engine run — ever takes that path. Which
/// components contributed is derived from which persisted
/// component fields are non-null.
///
/// SNAPSHOT-FIRST (founder amendment, Oct 20, 2026): a NEW score
/// is never computed from stale store state when a fresher Health
/// Connect capture is obtainable. Every compute trigger first
/// runs/awaits a capture (the snapshot) covering the days it is
/// about to score: the post-capture engine run has this shape by
/// construction, and the other triggers (Home, the history
/// screen) await a capture before their compute runs. Those
/// snapshot captures stay subject to the capture's normal rules
/// (the 6h throttle) — only the refresh button forces a capture.
/// When a snapshot is throttled/skipped, the trigger scores from
/// the store exactly as the last completed capture left it.
///
/// TODAY RULE (R70 fix pass Vera F2, amended Oct 20, 2026): the
/// CURRENT calendar day is scored ONLY by the post-capture engine
/// run in `health_history_sync.dart` — the one run that happens
/// after a Health Connect capture has merged the day's freshest
/// data — and, since the amendment, ONLY WHEN THE DAY IS COMPLETE:
/// all three components available (each component's value present
/// AND its counting rule satisfied — see
/// [DailyScoreComputation.hasAllComponents]). An incomplete today
/// is NOT scored: no number, no frozen partial; the day stays
/// pending and later captures retry, and the first capture that
/// finds the day complete scores it, once. Every OTHER compute
/// trigger (Home, the score history screen) must pass
/// `beforeDate:` = today to
/// [DailyScoreEngine.computeMissingScores] (after awaiting its
/// snapshot capture, whose own post-capture run is the today
/// scorer above), so an early trigger can never freeze today
/// itself. The refresh button is exempt from the gate by founder
/// direction: it scores the viewed day immediately from its
/// forced snapshot, complete or not. DAY-BOUNDARY FALLBACK: once
/// a day is no longer today, the gate no longer applies to it —
/// it scores with whatever the store holds at its first post-day
/// snapshot, partial components honestly absent. Triggers that
/// never run the engine (the Sleep screen's Sleep Need estimate,
/// the union reader in `health_history_queries.dart`) persist no
/// scores and need no cutoff.
library;

import 'package:tabs_lab/src/data/daily_score_sync.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/sleep_need.dart';

/// Component weights (renormalized over the available set).
const int weightSleep = 40;
const int weightHrv = 35;
const int weightRestingHr = 25;

/// Baseline window: the most recent days WITH DATA strictly before
/// the scored day.
const int baselineWindowDays = 28;

/// Minimum baseline days before a component is available.
const int baselineMinDays = 7;

/// HRV anchors (percent deviation from the baseline median).
const double hrvAnchorLowDev = -40; // → score 0
const double hrvAnchorHighDev = 25; // → score 100

/// Resting-HR anchors (percent deviation from the baseline
/// median). Inverted: negative deviation (below baseline) scores
/// higher; benefit saturates at [rhrAnchorLowDev].
const double rhrAnchorLowDev = -10; // → score 100 (saturated)
const double rhrAnchorHighDev = 20; // → score 0

/// The score shared by both deviation-mapped components when the
/// day sits exactly at its baseline median.
const double baselineAnchorScore = 70;

/// Algorithm version stamped on every Daily Score record that
/// leaves the device (server sync, see `daily_score_sync.dart`)
/// and into the store's per-day score metadata.
///
/// 1 = the original scoring formula, whose sleep component is
/// the LINEAR curve (`100 × min(asleepRatio, 1.0)`), with the
/// HRV / resting-HR piecewise maps as documented in the file
/// header. Every build that ever ran v1 (through VC 100109, and
/// the server-sync branch itself) computed with the linear curve,
/// so v1-stamped records are genuinely linear-curve scores.
///
/// 2 = v1 with ONE change: the sleep component is the SQUARED
/// curve in [scoreSleepComponent] below (`100 × min(asleepRatio,
/// 1.0)²` — squared below need, capped at need). The squared
/// curve and this bump ship together in the VC 100110 combine:
/// no earlier build contained the squared curve (verified at
/// combine: the squared-curve branch carried no version marker
/// and no sync code, and no shipped build contained the curve),
/// so no v1-stamped squared-curve score was ever pushed.
const int dailyScoreAlgorithmVersion = 2;

/// Sync source for a score written by an automatic path (the
/// engine's write-once first scoring). Server contract value.
const String dailyScoreSourceAuto = 'auto';

/// Sync source for a score written by the founder's deliberate
/// refresh ([HealthHistoryStore.replaceScore] via the refresher).
/// Server contract value.
const String dailyScoreSourceManualRefresh = 'manual_refresh';

/// Sleep component from [asleepRatio] (asleep ÷ personal need):
/// squared below need, capped at need, never below 0.
double scoreSleepComponent(double asleepRatio) {
  final r = asleepRatio < 0 ? 0.0 : asleepRatio;
  final c = r > 1.0 ? 1.0 : r;
  return 100.0 * c * c;
}

/// HRV component: piecewise-linear on percent deviation from the
/// baseline median (anchors documented in the file header).
double scoreHrvComponent(double todayMs, double baselineMedianMs) {
  final dev = (todayMs - baselineMedianMs) / baselineMedianMs * 100;
  return _piecewise(
    dev,
    lowDev: hrvAnchorLowDev,
    lowScore: 0,
    highDev: hrvAnchorHighDev,
    highScore: 100,
  );
}

/// Resting-HR component: INVERTED piecewise-linear on percent
/// deviation from the baseline median — below baseline scores
/// higher, with the benefit saturating at [rhrAnchorLowDev].
double scoreRestingHrComponent(double todayBpm, double baselineMedianBpm) {
  final dev = (todayBpm - baselineMedianBpm) / baselineMedianBpm * 100;
  // Inverted: feed the negated deviation through the same shape —
  // dev −10% (below baseline) reads as +10 on the benefit side.
  return _piecewise(
    -dev,
    lowDev: -rhrAnchorHighDev, // dev +20% → score 0
    lowScore: 0,
    highDev: -rhrAnchorLowDev, // dev −10% → score 100
    highScore: 100,
  );
}

/// Piecewise-linear map through (lowDev, lowScore),
/// (0, [baselineAnchorScore]), (highDev, highScore), clamped
/// outside [lowDev, highDev]. Requires lowDev < 0 < highDev.
double _piecewise(
  double dev, {
  required double lowDev,
  required double lowScore,
  required double highDev,
  required double highScore,
}) {
  if (dev <= lowDev) return lowScore;
  if (dev >= highDev) return highScore;
  if (dev < 0) {
    final t = (dev - lowDev) / (0 - lowDev);
    return lowScore + t * (baselineAnchorScore - lowScore);
  }
  final t = dev / highDev;
  return baselineAnchorScore + t * (highScore - baselineAnchorScore);
}

/// Median of a non-empty list (mean of the two middle values for
/// an even count).
double medianOf(List<double> values) {
  final sorted = [...values]..sort();
  final mid = sorted.length ~/ 2;
  if (sorted.length.isOdd) return sorted[mid];
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

/// The baseline values for one metric: the values from the most
/// recent [baselineWindowDays] days WITH DATA strictly before
/// [date], newest first. Null when fewer than [baselineMinDays]
/// baseline days exist (component unavailable).
List<double>? _baselineValues(
  Map<String, DailyBiometrics> days,
  String date,
  double? Function(DailyBiometrics) pick,
) {
  final dates = days.keys.where((d) => d.compareTo(date) < 0).toList()
    ..sort((a, b) => b.compareTo(a)); // newest first
  final values = <double>[];
  for (final d in dates) {
    final v = pick(days[d]!);
    if (v == null) continue;
    values.add(v);
    if (values.length >= baselineWindowDays) break;
  }
  if (values.length < baselineMinDays) return null;
  return values;
}

/// One day's Daily Score computation: the exact (unrounded)
/// component scores and daily score, plus the inputs and baselines
/// behind them — the detail screen renders actual-vs-baseline from
/// exactly these fields (recomputed deterministically from store
/// data ≤ the day; the PERSISTED score itself is what the record
/// shows and changes only through the write paths on the store —
/// the engine's write-once [HealthHistoryStore.persistScore], or
/// the founder's explicit refresh via
/// [HealthHistoryStore.replaceScore]).
class DailyScoreComputation {
  final String date;

  /// Exact component scores; null = component unavailable.
  final double? sleepScore;
  final double? hrvScore;
  final double? restingHrScore;

  /// Exact weighted mean over the available components.
  final double dailyExact;

  // Inputs vs baselines (null wherever the component is
  // unavailable or the input itself is absent).
  final int? asleepMinutes;
  final int? sleepNeedMinutes;
  final double? hrvMs;
  final double? hrvBaselineMs;
  final int? restingHrBpm;
  final double? restingHrBaselineBpm;

  const DailyScoreComputation({
    required this.date,
    required this.sleepScore,
    required this.hrvScore,
    required this.restingHrScore,
    required this.dailyExact,
    this.asleepMinutes,
    this.sleepNeedMinutes,
    this.hrvMs,
    this.hrvBaselineMs,
    this.restingHrBpm,
    this.restingHrBaselineBpm,
  });

  /// The rounded whole-number daily score that gets persisted.
  int get dailyScore => dailyExact.round();

  /// Completeness (founder amendment, Oct 20, 2026): ALL THREE
  /// component scores are non-null — each component's value is
  /// present for the day AND its counting rule is satisfied (the
  /// sleep night evaluated against a personal need, ≥
  /// [baselineMinDays] baseline days for HRV / resting HR). This
  /// is the gate automatic scoring applies to the current day.
  bool get hasAllComponents =>
      sleepScore != null && hrvScore != null && restingHrScore != null;

  int? get sleepScoreRounded => sleepScore?.round();
  int? get hrvScoreRounded => hrvScore?.round();
  int? get restingHrScoreRounded => restingHrScore?.round();
}

/// Computes the Daily Score for [date] from [days] (the store's
/// full date → row map). Null when NO component is available —
/// the honest cold-start state, never a fabricated number.
///
/// Pure and deterministic given [days]; the engine below supplies
/// the store's current contents.
DailyScoreComputation? computeDailyScore(
  Map<String, DailyBiometrics> days,
  String date,
) {
  final row = days[date];
  if (row == null) return null;

  // Sleep: the night ending on [date], via Sleep Need.
  double? sleepScore;
  int? asleepMinutes;
  int? sleepNeedMinutes;
  final sleepByDate = <String, int>{
    for (final e in days.entries)
      if (e.value.sleepMinutes != null) e.key: e.value.sleepMinutes!,
  };
  final night = evaluateSleepNight(sleepByDate, date);
  if (night != null && night.asleepRatio != null) {
    sleepScore = scoreSleepComponent(night.asleepRatio!);
    asleepMinutes = night.asleepMinutes;
    sleepNeedMinutes = night.needMinutes;
  }

  // HRV: today's value vs the baseline median.
  double? hrvScore;
  double? hrvBaseline;
  if (row.hrvRmssdMs != null) {
    final baseline =
        _baselineValues(days, date, (d) => d.hrvRmssdMs);
    if (baseline != null) {
      hrvBaseline = medianOf(baseline);
      hrvScore = scoreHrvComponent(row.hrvRmssdMs!, hrvBaseline);
    }
  }

  // Resting HR: today's value vs the baseline median, inverted.
  double? restingHrScore;
  double? restingHrBaseline;
  if (row.restingHrBpm != null) {
    final baseline = _baselineValues(
        days, date, (d) => d.restingHrBpm?.toDouble());
    if (baseline != null) {
      restingHrBaseline = medianOf(baseline);
      restingHrScore =
          scoreRestingHrComponent(row.restingHrBpm!.toDouble(), restingHrBaseline);
    }
  }

  var weightedSum = 0.0;
  var weightTotal = 0;
  if (sleepScore != null) {
    weightedSum += weightSleep * sleepScore;
    weightTotal += weightSleep;
  }
  if (hrvScore != null) {
    weightedSum += weightHrv * hrvScore;
    weightTotal += weightHrv;
  }
  if (restingHrScore != null) {
    weightedSum += weightRestingHr * restingHrScore;
    weightTotal += weightRestingHr;
  }
  if (weightTotal == 0) return null;

  return DailyScoreComputation(
    date: date,
    sleepScore: sleepScore,
    hrvScore: hrvScore,
    restingHrScore: restingHrScore,
    dailyExact: weightedSum / weightTotal,
    asleepMinutes: asleepMinutes,
    sleepNeedMinutes: sleepNeedMinutes,
    hrvMs: hrvScore == null ? null : row.hrvRmssdMs,
    hrvBaselineMs: hrvBaseline,
    restingHrBpm: restingHrScore == null ? null : row.restingHrBpm,
    restingHrBaselineBpm: restingHrBaseline,
  );
}

/// Drives score computation over a [HealthHistoryStore]: computes
/// every stored day that does not yet hold a score and whose
/// inputs now exist, skipping any day already scored — write-once
/// for automatic runs, enforced again inside
/// [HealthHistoryStore.persistScore]. The engine NEVER rewrites a
/// scored day and NEVER calls [HealthHistoryStore.replaceScore]:
/// re-scoring a scored day is the refresh button's job alone, via
/// `DailyScoreRefresher`. Which days a run may score is bounded by
/// the caller's `beforeDate` cutoff (see the TODAY RULE in the
/// file header).
class DailyScoreEngine {
  final HealthHistoryStore store;

  /// Server-sync hook (Oct 28, 2026): when wired, every score this
  /// engine persists is queued for upload as an
  /// [dailyScoreSourceAuto] record — the queue/flush live in
  /// [DailyScoreSync], which the production call sites pass in
  /// (the post-capture run in `health_history_sync.dart`, Home,
  /// the score history screen, the background runner). Null in
  /// tests and in any caller that does not wire sync: scoring is
  /// then exactly the pre-sync behavior. Queueing is
  /// fire-and-forget from here — it never delays or fails a
  /// scoring run (the standing instant-paint rule).
  final DailyScoreSync? scoreSync;

  /// Clock for the persisted score's `computedAt` stamp (the same
  /// value the sync payload carries). Injectable for tests.
  final DateTime Function() _now;

  DailyScoreEngine({
    HealthHistoryStore? store,
    this.scoreSync,
    DateTime Function()? now,
  })  : store = store ?? HealthHistoryStore.instance,
        _now = now ?? DateTime.now;

  /// Computes and persists scores for all missing days, oldest
  /// first. Returns how many days were newly scored. Never throws —
  /// a scoring failure must never break a screen or a capture.
  ///
  /// [beforeDate] is an EXCLUSIVE cutoff ("YYYY-MM-DD"): days on
  /// or after it are never scored by this run. Per the TODAY RULE
  /// in the file header, every trigger except the post-capture run
  /// passes today here, so only the post-capture run scores today.
  ///
  /// [completeOnlyDate] is the completeness gate (founder
  /// amendment, Oct 20, 2026): the day named here — the current
  /// day, passed by the post-capture run — is scored ONLY when
  /// its computation [DailyScoreComputation.hasAllComponents]. An
  /// incomplete gated day is skipped (left pending for a later
  /// capture to retry); the gate applies to that one day only and
  /// never blocks any other day in the same run. Days after the
  /// gated day are past the day boundary by definition of the
  /// caller naming its own today, and score under the fallback:
  /// whatever the store holds.
  Future<int> computeMissingScores({
    String? beforeDate,
    String? completeOnlyDate,
  }) async {
    try {
      final days = await store.readAll();
      var written = 0;
      for (final date in days.keys) {
        if (beforeDate != null && date.compareTo(beforeDate) >= 0) {
          continue; // cutoff: this run must not score these days
        }
        if (days[date]!.dailyScore != null) continue; // write-once
        final computation = computeDailyScore(days, date);
        if (computation == null) continue;
        if (date == completeOnlyDate && !computation.hasAllComponents) {
          continue; // gate: today stays pending until complete
        }
        // One computedAt for the whole persist: the store's
        // score metadata and the sync payload must carry the
        // SAME stamp, or the hydration conflict rule would be
        // comparing two different clocks for one record.
        final computedAt = _now().millisecondsSinceEpoch;
        final ok = await store.persistScore(
          date,
          dailyScore: computation.dailyScore,
          scoreSleep: computation.sleepScoreRounded,
          scoreHrv: computation.hrvScoreRounded,
          scoreRestingHr: computation.restingHrScoreRounded,
          scoreSource: dailyScoreSourceAuto,
          scoreComputedAt: computedAt,
          scoreAlgorithmVersion: dailyScoreAlgorithmVersion,
        );
        if (ok) {
          written++;
          // Sync hook: queue the JUST-PERSISTED computation for
          // upload. Fire-and-forget by design (see [scoreSync]);
          // a queue/flush failure leaves the record queued for
          // the next trigger and never reaches this run.
          scoreSync?.queueComputation(
            computation,
            source: dailyScoreSourceAuto,
            computedAt: computedAt,
          );
        }
      }
      return written;
    } catch (_) {
      return 0;
    }
  }
}
