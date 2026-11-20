import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/features/home/event_counter_rotator.dart';
import 'package:tabs_lab/src/features/home/streak_flame.dart';
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

  /// Home redesign — compact variant for the AppBar title slot: tighter
  /// padding, tighter divider slots, no outer margin, and
  /// content width instead of the body column's full width. Cell
  /// order, radius and scrim are unchanged.
  ///
  /// Header alignment package (Nov 10, 2026, founder ruling "pill a
  /// little bigger"): the compact pill steps back up from the
  /// redesign's measured 211.3×36.0dp to ≈251×39dp — padding
  /// h10/v8 → h15/v8, divider slots h1 → h3, icon 16 → 17, values
  /// 14sp → 15sp bold (icon∶text scale relationship kept), cell
  /// icon–value gap 4 → 5. The non-compact strip is untouched.
  final bool compact;

  const VitalsStrip(
      {super.key,
      this.vitals,
      this.animateCountUps = true,
      this.compact = false});

  @override
  Widget build(BuildContext context) {
    final v = vitals;
    return Container(
      key: compact ? const Key('vitalsStripCompact') : null,
      margin: compact
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 16.0, vertical: 6.0),
      decoration: BoxDecoration(
        color: NotelColors.legacyDarkScrim,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: NotelColors.legacyDarkHairline, width: 1),
      ),
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 15.0, vertical: 8.0)
          : const EdgeInsets.symmetric(horizontal: 12.0, vertical: 12.0),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
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
              style: _effectiveValueStyle,
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
              style: _effectiveValueStyle,
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
              style: _effectiveValueStyle,
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
              style: _effectiveValueStyle,
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

  /// Header alignment package (Nov 10, 2026) — the compact pill's
  /// stepped-up value size (14sp → 15sp), keeping the icon∶text
  /// relationship with the compact icon at 17.
  static const _valueStyleCompact = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.bold,
    color: NotelColors.legacyDarkOnDark,
  );

  TextStyle get _effectiveValueStyle =>
      compact ? _valueStyleCompact : _valueStyle;

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
        Icon(icon,
            size: compact ? 17 : 16, color: iconColor, semanticLabel: label),
        SizedBox(width: compact ? 5 : 4),
        value,
      ],
    );
  }

  Widget _divider() {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: compact ? 3.0 : 2.0),
      child: Container(
        width: 1,
        height: 16,
        color: NotelColors.legacyDarkDivider,
      ),
    );
  }
}

/// One streak pill — the exact construction [HomeStreakRow] has always
/// used (height 34, radius 8, surfaceHigh @ 15% fill, white @ 8% border,
/// glyph 12sp + value 12sp bold), shared by the row and the redesign's
/// vertical stack so the two never drift.
///
/// The leading slot is the [leading] widget (the current-streak
/// flame, [StreakPillFlame]).
///
/// Added scope #5 (Nov 20, 2026, founder direction): the trophy /
/// best-streak pill is removed from Home entirely — Home shows only
/// the current streak and the gems. The best/record streak still
/// lives on the streak screen; its data and computation are
/// untouched. With the trophy gone, the old text-`glyph` leading
/// slot had no remaining caller and was removed with it.
Widget streakPill({required Widget leading, required Widget value}) {
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
        leading,
        const SizedBox(width: 4),
        value,
      ],
    ),
  );
}

