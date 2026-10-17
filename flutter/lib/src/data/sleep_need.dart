/// R70 — Personal Sleep Need (founder input Oct 16, 2026, from
/// Fitbit's Sleep Balance): a need estimate derived from the user's
/// OWN sleep history in the HealthHistoryStore — never a generic
/// 8-hour rule.
///
/// FORMULA (all windows count NIGHTS WITH DATA; a night with no
/// record is excluded, never treated as 0 sleep — the founder zero
/// rule; sleep values ≤ 0 are likewise excluded on the way in):
///
/// - `baseNeed` = 75th percentile (nearest-rank) of nightly
///   sleepMinutes over the most recent 28 nights with data — his
///   demonstrated adequate nights. Requires ≥ 7 nights with data
///   in total, else the estimate is null (honest insufficient-data
///   state, no number shown).
/// - `recentDebt` = Σ over the most recent 7 nights with data of
///   max(0, baseNeed − asleep). A long night earns NO credit here.
/// - `tonightNeed` = baseNeed + min(recentDebt, 120). The 120-minute
///   cap keeps one bad week from demanding an impossible night.
///
/// RELATIONSHIP TO THE EXISTING DEBT DEFINITION (documented
/// deviation): the app's pre-existing sleep debt — native
/// `FitbitViewModel.calculateDebtAtDate`, ported as
/// `computeSleepDebtMins` in sleep_screen.dart and reused by the
/// Health Coach context builder (R55) — measures debt against a
/// FIXED 480-minute (8h) target over a rolling window of the last
/// 10 nights, with surplus over target earning up to 1.5h of credit
/// per night. Sleep Need keeps that definition's CORE (debt is a
/// sum of per-night shortfalls against a target, over the most
/// recent nights with data, floored at zero) and deviates in
/// exactly the three ways the founder's personal-need spec
/// requires: (1) the target is the personal `baseNeed`, not the
/// generic 480 — a generic 8-hour rule is explicitly forbidden for
/// this feature; (2) the debt window is the most recent 7 nights
/// with data, not the rolling 10; (3) no surplus credit — a long
/// night does not cancel a short one in this estimate. The hero
/// Deficit on the Sleep screen keeps using the native definition
/// unchanged; the two numbers answer different questions (native
/// debt = shortfall vs 8h; Sleep Need debt = shortfall vs his own
/// usual need) and are labeled as such.
///
/// This file is pure: input is a `date ("YYYY-MM-DD") → sleep
/// minutes` map (the store's sleepMinutes, or a union map), output
/// is plain values. The Daily Score workstream consumes
/// [evaluateSleepNight] / [evaluateRecentNights]:
/// `asleep / tonightNeed` per night.

/// Minimum nights with data before any estimate exists.
const int sleepNeedMinNights = 7;

/// Nights with data that feed `baseNeed` (most recent).
const int sleepNeedBaseWindowNights = 28;

/// Nights with data that feed `recentDebt` (most recent).
const int sleepNeedDebtWindowNights = 7;

/// Cap on how much recent debt may inflate one night's need.
const int sleepNeedDebtCapMinutes = 120;

/// Balance tolerance for the plain status descriptors: within
/// ±15 minutes of need reads as "Near need".
const int sleepNeedNearToleranceMinutes = 15;

/// A personal Sleep Need estimate as of a point in history.
class SleepNeedEstimate {
  /// 75th percentile of the most recent 28 nights with data.
  final int baseNeedMinutes;

  /// Σ shortfall vs [baseNeedMinutes] over the most recent 7
  /// nights with data (uncapped; the cap applies to tonightNeed).
  final int recentDebtMinutes;

  /// baseNeed + min(recentDebt, 120).
  final int tonightNeedMinutes;

  /// How many nights with data fed the base / debt windows
  /// (transparency for tests and empty-state copy decisions).
  final int baseNightsUsed;
  final int debtNightsUsed;

  const SleepNeedEstimate({
    required this.baseNeedMinutes,
    required this.recentDebtMinutes,
    required this.tonightNeedMinutes,
    required this.baseNightsUsed,
    required this.debtNightsUsed,
  });
}

/// One night's evaluation against the need that applied TO that
/// night: the estimate computed from the nights BEFORE it (a night
/// never inflates or deflates its own need). This is the shape
/// the Daily Score workstream consumes (`asleep / tonightNeed`).
class SleepNightEvaluation {
  final String date; // "YYYY-MM-DD"
  final int asleepMinutes;

  /// The per-night need (that night's `tonightNeed`), or null when
  /// the nights before it are too few to estimate from.
  final int? needMinutes;

  /// asleep − need; null when [needMinutes] is null.
  final int? balanceMinutes;

