/// The badge engine (BADGES package, Nov 20, 2026) — pure logic:
/// the 12 metrics × 15 rungs of `~/workspace/badge-design/
/// BADGE-LADDER.md` (the spec of record), the metric derivations
/// from raw history, and the rung math. No I/O, no clocks except
/// the values passed in; persistence, the gem-grant queue, and
/// evaluation orchestration live in badge_store.dart.
///
/// RUNG ORDER (founder's rule, Nov 19, 2026 — easy to get wrong):
/// within each metal III is FIRST, then II, then I is the top of
/// the metal. Rung index 0 = Bronze III, 1 = Bronze II, 2 =
/// Bronze I, 3 = Silver III, …, 12 = Diamond III, 14 = Diamond I.
/// The level bars under the icon mirror the numeral: index % 3
/// == 0 → III (3 bars), == 1 → II (2 bars), == 2 → I (1 bar).
///
/// DAY SEAM (coordinator ruling): every timestamp → day-key
/// derivation in this file routes through the streak engine's
/// [tabsDayStr] / [tabsDayAnchor] — no independent day-boundary
/// math is introduced. Day keys that arrive pre-computed (Health
/// Connect per-day aggregate rows, the streak state's own day
/// sets) are already day keys; week/month windows over day keys
/// use [streakDayStr] exactly as gem_service.dart's week helpers
/// do. When the boundary-migration package flips the Tabs anchor
/// to calendar midnight, badges follow automatically.
///
/// Biometric zero rule: a 0 from Health Connect is a failed read,
/// never data. HC per-day maps handed to this engine are expected
/// pre-filtered to values > 0 (the HC service layer enforces it,
/// the same rule every existing reader applies); the derivations
/// here additionally ignore any non-positive value they are given.
library;

import 'package:tabs_lab/src/data/streak_engine.dart';

/// The five metals, low to high (index = rungIndex ~/ 3).
enum BadgeMetal { bronze, silver, gold, platinum, diamond }

/// One badge metric: its stable id (used in the gem-grant
/// idempotency key and the persisted record), its section, and its
/// 15 thresholds in rung order (Bronze III → Diamond I), copied
/// EXACTLY from BADGE-LADDER.md.
class BadgeMetric {
  final String id;
  final String section;
  final List<int> thresholds;

  const BadgeMetric({
    required this.id,
    required this.section,
    required this.thresholds,
  });

  /// The highest rung index whose threshold [value] reaches, or
  /// -1 when no rung is reached. Thresholds ascend, so the earned
  /// set is always the prefix 0..result.
  int rungForValue(int value) {
    var rung = -1;
    for (var i = 0; i < thresholds.length; i++) {
      if (value >= thresholds[i]) {
        rung = i;
      } else {
        break;
      }
    }
    return rung;
  }
}

/// Section ids in screen order.
abstract final class BadgeSections {
  static const String logging = 'logging';
  static const String streaks = 'streaks';
  static const String activity = 'activity';
  static const String sleep = 'sleep';

  static const List<String> order = [logging, streaks, activity, sleep];
}