/// The current-streak pill's flame (added scope, Nov 19, 2026 —
/// founder direction: the Home pill carries the streak screen's
/// flame presentation, not the Unicode 🔥 emoji).
///
/// The presentation is [StreakFlame]'s, rendered statically at pill
/// scale: `Icons.local_fire_department`, lit #FF6A3D when today is
/// complete; while today is incomplete, StreakFlame's grey
/// treatment verbatim — icon #8E97B8 under its desaturation matrix
/// at 45% opacity. [lit] is the streak screen's todayDone rule
/// (today counted in the SETTLED streak state), derived by the
/// caller from the same settled state that feeds the pill counts —
/// never a parallel read, and never lit on a guess.
///
/// StreakFlame itself is not reused here: its lit branch runs a
/// perpetual 1600ms flicker controller, and this pill is an
/// always-visible Home surface — a perpetual ticker there keeps
/// repaint boundaries dirty (the capture harnesses freeze tickers
/// for exactly this) and adds motion beyond the directed glyph
/// swap. No second animation is hand-rolled either: the pill flame
/// is static in both states.
///
/// Icon size 15 matches the replaced emoji glyph's measured
/// footprint (the 12sp emoji text measured 15.2 wide in the test
/// harness with Roboto + Noto Color Emoji loaded). 16 was tried
/// first and overflowed the pill by 0.500px inside Home's
/// founder-fixed 62dp corner slot (the baseline pill fit with
/// under 0.5px of headroom) — the slot geometry does not move
/// for this swap, so the icon sits 0.2dp under the emoji's
/// measured width instead.
class StreakPillFlame extends StatelessWidget {
  final bool lit;

  const StreakPillFlame({super.key, required this.lit});

  /// StreakFlame's lit color.
  static const Color litColor = Color(0xFFFF6A3D);

  /// StreakFlame's unlit icon color (before desaturation).
  static const Color unlitColor = Color(0xFF8E97B8);

  /// StreakFlame's unlit opacity.
  static const double unlitOpacity = 0.45;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      Icons.local_fire_department,
      size: 15,
      color: lit ? litColor : unlitColor,
    );
    if (lit) return icon;
    // Grey state: StreakFlame's desaturation matrix + opacity,
    // verbatim from streak_flame.dart.
    return Opacity(
      opacity: unlitOpacity,
      child: ColorFiltered(
        colorFilter: const ColorFilter.matrix(<double>[
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0.2126, 0.7152, 0.0722, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: icon,
      ),
    );
  }
}

/// The gem pill's count color (founder-approved mock, Nov 19,
/// 2026): lavender, following the streak pills' per-pill accent
/// pattern (gold for the trophy, orange for the flame).
const Color kGemCountColor = Color(0xFFB9AFFF);

/// The Home gem pill (gems feature, Nov 19, 2026): directly under
/// the current-streak pill, same pill construction as [streakPill]
/// (height 34, radius 8, same fill/border/padding), founder-
/// approved gem icon v1 + the SERVER balance in lavender, plain
/// digits (no thousands separator). The pill hugs its content, so
/// it widens as the count grows. Its semantics label is Juno §1
/// (`{count} gems` / `1 gem`) via [GemCopy.pillLabel].
class HomeGemPill extends StatelessWidget {
  final int gemBalance;

