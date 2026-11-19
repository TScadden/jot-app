import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';

/// Streak engine v2 (streak upgrade, Nov 18, 2026; design SIGNED
/// round 3): Tabs-day anchor, freeze-economy bridging, the A1 cap
/// accounting, B1 accrual rollover, v1→v2 migration, A6 seeding
/// anchors, and the milestone ladder.
void main() {
  DateTime at(int y, int m, int d, [int h = 12]) => DateTime(y, m, d, h);

  StreakState state({
    Set<String> counted = const {},
    Set<String> restored = const {},
    Set<String> consumed = const {},
    Set<String> spoiled = const {},
    int earned = 0,
    int purchased = 0,
    bool pending = false,
    String accrual = '2026-01',
    int ffmc = 0,
    String? lastEval,
  }) => StreakState(
    seeded: true,
    countedDays: counted,
    restoredDays: restored,
    consumedSaveMonths: consumed,
    spoiledMonths: spoiled,
    earnedFreezes: earned,
    purchasedFreezes: purchased,
    earnedPending: pending,
    accrualMonth: accrual,
    freezeFreeMonthsCompleted: ffmc,
    lastEvaluatedDay: lastEval,
  );

  group('tabsDayAnchor (A7)', () {
    test('before 04:00 the Tabs day is still yesterday', () {
      expect(tabsDayStr(at(2026, 3, 1, 2)), '2026-02-28');
      expect(tabsDayStr(at(2026, 3, 1, 3)), '2026-02-28');
    });

    test('at and after 04:00 the Tabs day is today', () {
      expect(tabsDayStr(at(2026, 3, 1, 4)), '2026-03-01');
      expect(tabsDayStr(at(2026, 3, 1, 12)), '2026-03-01');
    });
  });

  group('settle (D3): settlement never counts a day', () {
    test('gap of zero: counted days unchanged, stamp advances', () {
      final s = state(counted: {'2026-11-03'}, accrual: '2026-11');
      final next = settle(s, at(2026, 11, 4));
      expect(next.countedDays, {'2026-11-03'});
      expect(next.lastEvaluatedDay, '2026-11-04');
    });

    test('a bridged day enters BOTH countedDays and restoredDays', () {
      final s = state(counted: {'2026-11-02'}, accrual: '2026-11');
      final r = settleDetailed(s, at(2026, 11, 4));
      expect(r.bridgedDays, ['2026-11-03']);
      expect(r.state.countedDays, contains('2026-11-03'));
      expect(r.state.restoredDays, contains('2026-11-03'));
      expect(r.state.countedDays.contains('2026-11-04'), isFalse);
      expect(r.brokeStreak, isFalse);
    });
  });

  group('bridging (A5): chronological per-day draw, purchased first', () {
    test('one missed day draws the purchased freeze before earned', () {
      final s = state(
        counted: {'2026-01-09', '2026-01-10'},
        earned: 1,
        purchased: 1,
      );
      final r = settleDetailed(s, at(2026, 1, 12));
      expect(r.freezeUsedKinds['2026-01-11'], FreezeKind.purchased);
      expect(r.state.purchasedFreezes, 0);
      expect(r.state.earnedFreezes, 1);
      // Spoils attribution: the missed day's month.
      expect(r.state.spoiledMonths, contains('2026-01'));
    });

    test('two missed days draw purchased, then earned', () {
      final s = state(counted: {'2026-01-10'}, earned: 1, purchased: 1);
      final r = settleDetailed(s, at(2026, 1, 13));
      expect(r.freezeUsedKinds['2026-01-11'], FreezeKind.purchased);
      expect(r.freezeUsedKinds['2026-01-12'], FreezeKind.earned);
      expect(r.state.purchasedFreezes, 0);
      expect(r.state.earnedFreezes, 0);
    });

    test('the monthly grant drawn is the missed day\'s month', () {
      final jan31 = state(counted: {'2026-01-30'});
      final r1 = settleDetailed(jan31, at(2026, 2, 1));
      expect(r1.freezeUsedKinds['2026-01-31'], FreezeKind.monthly);
      expect(r1.state.consumedSaveMonths, contains('2026-01'));
      expect(r1.state.consumedSaveMonths.contains('2026-02'), isFalse);
      expect(r1.state.spoiledMonths, contains('2026-01'));

      final feb1 = state(counted: {'2026-01-31'});
      final r2 = settleDetailed(feb1, at(2026, 2, 2));
      expect(r2.freezeUsedKinds['2026-02-01'], FreezeKind.monthly);
      expect(r2.state.consumedSaveMonths, contains('2026-02'));
    });

    test('a gap spanning a month boundary draws each month\'s grant', () {
      final s = state(counted: {'2026-01-30'});
      final r = settleDetailed(s, at(2026, 2, 2));
      // Jan 31 from January's grant, Feb 1 from February's.
      expect(r.freezeUsedKinds['2026-01-31'], FreezeKind.monthly);
      expect(r.freezeUsedKinds['2026-02-01'], FreezeKind.monthly);
      expect(r.brokeStreak, isFalse);
    });

    test('an unbridgeable gap consumes NOTHING and breaks the run', () {
      final s = state(counted: {'2026-01-10'}, earned: 1, purchased: 1);
      // Jan 11–14 missed: purchased + earned + January's grant
      // cover three; the fourth day fails, so nothing is consumed.
      final r = settleDetailed(s, at(2026, 1, 15));
      expect(r.brokeStreak, isTrue);
      expect(r.state.purchasedFreezes, 1);
      expect(r.state.earnedFreezes, 1);
      expect(r.state.consumedSaveMonths, isEmpty);
      expect(r.state.restoredDays, isEmpty);
      expect(r.state.spoiledMonths, isEmpty);
      expect(r.state.countedDays, {'2026-01-10'});
    });
  });

  group('A1: pending landing needs BOTH clauses', () {
    test('a total slot free but the earned slot held: NO landing '
        '(the Vera corollary counterexample)', () {
      // Monthly grant for January already used, so cover =
      // 0 + earned 1 + purchased 1 = 2 < cap 3 — a total slot is
      // free, but the earned slot is occupied by the held freeze.
      final s = state(
        counted: {'2026-01-10'},
        consumed: {'2026-01'},
        earned: 1,
        purchased: 1,
        pending: true,
      );
      final next = settle(s, at(2026, 1, 11));
      expect(next.earnedFreezes, 1);
      expect(next.earnedPending, isTrue);
    });

    test('earned slot free and cover under cap: the pending '
        'freeze lands', () {
      final s = state(
        counted: {'2026-01-10'},
        consumed: {'2026-01'},
        earned: 0,
        purchased: 1,
        pending: true,
      );
      final next = settle(s, at(2026, 1, 11));
      expect(next.earnedFreezes, 1);
      expect(next.earnedPending, isFalse);
    });

    test('pending lands on a plain settle when only the monthly '
        'grant stands in the way', () {
      final s = state(
        counted: {'2026-01-10'},
        earned: 0,
        purchased: 0,
        pending: true,
      );
      final next = settle(s, at(2026, 1, 11));
      expect(next.earnedFreezes, 1);
      expect(next.earnedPending, isFalse);
    });
  });

  group('B1: accrual rollover', () {
    test('a freeze-free month the streak was alive in closes: '
        'counter increments and the earned freeze is granted', () {
      final s = state(counted: {'2026-01-05', '2026-01-20'});
      final next = settle(s, at(2026, 2, 3));
      expect(next.freezeFreeMonthsCompleted, 1);
      expect(next.earnedFreezes, 1);
      expect(next.earnedPending, isFalse);
      expect(next.accrualMonth, '2026-02');
    });

    test('attribution before close: a Jan 31 bridge spoils '
        'January in the same settlement that closes it', () {
      final s = state(counted: {'2026-01-30'});
      final next = settle(s, at(2026, 2, 1));
      expect(next.restoredDays, contains('2026-01-31'));
      expect(next.freezeFreeMonthsCompleted, 0);
      expect(next.earnedFreezes, 0);
      expect(next.accrualMonth, '2026-02');
    });

    test('inactive months mint nothing and do NOT reset the '
        'count (pause semantics)', () {
      final s = state(counted: {'2026-01-10'});
      final next = settle(s, at(2026, 4, 2));
      // January qualifies (+1, earned granted); February and
      // March had no counted/restored day — they mint nothing.
      expect(next.freezeFreeMonthsCompleted, 1);
      expect(next.earnedFreezes, 1);
      expect(next.accrualMonth, '2026-04');
    });

    test('multi-month catch-up resolves each due in order: the '
        'second due queues as pending behind the held earned', () {
      final s = state(counted: {'2026-01-10', '2026-02-10'});
      final next = settle(s, at(2026, 3, 2));
      expect(next.freezeFreeMonthsCompleted, 2);
      expect(next.earnedFreezes, 1);
      expect(next.earnedPending, isTrue);
      expect(next.accrualMonth, '2026-03');
    });

    test('a spoiled-but-alive month only fails to increment — '
        'the counter never decrements', () {
      final s = state(counted: {'2026-01-10'}, spoiled: {'2026-01'}, ffmc: 3);
      final next = settle(s, at(2026, 2, 2));
      expect(next.freezeFreeMonthsCompleted, 3);
      expect(next.earnedFreezes, 0);
      expect(next.earnedPending, isFalse);
    });

    test('a due arriving while one is held AND one is pending '
        'does not bank, but the month still counts', () {
      final s = state(counted: {'2026-01-10'}, earned: 1, pending: true);
      final next = settle(s, at(2026, 2, 2));
      expect(next.freezeFreeMonthsCompleted, 1);
      expect(next.earnedFreezes, 1);
      expect(next.earnedPending, isTrue);
    });

    test('spoiledMonths prunes only old, already-closed months', () {
      final s = state(
        counted: {'2026-11-02'},
        spoiled: {'2024-01', '2026-10'},
        accrual: '2026-11',
      );
      final next = settle(s, at(2026, 11, 3));
      expect(next.spoiledMonths.contains('2024-01'), isFalse);
      expect(next.spoiledMonths, contains('2026-10'));
    });
  });

  group('migration v1 → v2 (A4 + B1)', () {
    Map<String, dynamic> v1Blob(Set<String> consumed) => {
      'v': 1,
      'seeded': true,
      'seededCurrent': 5,
      'seededBest': 9,
      'countedDays': ['2026-11-02'],
      'restoredDays': <String>[],
      'consumedSaveMonths': consumed.toList(),
      'lastEvaluatedDay': '2026-11-02',
    };

    test('lossless: counters and days carry; new fields derive '
        'per A4, never inferred', () {
      final s = StreakState.fromJson(
        v1Blob({'2026-11'}),
        migrationNow: at(2026, 11, 10),
      );
      expect(s.seededCurrent, 5);
      expect(s.seededBest, 9);
      expect(s.countedDays, {'2026-11-02'});
      expect(s.earnedFreezes, 0);
      expect(s.purchasedFreezes, 0);
      expect(s.earnedPending, isFalse);
      expect(s.freezeFreeMonthsCompleted, 0);
      expect(s.accrualMonth, '2026-11');
      // spoiledMonths seeds from consumedSaveMonths…
      expect(s.spoiledMonths, {'2026-11'});
      // …so a pre-upgrade Restore THIS month spoils this month's
      // accrual instead of fabricating an earned freeze.
      expect(s.freezeUsedInAccrualMonth, isTrue);
      expect(s.toJson()['v'], 2);
    });

    test('a Restore in a PRIOR month does not spoil this month', () {
      final s = StreakState.fromJson(
        v1Blob({'2026-10'}),
        migrationNow: at(2026, 11, 10),
      );
      expect(s.spoiledMonths, {'2026-10'});
      expect(s.freezeUsedInAccrualMonth, isFalse);
    });

    test('v2 JSON round-trips exactly', () {
      final s = state(
        counted: {'2026-01-10'},
        consumed: {'2026-01'},
        spoiled: {'2026-01'},
        earned: 1,
        pending: true,
        ffmc: 2,
        lastEval: '2026-01-10',
      );
      expect(StreakState.fromJson(s.toJson()), s);
    });
  });

  group('seeding anchors (A6)', () {
    test('adoption seeding anchors the run on the PRIOR Tabs day', () {
      // 02:00 on Nov 5 is still the Nov 4 Tabs day; the prior
      // Tabs day is Nov 3.
      final s = streakSeedForAdoption(
        current: 4,
        best: 9,
        now: at(2026, 11, 5, 2),
      );
      expect(s.countedDays, hasLength(4));
      expect(s.countedDays.contains('2026-11-03'), isTrue);
      expect(s.countedDays.contains('2026-11-04'), isFalse);
      expect(s.countedDays.contains('2026-11-05'), isFalse);
    });

    test('completion seeding anchors on the summary\'s own day', () {
      final s = streakSeedForCompletion(
        current: 4,
        best: 9,
        summaryTabsDay: '2026-11-05',
      );
      expect(s.countedDays, hasLength(4));
      expect(s.countedDays.contains('2026-11-05'), isTrue);
      expect(s.countedDays.contains('2026-11-02'), isTrue);
    });
  });

  group('cover, cap, milestones', () {
    test('totalAvailableCover counts the unused monthly grant', () {
      final s = state(earned: 1, purchased: 1, accrual: '2026-11');
      expect(totalAvailableCover(s, at(2026, 11, 5)), 3);
      expect(streakCap(s), 3);
      final used = state(
        earned: 1,
        purchased: 1,
        consumed: {'2026-11'},
        accrual: '2026-11',
      );
      expect(totalAvailableCover(used, at(2026, 11, 5)), 2);
      final noPurchase = state(earned: 1, accrual: '2026-11');
      expect(streakCap(noPurchase), 2);
    });

    test('the ladder and its +365 steps', () {
      for (final m in [7, 14, 30, 60, 90, 180, 365, 730]) {
        expect(isMilestone(m), isTrue, reason: '$m');
      }
      for (final n in [0, 1, 21, 100, 364, 400]) {
        expect(isMilestone(n), isFalse, reason: '$n');
      }
      expect(nextMilestone(0), 7);
      expect(nextMilestone(7), 14);
      expect(nextMilestone(20), 30);
      expect(nextMilestone(21), 30);
      expect(nextMilestone(365), 730);
      expect(nextMilestone(400), 730);
      expect(nextMilestone(730), 1095);
    });
  });

  group('completeDay (D1)', () {
    test('a consecutive completion counts the summary day', () {
      final s = state(
        counted: {'2026-11-01', '2026-11-02', '2026-11-03'},
        accrual: '2026-11',
      );
      final done = completeDay(
        s,
        summaryTabsDay: '2026-11-04',
        now: at(2026, 11, 4),
      );
      expect(done.state.countedDays, contains('2026-11-04'));
      expect(done.result.newCount, 4);
      expect(done.result.brokeStreak, isFalse);
      expect(done.result.isMilestone, isFalse);
      expect(done.state.lastEvaluatedDay, '2026-11-04');
    });

    test('reaching a ladder rung reports the milestone', () {
      final s = state(
        counted: {
          '2026-11-01',
          '2026-11-02',
          '2026-11-03',
          '2026-11-04',
          '2026-11-05',
          '2026-11-06',
        },
        accrual: '2026-11',
      );
      final done = completeDay(
        s,
        summaryTabsDay: '2026-11-07',
        now: at(2026, 11, 7),
      );
      expect(done.result.newCount, 7);
      expect(done.result.isMilestone, isTrue);
    });

    test('settlement bridges into the completion and reports it', () {
      final s = state(
        counted: {'2026-11-01', '2026-11-02'},
        accrual: '2026-11',
      );
      final done = completeDay(
        s,
        summaryTabsDay: '2026-11-04',
        now: at(2026, 11, 4),
      );
      expect(done.result.bridgedDays, ['2026-11-03']);
      expect(done.result.freezeUsedKinds['2026-11-03'], FreezeKind.monthly);
      expect(done.result.newCount, 4);
      expect(done.result.brokeStreak, isFalse);
    });

    test('an unbridgeable gap restarts the run at the summary '
        'day and consumes nothing', () {
      final s = state(
        counted: {'2026-11-01', '2026-11-02'},
        accrual: '2026-11',
      );
      final done = completeDay(
        s,
        summaryTabsDay: '2026-11-05',
        now: at(2026, 11, 5),
      );
      expect(done.result.brokeStreak, isTrue);
      expect(done.result.newCount, 1);
      expect(done.state.restoredDays, isEmpty);
      expect(done.state.consumedSaveMonths, isEmpty);
    });

    test('completing an already-counted day is a no-op', () {
      final s = state(
        counted: {'2026-11-01', '2026-11-02'},
        accrual: '2026-11',
      );
      final done = completeDay(
        s,
        summaryTabsDay: '2026-11-02',
        now: at(2026, 11, 2),
      );
      expect(done.result.newCount, 2);
      expect(done.state.countedDays, hasLength(2));
    });

    test('an earned freeze granted by the settlement\'s rollover '
        'reports earnedLanded', () {
      final s = state(counted: {'2026-01-10'});
      final done = completeDay(
        s,
        summaryTabsDay: '2026-02-01',
        now: at(2026, 2, 1),
      );
      expect(done.result.earnedLanded, isTrue);
      expect(done.state.earnedFreezes, 1);
      expect(done.result.newCount, 1);
    });
  });
}
