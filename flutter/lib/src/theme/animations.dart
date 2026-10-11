import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 14 — shared animation utilities for the Flutter rebuild.
///
/// Every animation in this file honors the OS reduced-motion setting:
/// when [animationsDisabled] is true, widgets render their final state
/// instantly and one-shot effects (confetti) are skipped entirely.
///
/// Performance rules applied throughout:
/// - Painters draw a handful of shapes per frame (no shadows, no
///   saveLayer); controllers are disposed with their widgets and driven
///   by the widget vsync, so nothing ticks off-screen or in the
///   background.
/// - Animations never gate data: they play over/after content loads.

/// True when the user asked the OS to reduce motion (Android:
/// Settings → Accessibility → "Remove animations"). Everything in this
/// file renders its final state instantly in that case.
bool animationsDisabled(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context);

/// Shared-element tag for the watch icon (home header) → the data
/// connections screen's back arrow.
const String watchConnectionsHeroTag = 'watch_connections_hero';

// ── Count-up numbers ─────────────────────────────────────────────────────

/// Round 14 — animated count-up for numeric readouts (vitals, streak
/// pills). Tweens from the previously shown value (0 on first load) to
/// [value] with an ease-out curve. A null [value] renders the honest
/// "--" statically — the count-up never invents a number, and the
/// animation starts only once the real value exists.
class CountUp extends StatefulWidget {
  final int? value;
  final TextStyle? style;
  final Duration duration;
  final String Function(int value)? format;

  const CountUp({
    super.key,
    required this.value,
    this.style,
    this.duration = const Duration(milliseconds: 900),
    this.format,
  });

  @override
  State<CountUp> createState() => _CountUpState();
}

class _CountUpState extends State<CountUp>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _from = 0;
  double _to = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _to = (widget.value ?? 0).toDouble();
    if (widget.value != null) _controller.forward();
  }

  double _shownNow() {
    final eased = Curves.easeOutCubic.transform(_controller.value);
    return _from + (_to - _from) * eased;
  }

  @override
  void didUpdateWidget(CountUp oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
    final target = (widget.value ?? 0).toDouble();
    if (widget.value != null && target != _to) {
      _from = _shownNow();
      _to = target;
      _controller.reset();
      _controller.forward();
    } else if (widget.value == null) {
      _from = 0;
      _to = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _text(int v) =>
      widget.format != null ? widget.format!(v) : '$v';

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    if (v == null) return Text('--', style: widget.style);
    if (animationsDisabled(context)) return Text(_text(v), style: widget.style);
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) => Text(_text(_shownNow().round()), style: widget.style),
    );
  }
}

// ── Staggered entrance ───────────────────────────────────────────────────

/// Round 14 — fade + slight rise-in for home-screen cards. Each card
/// passes its [index]; the entrance is delayed `index * step` so the
/// cards cascade. The child is laid out (but invisible) before its
/// turn, so nothing shifts when it appears. Data loading is untouched —
/// this is purely the container animating in.
class StaggeredEntrance extends StatefulWidget {
  final int index;
  final Widget child;
  final Duration step;
  final Duration duration;

  const StaggeredEntrance({
    super.key,
    required this.index,
    required this.child,
    this.step = const Duration(milliseconds: 80),
    this.duration = const Duration(milliseconds: 450),
  });

  @override
  State<StaggeredEntrance> createState() => _StaggeredEntranceState();
}

class _StaggeredEntranceState extends State<StaggeredEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  bool _started = false;
  bool _scheduled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Runs once after initState (inherited widgets can't be read there).
    if (_scheduled) return;
    _scheduled = true;
    // Reduced motion: never schedule the delay timer — the child
    // renders instantly (build returns it directly).
    if (animationsDisabled(context)) return;
    final delay = widget.step * widget.index;
    if (delay == Duration.zero) {
      _begin();
    } else {
      Future.delayed(delay, () {
        if (mounted) _begin();
      });
    }
  }

  void _begin() {
    setState(() => _started = true);
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (animationsDisabled(context)) return widget.child;
    if (!_started) {
      // Laid out but invisible: no layout jump when the entrance runs.
      return Opacity(opacity: 0, child: widget.child);
    }
    return FadeTransition(
      opacity: CurvedAnimation(parent: _controller, curve: Curves.easeOut),
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.12),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic),
        ),
        child: widget.child,
      ),
    );
  }
}

// ── Living weather icons ─────────────────────────────────────────────────

/// Open-Meteo weather-code → icon kind mapping (same ranges as the
/// weather sheet's emoji mapping).
enum _WxKind { clear, partlyCloudy, cloudy, rain, snow, thunder, unknown }

