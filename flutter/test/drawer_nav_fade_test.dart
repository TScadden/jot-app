import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';

/// Nav Bar Style update (Nov 24, 2026): the shell's default dock is
/// now NavDockSolid; the fade wrapper under test is style-agnostic
/// and wraps either dock identically, so the dock reads below scope
/// to the Solid dock the bare shell mounts.
///
/// Drawer nav fade (founder, Nov 20, 2026) — while the Home drawer
/// is open, the shell's bottom nav dock fades out and leaves the
/// hit path; when the drawer closes, it fades back in and is live
/// again.
///
/// The shell is pumped bare, exactly like nav_dock_test.dart: Home
/// is the settled tab, and the drawer opens from Home's own header
/// button (home_drawer_button). Home's weather icon animates on a
/// repeating controller, so timed pumps replace pumpAndSettle; the
/// 400ms pumps run past both the drawer slide (250ms) and the dock
/// fade (200ms) and fire Home's staggered-entrance timers (max
/// 240ms), so no timer is pending at teardown.
void main() {
  Widget shell() => const MaterialApp(home: MainShell());

  Finder fade() => find.byKey(const ValueKey('nav_dock_drawer_fade'));
  Finder gate() =>
      find.byKey(const ValueKey('nav_dock_drawer_ignore_pointer'));

  double fadeTarget(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(fade()).opacity;
  bool gateIgnoring(WidgetTester tester) =>
      tester.widget<IgnorePointer>(gate()).ignoring;

  /// Open the drawer and run past both animations.
  Future<void> openDrawer(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('home_drawer_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets(
      'dock fades out and stops taking touches while the Home '
      'drawer is open', (tester) async {
    await tester.pumpWidget(shell());
    await tester.pump();

    // Resting state: fade target fully visible, hit path open.
    expect(fade(), findsOneWidget);
    expect(fadeTarget(tester), 1.0);
    expect(gateIgnoring(tester), isFalse);
    final dockSizeAtRest = tester.getSize(find.byType(NavDockSolid));

    await openDrawer(tester);

    // The drawer is really open (its first entry is on screen)...
    expect(find.byKey(const ValueKey('home_drawer_ai_advocate')),
        findsOneWidget);
    // ...and the dock's fade target is 0 with the hit path closed.
    expect(fadeTarget(tester), 0.0);
    expect(gateIgnoring(tester), isTrue);
    // The dock stays mounted in its unchanged slot (no layout
    // hole, no jump): same size as at rest.
    expect(find.byType(NavDockSolid), findsOneWidget);
    expect(tester.getSize(find.byType(NavDockSolid)), dockSizeAtRest);

    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets(
      'dock fades back in and takes touches again when the drawer '
      'closes', (tester) async {
    await tester.pumpWidget(shell());
    await tester.pump();
    await openDrawer(tester);
    expect(fadeTarget(tester), 0.0);
    expect(gateIgnoring(tester), isTrue);

    // Close via the scrim, tapping LOW on the screen — inside the
    // dock's own band. That is exactly the tap the faded dock must
    // not swallow: it has to reach the scrim and close the drawer.
    await tester.tapAt(const Offset(700, 560));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const ValueKey('home_drawer_ai_advocate')),
        findsNothing);
    expect(fadeTarget(tester), 1.0);
    expect(gateIgnoring(tester), isFalse);

    await tester.pump(const Duration(milliseconds: 300));
  });
}
