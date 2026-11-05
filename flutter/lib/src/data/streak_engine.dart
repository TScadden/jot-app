import 'package:flutter/foundation.dart';

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
/// passed in. Persistence lives in streak_store.dart.

/// One calendar day in local time, as an ISO `yyyy-MM-dd` string.
String streakDayStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// The `yyyy-MM` grant key for the month containing [d].
String streakMonthKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}';

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

  const StreakState({
    this.seeded = false,
    this.seededCurrent = 0,
    this.seededBest = 0,
    this.countedDays = const {},
    this.restoredDays = const {},
    this.consumedSaveMonths = const {},
    this.lastEvaluatedDay,
  });

  static const empty = StreakState();

  /// Lab-local history worth protecting from a re-seed: any restored
  /// day or consumed save exists only in this record.
  bool get hasProtectedHistory =>
      restoredDays.isNotEmpty || consumedSaveMonths.isNotEmpty;

  StreakState copyWith({
    bool? seeded,
    int? seededCurrent,
    int? seededBest,
    Set<String>? countedDays,
    Set<String>? restoredDays,
    Set<String>? consumedSaveMonths,
    String? lastEvaluatedDay,
  }) {
    return StreakState(
      seeded: seeded ?? this.seeded,
      seededCurrent: seededCurrent ?? this.seededCurrent,
      seededBest: seededBest ?? this.seededBest,
      countedDays: countedDays ?? this.countedDays,
      restoredDays: restoredDays ?? this.restoredDays,
      consumedSaveMonths: consumedSaveMonths ?? this.consumedSaveMonths,
      lastEvaluatedDay: lastEvaluatedDay ?? this.lastEvaluatedDay,
    );
  }

  Map<String, dynamic> toJson() => {
        'v': 1,
        'seeded': seeded,
        'seededCurrent': seededCurrent,
        'seededBest': seededBest,
        'countedDays': countedDays.toList()..sort(),
        'restoredDays': restoredDays.toList()..sort(),
        'consumedSaveMonths': consumedSaveMonths.toList()..sort(),
        'lastEvaluatedDay': lastEvaluatedDay,
      };

  factory StreakState.fromJson(Map<String, dynamic> json) {
    Set<String> setOf(String key) {
      final v = json[key];
      if (v is! List) return const {};
      return v.whereType<String>().toSet();
    }

    int intOf(String key) {
      final v = json[key];
      return v is int ? v : 0;
    }

    final last = json['lastEvaluatedDay'];
    return StreakState(
      seeded: json['seeded'] == true,
      seededCurrent: intOf('seededCurrent'),
      seededBest: intOf('seededBest'),
      countedDays: setOf('countedDays'),
      restoredDays: setOf('restoredDays'),
      consumedSaveMonths: setOf('consumedSaveMonths'),
      lastEvaluatedDay: last is String ? last : null,
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
      other.lastEvaluatedDay == lastEvaluatedDay;

  @override
  int get hashCode => Object.hash(
        seeded,
        seededCurrent,
        seededBest,
        Object.hashAllUnordered(countedDays),
        Object.hashAllUnordered(restoredDays),
        Object.hashAllUnordered(consumedSaveMonths),
        lastEvaluatedDay,
      );
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

/// Days in the given month that count toward the streak.
int streakCountedDaysInMonth(StreakState s, int year, int month) {
  final prefix =
      '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}-';
  return s.countedDays.where((d) => d.startsWith(prefix)).length;
}

/// Seed the engine from the profile pull counters. The current run
/// is assumed to end today (the app is open today; the native rule
/// counts today), so the run's days become counted days. A null or
/// non-positive pull seeds nothing but still marks the state seeded
/// when [markSeeded] — callers pass the pull's real values only.
StreakState streakSeed({
  required int current,
  required int best,
  required DateTime now,
}) {
  final today = streakDayStr(now);
  final counted = <String>{};
  if (current >= 1) {
    for (var i = 0; i < current; i++) {
      counted.add(_addDays(today, -i));
    }
  }
  return StreakState(
    seeded: true,
    seededCurrent: current > 0 ? current : 0,
    seededBest: best > 0 ? best : 0,
    countedDays: counted,
    lastEvaluatedDay: counted.contains(today) ? today : null,
  );
}

/// One app-open evaluation at [now]. Idempotent within a day.
/// Returns the (possibly unchanged) next state.
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