/// The 12 metrics in screen order (Logging, Streaks, Activity,
/// Sleep; spec order within a section). Threshold lists are in
/// rung order Bronze III → Diamond I (BADGE-LADDER.md).
abstract final class BadgeMetrics {
  static const BadgeMetric totalLogs = BadgeMetric(
    id: 'total_logs',
    section: BadgeSections.logging,
    thresholds: [
      5, 15, 30, 50, 75, 100, 150, 200, 250, 300, 350, 425, 500, 1000, 2000,
    ],
  );
  static const BadgeMetric logsInDay = BadgeMetric(
    id: 'logs_in_day',
    section: BadgeSections.logging,
    thresholds: [
      5, 10, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80,
    ],
  );
  static const BadgeMetric morningLogger = BadgeMetric(
    id: 'morning_logger',
    section: BadgeSections.logging,
    thresholds: [
      1, 3, 5, 10, 15, 20, 30, 40, 50, 65, 80, 100, 150, 200, 300,
    ],
  );
  static const BadgeMetric dayStreak = BadgeMetric(
    id: 'day_streak',
    section: BadgeSections.streaks,
    thresholds: [
      3, 5, 7, 10, 14, 21, 30, 45, 60, 75, 90, 100, 150, 250, 365,
    ],
  );
  static const BadgeMetric perfectWeeks = BadgeMetric(
    id: 'perfect_weeks',
    section: BadgeSections.streaks,
    thresholds: [
      1, 2, 3, 4, 6, 8, 10, 13, 16, 20, 25, 30, 40, 45, 52,
    ],
  );
  static const BadgeMetric freezeSaver = BadgeMetric(
    id: 'freeze_saver',
    section: BadgeSections.streaks,
    thresholds: [
      1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20,
    ],
  );
  static const BadgeMetric caloriesMonth = BadgeMetric(
    id: 'calories_month',
    section: BadgeSections.activity,
    thresholds: [
      25000, 35000, 45000, 55000, 62000, 68000, 75000, 82000, 90000, 100000,
      108000, 115000, 122000, 130000, 140000,
    ],
  );
  static const BadgeMetric stepsDay = BadgeMetric(
    id: 'steps_day',
    section: BadgeSections.activity,
    thresholds: [
      5000, 7500, 10000, 12500, 15000, 17500, 20000, 22500, 25000, 27500,
      30000, 32500, 35000, 37500, 40000,
    ],
  );
  static const BadgeMetric activeWeek = BadgeMetric(
    id: 'active_week',
    section: BadgeSections.activity,
    thresholds: [
      60, 120, 180, 240, 300, 360, 420, 480, 540, 600, 660, 720, 780, 840, 900,
    ],
  );
  static const BadgeMetric nightsTracked = BadgeMetric(
    id: 'nights_tracked',
    section: BadgeSections.sleep,
    thresholds: [
      3, 7, 14, 21, 30, 45, 60, 90, 120, 150, 180, 240, 300, 330, 365,
    ],
  );
  static const BadgeMetric sleepWeek = BadgeMetric(
    id: 'sleep_week',
    section: BadgeSections.sleep,
    thresholds: [
      1, 2, 3, 4, 6, 8, 10, 13, 16, 20, 25, 30, 40, 45, 52,
    ],
  );
  static const BadgeMetric earlyToBed = BadgeMetric(
    id: 'early_to_bed',
    section: BadgeSections.sleep,
    thresholds: [
      1, 3, 5, 8, 12, 16, 20, 25, 30, 40, 50, 60, 75, 100, 150,
    ],
  );

  /// All 12 metrics in screen order.
  static const List<BadgeMetric> all = [
    totalLogs,
    logsInDay,
    morningLogger,
    dayStreak,
    perfectWeeks,
    freezeSaver,
    caloriesMonth,
    stepsDay,
    activeWeek,
    nightsTracked,
    sleepWeek,
    earlyToBed,
  ];

  static BadgeMetric byId(String id) => all.firstWhere((m) => m.id == id);

  /// The metrics of one section, in screen order.
  static List<BadgeMetric> inSection(String section) =>
      [for (final m in all) if (m.section == section) m];
}

/// The metal of rung [rungIndex] (0..14).
BadgeMetal badgeMetalOf(int rungIndex) =>
    BadgeMetal.values[rungIndex ~/ 3];

/// Bars for rung [rungIndex]: III → 3, II → 2, I → 1.
int badgeBarsOf(int rungIndex) => 3 - (rungIndex % 3);

/// The Roman numeral of rung [rungIndex]: III, II, or I.
String badgeNumeralOf(int rungIndex) =>
    const ['III', 'II', 'I'][rungIndex % 3];

/// The display metal name of rung [rungIndex] (Juno §6 forms).
String badgeMetalNameOf(int rungIndex) => const [
      'Bronze',
      'Silver',
      'Gold',
      'Platinum',
      'Diamond',
    ][rungIndex ~/ 3];

/// The full rung name (Juno §6 template `{Metal} {Numeral}`).
String badgeRungName(int rungIndex) =>
    '${badgeMetalNameOf(rungIndex)} ${badgeNumeralOf(rungIndex)}';

/// The gem-grant idempotency key token for rung [rungIndex]
/// (coordinator grammar, Nov 20, 2026): `{metal}_{n}` with the
/// metal lowercase and n the numeral's value — `_3` = III (the
/// first rung of the metal), `_1` = I (the top). Ladder order:
/// bronze_3, bronze_2, bronze_1, silver_3, …, diamond_1.
String badgeRungToken(int rungIndex) =>
    '${badgeMetalNameOf(rungIndex).toLowerCase()}_${badgeBarsOf(rungIndex)}';

/// The full gem-grant idempotency key for one rung:
/// `badge:{metric}:{metal}_{n}` (e.g. `badge:total_logs:bronze_3`).
/// The server gems ledger (POST /api/gems/grant) makes a replayed
/// key an alreadyGranted no-op, so a rung can never double-pay.
String badgeGrantKey(String metricId, int rungIndex) =>
    'badge:$metricId:${badgeRungToken(rungIndex)}';

