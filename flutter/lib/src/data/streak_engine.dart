import 'package:flutter/foundation.dart';

import 'tabs_day.dart';

/// The streak engine (Lab streak package Nov 4, 2026; release
/// line VC 100115). Pure logic — the day rule and the monthly
/// Restore; persistence and sync live in streak_store.dart.
///
/// The Tabs streak is an APP-OPEN streak: consecutive local calendar
/// days the app was opened. The governing semantics are the legacy
/// native rule (`NotelPreferences.updateStreak()`): first open = 1,
/// same day = unchanged, yesterday = +1, a missed day = reset to 1,
/// best = max(best, current). The server profile is the ONE
/// authoritative record: it holds the two counters
/// (`currentStreak` / `bestStreak`) AND this engine's day-level
/// state (`streakState`) — two ints alone cannot mark WHICH day a
/// save restored, so the counters are derived from the day record
/// and both are stored server-side.
///
/// Founder's save rule (Nov 4, 2026): everyone gets ONE streak save
/// per calendar month; a missed day consumes it automatically and
/// the streak survives; the saved day is marked as restored.
///
/// STATE V2 (streak upgrade, Nov 18, 2026; design SIGNED round 3 —
/// STAGE-LOG.md D1–D14/A1–A10/B1–B2 + VERA-DESIGN-REVIEW.md): the
/// counted-day event is Daily Summary completion, not app-open.
/// App-open runs rollover SETTLEMENT only ([settle]); the freeze
/// inventory (earned / purchased / monthly grant) bridges missed
/// days chronologically, purchased first; a freeze-free month with
/// the streak alive earns an extra freeze under the A1 cap
/// accounting (total available cover vs cap 2, or 3 while a
/// purchased freeze is held). All day keys derive from the Tabs
/// anchor ([tabsDayAnchor] — the shared Tabs-day definition in
/// tabs_day.dart: the legacy 04:00 rule for instants before the
/// persisted cutover instant, calendar-midnight from it on).
///
/// Named interpretations (STREAK_SPEC.md, founder can flip any):
/// - No rollover: the grant is derived per month — a month has a
///   save iff no save was consumed for a missed day in that month.
/// - The save is drawn from the grant of the month containing the
///   MISSED day (a Jan 31 miss found on Feb 1 is paid by January).
/// - One save covers exactly one missed day: a gap of 2+ missed days
///   breaks the streak and consumes NOTHING.
/// - Consumption is automatic, evaluated at the app-open point
///   (Home load), never a manual action.
/// - All dates are device-local calendar days.
///
/// This file is pure logic: no I/O, no clocks except the `now`
/// passed in. Persistence lives in streak_store.dart (the Tabs-day
/// cutover's persistence lives in tabs_day.dart; the derivations
/// here only read its loaded in-memory value).

/// One calendar day in local time, as an ISO `yyyy-MM-dd` string.
String streakDayStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The `yyyy-MM` grant key for the month containing [d].
String streakMonthKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}';

/// The Tabs-day anchor (design A7, streak upgrade Nov 18, 2026):
/// the ONE day derivation every streak read and write path uses.
/// Delegates to the shared Tabs-day definition (tabs_day.dart):
/// before the persisted cutover instant the anchor is [now]
/// shifted back 4 hours (a Tabs day started at 04:00 local, so
/// between 00:00–03:59 the anchor still belongs to the previous
/// calendar day — the still-open Tabs day); from the cutover on
/// the Tabs day is the calendar day and the anchor is [now]
/// itself. The Tabs day a wall-clock moment belongs to is the
/// calendar day of its anchor.
DateTime tabsDayAnchor(DateTime now) => TabsDayBoundary.instance.anchor(now);

/// The Tabs day (ISO `yyyy-MM-dd`) containing [now], via the
/// shared Tabs-day definition (tabs_day.dart). All day keys in
/// the v2 engine derive from this, never from raw wall-clock
/// `now` formatted directly.
String tabsDayStr(DateTime now) => TabsDayBoundary.instance.key(now);

/// The `yyyy-MM` key of the month containing an ISO day string.
String _monthOfDay(String day) => day.substring(0, 7);

/// Adds [n] months to a `yyyy-MM` key.
String _addMonthsToKey(String key, int n) {
  final y = int.parse(key.substring(0, 4));
  final m = int.parse(key.substring(5, 7));
  final total = y * 12 + (m - 1) + n;
  final ny = total ~/ 12;
  final nm = total % 12 + 1;
  return '${ny.toString().padLeft(4, '0')}-${nm.toString().padLeft(2, '0')}';
}

DateTime _parseDay(String s) => DateTime.parse(s);

/// Whole days from [a] to [b] (b − a), both ISO day strings, computed
/// on UTC midnights so DST never skews a calendar-day difference.
int streakDaysBetween(String a, String b) {
  final da = _parseDay(a);
  final db = _parseDay(b);
  final ua = DateTime.utc(da.year, da.month, da.day);
  final ub = DateTime.utc(db.year, db.month, db.day);
  return ub.difference(ua).inDays;
}

String _addDays(String day, int n) {
  final d = _parseDay(day);
  final u = DateTime.utc(d.year, d.month, d.day).add(Duration(days: n));
  return streakDayStr(u);
}

