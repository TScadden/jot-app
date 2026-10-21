import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 9 — nav dock tests: all five tabs tappable, home shows the real
/// home screen, the other four show blank placeholders, and the active
/// highlight follows the selection.
///
/// Round 14 note: the home header's weather icon now animates on a
/// repeating controller, so these tests use explicit timed pumps instead
/// of pumpAndSettle (which would never settle while home is visible).
/// Each pump also fires the staggered-entrance delay timers so no timer
/// is pending at teardown.
void main() {
  Widget shell() => const MaterialApp(home: MainShell());

  /// Enough for tab switches, the 300ms route transitions, and the
  /// staggered-entrance delays (max 240ms). Two pumps: the first flushes
  /// the tap's rebuild (which schedules the entrance delays), the second
  /// advances the clock so they fire — a single timed pump would leave
  /// them pending at teardown.
  Future<void> settleDock(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Finder dockIcon(IconData icon) => find.descendant(
        of: find.byType(NavDock),
        matching: find.byIcon(icon),
      );

  Color iconColor(WidgetTester tester, IconData icon) {
    final widget = tester.widget<Icon>(dockIcon(icon).first);
    return widget.color!;
  }

  testWidgets('all five dock tabs are present and tappable', (tester) async {
    await tester.pumpWidget(shell());
    for (final icon in [
      Icons.home,
      Icons.assignment,
      Icons.edit,
      Icons.favorite,
      Icons.settings,
    ]) {
      expect(dockIcon(icon), findsOneWidget,
          reason: 'dock icon $icon missing');
    }
    await settleDock(tester);
  });

  testWidgets('home tab shows the home screen; others show blank screens',
      (tester) async {
    await tester.pumpWidget(shell());

    // Home tab: the real home screen (Today header).
    expect(find.text('Today'), findsOneWidget);

    // Tools -> blank: no Today title, navy background only.
    await tester.tap(dockIcon(Icons.assignment));
    await settleDock(tester);
    expect(find.text('Today'), findsNothing);

    // Heart -> the real Heart screen. Its AppBar title shows, and
    // its date pill reads "Today" in EVERY connection state — the
    // pill is no longer gated on the connection verdict
    // (fix/heart-day-picker). This step used to expect no "Today"
    // here and passed only because the gated pill was missing,
    // which was the very defect that package fixed. Home's own
    // "Today" header is offstage on this tab, so the single match
    // is the Heart pill.
    await tester.tap(dockIcon(Icons.favorite));
    await settleDock(tester);
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.text('Heart')),
        findsOneWidget);
    expect(find.text('Today'), findsOneWidget);

    // Settings -> blank.
    await tester.tap(dockIcon(Icons.settings));
    await settleDock(tester);
    expect(find.text('Today'), findsNothing);

    // Quick log (center pencil) -> blank.
    await tester.tap(dockIcon(Icons.edit));
    await settleDock(tester);
    expect(find.text('Today'), findsNothing);

    // Home -> back to the real home screen.
    await tester.tap(dockIcon(Icons.home));
    await settleDock(tester);
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('active highlight follows the selected tab', (tester) async {
    await tester.pumpWidget(shell());

    // Home starts selected (purple); the rest are muted.
    expect(iconColor(tester, Icons.home), NotelColors.primary);
    expect(iconColor(tester, Icons.favorite), NotelColors.textSecondary);

    // Select Heart: highlight moves, home goes muted.
    await tester.tap(dockIcon(Icons.favorite));
    await settleDock(tester);
    expect(iconColor(tester, Icons.favorite), NotelColors.primary);
    expect(iconColor(tester, Icons.home), NotelColors.textSecondary);

    // Tapping the active tab again keeps it selected (no-op, no crash).
    await tester.tap(dockIcon(Icons.favorite));
    await settleDock(tester);
    expect(iconColor(tester, Icons.favorite), NotelColors.primary);
  });

  testWidgets('dock stays visible on blank tabs', (tester) async {
    await tester.pumpWidget(shell());
    await tester.tap(dockIcon(Icons.settings));
    await settleDock(tester);
    // The dock (with all five icons) is still on screen.
    expect(find.byType(NavDock), findsOneWidget);
    expect(dockIcon(Icons.home), findsOneWidget);
  });
}
