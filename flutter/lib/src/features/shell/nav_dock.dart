import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 9 — the floating bottom nav dock.
///
/// Pixel-port of the native "Concept A: Wide Low-Profile Dock" in
/// `MainActivity.kt` (~line 651):
/// - Bottom-center, full width, 16dp horizontal padding,
///   12dp bottom padding + system nav-bar inset.
/// - Height 56dp with labels off (66dp with labels on — Round 30).
/// - 20dp rounded rect, `NotelSurface` @ 94% (the native `liquidGlass`
///   is a solid tile now, not a blur), 1dp `NotelPrimary` @ 18% border.
/// - Row `SpaceEvenly`, 4dp horizontal padding; five weight-1 slots:
///   Home, Tools, center quick-log button, Heart, Settings.
/// - Side icons 22dp: `NotelPrimary` when selected,
///   `NotelTextSecondary` when not. No labels (labels off).
/// - Center: 48x44dp rounded square (16dp radius), `NotelPrimary` fill,
///   4dp elevation, white Edit glyph 22dp.
enum DockTab { home, tools, quickLog, heart, settings }

/// Shared nav-dock geometry contract.
///
/// These values are the single source of truth for the dock's
/// geometry: [NavDock] builds from them, and MainShell derives its
/// scoped snackbar inset from them (see
/// [navDockSnackBarBottomInset]), so a snackbar parked above the
/// pill can never drift out of sync with the pill itself.
const double kNavDockHeightNoLabels = 56.0;
const double kNavDockHeightWithLabels = 66.0;

/// Space below the pill, above the system inset.
const double kNavDockBottomGap = 12.0;

/// Breathing room between the pill's top edge and a snackbar
/// parked above it.
const double kNavDockSnackBarGap = 8.0;

double navDockHeight({required bool showLabels}) => showLabels
    ? kNavDockHeightWithLabels
    : kNavDockHeightNoLabels;

/// Bottom inset (from the system-inset line) for a floating
/// snackbar inside the shell: the dock's bottom gap + the pill's
/// height + the gap above the pill. Because the floating base and
/// the dock both resolve against the same viewPadding line, a
/// snackbar with this bottom inset parks exactly
/// [kNavDockSnackBarGap] above the pill's top edge.
double navDockSnackBarBottomInset({required bool showLabels}) =>
    kNavDockBottomGap +
    navDockHeight(showLabels: showLabels) +
    kNavDockSnackBarGap;

/// Round 14 — the selected-tab pill now glides between tabs on a real
/// spring ([SpringSimulation]) instead of just flipping the highlight.
/// All five slots are equal-width (Expanded), so the pill's center is
/// deterministic: slot i → (i + 0.5) * slotWidth. Under reduced motion
/// the pill jumps to its slot with no animation.
///
/// Round 19c fix (founder-reported): on Quick Log the dock highlighted
/// TOOLS instead. Root cause — the pill controller was a default
/// [AnimationController], whose value is bounded to 0.0–1.0, but slot
/// indices run 0–4: selecting Quick Log (2), Heart (3), or Settings (4)
/// clamped the pill to 1.0 — the Tools slot. Home (0) and Tools (1)
/// were correct only by accident. The controller is now UNBOUNDED, so
/// the pill value is the true slot index (spring overshoot past the
/// target is also legal). Audit of the same class of bug: the side
/// icons' colors derive directly from `selected == DockTab.x` and were
/// always correct; only the pill was misplaced. The center quick-log
/// button additionally had NO selected state of its own and its opaque
/// fill hides the pill behind it, so it now carries an explicit
/// selected ring (see below) — every tab now has exactly one visible
/// selected indication, on its own slot.
class NavDock extends StatefulWidget {
  final DockTab selected;
  final ValueChanged<DockTab> onSelect;