  const HomeGemPill({super.key, required this.gemBalance});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      label: GemCopy.pillLabel(gemBalance),
      child: ExcludeSemantics(
        child: Container(
          key: const Key('homeGemPill'),
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
              Image.asset(
                GemCopy.iconAsset,
                key: const Key('homeGemPillIcon'),
                height: 20,
                fit: BoxFit.contain,
              ),
              const SizedBox(width: 4),
              Text(
                '$gemBalance',
                key: const Key('homeGemPillCount'),
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: kGemCountColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Home redesign — the streak pill as a vertical stack for the corner
/// band: flame CURRENT on top (tweak 5), 8dp gaps, hug content width,
/// left aligned. The stack is ONE combined tap target, exactly as in
/// [HomeStreakRow]; null values render `--` via CountUp.
///
/// Added scope #5 (Nov 20, 2026, founder direction): the 🏆
/// best-streak pill no longer renders here — the stack is exactly
/// the current-streak pill plus, when a balance has landed, the gem
/// pill. The best/record streak is still computed and still shown
/// on the streak screen.
///
/// Gems (Nov 19, 2026): when [gemBalance] is non-null (a server
/// balance has landed), the gem pill renders DIRECTLY UNDER the
/// current-streak pill in the same stack and the same tap target.
/// Null keeps the pre-gems stack exactly — no pill is rendered on
/// a guess.
class HomeStreakStack extends StatelessWidget {
  final int? currentStreak;
  final bool animateCountUps;
  final VoidCallback? onStreakTap;

  /// Whether today is complete per the SETTLED streak state — the
  /// streak screen's todayDone rule (today counted in the settled
  /// state's countedDays). Home derives this from the same settled
  /// state that writes [currentStreak]; false until a
  /// settled state lands, so the pill flame is grey, never lit on a
  /// guess. Drives [StreakPillFlame].
  final bool streakTodayComplete;

  /// The server gem balance for the gem pill under the streak
  /// pills; null hides the pill (no server value yet).
  final int? gemBalance;

  /// Header alignment package (Nov 10, 2026) — the Home corner
  /// band centers the pills in their 62dp slot so both pills share
  /// the slot's center axis (the drawer button's axis) whatever
  /// their content widths. Default keeps the original
  /// left-aligned construction.
  final CrossAxisAlignment crossAxisAlignment;

  const HomeStreakStack({
    super.key,
    this.currentStreak,
    this.animateCountUps = true,
    this.onStreakTap,
    this.crossAxisAlignment = CrossAxisAlignment.start,
    this.gemBalance,
    this.streakTodayComplete = false,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('homeStreakPills'),
      behavior: HitTestBehavior.opaque,
      onTap: onStreakTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: crossAxisAlignment,
        children: [
          streakPill(
            leading: StreakPillFlame(lit: streakTodayComplete),
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
          if (gemBalance != null) ...[
            const SizedBox(height: 8),
            HomeGemPill(gemBalance: gemBalance!),
          ],
        ],
      ),
    );
  }
}

/// Round 7 — the streak boxes + event-counter row (native `TodayScreen.kt`
/// "Compact Streak Boxes & Rotating Event Counters Row").
///
/// Left: current-streak pill (flame). Right:
/// the rotating event-counter slot ("Until X … N Days").
///
/// Added scope #5 (Nov 20, 2026, founder direction): the 🏆
/// best-streak pill no longer renders here either — the row carries
/// only the current streak. The best/record streak is still
/// computed and still shown on the streak screen.
///
/// Round 13 — [currentStreak] carries the real streak from the
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

  /// Round 15c — false on later home views the same day (the once-per-day
  /// count-up gate already fired): numbers render instantly.
  final bool animateCountUps;

  /// Round 34 — active event counters for the rotating slot.
  final List<EventCounterItem> counters;

  /// Round 34 — tap on the counter slot (opens Settings → Event
  /// Counters). Null disables the tap.
  final VoidCallback? onCountersTap;

  /// Lab (streak screen package, Nov 4, 2026) — tap on the streak
  /// pill (opens the Streak detail screen). Null disables the tap.
  /// The pill's visuals are unchanged; it is the tap target.
  final VoidCallback? onStreakTap;

  /// Whether today is complete per the SETTLED streak state (the
  /// streak screen's todayDone rule) — same source and default as
  /// [HomeStreakStack.streakTodayComplete]. Drives the
  /// current-streak pill's [StreakPillFlame].
  final bool streakTodayComplete;

  const HomeStreakRow(
      {super.key,
      this.currentStreak,
      this.animateCountUps = true,
      this.counters = const [],
      this.onCountersTap,
      this.onStreakTap,
      this.streakTodayComplete = false});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Left: the current-streak pill. Lab (streak screen
          // package) — it is the tap target for the Streak detail
          // screen when [onStreakTap] is provided; visuals unchanged.
          GestureDetector(
            key: const Key('homeStreakPills'),
            behavior: HitTestBehavior.opaque,
            onTap: onStreakTap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _streakPill(
                  leading: StreakPillFlame(lit: streakTodayComplete),
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
              ],
            ),
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
    required Widget leading,
    required Widget value,
  }) =>
      streakPill(leading: leading, value: value);
}
