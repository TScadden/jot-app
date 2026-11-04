import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// BlackGlass v4 (Lab branch) — the NAMED theme delta for this
/// package. These tests exist only on lab/blackglass-theme; they
/// pin the theme-only change (palette tokens + glass recipe) that
/// the founder approved, on the production layout, unchanged.
void main() {
  group('BlackGlass v4 theme (named delta)', () {
    test('(a) core tokens carry the near-black palette', () {
      expect(NotelColors.background.toARGB32(), 0xFF0A0A0B);
      // Settings-fidelity round (audit P2/P3): surface #1A1A1E ->
      // #101013 (card-over-background step +16.3 -> +6.5, inside
      // the DNA's +5-10 band); surfaceHigh #121215 -> #0C0C0F
      // (nested one step DARKER than the new card, -4 levels; P3
      // direction indeterminate in the audit, resolved to the
      // UI_FORMAT_SPEC side). Same test, same assertions, new
      // intentional values.
      expect(NotelColors.surface.toARGB32(), 0xFF101013);
      expect(NotelColors.surfaceHigh.toARGB32(), 0xFF0C0C0F);
      expect(LabBlackColors.card.toARGB32(), 0xFF101013);
      expect(LabBlackColors.nested.toARGB32(), 0xFF0C0C0F);
      expect(NotelColors.textPrimary.toARGB32(), 0xFFF5F5F7);
      expect(NotelColors.textSecondary.toARGB32(), 0xFF9A9AA3);
      // The brand purple itself is untouched.
      expect(NotelColors.primary.toARGB32(), 0xFF7C6EFF);
    });

    test('(b) text tokens keep WCAG AA contrast on the surfaces', () {
      double lum(Color c) {
        double f(double v) {
          final s = v / 255.0;
          return s <= 0.03928
              ? s / 12.92
              : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
        }

        return 0.2126 * f(c.r * 255) +
            0.7152 * f(c.g * 255) +
            0.0722 * f(c.b * 255);
      }

      double ratio(Color a, Color b) {
        final la = lum(a), lb = lum(b);
        final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
        return (hi + 0.05) / (lo + 0.05);
      }

      // AA for normal text is 4.5:1; the v3-verified values for
      // this palette were 18.18:1 (primary on background) and
      // 6.70:1 (secondary on card). Assert the AA floor with
      // margin, computed with the WCAG luminance formula.
      expect(
        ratio(NotelColors.textPrimary, NotelColors.background),
        greaterThan(15.0),
      );
      expect(
        ratio(NotelColors.textSecondary, NotelColors.surface),
        greaterThan(4.5),
      );
    });

    testWidgets('(c) dock renders real glass: blur + gradient + rim', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: NavDock(selected: DockTab.home, onSelect: _noop),
          ),
        ),
      );
      await tester.pump();
      // A real BackdropFilter at the studied sigma wraps the dock.
      final filters = find.byType(BackdropFilter);
      expect(filters, findsOneWidget);
      final bf = tester.widget<BackdropFilter>(filters);
      expect(bf.filter, isA<ui.ImageFilter>());
      // Phase 2 navbar replica (NAVBAR_SPEC §5): the BAR glass is
      // now the NEUTRAL white gradient (the v4 lavender tint is
      // dropped in the bar only) — some Container in the dock
      // carries exactly that gradient.
      final gradients = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(NavDock),
              matching: find.byType(Container),
            ),
          )
          .map((c) => (c.decoration as BoxDecoration?)?.gradient)
          .whereType<Gradient>()
          .toList();
      expect(gradients, contains(LabBlackColors.navbarGlassGradient));
      expect(gradients, isNot(contains(LabBlackColors.dockGlassGradient)));
      // The selection capsule is SOLID opaque near-black (spec §3),
      // one full cell wide x 52dp. Default test surface is 800dp
      // wide: cell = (800 - 32 margins - 8 inner padding) / 4 = 190.
      // (Updated from the v4 glass-pill expectation — 44x36 purple
      // glass gradient — for exactly this intentional change; the
      // divisor went 5 -> 4 in the settings-gear round, when the
      // Settings cell left the dock — same test, same assertion,
      // new intentional width.)
      final pill = find.byKey(const ValueKey('dock_selection_pill'));
      expect(pill, findsOneWidget);
      expect(tester.getSize(pill), const Size(190, 52));
      final container = tester.widget<Container>(pill);
      final deco = container.decoration! as BoxDecoration;
      expect(deco.color, LabBlackColors.navbarCapsuleFill);
      expect(deco.gradient, isNull);
      expect(deco.border, isNull);
    });

    test('(d) settings-fidelity palette: tray gradient stops + '
        'segmented polarity (selected LIGHTER than track)', () {
      // Audit P4: tray gradient retargeted to the neutral
      // equivalents at the DNA's measured lightness —
      // #202027 -> #1D1D22 -> #1A1A1F, all at ~90% (0xE6).
      final g = LabBlackColors.settingsTrayGradient;
      expect(g.colors, const [
        Color(0xE6202027),
        Color(0xE61D1D22),
        Color(0xE61A1A1F),
      ]);
      // Audit D11: the delivered segmented control had inverted
      // polarity (selected ~5 levels DARKER than its track). The
      // reference delta is ~+28 luminance; pin the sign AND the
      // band from the tokens (Rec.709 luma).
      double luma(Color c) =>
          0.2126 * (c.r * 255) + 0.7152 * (c.g * 255) + 0.0722 * (c.b * 255);
      final delta = luma(LabBlackColors.segmentedSelected) -
          luma(LabBlackColors.segmentedTrack);
      expect(delta, greaterThan(20));
      expect(delta, lessThan(36));
      // Tray radii: top ~30pt (match, unchanged), bottom ~33pt
      // (audit D4 — the tray floats now, it no longer merges
      // with the screen's bottom edge).
      expect(LabBlackColors.settingsTrayRadius, 30.0);
      expect(LabBlackColors.settingsTrayBottomRadius, 33.0);
      // P5 (bar glass) deliberately NOT moved: the signed neutral
      // navbar recipe stays (the DNA's as-captured warm #4B3C43
      // contradicts both the signed recipe and the founder's
      // "more black" direction). Pin that it is unchanged.
      expect(LabBlackColors.navbarGlassGradient.colors, const [
        Color(0x40FFFFFF),
        Color(0x33FFFFFF),
        Color(0x26FFFFFF),
      ]);
      // P7: muted text NOT darkened when surfaces darkened.
      expect(NotelColors.textSecondary.toARGB32(), 0xFF9A9AA3);
    });
  });
}

void _noop(DockTab _) {}
