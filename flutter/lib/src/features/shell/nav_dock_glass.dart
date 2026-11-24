import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/theme/lab_black_colors.dart';

/// Liquid-glass material for the production [NavDock] ONLY
/// (Nav Bar Liquid Glass package, founder directive Nov 24, 2026:
/// "Do just the nav bar… Don't change the icons or anything like
/// that. Just the liquid glass.").
///
/// This is a MATERIAL RETUNE of the dock's existing BlackGlass
/// Phase 2 surface to the Orpheon recipe (founder-approved mock
/// `glass_home_v4_phone.png`, dock region only):
///
/// 1. VIBRANCY — the dock's BackdropFilter composes a saturation
///    boost of [saturationFactor] (1.55×) with the existing blur
///    (sigma [LabBlackColors.glassBlurSigma] = 14, unchanged), so
///    content scrolling under the dock blurs AND its colors pop.
/// 2. TINT — the milky WHITE gradient is replaced by a translucent
///    DARK gradient in the dock's current dark-gray tone family
///    (neutral grays, alpha 0.50 → 0.42 → 0.35, top slightly
///    lighter for the sheen feel), so the near-white icons hold
///    exactly as before.
/// 3. RIM — the flat white-20% border is replaced by a GRADIENT
///    rim ([rimGradient] / [NavDockGlassRimPainter]): white @ 50%
///    at the top edge, fading through 18% at mid-height to white
///    @ 10% at the bottom — light catching a glass edge.
///
/// Everything else about the dock is untouched: the shadow
/// ([LabBlackColors.glassShadow]), the solid #050505 selection
/// capsule, all geometry, all icons, semantics and tap behavior.
///
/// These values live HERE, dock-locally, on purpose: the shared
/// [LabBlackColors] glass tokens are NOT retuned, so no other
/// surface in the app changes.
abstract final class NavDockLiquidGlass {
  /// Marker for the shipped-binary check: this class name (and
  /// this literal) must survive into the AAB's libapp.so strings.
  static const String marker = 'NavDockLiquidGlass';

  /// Saturation boost composed with the dock's backdrop blur.
  static const double saturationFactor = 1.55;

  /// The 4×5 saturation matrix for [saturationFactor], using the
  /// standard luminance weights (0.213 / 0.715 / 0.072 — the
  /// feColorMatrix `saturate` construction): each output channel
  /// is its luminance share pulled away from gray by the factor.
  /// At factor 1.0 this is the identity-with-luminance matrix
  /// (grayscale-preserving); above 1.0 the RGB rows scale away
  /// from the luminance row.
  static List<double> saturationMatrix([double s = saturationFactor]) {
    const lr = 0.213, lg = 0.715, lb = 0.072;
    return <double>[
      lr + (1 - lr) * s, lg - lg * s, lb - lb * s, 0, 0,
      lr - lr * s, lg + (1 - lg) * s, lb - lb * s, 0, 0,
      lr - lr * s, lg - lg * s, lb + (1 - lb) * s, 0, 0,
      0, 0, 0, 1, 0,
    ];
  }

  /// The dock's backdrop filter: blur sigma 14 (unchanged) with
  /// the saturation boost applied to the blurred backdrop, so
  /// under-dock content reads blurred and vibrant.
  static ui.ImageFilter backdropFilter() => ui.ImageFilter.compose(
        outer: ui.ColorFilter.matrix(saturationMatrix()),
        inner: ui.ImageFilter.blur(
          sigmaX: LabBlackColors.glassBlurSigma,
          sigmaY: LabBlackColors.glassBlurSigma,
        ),
      );

  /// Translucent DARK tint gradient (replaces the milky white
  /// [LabBlackColors.navbarGlassGradient] on the dock only — that
  /// token itself is unchanged). Neutral dark grays in the dock's
  /// tone family; same stop shape as the old gradient
  /// (0 / 0.18 / 1), alpha inside the 0.35–0.50 envelope, top
  /// slightly lighter than bottom.
  static const LinearGradient tintGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.18, 1.0],
    colors: [
      Color(0x802E2E2E), // neutral dark gray @ 50% — top
      Color(0x6B262626), // neutral dark gray @ 42%
      Color(0x5A1C1C1C), // neutral dark gray @ 35% — bottom
    ],
  );

  /// Gradient rim colors: brightest at the top edge (white @ 50%),
  /// fading down the sides to white @ 10% at the bottom.
  static const Color rimTop = Color(0x80FFFFFF); // white @ 50%
  static const Color rimMid = Color(0x2EFFFFFF); // white @ 18%
  static const Color rimBottom = Color(0x1AFFFFFF); // white @ 10%

  /// The rim's vertical gradient (applied by
  /// [NavDockGlassRimPainter] as a 1dp stroke).
  static const LinearGradient rimGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    stops: [0.0, 0.5, 1.0],
    colors: [rimTop, rimMid, rimBottom],
  );
}

/// Paints the dock's gradient rim: a 1dp stroke just inside the
/// pill outline (radius must match the dock's ClipRRect exactly —
/// the caller passes the dock radius, 31dp), bright at the top
/// edge and fading to the bottom, per [NavDockLiquidGlass].
class NavDockGlassRimPainter extends CustomPainter {
  final double radius;

  const NavDockGlassRimPainter({required this.radius});

  @override
  void paint(Canvas canvas, Size size) {
    // Inset by half the stroke width so the full 1dp stroke sits
    // inside the pill outline the ClipRRect already applied.
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.5),
      Radius.circular(radius - 0.5),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = NavDockLiquidGlass.rimGradient.createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(NavDockGlassRimPainter oldDelegate) =>
      oldDelegate.radius != radius;
}
