import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';

/// Lab (streak screen package, Nov 4, 2026) — the streak engine's
/// rules, pinned: native app-open semantics + the founder's monthly
/// save (one per calendar month, automatic, no rollover, drawn from
/// the missed day's month, covers exactly one missed day).
void main() {
  // All evaluations at local noon so no test rides a midnight edge.
  DateTime at(int y, int m, int d) => DateTime(y, m, d, 12);

  group('seeding from the profile pull', () {
    test('current run becomes counted days ending today', () {
      final s = streakSeed(current: 6, best: 12, now: at(2026, 11, 4));
      expect(s.seeded, isTrue);
      expect(s.countedDays.length, 6);
      expect(s.countedDays.contains('2026-11-04'), isTrue);
      expect(s.countedDays.contains('2026-10-30'), isTrue);
      expect(streakCurrent(s, at(2026, 11, 4)), 6);
      expect(streakBest(s), 12);
      // Best (12) predates day-level records: no range.
      expect(streakBestRange(s), isNull);
    });

    test('current == best at seed: the run IS the longest range', () {
      final s = streakSeed(current: 8, best: 8, now: at(2026, 9, 8));
      final range = streakBestRange(s);
      expect(range, isNotNull);
      expect(range!.start, '2026-09-01');
      expect(range.end, '2026-09-08');
    });

    test('zero current with a best (the reference state) seeds best only',
        () {
      final s = streakSeed(current: 0, best: 8, now: at(2026, 11, 4));
      expect(s.countedDays, isEmpty);
      expect(streakBest(s), 8);
      final next = streakEvaluate(s, at(2026, 11, 4));
      expect(streakCurrent(next, at(2026, 11, 4)), 1);
      expect(streakBest(next), 8);
    });
  });

  group('native app-open semantics', () {
    test('same-day evaluation is idempotent', () {
      final s = streakSeed(current: 3, best: 3, now: at(2026, 11, 4));
      final again = streakEvaluate(s, at(2026, 11, 4));
      expect(again, s);
      expect(streakCurrent(again, at(2026, 11, 4)), 3);
    });

    test('consecutive day increments the run', () {
      var s = streakSeed(current: 3, best: 3, now: at(2026, 11, 4));
      s = streakEvaluate(s, at(2026, 11, 5));
      expect(streakCurrent(s, at(2026, 11, 5)), 4);
      expect(streakBest(s), 4);
    });

    test('first ever open starts at 1', () {
      final s = streakEvaluate(StreakState.empty, at(2026, 11, 4));
      expect(streakCurrent(s, at(2026, 11, 4)), 1);
      expect(streakBest(s), 1);
    });

    test('best range tracks an engine-grown best', () {
      var s = streakSeed(current: 2, best: 2, now: at(2026, 11, 2));
      s = streakEvaluate(s, at(2026, 11, 3));
      s = streakEvaluate(s, at(2026, 11, 4));
      expect(streakBest(s), 4);
      final range = streakBestRange(s);
      expect(range!.start, '2026-11-01');
      expect(range.end, '2026-11-04');
    });
  });

  group('the monthly save', () {
    test('a single missed day is restored automatically and the streak '
        'continues', () {
      var s = streakSeed(current: 5, best: 5, now: at(2026, 11, 2));
      // Nov 3 missed; next open Nov 4.
      s = streakEvaluate(s, at(2026, 11, 4));
      expect(s.restoredDays, contains('2026-11-03'));
      expect(s.countedDays, contains('2026-11-03'));
      expect(streakCurrent(s, at(2026, 11, 4)), 7);
      expect(streakBest(s), 7);
      expect(streakSavesLeft(s, at(2026, 11, 4)), 0);
    });

    test('a second missed day in the same month breaks the streak', () {
      var s = streakSeed(current: 5, best: 5, now: at(2026, 11, 2));
      s = streakEvaluate(s, at(2026, 11, 4)); // Nov 3 restored.
      expect(streakCurrent(s, at(2026, 11, 4)), 7);
      // Nov 5 missed; next open Nov 6 — November's save is gone.
      s = streakEvaluate(s, at(2026, 11, 6));
      expect(s.restoredDays, isNot(contains('2026-11-05')));
      expect(streakCurrent(s, at(2026, 11, 6)), 1);
      expect(streakBest(s), 7);
    });

    test('a gap of two missed days breaks the streak and consumes '
        'nothing', () {
      var s = streakSeed(current: 5, best: 5, now: at(2026, 11, 2));
      // Nov 3 and Nov 4 missed; next open Nov 5.
      s = streakEvaluate(s, at(2026, 11, 5));
      expect(streakCurrent(s, at(2026, 11, 5)), 1);
      expect(s.restoredDays, isEmpty);
      expect(streakSavesLeft(s, at(2026, 11, 5)), 1);
    });

    test('month boundary: a Jan 31 miss is paid by January, not February',
        () {
      var s = streakSeed(current: 4, best: 4, now: at(2026, 1, 30));
      // Jan 31 missed; next open Feb 1.
      s = streakEvaluate(s, at(2026, 2, 1));
      expect(s.restoredDays, contains('2026-01-31'));
      expect(s.consumedSaveMonths, contains('2026-01'));
      expect(streakCurrent(s, at(2026, 2, 1)), 6);
      // February's own grant is untouched.
      expect(streakSavesLeft(s, at(2026, 2, 1)), 1);
    });

    test('month boundary: a Feb 1 miss is paid by February', () {
      var s = streakSeed(current: 4, best: 4, now: at(2026, 1, 31));
      // Feb 1 missed; next open Feb 2.
      s = streakEvaluate(s, at(2026, 2, 2));
      expect(s.restoredDays, contains('2026-02-01'));
      expect(s.consumedSaveMonths, contains('2026-02'));
      expect(streakSavesLeft(s, at(2026, 2, 2)), 0);
      expect(streakCurrent(s, at(2026, 2, 2)), 6);
    });

    test('no rollover: an unused save never accumulates', () {
      var s = streakSeed(current: 2, best: 2, now: at(2026, 1, 15));
      // Opens every day through January and February, no misses.
      for (var d = 16; d <= 31; d++) {
        s = streakEvaluate(s, at(2026, 1, d));
      }
      for (var d = 1; d <= 28; d++) {
        s = streakEvaluate(s, at(2026, 2, d));
      }
      // Still exactly one available in March — never two.
      expect(streakSavesLeft(s, at(2026, 3, 1)), 1);
      // A March miss consumes March's one save…
      s = streakEvaluate(s, at(2026, 3, 2));
      expect(s.restoredDays, contains('2026-03-01'));
      expect(streakSavesLeft(s, at(2026, 3, 2)), 0);
      // …and a second March miss breaks the streak: no banked save
      // from the quiet months rides to the rescue.
      s = streakEvaluate(s, at(2026, 3, 4));
      expect(streakCurrent(s, at(2026, 3, 4)), 1);
    });

    test('a fresh grant arrives with the new month after a break', () {
      var s = streakSeed(current: 3, best: 3, now: at(2026, 11, 28));
      s = streakEvaluate(s, at(2026, 11, 30)); // Nov 29 restored.
      expect(streakSavesLeft(s, at(2026, 11, 30)), 0);
      s = streakEvaluate(s, at(2026, 12, 1)); // consecutive.
      expect(streakSavesLeft(s, at(2026, 12, 1)), 1);
      // Dec 2 missed; Dec 3 open restores it with December's grant.
      s = streakEvaluate(s, at(2026, 12, 3));
      expect(s.restoredDays, contains('2026-12-02'));
      // Nov 26–28, Nov 29 restored, Nov 30, Dec 1, Dec 2 restored,
      // Dec 3: one unbroken run of 8.
      expect(streakCurrent(s, at(2026, 12, 3)), 8);
    });
  });

  group('derived views', () {
    test('counted days in month includes restored days', () {
      var s = streakSeed(current: 3, best: 3, now: at(2026, 11, 2));
      s = streakEvaluate(s, at(2026, 11, 4)); // Nov 3 restored.
      // Nov 1, 2, 3 (restored), 4 in November; Oct 31 in October.
      expect(streakCountedDaysInMonth(s, 2026, 11), 4);
      expect(streakCountedDaysInMonth(s, 2026, 10), 1);
    });

    test('current reads the run ending yesterday before evaluation', () {
      final s = streakSeed(current: 3, best: 3, now: at(2026, 11, 3));
      // Morning of Nov 4, before today's open is recorded: the
      // streak is still alive at 3.
      expect(streakCurrent(s, at(2026, 11, 4)), 3);
      // By Nov 5 with no Nov 4 open, the run no longer reaches.
      expect(streakCurrent(s, at(2026, 11, 5)), 0);
    });

    test('state JSON round-trips exactly', () {
      var s = streakSeed(current: 5, best: 9, now: at(2026, 11, 2));
      s = streakEvaluate(s, at(2026, 11, 4));
      final back = StreakState.fromJson(s.toJson());
      expect(back, s);
    });
  });
}