/// Immutable streak state. [countedDays] holds every day that counts
/// toward a streak (opened days ∪ restored days); [restoredDays] is
/// the subset bridged by a save. [seededBest] is the best-streak
/// counter carried in from the profile pull — day-level history from
/// before the engine existed is not reconstructable, so the seeded
/// best survives as a floor even when no local run reaches it.
@immutable
class StreakState {
  final bool seeded;

  /// The pull counters this state was last seeded/merged with.
  /// A later pull carrying a DIFFERENT pair re-seeds (the server
  /// truth moved — another client, an account's real numbers); the
  /// same pair never re-seeds, so local opens keep growing the run.
  final int seededCurrent;
  final int seededBest;
  final Set<String> countedDays;
  final Set<String> restoredDays;

  /// `yyyy-MM` keys (of the missed day's month) whose grant is used.
  final Set<String> consumedSaveMonths;

  /// The last day an evaluation ran (ISO), or null before the first.
  final String? lastEvaluatedDay;

  // ── State v2 (streak upgrade, design D4/A1/A4/B1) ──────────────

  /// Earned freezes held (0..1): granted when a full calendar month
  /// closes with zero attributed freeze consumption while the streak
  /// was alive in it.
  final int earnedFreezes;

  /// Purchased freezes held (0..1): server-verified inventory (the
  /// server profile column is authoritative; see streak_store's A2
  /// field-level merge).
  final int purchasedFreezes;

  /// An earned freeze is due but paused: it waits (at most one) for
  /// BOTH the earned slot and a total-cover slot to free (A1).
  final bool earnedPending;

  /// The `yyyy-MM` the accrual counters belong to. Months before
  /// this have been close-evaluated; this month is still open.
  /// Empty only on never-migrated in-memory states; [settle]
  /// anchors it to the current month without closing anything.
  final String accrualMonth;

  /// Every month with >= 1 attributed freeze consumption
  /// (attribution = the missed day's month, A5). The source of
  /// truth for spoils; pruned to the trailing 24 months, and only
  /// months already closed are ever pruned (B1/Vera round 3).
  final Set<String> spoiledMonths;

  /// Consecutive full calendar months that closed freeze-free with
  /// the streak alive. Pauses across inactive months; never
  /// decrements (B1).
  final int freezeFreeMonthsCompleted;

  /// Days whose Daily Summary actually COMPLETED (P0 fix, Nov 18,
  /// 2026): written only by the completion path
  /// (StreakStore.recordSummaryComplete). This is the record the
  /// adoption-time open-day revalidation checks — a counted or
  /// restored mark for the CURRENT OPEN Tabs day with no entry
  /// here is a legacy app-open artifact (v1 counted at app open)
  /// and is stripped at adoption; closed days are never touched.
  /// Additive + JSON-tolerant: states written before this field
  /// existed deserialize with it empty.
  final Set<String> summaryCompletedDays;

  /// Days whose counted/restored marks revalidation STRIPPED
  /// (streak-bugs fix, Nov 19, 2026): a day counted under legacy
  /// app-open semantics with no summary completion and no freeze
  /// cover. The tombstone is what makes settlement deterministic
  /// across sync: an adoption merge must never resurrect a
  /// tombstoned day from a stale server blob (the Nov 18
  /// flip-flop — strict evaluation broke the run, then the
  /// union-merge restored the day and the 27 was pushed back).
  /// A day leaves this set by genuinely completing its
  /// summary ([completeDay]), by the dev Restore Streak path —
  /// both also record it in [summaryCompletedDays] — or by a
  /// settlement freeze bridge covering it (the day joins
  /// [restoredDays]; A1 fix, Nov 19, 2026). Additive +
  /// JSON-tolerant: pre-fix blobs deserialize with it empty.
  final Set<String> invalidatedDays;

  const StreakState({
    this.seeded = false,
    this.seededCurrent = 0,
    this.seededBest = 0,
    this.countedDays = const {},
    this.restoredDays = const {},
    this.consumedSaveMonths = const {},
    this.lastEvaluatedDay,
    this.earnedFreezes = 0,
    this.purchasedFreezes = 0,
    this.earnedPending = false,
    this.accrualMonth = '',
    this.spoiledMonths = const {},
    this.freezeFreeMonthsCompleted = 0,
    this.summaryCompletedDays = const {},
    this.invalidatedDays = const {},
  });

  /// Whether a freeze of any kind was consumed with attribution to
  /// the accrual month (B1: DERIVED from [spoiledMonths], never a
  /// stored bool that could go stale across a rollover).
  bool get freezeUsedInAccrualMonth => spoiledMonths.contains(accrualMonth);

  static const empty = StreakState();

  /// Lab-local history worth protecting from a re-seed: any restored
  /// day or consumed save exists only in this record.
  bool get hasProtectedHistory =>
      restoredDays.isNotEmpty ||
      consumedSaveMonths.isNotEmpty ||
      spoiledMonths.isNotEmpty ||
      earnedFreezes > 0 ||
      purchasedFreezes > 0 ||
      earnedPending ||
      freezeFreeMonthsCompleted > 0;

