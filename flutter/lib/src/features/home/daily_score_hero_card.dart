import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/home/daily_score_vocabulary.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Lab (TikTok-UI exploration) — the Daily Score HERO card.
///
/// The reference layout system's hero pattern (f_011 streak hero):
/// one large QUIET grouped card topping the scroll — a small muted
/// label, the score as the dominant numeral sitting directly on
/// the dark card surface, and a muted caption under it. Fix round
/// (Vera condition C2): the hero no longer reuses [DailyScoreFace]
/// — no purple liquid fill, no thick ring, no solid band chip.
/// The only color is a THIN progress arc around the numeral,
/// drawn in the band color (green for "Good"); the band word is a
/// muted caption line, not a filled chip. This presentation is
/// hero-only: the Daily Score detail screen keeps its face, and
/// no score computation or state logic lives here.
///
/// All wording is the existing Daily Score vocabulary ('Daily
/// Score', the band words, 'Building' / 'Waiting') — no new copy.
/// A null [score] renders the honest no-data state exactly as
/// before: '--' as the numeral, never an invented number, an
/// empty arc track, and the building / pending caption
/// distinguishing the two null states. Tap opens the Daily Score
/// detail, as the header circle's tap did.
class DailyScoreHeroCard extends StatelessWidget {
  /// Today's persisted score, or null while no score exists.
  final int? score;

  /// True when today is unscored because it is not yet complete
  /// (the completeness gate's pending state). Only meaningful
  /// when [score] is null.
  final bool pending;
  final VoidCallback? onTap;

  const DailyScoreHeroCard({
    super.key,
    required this.score,
    this.pending = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final band = score == null ? null : bandForScore(score!);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: NotelColors.legacyDarkHairline, width: 1),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          child: Semantics(
            button: true,
            label: score == null
                ? (pending
                    ? 'Daily Score, waiting for today\'s health data'
                    : 'Daily Score, building baseline')
                : 'Daily Score $score, ${band!.label}',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Daily Score',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 14),
                  _HeroScoreRing(score: score),
                  const SizedBox(height: 12),
                  // The band as a muted caption line (reference:
                  // "Best 8 days" under the numeral) — the word
                  // itself carries the state; the arc above is the
                  // only place the band color appears.
                  Text(
                    band?.label ?? (pending ? 'Waiting' : 'Building'),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The hero's score composition: a thin progress arc (sweep ∝
/// score, from the top, band color) around the dominant numeral,
/// which sits directly on the card surface — the ring's interior
/// is NOT filled, so the surface color shows through. A null
/// score paints only the empty track and the '--' numeral.
class _HeroScoreRing extends StatelessWidget {
  final int? score;

  const _HeroScoreRing({required this.score});

  /// Composition size: same footprint the old 132dp face gave the
  /// card, now mostly open surface around the numeral.
  static const double _size = 132;

  @override
  Widget build(BuildContext context) {
    final band = score == null ? null : bandForScore(score!);
    return SizedBox(
      width: _size,
      height: _size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: const Size(_size, _size),
            painter: _HeroArcPainter(
              score: score,
              arcColor: band?.color ?? NotelColors.surfaceHigh,
            ),
          ),
          Text(
            // §0.7: a missing number renders '--', as everywhere
            // else in the app — never a one-off glyph.
            score?.toString() ?? '--',
            style: TextStyle(
              fontSize: 64,
              height: 1.0,
              fontWeight: FontWeight.w900,
              color: score == null
                  ? NotelColors.textSecondary
                  : NotelColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _HeroArcPainter extends CustomPainter {
  final int? score;
  final Color arcColor;

  const _HeroArcPainter({required this.score, required this.arcColor});

  /// Thin arc — a progress ring, not the old face's thick band
  /// (the face's ring was 10% of its size; this is a fixed 5dp).
  static const double _strokeWidth = 5;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - _strokeWidth / 2;

    // Track: the full circle in the elevated surface tone.
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = _strokeWidth
      ..color = NotelColors.surfaceHigh;
    canvas.drawCircle(center, radius, track);

    // Progress arc: sweep ∝ score from the top, band color only.
    final s = score;
    if (s != null && s > 0) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = _strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = arcColor;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * (s / 100),
        false,
        arc,
      );
    }
    // No interior fill: the card surface is the numeral's ground.
  }

  @override
  bool shouldRepaint(_HeroArcPainter oldDelegate) =>
      oldDelegate.score != score || oldDelegate.arcColor != arcColor;
}
