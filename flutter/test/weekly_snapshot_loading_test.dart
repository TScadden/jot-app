import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
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

  Widget wrap(Future<WeeklySnapshotMetricData> Function(SnapshotMetric) load) {
    return MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: WeeklySnapshotCard(loadData: load),
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
}
