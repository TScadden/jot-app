import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 7 — the vitals strip ("Restored Black Health Metrics Box" in the
/// native `TodayScreen.kt`).
///
/// Four cells — heart rate, active calories, log count, sleep — separated by
/// vertical dividers.
///
/// Round 13 — [vitals] carries the real data:
/// - heart rate → daytime-only Health Connect average, "--" when missing
/// - active calories → Health Connect, "--" when missing/0
/// - logs → the REAL today count (native shows the raw count even when 0;
///   "0" is honest here, not a placeholder)
/// - sleep → Health Connect minutes, "--" when missing/0
///
/// Null [vitals] keeps the round-7 honest placeholders. Never invents
/// numbers: the native "never show placeholder zeros" rule applies to the
/// biometrics.
class VitalsStrip extends StatelessWidget {
  final TodayVitals? vitals;

  const VitalsStrip({super.key, this.vitals});

  @override
  Widget build(BuildContext context) {
    final v = vitals;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
      decoration: BoxDecoration(
        color: NotelColors.legacyDarkScrim,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NotelColors.legacyDarkHairline, width: 1),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _cell(
            icon: Icons.favorite,
            iconColor: NotelColors.primary,
            label: 'Heart Rate',
            value: v?.heartRate?.toString() ?? '--',
          ),
          _divider(),
          _cell(
            icon: Icons.whatshot,
            iconColor: NotelColors.error,
            label: 'Calories',
            value: v?.activeCalories?.toString() ?? '--',
          ),
          _divider(),
          _cell(
            icon: Icons.edit,
            iconColor: NotelColors.success,
            label: 'Logs',
            value: '${v?.logCountToday ?? 0}',
          ),
          _divider(),
          _cell(
            icon: Icons.nightlight_round,
            iconColor: NotelColors.info,
            label: 'Sleep',
            value: v?.sleepMinutes?.toString() ?? '--',
          ),
        ],
      ),
    );
  }

  Widget _cell({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: iconColor, semanticLabel: label),
        const SizedBox(width: 4),
        Text(
          value,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: NotelColors.legacyDarkOnDark,
          ),
        ),
      ],
    );
  }

  Widget _divider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.0),
      child: Container(
        width: 1,
        height: 16,
        color: NotelColors.legacyDarkDivider,
      ),
    );
  }
}

/// Round 7 — the streak boxes + event-counter row (native `TodayScreen.kt`
/// "Compact Streak Boxes & Rotating Event Counters Row").
///
/// Left: current-streak pill (🔥) and best-streak pill (🏆). Right: the
/// rotating event-counter slot ("Until X … N Days").
///
/// Round 13 — [currentStreak]/[bestStreak] carry the real streaks from the
/// backend sync pull; null renders "--". The event counter stays "--"
/// (out of scope — user-created counters aren't wired yet).
class HomeStreakRow extends StatelessWidget {
  final int? currentStreak;
  final int? bestStreak;

  const HomeStreakRow({super.key, this.currentStreak, this.bestStreak});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left: streak pills.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _streakPill(
                glyph: '🔥',
                value: currentStreak?.toString() ?? '--',
                valueColor: NotelColors.warning,
              ),
              const SizedBox(width: 8),
              _streakPill(
                glyph: '🏆',
                value: bestStreak?.toString() ?? '--',
                valueColor: NotelColors.streakGold,
              ),
            ],
          ),
          // Right: event-counter slot. Native shows a rotating pager of
          // user-created counters here; with no counters wired, the exact
          // layout renders with "--" placeholders.
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 12.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Flexible(
                    child: Text(
                      '--', // TODO: wire event-counter label ("Until …")
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                        color: NotelColors.primary.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '--', // TODO: wire event-counter day count
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'Days',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.5,
                      color: NotelColors.textSecondary,
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

  Widget _streakPill({
    required String glyph,
    required String value,
    required Color valueColor,
  }) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: const Color(0xFFFFFFFF).withValues(alpha: 0.08),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 6.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(glyph, style: const TextStyle(fontSize: 12)),
          const SizedBox(width: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: valueColor,
            ),
          ),
        ],
      ),
    );
  }
}