  /// Round 30 — the Settings "Show Navigation Bar Labels" preference,
  /// wired for real. Native (MainActivity.kt:657, NavIcon :1005-1043):
  /// labels ON grows the dock 56dp → 66dp and each side slot renders
  /// its label under the icon (10sp, primary + bold when selected,
  /// text-secondary + medium otherwise, 2dp gap). The center quick-log
  /// button never carries a label in native. Defaults to false so
  /// existing direct usages keep the Round 9 geometry; MainShell
  /// passes the stored preference.
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
        DockTab.settings => 4,
      };

  @override
  void initState() {
    super.initState();
    // No fixed duration: the spring simulation drives the timing.
    // UNBOUNDED (round 19c): the value is a slot index (0–4), not a
    // 0–1 progress — a bounded controller clamps every tab past Tools
    // onto the Tools slot (the founder-reported bug).
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
            const SpringDescription(
              mass: 1.0,
              stiffness: 170.0,
              damping: 15.0,
            ),
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
    // Native: bottom 12dp + navigationBarsPadding().
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    // Native MainActivity.kt:657 — labels on: 66dp dock, off: 56dp.
    final dockHeight = navDockHeight(showLabels: widget.showLabels);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: kNavDockBottomGap + bottomInset,
      ),
      // Material ancestor for the InkWell ripples below: the dock floats
      // beside each tab's Scaffold (not inside one), so without this the
      // ink responses have no Material to print on.
      child: Material(
        color: NotelColors.surface.withValues(alpha: 0.94),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(
            color: NotelColors.primary.withValues(alpha: 0.18),
            width: 1,
          ),
        ),
        child: Container(
          height: dockHeight,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final slotWidth = constraints.maxWidth / 5;
              return Stack(
                children: [
                  // The gliding selection pill, behind the icons.
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (_, _) {
                      const pillWidth = 44.0;
                      const pillHeight = 36.0;
                      final left = _controller.value * slotWidth +
                          (slotWidth - pillWidth) / 2;
                      return Positioned(
                        left: left,
                        top: (dockHeight - pillHeight) / 2,
                        child: Container(
                          key: const ValueKey('dock_selection_pill'),
                          width: pillWidth,
                          height: pillHeight,
                          decoration: BoxDecoration(
                            color: NotelColors.primary.withValues(alpha: 0.20),
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                      );
                    },
                  ),
          Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _DockIcon(
              icon: Icons.home,
              semanticLabel: 'Home',
              label: 'Home',
              showLabel: widget.showLabels,
              selected: widget.selected == DockTab.home,
              onTap: () => widget.onSelect(DockTab.home),
            ),
            _DockIcon(
              icon: Icons.assignment,
              semanticLabel: 'Tools',
              label: 'Tools',
              showLabel: widget.showLabels,
              selected: widget.selected == DockTab.tools,
              onTap: () => widget.onSelect(DockTab.tools),
            ),
            // Center quick-log button: inline inside the dock.
            // Round 19c: the button is always primary-filled, so its
            // selected state is an explicit ring around it (the gliding
            // pill sits behind the opaque fill and can't show through).
            // The ring wrapper is a fixed 52x48 in both states (border
            // transparent when unselected) so nothing shifts on select.
            Expanded(
              child: SizedBox(
                height: double.infinity,
                child: Center(
                  // R49 N1: the ring wrapper (52×48) joins the hit
                  // area, bringing the center button's tap height to
                  // 48dp (was the 44dp visual button alone). The
                  // visual button keeps its 48×44 geometry and the
                  // inner InkWell keeps its ripple; both fire the
                  // same callback and the gesture arena delivers one.
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => widget.onSelect(DockTab.quickLog),
                    child: Container(
                      key: const ValueKey('dock_quicklog_ring'),
                      width: 52,
                      height: 48,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: widget.selected == DockTab.quickLog
                              ? NotelColors.textPrimary
                              : Colors.transparent,
                          width: 2,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Material(
                        color: NotelColors.primary,
                        borderRadius: BorderRadius.circular(16),
                        elevation:
                            widget.selected == DockTab.quickLog ? 8 : 4,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => widget.onSelect(DockTab.quickLog),
                          child: const SizedBox(
                            width: 48,
                            height: 44,
                            child: Center(
                              child: Icon(
                                Icons.edit,
                                size: 22,
                                color: Colors.white,
                                semanticLabel: 'Quick log',
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _DockIcon(
              icon: Icons.favorite,
              semanticLabel: 'Heart',
              label: 'Heart',
              showLabel: widget.showLabels,
              selected: widget.selected == DockTab.heart,
              onTap: () => widget.onSelect(DockTab.heart),
            ),
            _DockIcon(
              icon: Icons.settings,
              semanticLabel: 'Settings',
              label: 'Settings',
              showLabel: widget.showLabels,
              selected: widget.selected == DockTab.settings,
              onTap: () => widget.onSelect(DockTab.settings),
            ),
          ],
        ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// One side icon slot: weight-1, 16dp ink clip, 4dp vertical padding —
/// mirrors the native `NavIcon` composable (MainActivity.kt:1005-1043).
/// With [showLabel] the slot is a column: 22dp icon, 2dp gap, 10sp
/// label (primary + bold when selected, text-secondary + medium
/// otherwise) — native's exact values.
class _DockIcon extends StatelessWidget {
  final IconData icon;
  final String semanticLabel;
  final String label;
  final bool showLabel;
  final bool selected;
  final VoidCallback onTap;

  const _DockIcon({
    required this.icon,
    required this.semanticLabel,
    required this.label,
    required this.showLabel,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        selected ? NotelColors.primary : NotelColors.textSecondary;
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  icon,
                  size: 22,
                  semanticLabel: semanticLabel,
                  color: color,
                ),
                if (showLabel) ...[
                  const SizedBox(height: 2),
                  Text(
                    label,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 10,
                      color: color,
                      fontWeight:
                          selected ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