/// The gems one rung pays (founder ruling, Nov 20, 2026).
const int badgeRungGemAmount = 5;

/// Parses a `yyyy-MM-dd` day key into a UTC-midnight [DateTime].
/// Split-parse instead of [DateTime.parse]: DateTime.parse rejects
/// non-zero-padded keys (e.g. `2026-11-9`), and a day-key set that
/// contains one must never crash week arithmetic. Canonical keys
/// from [streakDayStr] are always padded, so this is identical for
/// well-formed keys and tolerant of legacy ones.
DateTime _badgeDayKeyUtc(String dayKey) {
  final parts = dayKey.split('-');
  return DateTime.utc(
      int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
}

/// The Monday (day key) of the Mon–Sun week containing [dayKey].
/// Day-key arithmetic in the gem_service.dart pattern: parse the
/// key, step on UTC midnights so DST never skews a calendar-day
/// step, and format back through [streakDayStr].
String badgeWeekMonday(String dayKey) {
  final d = _badgeDayKeyUtc(dayKey);
  final monday = d.subtract(Duration(days: d.weekday - 1));
  return streakDayStr(monday);
}

/// The seven day keys of the Mon–Sun week starting [monday].
List<String> badgeWeekDays(String monday) {
  final base = _badgeDayKeyUtc(monday);
  return [for (var i = 0; i < 7; i++) streakDayStr(base.add(Duration(days: i)))];
}

/// One raw Health Connect exercise session (epoch ms span).
typedef BadgeExerciseSpan = ({int startMs, int endMs});

/// One raw Health Connect sleep session: its span plus its
/// genuinely-asleep minutes (session interval minus awake stages,
/// computed by the HC service's summarizer helpers). A session
/// with [asleepMinutes] ≤ 0 is a failed/empty read (zero rule)
/// and never counts as a tracked night.
typedef BadgeSleepSession = ({int startMs, int endMs, int asleepMinutes});

/// Everything one evaluation derives from. A null source means
/// "unknown this run" (read failed / not attempted): the metrics
/// fed by that source keep their previously stored values and
/// grant nothing new — an outage is never recomputed over as an
/// empty history.
class BadgeInputs {
  /// All-time log entry timestamps (epoch ms) — the same list the
  /// app's existing log counters read (`fetchLogEntries`).
  final List<int>? logTimestampsMs;

  /// The settled streak state (settlement data: counted /
  /// restored / summary-completed day sets + the seeded best).
  final StreakState? streakState;

  /// HC TOTAL calories per day key (values > 0 only).
  final Map<String, int>? dailyTotalCalories;

  /// HC steps per day key (values > 0 only).
  final Map<String, int>? dailySteps;

  /// HC exercise sessions (active minutes source).
  final List<BadgeExerciseSpan>? exerciseSessions;

  /// HC sleep sessions (raw, with asleep minutes).
  final List<BadgeSleepSession>? sleepSessions;

  const BadgeInputs({
    this.logTimestampsMs,
    this.streakState,
    this.dailyTotalCalories,
    this.dailySteps,
    this.exerciseSessions,
    this.sleepSessions,
  });
}

/// The metric values derivable from [inputs]: metric id → value.
/// A metric whose source is null in [inputs] is ABSENT from the
/// result (unknown), never zero-filled.
Map<String, int> computeBadgeValues(BadgeInputs inputs) {
  final out = <String, int>{};

  final logs = inputs.logTimestampsMs;
  if (logs != null) {
    out[BadgeMetrics.totalLogs.id] = logs.length;
    final perDay = <String, int>{};
    final morningDays = <String>{};
    for (final t in logs) {
      final dt = DateTime.fromMillisecondsSinceEpoch(t);
      final day = tabsDayStr(dt);
      perDay[day] = (perDay[day] ?? 0) + 1;
      // Morning logger: a log in the Tabs day's morning window.
      // The Tabs day starts at 04:00 (the anchor), so its
      // "before 9 AM" window is wall-clock [04:00, 09:00) — an
      // entry at 00:00–03:59 belongs to the still-open previous
      // Tabs day's night, not to a morning.
      if (dt.hour >= 4 && dt.hour < 9) morningDays.add(day);
    }
    out[BadgeMetrics.logsInDay.id] =
        perDay.values.fold(0, (a, b) => b > a ? b : a);
    out[BadgeMetrics.morningLogger.id] = morningDays.length;
  }

  final streak = inputs.streakState;
  if (streak != null) {
    // Best streak from the settled store's own derivation —
    // reused, never recomputed from raw days.
    out[BadgeMetrics.dayStreak.id] = streakBest(streak);
    // Perfect weeks: Mon–Sun weeks with all 7 Daily Summaries
    // complete (the settlement record's summaryCompletedDays).
    final mondays = <String>{
      for (final d in streak.summaryCompletedDays) badgeWeekMonday(d),
    };
    var perfect = 0;
    for (final monday in mondays) {
      if (badgeWeekDays(monday)
          .every(streak.summaryCompletedDays.contains)) {
        perfect++;
      }
    }
    out[BadgeMetrics.perfectWeeks.id] = perfect;
    // Freeze saver: days a freeze actually covered — the settled
    // record's restoredDays is exactly that set.
    out[BadgeMetrics.freezeSaver.id] = streak.restoredDays.length;
  }

  final calories = inputs.dailyTotalCalories;
  if (calories != null) {
    final perMonth = <String, int>{};
    for (final e in calories.entries) {
      if (e.value <= 0) continue; // zero rule
      final month = e.key.substring(0, 7);
      perMonth[month] = (perMonth[month] ?? 0) + e.value;
    }
    out[BadgeMetrics.caloriesMonth.id] =
        perMonth.values.fold(0, (a, b) => b > a ? b : a);
  }

  final steps = inputs.dailySteps;
  if (steps != null) {
    var best = 0;
    for (final v in steps.values) {
      if (v > best) best = v;
    }
    out[BadgeMetrics.stepsDay.id] = best;
  }

  final exercise = inputs.exerciseSessions;
  if (exercise != null) {
    // Active week: exercise-session minutes summed per Tabs day
    // (attributed to the session's start day, via the anchor),
    // then per Mon–Sun week; the best week wins.
    final perDay = <String, int>{};
    for (final s in exercise) {
      final minutes = (s.endMs - s.startMs) ~/ 60000;
      if (minutes <= 0) continue;
      final day =
          tabsDayStr(DateTime.fromMillisecondsSinceEpoch(s.startMs));
      perDay[day] = (perDay[day] ?? 0) + minutes;
    }
    final perWeek = <String, int>{};
    for (final e in perDay.entries) {
      final monday = badgeWeekMonday(e.key);
      perWeek[monday] = (perWeek[monday] ?? 0) + e.value;
    }
    out[BadgeMetrics.activeWeek.id] =
        perWeek.values.fold(0, (a, b) => b > a ? b : a);
  }

  final sleep = inputs.sleepSessions;
  if (sleep != null) {
    // A night is identified by the Tabs day of the session's end
    // (the wake moment), through the anchor — the same seam every
    // other day derivation uses.
    final nights = <String>{};
    final mainOnsetByNight = <String, ({int onsetMinutes, int asleep})>{};
    for (final s in sleep) {
      if (s.asleepMinutes <= 0) continue; // zero rule
      final night =
          tabsDayStr(DateTime.fromMillisecondsSinceEpoch(s.endMs));
      nights.add(night);
      // The night's bedtime is the onset of its main session —
      // the one with the most asleep minutes (a nap never stands
      // in for the night's bedtime).
      final prev = mainOnsetByNight[night];
      if (prev == null || s.asleepMinutes > prev.asleep) {
        final start = DateTime.fromMillisecondsSinceEpoch(s.startMs);
        mainOnsetByNight[night] = (
          onsetMinutes: start.hour * 60 + start.minute,
          asleep: s.asleepMinutes,
        );
      }
    }
    out[BadgeMetrics.nightsTracked.id] = nights.length;
    final mondays = {for (final d in nights) badgeWeekMonday(d)};
    var fullWeeks = 0;
    for (final monday in mondays) {
      if (badgeWeekDays(monday).every(nights.contains)) fullWeeks++;
    }
    out[BadgeMetrics.sleepWeek.id] = fullWeeks;
    // Early to bed: onset in the evening window [12:00, 22:00] —
    // in bed by 10 PM. An onset after midnight (00:00–11:59) is
    // not "by 10 PM" and never counts.
    var early = 0;
    for (final e in mainOnsetByNight.values) {
      if (e.onsetMinutes >= 12 * 60 && e.onsetMinutes <= 22 * 60) early++;
    }
    out[BadgeMetrics.earlyToBed.id] = early;
  }

  return out;
}