_WxKind _wxKindFor(int? code) {
  if (code == null) return _WxKind.unknown;
  if (code == 0) return _WxKind.clear;
  if (code == 1 || code == 2) return _WxKind.partlyCloudy;
  if (code == 3 || (code >= 45 && code <= 48)) return _WxKind.cloudy;
  if ((code >= 51 && code <= 67) || (code >= 80 && code <= 82)) {
    return _WxKind.rain;
  }
  if ((code >= 71 && code <= 77) || code == 85 || code == 86) {
    return _WxKind.snow;
  }
  if (code >= 95) return _WxKind.thunder;
  return _WxKind.unknown;
}

/// Round 14 — the header condition icon, alive. Hand-rolled painters,
/// no packages:
/// - clear day: sun with slowly rotating rays; clear night: crescent
///   moon with twinkling stars
/// - partly cloudy: small sun peeking behind a drifting cloud
///   (moon at night)
/// - cloudy/fog: gently drifting cloud puffs
/// - rain: cloud with falling drops; snow: cloud with drifting flakes
/// - thunder: cloud with a flickering bolt
/// - unknown (no code yet): a static cloud, matching the old icon's
///   role as the "no data yet" glyph.
///
/// One repeating controller per icon, driven by the widget vsync —
/// nothing ticks when the header is off-screen or the app is
/// backgrounded. Reduced motion renders a single mid-motion frame.
class AnimatedWeatherIcon extends StatefulWidget {
  final int? weatherCode;
  final bool isDay;
  final double size;

  const AnimatedWeatherIcon({
    super.key,
    required this.weatherCode,
    required this.isDay,
    this.size = 20,
  });

  @override
  State<AnimatedWeatherIcon> createState() => _AnimatedWeatherIconState();
}

class _AnimatedWeatherIconState extends State<AnimatedWeatherIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = animationsDisabled(context);
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, _) => CustomPaint(
        size: Size(widget.size, widget.size),
        painter: _WeatherIconPainter(
          kind: _wxKindFor(widget.weatherCode),
          isDay: widget.isDay,
          // Reduced motion: a pleasant frozen mid-frame.
          t: disabled ? 0.35 : _controller.value,
        ),
      ),
    );
  }
}

class _WeatherIconPainter extends CustomPainter {
  final _WxKind kind;
  final bool isDay;
  final double t; // 0..1 loop phase

