import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/badge_engine.dart';

/// The native badge (BADGES package) — a Flutter rendering of the
/// PIL design in `~/workspace/badge-design/make_badges.py`:
/// a metallic gradient ring (tier palette dark → base → light on
/// the renderer's diagonal), a dark disc (#0D1428, the renderer's
/// SURF), the metric icon filled with the same tier gradient, and
/// the level bars under the icon (3 bars = III, 2 = II, 1 = I —
/// the numeral is the primary level signal).
///
/// The locked variant is the SAME widget desaturated and darkened
/// (the mock's greyscale tiles) — never a different shape.
class BadgeWidget extends StatelessWidget {
  /// Rung index 0..14 (0 = Bronze III … 14 = Diamond I).
  final int rungIndex;
  final IconData icon;
  final double size;

  /// Greyscale/darkened rendering for a not-yet-earned rung.
  final bool locked;

  const BadgeWidget({
    super.key,
    required this.rungIndex,
    required this.icon,
    this.size = 64,
    this.locked = false,
  });

  /// Tier palettes from make_badges.py TIERS: (dark, base, light).
  static ({Color dark, Color base, Color light}) paletteOf(int rungIndex) {
    return switch (badgeMetalOf(rungIndex)) {
      BadgeMetal.bronze => (
          dark: const Color(0xFF6E421C),
          base: const Color(0xFFBE763A),
          light: const Color(0xFFF5BE82),
        ),
      BadgeMetal.silver => (
          dark: const Color(0xFF6E7484),
          base: const Color(0xFFC4C9D6),
          light: const Color(0xFFF8FAFF),
        ),
      BadgeMetal.gold => (
          dark: const Color(0xFF926814),
          base: const Color(0xFFE8B33C),
          light: const Color(0xFFFFEA96),
        ),
      BadgeMetal.platinum => (
          dark: const Color(0xFF78949E),
          base: const Color(0xFFCEE6EC),
          light: const Color(0xFFFFFFFF),
        ),
      BadgeMetal.diamond => (
          dark: const Color(0xFF548CBA),
          base: const Color(0xFF96CDF2),
          light: const Color(0xFFEBFAFF),
        ),
    };
  }

  static LinearGradient gradientOf(int rungIndex) {
    final p = paletteOf(rungIndex);
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [p.dark, p.base, p.light],
      stops: const [0, 0.5, 1],
    );
  }

  /// The tier's display color for rung-name text (the palette's
  /// light tone — the mock renders rung names in the tier color).
  static Color tierTextColor(int rungIndex) => paletteOf(rungIndex).light;

  @override
  Widget build(BuildContext context) {
    final palette = paletteOf(rungIndex);
    final gradient = gradientOf(rungIndex);
    final bars = badgeBarsOf(rungIndex);
    final isDiamond = badgeMetalOf(rungIndex) == BadgeMetal.diamond;

    Widget badge = SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _BadgePainter(
              palette: palette,
              gradient: gradient,
              bars: bars,
              isDiamond: isDiamond,
            ),
          ),
          // Center icon filled with the tier gradient, shifted up
          // a touch to leave room for the level bars (renderer).
          Positioned.fill(
            child: Align(
              alignment: const Alignment(0, -0.18),
              child: ShaderMask(
                shaderCallback: (rect) => gradient.createShader(rect),
                blendMode: BlendMode.srcIn,
                child: Icon(
                  icon,
                  size: size * 0.42,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (locked) {
      // Desaturate + darken (the mock's greyscale tiles).
      badge = ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.117, 0.393, 0.040, 0, 0,
          0.117, 0.393, 0.040, 0, 0,
          0.117, 0.393, 0.040, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: badge,
      );
    }
    return badge;
  }
}

class _BadgePainter extends CustomPainter {
  final ({Color dark, Color base, Color light}) palette;
  final LinearGradient gradient;
  final int bars;
  final bool isDiamond;

  _BadgePainter({
    required this.palette,
    required this.gradient,
    required this.bars,
    required this.isDiamond,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width;
    final center = Offset(s / 2, s / 2);
    final r = s * 0.47;

    // Metal ring.
    final ringPaint = Paint()
      ..shader = gradient.createShader(Offset.zero & size)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, r, ringPaint);

    // Ring bevel lines (renderer: outer hairline + inner bevel).
    final outerBevel = Paint()
      ..color = Colors.black.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.006;
    canvas.drawCircle(center, r - s * 0.003, outerBevel);
    final innerBevel = Paint()
      ..color = Color.lerp(palette.dark, Colors.black, 0.45)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.010;
    canvas.drawCircle(center, r * 0.86, innerBevel);

    // Inner disc — the renderer's SURF, #0D1428 (brief-exact).
    final discPaint = Paint()..color = const Color(0xFF0D1428);
    canvas.drawCircle(center, r * 0.845, discPaint);

    // Diamond facets: faint lines across the disc (renderer).
    if (isDiamond) {
      final facet = Paint()
        ..color = const Color(0xFFBEE6FC).withValues(alpha: 0.14)
        ..strokeWidth = s * 0.006;
      for (final deg in [25.0, 90.0, 155.0]) {
        final a = deg * 3.141592653589793 / 180;
        final dx = r * 0.845 * math.cos(a);
        final dy = r * 0.845 * math.sin(a);
        canvas.drawLine(
          Offset(center.dx - dx, center.dy - dy),
          Offset(center.dx + dx, center.dy + dy),
          facet,
        );
      }
    }

    // Level bars under the icon: vertical rounded bars in the
    // palette's light tone with a dark outline (renderer).
    final bw = (s * 0.030).clamp(1.2, double.infinity);
    final bh = s * 0.066;
    const gapRatio = 0.020;
    final gap = s * gapRatio;
    final totalW = bars * bw + (bars - 1) * gap;
    var x = center.dx - totalW / 2;
    final y = center.dy + r * 0.58;
    final barFill = Paint()..color = palette.light;
    final barStroke = Paint()
      ..color = Color.lerp(palette.dark, Colors.black, 0.45)!
      ..style = PaintingStyle.stroke
      ..strokeWidth = (s * 0.003).clamp(0.6, double.infinity);
    for (var i = 0; i < bars; i++) {
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, bw, bh),
        Radius.circular(bw * 0.38),
      );
      canvas.drawRRect(rect, barFill);
      canvas.drawRRect(rect, barStroke);
      x += bw + gap;
    }

    // Diamond sparkles (renderer).
    if (isDiamond) {
      _sparkle(canvas, Offset(center.dx - r * 0.52, center.dy - r * 0.60),
          s * 0.045, Colors.white.withValues(alpha: 0.92));
      _sparkle(canvas, Offset(center.dx + r * 0.58, center.dy - r * 0.34),
          s * 0.032, Colors.white.withValues(alpha: 0.78));
    }
  }

  void _sparkle(Canvas canvas, Offset c, double s, Color color) {
    final path = Path()
      ..moveTo(c.dx, c.dy - s)
      ..lineTo(c.dx + s * 0.16, c.dy - s * 0.16)
      ..lineTo(c.dx + s, c.dy)
      ..lineTo(c.dx + s * 0.16, c.dy + s * 0.16)
      ..lineTo(c.dx, c.dy + s)
      ..lineTo(c.dx - s * 0.16, c.dy + s * 0.16)
      ..lineTo(c.dx - s, c.dy)
      ..lineTo(c.dx - s * 0.16, c.dy - s * 0.16)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_BadgePainter oldDelegate) =>
      oldDelegate.bars != bars ||
      oldDelegate.isDiamond != isDiamond ||
      oldDelegate.palette != palette;
}
