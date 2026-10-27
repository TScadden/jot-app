import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/material.dart';

/// Test seam for the mascot motion gate. Widget tests run under
/// FLUTTER_TEST, where [_motionEnabled] is hard-off, so a test may set
/// this to true to exercise the idle cycle. Reduced motion still wins,
/// and production code never sets it.
@visibleForTesting
bool? debugMascotMotionOverride;

/// Mascot motion runs only on a real device with animations allowed.
/// Widget tests (FLUTTER_TEST) and reduced-motion users get a static
/// Bandit — the repo's chat tests settle on pumpAndSettle, and a
/// perpetual animation or pending blink timer would wedge them.
bool _motionEnabled(BuildContext context) {
  final override = debugMascotMotionOverride;
  if (override != null) {
    return override && !MediaQuery.disableAnimationsOf(context);
  }
  if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
  return !MediaQuery.disableAnimationsOf(context);
}

/// Timer driver for Bandit's blink: eyes shut for ~180 ms every
/// 4–5 s. Shared by the head avatar and the full-body figure so both
/// blink on the established numbers.
class _BlinkCycle {
  _BlinkCycle(this._onBlinkChanged);

  final void Function() _onBlinkChanged;
  final Random _rng = Random();
  Timer? _timer;
  Timer? _endTimer;
  bool _disposed = false;

  bool blinking = false;

  void start() => _schedule();

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(
      Duration(milliseconds: 4000 + _rng.nextInt(1000)),
      () {
        if (_disposed) return;
        blinking = true;
        _onBlinkChanged();
        _endTimer = Timer(const Duration(milliseconds: 180), () {
          if (_disposed) return;
          blinking = false;
          _onBlinkChanged();
          _schedule();
        });
      },
    );
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _endTimer?.cancel();
  }
}

/// Bandit — the Tabs raccoon mascot as the Health Coach's face/persona.
///
/// The name lives in exactly one place ([kCoachName]); every name-bearing
/// coach string interpolates it. Art is the glossy cartoon Bandit
/// (founder-approved Oct 26, 2026): full body from the cartoon master,
/// avatar is a head crop of the same art, blink frames are the
/// matching eyes-shut art (head crop for the avatar, full-body frame
/// from the generated blink pose for the figure).
///
/// Idle life is deliberately subtle, matching the mascot's established
/// numbers: a blink of ~180 ms every 4–5 s, a 2 px breathing bob on a
/// 4 s cycle, and a gentle sway on a 5 s cycle. The avatar and the
/// full-body figure run the same cycle. All motion stops when
/// the platform reports reduced motion (MediaQuery.disableAnimations).
const String kCoachName = 'Bandit';
const String kCoachAvatarAsset = 'assets/images/bandit_avatar.png';
const String kCoachAvatarBlinkAsset = 'assets/images/bandit_avatar_blink.png';
const String kCoachFullAsset = 'assets/images/bandit_full.png';
const String kCoachFullBlinkAsset = 'assets/images/bandit_full_blink.png';

/// Subtle idle motion wrapper: breathing bob + sway. Static when
/// reduced motion is requested.
class _IdleMotion extends StatefulWidget {
  final Widget child;

  const _IdleMotion({required this.child});

  @override
  State<_IdleMotion> createState() => _IdleMotionState();
}

class _IdleMotionState extends State<_IdleMotion>
    with TickerProviderStateMixin {
  AnimationController? _bob;
  AnimationController? _sway;
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!_motionEnabled(context)) return;
    _bob = AnimationController(
        vsync: this, duration: const Duration(seconds: 4))
      ..repeat(reverse: true);
    _sway = AnimationController(
        vsync: this, duration: const Duration(seconds: 5))
      ..repeat(reverse: true);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _bob?.dispose();
    _sway?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bob = _bob;
    final sway = _sway;
    if (bob == null || sway == null) return widget.child;
    return AnimatedBuilder(
      animation: Listenable.merge([bob, sway]),
      builder: (context, child) {
        // 2 px breathing bob; sway is a whisper of the tail-sway angle.
        final dy = -2.0 * bob.value;
        final angle = -0.02 + 0.04 * sway.value;
        return Transform.translate(
          offset: Offset(0, dy),
          child: Transform.rotate(angle: angle, child: child),
        );
      },
      child: widget.child,
    );
  }
}

/// Bandit's head avatar for the coach header and beside coach messages.
/// Blinks ~180 ms every 4–5 s (image swap to the eyes-shut frame).
class CoachMascotAvatar extends StatefulWidget {
  final double size;

  const CoachMascotAvatar({super.key, required this.size});

  @override
  State<CoachMascotAvatar> createState() => _CoachMascotAvatarState();
}

class _CoachMascotAvatarState extends State<CoachMascotAvatar> {
  late final _BlinkCycle _blink = _BlinkCycle(() {
    if (mounted) setState(() {});
  });
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!_motionEnabled(context)) return;
    _blink.start();
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _IdleMotion(
      child: ClipOval(
        child: Image.asset(
          _blink.blinking ? kCoachAvatarBlinkAsset : kCoachAvatarAsset,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
          semanticLabel: '$kCoachName, Tabs Coach',
        ),
      ),
    );
  }
}

/// Full-body Bandit for the coach empty / first-run states. Runs the
/// same idle cycle as the avatar: the shared [_BlinkCycle] swaps to
/// the full-body blink frame while [_IdleMotion] bobs and sways.
/// Reduced motion (and tests) render the still.
class CoachMascotFigure extends StatefulWidget {
  final double height;

  /// Accessibility label. Coach surfaces pass Juno's approved
  /// 'Bandit, Tabs Coach'; app-wide placements keep the plain name.
  final String semanticLabel;

  const CoachMascotFigure({
    super.key,
    required this.height,
    this.semanticLabel = kCoachName,
  });

  @override
  State<CoachMascotFigure> createState() => _CoachMascotFigureState();
}

class _CoachMascotFigureState extends State<CoachMascotFigure> {
  late final _BlinkCycle _blink = _BlinkCycle(() {
    if (mounted) setState(() {});
  });
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    if (!_motionEnabled(context)) return;
    _blink.start();
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _IdleMotion(
      child: Image.asset(
        _blink.blinking ? kCoachFullBlinkAsset : kCoachFullAsset,
        height: widget.height,
        fit: BoxFit.contain,
        semanticLabel: widget.semanticLabel,
      ),
    );
  }
}