  _WeatherIconPainter({
    required this.kind,
    required this.isDay,
    required this.t,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final u = size.width / 24; // design unit
    switch (kind) {
      case _WxKind.clear:
        if (isDay) {
          _sun(canvas, size, u, Offset(12 * u, 12 * u), 5.2 * u, t);
        } else {
          _moon(canvas, size, u, t);
        }
      case _WxKind.partlyCloudy:
        if (isDay) {
          _sun(canvas, size, u, Offset(8.5 * u, 8 * u), 3.6 * u, t);
        } else {
          _moonSmall(canvas, size, u, Offset(8.5 * u, 8 * u), t);
        }
        _cloud(canvas, size, u, Offset(13 * u, 15 * u), 1.0, t);
      case _WxKind.cloudy:
        _cloud(canvas, size, u, Offset(10 * u, 13.5 * u), 0.85, t);
        _cloud(canvas, size, u, Offset(14.5 * u, 15.5 * u), 1.0, t + 0.5);
      case _WxKind.rain:
        _cloud(canvas, size, u, Offset(12 * u, 10 * u), 1.0, t);
        _rain(canvas, size, u, t);
      case _WxKind.snow:
        _cloud(canvas, size, u, Offset(12 * u, 10 * u), 1.0, t);
        _snow(canvas, size, u, t);
      case _WxKind.thunder:
        _cloud(canvas, size, u, Offset(12 * u, 10 * u), 1.0, t,
            dark: true);
        _bolt(canvas, size, u, t);
      case _WxKind.unknown:
        _cloud(canvas, size, u, Offset(12 * u, 13 * u), 1.0, 0.35);
    }
  }

  void _sun(Canvas canvas, Size size, double u, Offset c, double r, double t) {
    // Slowly rotating rays — one revolution per ~14s.
    final rayPaint = Paint()
      ..color = const Color(0xFFFFC94D)
      ..strokeWidth = 1.6 * u
      ..strokeCap = StrokeCap.round;
    final baseAngle = t * math.pi * 2 * (4 / 14);
    for (var i = 0; i < 8; i++) {
      final a = baseAngle + i * math.pi / 4;
      final inner = c + Offset(math.cos(a), math.sin(a)) * (r + 1.6 * u);
      final outer = c + Offset(math.cos(a), math.sin(a)) * (r + 4.2 * u);
      canvas.drawLine(inner, outer, rayPaint);
    }
    canvas.drawCircle(
      c,
      r,
      Paint()..color = const Color(0xFFFFD25E),
    );
    canvas.drawCircle(
      c,
      r * 0.72,
      Paint()..color = const Color(0xFFFFE29A),
    );
  }

  void _moon(Canvas canvas, Size size, double u, double t) {
    _crescent(canvas, Offset(12 * u, 12 * u), 6 * u, u);
    _stars(canvas, u, t, Offset(12 * u, 12 * u));
  }

  void _moonSmall(Canvas canvas, Size size, double u, Offset c, double t) {
    _crescent(canvas, c, 3.4 * u, u);
  }

  void _crescent(Canvas canvas, Offset c, double r, double u) {
    final path = Path()
      ..addOval(Rect.fromCircle(center: c, radius: r))
      ..addOval(Rect.fromCircle(
          center: c + Offset(r * 0.38, -r * 0.28), radius: r * 0.82))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(path, Paint()..color = const Color(0xFFE8ECFF));
  }

  void _stars(Canvas canvas, double u, double t, Offset center) {
    final starPaint = Paint()..color = const Color(0xFFB9C6FF);
    final spots = [
      (Offset(-7 * u, -6 * u), 0.0),
      (Offset(7.5 * u, -3 * u), 0.37),
      (Offset(-4 * u, 7.5 * u), 0.71),
    ];
    for (final (off, phase) in spots) {
      final twinkle = 0.45 + 0.55 * (0.5 + 0.5 * math.sin((t + phase) * math.pi * 4));
      starPaint.color = const Color(0xFFB9C6FF).withValues(alpha: twinkle);
      canvas.drawCircle(center + off, 1.1 * u, starPaint);
    }
  }

  void _cloud(Canvas canvas, Size size, double u, Offset c, double s, double t,
      {bool dark = false}) {
    // Gentle horizontal drift (±1.2u over the loop).
    final drift = math.sin(t * math.pi * 2) * 1.2 * u;
    final cc = c + Offset(drift, 0);
    final color = dark
        ? const Color(0xFF5B6B8C)
        : NotelColors.textSecondary.withValues(alpha: 0.95);
    final paint = Paint()..color = color;
    final r = 4.6 * u * s;
    canvas.drawCircle(cc + Offset(-4.2 * u * s, 1.2 * u * s), r * 0.78, paint);
    canvas.drawCircle(cc + Offset(0, -1.4 * u * s), r, paint);
    canvas.drawCircle(cc + Offset(4.2 * u * s, 1.2 * u * s), r * 0.78, paint);
    canvas.drawRRect(
      RRect.fromLTRBR(
        cc.dx - 7.6 * u * s,
        cc.dy - 0.6 * u * s,
        cc.dx + 7.6 * u * s,
        cc.dy + 3.4 * u * s,
        Radius.circular(2.6 * u * s),
      ),
      paint,
    );
  }

  void _rain(Canvas canvas, Size size, double u, double t) {
    final dropPaint = Paint()
      ..color = NotelColors.info
      ..strokeWidth = 1.7 * u
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      final x = (7.5 + i * 4.5) * u;
      final yTop = 15.5 * u;
      final y = yTop + phase * 7 * u;
      dropPaint.color =
          NotelColors.info.withValues(alpha: 1.0 - phase * 0.55);
      canvas.drawLine(
        Offset(x, y),
        Offset(x - 0.8 * u, y + 2.6 * u),
        dropPaint,
      );
    }
  }

  void _snow(Canvas canvas, Size size, double u, double t) {
    final flakePaint = Paint()..color = const Color(0xFFEAF2FF);
    for (var i = 0; i < 3; i++) {
      final phase = (t * 0.7 + i / 3) % 1.0;
      final x = (8 + i * 4.2) * u + math.sin((t * 2 + i) * math.pi * 2) * 1.4 * u;
      final y = 15.5 * u + phase * 7 * u;
      flakePaint.color =
          const Color(0xFFEAF2FF).withValues(alpha: 1.0 - phase * 0.4);
      canvas.drawCircle(Offset(x, y), 1.25 * u, flakePaint);
    }
  }

  void _bolt(Canvas canvas, Size size, double u, double t) {
    // Flicker: bright most of the loop, dipping twice.
    final flicker = math.sin(t * math.pi * 6) > 0.55 ? 0.45 : 1.0;
    final boltPaint = Paint()
      ..color = const Color(0xFFFFD25E).withValues(alpha: flicker)
      ..style = PaintingStyle.fill;
    final cx = 12 * u;
    final path = Path()
      ..moveTo(cx + 1.5 * u, 13 * u)
      ..lineTo(cx - 2.2 * u, 19 * u)
      ..lineTo(cx + 0.2 * u, 19 * u)
      ..lineTo(cx - 1.2 * u, 23.5 * u)
      ..lineTo(cx + 2.6 * u, 17.2 * u)
      ..lineTo(cx + 0.4 * u, 17.2 * u)
      ..close();
    canvas.drawPath(path, boltPaint);
  }

