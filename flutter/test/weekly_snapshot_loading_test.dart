import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/data/weekly_snapshot_cache.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';

/// Founder spec (Oct 26, 2026): the Weekly Snapshot must never flash its
/// no-data state while the week is still loading. Loading shows a loading
/// state; the empty state may appear only when a load completes with no
/// data or after 30 s with nothing loaded; late data still swaps in.
void main() {
  WeeklySnapshotMetricData dataWithValues(SnapshotMetric metric) {
    final now = DateTime.now();
    return WeeklySnapshotMetricData(
      metric: metric,
      points: List.generate(7, (i) {
        final d = now.subtract(Duration(days: 6 - i));
        return DailySnapshotPoint(
          dateStr: d.toIso8601String().substring(0, 10),
          dayLabel: 'D$i',
          value: 6.0 + i * 0.25,
        );
      }),
      averageOrTotalText: '7-Day Avg: 6.8 hrs',
    );
  }

  Widget wrap(
    Future<WeeklySnapshotMetricData> Function(SnapshotMetric) load, {
    WeeklySnapshotCache? cache,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          // Session-cache fix (Oct 30, 2026): every case gets its own
          // cache instance unless it passes a shared one — the
          // production default is the app-session singleton, and
          // entries must never leak across cases through it.
          child: WeeklySnapshotCard(
            loadData: load,
            cache: cache ?? WeeklySnapshotCache.testInstance(),
          ),
        ),
      ),
    );
  }

  testWidgets('entry shows loading, not the empty state', (tester) async {
    final completer = Completer<WeeklySnapshotMetricData>();
    await tester.pumpWidget(wrap((_) => completer.future));
    await tester.pump();

    expect(find.text('Loading your week...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Not enough sleep data yet'), findsNothing);
    expect(find.text('No data available past 7 days'), findsNothing);

    completer.complete(dataWithValues(SnapshotMetric.sleepHours));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Loading your week...'), findsNothing);
    expect(find.text('7-Day Avg: 6.8 hrs'), findsOneWidget);
  });

  testWidgets('never-resolving load: empty only at 30 s, late data swaps in',
      (tester) async {
    final completer = Completer<WeeklySnapshotMetricData>();
    await tester.pumpWidget(wrap((_) => completer.future));
    await tester.pump();

    // 29 s in: still loading, still no empty state.
    await tester.pump(const Duration(seconds: 29));
    expect(find.text('Loading your week...'), findsOneWidget);
    expect(find.text('Not enough sleep data yet'), findsNothing);
    expect(find.text('No data available past 7 days'), findsNothing);

    // At 30 s the empty state may appear.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Loading your week...'), findsNothing);
    expect(find.text('Not enough sleep data yet'), findsOneWidget);

    // Data arriving after the 30 s mark replaces the empty state.
    completer.complete(dataWithValues(SnapshotMetric.sleepHours));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Not enough sleep data yet'), findsNothing);
    expect(find.text('7-Day Avg: 6.8 hrs'), findsOneWidget);
  });

  testWidgets('load completing empty shows the empty state, not loading',
      (tester) async {
    await tester.pumpWidget(
        wrap((m) async => emptyMetricData(SnapshotMetric.sleepHours)));
    await tester.pump();
    await tester.pump();

    expect(find.text('Loading your week...'), findsNothing);
    expect(find.text('Not enough sleep data yet'), findsOneWidget);
  });

  // Screen-load perf (Oct 26, 2026): per-metric result cache.
  WeeklySnapshotMetricData namedData(SnapshotMetric metric) {
    final now = DateTime.now();
    return WeeklySnapshotMetricData(
      metric: metric,
      points: List.generate(7, (i) {
        final d = now.subtract(Duration(days: 6 - i));
        return DailySnapshotPoint(
          dateStr: d.toIso8601String().substring(0, 10),
          dayLabel: 'D$i',
          value: 5.0 + i,
        );
      }),
      averageOrTotalText: 'Avg for ${metric.displayName}',
    );
  }

  Future<void> switchTo(WidgetTester tester, String displayName) async {
    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text(displayName).last);
    await tester.pump();
  }

  testWidgets(
      'switch back to a loaded metric: cached data instantly, no '
      'loading label, loader not re-called for the paint', (tester) async {
    final calls = <SnapshotMetric, int>{};
    Future<WeeklySnapshotMetricData> loader(SnapshotMetric m) {
      calls[m] = (calls[m] ?? 0) + 1;
      return Future.value(namedData(m));
    }

    await tester.pumpWidget(wrap(loader));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    // Metric A (Sleep Hours, the default) loaded once.
    expect(find.text('Avg for Sleep Hours'), findsOneWidget);
    expect(calls[SnapshotMetric.sleepHours], 1);

    // Switch to metric B: a real first load for B.
    await switchTo(tester, 'Resting Heart Rate');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Avg for Resting Heart Rate'), findsOneWidget);
    expect(find.text('Avg for Sleep Hours'), findsNothing);
    expect(calls[SnapshotMetric.restingHeartRate], 1);

    // Switch back to A: its cached data paints immediately — no
    // loading state, and the paint did NOT come from a new loader
    // call (the background revalidation is deferred past this frame).
    await switchTo(tester, 'Sleep Hours');
    expect(find.text('Avg for Sleep Hours'), findsOneWidget);
    expect(find.text('Loading your week...'), findsNothing);
    expect(calls[SnapshotMetric.sleepHours], 1,
        reason: 'switch-back paint must come from the per-metric '
            'cache, not a fresh load');

    // The revalidation then runs behind the painted cache and swaps
    // fresh data in without any loading state.
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(calls[SnapshotMetric.sleepHours], 2,
        reason: 'cache hit still revalidates in the background');
    expect(find.text('Avg for Sleep Hours'), findsOneWidget);
    expect(find.text('Loading your week...'), findsNothing);
  });

  testWidgets('a failed load does not poison the per-metric cache',
      (tester) async {
    final calls = <SnapshotMetric, int>{};
    var failSleep = true;
    // The return load for Sleep Hours is held open so the loading
    // state is observable mid-flight (an instantly-resolving future
    // would complete inside the same pump that starts it).
    final sleepRetry = Completer<WeeklySnapshotMetricData>();
    Future<WeeklySnapshotMetricData> loader(SnapshotMetric m) {
      calls[m] = (calls[m] ?? 0) + 1;
      if (m == SnapshotMetric.sleepHours && failSleep) {
        return Future.error(StateError('boom'));
      }
      if (m == SnapshotMetric.sleepHours) return sleepRetry.future;
      return Future.value(namedData(m));
    }

    await tester.pumpWidget(wrap(loader));
    await tester.pump();
    await tester.pump();
    // Failed first load: the honest empty state (pre-cache behavior),
    // and nothing was cached for Sleep Hours.
    expect(find.text('Not enough sleep data yet'), findsOneWidget);
    expect(calls[SnapshotMetric.sleepHours], 1);

    // Visit B, fix the failure, come back to A: A runs the normal
    // loading flow again (a cached failure would have painted the
    // empty state instantly instead) and now loads for real.
    await switchTo(tester, 'Resting Heart Rate');
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Avg for Resting Heart Rate'), findsOneWidget);
    failSleep = false;
    await switchTo(tester, 'Sleep Hours');
    expect(find.text('Loading your week...'), findsOneWidget,
        reason: 'a failed load must not be served from the cache — '
            'the metric loads fresh on return');
    sleepRetry.complete(namedData(SnapshotMetric.sleepHours));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Avg for Sleep Hours'), findsOneWidget);
    expect(calls[SnapshotMetric.sleepHours], 2);
  });

  testWidgets('metric switch restarts the loading cycle', (tester) async {
    final completers = <SnapshotMetric, Completer<WeeklySnapshotMetricData>>{};
    Future<WeeklySnapshotMetricData> loader(SnapshotMetric m) {
      if (m == SnapshotMetric.sleepHours) {
        return Future.value(dataWithValues(m));
      }
      return (completers[m] ??= Completer<WeeklySnapshotMetricData>()).future;
    }

    await tester.pumpWidget(wrap(loader));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('7-Day Avg: 6.8 hrs'), findsOneWidget);

    // Switch to Resting Heart Rate, whose load never resolves.
    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Resting Heart Rate').last);
    await tester.pump();

    // New metric is loading again: no stale content, no empty flash.
    expect(find.text('Loading your week...'), findsOneWidget);
    expect(find.text('No heart rate data logged past 7 days'), findsNothing);
    expect(find.text('7-Day Avg: 6.8 hrs'), findsNothing);

    // Clean up the pending timer so the test can end.
    await tester.pump(const Duration(seconds: 30));
    expect(find.text('No heart rate data logged past 7 days'), findsOneWidget);
  });

  // Session-cache fix (Oct 30, 2026): the per-metric cache outlives
  // the card State (MainShell destroys Home on every tab switch), so
  // a return visit paints instantly and revalidates in the
  // background instead of running the foreground load again.
  group('session cache (dispose + recreate)', () {
    WeeklySnapshotMetricData versionedData(String avgText) {
      final now = DateTime.now();
      return WeeklySnapshotMetricData(
        metric: SnapshotMetric.sleepHours,
        points: List.generate(7, (i) {
          final d = now.subtract(Duration(days: 6 - i));
          return DailySnapshotPoint(
            dateStr: d.toIso8601String().substring(0, 10),
            dayLabel: 'D$i',
            value: 5.0 + i,
          );
        }),
        averageOrTotalText: avgText,
      );
    }

    testWidgets(
        'recreated card paints the cached week with NO loading state '
        'while revalidation is pending; updated data swaps in',
        (tester) async {
      final cache = WeeklySnapshotCache.testInstance();
      final revalidation = Completer<WeeklySnapshotMetricData>();
      var calls = 0;
      Future<WeeklySnapshotMetricData> loader(SnapshotMetric m) {
        calls++;
        // First load resolves immediately; the return visit's
        // background revalidation is held open on [revalidation].
        return calls == 1
            ? Future.value(versionedData('Avg v1'))
            : revalidation.future;
      }

      // First visit: normal foreground load, result cached.
      await tester.pumpWidget(wrap(loader, cache: cache));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Avg v1'), findsOneWidget);
      expect(calls, 1);

      // Leave Home: the card State is destroyed (tab switch).
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: SizedBox())));
      await tester.pump();

      // Return: a fresh card State over the SAME session cache paints
      // the cached week immediately — no loading state — while the
      // background revalidation is still pending.
      await tester.pumpWidget(wrap(loader, cache: cache));
      await tester.pump();
      expect(find.text('Avg v1'), findsOneWidget);
      expect(find.text('Loading your week...'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      // The revalidation runs behind the paint...
      await tester.pump(const Duration(milliseconds: 1));
      expect(calls, 2,
          reason: 'return visit must revalidate in the background');
      expect(find.text('Avg v1'), findsOneWidget);
      expect(find.text('Loading your week...'), findsNothing);

      // ...and its result swaps in when it completes.
      revalidation.complete(versionedData('Avg v2'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Avg v2'), findsOneWidget);
      expect(find.text('Avg v1'), findsNothing);
      expect(find.text('Loading your week...'), findsNothing);
    });

    testWidgets(
        'cold first load with an empty shared cache still shows the '
        'loading state', (tester) async {
      final cache = WeeklySnapshotCache.testInstance();
      final completer = Completer<WeeklySnapshotMetricData>();
      await tester.pumpWidget(wrap((_) => completer.future, cache: cache));
      await tester.pump();

      expect(find.text('Loading your week...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Not enough sleep data yet'), findsNothing);

      completer.complete(versionedData('Avg v1'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Avg v1'), findsOneWidget);
    });

    testWidgets(
        'an entry stamped for a previous day does NOT instant-paint: '
        'the recreated card runs the normal foreground flow',
        (tester) async {
      final cache = WeeklySnapshotCache.testInstance();
      // Seed the shared cache as if yesterday's visit loaded fine.
      cache.store(
        SnapshotMetric.sleepHours,
        versionedData('Avg yesterday'),
        loadedAt: DateTime.now().subtract(const Duration(days: 1)),
      );
      expect(cache.lookup(SnapshotMetric.sleepHours), isNull,
          reason: 'a previous-day entry is a miss, never a paint');

      final completer = Completer<WeeklySnapshotMetricData>();
      await tester.pumpWidget(wrap((_) => completer.future, cache: cache));
      await tester.pump();

      // Yesterday's week must not paint as the current week: the
      // card is in the foreground loading state instead.
      expect(find.text('Avg yesterday'), findsNothing);
      expect(find.text('Loading your week...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completer.complete(versionedData('Avg today'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Avg today'), findsOneWidget);
      expect(find.text('Loading your week...'), findsNothing);
    });
  });
}
