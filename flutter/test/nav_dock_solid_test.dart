import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/shell/heart_sleep_mode.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';

/// Nav Bar Style package — the NEW Solid dock (NavDockSolid):
/// geometry pins from the founder-approved Withings-style mock
/// (.wdock/.wcell CSS), the always-on labels with the codebase's
/// destination names, the heart/sleep glyph+label swap, the
/// selected/unselected colors, the capsule spring character
/// (mirroring lab_navbar_test.dart's motion approach), the
/// reduced-motion jump, tap routing, and the bottom-float rule.
///
/// Default test surface is 800x600 logical dp, viewPadding 0
/// unless a test sets it. Bar math at 800 wide: outer width
/// 800 - 32 margins = 768; inner width 768 - 10 padding = 758;
/// cell = 189.5.
void main() {
  Finder gradientBar() => find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient ==
                kNavDockSolidGradient,
      );

  Widget dock({
    DockTab selected = DockTab.home,
    HeartSleepMode heartSleepMode = HeartSleepMode.heart,
    bool disableAnimations = false,
    ValueChanged<DockTab>? onSelect,
    double? viewPaddingBottom,
  }) =>
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: disableAnimations,
              viewPadding: viewPaddingBottom == null
                  ? null
                  : EdgeInsets.only(bottom: viewPaddingBottom),
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: NavDockSolid(
                  selected: selected,
                  onSelect: onSelect ?? (_) {},
                  heartSleepMode: heartSleepMode,
                ),
              ),
            ),
          ),
        ),
      );

  group('Solid geometry constants', () {
    test('pins match the approved mock CSS', () {
      expect(kNavDockSolidHeight, 58);
      expect(kNavDockSolidRadius, 29);
      expect(kNavDockSolidSideMargin, 16);
      expect(kNavDockSolidInnerPadding, 5);
      expect(kNavDockSolidCapsuleHeight, 48);
      expect(kNavDockSolidCapsuleRadius, 24);
      expect(kNavDockSolidCapsuleColor, const Color(0xFF3E3E44));
      expect(kNavDockSolidGradient.colors, const [
        Color(0xFF2B2B30),
        Color(0xFF232327),
      ]);
      expect(kNavDockSolidGradient.begin, Alignment.topCenter);
      expect(kNavDockSolidGradient.end, Alignment.bottomCenter);
      expect(kNavDockSolidBorderColor, const Color(0x17FFFFFF));
      expect(kNavDockSolidShadow.color, const Color(0x73000000));
      expect(kNavDockSolidShadow.blurRadius, 28);
      expect(kNavDockSolidShadow.offset, const Offset(0, 12));
      expect(kNavDockSolidMarker, 'NavDockSolid');
    });

    test('bottom float rule: max(16, viewPadding + 4)', () {
      expect(navDockSolidBottomPadding(0), 16);
      expect(navDockSolidBottomPadding(10), 16);
      expect(navDockSolidBottomPadding(12), 16);
      expect(navDockSolidBottomPadding(30), 34);
    });

    test('snackbar inset helper parks above the 58dp dock', () {
      // vp 0: float 16 above the inset line + 58 + 8 gap.
      expect(navDockSolidSnackBarBottomInset(viewPaddingBottom: 0), 82);
      // vp 24: float = max(16, 28) = 28 -> (28-24) + 58 + 8 = 70.
      expect(navDockSolidSnackBarBottomInset(viewPaddingBottom: 24), 70);
      // Default arg is vp 0.
      expect(navDockSolidSnackBarBottomInset(), 82);
    });
  });

  group('NavDockSolid widget', () {
    testWidgets('geometry: 58dp pill, margins 16, capsule 48/r24',
        (tester) async {
      await tester.pumpWidget(dock(disableAnimations: true));
      await tester.pump();

      // Bar: 58 high, 768 wide at this surface.
      expect(tester.getSize(gradientBar()), const Size(768, 58));
      expect(tester.getTopLeft(gradientBar()).dx, 16);

      // Border: 1dp in the mock color, riding the Material shape
      // side (a Container-decoration border would shrink the
      // cells' inner width by 2dp).
      final material = tester.widget<Material>(
        find
            .descendant(
                of: find.byType(NavDockSolid),
                matching: find.byType(Material))
            .first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.side.color, const Color(0x17FFFFFF));
      expect(shape.side.width, 1);
      expect(shape.borderRadius, BorderRadius.circular(29));

      // Total widget height = bar + bottom float (16 at inset 0).
      expect(tester.getSize(find.byType(NavDockSolid)).height, 58 + 16);

      // Capsule per tab: full cell (189.5) x 48, radius 24,
      // left = barLeft + 5 + i x 189.5, top = barTop + 5,
      // fill #3E3E44.
      final barTopLeft = tester.getTopLeft(gradientBar());
      final pill = find.byKey(const ValueKey('solid_dock_selection_pill'));
      for (var i = 0; i < DockTab.values.length; i++) {
        await tester.pumpWidget(
          dock(selected: DockTab.values[i], disableAnimations: true),
        );
        await tester.pump();
        expect(tester.getSize(pill), const Size(189.5, 48),
            reason: 'capsule size for ${DockTab.values[i]}');
        final tl = tester.getTopLeft(pill);
        expect(tl.dx, closeTo(barTopLeft.dx + 5 + i * 189.5, 0.01),
            reason: 'capsule left for ${DockTab.values[i]}');
        expect(tl.dy, closeTo(barTopLeft.dy + 5, 0.01),
            reason: 'capsule top for ${DockTab.values[i]}');
        final pillDeco =
            tester.widget<Container>(pill).decoration! as BoxDecoration;
        expect(pillDeco.borderRadius, BorderRadius.circular(24));
        expect(pillDeco.color, const Color(0xFF3E3E44));
      }

      // Drop shadow rides the outer DecoratedBox.
      final boxes = tester.widgetList<DecoratedBox>(
        find.descendant(
            of: find.byType(NavDockSolid),
            matching: find.byType(DecoratedBox)),
      );
      expect(
        boxes.any((b) =>
            b.decoration is BoxDecoration &&
            ((b.decoration as BoxDecoration).boxShadow
                    ?.contains(kNavDockSolidShadow) ??
                false)),
        isTrue,
        reason: 'shadow black @45% blur 28 offset (0,12)',
      );
    });

    testWidgets('labels always render with the real destination names',
        (tester) async {
      await tester.pumpWidget(dock());
      await tester.pump();
      for (final label in ['Home', 'Tools', 'Quick log', 'Heart']) {
        expect(
          find.descendant(
              of: find.byType(NavDockSolid), matching: find.text(label)),
          findsOneWidget,
          reason: 'label "$label"',
        );
        final text = tester.widget<Text>(find.descendant(
            of: find.byType(NavDockSolid), matching: find.text(label)));
        expect(text.style?.fontSize, 10.5);
        expect(text.style?.fontWeight, FontWeight.w600);
      }
      // Icons: 20dp, the same glyphs as nav_dock.dart.
      final icons = tester
          .widgetList<Icon>(find.descendant(
              of: find.byType(NavDockSolid), matching: find.byType(Icon)))
          .toList();
      expect(icons.map((i) => i.icon), [
        Icons.home,
        Icons.assignment,
        Icons.edit,
        Icons.favorite,
      ]);
      expect(icons.map((i) => i.semanticLabel), [
        'Home',
        'Tools',
        'Quick log',
        'Heart',
      ]);
      for (final icon in icons) {
        expect(icon.size, 20);
      }
    });

    testWidgets('selected is white, unselected is #C6C6CE',
        (tester) async {
      await tester.pumpWidget(
          dock(selected: DockTab.tools, disableAnimations: true));
      await tester.pump();
      Color iconColor(IconData glyph) => tester
          .widget<Icon>(find.descendant(
              of: find.byType(NavDockSolid), matching: find.byIcon(glyph)))
          .color!;
      Color labelColor(String label) => tester
          .widget<Text>(find.descendant(
              of: find.byType(NavDockSolid), matching: find.text(label)))
          .style!
          .color!;
      expect(iconColor(Icons.assignment), const Color(0xFFFFFFFF));
      expect(labelColor('Tools'), const Color(0xFFFFFFFF));
      for (final glyph in [Icons.home, Icons.edit, Icons.favorite]) {
        expect(iconColor(glyph), const Color(0xFFC6C6CE));
      }
      for (final label in ['Home', 'Quick log', 'Heart']) {
        expect(labelColor(label), const Color(0xFFC6C6CE));
      }
    });

    testWidgets('heart/sleep swap: glyph AND label follow the mode',
        (tester) async {
      await tester.pumpWidget(dock(heartSleepMode: HeartSleepMode.sleep));
      await tester.pump();
      expect(
        find.descendant(
            of: find.byType(NavDockSolid),
            matching: find.byIcon(Icons.bedtime)),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byType(NavDockSolid), matching: find.text('Sleep')),
        findsOneWidget,
      );
      expect(
        find.descendant(
            of: find.byType(NavDockSolid),
            matching: find.byIcon(Icons.favorite)),
        findsNothing,
      );
      expect(
        find.descendant(
            of: find.byType(NavDockSolid), matching: find.text('Heart')),
        findsNothing,
      );
      final icon = tester.widget<Icon>(find.descendant(
          of: find.byType(NavDockSolid),
          matching: find.byIcon(Icons.bedtime)));
      expect(icon.semanticLabel, 'Sleep');
    });

    testWidgets('taps select the right DockTab', (tester) async {
      final tapped = <DockTab>[];
      await tester.pumpWidget(dock(onSelect: tapped.add));
      await tester.pump();
      for (final glyph in [
        Icons.assignment,
        Icons.edit,
        Icons.favorite,
        Icons.home,
      ]) {
        await tester.tap(find.descendant(
            of: find.byType(NavDockSolid), matching: find.byIcon(glyph)));
        await tester.pump();
      }
      expect(tapped, [
        DockTab.tools,
        DockTab.quickLog,
        DockTab.heart,
        DockTab.home,
      ]);
    });

    testWidgets('bottom float: vp 0 -> 16, vp 30 -> 34', (tester) async {
      await tester.pumpWidget(dock());
      await tester.pump();
      expect(tester.getSize(find.byType(NavDockSolid)).height, 58 + 16);
      await tester.pumpWidget(dock(viewPaddingBottom: 30));
      await tester.pump();
      expect(tester.getSize(find.byType(NavDockSolid)).height, 58 + 34);
    });

    testWidgets('reduced motion: capsule jumps, no glide',
        (tester) async {
      await tester.pumpWidget(
          dock(selected: DockTab.home, disableAnimations: true));
      await tester.pump();
      await tester.pumpWidget(
          dock(selected: DockTab.heart, disableAnimations: true));
      await tester.pump();
      final pill = find.byKey(const ValueKey('solid_dock_selection_pill'));
      final barLeft = tester.getTopLeft(gradientBar()).dx;
      expect(tester.getTopLeft(pill).dx,
          closeTo(barLeft + 5 + 3 * 189.5, 0.01));
    });

    testWidgets('motion: capsule spring is monotonic and settles',
        (tester) async {
      var tab = DockTab.home;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: NavDockSolid(
                  selected: tab,
                  onSelect: (t) => setState(() => tab = t),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final pill = find.byKey(const ValueKey('solid_dock_selection_pill'));
      final startLeft = tester.getTopLeft(pill).dx;

      // Worst-case flip: home -> heart (3 cells of travel).
      await tester.tap(find.descendant(
        of: find.byType(NavDockSolid),
        matching: find.byIcon(Icons.favorite),
      ));
      final samples = <({int ms, double left})>[];
      await tester.pump();
      samples.add((ms: 0, left: tester.getTopLeft(pill).dx));
      for (var ms = 16; ms <= 800; ms += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        samples.add((ms: ms, left: tester.getTopLeft(pill).dx));
      }

      final targetLeft = startLeft + 3 * 189.5;
      final travel = targetLeft - startLeft;
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i].left,
            greaterThanOrEqualTo(samples[i - 1].left - 0.01),
            reason: 'sample ${samples[i].ms}ms moved backwards');
      }
      final maxLeft =
          samples.map((s) => s.left).reduce((a, b) => a > b ? a : b);
      final overshootPct = (maxLeft - targetLeft) / travel * 100;
      expect(overshootPct, lessThanOrEqualTo(2.0),
          reason: 'overshoot ${overshootPct.toStringAsFixed(3)}%');
      int? settleMs;
      for (var i = 0; i < samples.length; i++) {
        if (samples.skip(i).every((s) => (s.left - targetLeft).abs() <= 0.5)) {
          settleMs = samples[i].ms;
          break;
        }
      }
      expect(settleMs, isNotNull);
      expect(settleMs!, lessThanOrEqualTo(300),
          reason: 'settled at ${settleMs}ms, over the 300ms bound');
    });
  });
}
