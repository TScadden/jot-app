import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';

/// Navbar replica — Phase 2 of the Lab nav-bar package
/// (NAVBAR_SPEC.md). These tests are the NAMED additions of this
/// package over the BlackGlass baseline (2,359): they pin the
/// replica geometry, the capsule-only selection treatment, the
/// neutral glass, the bottom-float rule, and — critically — the
/// capsule spring's character, which the reference cannot supply
/// directly (it contains no tab switch; NAVBAR_SPEC §6): the
/// motion test proves the built spring matches the reference's
/// measured motion language (monotonic, no overshoot, settled in
/// the ~200–250ms container range).
///
/// Default test surface is 800x600 logical dp, viewPadding 0
/// unless a test sets it. Bar math at 800 wide: outer width
/// 800 - 32 margins = 768; inner width 768 - 8 padding = 760;
/// cell = 190 (settings-gear round: FOUR cells — Settings left
/// the dock for the Home header gear; every other geometry value
/// is the signed navbar invariant, re-pinned below).
void main() {
  Finder dockGradientBar() => find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).gradient ==
                LabBlackColors.navbarGlassGradient,
      );

  Widget dock({
    DockTab selected = DockTab.home,
    bool showLabels = false,
    bool disableAnimations = false,
    ValueChanged<DockTab>? onSelect,
    double? viewPaddingBottom,
  }) =>
      MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            // Copy the AMBIENT MediaQuery (tester.view viewPadding
            // must survive — test (d) depends on it) and flip only
            // the reduced-motion flag.
            data: MediaQuery.of(context).copyWith(
              disableAnimations: disableAnimations,
              viewPadding: viewPaddingBottom == null
                  ? null
                  : EdgeInsets.only(bottom: viewPaddingBottom),
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: NavDock(
                  selected: selected,
                  onSelect: onSelect ?? (_) {},
                  showLabels: showLabels,
                ),
              ),
            ),
          ),
        ),
      );

  group('Lab navbar replica (Phase 2 named additions)', () {
    testWidgets('(a) geometry: 62dp true-pill bar, full-cell capsule',
        (tester) async {
      await tester.pumpWidget(dock(disableAnimations: true));
      await tester.pump();

      // Bar: 62dp high, 768 wide at this surface, radius 31.
      expect(tester.getSize(dockGradientBar()), const Size(768, 62));
      final material = tester.widget<Material>(
        find
            .descendant(of: find.byType(NavDock), matching: find.byType(Material))
            .first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(31));

      // Total widget height = bar + bottom float (27 at inset 0).
      expect(tester.getSize(find.byType(NavDock)).height, 62 + 27);

      // Capsule per tab: full cell (190 = inner 760 / 4) x 52,
      // radius 26, left = barLeft + 4 + i x 190, top = barTop + 5.
      final barTopLeft = tester.getTopLeft(dockGradientBar());
      final pill = find.byKey(const ValueKey('dock_selection_pill'));
      for (var i = 0; i < DockTab.values.length; i++) {
        await tester.pumpWidget(
          dock(selected: DockTab.values[i], disableAnimations: true),
        );
        await tester.pump();
        expect(tester.getSize(pill), const Size(190, 52),
            reason: 'capsule size for ${DockTab.values[i]}');
        final tl = tester.getTopLeft(pill);
        expect(tl.dx, closeTo(barTopLeft.dx + 4 + i * 190, 0.01),
            reason: 'capsule left for ${DockTab.values[i]}');
        expect(tl.dy, closeTo(barTopLeft.dy + 5, 0.01),
            reason: 'capsule top for ${DockTab.values[i]}');
        final deco =
            tester.widget<Container>(pill).decoration! as BoxDecoration;
        expect(deco.borderRadius, BorderRadius.circular(26));
        expect(deco.color, LabBlackColors.navbarCapsuleFill);
      }

      // Height is invariant with the labels preference.
      await tester.pumpWidget(dock(showLabels: true));
      await tester.pump();
      expect(tester.getSize(find.byType(NavDock)).height, 62 + 27);
      expect(tester.getSize(dockGradientBar()), const Size(768, 62));
    });

    testWidgets(
        '(b) icons: four glyphs, 24dp near-white in both states, '
        'no labels ever, center cell plain, NO settings cell',
        (tester) async {
      await tester.pumpWidget(
        dock(selected: DockTab.heart, showLabels: true),
      );
      await tester.pump();

      final icons = tester
          .widgetList<Icon>(
            find.descendant(of: find.byType(NavDock), matching: find.byType(Icon)),
          )
          .toList();
      // Settings-gear round: exactly four cells, order unchanged,
      // and NO settings glyph anywhere in the dock (Settings lives
      // on the Home header gear now — covered by
      // lab_settingsgear_test.dart).
      expect(icons.map((i) => i.icon), [
        Icons.home,
        Icons.assignment,
        Icons.edit,
        Icons.favorite,
      ]);
      expect(
        find.descendant(
            of: find.byType(NavDock), matching: find.byIcon(Icons.settings)),
        findsNothing,
      );
      // Semantic labels of the remaining cells unchanged.
      expect(icons.map((i) => i.semanticLabel), [
        'Home',
        'Tools',
        'Quick log',
        'Heart',
      ]);
      for (final icon in icons) {
        expect(icon.size, 24);
        expect(icon.color, LabBlackColors.textPrimary);
      }
      // No rendered text labels in the dock, even with the
      // preference on.
      expect(
        find.descendant(of: find.byType(NavDock), matching: find.byType(Text)),
        findsNothing,
      );
      // Center flattened: no ring, no elevated Material anywhere
      // in the dock (the raised primary button is gone).
      expect(find.byKey(const ValueKey('dock_quicklog_ring')), findsNothing);
      for (final m in tester.widgetList<Material>(
        find.descendant(of: find.byType(NavDock), matching: find.byType(Material)),
      )) {
        expect(m.elevation, 0);
      }
      // Tapping the edit cell still selects quickLog.
      DockTab? tapped;
      await tester.pumpWidget(
        dock(onSelect: (t) => tapped = t, disableAnimations: true),
      );
      await tester.pump();
      await tester.tap(find.descendant(
        of: find.byType(NavDock),
        matching: find.byIcon(Icons.edit),
      ));
      await tester.pump();
      expect(tapped, DockTab.quickLog);
    });

    testWidgets('(c) glass: neutral white gradient, sigma 14 blur, '
        'rim, specular, sheen, shadow', (tester) async {
      await tester.pumpWidget(dock());
      await tester.pump();

      final bf = tester.widget<BackdropFilter>(
        find.descendant(of: find.byType(NavDock), matching: find.byType(BackdropFilter)),
      );
      expect(bf.filter, isA<ui.ImageFilter>());
      expect(LabBlackColors.glassBlurSigma, 14);

      // Bar rim: white @ 20%, 1dp, on the bar Material shape.
      final material = tester.widget<Material>(
        find
            .descendant(of: find.byType(NavDock), matching: find.byType(Material))
            .first,
      );
      final shape = material.shape! as RoundedRectangleBorder;
      expect(shape.side.color, LabBlackColors.glassEdge);
      expect(shape.side.width, 1);

      // Specular top line + sheen band + drop shadow all present.
      final boxes = tester
          .widgetList<DecoratedBox>(
            find.descendant(
                of: find.byType(NavDock), matching: find.byType(DecoratedBox)),
          )
          .toList();
      expect(
        boxes.any((b) =>
            b.decoration is BoxDecoration &&
            (b.decoration as BoxDecoration).color ==
                LabBlackColors.glassSpecular),
        isTrue,
        reason: 'specular top line (white @ 45%, 1dp)',
      );
      expect(
        boxes.any((b) =>
            b.decoration is BoxDecoration &&
            (b.decoration as BoxDecoration).gradient is LinearGradient &&
            ((b.decoration as BoxDecoration).gradient as LinearGradient)
                .colors
                .contains(LabBlackColors.glassSheen)),
        isTrue,
        reason: 'top sheen band',
      );
      expect(
        boxes.any((b) =>
            b.decoration is BoxDecoration &&
            ((b.decoration as BoxDecoration).boxShadow?.contains(
                      LabBlackColors.glassShadow,
                    ) ??
                    false)),
        isTrue,
        reason: 'drop shadow black @ 35%, blur 16, offset (0, 6)',
      );
      // Neutral means: none of the bar's gradient stops is a
      // purple tint — every stop is pure white at some alpha.
      for (final c in LabBlackColors.navbarGlassGradient.colors) {
        expect(c.r, c.g);
        expect(c.g, c.b);
      }
    });

    testWidgets('(d) bottom float: max(27, viewPadding.bottom + 4)',
        (tester) async {
      // Small inset (0): the 27dp reference float governs.
      await tester.pumpWidget(dock());
      await tester.pump();
      expect(tester.getSize(find.byType(NavDock)).height, 62 + 27);

      // Driven through MediaQuery.viewPadding (what NavDock
      // reads); the real tester.view path with a 24dp inset is
      // covered end-to-end by snackbar_nav_clearance_test.dart.
      // Inset 10: still 27 (27 > 14).
      await tester.pumpWidget(dock(viewPaddingBottom: 10));
      await tester.pump();
      expect(tester.getSize(find.byType(NavDock)).height, 62 + 27);

      // Inset 40: inset + 4 governs -> 44.
      await tester.pumpWidget(dock(viewPaddingBottom: 40));
      await tester.pump();
      expect(tester.getSize(find.byType(NavDock)).height, 62 + 44);
    });

    testWidgets('(e) motion: capsule spring is monotonic, '
        'overshoot <= 2%, settled <= 300ms', (tester) async {
      var tab = DockTab.home;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) => Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: NavDock(
                  selected: tab,
                  onSelect: (t) => setState(() => tab = t),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final pill = find.byKey(const ValueKey('dock_selection_pill'));
      final startLeft = tester.getTopLeft(pill).dx;

      // Worst-case flip: home -> heart (3 cells of travel — the
      // widest jump the 4-cell dock has; was home -> settings
      // before Settings left the dock).
      await tester.tap(find.descendant(
        of: find.byType(NavDock),
        matching: find.byIcon(Icons.favorite),
      ));
      final samples = <({int ms, double left})>[];
      await tester.pump();
      samples.add((ms: 0, left: tester.getTopLeft(pill).dx));
      for (var ms = 16; ms <= 800; ms += 16) {
        await tester.pump(const Duration(milliseconds: 16));
        samples.add((ms: ms, left: tester.getTopLeft(pill).dx));
      }
      // Evidence trace for the package report (opt-in via env) —
      // written BEFORE the assertions so a failing run still
      // leaves its trace for diagnosis.
      final out = Platform.environment['NAVBAR_TRACE_OUT'];
      if (out != null) {
        final tgt = startLeft + 3 * 190.0;
        int? st;
        for (var i = 0; i < samples.length; i++) {
          if (samples.skip(i).every((x) => (x.left - tgt).abs() <= 0.5)) {
            st = samples[i].ms;
            break;
          }
        }
        final mx = samples.map((x) => x.left).reduce((a, b) => a > b ? a : b);
        File(out).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert({
            'spring': {
              'mass': kNavDockCapsuleSpring.mass,
              'stiffness': kNavDockCapsuleSpring.stiffness,
              'damping': kNavDockCapsuleSpring.damping,
            },
            'startLeft': startLeft,
            'targetLeft': tgt,
            'travelDp': tgt - startLeft,
            'settleMs': st,
            'overshootPct': (mx - tgt) / (tgt - startLeft) * 100,
            'samples': [
              for (final x in samples) {'ms': x.ms, 'left': x.left},
            ],
          }),
        );
      }

      final targetLeft = startLeft + 3 * 190.0;
      final travel = targetLeft - startLeft;

      // (a) Monotonic approach (no sample ever moves backwards).
      for (var i = 1; i < samples.length; i++) {
        expect(samples[i].left, greaterThanOrEqualTo(samples[i - 1].left - 0.01),
            reason: 'sample ${samples[i].ms}ms moved backwards: '
                '${samples[i - 1].left} -> ${samples[i].left}');
      }
      // (b) Overshoot <= 2% of travel.
      final maxLeft =
          samples.map((s) => s.left).reduce((a, b) => a > b ? a : b);
      final overshootPct = (maxLeft - targetLeft) / travel * 100;
      expect(overshootPct, lessThanOrEqualTo(2.0),
          reason: 'overshoot ${overshootPct.toStringAsFixed(3)}% of travel');
      // (c) Settled (within 0.5dp of target, and stays there) in
      // <= 300ms.
      int? settleMs;
      for (var i = 0; i < samples.length; i++) {
        if (samples.skip(i).every((s) => (s.left - targetLeft).abs() <= 0.5)) {
          settleMs = samples[i].ms;
          break;
        }
      }
      expect(settleMs, isNotNull,
          reason: 'capsule never settled within 0.5dp of target');
      expect(settleMs!, lessThanOrEqualTo(300),
          reason: 'settled at ${settleMs}ms, over the 300ms bound');
    });
  });
}