  const SleepNightEvaluation({
    required this.date,
    required this.asleepMinutes,
    required this.needMinutes,
    required this.balanceMinutes,
  });

  /// Plain status descriptor — trend language only, no borrowed
  /// rating words, no medical claim. Null when there is no need
  /// estimate for the night.
  String? get statusLabel {
    final b = balanceMinutes;
    if (b == null) return null;
    if (b < -sleepNeedNearToleranceMinutes) return 'Below need';
    if (b > sleepNeedNearToleranceMinutes) return 'Above need';
    return 'Near need';
  }

  /// asleep / need for the night (Daily Score input); null when
  /// there is no need estimate.
  double? get asleepRatio =>
      needMinutes == null ? null : asleepMinutes / needMinutes!;
}

/// The nights with real data in [sleepByDate], ascending by date:
/// values > 0 only (a 0 is a failed read, never a night of sleep),
/// optionally restricted to dates ≤ [upToDate] / < [beforeDate].
List<({String date, int mins})> _nightsWithData(
  Map<String, int> sleepByDate, {
  String? upToDate,
  String? beforeDate,
}) {
  final dates = sleepByDate.keys.where((d) {
    if (sleepByDate[d]! <= 0) return false;
    if (upToDate != null && d.compareTo(upToDate) > 0) return false;
    if (beforeDate != null && d.compareTo(beforeDate) >= 0) return false;
    return true;
  }).toList()
    ..sort();
  return [for (final d in dates) (date: d, mins: sleepByDate[d]!)];
}

/// Nearest-rank 75th percentile of [values] (non-empty).
int _percentile75(List<int> values) {
  final sorted = [...values]..sort();
  var rank = (0.75 * sorted.length).ceil();
  if (rank < 1) rank = 1;
  if (rank > sorted.length) rank = sorted.length;
  return sorted[rank - 1];
}

/// The current personal Sleep Need estimate from [sleepByDate],
/// using nights at or before [asOfDate] when given. Null when
/// fewer than [sleepNeedMinNights] nights with data exist — the
/// honest insufficient-data state.
SleepNeedEstimate? estimateSleepNeed(
  Map<String, int> sleepByDate, {
  String? asOfDate,
}) {
  final nights = _nightsWithData(sleepByDate, upToDate: asOfDate);
  if (nights.length < sleepNeedMinNights) return null;

  final baseWindow = nights.length > sleepNeedBaseWindowNights
      ? nights.sublist(nights.length - sleepNeedBaseWindowNights)
      : nights;
  final base = _percentile75([for (final n in baseWindow) n.mins]);

  final debtWindow = nights.length > sleepNeedDebtWindowNights
      ? nights.sublist(nights.length - sleepNeedDebtWindowNights)
      : nights;
  var debt = 0;
  for (final n in debtWindow) {
    if (n.mins < base) debt += base - n.mins;
  }
  final capped = debt > sleepNeedDebtCapMinutes ? sleepNeedDebtCapMinutes : debt;
  return SleepNeedEstimate(
    baseNeedMinutes: base,
    recentDebtMinutes: debt,
    tonightNeedMinutes: base + capped,
    baseNightsUsed: baseWindow.length,
    debtNightsUsed: debtWindow.length,
  );
}

/// Evaluates the night of [date] against the need computed from
/// the nights BEFORE it. Null when [date] itself has no real
/// sleep data; the evaluation's need is null when the prior
/// history is too sparse to estimate from.
SleepNightEvaluation? evaluateSleepNight(
  Map<String, int> sleepByDate,
  String date,
) {
  final asleep = sleepByDate[date];
  if (asleep == null || asleep <= 0) return null;
  final prior = _nightsWithData(sleepByDate, beforeDate: date);
  int? need;
  if (prior.length >= sleepNeedMinNights) {
    // Rebuild the estimate over the prior nights only.
    final priorMap = {for (final n in prior) n.date: n.mins};
    need = estimateSleepNeed(priorMap)?.tonightNeedMinutes;
  }
  return SleepNightEvaluation(
    date: date,
    asleepMinutes: asleep,
    needMinutes: need,
    balanceMinutes: need == null ? null : asleep - need,
  );
}

/// Evaluations for the most recent [count] nights with data,
/// chronological (oldest → newest). Nights whose prior history is
/// too sparse carry a null need/balance rather than a fake one.
List<SleepNightEvaluation> evaluateRecentNights(
  Map<String, int> sleepByDate, {
  int count = 7,
}) {
  final nights = _nightsWithData(sleepByDate);
  final recent =
      nights.length > count ? nights.sublist(nights.length - count) : nights;
  return [
    for (final n in recent)
      evaluateSleepNight(sleepByDate, n.date)!,
  ];
}
