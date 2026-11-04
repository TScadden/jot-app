import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';

/// The floating bottom nav dock.
///
/// BlackGlass Phase 2 — Lab nav-bar replication (NAVBAR_SPEC.md,
/// measured from the @dbzzle "Buttery UX pt 2" reference):
/// - Centered floating pill: full width minus 16dp margins each
///   side (production's existing footprint — the reference's 0.665
///   width fraction is a consequence of its 3 cells x 85pt and
///   cannot hold Tabs' destinations), height exactly 62dp in ALL
///   states, corner radius 31dp (height/2, a true pill).
/// - Four equal cells, icon-only in every state: the reference
///   renders no text labels in any state, so this presentation
///   never draws labels and the height never varies. The
///   [NavDock.showLabels] preference parameter stays in the API
///   (MainShell still feeds it from SettingsStore) but does not
///   change this presentation.
/// - Settings-gear round (Lab): Settings is NO LONGER a dock
///   destination — it moved to the Home header gear (left of the
///   watch icon), which opens Settings as a bottom tray
///   (SETTINGS_SPEC). The dock keeps Home, Tools, Quick log,
///   Heart in their original order; every signed navbar invariant
///   (62dp height, radius 31, inner padding 4, margins 16, bottom
///   float max(27, viewPadding + 4), full-cell solid #050505
///   capsule 52dp / radius 26, spring 900/57, 24dp near-white
///   icons, no labels) is unchanged — only the cell count (and
///   therefore the cell/capsule width) changed.
/// - Selection capsule: one FULL cell wide, 52dp high, radius
///   26dp, vertically centered (5dp top/bottom), gliding so its
///   left edge is 4dp + i x cellWidth (the bar's horizontal inner
///   padding is 4dp). Fill is SOLID opaque near-black #050505 —
///   measured opaque in the reference; any translucency or purple
///   tint fails it. The capsule is the ONLY selection signal:
///   every icon is near-white (#F5F5F7) at 24dp in both selected
///   and unselected states — no primary tint, no gray dimming,
///   no scale/fill change.
/// - Center quick-log is FLATTENED (the reference has no center /
///   raised item): the edit glyph is a plain equal cell like the
///   other four; no raised button, fill, elevation, or ring.
/// - Glass: NEUTRAL milky glass (this drops the v4 dock's lavender
///   tint in the bar only) — real BackdropFilter blur sigma 14,
///   a vertical WHITE-tint gradient (top lighter), a 1dp specular
///   top line (white ~45%) plus a top sheen band, a white ~20%
///   1dp rim, and a drop shadow black @ 35%, blur 16, offset (0,6).
///   The v4 glass widget structure is reused; only the tint is
///   neutralized. Surfaces above the dock keep their v4 treatment.
/// - Bottom float: bottom padding = max(27dp, viewPadding.bottom
///   + 4dp). The reference renders no home indicator and floats
///   ~27pt from the screen edge; Tabs must still clear Android's
///   gesture area, hence the +4dp-over-inset floor alternative.
/// - Motion: the reference contains NO tab switch (NAVBAR_SPEC
///   section 6); its only measured container motion is a
///   200-250ms monotonic collapse with no overshoot. The capsule
///   spring is tuned to that language (see
///   [kNavDockCapsuleSpring]) and proven by the widget test in
///   lab_navbar_test.dart.
enum DockTab { home, tools, quickLog, heart }

/// Shared nav-dock geometry contract.
///
/// These values are the single source of truth for the dock's
/// geometry: [NavDock] builds from them, and MainShell derives its
/// scoped snackbar inset from them (see
/// [navDockSnackBarBottomInset]), so a snackbar parked above the
/// pill can never drift out of sync with the pill itself.
const double kNavDockHeight = 62.0;

/// Height is invariant in the replica presentation (62dp with
/// labels on or off — labels are never drawn). Both legacy names
/// are kept so existing callers/tests keep compiling.
const double kNavDockHeightNoLabels = kNavDockHeight;
const double kNavDockHeightWithLabels = kNavDockHeight;

/// The bar's corner radius: height/2 — a true pill.
const double kNavDockRadius = 31.0;

/// The selection capsule: height 52dp, radius height/2.
const double kNavDockCapsuleHeight = 52.0;
const double kNavDockCapsuleRadius = 26.0;

/// The bar's horizontal inner padding; the capsule's left edge for
/// cell i is this + i x cellWidth.
const double kNavDockInnerPadding = 4.0;

