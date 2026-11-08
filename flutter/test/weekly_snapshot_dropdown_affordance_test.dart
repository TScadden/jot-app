import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Work package B (Nov 8, 2026) — scroll affordance for the Weekly
/// Snapshot metric dropdown.
///
/// Background: the Nov 6, 2026 overflow fix caps the dropdown panel
/// to the space available below the selector and scrolls the rows
/// inside that cap, but shipped with no scrollbar and no scroll
/// hint, so the last metric (Morning Score, row 8 of 8) sat below
/// the fold invisibly — the founder's Nov 8 report "I don't see the
/// 1-5 score". These tests prove the affordance added on top of the
/// UNCHANGED cap:
///  (a) a persistent, token-styled scrollbar plus a bottom fade are
///      present when the row list overflows the capped panel, and
///      the fade clears at scroll end;
///  (b) the scrollbar is inert and the fade absent when every row
///      fits inside the panel;
///  (c) the cap behavior itself is unchanged (the pre-existing cap
///      proof also still lives in weekly_snapshot_test.dart).
void main() {
  group('WeeklySnapshotCard dropdown scroll affordance', () {
    const panelKey = ValueKey('weekly_snapshot_metric_panel');
    const optionsKey = ValueKey('weekly_snapshot_metric_options');
    const scrollbarKey = ValueKey('weekly_snapshot_metric_scrollbar');
    const fadeKey = ValueKey('weekly_snapshot_metric_bottom_fade');

    Future<void> openDropdown(WidgetTester tester, Size physicalSize) async {
      tester.view.physicalSize = physicalSize;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: WeeklySnapshotCard())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
      expect(find.byKey(panelKey), findsOneWidget);
    }

    testWidgets(
        'persistent scrollbar and bottom fade show when the capped '
        'panel overflows, and the fade clears at scroll end',
        (tester) async {
      // Same constrained viewport as the Nov 6 cap test: 400 logical
      // px tall, so the uncapped 8-row panel (>= 386dp) overflows.
      await openDropdown(tester, const Size(800, 400));

      final panelRect = tester.getRect(find.byKey(panelKey));
      expect(panelRect.height, lessThan(8 * 48));

      // (a) Persistent scrollbar: present and thumb/track visible
      // WITHOUT any drag or scroll in progress, styled from the
      // app's design tokens (primary thumb, no hardcoded color).
      final scrollbarFinder = find.byKey(scrollbarKey);
      expect(scrollbarFinder, findsOneWidget);
      final scrollbar = tester.widget<RawScrollbar>(scrollbarFinder);
      expect(scrollbar.thumbVisibility, isTrue);
      expect(scrollbar.trackVisibility, isTrue);
      expect(scrollbar.thumbColor, NotelColors.primary);
      expect(scrollbar.thickness, 4);

      // (a) Bottom fade is present while rows sit below the fold.
      expect(find.byKey(fadeKey), findsOneWidget);

      // Row layout is unchanged by the affordance: the first row's
      // label still starts at the panel's 1dp border plus the rows'
      // own 12dp horizontal padding — no scrollbar gutter was carved
      // out of the rows.
      final firstRowLabel = find.text('Sleep Hours').last;
      expect(tester.getRect(firstRowLabel).left,
          closeTo(panelRect.left + 1 + 12, 0.6));

      // Morning Score starts below the panel's bottom edge...
      final morning = find.text('Morning Score');
      expect(tester.getRect(morning).bottom,
          greaterThan(panelRect.bottom));

      // ...and scrolling it into view reaches scroll end, where the
      // fade disappears (nothing remains below the fold) while the
      // persistent scrollbar stays.
      await tester.ensureVisible(morning);
      await tester.pumpAndSettle();
      final morningRect = tester.getRect(morning);
      expect(morningRect.bottom, lessThanOrEqualTo(panelRect.bottom + 1));
      expect(morningRect.top, greaterThanOrEqualTo(panelRect.top - 1));
      expect(find.byKey(fadeKey), findsNothing);
      expect(
          tester.widget<RawScrollbar>(scrollbarFinder).thumbVisibility,
          isTrue);
    });

    testWidgets(
        'scrollbar is inert and no fade shows when all rows fit',
        (tester) async {
      // Tall viewport: all 8 rows fit inside the panel at once.
      await openDropdown(tester, const Size(800, 1200));

      final panelRect = tester.getRect(find.byKey(panelKey));
      // The panel takes its full uncapped height (8 rows x 48dp
      // plus the 1dp borders).
      expect(panelRect.height, greaterThanOrEqualTo(8 * 48));

      // (b) No persistent thumb/track, and no bottom fade.
      final scrollbar = tester.widget<RawScrollbar>(
        find.byKey(scrollbarKey),
      );
      expect(scrollbar.thumbVisibility, isFalse);
      expect(scrollbar.trackVisibility, isFalse);
      expect(find.byKey(fadeKey), findsNothing);

      // Every metric — Morning Score included — is already inside
      // the panel without scrolling.
      for (final m in SnapshotMetric.values) {
        final rect = tester.getRect(find.text(m.displayName).last);
        expect(rect.top, greaterThanOrEqualTo(panelRect.top - 1),
            reason: '${m.displayName} top inside panel');
        expect(rect.bottom, lessThanOrEqualTo(panelRect.bottom + 1),
            reason: '${m.displayName} bottom inside panel');
      }
    });

    testWidgets('panel cap is unchanged by the affordance', (tester) async {
      await openDropdown(tester, const Size(800, 400));

      // (c) Bottom edge stays inside the 400dp viewport and the
      // height stays under the uncapped 8-row height, exactly as
      // the Nov 6 fix left it; the panel is not collapsed either.
      final panelRect = tester.getRect(find.byKey(panelKey));
      expect(panelRect.bottom, lessThanOrEqualTo(400));
      expect(panelRect.height, lessThan(8 * 48));
      expect(panelRect.height, greaterThan(100));

      // The scrolling viewport fills the capped panel inside its
      // 1dp border (the cap is applied by the panel container, not
      // by shrinking the list).
      final optionsRect = tester.getRect(find.byKey(optionsKey));
      expect(optionsRect.height, closeTo(panelRect.height - 2, 1.0));
      expect(optionsRect.width, closeTo(panelRect.width - 2, 1.0));
    });
  });
}
