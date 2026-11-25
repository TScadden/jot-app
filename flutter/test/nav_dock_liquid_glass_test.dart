import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_glass.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';

/// Nav Bar Liquid Glass package — coverage for the NEW dock
/// material only (see nav_dock_glass.dart): the saturation matrix
/// behind the vibrancy filter, the dark tint gradient the dock
/// paints, and the gradient rim. Geometry / icon / capsule /
/// motion invariants stay pinned by lab_navbar_test.dart and
/// nav_dock_test.dart, unchanged.
void main() {
  group('NavDockLiquidGlass saturation matrix', () {
    test('factor is 1.55 and the matrix is a 4x5 color matrix', () {
      expect(NavDockLiquidGlass.saturationFactor, 1.55);
      final m = NavDockLiquidGlass.saturationMatrix();
      expect(m, hasLength(20));
    });

    test('RGB rows scale away from luminance at the factor', () {
      const s = 1.55;
      final m = NavDockLiquidGlass.saturationMatrix();
      // Red row: own channel pulled up, others pushed negative.
      expect(m[0], closeTo(0.213 + 0.787 * s, 1e-9));
      expect(m[0], greaterThan(1.0));
      expect(m[1], closeTo(0.715 - 0.715 * s, 1e-9));
      expect(m[1], lessThan(0.0));
      expect(m[2], closeTo(0.072 - 0.072 * s, 1e-9));
      // Green row.
      expect(m[6], closeTo(0.715 + 0.285 * s, 1e-9));
      expect(m[6], greaterThan(1.0));
      // Blue row.
      expect(m[12], closeTo(0.072 + 0.928 * s, 1e-9));
      expect(m[12], greaterThan(1.0));
      // No offsets, alpha untouched.
      expect([m[4], m[9], m[14], m[19]], [0, 0, 0, 0]);
      expect([m[15], m[16], m[17], m[18]], [0, 0, 0, 1]);
    });

    test('gray is preserved: every RGB row sums to 1', () {
      final m = NavDockLiquidGlass.saturationMatrix();
      for (final row in [0, 1, 2]) {
        final sum = m[row * 5] + m[row * 5 + 1] + m[row * 5 + 2];
        expect(sum, closeTo(1.0, 1e-9),
            reason: 'row $row must map gray to itself');
      }
    });

    test('factor 1.0 keeps channels at their luminance mix', () {
      final m = NavDockLiquidGlass.saturationMatrix(1.0);
      expect(m[0], closeTo(1.0, 1e-9));
      expect(m[1], closeTo(0.0, 1e-9));
      expect(m[6], closeTo(1.0, 1e-9));
      expect(m[12], closeTo(1.0, 1e-9));
    });

    test('backdrop filter construction returns an ImageFilter', () {
      expect(NavDockLiquidGlass.backdropFilter(), isA<ui.ImageFilter>());
    });

    test('marker string is the class name', () {
      expect(NavDockLiquidGlass.marker, 'NavDockLiquidGlass');
    });
  });

  group('NavDockLiquidGlass tint + rim values', () {
    test('tint is a dark neutral gradient, alpha 0.35–0.50', () {
      final g = NavDockLiquidGlass.tintGradient;
      expect(g.colors, const [
        Color(0x802E2E2E),
        Color(0x6B262626),
        Color(0x5A1C1C1C),
      ]);
      expect(g.stops, const [0.0, 0.18, 1.0]);
      for (final c in g.colors) {
        expect(c.r, c.g);
        expect(c.g, c.b);
        expect(c.a, inInclusiveRange(0.35, 0.51)); // 0x80 = 50.2%
      }
      // Top lighter than bottom (sheen feel).
      expect(g.colors.first.a, greaterThan(g.colors.last.a));
    });

    test('rim gradient: 50% white top fading to 10% bottom', () {
      expect(NavDockLiquidGlass.rimTop, const Color(0x80FFFFFF));
      expect(NavDockLiquidGlass.rimMid, const Color(0x2EFFFFFF));
      expect(NavDockLiquidGlass.rimBottom, const Color(0x1AFFFFFF));
      expect(NavDockLiquidGlass.rimGradient.stops, const [0.0, 0.5, 1.0]);
    });

    test('shared LabBlackColors tokens are NOT retuned', () {
      // The old navbar token and the shared glass tokens keep
      // their exact pre-package values; the retune is dock-local.
      expect(LabBlackColors.navbarGlassGradient.colors, const [
        Color(0x40FFFFFF),
        Color(0x33FFFFFF),
        Color(0x26FFFFFF),
      ]);
      expect(LabBlackColors.glassEdge, const Color(0x33FFFFFF));
      expect(LabBlackColors.glassBlurSigma, 14);
      expect(LabBlackColors.navbarCapsuleFill, const Color(0xFF050505));
    });
  });

  group('Liquid Glass switch (founder amendment, Nov 24, 2026)', () {
    SettingsStore storeOver(Map<String, String> map) =>
        SettingsStore.withStorage(
          read: (k) async => map[k],
          write: (k, v) async => map[k] = v,
          delete: (k) async => map.remove(k),
        );

    test('(a) persistence round-trip through SettingsStore', () async {
      final map = <String, String>{};
      final store = storeOver(map);
      // Unset reads as the default: ON.
      expect(await store.getLiquidGlass(), isTrue);
      // Write OFF: lands in storage under the settings key, and a
      // FRESH store over the same storage reads it back (the cold
      // restart leg).
      await store.setLiquidGlass(false);
      expect(map[SettingsStore.liquidGlassKey], 'false');
      expect(await storeOver(map).getLiquidGlass(), isFalse);
      // Write ON again: round-trips back.
      await storeOver(map).setLiquidGlass(true);
      expect(map[SettingsStore.liquidGlassKey], 'true');
      expect(await storeOver(map).getLiquidGlass(), isTrue);
    });

    test('(a2) setLiquidGlass notifies listeners after the write',
        () async {
      final map = <String, String>{};
      final store = storeOver(map);
      var notified = 0;
      store.addListener(() => notified++);
      await store.setLiquidGlass(false);
      expect(notified, 1);
      expect(map[SettingsStore.liquidGlassKey], 'false');
    });

    Widget dockWith({required bool liquidGlass}) => MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: NavDock(
                selected: DockTab.home,
                onSelect: _noop,
                liquidGlass: liquidGlass,
              ),
            ),
          ),
        );

    testWidgets('(b) switch OFF: dock renders the LEGACY path',
        (tester) async {
      await tester.pumpWidget(dockWith(liquidGlass: false));
      await tester.pump();

      // The milky pre-package gradient is what's painted.
      final gradients = tester
          .widgetList<Container>(
            find.descendant(
                of: find.byType(NavDock), matching: find.byType(Container)),
          )
          .map((c) => (c.decoration as BoxDecoration?)?.gradient)
          .whereType<Gradient>()
          .toList();
      expect(gradients, contains(LabBlackColors.navbarGlassGradient));
      expect(gradients, isNot(contains(NavDockLiquidGlass.tintGradient)));

      // The flat white-20% 1dp rim is back on the Material shape.
      final material = tester.widget<Material>(
        find
            .descendant(
                of: find.byType(NavDock), matching: find.byType(Material))
            .first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.side.color, LabBlackColors.glassEdge);
      expect(shape.side.width, 1);

      // No gradient-rim painter anywhere in the dock.
      expect(
        tester
            .widgetList<CustomPaint>(
              find.descendant(
                  of: find.byType(NavDock),
                  matching: find.byType(CustomPaint)),
            )
            .map((p) => p.painter)
            .whereType<NavDockGlassRimPainter>(),
        isEmpty,
      );

      // A plain-blur BackdropFilter is in the tree (the legacy
      // filter construction; the composed saturation filter is
      // only built on the ON path).
      expect(
        find.descendant(
            of: find.byType(NavDock), matching: find.byType(BackdropFilter)),
        findsOneWidget,
      );

      // Geometry is invariant in the OFF state too.
      expect(tester.getSize(find.byType(NavDock)).height, 62 + 27);
      final pill = find.byKey(const ValueKey('dock_selection_pill'));
      expect(tester.getSize(pill), const Size(190, 52));
    });

    testWidgets(
        '(c) UPDATED (Nav Bar Style package): MainShell mounts the '
        'glass dock only when the STYLE is liquidGlass, live both ways',
        (tester) async {
      // The bool wiring this leg originally pinned was superseded
      // by the style preference (founder: Solid is the default for
      // everyone, regardless of the legacy bool). The glass dock's
      // own ON/OFF rendering stays pinned by legs (a)/(b) above
      // and the direct-NavDock tests below, unchanged.
      final map = <String, String>{
        SettingsStore.liquidGlassKey: 'false',
      };
      final store = storeOver(map);
      await tester.pumpWidget(
          MaterialApp(home: MainShell(settingsStore: store)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // No style key: Solid is the default even with the legacy
      // bool present — the glass NavDock is not mounted at all.
      expect(find.byType(NavDock), findsNothing);
      expect(find.byType(NavDockSolid), findsOneWidget);

      // Flip the STYLE to Liquid Glass through the store setter
      // (what the Settings choice calls): the shipped glass dock
      // mounts LIVE, always with liquidGlass: true on this path.
      await store.setNavBarStyle(NavBarStyle.liquidGlass);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.widget<NavDock>(find.byType(NavDock)).liquidGlass,
          isTrue);
      expect(find.byType(NavDockSolid), findsNothing);
      final onGradients = tester
          .widgetList<Container>(
            find.descendant(
                of: find.byType(NavDock), matching: find.byType(Container)),
          )
          .map((c) => (c.decoration as BoxDecoration?)?.gradient)
          .whereType<Gradient>()
          .toList();
      expect(onGradients, contains(NavDockLiquidGlass.tintGradient));

      // Flip back to Solid live.
      await store.setNavBarStyle(NavBarStyle.solid);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(NavDock), findsNothing);
      expect(find.byType(NavDockSolid), findsOneWidget);
    });
  });

  testWidgets('dock paints the new tint gradient + gradient rim',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: NavDock(selected: DockTab.home, onSelect: _noop),
          ),
        ),
      ),
    );
    await tester.pump();

    // The dock's tint decoration carries the new gradient colors.
    final tinted = tester.widgetList<Container>(
      find.descendant(of: find.byType(NavDock), matching: find.byType(Container)),
    ).where((c) =>
        (c.decoration as BoxDecoration?)?.gradient ==
        NavDockLiquidGlass.tintGradient);
    expect(tinted, hasLength(1));
    final deco = tinted.single.decoration! as BoxDecoration;
    expect((deco.gradient! as LinearGradient).colors, const [
      Color(0x802E2E2E),
      Color(0x6B262626),
      Color(0x5A1C1C1C),
    ]);

    // The gradient rim painter is mounted at the dock radius.
    final rims = tester
        .widgetList<CustomPaint>(
          find.descendant(
              of: find.byType(NavDock), matching: find.byType(CustomPaint)),
        )
        .map((p) => p.painter)
        .whereType<NavDockGlassRimPainter>();
    expect(rims, hasLength(1));
    expect(rims.single.radius, kNavDockRadius);
  });
}

void _noop(DockTab _) {}
