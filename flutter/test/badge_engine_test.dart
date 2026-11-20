import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';

/// Badge engine pins (BADGES package): the founder's rung order,
/// the spec anchors, every ladder copied from BADGE-LADDER.md,
/// each metric's derivation on synthetic history, and the
/// biometric zero rule.
void main() {
  group('rung order (founder rule: III first, I tops the metal)', () {
    test('rung index mapping is pinned explicitly', () {
      expect(badgeRungName(0), 'Bronze III');
      expect(badgeRungName(1), 'Bronze II');
      expect(badgeRungName(2), 'Bronze I');
      expect(badgeRungName(3), 'Silver III');
      expect(badgeRungName(4), 'Silver II');
      expect(badgeRungName(5), 'Silver I');
      expect(badgeRungName(6), 'Gold III');
      expect(badgeRungName(8), 'Gold I');
      expect(badgeRungName(9), 'Platinum III');
      expect(badgeRungName(11), 'Platinum I');
      expect(badgeRungName(12), 'Diamond III');
      expect(badgeRungName(13), 'Diamond II');
      expect(badgeRungName(14), 'Diamond I');
    });

    test('bars mirror the numeral: III=3, II=2, I=1', () {
      expect(badgeBarsOf(0), 3);
      expect(badgeBarsOf(1), 2);
      expect(badgeBarsOf(2), 1);
      expect(badgeBarsOf(12), 3);
      expect(badgeBarsOf(14), 1);
    });

    test('grant key tokens follow the coordinator grammar', () {
      expect(badgeRungToken(0), 'bronze_3');
      expect(badgeRungToken(1), 'bronze_2');
      expect(badgeRungToken(2), 'bronze_1');
      expect(badgeRungToken(3), 'silver_3');
      expect(badgeRungToken(6), 'gold_3');
      expect(badgeRungToken(9), 'platinum_3');
      expect(badgeRungToken(12), 'diamond_3');
      expect(badgeRungToken(14), 'diamond_1');
      expect(badgeGrantKey('total_logs', 0), 'badge:total_logs:bronze_3');
      expect(badgeGrantKey('day_streak', 14), 'badge:day_streak:diamond_1');
    });

    test('every ladder has exactly 15 ascending thresholds', () {
      expect(BadgeMetrics.all.length, 12);
      for (final m in BadgeMetrics.all) {
        expect(m.thresholds.length, 15, reason: m.id);
        for (var i = 1; i < 15; i++) {
          expect(m.thresholds[i] > m.thresholds[i - 1], isTrue,
              reason: '${m.id} rung $i');
        }
      }
    });
  });

  group('founder anchors', () {
    test('500 total logs = Diamond III (index 12)', () {
      expect(BadgeMetrics.totalLogs.rungForValue(500), 12);
      expect(BadgeMetrics.totalLogs.rungForValue(499), 11);
      expect(BadgeMetrics.totalLogs.rungForValue(1000), 13);
      expect(BadgeMetrics.totalLogs.rungForValue(2000), 14);
    });

    test('100,000 kcal month = Platinum III (index 9)', () {
      expect(BadgeMetrics.caloriesMonth.rungForValue(100000), 9);
      expect(BadgeMetrics.caloriesMonth.rungForValue(99999), 8);
      expect(BadgeMetrics.caloriesMonth.rungForValue(140000), 14);
    });

    test('logs in a day 5/10/20 = Bronze III/II/I', () {
      expect(BadgeMetrics.logsInDay.rungForValue(5), 0);
      expect(BadgeMetrics.logsInDay.rungForValue(10), 1);
      expect(BadgeMetrics.logsInDay.rungForValue(20), 2);
      expect(BadgeMetrics.logsInDay.rungForValue(4), -1);
      expect(BadgeMetrics.logsInDay.rungForValue(80), 14);
    });
  });

  group('ladder spot checks (BADGE-LADDER.md verbatim)', () {
    test('thresholds match the spec of record', () {
      expect(BadgeMetrics.totalLogs.thresholds,
          [5, 15, 30, 50, 75, 100, 150, 200, 250, 300, 350, 425, 500, 1000, 2000]);
      expect(BadgeMetrics.logsInDay.thresholds,
          [5, 10, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80]);
      expect(BadgeMetrics.morningLogger.thresholds,
          [1, 3, 5, 10, 15, 20, 30, 40, 50, 65, 80, 100, 150, 200, 300]);
      expect(BadgeMetrics.dayStreak.thresholds,
          [3, 5, 7, 10, 14, 21, 30, 45, 60, 75, 90, 100, 150, 250, 365]);
      expect(BadgeMetrics.perfectWeeks.thresholds,
          [1, 2, 3, 4, 6, 8, 10, 13, 16, 20, 25, 30, 40, 45, 52]);
      expect(BadgeMetrics.freezeSaver.thresholds,
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 18, 20]);
      expect(BadgeMetrics.caloriesMonth.thresholds, [
        25000, 35000, 45000, 55000, 62000, 68000, 75000, 82000, 90000,
        100000, 108000, 115000, 122000, 130000, 140000,
      ]);
      expect(BadgeMetrics.stepsDay.thresholds, [
        5000, 7500, 10000, 12500, 15000, 17500, 20000, 22500, 25000,
        27500, 30000, 32500, 35000, 37500, 40000,
      ]);
      expect(BadgeMetrics.activeWeek.thresholds,
          [60, 120, 180, 240, 300, 360, 420, 480, 540, 600, 660, 720, 780, 840, 900]);
      expect(BadgeMetrics.nightsTracked.thresholds,
          [3, 7, 14, 21, 30, 45, 60, 90, 120, 150, 180, 240, 300, 330, 365]);
      expect(BadgeMetrics.sleepWeek.thresholds,
          [1, 2, 3, 4, 6, 8, 10, 13, 16, 20, 25, 30, 40, 45, 52]);
      expect(BadgeMetrics.earlyToBed.thresholds,
          [1, 3, 5, 8, 12, 16, 20, 25, 30, 40, 50, 60, 75, 100, 150]);
    });
  });

  /// Epoch ms for a local wall-clock moment.
  int ms(int y, int mo, int d, [int h = 12, int mi = 0]) =>
      DateTime(y, mo, d, h, mi).millisecondsSinceEpoch;

  group('logging metrics', () {
    test('total / in-a-day / morning from raw timestamps', () {
      // 2026-11-02 is a Monday. Day seam: Tabs day starts 04:00.
      final logs = <int>[
        // Nov 2: five logs, two in the morning window.
        ms(2026, 11, 2, 7, 30), ms(2026, 11, 2, 8, 15),
        ms(2026, 11, 2, 12), ms(2026, 11, 2, 15), ms(2026, 11, 2, 21),
        // Nov 3: one morning log.
        ms(2026, 11, 3, 6, 45),
        // 02:30 on Nov 4 belongs to Nov 3's Tabs day and is NOT a
        // morning log (night of the still-open day).
        ms(2026, 11, 4, 2, 30),
      ];
      final v = computeBadgeValues(BadgeInputs(logTimestampsMs: logs));
      expect(v['total_logs'], 7);
      expect(v['logs_in_day'], 5);
      expect(v['morning_logger'], 2);
    });

    test('null log source leaves logging metrics unknown', () {
      final v = computeBadgeValues(const BadgeInputs());
      expect(v.containsKey('total_logs'), isFalse);
      expect(v.containsKey('logs_in_day'), isFalse);
    });
  });

  group('streak metrics (settlement data, reused not recomputed)', () {
    test('day streak = streakBest of the settled state', () {
      final state = StreakState(
        seeded: true,
        seededBest: 68,
        countedDays: {'2026-11-01', '2026-11-02', '2026-11-03'},
      );
      final v = computeBadgeValues(BadgeInputs(streakState: state));
      expect(v['day_streak'], 68);
    });

    test('perfect weeks counts Mon-Sun weeks with all 7 summaries', () {
      // Week of Mon 2026-11-02 .. Sun 2026-11-08 complete; the
      // next week has 6 of 7.
      final days = <String>{
        for (var d = 2; d <= 8; d++) '2026-11-0$d',
        for (var d = 9; d <= 14; d++) '2026-11-$d',
      };
      final state = StreakState(summaryCompletedDays: days);
      final v = computeBadgeValues(BadgeInputs(streakState: state));
      expect(v['perfect_weeks'], 1);
    });

    test('freeze saver = restored days count', () {
      final state = StreakState(
        restoredDays: {'2026-10-03', '2026-11-14'},
      );
      final v = computeBadgeValues(BadgeInputs(streakState: state));
      expect(v['freeze_saver'], 2);
    });
  });

  group('activity metrics', () {
    test('calories month = best calendar month sum', () {
      final v = computeBadgeValues(BadgeInputs(dailyTotalCalories: {
        '2026-10-05': 3000, '2026-10-20': 3200, // Oct: 6,200
        '2026-11-01': 50000, '2026-11-15': 50000, // Nov: 100,000
      }));
      expect(v['calories_month'], 100000);
      expect(BadgeMetrics.caloriesMonth.rungForValue(v['calories_month']!), 9);
    });

    test('steps day = max day; zero days excluded', () {
      final v = computeBadgeValues(BadgeInputs(dailySteps: {
        '2026-11-01': 0, // failed read — never data
        '2026-11-02': 12345,
        '2026-11-03': 8000,
      }));
      expect(v['steps_day'], 12345);
    });

    test('zero-only calories month computes 0, not a phantom month', () {
      final v = computeBadgeValues(BadgeInputs(dailyTotalCalories: {
        '2026-11-01': 0,
      }));
      expect(v['calories_month'], 0);
    });

    test('active week sums exercise minutes per Mon-Sun week', () {
      // Mon 2026-11-02: 90 min; Wed 2026-11-04: 60 min → week 150.
      // Mon 2026-11-09: 45 min → week 45. Best = 150.
      final v = computeBadgeValues(BadgeInputs(exerciseSessions: [
        (startMs: ms(2026, 11, 2, 7), endMs: ms(2026, 11, 2, 8, 30)),
        (startMs: ms(2026, 11, 4, 18), endMs: ms(2026, 11, 4, 19)),
        (startMs: ms(2026, 11, 9, 7), endMs: ms(2026, 11, 9, 7, 45)),
        // A zero-length session is no data.
        (startMs: ms(2026, 11, 3, 7), endMs: ms(2026, 11, 3, 7)),
      ]));
      expect(v['active_week'], 150);
    });
  });

  group('sleep metrics', () {
    BadgeSleepSession night(int y, int mo, int d,
            {int bedH = 22, int bedM = 0, int wakeH = 6, int asleep = 420}) =>
        (
          startMs: ms(y, mo, d, bedH, bedM),
          endMs: ms(y, mo, d + 1, wakeH),
          asleepMinutes: asleep,
        );

    test('nights tracked counts distinct nights with asleep > 0', () {
      final v = computeBadgeValues(BadgeInputs(sleepSessions: [
        night(2026, 11, 2),
        night(2026, 11, 3),
        // A zero-asleep session is a failed read — not a night.
        night(2026, 11, 4, asleep: 0),
        // A second bout ending the same wake day does not
        // double-count the night.
        (
          startMs: ms(2026, 11, 3, 13),
          endMs: ms(2026, 11, 3, 14),
          asleepMinutes: 60,
        ),
      ]));
      expect(v['nights_tracked'], 2);
    });

    test('full sleep week needs all 7 nights Mon-Sun', () {
      final sessions = [
        for (var d = 1; d <= 7; d++) night(2026, 11, d), // nights
        // ending Nov 2..Nov 8 (Mon-Sun week of Nov 2).
      ];
      final v = computeBadgeValues(BadgeInputs(sleepSessions: sessions));
      expect(v['nights_tracked'], 7);
      expect(v['sleep_week'], 1);
    });

    test('early to bed: onset by 22:00 counts; after midnight does not', () {
      final v = computeBadgeValues(BadgeInputs(sleepSessions: [
        night(2026, 11, 2, bedH: 21, bedM: 30), // in bed 9:30 PM ✓
        night(2026, 11, 3, bedH: 23, bedM: 15), // 11:15 PM ✗
        night(2026, 11, 4, bedH: 22, bedM: 0), // exactly 10 PM ✓
      ]));
      expect(v['early_to_bed'], 2);
      // A session starting after midnight (01:00) is not by 10 PM.
      final v2 = computeBadgeValues(BadgeInputs(sleepSessions: [
        (
          startMs: ms(2026, 11, 5, 1, 0),
          endMs: ms(2026, 11, 5, 7, 0),
          asleepMinutes: 300,
        ),
      ]));
      expect(v2['early_to_bed'], 0);
      expect(v2['nights_tracked'], 1);
    });

    test('a nap does not stand in for the night bedtime', () {
      // Both sessions end on Nov 3 (the same night by the
      // wake-day rule): an afternoon nap (60 asleep) and the main
      // night session starting 23:30 (420 asleep). The bedtime is
      // the main session's onset — 23:30 is not early.
      final v = computeBadgeValues(BadgeInputs(sleepSessions: [
        (
          startMs: ms(2026, 11, 3, 13),
          endMs: ms(2026, 11, 3, 14),
          asleepMinutes: 60,
        ),
        night(2026, 11, 2, bedH: 23, bedM: 30),
      ]));
      expect(v['early_to_bed'], 0);
      expect(v['nights_tracked'], 1);
    });
  });

  group('week helpers', () {
    test('badgeWeekMonday lands on the Monday of the week', () {
      expect(badgeWeekMonday('2026-11-02'), '2026-11-02'); // Monday
      expect(badgeWeekMonday('2026-11-08'), '2026-11-02'); // Sunday
      expect(badgeWeekMonday('2026-11-04'), '2026-11-02'); // Wednesday
      expect(badgeWeekDays('2026-11-02').length, 7);
      expect(badgeWeekDays('2026-11-02').last, '2026-11-08');
    });
  });
}
