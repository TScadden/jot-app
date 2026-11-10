import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';

void main() {
  group('TodaySummaryCard', () {
    // Round 35 reconciliation: the card is wired to real data now
    // (it was an inert shell when these tests were written), so its
    // default services touch platform channels. Null-returning
    // handlers give the honest "nothing stored / not connected"
    // answers every other suite gets from injected fakes, and let
    // the loads complete under the widget-test fake-async zone
    // (the real secure-storage plugin performs genuine IO whose
    // completion pumpAndSettle never flushes). All assertions below
    // are unchanged from the original contract.
    setUp(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel(
            'com.notel.notel.playground.flutter/health_connect'),
        (call) async => null,
      );
    });

    testWidgets(
        'renders title and subtitle; collapsed by default, no chevron '
        '(home redesign: the card never expands in place)',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TodaySummaryCard())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Today Summary'), findsOneWidget);
      // Header subtitle only — the sheet content (with its second
      // "No plans recorded today") is hidden while collapsed.
      expect(find.text('No plans recorded today'), findsOneWidget);
      expect(find.text("Today's Plan"), findsNothing);
      expect(find.text('Trends'), findsNothing);
      expect(find.text('Not enough data yet'), findsNothing);
      // The header chevron is dropped under the redesign.
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
    });

    testWidgets('tapping the card opens the summary sheet',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TodaySummaryCard())),
      );
      await tester.pumpAndSettle();

      // Starts collapsed.
      expect(find.text("Today's Plan"), findsNothing);

      await tester.tap(find.text('Today Summary'));
      await tester.pumpAndSettle();
      expect(find.text("Today's Plan"), findsOneWidget);
      expect(find.text('Trends'), findsOneWidget);
      expect(find.text('Not enough data yet'), findsOneWidget);
    });

    testWidgets('the sheet dismisses via the scrim', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: TodaySummaryCard())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Today Summary'));
      await tester.pumpAndSettle();
      expect(find.text("Today's Plan"), findsOneWidget);

      await tester.tapAt(const Offset(400, 10));
      await tester.pumpAndSettle();
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

    testWidgets('dropdown lists all metrics and switching works',
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

    testWidgets(
        'dropdown panel is capped to the viewport at a constrained '
        'height, Morning Score scrolls into view and selects',
        (tester) async {
      // Constrained viewport height: 400 logical px tall (width
      // stays at the suite's usual 800 so the test font's wide
      // glyphs do not overflow the card header — a harness artifact
      // only). The selector sits near the top, so the uncapped
      // 8-row panel (>= 386dp) would run well past the 400dp
      // bottom edge — the exact founder defect (Blood Pressure
      // cut, Morning Score unreachable) reproduced at small scale.
      tester.view.physicalSize = const Size(800, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WeeklySnapshotCard())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();

      // (1) The panel's bottom edge is within the viewport.
      final panel = find.byKey(
        const ValueKey('weekly_snapshot_metric_panel'),
      );
      expect(panel, findsOneWidget);
      final panelRect = tester.getRect(panel);
      expect(panelRect.bottom, lessThanOrEqualTo(400));
      expect(panelRect.height, lessThan(8 * 48));

      // (2) Morning Score (8th option) can be scrolled into view
      // inside the capped panel.
      await tester.ensureVisible(find.text('Morning Score'));
      await tester.pumpAndSettle();
      final morningRect = tester.getRect(find.text('Morning Score').last);
      expect(morningRect.bottom, lessThanOrEqualTo(panelRect.bottom + 1));
      expect(morningRect.top, greaterThanOrEqualTo(panelRect.top - 1));

      // (3) Tapping it switches the selected metric.
      await tester.tap(find.text('Morning Score').last);
      await tester.pumpAndSettle();
      expect(find.text('No morning scores logged past 7 days'),
          findsOneWidget);
      // Dropdown closed after selection; the selector itself now
      // shows Morning Score.
      expect(panel, findsNothing);
      expect(find.text('Morning Score'), findsOneWidget);
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