/// Bottom float from the screen edge when the system inset is
/// small (the reference's measured ~27pt float).
const double kNavDockBottomFloat = 27.0;

/// Extra clearance over the system bottom inset when that inset
/// is the larger term of the float rule.
const double kNavDockBottomInsetSlack = 4.0;

/// Breathing room between the pill's top edge and a snackbar
/// parked above it.
const double kNavDockSnackBarGap = 8.0;

/// The capsule spring, retuned to the reference's measured motion
/// language (NAVBAR_SPEC section 6 proxy: ~200-250ms, monotonic,
/// no overshoot), proved by the motion test in
/// lab_navbar_test.dart (monotonic approach, overshoot <= 2% of
/// travel, settled within 0.5dp in <= 300ms).
///
/// Tuning record: the starting point (mass 1.0, stiffness 320,
/// damping 34, zeta ~= 0.95) was measured FIRST in the widget
/// trace — for the worst-case 4-cell jump it settled in 448ms,
/// too slow for the gate. The retune keeps zeta at 0.95 (the
/// overshoot character is unchanged, ~0.007% of travel) and
/// raises the rate: mass 1.0, stiffness 900, damping 57 — the
/// exact SpringSimulation settles the 4-cell jump in 258ms and
/// the widget test's sampled trace confirms it in the tree.
const SpringDescription kNavDockCapsuleSpring = SpringDescription(
  mass: 1.0,
  stiffness: 900.0,
  damping: 57.0,
);

double navDockHeight({required bool showLabels}) => kNavDockHeight;

/// The dock's bottom padding (from the screen edge) for a given
/// system bottom view-padding: max(27dp, viewPadding + 4dp).
double navDockBottomPadding(double viewPaddingBottom) => math.max(
      kNavDockBottomFloat,
      viewPaddingBottom + kNavDockBottomInsetSlack,
    );

/// Bottom inset (from the system-inset line) for a floating
/// snackbar inside the shell: the dock's float above that line +
/// the pill's height + the gap above the pill. Because the
/// floating base and the dock both resolve against the same
/// viewPadding line, a snackbar with this bottom inset parks
/// exactly [kNavDockSnackBarGap] above the pill's top edge.
double navDockSnackBarBottomInset({
  required bool showLabels,
  double viewPaddingBottom = 0,
}) =>
    (navDockBottomPadding(viewPaddingBottom) - viewPaddingBottom) +
    navDockHeight(showLabels: showLabels) +
    kNavDockSnackBarGap;

/// The selected-tab capsule glides between tabs on a real spring
/// ([SpringSimulation]). All four slots are equal-width (Expanded),
/// so the capsule's left edge is deterministic: slot i ->
/// i * slotWidth (inside the bar's 4dp inner padding). Under
/// reduced motion the capsule jumps to its slot with no animation.
///
/// The controller is UNBOUNDED (round 19c): its value is a slot
/// index (0-3), not a 0-1 progress — a bounded controller clamps
/// every tab past Tools onto the Tools slot.
class NavDock extends StatefulWidget {
  final DockTab selected;
  final ValueChanged<DockTab> onSelect;

  /// The Settings "Show Navigation Bar Labels" preference, kept in
  /// the API for stability (MainShell feeds it from SettingsStore
  /// exactly as before). The replica presentation is icon-only in
  /// every state (NAVBAR_SPEC: no labels in any state), so this
  /// value does not change what the dock draws or its height.
  final bool showLabels;

  const NavDock({
    super.key,
    required this.selected,
    required this.onSelect,
    this.showLabels = false,
  });

  @override
  State<NavDock> createState() => _NavDockState();
}

