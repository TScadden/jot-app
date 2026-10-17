import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/home/daily_score_vocabulary.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// R70 Daily Score — the score face and the Home header pairing,
/// built to the founder-approved concept (shown to him Oct 17,
/// 2026; see `daily_score_vocabulary.dart` for the wording status
/// of every string).
///
/// The face: a band-color progress ARC (sweep ∝ score) around a
/// purple LIQUID fill that rises with the score (fill height ∝
/// score, Tabs purple, gentle wave crest), the number centered,
/// and — at detail size — the "Daily Score" label inside the
/// circle under the number, as in the concept. The word is never
/// carried by color alone: the header pairing adds the "Daily
/// Score" label and a solid band-word chip beside the circle, and
/// the detail screen shows the same face large with its chip.
///
/// Scaling note (for Mira's pass): the concept pairs the circle
/// with a large weather CARD; the real Home weather element is the
/// small AppBar action, so the header face is 44dp beside it —
/// concept language at the real layout's scale.
///
/// A null score renders the cold-start baseline-building state:
/// the empty ring/disc with a dash, NO liquid and NO number (a
/// number is never shown or persisted from nothing).

/// The circular score face (arc + liquid + number). Purely
/// presentational; [score] is the day's persisted score.
class DailyScoreFace extends StatelessWidget {
  final int? score;
  final double size;

  /// Shows the "Daily Score" label inside the circle under the
  /// number (detail size, as in the concept). Too small to read at
  /// header size, where the label sits beside the circle instead.
  final bool showInnerLabel;

  const DailyScoreFace({
    super.key,
    required this.score,
    required this.size,
    this.showInnerLabel = false,
  });

