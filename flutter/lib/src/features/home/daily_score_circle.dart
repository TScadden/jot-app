import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// R70 Daily Score — score bands and the Home header circle.
///
/// Bands carry a TEXT label as well as a color (never color
/// alone). The words are plain state words proposed for Juno's
/// wording pass — no diagnostic language, no borrowed vendor
/// "readiness" language, no accuracy claims. FLAG FOR JUNO: every
/// string in this file and `daily_score_screen.dart`.
///
/// Design notes (for Mira's pass):
/// - Solid band color, NOT a partial fill level: at 34dp a
///   fuel-tank fill line would sit behind the two-digit numeral
///   and muddy it — the numeral's contrast cannot hold against
///   both the filled and unfilled parts of the circle. The solid
///   fill keeps one honest glanceable state per band; the band
///   word under the circle carries the same information in text.
/// - Numeral is `NotelColors.background` ink on the band fill:
///   ≥ 4.9:1 against every band token (white fails on success /
///   warning); band words use the band token as text on the page
///   background (≥ 6.9:1 for every band).

/// One score band: range, plain state word, token color.
class DailyScoreBand {
  final String label;
  final Color color;
  const DailyScoreBand(this.label, this.color);
}

/// The band for a persisted score. Ranges: 80+ / 60–79 / 40–59 /
/// below 40.
DailyScoreBand bandForScore(int score) {
  if (score >= 80) return const DailyScoreBand('Strong', NotelColors.success);
  if (score >= 60) return const DailyScoreBand('Steady', NotelColors.info);
  if (score >= 40) return const DailyScoreBand('Low', NotelColors.warning);
  return const DailyScoreBand('Very low', NotelColors.error);
}

/// The Home header circle: today's Daily Score beside the weather
/// icon. A null [score] renders the cold-start baseline-building
/// state — a dash in a pulsing circle, NO number (a number is
/// never shown or persisted from nothing).
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
    final circle = Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: band?.color ?? NotelColors.surfaceHigh,
      ),
      alignment: Alignment.center,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Text(
          score?.toString() ?? '—',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: band == null
                ? NotelColors.textSecondary
                : NotelColors.background,
          ),
        ),
      ),
    );
    final pulsed = _pulse == null
        ? circle
        : AnimatedBuilder(
            animation: _pulse!,
            builder: (_, child) => Opacity(
              opacity: 0.55 + 0.45 * _pulse!.value,
              child: child,
            ),
            child: circle,
          );
    return Semantics(
      button: true,
      label: score == null
          ? 'Daily Score, building baseline'
          : 'Daily Score $score, ${band!.label}',
      child: InkWell(
        onTap: widget.onTap,
        customBorder: const CircleBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                pulsed,
                const SizedBox(height: 2),
                Text(
                  band?.label ?? 'Building',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: band?.color ?? NotelColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