class _NavDockState extends State<NavDock>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  static double _slotFor(DockTab tab) => switch (tab) {
        DockTab.home => 0,
        DockTab.tools => 1,
        DockTab.quickLog => 2,
        DockTab.heart => 3,
      };

  @override
  void initState() {
    super.initState();
    // No fixed duration: the spring simulation drives the timing.
    // UNBOUNDED (round 19c): the value is a slot index (0-3).
    _controller = AnimationController.unbounded(vsync: this);
    _controller.value = _slotFor(widget.selected);
  }

  @override
  void didUpdateWidget(NavDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected != oldWidget.selected) {
      final target = _slotFor(widget.selected);
      if (animationsDisabled(context)) {
        _controller.value = target;
      } else {
        _controller.animateWith(
          SpringSimulation(
            kNavDockCapsuleSpring,
            _controller.value,
            target,
            0, // released from rest
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    const dockHeight = kNavDockHeight;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: navDockBottomPadding(bottomInset),
      ),
      // Material ancestor for the InkWell ripples below: the dock floats
      // beside each tab's Scaffold (not inside one), so without this the
      // ink responses have no Material to print on.
      //
      // Glass structure reused from BlackGlass v4 (ClipRRect +
      // BackdropFilter sigma 14 + gradient + rim + shadow, every
      // wrapper sizing exactly to the dock), with the tint
      // neutralized to the reference's milky white glass.
      child: DecoratedBox(
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(kNavDockRadius)),
          boxShadow: [LabBlackColors.glassShadow],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.all(Radius.circular(kNavDockRadius)),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(
              sigmaX: LabBlackColors.glassBlurSigma,
              sigmaY: LabBlackColors.glassBlurSigma,
            ),
            child: Material(
              color: Colors.transparent,
              shape: const RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.all(Radius.circular(kNavDockRadius)),
                side: BorderSide(
                  color: LabBlackColors.glassEdge,
                  width: 1,
                ),
              ),
              child: Container(
                height: dockHeight,
                padding: const EdgeInsets.symmetric(
                  horizontal: kNavDockInnerPadding,
                ),
                decoration: const BoxDecoration(
                  gradient: LabBlackColors.navbarGlassGradient,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final slotWidth = constraints.maxWidth / 4;
                    return Stack(
                      children: [
                        // The gliding selection capsule, behind the
                        // icons: one full cell wide, solid opaque
                        // near-black, vertically centered.
                        AnimatedBuilder(
                          animation: _controller,
                          builder: (_, _) {
                            final left = _controller.value * slotWidth;
                            return Positioned(
                              left: left,
                              top: (dockHeight - kNavDockCapsuleHeight) / 2,
                              child: Container(
                                key: const ValueKey('dock_selection_pill'),
                                width: slotWidth,
                                height: kNavDockCapsuleHeight,
                                decoration: const BoxDecoration(
                                  color: LabBlackColors.navbarCapsuleFill,
                                  borderRadius: BorderRadius.all(
                                    Radius.circular(kNavDockCapsuleRadius),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                        // Top sheen band: white @ 10% fading over
                        // the top ~18% of the bar (under the icons).
                        const Positioned(
                          left: 0,
                          right: 0,
                          top: 0,
                          height: 11,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  LabBlackColors.glassSheen,
                                  Color(0x00FFFFFF),
                                ],
                              ),
                            ),
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _DockIcon(
                              icon: Icons.home,
                              semanticLabel: 'Home',
                              onTap: () => widget.onSelect(DockTab.home),
                            ),
                            _DockIcon(
                              icon: Icons.assignment,
                              semanticLabel: 'Tools',
                              onTap: () => widget.onSelect(DockTab.tools),
                            ),
                            // Center quick-log, FLATTENED: a plain
                            // equal cell like the other three (no
                            // raised button, fill, elevation, or
                            // ring). Tap behavior is unchanged.
                            _DockIcon(
                              icon: Icons.edit,
                              semanticLabel: 'Quick log',
                              onTap: () => widget.onSelect(DockTab.quickLog),
                            ),
                            _DockIcon(
                              icon: Icons.favorite,
                              semanticLabel: 'Heart',
                              onTap: () => widget.onSelect(DockTab.heart),
                            ),
                            // No Settings cell: Settings moved to
                            // the Home header gear + bottom tray
                            // (settings-gear round, SETTINGS_SPEC).
                          ],
                        ),
                        // Specular top edge: a 1dp white @ 45% line
                        // inset to clear the corners, painted inside
                        // the dock's existing bounds.
                        const Positioned(
                          left: 16,
                          right: 16,
                          top: 0,
                          height: 1,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: LabBlackColors.glassSpecular,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One icon cell: weight-1, icon-only in every state. The glyph is
/// 24dp in [LabBlackColors.textPrimary] near-white whether selected
/// or not — the black capsule behind it is the only selection
/// signal (NAVBAR_SPEC section 4), so this cell takes no selected
/// state at all: there is nothing for it to change.
class _DockIcon extends StatelessWidget {
  final IconData icon;
  final String semanticLabel;
  final VoidCallback onTap;

  const _DockIcon({
    required this.icon,
    required this.semanticLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Center(
            child: Icon(
              icon,
              size: 24,
              semanticLabel: semanticLabel,
              color: LabBlackColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
