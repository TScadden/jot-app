import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/features/tools/community_screen.dart';
import 'package:tabs_lab/src/features/tools/key_metrics_screen.dart';
import 'package:tabs_lab/src/features/tools/sleep_screen.dart';

/// R61 — founder ruling (Oct 15, 2026, closing design flag M1):
/// sleep durations read compact `7h6m` EVERYWHERE, through the single
/// shared `formatSleepMinutes`. These tests pin the compact form at
/// every site that previously rendered the spaced `7h 6m` form, and
/// assert the spaced form never appears. (The Health Coach context
/// strings are pinned in tools_r55_test.dart; the Sleep screen widget
/// strings in tools_team_b_test.dart / tools_r48b_test.dart /
/// tools_r18b_test.dart.)
void main() {
  group('Sleep screen hero formatter (was spaced "7h 30m")', () {
    test('renders compact', () {
      expect(formatSleepHeroMins(426), '7h6m');
      expect(formatSleepHeroMins(450), '7h30m');
      expect(formatSleepHeroMins(480), '8h0m');
      expect(formatSleepHeroMins(45), '45m');
    });
  });

  group('Community friend sleep (was spaced "2h 5m")', () {
    test('renders compact, keeps null/zero-debt sentinels', () {
      expect(formatFriendSleep(426), '7h6m');
      expect(formatFriendSleep(125), '2h5m');
      expect(formatFriendSleep(480), '8h0m');
      expect(formatFriendSleep(45), '45m');
      expect(formatFriendSleep(null), '·');
      expect(formatFriendSleepDebt(-426), '-7h6m');
      expect(formatFriendSleepDebt(-90), '-1h30m');
      expect(formatFriendSleepDebt(-45), '-45m');
      expect(formatFriendSleepDebt(0), 'None');
      expect(formatFriendSleepDebt(null), '·');
    });
  });

  group('Key Metrics CSV export (was spaced "7h 30m")', () {
    test('sleep and deep-sleep columns render compact', () {
      final csv = buildMetricsCsv(
        datesDesc: const ['2026-10-15'],
        avgHrByDate: const {'2026-10-15': 72},
        sleepByDate: const {'2026-10-15': 426},
        deepByDate: const {'2026-10-15': 76},
        spikesByDate: const {'2026-10-15': 0},
      );
      expect(csv, contains('7h6m'));
      expect(csv, contains('1h16m'));
      expect(csv, isNot(contains('7h 6m')));
      expect(csv, isNot(contains('1h 16m')));
    });
  });

  group('Weekly Snapshot sleep average (was spaced "7-Day Avg: 7h 45m")', () {
    test('buildSleepMetric renders compact', () {
      final dates = [for (var i = 9; i <= 15; i++) '2026-10-$i'];
      final data = buildSleepMetric(
        dates,
        const ['Fri', 'Sat', 'Sun', 'Mon', 'Tue', 'Wed', 'Thu'],
        {for (final d in dates) d: 450},
      );
      expect(data.averageOrTotalText, '7-Day Avg: 7h30m');
      expect(data.averageOrTotalText, isNot(contains('7h 30m')));
    });

    testWidgets('card average line + chart tooltip render compact',
        (tester) async {
      final dates = [for (var i = 9; i <= 15; i++) '2026-10-$i'];
      final data = buildSleepMetric(
        dates,
        const ['Fri', 'Sat', 'Sun', 'Mon', 'Tue', 'Wed', 'Thu'],
        {for (final d in dates) d: 450},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WeeklySnapshotCard(loadData: (_) async => data),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('7-Day Avg: 7h30m'), findsOneWidget);
      expect(find.textContaining('7h 30m'), findsNothing);

      // Tap the chart → tooltip for the tapped day renders via the
      // same shared formatter (was "7h 30m").
      await tester.tap(
        find
            .descendant(
              of: find.byType(WeeklySnapshotCard),
              matching: find.byType(CustomPaint),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('): 7h30m'), findsOneWidget);
      expect(find.textContaining('7h 30m'), findsNothing);
    });
  });

  group('Today Summary sleep comparison (was spaced "7h 0m today")', () {
    test('buildTrendComparisons renders compact', () {
      final out = buildTrendComparisons(
        sleepMinutesByDate: const {
          '2026-10-15': 426,
          '2026-10-14': 400,
          '2026-10-13': 410,
          '2026-10-12': 420,
        },
        restingHrByDate: const {},
        symptomLogCount: 0,
        todayStr: '2026-10-15',
      );
      final sleep = out.singleWhere((c) => c.metricName == 'Sleep Duration');
      expect(sleep.currentPeriod, '7h6m today');
      expect(sleep.comparisonPeriod, '7-day avg (6h50m)');
      expect(sleep.currentPeriod, isNot(contains('7h 6m')));
      expect(sleep.comparisonPeriod, isNot(contains('6h 50m')));
    });
  });

  group('no spaced sleep form at any pinned site', () {
    test('canonical 426 minutes is "7h6m", never "7h 6m"', () {
      final rendered = [
        formatSleepHeroMins(426),
        formatFriendSleep(426),
        formatFriendSleepDebt(-426),
      ];
      for (final s in rendered) {
        expect(s, isNot(contains('7h 6m')), reason: s);
        expect(s, contains('7h6m'), reason: s);
      }
      // buildSleepMetric averages in double hours with the native
      // truncation split, so its pinned value uses an exact-hours
      // input: 450m renders "7h30m", never the spaced "7h 30m".
      final avg = buildSleepMetric(
        const ['2026-10-15'],
        const ['Thu'],
        const {'2026-10-15': 450},
      ).averageOrTotalText;
      expect(avg, contains('7h30m'));
      expect(avg, isNot(contains('7h 30m')));
    });
  });
}
