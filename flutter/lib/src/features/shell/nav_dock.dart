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
/// - Height 56dp (nav labels off — matches the founder's phone).
/// - 20dp rounded rect, `NotelSurface` @ 94% (the native `liquidGlass`
///   is a solid tile now, not a blur), 1dp `NotelPrimary` @ 18% border.
/// - Row `SpaceEvenly`, 4dp horizontal padding; five weight-1 slots:
///   Home, Tools, center quick-log button, Heart, Settings.
/// - Side icons 22dp: `NotelPrimary` when selected,
///   `NotelTextSecondary` when not. No labels (labels off).
/// - Center: 48x44dp rounded square (16dp radius), `NotelPrimary` fill,
///   4dp elevation, white Edit glyph 22dp.
enum DockTab { home, tools, quickLog, heart, settings }

/// Round 14 — the selected-tab pill now glides between tabs on a real
/// spring ([SpringSimulation]) instead of just flipping the highlight.
/// All five slots are equal-width (Expanded), so the pill's center is
/// deterministic: slot i → (i + 0.5) * slotWidth. Under reduced motion
/// the pill jumps to its slot with no animation.
class NavDock extends StatefulWidget {
  final DockTab selected;
  final ValueChanged<DockTab> onSelect;

  const NavDock({super.key, required this.selected, required this.onSelect});

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
    _controller = AnimationController(vsync: this);
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
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: 12 + bottomInset,
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
          height: 56,
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
                        top: (56 - pillHeight) / 2,
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
              selected: widget.selected == DockTab.home,
              onTap: () => widget.onSelect(DockTab.home),
            ),
            _DockIcon(
              icon: Icons.assignment,
              semanticLabel: 'Tools',
              selected: widget.selected == DockTab.tools,
              onTap: () => widget.onSelect(DockTab.tools),
            ),
            // Center quick-log button: inline inside the dock.
            Expanded(
              child: SizedBox(
                height: double.infinity,
                child: Center(
                  child: Material(
                    color: NotelColors.primary,
                    borderRadius: BorderRadius.circular(16),
                    elevation: 4,
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
            _DockIcon(
              icon: Icons.favorite,
              semanticLabel: 'Heart',
              selected: widget.selected == DockTab.heart,
              onTap: () => widget.onSelect(DockTab.heart),
            ),
            _DockIcon(
              icon: Icons.settings,
              semanticLabel: 'Settings',
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
/// mirrors the native `NavIcon` composable (labels off).
class _DockIcon extends StatelessWidget {
  final IconData icon;
  final String semanticLabel;
  final bool selected;
  final VoidCallback onTap;

  const _DockIcon({
    required this.icon,
    required this.semanticLabel,
    required this.selected,
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
              size: 22,
              semanticLabel: semanticLabel,
              color: selected
                  ? NotelColors.primary
                  : NotelColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
