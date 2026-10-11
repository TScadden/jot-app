import 'package:flutter/material.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 7 — the vitals strip ("Restored Black Health Metrics Box" in the
/// native `TodayScreen.kt`).
///
/// Four cells — heart rate, active calories, log count, sleep — separated by
/// vertical dividers. Values come from Health Connect in the native app;
/// Health Connect is NOT wired yet in this fresh app, so:
///
/// - heart rate → "--" (native: shown only when avgHeartRate > 0)
/// - active calories → "--" (native: shown only when activeCalories > 0)
/// - logs → "0" — REAL: this fresh app has no logs, and the native app
///   shows the raw count even when 0 (`"${state.jotCountDaily}"`)
/// - sleep → "--" (native: shown only when sleepMinutes > 0)
///
/// Never invent numbers: the native "never show placeholder zeros" rule
/// applies here too. Each cell's data source gets wired in a later round.
class VitalsStrip extends StatelessWidget {
  const VitalsStrip({super.key});

  @override
  Widget build(BuildContext context) {
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
            value: '--', // TODO: wire Health Connect avgHeartRate
          ),
          _divider(),
          _cell(
            icon: Icons.whatshot,
            iconColor: NotelColors.error,
            label: 'Calories',
            value: '--', // TODO: wire Health Connect activeCalories
          ),
          _divider(),
          _cell(
            icon: Icons.edit,
            iconColor: NotelColors.success,
            label: 'Logs',
            value: '0', // Real: no logs exist in this fresh app yet.
          ),
          _divider(),
          _cell(
            icon: Icons.nightlight_round,
            iconColor: NotelColors.info,
            label: 'Sleep',
            value: '--', // TODO: wire Health Connect sleepMinutes
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
/// Streaks are computed from log history in the native app and event
/// counters are user-created in Quick Log — neither source is wired yet,
/// so every value renders "--". Layout matches the native app exactly so
/// the founder can verify it now; data lands in later rounds.
class HomeStreakRow extends StatelessWidget {
  const HomeStreakRow({super.key});

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
                value: '--', // TODO: wire currentStreak from log history
                valueColor: NotelColors.warning,
              ),
              const SizedBox(width: 8),
              _streakPill(
                glyph: '🏆',
                value: '--', // TODO: wire bestStreak from log history
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