  StreakState copyWith({
    bool? seeded,
    int? seededCurrent,
    int? seededBest,
    Set<String>? countedDays,
    Set<String>? restoredDays,
    Set<String>? consumedSaveMonths,
    String? lastEvaluatedDay,
    int? earnedFreezes,
    int? purchasedFreezes,
    bool? earnedPending,
    String? accrualMonth,
    Set<String>? spoiledMonths,
    int? freezeFreeMonthsCompleted,
    Set<String>? summaryCompletedDays,
    Set<String>? invalidatedDays,
  }) {
    return StreakState(
      seeded: seeded ?? this.seeded,
      seededCurrent: seededCurrent ?? this.seededCurrent,
      seededBest: seededBest ?? this.seededBest,
      countedDays: countedDays ?? this.countedDays,
      restoredDays: restoredDays ?? this.restoredDays,
      consumedSaveMonths: consumedSaveMonths ?? this.consumedSaveMonths,
      lastEvaluatedDay: lastEvaluatedDay ?? this.lastEvaluatedDay,
      earnedFreezes: earnedFreezes ?? this.earnedFreezes,
      purchasedFreezes: purchasedFreezes ?? this.purchasedFreezes,
      earnedPending: earnedPending ?? this.earnedPending,
      accrualMonth: accrualMonth ?? this.accrualMonth,
      spoiledMonths: spoiledMonths ?? this.spoiledMonths,
      freezeFreeMonthsCompleted:
          freezeFreeMonthsCompleted ?? this.freezeFreeMonthsCompleted,
      summaryCompletedDays: summaryCompletedDays ?? this.summaryCompletedDays,
      invalidatedDays: invalidatedDays ?? this.invalidatedDays,
    );
  }

  Map<String, dynamic> toJson() => {
    'v': 2,
    'seeded': seeded,
    'seededCurrent': seededCurrent,
    'seededBest': seededBest,
    'countedDays': countedDays.toList()..sort(),
    'restoredDays': restoredDays.toList()..sort(),
    'consumedSaveMonths': consumedSaveMonths.toList()..sort(),
    'lastEvaluatedDay': lastEvaluatedDay,
    'earnedFreezes': earnedFreezes,
    'purchasedFreezes': purchasedFreezes,
    'earnedPending': earnedPending,
    'accrualMonth': accrualMonth,
    'spoiledMonths': spoiledMonths.toList()..sort(),
    'freezeFreeMonthsCompleted': freezeFreeMonthsCompleted,
    'summaryCompletedDays': summaryCompletedDays.toList()..sort(),
    'invalidatedDays': invalidatedDays.toList()..sort(),
  };

