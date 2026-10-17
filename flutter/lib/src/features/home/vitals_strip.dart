import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/features/home/event_counter_rotator.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 17b — formats sleep minutes exactly like the native
/// `TodayScreen.kt` vitals strip: "8h42m", "1h0m", "45m" (under an hour).
/// Missing/zero sleep never reaches here (the repo nulls it and [CountUp]
/// renders "--"); the cache keeps storing raw minutes and formatting
/// happens at render time, so the CountUp animation tweens the minute
/// value and formats each frame.
String formatSleepMinutes(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  return h > 0 ? '${h}h${m}m' : '${m}m';
}

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

  /// Round 15c — false on later home views the same day (the once-per-day
  /// count-up gate already fired): numbers render instantly.
  final bool animateCountUps;

  const VitalsStrip({super.key, this.vitals, this.animateCountUps = true});

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
            // Round 14 — counts up to the real value on load; "--" until
            // the real value exists (CountUp never invents numbers).
            value: CountUp(
              value: v?.heartRate,
              style: _valueStyle,
              animate: animateCountUps,
            ),
          ),
          _divider(),
          _cell(
            icon: Icons.whatshot,
            iconColor: NotelColors.error,
            label: 'Calories',
            value: CountUp(
              value: v?.activeCalories,
              style: _valueStyle,
              animate: animateCountUps,
            ),
          ),
          _divider(),
          _cell(
            icon: Icons.edit,
            iconColor: NotelColors.success,
            label: 'Logs',
            // The log count is real even at 0 — CountUp handles 0→0 as
            // a static render.
            value: CountUp(
              value: v?.logCountToday ?? 0,
              style: _valueStyle,
              animate: animateCountUps,
            ),
          ),
          _divider(),
          _cell(
            icon: Icons.nightlight_round,
            iconColor: NotelColors.info,
            label: 'Sleep',
            value: CountUp(
              value: v?.sleepMinutes,
              style: _valueStyle,
              animate: animateCountUps,
              // Round 17b — native shows "8h42m", not total minutes.
              format: formatSleepMinutes,
            ),
          ),
        ],
      ),
    );
  }

  static const _valueStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.bold,
    color: NotelColors.legacyDarkOnDark,
  );

  Widget _cell({
    required IconData icon,
    required Color iconColor,
    required String label,
    required Widget value,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(icon, size: 16, color: iconColor, semanticLabel: label),
        const SizedBox(width: 4),
        value,
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
/// backend sync pull; null renders "--".
///
/// Round 34 — [counters] carries the real ACTIVE event counters
/// (profile-synced, Settings list order, archived already excluded by
/// the caller via [activeEventCounters]). The slot is the native
/// rotating pager ([EventCounterRotator]): multiple counters rotate
/// every 10s, one counter is static, and ZERO active counters render
/// no slot at all — no placeholder (native's zero-counter fallback is
/// its upcoming-reminders line, which is not counter data; the
/// founder's round-34 spec rules out an empty placeholder here).
class HomeStreakRow extends StatelessWidget {
  final int? currentStreak;
  final int? bestStreak;

  /// Round 15c — false on later home views the same day (the once-per-day
  /// count-up gate already fired): numbers render instantly.
  final bool animateCountUps;

  /// Round 34 — active event counters for the rotating slot.
  final List<EventCounterItem> counters;

  /// Round 34 — tap on the counter slot (opens Settings → Event
  /// Counters). Null disables the tap.
  final VoidCallback? onCountersTap;

  const HomeStreakRow(
      {super.key,
      this.currentStreak,
      this.bestStreak,
      this.animateCountUps = true,
      this.counters = const [],
      this.onCountersTap});

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
                // Round 14 — counts up to the real streak on load.
                value: CountUp(
                  value: currentStreak,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.warning,
                  ),
                  animate: animateCountUps,
                ),
              ),
              const SizedBox(width: 8),
              _streakPill(
                glyph: '🏆',
                value: CountUp(
                  value: bestStreak,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: NotelColors.streakGold,
                  ),
                  animate: animateCountUps,
                ),
              ),
            ],
          ),
          // Right: event-counter slot (round 34) — the native rotating
          // pager. Zero active counters render NOTHING here (the row
          // is just the streak pills).
          if (counters.isNotEmpty)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 12.0),
                child: EventCounterRotator(
                  counters: counters,
                  onTap: onCountersTap,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _streakPill({
    required String glyph,
    required Widget value,
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
          value,
        ],
      ),
    );
  }
}
