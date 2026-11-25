import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:tabs_lab/src/features/shell/heart_sleep_mode.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/animations.dart';

/// Solid nav dock — the NEW default bottom navigation style
/// (Nav Bar Style package, Nov 24, 2026; founder directive:
/// "Build that as the default with glass being something they
/// can change in settings.").
///
/// A floating charcoal pill matching the founder-approved
/// Withings-style mock (`withings_dock_v1.html`, .wdock/.wcell
/// CSS is the geometry spec):
/// - Height 58dp, radius 29dp (a true pill), side margins 16dp,
///   inner padding 5dp.
/// - Body: vertical gradient #2B2B30 (top) -> #232327 (bottom),
///   1dp border white @ 9% (Color(0x17FFFFFF)), drop shadow
///   black @ 45%, blur 28, offset (0, 12).
/// - Four labeled cells in [DockTab] order (Home, Tools,
///   Quick log, Heart/Sleep): icon 20dp + label 10.5px w600,
///   gap 2.5dp. Labels are ALWAYS shown in this style — there
///   is no showLabels parameter. The visible labels are the
///   codebase's destination names, the same strings
///   [NavDock] uses as semantic labels; the heart cell follows
///   [HeartSleepMode] for BOTH glyph and label, exactly like
///   the glass dock.
/// - Selection: white icon + label (#FFFFFF) over a gliding
///   capsule, fill #3E3E44, height 48dp, radius 24dp, with a
///   1dp white-10% inset top line. Unselected icon + label
///   #C6C6CE. The capsule glides on the SAME pattern as
///   [NavDock]: an unbounded AnimationController holding a slot
///   index, a [SpringSimulation] on [kNavDockCapsuleSpring],
///   and an instant jump under reduced motion.
/// - Bottom float: max(16dp, viewPadding.bottom + 4dp) — the
///   mock's 16dp is the floor; the +4-over-inset term keeps the
///   bar clear of the gesture area.
///
/// The glass dock ([NavDock] / nav_dock_glass.dart) is NOT
/// touched by this style: MainShell mounts this widget when
/// the style preference is Solid and the shipped [NavDock]
/// with liquidGlass: true when it is Liquid Glass.

/// Marker for the shipped-binary check: this literal (and the
/// [NavDockSolid] class name) must survive into the AAB's
/// libapp.so strings.
const String kNavDockSolidMarker = 'NavDockSolid';

/// The bar's height in every state (labels are always shown).
const double kNavDockSolidHeight = 58.0;

/// The bar's corner radius: height/2 — a true pill.
const double kNavDockSolidRadius = 29.0;

/// The bar's horizontal side margins.
const double kNavDockSolidSideMargin = 16.0;

/// The bar's horizontal inner padding; the capsule's left edge
/// for cell i is this + i x cellWidth.
const double kNavDockSolidInnerPadding = 5.0;

/// The selection capsule: height 48dp, radius 24dp.
const double kNavDockSolidCapsuleHeight = 48.0;
const double kNavDockSolidCapsuleRadius = 24.0;

/// The capsule's fill.
const Color kNavDockSolidCapsuleColor = Color(0xFF3E3E44);

/// The capsule's 1dp inset top line: white @ 10%.
const Color kNavDockSolidCapsuleTopLine = Color(0x1AFFFFFF);

/// Body gradient endpoints: #2B2B30 (top) -> #232327 (bottom).
const Color kNavDockSolidGradientTop = Color(0xFF2B2B30);
const Color kNavDockSolidGradientBottom = Color(0xFF232327);

/// The body's vertical gradient.
const LinearGradient kNavDockSolidGradient = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [kNavDockSolidGradientTop, kNavDockSolidGradientBottom],
);

/// The body's 1dp border: white @ 9%.
const Color kNavDockSolidBorderColor = Color(0x17FFFFFF);

/// Selected cell icon + label color.
const Color kNavDockSolidSelectedColor = Color(0xFFFFFFFF);

/// Unselected cell icon + label color.
const Color kNavDockSolidUnselectedColor = Color(0xFFC6C6CE);

/// The bar's drop shadow: black @ 45%, blur 28, offset (0, 12).
const BoxShadow kNavDockSolidShadow = BoxShadow(
  color: Color(0x73000000), // black @ 45%
  blurRadius: 28,
  offset: Offset(0, 12),
);

/// Bottom float from the screen edge when the system inset is
/// small (the approved mock's 16dp).
const double kNavDockSolidBottomFloat = 16.0;

/// Extra clearance over the system bottom inset when that inset
/// is the larger term of the float rule.
const double kNavDockSolidBottomInsetSlack = 4.0;

/// Breathing room between the pill's top edge and a snackbar
/// parked above it.
const double kNavDockSolidSnackBarGap = 8.0;

/// The dock's bottom padding (from the screen edge) for a given
/// system bottom view-padding: max(16dp, viewPadding + 4dp).
double navDockSolidBottomPadding(double viewPaddingBottom) => math.max(
      kNavDockSolidBottomFloat,
      viewPaddingBottom + kNavDockSolidBottomInsetSlack,
    );

/// Bottom inset (from the system-inset line) for a floating
/// snackbar inside the shell when the Solid dock is active:
/// the dock's float above that line + the pill's height + the
/// gap above the pill. Mirrors [navDockSnackBarBottomInset].
double navDockSolidSnackBarBottomInset({
  double viewPaddingBottom = 0,
}) =>
    (navDockSolidBottomPadding(viewPaddingBottom) - viewPaddingBottom) +
    kNavDockSolidHeight +
    kNavDockSolidSnackBarGap;