  /// Parses a v2 blob, or migrates a v1 blob losslessly (A4+B1):
  /// the day-level record and counters carry over untouched;
  /// `freezeFreeMonthsCompleted` := 0 (NEVER inferred — an absent
  /// consumed-month key also means "inactive" or "before the
  /// account existed"); `spoiledMonths` := [consumedSaveMonths]
  /// (those months had a monthly-grant consumption by definition);
  /// `accrualMonth` := the current Tabs month of [migrationNow]
  /// (defaults to the wall clock — the store loads at app-open, so
  /// that IS the current month; tests pass it explicitly). The A4
  /// derivation `freezeUsedInAccrualMonth =
  /// consumedSaveMonths.contains(current month)` falls out of the
  /// spoiled-months seed + the derived getter, so a pre-upgrade
  /// Restore use this month correctly spoils this month's accrual.
  factory StreakState.fromJson(
    Map<String, dynamic> json, {
    DateTime? migrationNow,
  }) {
    Set<String> setOf(String key) {
      final v = json[key];
      if (v is! List) return const {};
      return v.whereType<String>().toSet();
    }

    int intOf(String key) {
      final v = json[key];
      return v is int ? v : 0;
    }

    int heldOf(String key) => intOf(key).clamp(0, 1);

    final last = json['lastEvaluatedDay'];
    final consumed = setOf('consumedSaveMonths');
    final version = json['v'];
    final isV2 = version is int && version >= 2;
    final accrualRaw = json['accrualMonth'];
    return StreakState(
      seeded: json['seeded'] == true,
      seededCurrent: intOf('seededCurrent'),
      seededBest: intOf('seededBest'),
      countedDays: setOf('countedDays'),
      restoredDays: setOf('restoredDays'),
      consumedSaveMonths: consumed,
      lastEvaluatedDay: last is String ? last : null,
      earnedFreezes: isV2 ? heldOf('earnedFreezes') : 0,
      purchasedFreezes: isV2 ? heldOf('purchasedFreezes') : 0,
      earnedPending: isV2 ? json['earnedPending'] == true : false,
      accrualMonth: isV2
          ? (accrualRaw is String ? accrualRaw : '')
          : _monthOfDay(tabsDayStr(migrationNow ?? DateTime.now())),
      spoiledMonths: isV2 ? setOf('spoiledMonths') : Set<String>.of(consumed),
      freezeFreeMonthsCompleted: isV2 ? intOf('freezeFreeMonthsCompleted') : 0,
      // P0 fix: absent on every pre-fix blob (v1 AND shipped v2) —
      // setOf returns {} for a missing key, which is exactly the
      // legacy default the open-day revalidation relies on.
      summaryCompletedDays: setOf('summaryCompletedDays'),
      // Streak-bugs fix: absent on every pre-fix blob — {} is the
      // correct default (nothing tombstoned yet).
      invalidatedDays: setOf('invalidatedDays'),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is StreakState &&
      other.seeded == seeded &&
      other.seededCurrent == seededCurrent &&
      other.seededBest == seededBest &&
      setEquals(other.countedDays, countedDays) &&
      setEquals(other.restoredDays, restoredDays) &&
      setEquals(other.consumedSaveMonths, consumedSaveMonths) &&
      other.lastEvaluatedDay == lastEvaluatedDay &&
      other.earnedFreezes == earnedFreezes &&
      other.purchasedFreezes == purchasedFreezes &&
      other.earnedPending == earnedPending &&
      other.accrualMonth == accrualMonth &&
      setEquals(other.spoiledMonths, spoiledMonths) &&
      other.freezeFreeMonthsCompleted == freezeFreeMonthsCompleted &&
      setEquals(other.summaryCompletedDays, summaryCompletedDays) &&
      setEquals(other.invalidatedDays, invalidatedDays);

  @override
  int get hashCode => Object.hash(
    seeded,
    seededCurrent,
    seededBest,
    Object.hashAllUnordered(countedDays),
    Object.hashAllUnordered(restoredDays),
    Object.hashAllUnordered(consumedSaveMonths),
    lastEvaluatedDay,
    earnedFreezes,
    purchasedFreezes,
    earnedPending,
    accrualMonth,
    Object.hashAllUnordered(spoiledMonths),
    freezeFreeMonthsCompleted,
    Object.hashAllUnordered(summaryCompletedDays),
    Object.hashAllUnordered(invalidatedDays),
  );
}

/// Open-day revalidation (P0 fix, Defect A1): a counted/restored
/// mark for the CURRENT OPEN Tabs day [openTabsDay] that has no
/// summary-completion record is a legacy app-open artifact — v1
/// counted the day at app open, and adoption carried that mark
/// into v2 wholesale. Strip ONLY that day's marks; closed days
/// are grandfathered untouched, and a day with a completion
/// record keeps its marks. Pure; returns [s] unchanged when there
/// is nothing to strip.
StreakState revalidateOpenDay(StreakState s, String openTabsDay) {
  if (s.summaryCompletedDays.contains(openTabsDay)) return s;
  if (!s.countedDays.contains(openTabsDay) &&
      !s.restoredDays.contains(openTabsDay)) {
    return s;
  }
  return s.copyWith(
    countedDays: Set<String>.of(s.countedDays)..remove(openTabsDay),
    restoredDays: Set<String>.of(s.restoredDays)..remove(openTabsDay),
    // Streak-bugs fix: tombstone the stripped day so no later
    // adoption/union-merge can resurrect it from a stale blob.
    invalidatedDays: {...s.invalidatedDays, openTabsDay},
  );
}

/// Just-closed revalidation (streak-bugs fix, Nov 19, 2026): the
/// day that was the OPEN Tabs day at the state's last evaluation
/// ([StreakState.lastEvaluatedDay]) has now closed. If it is
/// counted with no summary completion and no freeze cover
/// (not in [StreakState.restoredDays]), its counted mark is a
/// legacy app-open artifact that arrived (or survived) after the
/// open-day revalidation ran — strip and tombstone it, exactly
/// as the open-day rule would have. The subsequent settlement
/// then treats the day as missed: gap bridging may still cover
/// it with a freeze (it then renders as a freeze day), otherwise
/// the run breaks. Days that closed BEFORE the last evaluation
/// are not touched — closed-day grandfathering (the P0 doctrine)
/// still governs history the engine never evaluated while open.
StreakState revalidateJustClosedDay(StreakState s, String todayTabsDay) {
  final last = s.lastEvaluatedDay;
  if (last == null || last.compareTo(todayTabsDay) >= 0) return s;
  // ONLY the day that just closed — the one that was open at the
  // last evaluation, i.e. yesterday relative to this evaluation.
  // An older stamp means several days closed since the last
  // evaluation; that head day is part of a multi-day gap, which
  // settlement's ordinary bridging/breaking governs (a pinned
  // store test bridges exactly such a gap with the monthly
  // grant), not this revalidation.
  if (last != _addDays(todayTabsDay, -1)) return s;
  if (!s.countedDays.contains(last)) return s;
  if (s.summaryCompletedDays.contains(last)) return s;
  if (s.restoredDays.contains(last)) return s;
  // Cover guard (A2 contract): if any freeze COULD cover the day
  // — the missed day's monthly grant still unused, or an earned
  // or purchased freeze held — the day has a legitimate basis and
  // stays counted: settlement's bridging governs GAPS, and a
  // counted day is not a gap (stripping it here would manufacture
  // a gap and burn the very freeze inventory the A2 merge just
  // adopted). Revalidation strips only a day with no completion,
  // no freeze cover, and no possible cover — the founder's
  // Nov 18 exactly (grant consumed by Nov 7, earned 0, purchased 0).
  if (!s.consumedSaveMonths.contains(_monthOfDay(last)) ||
      s.earnedFreezes > 0 ||
      s.purchasedFreezes > 0) {
    return s;
  }
  return s.copyWith(
    countedDays: Set<String>.of(s.countedDays)..remove(last),
    invalidatedDays: {...s.invalidatedDays, last},
  );
}

/// Dev "Restore Streak" (founder ask, Nov 19, 2026): mark the
/// most recent broken day as a NORMAL completed day — the day
/// right after a counted day, itself uncounted, whose next day
/// is counted or is the current open Tabs day (a single-day
/// break a one-day repair can actually reconnect). The day joins
/// [StreakState.countedDays] AND [StreakState.summaryCompletedDays]
/// (it counts as if the summary had completed — never a freeze
/// day: [StreakState.restoredDays] is untouched and no freeze is
/// consumed or granted) and any tombstone for it clears. Returns
/// the state unchanged with a null day when there is no such
/// single-day break (run alive, gap of 2+, or no counted days) —
/// the caller's safe no-op.
({StreakState state, String? restoredDay}) restoreBrokenDay(
  StreakState s, {
  required String todayTabsDay,
}) {
  if (s.countedDays.isEmpty) return (state: s, restoredDay: null);
  final sorted = s.countedDays.toList()..sort();
  final earliest = sorted.first;
  var d = _addDays(todayTabsDay, -1);
  while (d.compareTo(earliest) >= 0) {
    final prev = _addDays(d, -1);
    final next = _addDays(d, 1);
    if (!s.countedDays.contains(d) &&
        s.countedDays.contains(prev) &&
        (s.countedDays.contains(next) || next == todayTabsDay)) {
      final nextState = s.copyWith(
        countedDays: {...s.countedDays, d},
        summaryCompletedDays: {...s.summaryCompletedDays, d},
        invalidatedDays: Set<String>.of(s.invalidatedDays)..remove(d),
      );
      return (state: nextState, restoredDay: d);
    }
    d = _addDays(d, -1);
  }
  return (state: s, restoredDay: null);
}

/// The consecutive-day run ending on [endDay] within [days], as
/// (length, startDay). Length 0 when [endDay] is not in [days].
({int length, String? start}) _runEndingAt(Set<String> days, String endDay) {
  if (!days.contains(endDay)) return (length: 0, start: null);
  var length = 0;
  var cursor = endDay;
  while (days.contains(cursor)) {
    length++;
    cursor = _addDays(cursor, -1);
  }
  return (length: length, start: _addDays(endDay, -(length - 1)));
}

/// The longest consecutive-day run in [days] (the most recent one on
/// ties), as (length, start, end). All null/0 when empty.
({int length, String? start, String? end}) _longestRun(Set<String> days) {
  if (days.isEmpty) return (length: 0, start: null, end: null);
  final sorted = days.toList()..sort();
  var bestLength = 1;
  var bestStart = sorted.first;
  var bestEnd = sorted.first;
  var runStart = sorted.first;
  var runLength = 1;
  for (var i = 1; i < sorted.length; i++) {
    if (streakDaysBetween(sorted[i - 1], sorted[i]) == 1) {
      runLength++;
    } else {
      runStart = sorted[i];
      runLength = 1;
    }
    if (runLength >= bestLength) {
      bestLength = runLength;
      bestStart = runStart;
      bestEnd = sorted[i];
    }
  }
  return (length: bestLength, start: bestStart, end: bestEnd);
}

/// The current streak as of [now]: the run ending today, or the run
/// ending yesterday (still alive — a miss is only settled when the
/// next open evaluates it, the native rule). 0 when neither exists.
int streakCurrent(StreakState s, DateTime now) {
  final today = streakDayStr(now);
  if (s.countedDays.contains(today)) {
    return _runEndingAt(s.countedDays, today).length;
  }
  final yesterday = _addDays(today, -1);
  if (s.countedDays.contains(yesterday)) {
    return _runEndingAt(s.countedDays, yesterday).length;
  }
  return 0;
}

/// The best streak: the seeded profile floor vs the longest local
/// run, whichever is larger.
int streakBest(StreakState s) {
  final local = _longestRun(s.countedDays).length;
  return local > s.seededBest ? local : s.seededBest;
}

/// The date range of the best run, when it is locally known: the
/// longest local run reaches the best (this includes the seeded
/// current run when current == best at seed time — that run IS a
/// longest run). Null when the best predates day-level records.
({String start, String end})? streakBestRange(StreakState s) {
  final longest = _longestRun(s.countedDays);
  if (longest.length == 0 || longest.length < streakBest(s)) return null;
  return (start: longest.start!, end: longest.end!);
}

/// Saves left for the month containing [now]: 1, or 0 if that
/// month's grant was already consumed. Never more than 1 — an unused
/// save expires with its month (no rollover, nothing accumulates).
int streakSavesLeft(StreakState s, DateTime now) =>
    s.consumedSaveMonths.contains(streakMonthKey(now)) ? 0 : 1;

/// Total available cover (A1, Vera's D6 ruling): the monthly grant
/// while it is unused for the month containing [now]'s Tabs day,
/// plus held earned and purchased freezes. This — never held-only —
/// is the number the UI displays as freezes held (Juno ruling).
int totalAvailableCover(StreakState s, DateTime now) =>
    (s.consumedSaveMonths.contains(streakMonthKey(tabsDayAnchor(now)))
        ? 0
        : 1) +
    s.earnedFreezes +
    s.purchasedFreezes;

/// The freeze cap (A1): 2, or 3 while a purchased freeze is held.
/// (The monthly grant counts toward the cap while unused; the
/// purchased freeze is the +1.)
int streakCap(StreakState s) => 2 + (s.purchasedFreezes > 0 ? 1 : 0);

/// Cover against a specific month's grant, for accrual arithmetic
/// inside a settlement (the month whose grant is being counted is
/// not always the settlement's current month).
int _coverFor(
  Set<String> consumed,
  String grantMonth,
  int earned,
  int purchased,
) => (consumed.contains(grantMonth) ? 0 : 1) + earned + purchased;

/// The milestone ladder (stage log, coordinator ladder signed in
/// the design pass): [7, 14, 30, 60, 90, 180, 365], then +365 steps.
const List<int> streakMilestoneLadder = [7, 14, 30, 60, 90, 180, 365];

/// True when [count] is exactly a milestone rung.
bool isMilestone(int count) {
  if (count <= 0) return false;
  if (streakMilestoneLadder.contains(count)) return true;
  return count > 365 && count % 365 == 0;
}

/// The next milestone strictly above [count].
int nextMilestone(int count) {
  for (final rung in streakMilestoneLadder) {
    if (count < rung) return rung;
  }
  return 365 * (count ~/ 365 + 1);
}

/// Which freeze kind bridged a missed day (A5 draw order:
/// purchased, then earned, then the missed day's monthly grant).
enum FreezeKind { purchased, earned, monthly }

/// The outcome of a rollover settlement, beyond the state itself:
/// which days were bridged and by what, and whether the gap broke
/// the run (nothing consumed in that case — the shipped rule).
class StreakSettleResult {
  final StreakState state;
  final List<String> bridgedDays;
  final Map<String, FreezeKind> freezeUsedKinds;
  final bool brokeStreak;

  const StreakSettleResult({
    required this.state,
    required this.bridgedDays,
    required this.freezeUsedKinds,
    required this.brokeStreak,
  });
}

/// What the UI layer needs from one Daily Summary completion
/// (brief deliverable 1): the new run length, the days this
/// completion's settlement bridged (and with what), whether the
/// run broke and restarted at the summary day, whether an earned
/// freeze landed during the operation, and whether the new count
/// is a milestone.
class StreakCompletionResult {
  final int newCount;
  final List<String> bridgedDays;
  final Map<String, FreezeKind> freezeUsedKinds;
  final bool brokeStreak;
  final bool earnedLanded;
  final bool isMilestone;

  const StreakCompletionResult({
    required this.newCount,
    required this.bridgedDays,
    required this.freezeUsedKinds,
    required this.brokeStreak,
    required this.earnedLanded,
    required this.isMilestone,
  });
}

/// The settlement core, against an explicit Tabs [today] day
/// string. Shared by [settle] (today = the current Tabs day) and
/// [completeDay] (today = the summary's Tabs day).
StreakSettleResult _settleDetailed(StreakState s, String today) {
  var earned = s.earnedFreezes;
  var purchased = s.purchasedFreezes;
  var pending = s.earnedPending;
  var ffmc = s.freezeFreeMonthsCompleted;
  final counted = Set<String>.of(s.countedDays);
  final restored = Set<String>.of(s.restoredDays);
  final invalidated = Set<String>.of(s.invalidatedDays);
  var consumed = Set<String>.of(s.consumedSaveMonths);
  final spoiled = Set<String>.of(s.spoiledMonths);
  final bridged = <String>[];
  final kinds = <String, FreezeKind>{};
  var broke = false;

  // ── Gap bridging (D3/D5/A5): chronological, per missed day,
  // oldest first, drawn purchased → earned → the monthly grant OF
  // THE MONTH CONTAINING THAT MISSED DAY. All draws are computed
  // on working copies and committed only if the FULL gap bridges;
  // a gap that cannot fully bridge breaks the run and consumes
  // NOTHING (the shipped rule, generalized).
  String? lastCounted;
  for (final d in counted) {
    if (streakDaysBetween(d, today) > 0 &&
        (lastCounted == null || d.compareTo(lastCounted) > 0)) {
      lastCounted = d;
    }
  }
  if (lastCounted != null) {
    final gap = streakDaysBetween(lastCounted, today);
    if (gap > 1) {
      var wEarned = earned;
      var wPurchased = purchased;
      final wConsumed = Set<String>.of(consumed);
      final draws = <String, FreezeKind>{};
      var ok = true;
      for (var i = 1; i < gap; i++) {
        final missed = _addDays(lastCounted, i);
        final mk = _monthOfDay(missed);
        if (wPurchased > 0) {
          wPurchased--;
          draws[missed] = FreezeKind.purchased;
        } else if (wEarned > 0) {
          wEarned--;
          draws[missed] = FreezeKind.earned;
        } else if (!wConsumed.contains(mk)) {
          wConsumed.add(mk);
          draws[missed] = FreezeKind.monthly;
        } else {
          ok = false;
          break;
        }
      }
      if (ok) {
        earned = wEarned;
        purchased = wPurchased;
        consumed = wConsumed;
        for (final e in draws.entries) {
          counted.add(e.key);
          restored.add(e.key);
          // A freeze bridge LEGITIMIZES the day it covers (A1 fix,
          // Vera blocker, Nov 19, 2026): clear any revalidation
          // tombstone for it, exactly as a genuine completion does
          // in completeDay. Without this, the adoption merge —
          // which admits a tombstoned day only on completion or
          // freeze cover — could eat the bridged day on the next
          // adoption while the freeze spent bridging it stays
          // spent (the 27 → 0 flip-flop, with a paid freeze burned).
          invalidated.remove(e.key);
          // Spoils attribution (A5): the missed day's month.
          spoiled.add(_monthOfDay(e.key));
          bridged.add(e.key);
          kinds[e.key] = e.value;
        }
        bridged.sort();
      } else {
        broke = true;
      }
    }
  }

  // ── Accrual rollover (B1), AFTER the bridging walk so every
  // attribution for a month lands BEFORE that month's close is
  // evaluated. Each month from accrualMonth forward while it is
  // behind the current month is closed in chronological order
  // (multi-month catch-up fully processed, never skipped); the
  // current partial month is never closed early.
  var accrual = s.accrualMonth;
  final currentMonth = _monthOfDay(today);
  if (accrual.isEmpty) {
    // Never-migrated in-memory state: anchor without closing
    // anything — the past cannot be inferred (A4's rule).
    accrual = currentMonth;
  } else {
    while (accrual.compareTo(currentMonth) < 0) {
      final m = accrual;
      final alive =
          counted.any((d) => _monthOfDay(d) == m) ||
          restored.any((d) => _monthOfDay(d) == m);
      if (!spoiled.contains(m) && alive) {
        ffmc++;
        // An earned freeze comes due, resolved immediately under
        // A1 against the evolving inventory. The cover count uses
        // the grant of the month being entered (m+1): at m's close
        // that is the live monthly grant.
        final cover = _coverFor(
          consumed,
          _addMonthsToKey(m, 1),
          earned,
          purchased,
        );
        final cap = 2 + (purchased > 0 ? 1 : 0);
        if (earned == 0 && cover < cap) {
          earned = 1;
        } else {
          // Grant blocked (earned slot held, or at cap): the due
          // freeze queues as pending. If one is held AND one is
          // already pending, the due does NOT bank — pending is
          // already true and stays true; the month still counted.
          pending = true;
        }
      }
      // A month that was spoiled, or in which the streak was never
      // alive (no counted/restored day), mints nothing and does
      // NOT reset ffmc — the count pauses (B1).
      accrual = _addMonthsToKey(m, 1);
    }
  }

  // ── Pending landing (A1): checked at every settlement, as the
  // final step, against the CURRENT month's cover. BOTH clauses
  // must hold: the earned slot free AND total cover under cap. A
  // purchased-first bridge that frees only a total slot while an
  // earned freeze is held does NOT land the pending freeze.
  if (pending && earned == 0) {
    final cover = _coverFor(consumed, currentMonth, earned, purchased);
    final cap = 2 + (purchased > 0 ? 1 : 0);
    if (cover < cap) {
      earned = 1;
      pending = false;
    }
  }

  // ── Prune spoiledMonths to the trailing 24 months (B1), only
  // months already closed (behind the post-catch-up accrualMonth)
  // — an unclosed month never loses its spoiled mark before its
  // close evaluation reads it (Vera round 3 note).
  final threshold = _addMonthsToKey(currentMonth, -23);
  spoiled.removeWhere(
    (m) => m.compareTo(threshold) < 0 && m.compareTo(accrual) < 0,
  );

  // ── Stamp (A3): every settlement stamps lastEvaluatedDay with
  // the current Tabs day, exactly as the shipped engine stamps
  // every evaluation. A backwards clock never moves the stamp
  // backwards (adoption comparisons depend on its monotonicity).
  final stamp =
      (s.lastEvaluatedDay != null && s.lastEvaluatedDay!.compareTo(today) > 0)
      ? s.lastEvaluatedDay!
      : today;

  final next = s.copyWith(
    countedDays: counted,
    restoredDays: restored,
    invalidatedDays: invalidated,
    consumedSaveMonths: consumed,
    earnedFreezes: earned,
    purchasedFreezes: purchased,
    earnedPending: pending,
    accrualMonth: accrual,
    spoiledMonths: spoiled,
    freezeFreeMonthsCompleted: ffmc,
    lastEvaluatedDay: stamp,
  );
  return StreakSettleResult(
    state: next,
    bridgedDays: bridged,
    freezeUsedKinds: kinds,
    brokeStreak: broke,
  );
}

/// Rollover settlement (D3): bridges or breaks the gap between the
/// last counted day and the current Tabs day, runs accrual
/// rollover, lands a pending earned freeze when A1's conditions
/// hold, and stamps [StreakState.lastEvaluatedDay]. It NEVER adds
/// a counted day — the counted-day event is Daily Summary
/// completion ([completeDay]) only.
StreakState settle(StreakState s, DateTime now) =>
    _settleDetailed(s, tabsDayStr(now)).state;

/// [settle] with its bridging detail exposed.
StreakSettleResult settleDetailed(StreakState s, DateTime now) =>
    _settleDetailed(s, tabsDayStr(now));

/// One Daily Summary completion (D1): settles first with the
/// summary's own Tabs day as the anchor "today", then counts that
/// day. If the gap from the last counted day to the summary day
/// cannot bridge, the run restarts at the summary day (the shipped
/// evaluate semantics). A completion for a day already counted
/// (e.g. bridged content aside, a repeat fire) changes nothing.
({StreakState state, StreakCompletionResult result}) completeDay(
  StreakState s, {
  required String summaryTabsDay,
  required DateTime now,
}) {
  final settled = _settleDetailed(s, summaryTabsDay);
  var st = settled.state;
  if (!st.countedDays.contains(summaryTabsDay)) {
    st = st.copyWith(
      countedDays: Set<String>.of(st.countedDays)..add(summaryTabsDay),
    );
  }
  // A genuine completion legitimizes the day: clear any
  // revalidation tombstone for it (streak-bugs fix).
  if (st.invalidatedDays.contains(summaryTabsDay)) {
    st = st.copyWith(
      invalidatedDays: Set<String>.of(st.invalidatedDays)
        ..remove(summaryTabsDay),
    );
  }
  final newCount = _runEndingAt(st.countedDays, summaryTabsDay).length;
  return (
    state: st,
    result: StreakCompletionResult(
      newCount: newCount,
      bridgedDays: settled.bridgedDays,
      freezeUsedKinds: settled.freezeUsedKinds,
      brokeStreak: settled.brokeStreak,
      earnedLanded: st.earnedFreezes > s.earnedFreezes,
      isMilestone: isMilestone(newCount),
    ),
  );
}

/// Days in the given month that count toward the streak.
int streakCountedDaysInMonth(StreakState s, int year, int month) {
  final prefix =
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-';
  return s.countedDays.where((d) => d.startsWith(prefix)).length;
}

/// The shared seeding core: the run the pull counters attest is
/// assumed to end on [endDay], so its days become counted days.
StreakState _seedEndingAt({
  required int current,
  required int best,
  required String endDay,
  int purchasedFreezes = 0,
}) {
  final counted = <String>{};
  if (current >= 1) {
    for (var i = 0; i < current; i++) {
      counted.add(_addDays(endDay, -i));
    }
  }
  return StreakState(
    seeded: true,
    seededCurrent: current > 0 ? current : 0,
    seededBest: best > 0 ? best : 0,
    countedDays: counted,
    lastEvaluatedDay: counted.isEmpty ? null : endDay,
    purchasedFreezes: purchasedFreezes.clamp(0, 1),
    accrualMonth: _monthOfDay(endDay),
  );
}

/// Seed the engine from the profile pull counters. The current run
/// is assumed to end today (the app is open today; the native rule
/// counts today), so the run's days become counted days. A null or
/// non-positive pull seeds nothing but still marks the state seeded
/// when [markSeeded] — callers pass the pull's real values only.
///
/// LEGACY (pre-v2): [settle]/[completeDay] seeding goes through
/// [streakSeedForAdoption] / [streakSeedForCompletion] (A6); this
/// form remains for the legacy [streakEvaluate] path and its tests.
StreakState streakSeed({
  required int current,
  required int best,
  required DateTime now,
}) => _seedEndingAt(current: current, best: best, endDay: streakDayStr(now));

/// Adoption seeding (A6): the assumed run anchors on the PRIOR
/// Tabs day — today is not yet counted (no summary has completed),
/// so the run the counters attest ended yesterday-Tabs-day. Used
/// by the app-open path; no counted day is fabricated for a day
/// with no completed summary.
StreakState streakSeedForAdoption({
  required int current,
  required int best,
  required DateTime now,
  int purchasedFreezes = 0,
}) => _seedEndingAt(
  current: current,
  best: best,
  endDay: _addDays(tabsDayStr(now), -1),
  purchasedFreezes: purchasedFreezes,
);

/// Completion seeding (A6): the assumed run anchors on the
/// summary's own Tabs day — the completion being recorded is the
/// event that culminates the attested run on that day.
StreakState streakSeedForCompletion({
  required int current,
  required int best,
  required String summaryTabsDay,
  int purchasedFreezes = 0,
}) => _seedEndingAt(
  current: current,
  best: best,
  endDay: summaryTabsDay,
  purchasedFreezes: purchasedFreezes,
);

/// One app-open evaluation at [now]. Idempotent within a day.
/// Returns the (possibly unchanged) next state.
///
/// LEGACY (pre-v2): superseded by [settle] + [completeDay] — the
/// counted-day event is now Daily Summary completion, and app-open
/// never adds a counted day (D1). Retained for its pinned tests;
/// no production path calls it.
///
/// - Today already counted → unchanged.
/// - Last counted day was yesterday → today joins the run.
/// - Exactly one missed day → that month's save is consumed
///   automatically if available (the missed day becomes a restored,
///   counted day) and the run continues; if the save is gone, the
///   run restarts at today.
/// - Two or more missed days → the run restarts at today and NO
///   save is consumed (one save covers exactly one missed day).
StreakState streakEvaluate(StreakState s, DateTime now) {
  final today = streakDayStr(now);
  if (s.countedDays.contains(today)) {
    return s.lastEvaluatedDay == today
        ? s
        : s.copyWith(lastEvaluatedDay: today);
  }
  final counted = Set<String>.of(s.countedDays);
  final restored = Set<String>.of(s.restoredDays);
  final consumed = Set<String>.of(s.consumedSaveMonths);

  String? lastCounted;
  for (final d in counted) {
    if (streakDaysBetween(d, today) > 0 &&
        (lastCounted == null || d.compareTo(lastCounted) > 0)) {
      lastCounted = d;
    }
  }

  if (lastCounted != null) {
    final gap = streakDaysBetween(lastCounted, today);
    if (gap == 2) {
      final missed = _addDays(lastCounted, 1);
      final missedDate = _parseDay(missed);
      final key = streakMonthKey(missedDate);
      if (!consumed.contains(key)) {
        restored.add(missed);
        counted.add(missed);
        consumed.add(key);
      }
    }
    // gap == 1: consecutive, nothing extra. gap >= 3: the run is
    // broken; the recompute in streakCurrent starts it at today.
  }
  counted.add(today);

  return s.copyWith(
    countedDays: counted,
    restoredDays: restored,
    consumedSaveMonths: consumed,
    lastEvaluatedDay: today,
  );
}
