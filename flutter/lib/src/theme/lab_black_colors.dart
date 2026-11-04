import 'package:flutter/material.dart';

import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Lab (BlackGlass v4) — the near-black palette + the purple-glass
/// recipe for the Lab branch ONLY, on the PRODUCTION layout.
///
/// Founder correction (Nov 3, 2026): "I want everything to be where
/// it is now. Just change the UI look." — and "the glass look in our
/// app doesn't look like the video." So: no element moves, resizes,
/// appears, or disappears; only surface rendering changes.
///
/// The core palette is applied at the token level in
/// [NotelColors] itself (Lab branch only): background #0A0A0B,
/// surface/card #1A1A1E, surfaceHigh/nested #121215, text
/// #F5F5F7 / #9A9AA3, hairlines white 8%. This file carries the
/// values NotelColors lacks — the GLASS parameters, measured from
/// the reference video in ~/workspace/tiktok-ui-lab/GLASS_STUDY.md
/// (pixel-sampled, not eyeballed):
///
/// - Backdrop blur is STRONG (calendar numerals behind the pill are
///   illegible smudges; hard edges smear 6–12 pt) → sigma 14.
/// - The fill is a VERTICAL GRADIENT, top lighter (~7% lightness
///   falloff), never the v3 flat tint.
/// - A specular line ≈1 dp at the top edge (white ~50–80% in the
///   reference) with a sheen band fading over the top ~18%.
/// - Bleed-through keeps its hue/saturation (orange segment samples
///   at saturation 0.74–1.00 behind the glass) — iOS-style vibrancy.
///   The build therefore uses blur + a SATURATED purple tint and NO
///   gray/white frost overlay (the v3 miss: flat gray frost muted
///   everything it covered).
/// - Floating shadow: soft near-black, short (bezel-confounded in
///   the reference; estimate black @ 35%, blur 16, offset (0, 6)).
abstract final class LabBlackColors {
  /// Page background — true near-black, neutral.
  static const background = Color(0xFF0A0A0B);

  /// Inset card — one shade up from black.
  static const card = Color(0xFF1A1A1E);

  /// Nested row inside a card — one shade DARKER than the card.
  static const nested = Color(0xFF121215);

  /// Hairlines on the themed surfaces: white at 8% alpha.
  static const hairline = Color(0x14FFFFFF);

  /// Text on the near-black surfaces.
  static const textPrimary = Color(0xFFF5F5F7);
  static const textSecondary = Color(0xFF9A9AA3);

  // ── Glass recipe (GLASS_STUDY.md parameter table) ──────────────

  /// Backdrop blur strength for glass that floats over content.
  static const glassBlurSigma = 14.0;

  /// The glass rim on sides/bottom: white at 20% alpha.
  static const glassEdge = Color(0x33FFFFFF);

  /// Specular top edge: a 1 dp line, white at 45% alpha.
  static const glassSpecular = Color(0x73FFFFFF);

  /// Sheen band color at the very top of a glass surface (fades to
  /// transparent over the top ~18% via the gradients below).
  static const glassSheen = Color(0x1AFFFFFF);

  /// Drop shadow under floating glass (study estimate).
  static const glassShadow = BoxShadow(
    color: Color(0x59000000), // black @ 35%
    blurRadius: 16,
    offset: Offset(0, 6),
  );

  /// Dock surface glass: Tabs purple, gradient top→bottom —
  /// sheen-lit top (white sheen over primary @ 48%), primary @ 40%
  /// through the upper fifth, primary @ 30% at the base. Painted
  /// over a real BackdropFilter blur at [glassBlurSigma]; the
  /// composited result over the near-black page is a dark,
  /// saturated purple glass, brightest at its top edge.
  static const dockGlassGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.18, 1.0],
    colors: [
      Color(0x7D8A7FFF), // white-sheened purple — specular zone
      Color(0x667C6EFF), // primary @ 40%
      Color(0x4D7C6EFF), // primary @ 30%
    ],
  );

  /// Selection-pill glass (the dock's existing gliding pill):
  /// the same recipe at pill scale.
  static const pillGlassGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.18, 1.0],
    colors: [
      Color(0x8C9384FF),
      Color(0x737C6EFF), // primary @ 45%
      Color(0x597C6EFF), // primary @ 35%
    ],
  );

  /// Pill rim: white at 28% — brighter than the dock rim because
  /// the pill is the selected, lit element.
  static const pillGlassEdge = Color(0x47FFFFFF);

  /// Daily Score disc glass (painter-applied): [NotelColors.primary]
  /// blended over the card tone at 42% (top) → 16% (bottom), the
  /// study's gradient falloff at disc scale.
  static const scoreGlassTop = Color(0xFF433D7C);
  static const scoreGlassBottom = Color(0xFF242742);

  /// Score disc sheen: white at 10% (soft lens highlight, clipped
  /// to the disc by the painter).
  static const scoreGlassSheen = Color(0x1AFFFFFF);

  /// Score disc specular arc: white at 35%, stroked over the top
  /// of the disc by the painter.
  static const scoreGlassSpecular = Color(0x59FFFFFF);
}
