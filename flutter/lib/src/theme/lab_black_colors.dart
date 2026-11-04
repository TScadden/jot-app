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

  /// Inset card — one tonal step up from black.
  /// Settings-fidelity round (audit P2): #1A1A1E → #101013 — the
  /// card-over-background step drops from +16.3 to +6.5 levels,
  /// inside the reference's measured +5–10 band (DNA
  /// `surface.card`, segment-C/settings shot anchored).
  static const card = Color(0xFF101013);

  /// Nested row inside a card — one shade DARKER than the card.
  /// Settings-fidelity round (audit P3, INDETERMINATE direction —
  /// resolved to the UI_FORMAT_SPEC / Restore-pair side): #121215
  /// → #0C0C0F, −4 levels under the new card.
  static const nested = Color(0xFF0C0C0F);

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

  /// Dock surface glass: milky Tabs purple, gradient top→bottom —
  /// sheen-lit top @ 28%, @ 22% through the upper fifth, @ 16% at
  /// the base. Painted over a real BackdropFilter blur at
  /// [glassBlurSigma].
  ///
  /// BlackGlass v4 iteration (Vera Gate 2, Nov 3, 2026): the v4
  /// stops (primary @ 49% → 40% → 30%) buried the σ14 blur — dock
  /// interior sampled at saturation mean 0.46 / median 0.51 with
  /// zero non-purple hues reading through, vs the reference
  /// interior at ≈0.21 saturation under a ~20–25% LIGHT milky
  /// tint. Two-part fix, measured in the iteration round:
  /// (1) alphas cut to Vera's specified 28% → 22% → 16%, so the
  /// backdrop carries 72–84% of the composite and saturated
  /// content ghosts through with its hue intact; (2) the tint
  /// itself lightened toward white (milky lavender, tint
  /// saturation ≈0.29 in place of primary's 0.57) — an alpha-only
  /// cut was measured first in this round and the interior only
  /// fell to mean 0.476, because a saturated tint over near-black
  /// stays saturated at any alpha, while the reference's 0.21
  /// interior is the signature of a light tint. Gradient shape /
  /// stops, the specular line, the sheen, and σ14 blur are
  /// unchanged — paint values only.
  static const dockGlassGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.18, 1.0],
    colors: [
      Color(0x47CDC6FF), // milky lavender @ 28% — specular zone
      Color(0x38BEB5FF), // milky lavender @ 22%
      Color(0x29B2A8FF), // milky lavender @ 16%
    ],
  );

  // ── Navbar replica glass (Phase 2, NAVBAR_SPEC.md §5) ────────
  //
  // The nav bar ONLY drops the lavender tint for the reference's
  // neutral milky glass: a vertical WHITE-tint gradient, top
  // lighter (~25% → 20% → 15% white over the backdrop, the spec's
  // ~20–25% white-equivalent lift with an alpha profile analogous
  // to the v4 dock stops 0 / 0.18 / 1), over the same sigma-14
  // BackdropFilter, with the same specular line, sheen, rim
  // ([glassEdge]), and shadow ([glassShadow]) tokens as v4.
  // Everything above the dock band keeps the v4 treatment,
  // including [dockGlassGradient] and the score disc.
  static const navbarGlassGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.18, 1.0],
    colors: [
      Color(0x40FFFFFF), // white @ 25% — specular zone
      Color(0x33FFFFFF), // white @ 20%
      Color(0x26FFFFFF), // white @ 15%
    ],
  );

  /// Selection capsule fill (NAVBAR_SPEC §3): SOLID opaque
  /// near-black, measured constant across backdrops in the
  /// reference (build range #000–#0A0A0A). Any translucency or
  /// purple tint fails the reference.
  static const navbarCapsuleFill = Color(0xFF050505);

  // ── Settings tray glass (SETTINGS_SPEC §3 / GLASS_STUDY tray
  // recipe) ─────────────────────────────────────────────────────
  //
  // The settings tray is the GLASS_STUDY TRAY recipe, a different,
  // more opaque surface than the bar's glass: near-flat dark fill
  // above the inset cards, milky tint over a real BackdropFilter
  // blur at [glassBlurSigma] (14), ~90% opaque (SETTINGS_SPEC:
  // 85–90%, backdrop ghosts through as a blur), a specular top
  // line ([settingsTraySpecular] + skirt), ~30dp top corners and
  // ~33dp bottom corners (the tray floats inset, audit D2/D4).
  static const settingsTrayGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.18, 1.0],
    colors: [
      // Settings-fidelity round (audit P4): neutral equivalents at
      // the DNA's measured lightness/deltas — #202027 -> #1D1D22
      // -> #1A1A1F @ ~90% (lum 32.6 / 29.4 / 26.3; amplitude 6.3;
      // bottom stop = new card +9.8). The old stops (#2E2E34 top,
      // lum 46.5) were lighter than every reference tray reading.
      Color(0xE6202027), // ~90% — specular zone
      Color(0xE61D1D22), // ~90% — DNA surface.elevated #231D23 de-warmed
      Color(0xE61A1A1F), // ~90%
    ],
  );

  /// Settings tray corner radius at the top corners
  /// (SETTINGS_SPEC §3: ≈30pt).
  static const settingsTrayRadius = 30.0;

  /// Settings tray BOTTOM corner radius (audit D4): ≈33pt,
  /// following the phone corner zone — the fidelity tray FLOATS
  /// inset (0.89W, bottom gap ≈0.043H) instead of merging with
  /// the screen's bottom edge, so its bottom corners are rounded
  /// like the reference's.
  static const settingsTrayBottomRadius = 33.0;

  /// Tray specular core: white @ 65% (GLASS_STUDY: the reference
  /// core reads white ~50–80%; the dock's [glassSpecular] @ 45%
  /// is the signed bar recipe and is NOT retargeted — this token
  /// is tray-only).
  static const settingsTraySpecular = Color(0xA6FFFFFF);

  /// Tray specular falloff skirt: white @ 18% at the core's foot,
  /// fading to transparent over ≤4dp (audit D7).
  static const settingsTraySpecularSkirt = Color(0x2EFFFFFF);

  // ── Segmented control (tray root, audit D11) ─────────────────
  //
  // Reference form: ~36pt tall, full-pill, NO icons, selected
  // capsule LIGHTER than its track by ≈ +28 luminance (DNA:
  // track #2E252A family, capsule #4C3F46 family, as captured).
  // Neutral equivalents at that delta: track #17171B (lum ≈23.4),
  // capsule #33333A (lum ≈51.7) — delta +28.3. (The delivered
  // build had the polarity INVERTED: selected #1A1A1E rendered
  // ~5 levels DARKER than its track.)
  static const segmentedTrack = Color(0xFF17171B);
  static const segmentedSelected = Color(0xFF33333A);

  /// Selection-pill glass — the v4 dock pill recipe, retained for
  /// the record; the Phase 2 replica capsule is the solid
  /// [navbarCapsuleFill] above, not this gradient.
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
