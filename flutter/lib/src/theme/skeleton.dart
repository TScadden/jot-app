import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 19c — shared skeleton loaders (founder's rule: anything that
/// genuinely must load uses a skeleton shaped like the real content —
/// never a blocking spinner).
///
/// [SkeletonGroup] pulses its [SkeletonBox] children with a gentle
/// opacity shimmer. Reduced motion (OS "Remove animations", read via
/// [animationsDisabled] — the same check every animation in this app
/// uses) renders the boxes completely static: no controller runs.
///
/// Performance: one repeating controller per group (not per box),
/// driven by the widget vsync — nothing ticks off-screen, and the
/// controller is disposed with the group. Skeletons never gate data:
/// they only stand in for a section whose first load hasn't landed.
class SkeletonGroup extends StatefulWidget {
  final Widget child;

  const SkeletonGroup({super.key, required this.child});

  @override
  State<SkeletonGroup> createState() => _SkeletonGroupState();
}

class _SkeletonGroupState extends State<SkeletonGroup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion: never start the shimmer — build renders the
    // boxes at full static opacity.
    if (_started || animationsDisabled(context)) return;
    _started = true;
    _controller.repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (animationsDisabled(context)) return widget.child;
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, child) {
        final t = Curves.easeInOut.transform(_controller.value);
        return Opacity(opacity: 0.55 + 0.45 * t, child: child);
      },
      child: widget.child,
    );
  }
}

/// One placeholder block, shaped by its caller (chip, label line,
/// card, field…) to mirror the real content it stands in for.
class SkeletonBox extends StatelessWidget {
  final double? width;
  final double height;
  final double radius;

  const SkeletonBox({
    super.key,
    this.width,
    required this.height,
    this.radius = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: NotelColors.textSecondary.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}