class NavDockSolid extends StatefulWidget {
  final DockTab selected;
  final ValueChanged<DockTab> onSelect;

  /// Heart/Sleep toggle: which screen the heart slot currently
  /// hosts. The heart cell's glyph + label follow it — heart
  /// mode draws Icons.favorite / 'Heart', sleep mode draws
  /// Icons.bedtime / 'Sleep'. Mirrors [NavDock.heartSleepMode].
  final HeartSleepMode heartSleepMode;

  const NavDockSolid({
    super.key,
    required this.selected,
    required this.onSelect,
    this.heartSleepMode = HeartSleepMode.heart,
  });

  @override
  State<NavDockSolid> createState() => _NavDockSolidState();
}

class _NavDockSolidState extends State<NavDockSolid>
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
    // UNBOUNDED, mirroring NavDock: the value is a slot index (0-3).
    _controller = AnimationController.unbounded(vsync: this);
    _controller.value = _slotFor(widget.selected);
  }

  @override
  void didUpdateWidget(NavDockSolid oldWidget) {
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
    const dockHeight = kNavDockSolidHeight;
    return Padding(
      padding: EdgeInsets.only(
        left: kNavDockSolidSideMargin,
        right: kNavDockSolidSideMargin,
        bottom: navDockSolidBottomPadding(bottomInset),
      ),
      // Material ancestor for the InkWell ripples below: the dock
      // floats beside each tab's Scaffold (not inside one), so
      // without this the ink responses have no Material to print
      // on — the same arrangement as NavDock.
      child: DecoratedBox(
        decoration: const BoxDecoration(
          borderRadius:
              BorderRadius.all(Radius.circular(kNavDockSolidRadius)),
          boxShadow: [kNavDockSolidShadow],
        ),
        child: ClipRRect(
          borderRadius:
              const BorderRadius.all(Radius.circular(kNavDockSolidRadius)),
          child: Material(
            color: Colors.transparent,
            // The 1dp border rides the Material shape (the NavDock
            // OFF-path pattern): a border on the inner Container's
            // decoration would eat 2dp of the cells' inner width.
            shape: const RoundedRectangleBorder(
              borderRadius:
                  BorderRadius.all(Radius.circular(kNavDockSolidRadius)),
              side: BorderSide(color: kNavDockSolidBorderColor, width: 1),
            ),
            child: Container(
              height: dockHeight,
              padding: const EdgeInsets.symmetric(
                horizontal: kNavDockSolidInnerPadding,
              ),
              decoration: const BoxDecoration(
                gradient: kNavDockSolidGradient,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final slotWidth = constraints.maxWidth / 4;
                  final sleep = widget.heartSleepMode == HeartSleepMode.sleep;
                  return Stack(
                    children: [
                      // The gliding selection capsule, behind the
                      // cells: one full cell wide, vertically
                      // centered, with its 1dp white-10% inset
                      // top line.
                      AnimatedBuilder(
                        animation: _controller,
                        builder: (_, _) {
                          final left = _controller.value * slotWidth;
                          return Positioned(
                            left: left,
                            top: (dockHeight - kNavDockSolidCapsuleHeight) / 2,
                            child: Container(
                              key: const ValueKey(
                                  'solid_dock_selection_pill'),
                              width: slotWidth,
                              height: kNavDockSolidCapsuleHeight,
                              decoration: const BoxDecoration(
                                color: kNavDockSolidCapsuleColor,
                                borderRadius: BorderRadius.all(
                                  Radius.circular(kNavDockSolidCapsuleRadius),
                                ),
                              ),
                              child: const Align(
                                alignment: Alignment.topCenter,
                                child: Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: kNavDockSolidCapsuleTopLine,
                                    ),
                                    child: SizedBox(
                                      width: double.infinity,
                                      height: 1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                      Row(
                        children: [
                          _SolidDockCell(
                            icon: Icons.home,
                            label: 'Home',
                            selected: widget.selected == DockTab.home,
                            onTap: () => widget.onSelect(DockTab.home),
                          ),
                          _SolidDockCell(
                            icon: Icons.assignment,
                            label: 'Tools',
                            selected: widget.selected == DockTab.tools,
                            onTap: () => widget.onSelect(DockTab.tools),
                          ),
                          _SolidDockCell(
                            icon: Icons.edit,
                            label: 'Quick log',
                            selected: widget.selected == DockTab.quickLog,
                            onTap: () => widget.onSelect(DockTab.quickLog),
                          ),
                          _SolidDockCell(
                            icon: sleep ? Icons.bedtime : Icons.favorite,
                            label: sleep ? 'Sleep' : 'Heart',
                            selected: widget.selected == DockTab.heart,
                            onTap: () => widget.onSelect(DockTab.heart),
                          ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One labeled cell: icon 20dp over a 10.5px w600 label, gap
/// 2.5dp. The foreground color is the selection signal alongside
/// the capsule: white when selected, #C6C6CE otherwise.
class _SolidDockCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SolidDockCell({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = selected
        ? kNavDockSolidSelectedColor
        : kNavDockSolidUnselectedColor;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(kNavDockSolidCapsuleRadius),
        onTap: onTap,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 20,
              semanticLabel: label,
              color: color,
            ),
            const SizedBox(height: 2.5),
            Text(
              label,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
