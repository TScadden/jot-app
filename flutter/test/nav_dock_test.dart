import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';

/// Round 9 — nav dock tests: all four tabs tappable, home shows the real
/// home screen, the others show their screens, and the active
/// highlight follows the selection.
///
/// Settings-gear round (Lab): the dock has FOUR tabs — Settings
/// left the dock for the Home header gear (bottom tray). The
/// settings steps below were removed / retargeted for exactly
/// that intentional change; test count unchanged.
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

  // Nav Bar Style update (Nov 24, 2026): the bare shell mounts
  // the default Solid dock, whose cells carry the same glyphs —
  // the finder scopes to it.
  Finder dockIcon(IconData icon) => find.descendant(
        of: find.byType(NavDockSolid),
        matching: find.byIcon(icon),
      );

  Color iconColor(WidgetTester tester, IconData icon) {
    final widget = tester.widget<Icon>(dockIcon(icon).first);
    return widget.color!;
  }

  testWidgets('all four dock tabs are present and tappable', (tester) async {
    await tester.pumpWidget(shell());
    for (final icon in [
      Icons.home,
      Icons.assignment,
      Icons.edit,
      Icons.favorite,
    ]) {
      expect(dockIcon(icon), findsOneWidget,
          reason: 'dock icon $icon missing');
    }
    // No Settings cell in the dock anymore (header gear instead).
    expect(dockIcon(Icons.settings), findsNothing);
    await settleDock(tester);
  });

  testWidgets('home tab shows the home screen; others show blank screens',
      (tester) async {
    await tester.pumpWidget(shell());

    // Home tab: the real home screen. (Redesign: the "Today"
    // title text is gone from Home — the HomeScreen's presence
    // is the marker now.)
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Today'), findsNothing);

    // Tools -> blank: no Home, navy background only.
    await tester.tap(dockIcon(Icons.assignment));
    await settleDock(tester);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text('Today'), findsNothing);

    // Heart -> the real Heart screen. Its AppBar title shows, and
    // its date pill reads "Today" in EVERY connection state — the
    // pill is no longer gated on the connection verdict
    // (fix/heart-day-picker). This step used to expect no "Today"
    // here and passed only because the gated pill was missing,
    // which was the very defect that package fixed. Home is
    // offstage on this tab, so the single match is the Heart pill.
    await tester.tap(dockIcon(Icons.favorite));
    await settleDock(tester);
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.text('Heart')),
        findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);

    // Quick log (center pencil) -> blank.
    await tester.tap(dockIcon(Icons.edit));
    await settleDock(tester);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text('Today'), findsNothing);

    // Home -> back to the real home screen.
    await tester.tap(dockIcon(Icons.home));
    await settleDock(tester);
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Today'), findsNothing);
  });

  testWidgets('active highlight follows the selected tab', (tester) async {
    await tester.pumpWidget(shell());

    // Nav Bar Style update (Nov 24, 2026): the mounted dock is
    // the Solid default, whose selection signal is the gliding
    // #3E3E44 capsule PLUS the foreground color — selected icon
    // pure white, unselected #C6C6CE (the glass replica's
    // near-white-in-both-states rule stays pinned on the glass
    // dock itself by lab_navbar_test.dart). Home starts selected.
    expect(iconColor(tester, Icons.home), Colors.white);
    for (final icon in [Icons.assignment, Icons.edit, Icons.favorite]) {
      expect(iconColor(tester, icon), const Color(0xFFC6C6CE));
    }

    // Select Heart: the white highlight follows the selection.
    await tester.tap(dockIcon(Icons.favorite));
    await settleDock(tester);
    expect(iconColor(tester, Icons.favorite), Colors.white);
    expect(iconColor(tester, Icons.home), const Color(0xFFC6C6CE));

    // Tapping the active tab again keeps it selected (no-op, no crash).
    await tester.tap(dockIcon(Icons.favorite));
    await settleDock(tester);
    expect(iconColor(tester, Icons.favorite), Colors.white);
  });

  testWidgets('dock stays visible on blank tabs', (tester) async {
    await tester.pumpWidget(shell());
    await tester.tap(dockIcon(Icons.assignment));
    await settleDock(tester);
    // The dock (with all four icons) is still on screen.
    expect(find.byType(NavDockSolid), findsOneWidget);
    expect(dockIcon(Icons.home), findsOneWidget);
  });
}