  @override
  bool shouldRepaint(covariant _WeatherIconPainter old) =>
      old.t != t || old.kind != kind || old.isDay != isDay;
}

// ── Streak milestone confetti ─────────────────────────────────────────────

/// Milestones that earn a confetti burst, ascending.
const List<int> streakMilestones = [7, 30];

/// Secure-storage key holding the highest milestone already celebrated.
const String streakMilestoneStorageKey = 'streak_last_celebrated';

/// Pure milestone logic (unit-tested): returns the highest milestone in
/// (lastCelebrated, currentStreak], or null when nothing new was crossed.
/// Fires at most once per milestone: once persisted, a rebuild or a dip
/// below the milestone can never re-trigger it.
int? nextMilestoneToCelebrate({
  required int? currentStreak,
  required int lastCelebrated,
}) {
  final current = currentStreak;
  if (current == null || current <= 0) return null;
  int? crossed;
  for (final m in streakMilestones) {
    if (current >= m && m > lastCelebrated) crossed = m;
  }
  return crossed;
}

/// Round 14 — hand-rolled confetti burst (no packages). Inserts a
/// full-screen overlay for ~2.6s; particles are precomputed and drawn by
/// a single cheap painter. Skipped entirely under reduced motion.
class ConfettiOverlay {
  ConfettiOverlay._();

  static Future<void> show(BuildContext context) async {
    if (animationsDisabled(context)) return;
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final entry = OverlayEntry(builder: (_) => const _ConfettiBurst());
    overlay.insert(entry);
    await Future.delayed(const Duration(milliseconds: 2600));
    entry.remove();
  }
}

class _ConfettiBurst extends StatefulWidget {
  const _ConfettiBurst();

  @override
  State<_ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<_ConfettiBurst>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..forward();
    final rand = math.Random();
    const palette = [
      NotelColors.primary,
      NotelColors.streakGold,
      Colors.white,
      NotelColors.info,
      NotelColors.chipPink,
      NotelColors.success,
    ];
    _particles = List.generate(90, (_) {
      final angle = -math.pi / 2 + (rand.nextDouble() - 0.5) * 1.6;
      final speed = 280 + rand.nextDouble() * 420;
      return _Particle(
        // Burst origin: around the streak pills (top-left-ish), with
        // spread so phones of any size look right.
        originDx: 0.18 + rand.nextDouble() * 0.12,
        originDy: 0.16 + rand.nextDouble() * 0.06,
        vx: math.cos(angle) * speed,
        vy: math.sin(angle) * speed,
        size: 5 + rand.nextDouble() * 6,
        angle: rand.nextDouble() * math.pi * 2,
        spin: (rand.nextDouble() - 0.5) * 14,
        color: palette[rand.nextInt(palette.length)],
        delay: rand.nextDouble() * 0.25,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (_, _) => CustomPaint(
          painter: _ConfettiPainter(
            particles: _particles,
            elapsed: _controller.value * 2.4,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _Particle {
  final double originDx; // fraction of width
  final double originDy; // fraction of height
  final double vx; // px/s
  final double vy; // px/s
  final double size;
  final double angle;
  final double spin; // rad/s
  final Color color;
  final double delay; // seconds before this particle launches

  const _Particle({
    required this.originDx,
    required this.originDy,
    required this.vx,
    required this.vy,
    required this.size,
    required this.angle,
    required this.spin,
    required this.color,
    required this.delay,
  });
}

class _ConfettiPainter extends CustomPainter {
  final List<_Particle> particles;
  final double elapsed; // seconds since burst start

  _ConfettiPainter({required this.particles, required this.elapsed});

  @override
  void paint(Canvas canvas, Size size) {
    const gravity = 620.0; // px/s²
    const drag = 0.6; // mild air drag
    final paint = Paint();
    for (final p in particles) {
      final age = elapsed - p.delay;
      if (age <= 0) continue;
      final life = 2.4 - p.delay;
      if (age >= life) continue;
      // Closed-form ballistic motion with linear drag approximation.
      final dragK = 1 - math.exp(-drag * age);
      final x = size.width * p.originDx + (p.vx / drag) * dragK;
      final y = size.height * p.originDy +
          (p.vy / drag) * dragK +
          gravity * (age - dragK / drag);
      paint.color = p.color.withValues(alpha: (1 - age / life).clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.angle + p.spin * age);
      canvas.drawRect(
        Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.62),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) =>
      old.elapsed != elapsed || old.particles != particles;
}
