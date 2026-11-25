import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/shell/heart_sleep_mode.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';

/// Light Liquid Glass nav dock (Nav Bar Style Fixes package,
/// Nov 24, 2026; founder: "There's only one liquid glass thing
/// when in reality there should be the light and the dark one").
///
/// A thin named wrapper that mounts the shipped [NavDock] on
/// its LEGACY path (liquidGlass: false) — so the light style IS
/// the pre-PR #170 milky glass BY CONSTRUCTION, not a retune:
/// plain BackdropFilter blur σ14 (LabBlackColors.glassBlurSigma,
/// NO saturation), the milky white-tint
/// LabBlackColors.navbarGlassGradient, the flat white-20% 1dp
/// rim (glassEdge) on the Material side, the specular top line
/// (glassSpecular) + sheen band (glassSheen), the glassShadow
/// (black 35%, blur 16, offset (0,6)), and the solid #050505
/// selection capsule (navbarCapsuleFill) — every one of those
/// expressions lives untouched in nav_dock.dart's OFF branch,
/// and no LabBlackColors token is retuned by this style.
///
/// The wrapper exists for two reasons: a clean seam in
/// MainShell's three-way style mount, and a retained binary
/// marker — this class name must survive into the AAB's
/// libapp.so strings (the ship gate checks NavDockSolid,
/// NavDockLiquidGlass AND NavDockLightGlass in every ABI). It
/// takes exactly the parameters MainShell passes the dark-glass
/// path, so the two glass styles differ ONLY in the material
/// branch inside NavDock: geometry (62dp pill, 52dp capsule),
/// icons, the heart/sleep glyph swap, the capsule spring, and
/// the labels wiring are shared. The labels preference is
/// forwarded to NavDock exactly as on the dark path.

/// Marker for the shipped-binary check: this literal (and the
/// [NavDockLightGlass] class name) must survive into the AAB's
/// libapp.so strings.
const String kNavDockLightGlassMarker = 'NavDockLightGlass';

class NavDockLightGlass extends StatelessWidget {
  final DockTab selected;
  final ValueChanged<DockTab> onSelect;

  /// The Settings "Show Navigation Bar Labels" preference,
  /// forwarded to [NavDock] exactly as MainShell feeds the
  /// dark-glass path.
  final bool showLabels;

  /// Heart/Sleep toggle: forwarded to [NavDock] — the heart
  /// cell's glyph + semantic label follow it in both modes.
  final HeartSleepMode heartSleepMode;

  const NavDockLightGlass({
    super.key,
    required this.selected,
    required this.onSelect,
    this.showLabels = false,
    this.heartSleepMode = HeartSleepMode.heart,
  });

  @override
  Widget build(BuildContext context) {
    // The legacy path, hardcoded false on this branch — the
    // light glass is that rendering by construction (see the
    // class doc). nav_dock.dart itself is untouched.
    return NavDock(
      selected: selected,
      onSelect: onSelect,
      showLabels: showLabels,
      heartSleepMode: heartSleepMode,
      liquidGlass: false,
    );
  }
}
