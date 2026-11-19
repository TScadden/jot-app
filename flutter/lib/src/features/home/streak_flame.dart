import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The streak flame (streak upgrade deliverable 4).
///
/// Ruling (brief #4): the flame is the app's EXISTING streak flame
/// presentation — the streak hero's `Icons.local_fire_department` —
/// kept as-is. Grey (desaturated + reduced opacity, per the mocks)
/// while today is incomplete; lit on completion with a SUBTLE
/// native flicker: a transform animation on the icon itself (tip
/// sway + scale ~1.0↔1.04, base planted, NO zoom pulse, NO
/// redesign), matching tabs_flame_icon_animation_v2_20261118.mp4's
/// feel. Silent; no video player.
///
/// Reduced motion: when the platform reports animations disabled,
/// the flame renders static in both states.
class StreakFlame extends StatefulWidget {
  final bool lit;
  final double size;
  final Color litColor;

  const StreakFlame({
    super.key,
    required this.lit,
    this.size = 46,
    this.litColor = const Color(0xFFFF6A3D),
  });

  /// The flicker transform for animation value [t] in [0, 1):
  /// scale breathes 1.0↔1.04 and the tip sways ±1.2° around the
  /// planted base (transform origin at the icon's bottom center).
  @visibleForTesting
  static Matrix4 flickerTransform(double t) {
    final wave = t * 2 * math.pi;
    final scale = 1.0 + 0.04 * (0.5 - 0.5 * math.cos(wave));
    final sway = 0.021 * math.sin(wave); // ≈ ±1.2 degrees
    return Matrix4.identity()
      ..rotateZ(sway)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  State<StreakFlame> createState() => _StreakFlameState();
}

class _StreakFlameState extends State<StreakFlame>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(StreakFlame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lit != widget.lit) _syncAnimation();
  }

  void _syncAnimation() {
    if (widget.lit) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animationsOff =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final icon = Icon(
      Icons.local_fire_department,
      size: widget.size,
      color: widget.lit ? widget.litColor : const Color(0xFF8E97B8),
    );
    if (!widget.lit) {
      // Grey state: desaturated + reduced opacity, per the mock.
      return Opacity(
        opacity: 0.45,
        child: ColorFiltered(
          colorFilter: const ColorFilter.matrix(<double>[
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0.2126, 0.7152, 0.0722, 0, 0,
            0, 0, 0, 1, 0,
          ]),
          child: icon,
        ),
      );
    }
    if (animationsOff) return icon;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => Transform(
        transform: StreakFlame.flickerTransform(_controller.value),
        alignment: Alignment.bottomCenter,
        child: child,
      ),
      child: icon,
    );
  }
}

/// The freeze-day marker (FOUNDER ADDITION, Nov 18, 2026 —
/// STAGE-LOG "freeze-day visual treatment").
///
/// A day covered by a freeze (StreakState.restoredDays) renders
/// the SAME way on every rebuilt surface — the celebration week
/// row, the streak screen week row, and the streak screen month
/// calendar: a filled ICY-BLUE circle with a snowflake glyph in
/// dark navy. The recorded style, used exactly:
///
/// - fill: #6EC6FF (the freeze blue from the Streak Freeze card)
/// - glyph: Icons.ac_unit in #0D1428
///
/// It must read distinctly at a glance from the completed-day
/// check circle (purple / orange), today-open (dark, dashed
/// outline), today-done (orange check), missed, and upcoming
/// states. The legacy purple-ring Restore treatment is retired
/// on these surfaces — no purple rings anywhere in this package.
class StreakFreezeDayCircle extends StatelessWidget {
  /// The recorded freeze blue.
  static const Color fillColor = Color(0xFF6EC6FF);

  /// The recorded snowflake color (dark navy).
  static const Color glyphColor = Color(0xFF0D1428);

  final double size;

  const StreakFreezeDayCircle({super.key, required this.size});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: fillColor,
      ),
      child: Icon(
        Icons.ac_unit,
        size: size * 0.52,
        color: glyphColor,
      ),
    );
  }
}
