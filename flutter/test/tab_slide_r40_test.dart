import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Round 40 — direction-aware dock tab transitions.
///
/// Spec: tapping a tab to the RIGHT of the current tab slides the new
/// screen in from the right; tapping a tab to the LEFT slides it in
/// from the left. Tab order: 0 Home, 1 Tools, 2 Quick Log, 3 Heart,
/// 4 Settings; direction is pure index comparison. The slide is
/// paired (outgoing travels the same direction), 300ms, fully opaque,
/// no fade. Same-tab taps are no-ops; reduced motion stays instant.
///
/// These tests pin the direction by reading the shell slot
/// SlideTransitions' offsets mid-animation (150ms into the 300ms
/// slide): with Curves.easeOut at t=0.5 the eased progress is ~0.68,
/// so a screen entering from the right sits at dx ≈ +0.32, one
/// entering from the left at dx ≈ −0.32, and the outgoing screen sits
/// one full width away in the travel direction (offsets sum to 1.0 —
/// the paired-tiling invariant).
///
/// Slot parity is deterministic in these tests: the shell starts with
/// Home settled in slot 0, the first switch puts the incoming screen
/// in slot 1, the next back in slot 0, and so on.
///
/// Like nav_dock_test, explicit timed pumps are used throughout (the
/// home weather icon repeats forever, so pumpAndSettle never settles
/// while Home is visible).
void main() {
  const homeKey = ValueKey('home_screen');
  const toolsKey = ValueKey('tools_screen');
  const heartKey = ValueKey('heart_screen');
  const settingsKey = ValueKey('settings_screen');
  const slot0 = ValueKey('tab_slide_slot_0');
  const slot1 = ValueKey('tab_slide_slot_1');

  Widget shell({bool reducedMotion = false}) {
    return MaterialApp(
      // Mirror the production theme's transition wiring (Round 22),
      // exactly as nav_transitions_r22_test's harness does — a bare
      // default theme would wrap every route in Material 3
      // FadeTransitions that production never has.
      theme: ThemeData(
        scaffoldBackgroundColor: NotelColors.background,
        pageTransitionsTheme: slidePageTransitionsTheme(),
      ),
      builder: reducedMotion
          ? (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(disableAnimations: true),
                child: child!,
              )
          : null,
      home: const MainShell(),
    );
  }

  Finder dockIcon(IconData icon) => find.descendant(
        of: find.byType(NavDock),
        matching: find.byIcon(icon),
      );

  double slotDx(WidgetTester tester, ValueKey slotKey) {
    final transition = tester.widget<SlideTransition>(find.byKey(slotKey));
    return transition.position.value.dx;
  }

  int mountedSlots(WidgetTester tester) =>
      tester.widgetList(find.byType(SlideTransition)).where((w) {
        final key = w.key;
        return key == slot0 || key == slot1;
      }).length;

  /// Advance past the 300ms slide plus the staggered-entrance timers
  /// of the newly mounted screen (same pattern as nav_dock_test).
  Future<void> settleTabs(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> tapMidSlide(WidgetTester tester, IconData icon) async {
    await tester.tap(dockIcon(icon));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150)); // mid-slide
  }

  testWidgets('right jump Home -> Heart slides in from the right',
      (tester) async {
    await tester.pumpWidget(shell());
    expect(find.byKey(homeKey), findsOneWidget);

    await tapMidSlide(tester, Icons.favorite);

    // Incoming (Heart, slot 1) is part-way in FROM THE RIGHT; the
    // outgoing (Home, slot 0) has travelled the same direction (left).
    expect(slotDx(tester, slot1), greaterThan(0.2),
        reason: 'incoming Heart should be offset right of rest');
    expect(slotDx(tester, slot0), lessThan(-0.2),
        reason: 'outgoing Home should be offset left of rest');
    // Paired tiling: exactly one full width apart, no overlap/gap.
    expect(slotDx(tester, slot1) - slotDx(tester, slot0),
        closeTo(1.0, 0.01));
    // Both screens mounted mid-slide, carried by SlideTransitions
    // with NO FadeTransition wrapping either screen at the shell
    // level (Round 22 no-ghosting rule; screens may use fades
    // internally for their own content, which is not an ancestor).
    expect(find.byKey(heartKey), findsOneWidget);
    expect(find.byKey(homeKey), findsOneWidget);
    expect(
      find.ancestor(
          of: find.byKey(heartKey), matching: find.byType(FadeTransition)),
      findsNothing,
    );
    expect(
      find.ancestor(
          of: find.byKey(homeKey), matching: find.byType(FadeTransition)),
      findsNothing,
    );

    await settleTabs(tester);
    // Settled: Heart only — Home's State is gone, exactly like the
    // pre-Round-40 instant swap (no state preservation added).
    expect(find.byKey(heartKey), findsOneWidget);
    expect(find.byKey(homeKey), findsNothing);
    expect(mountedSlots(tester), 1);
    expect(slotDx(tester, slot1), 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('left jump Settings -> Tools slides in from the left',
      (tester) async {
    await tester.pumpWidget(shell());

    // Get to Settings first (a right jump), and settle there.
    await tester.tap(dockIcon(Icons.settings));
    await settleTabs(tester);
    expect(find.byKey(settingsKey), findsOneWidget);
    expect(find.byKey(homeKey), findsNothing);

    // Settings (4) -> Tools (1): left jump. Incoming takes slot 0,
    // outgoing Settings stays in slot 1.
    await tapMidSlide(tester, Icons.assignment);
    expect(slotDx(tester, slot0), lessThan(-0.2),
        reason: 'incoming Tools should be offset left of rest');
    expect(slotDx(tester, slot1), greaterThan(0.2),
        reason: 'outgoing Settings should be offset right of rest');
    expect(slotDx(tester, slot1) - slotDx(tester, slot0),
        closeTo(1.0, 0.01));
    expect(find.byKey(toolsKey), findsOneWidget);
    expect(find.byKey(settingsKey), findsOneWidget);

    await settleTabs(tester);
    expect(find.byKey(toolsKey), findsOneWidget);
    expect(find.byKey(settingsKey), findsNothing);
    expect(mountedSlots(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adjacent moves slide in their own directions',
      (tester) async {
    await tester.pumpWidget(shell());

    // Home (0) -> Tools (1): adjacent right.
    await tapMidSlide(tester, Icons.assignment);
    expect(slotDx(tester, slot1), greaterThan(0.2));
    expect(slotDx(tester, slot0), lessThan(-0.2));
    await settleTabs(tester);
    expect(find.byKey(toolsKey), findsOneWidget);

    // Tools (1) -> Home (0): adjacent left.
    await tapMidSlide(tester, Icons.home);
    expect(slotDx(tester, slot0), lessThan(-0.2));
    expect(slotDx(tester, slot1), greaterThan(0.2));
    await settleTabs(tester);
    expect(find.byKey(homeKey), findsOneWidget);
    expect(find.byKey(toolsKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-tab tap is a no-op: no transition, no error',
      (tester) async {
    await tester.pumpWidget(shell());
    await settleTabs(tester);
    await tester.pump(const Duration(milliseconds: 600));
    final todayDx = tester.getTopLeft(find.text('Today')).dx;

    await tester.tap(dockIcon(Icons.home)); // already on Home
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));

    // Still at rest: one slot mounted, no offset, Home unmoved.
    expect(mountedSlots(tester), 1);
    expect(slotDx(tester, slot0), 0);
    expect(find.byKey(homeKey), findsOneWidget);
    expect(tester.getTopLeft(find.text('Today')).dx, todayDx);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the in-flight target again does not restart it',
      (tester) async {
    await tester.pumpWidget(shell());
    await tapMidSlide(tester, Icons.favorite);
    final dxBefore = slotDx(tester, slot1);
    expect(dxBefore, greaterThan(0.2));

    // Same target again mid-slide: the running slide must continue
    // from where it is, not restart from a full width out.
    await tester.tap(dockIcon(Icons.favorite));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(slotDx(tester, slot1), lessThan(dxBefore));

    await settleTabs(tester);
    expect(find.byKey(heartKey), findsOneWidget);
    expect(find.byKey(homeKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid back-and-forth taps settle on the last tab',
      (tester) async {
    await tester.pumpWidget(shell());

    // Home -> Heart (mid-slide) -> Home (mid-slide) -> Heart.
    await tester.tap(dockIcon(Icons.favorite));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(dockIcon(Icons.home));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(dockIcon(Icons.favorite));
    await tester.pump();

    await settleTabs(tester);
    // Last tap wins, nothing stale queued behind it.
    expect(find.byKey(heartKey), findsOneWidget);
    expect(find.byKey(homeKey), findsNothing);
    expect(mountedSlots(tester), 1);
    // Dock selection agrees with the body (Round 19c single source).
    final heartIcon = tester.widget<Icon>(dockIcon(Icons.favorite).first);
    expect(heartIcon.color, NotelColors.primary);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bounce-back mid-slide re-enters from the captured offset',
      (tester) async {
    await tester.pumpWidget(shell());

    // Home -> Heart, 100ms in: Home is part-way out to the left,
    // Heart part-way in from the right.
    await tester.tap(dockIcon(Icons.favorite));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(slotDx(tester, slot0), lessThan(-0.25));
    expect(slotDx(tester, slot1), greaterThan(0.25));

    // Bounce straight back to Home. On the first frame of the new
    // slide Home must be near where it was captured (≈ −0.49), NOT
    // snapped to a full width out (−1.0), and Heart must start its
    // exit from its captured offset (≈ +0.51), not from rest.
    await tester.tap(dockIcon(Icons.home));
    await tester.pump();
    expect(slotDx(tester, slot0), greaterThan(-0.75));
    expect(slotDx(tester, slot0), lessThan(-0.25));
    expect(slotDx(tester, slot1), greaterThan(0.3));
    expect(slotDx(tester, slot1), lessThan(0.75));

    // Mid-bounce: Home nearly home, Heart nearly out to the right.
    await tester.pump(const Duration(milliseconds: 150));
    expect(slotDx(tester, slot0), greaterThan(-0.3));
    expect(slotDx(tester, slot1), greaterThan(0.7));

    await settleTabs(tester);
    expect(find.byKey(homeKey), findsOneWidget);
    expect(find.byKey(heartKey), findsNothing);
    expect(mountedSlots(tester), 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion: tab switch is instant', (tester) async {
    await tester.pumpWidget(shell(reducedMotion: true));
    expect(find.byKey(homeKey), findsOneWidget);

    await tester.tap(dockIcon(Icons.favorite));
    await tester.pump(); // a single frame, no timed advance

    // Already fully swapped — no second screen mounted mid-slide,
    // no offset on the settled screen.
    expect(find.byKey(heartKey), findsOneWidget);
    expect(find.byKey(homeKey), findsNothing);
    expect(mountedSlots(tester), 1);
    // Reduced-motion swaps land in the settled slot (slot 0 here):
    // the screen never changed parent, it just replaced in place.
    expect(slotDx(tester, slot0), 0);
    expect(tester.takeException(), isNull);

    // And back, also instantly.
    await tester.tap(dockIcon(Icons.home));
    await tester.pump();
    expect(find.byKey(homeKey), findsOneWidget);
    expect(find.byKey(heartKey), findsNothing);
    await settleTabs(tester);
    expect(tester.takeException(), isNull);
  });
}
