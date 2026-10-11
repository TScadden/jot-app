import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';

void main() {
  group('TodaySummaryCard', () {
    testWidgets('renders title, subtitle, and chevron; collapsed by default',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TodaySummaryCard())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Today Summary'), findsOneWidget);
      // Header subtitle only — expanded content (with its second
      // "No plans recorded today") is hidden while collapsed.
      expect(find.text('No plans recorded today'), findsOneWidget);
      expect(find.text("Today's Plan"), findsNothing);
      expect(find.text('Trends'), findsNothing);
      expect(find.text('Not enough data yet'), findsNothing);
      // Chevron points down when collapsed.
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
    });

    testWidgets('tapping expands the collapsed card', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TodaySummaryCard())),
      );
      await tester.pumpAndSettle();

      // Starts collapsed.
      expect(find.text("Today's Plan"), findsNothing);

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();
      expect(find.text("Today's Plan"), findsOneWidget);
      expect(find.text('Trends'), findsOneWidget);
      expect(find.text('Not enough data yet'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
    });

    testWidgets('chevron toggles expand/collapse', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TodaySummaryCard())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.keyboard_arrow_down));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.keyboard_arrow_up), findsOneWidget);
      expect(find.text("Today's Plan"), findsOneWidget);

      await tester.tap(find.byIcon(Icons.keyboard_arrow_up));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.text("Today's Plan"), findsNothing);
    });
  });

  group('WeeklySnapshotCard', () {
    testWidgets('renders header, selector, and empty state for default metric',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WeeklySnapshotCard())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Weekly Snapshot'), findsOneWidget);
      // Default metric is Sleep Hours (native DEFAULT).
      expect(find.text('Sleep Hours'), findsOneWidget);
      // Empty state — native aggregator message, no invented data.
      expect(find.text('Not enough sleep data yet'), findsOneWidget);
    });

    testWidgets('dropdown lists all 7 metrics and switching works',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WeeklySnapshotCard())),
      );
      await tester.pumpAndSettle();

      // Open the dropdown.
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();

      for (final m in SnapshotMetric.values) {
        expect(find.text(m.displayName), findsWidgets);
      }

      // Switch to Resting Heart Rate.
      await tester.tap(find.text('Resting Heart Rate').last);
      await tester.pumpAndSettle();
      expect(
          find.text('No heart rate data logged past 7 days'), findsOneWidget);

      // Switch to Logs — real zero count, not an empty state.
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Logs').last);
      await tester.pumpAndSettle();
      expect(find.text('7-Day Total: 0 logs'), findsOneWidget);
      // No empty-state message for Logs.
      expect(find.text('No data available past 7 days'), findsNothing);
    });

    testWidgets('each metric shows its native empty message', (tester) async {
      const expected = {
        SnapshotMetric.sleepHours: 'Not enough sleep data yet',
        SnapshotMetric.restingHeartRate:
            'No heart rate data logged past 7 days',
        SnapshotMetric.hrSpikes: 'Could not load HR spike records',
        SnapshotMetric.calories: 'No calorie data logged past 7 days',
        SnapshotMetric.habitCompletion: 'No habits configured',
        SnapshotMetric.bloodPressure: 'No blood pressure records found',
      };
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WeeklySnapshotCard())),
      );
      await tester.pumpAndSettle();

      for (final entry in expected.entries) {
        await tester.tap(find.byIcon(Icons.arrow_drop_down));
        await tester.pumpAndSettle();
        await tester.tap(find.text(entry.key.displayName).last);
        await tester.pumpAndSettle();
        expect(find.text(entry.value), findsOneWidget,
            reason: 'empty message for ${entry.key.displayName}');
      }
    });

    testWidgets('emptyMetricData never invents values', (tester) async {
      for (final m in SnapshotMetric.values) {
        final data = emptyMetricData(m);
        expect(data.points, hasLength(7));
        if (m == SnapshotMetric.logs) {
          // Real zeros only.
          expect(data.points.every((p) => p.value == 0), isTrue);
        } else {
          expect(data.points.every((p) => p.value == null), isTrue,
              reason: '${m.displayName} must have all-null points');
        }
      }
    });
  });
}
