import 'package:flutter/material.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/daily_score_vocabulary.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Lab (TikTok-UI exploration) — the Daily Score HERO card.
///
/// The reference layout system's hero pattern (streak hero): one
/// large grouped card topping the scroll, centered composition —
/// a small muted label, the score as the dominant numeral (the
/// existing [DailyScoreFace] at hero size, so the number carries
/// the card), and the band caption under it. All wording is the
/// existing Daily Score vocabulary ('Daily Score', the band words,
/// 'Building' / 'Waiting') — no new copy. A null [score] renders
/// the honest no-data state exactly as the old header pairing did:
/// the face's '--', never an invented number, with the building /
/// pending chip distinguishing the two null states. Tap opens the
/// Daily Score detail, as the header circle's tap did.
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
                  DailyScoreFace(score: score, size: 132),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: band?.color ?? NotelColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      band?.label ?? (pending ? 'Waiting' : 'Building'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: band == null
                            ? NotelColors.textSecondary
                            : NotelColors.background,
                      ),
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