  @override
  Widget build(BuildContext context) {
    final band = score == null ? null : bandForScore(score!);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _ScoreFacePainter(
              score: score,
              bandColor: band?.color ?? NotelColors.surfaceHigh,
            ),
          ),
          // FittedBox: the number (+ inner label at detail size)
          // always fits the face, whatever the font metrics — a
          // three-digit score in a small face scales down instead
          // of wrapping or overflowing.
          //
          // R71 face centering (Mira's measured pass, superseding
          // the R70 fixed-10 inner label): the number+label group
          // is sized analytically — number line 0.36·S × height
          // 0.90 = 0.324·S, explicit gap 0.024·S, label line
          // 0.115·S × height 1.00 — a total group height of
          // 0.463·S — and the whole group is shifted up optically
          // by 0.018·S (Transform.translate below) so the glyph
          // union sits centered on the face instead of reading low.
          Transform.translate(
            offset: Offset(0, -size * 0.018),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    // §0.7: a missing number renders '--', as everywhere
                    // else in the app — never a one-off glyph.
                    score?.toString() ?? '--',
                    style: TextStyle(
                      fontSize: size * 0.36,
                      height: 0.90,
                      fontWeight: FontWeight.w900,
                      // Ink over the liquid, measured (Mira pass,
                      // Oct 17, 2026): the number sits over the purple
                      // fill whenever the score is mid/high and over
                      // the dark disc when low, and pure white beats
                      // textPrimary on BOTH — 3.80:1 vs 3.32:1 on
                      // primary, 18.30:1 vs 16.01:1 on surface. White
                      // is also the concept's number ink.
                      color: score == null
                          ? NotelColors.textSecondary
                          : Colors.white,
                    ),
                  ),
                  if (showInnerLabel && score != null)
                    SizedBox(height: size * 0.024),
                  if (showInnerLabel && score != null)
                    Text(
                      'Daily Score',
                      style: TextStyle(
                        // R71: 0.115·S at height 1.00 (Mira's
                        // measured pass) — supersedes the R70
                        // fixed-10 label.
                        fontSize: size * 0.115,
                        height: 1.00,
                        fontWeight: FontWeight.w600,
                        // Solid white, no alpha: at detail size this
                        // label sits over the liquid (pixel-sampled at
                        // score 78), where textPrimary @ 85% composites
                        // to 2.84:1 — below the 3:1 floor. Solid white
                        // measures 3.80:1 on primary (Mira pass).
                        color: Colors.white,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScoreFacePainter extends CustomPainter {
  final int? score;
  final Color bandColor;
  const _ScoreFacePainter({required this.score, required this.bandColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final ringWidth = size.width * 0.10;
    final ringRadius = size.width / 2 - ringWidth / 2;

    // Ring track + band arc (sweep ∝ score, from the top).
    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth
      ..color = NotelColors.surfaceHigh;
    canvas.drawCircle(center, ringRadius, track);
    final s = score;
    if (s != null && s > 0) {
      final arc = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringWidth
        ..strokeCap = StrokeCap.round
        ..color = bandColor;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: ringRadius),
        -math.pi / 2,
        2 * math.pi * (s / 100),
        false,
        arc,
      );
    }

    // Inner disc + liquid (fill height ∝ score).
    final innerRadius = ringRadius - ringWidth / 2 - size.width * 0.02;
    if (innerRadius <= 0) return;
    canvas.save();
    canvas.clipPath(
      Path()..addOval(Rect.fromCircle(center: center, radius: innerRadius)),
    );
    canvas.drawCircle(center, innerRadius, Paint()..color = NotelColors.surface);
    if (s != null && s > 0) {
      final diameter = innerRadius * 2;
      final level = diameter * (s / 100);
      final crestY = center.dy + innerRadius - level;
      final amp = innerRadius * 0.10;
      final left = center.dx - innerRadius;
      final right = center.dx + innerRadius;
      final mid = center.dx;
      // The wave crest: two gentle humps, as in the concept.
      Path waveTop() => Path()
        ..moveTo(left, crestY)
        ..quadraticBezierTo(
            left + diameter * 0.25, crestY - amp, mid, crestY)
        ..quadraticBezierTo(
            mid + diameter * 0.25, crestY + amp, right, crestY);
      final liquid = waveTop()
        ..lineTo(right, center.dy + innerRadius)
        ..lineTo(left, center.dy + innerRadius)
        ..close();
      canvas.drawPath(liquid, Paint()..color = NotelColors.primary);
      // Crest highlight line (the liquid's lit surface).
      canvas.drawPath(
        waveTop(),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, size.width * 0.02)
          ..color = NotelColors.primaryText.withValues(alpha: 0.55),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ScoreFacePainter oldDelegate) =>
      oldDelegate.score != score || oldDelegate.bandColor != bandColor;
}

/// The Home header pairing: the face beside the weather action,
/// with the "Daily Score" label and the band-word chip next to it
/// (concept language at the real header's scale). A null [score]
/// renders the baseline-building state — pulsing empty face, dash,
/// "Building" chip, no number.
class DailyScoreCircle extends StatefulWidget {
  /// Today's persisted score, or null while the baseline builds.
  final int? score;
  final VoidCallback? onTap;

  const DailyScoreCircle({super.key, required this.score, this.onTap});

  @override
  State<DailyScoreCircle> createState() => _DailyScoreCircleState();
}

class _DailyScoreCircleState extends State<DailyScoreCircle>
    with SingleTickerProviderStateMixin {
  AnimationController? _pulse;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(DailyScoreCircle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.score != widget.score) _syncPulse();
  }

  /// Building-state pulse: the skeleton system's 1100ms easeInOut
  /// pulse (design-audit §8 allowed set). Reduced motion renders
  /// the static final state — no controller at all.
  void _syncPulse() {
    final shouldPulse = widget.score == null && !animationsDisabled(context);
    if (shouldPulse && _pulse == null) {
      _pulse = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 1100),
      )..repeat(reverse: true);
    } else if (!shouldPulse && _pulse != null) {
      _pulse!.dispose();
      _pulse = null;
    }
  }

  @override
  void dispose() {
    _pulse?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final score = widget.score;
    final band = score == null ? null : bandForScore(score);
    final face = DailyScoreFace(score: score, size: 44);
    final pulsed = _pulse == null
        ? face
        : AnimatedBuilder(
            animation: _pulse!,
            builder: (_, child) => Opacity(
              opacity: 0.55 + 0.45 * _pulse!.value,
              child: child,
            ),
            child: face,
          );
    return Semantics(
      button: true,
      label: score == null
          ? 'Daily Score, building baseline'
          : 'Daily Score $score, ${band!.label}',
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                pulsed,
                const SizedBox(width: 6),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Daily Score',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: NotelColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: band?.color ?? NotelColors.surfaceHigh,
                        // Chip radius 12 (closed scale §6; native
                        // Radii.chip) — at this height it still
                        // renders as the concept's pill.
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        band?.label ?? 'Building',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: band == null
                              ? NotelColors.textSecondary
                              : NotelColors.background,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
