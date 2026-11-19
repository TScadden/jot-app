import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/features/home/streak_flame.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart'
    show kGemCountColor;
import 'package:tabs_lab/src/features/home/streak_share_card.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// The display state one celebration renders from — a plain value,
/// built by the caller from a real [StreakCompletionResult] (the
/// completion path) or IN MEMORY by the Developer Terminal SIM
/// (which constructs the same shape without touching any store).
class StreakCelebrationData {
  /// The settled NEW streak count.
  final int count;

  /// The count as it stood BEFORE this completion — the ignition
  /// roll goes UP from this number to [count] (animation rebuild,
  /// Nov 18, 2026: the founder's "how it goes up from 20"). Null =
  /// derive [count] − 1 (the single-day completion step), so
  /// constructions that predate the field keep the right roll.
  final int? previousCount;

  /// The resolved roll start: [previousCount] when carried, else
  /// the one-step default, never negative.
  int get oldCount {
    final p = previousCount;
    if (p != null) return p;
    return count > 0 ? count - 1 : 0;
  }

  /// The week row: the Tabs days of the current week (Mon-first)
  /// with their counted state; today is the last counted day.
  /// [restored] marks a freeze-covered day (a subset of counted)
  /// — it renders with the freeze treatment, never a check.
  final List<({String label, bool counted, bool isToday, bool restored})> week;

  /// True when [count] is exactly a milestone ladder rung.
  final bool isMilestoneDay;

  /// Juno §5e freeze-used notice, when this completion's
  /// settlement bridged missed days; otherwise null.
  final String? freezeUsedNotice;

  /// Juno §5d earned-landed notice, when an earned freeze landed
  /// during this completion; otherwise null.
  final String? earnedLandedNotice;

  /// Gems — Juno §3 earn lines for THIS completion, in ruled
  /// order (daily, milestone, perfect week), each present ONLY
  /// when its grant was server-confirmed for this completion.
  /// Empty when the day's grants were already made (or none
  /// landed) — no line shows then. The SIM never sets this:
  /// simulated completions never earn.
  final List<String> gemLines;

  const StreakCelebrationData({
    required this.count,
    required this.week,
    required this.isMilestoneDay,
    this.previousCount,
    this.freezeUsedNotice,
    this.earnedLandedNotice,
    this.gemLines = const [],
  });

  /// Builds the display state from a settled completion: the count
  /// is the completion's settled count, the week is derived from
  /// the settled state's counted days, and the notices follow
  /// Juno §5d/§5e verbatim (counts read AFTER the settlement).
  factory StreakCelebrationData.fromCompletion({
    required StreakCompletionResult result,
    required StreakState state,
    required DateTime now,
    List<String> gemLines = const [],
  }) {
    final today = tabsDayStr(now);
    final todayDate = DateTime.parse(today);
    // Monday of today's week.
    final monday = todayDate.subtract(Duration(days: todayDate.weekday - 1));
    const labels = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
    final week =
        <({String label, bool counted, bool isToday, bool restored})>[];
    for (var i = 0; i < 7; i++) {
      final d = monday.add(Duration(days: i));
      final ds = streakDayStr(d);
      week.add((
        label: labels[i],
        counted: state.countedDays.contains(ds),
        isToday: ds == today,
        restored: state.restoredDays.contains(ds),
      ));
    }
    // The roll starts from the run as it stood at yesterday's
    // close: the consecutive counted run ending the day before
    // today in the settled state.
    var previousCount = 0;
    var cursor = todayDate.subtract(const Duration(days: 1));
    while (state.countedDays.contains(streakDayStr(cursor))) {
      previousCount++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    final available = totalAvailableCover(state, now);
    final max = streakCap(state);
    String? freezeNotice;
    if (result.bridgedDays.isNotEmpty) {
      if (result.bridgedDays.length == 1) {
        final d = DateTime.parse(result.bridgedDays.single);
        freezeNotice =
            'A freeze covered ${_monthNames[d.month - 1]} ${d.day} for you, so your streak is still going. You have $available of $max freezes available.';
      } else {
        freezeNotice =
            '${result.bridgedDays.length} freezes covered the missed days for you, so your streak is still going. You have $available of $max freezes available.';
      }
    }
    return StreakCelebrationData(
      count: result.newCount,
      previousCount: previousCount,
      week: week,
      isMilestoneDay: result.isMilestone,
      freezeUsedNotice: freezeNotice,
      earnedLandedNotice: result.earnedLanded
          ? 'Your earned freeze is here. You now have $available of $max freezes available.'
          : null,
      gemLines: gemLines,
    );
  }

  static const _monthNames = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
}

/// The celebration screen (streak upgrade deliverable 2; entrance
/// + sequence rebuilt Nov 18, 2026).
///
/// Fired ONCE per completion by the data layer's completion event
/// (the watcher's fired marker governs). The screen appears IN
/// PLACE (no slide — [InPlacePageRoute] on both the real and SIM
/// paths) and plays the ignition sequence (~2.2 s): grey flame +
/// the OLD count; ignition — the flame lights with an eruption and
/// the count rolls UP old → new; a squash-and-stretch settle as
/// "day streak" lands; the week row loads in ONE BY ONE, left to
/// right; the milestone line and notices fade in; the buttons fade
/// in LAST. The lit flame's subtle flicker then continues. A tap
/// anywhere during the sequence skips to the final state;
/// MediaQuery.disableAnimations renders the final state from the
/// first frame.
///
/// Buttons: NORMAL days — a share icon button + "LET'S GO!"
/// (founder-dictated, Juno copy update §1 — no name), which
/// dismisses. MILESTONE days — the primary button is
/// "SHARE MILESTONE" (Juno §6b) and "Continue" is a demoted text
/// link, visible and tappable WITHOUT sharing first (Juno §6c —
/// never gated; the copy update §2 keeps "Continue" verbatim).
/// Both share actions hand the generated card PNG to the system
/// share sheet.
class StreakCelebrationScreen extends StatefulWidget {
  final StreakCelebrationData data;
  final String? nickname;

  /// True only for the Developer Terminal SIM preview (B-APP-1).
  /// The SIM's count is simulated (settled + 1), and Juno §10
  /// forbids generating a share card from a simulated count, so
  /// when this is set BOTH share affordances (the share icon
  /// button and the SHARE MILESTONE primary button) are suppressed
  /// entirely — not rendered — and [_share] is a no-op. The
  /// YAY/Continue dismissal is unchanged. Real celebrations leave
  /// this false and are unchanged.
  final bool isSimulation;

  /// Test seam: replaces the share-sheet invocation.
  final Future<bool> Function(GlobalKey boundaryKey, int count)? shareFn;

  const StreakCelebrationScreen({
    super.key,
    required this.data,
    this.nickname,
    this.shareFn,
    this.isSimulation = false,
  });

  static Future<void> show(
    BuildContext context, {
    required StreakCelebrationData data,
    String? nickname,
    bool isSimulation = false,
  }) async {
    if (!context.mounted) return;
    await Navigator.of(context).push(
      // In place, never a slide (Nov 18, 2026 fix): the founder's
      // celebration "just slid in from the side" on the shipped
      // build — the takeover moment must not travel.
      InPlacePageRoute<void>(
        builder: (_) => StreakCelebrationScreen(
          data: data,
          nickname: nickname,
          isSimulation: isSimulation,
        ),
      ),
    );
  }

  @override
  State<StreakCelebrationScreen> createState() =>
      _StreakCelebrationScreenState();
}

class _StreakCelebrationScreenState extends State<StreakCelebrationScreen>
    with SingleTickerProviderStateMixin {
  final GlobalKey _cardKey = GlobalKey();
  bool _sharing = false;

  /// The ignition sequence clock (~2.2 s; phase map in build).
  late final AnimationController _seq = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  /// True once the sequence has finished (or was skipped, or
  /// reduced motion rendered the final state): the buttons become
  /// tappable only then — they fade in LAST.
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _seq.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_done && mounted) {
        setState(() => _done = true);
      }
    });
    _seq.forward();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reduced motion: the final state from the first frame — no
    // sequence at all.
    if (MediaQuery.maybeOf(context)?.disableAnimations ?? false) {
      if (_seq.value != 1.0) _seq.value = 1.0;
      if (!_done) _done = true;
    }
  }

  @override
  void dispose() {
    _seq.dispose();
    super.dispose();
  }

  /// A tap during the sequence jumps straight to the final state.
  void _skip() {
    if (_done) return;
    _seq.value = 1.0;
    setState(() => _done = true);
  }

  Future<void> _share() async {
    // B-APP-1 defense in depth: a simulated preview never shares,
    // even if a share affordance were somehow reached.
    if (widget.isSimulation) return;
    if (_sharing) return;
    _sharing = true;
    try {
      final share =
          widget.shareFn ??
          (key, count) =>
              StreakShareService.shareFromBoundary(key, count: count);
      await share(_cardKey, widget.data.count);
    } catch (_) {
      // A share failure keeps the celebration up; the user can
      // retry or simply continue.
    } finally {
      _sharing = false;
    }
  }

  // Sequence phase map (controller value t, ~2.2 s total):
  // ignition at 0.30; the count rolls UP 0.30→0.52; "day streak"
  // lands 0.50→0.62; the week days load in ONE BY ONE from 0.58,
  // staggered 0.045 apart; the milestone line fades 0.88→0.96; the
  // notices 0.90→0.98; the buttons fade in LAST, 0.94→1.00, and
  // are tappable only once the sequence is done.
  static const double _ignitionAt = 0.30;
  static const double _rollEnd = 0.52;

  double _phase(double t, double start, double end) =>
      ((t - start) / (end - start)).clamp(0.0, 1.0);

  /// Flame eruption scale: a fast swell at ignition, then an
  /// elastic settle that dips below 1 (the squash) before resting.
  double _eruption(double t) {
    if (t < _ignitionAt) return 1.0;
    if (t < 0.44) {
      return 1.0 +
          0.30 * Curves.easeOut.transform(_phase(t, _ignitionAt, 0.44));
    }
    if (t < 0.66) {
      return 1.30 - 0.30 * Curves.elasticOut.transform(_phase(t, 0.44, 0.66));
    }
    return 1.0;
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final next = nextMilestone(data.count);
    final distance = next - data.count;
    return Scaffold(
      backgroundColor: LabBlackColors.background,
      body: Stack(
        children: [
          StreakShareCardHost(boundaryKey: _cardKey, count: data.count),
          // A tap anywhere during the sequence skips to the final
          // state (after it, _skip is a no-op and buttons take
          // their own taps).
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _skip,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(22, 60, 22, 26),
                child: AnimatedBuilder(
                  animation: _seq,
                  builder: (context, _) {
                    final t = _seq.value;
                    return Column(
                      children: [
                        _flameAndCount(data, t),
                        const SizedBox(height: 40),
                        _weekRow(data, t),
                        const SizedBox(height: 16),
                        if (data.isMilestoneDay)
                          Opacity(
                            opacity: _phase(t, 0.88, 0.96),
                            child: Text(
                              'You reached a milestone today: ${data.count} days.',
                              key: const Key('celebrationMilestoneLine'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 16.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFC9CEEA),
                              ),
                            ),
                          )
                        else if (distance > 0)
                          Opacity(
                            opacity: _phase(t, 0.88, 0.96),
                            child: Text(
                              distance == 1
                                  ? '1 day to your next milestone'
                                  : '$distance days to your next milestone',
                              key: const Key('celebrationMilestoneLine'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 16.5,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFFC9CEEA),
                              ),
                            ),
                          ),
                        if (data.freezeUsedNotice != null) ...[
                          const SizedBox(height: 16),
                          Opacity(
                            opacity: _phase(t, 0.90, 0.98),
                            child: Text(
                              data.freezeUsedNotice!,
                              key: const Key('celebrationFreezeNotice'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.4,
                                color: LabBlackColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                        if (data.earnedLandedNotice != null) ...[
                          const SizedBox(height: 12),
                          Opacity(
                            opacity: _phase(t, 0.90, 0.98),
                            child: Text(
                              data.earnedLandedNotice!,
                              key: const Key('celebrationEarnedNotice'),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontSize: 14,
                                height: 1.4,
                                color: LabBlackColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                        // Buttons fade in LAST and are tappable
                        // only once the sequence is done (a tap
                        // before then skips the sequence instead —
                        // the GestureDetector above gets it because
                        // the buttons ignore pointers until done).
                        Opacity(
                          opacity: _phase(t, 0.94, 1.0),
                          child: IgnorePointer(
                            ignoring: !_done,
                            child: _buttons(context, data),
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The flame (grey until ignition, lit from ignition on — its
  /// own subtle flicker then continues), the count (the OLD count
  /// until ignition, rolling UP to the new count at ignition), and
  /// the "day streak" label landing as the settle completes.
  Widget _flameAndCount(StreakCelebrationData data, double t) {
    final eruption = _eruption(t);
    // Squash-and-stretch across the settle window: the flame
    // widens as it squashes vertically, then recovers.
    final squash = t > 0.44 && t < 0.60
        ? math.sin(math.pi * (t - 0.44) / 0.16) * 0.08
        : 0.0;
    return Column(
      children: [
        Transform(
          alignment: Alignment.bottomCenter,
          transform: Matrix4.identity()
            ..scaleByDouble(eruption + squash, eruption - squash, 1, 1),
          child: StreakFlame(lit: t >= _ignitionAt, size: 110),
        ),
        const SizedBox(height: 8),
        _count(data, t),
        Opacity(
          opacity: Curves.easeOut.transform(_phase(t, 0.50, 0.62)),
          child: const Text(
            'day streak',
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: Color(0xFFFF6B4A),
            ),
          ),
        ),
        // Gems — Juno §3: the earn lines sit DIRECTLY UNDER the
        // line that confirms the day counted toward the streak,
        // as part of that same confirmation block (never a toast
        // or banner). Each line renders only when its own grant
        // was server-confirmed for this completion; the gem icon
        // sits beside the base line, as on the Home pill.
        if (data.gemLines.isNotEmpty) ...[
          const SizedBox(height: 14),
          Opacity(
            opacity: _phase(t, 0.90, 0.98),
            child: Column(
              key: const Key('celebrationGemLines'),
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < data.gemLines.length; i++) ...[
                  if (i > 0) const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (i == 0) ...[
                        Image.asset(
                          GemCopy.iconAsset,
                          height: 18,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          data.gemLines[i],
                          key: Key('celebrationGemLine$i'),
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: kGemCountColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// The big count. Before ignition it reads the OLD count; at
  /// ignition the new count rolls UP into place (an upward roll,
  /// not a cut, not a fade); after the roll — and always under
  /// reduced motion — it is the plain settled count text.
  Widget _count(StreakCelebrationData data, double t) {
    const style = TextStyle(
      fontSize: 96,
      fontWeight: FontWeight.w900,
      height: 1.05,
      color: Color(0xFFFF6B4A),
    );
    final settled = Text(
      '${data.count}',
      key: const Key('celebrationCount'),
      style: style,
    );
    if (data.oldCount == data.count || t >= _rollEnd) return settled;
    final roll = Curves.easeOut.transform(_phase(t, _ignitionAt, _rollEnd));
    const lineBox = 96 * 1.05;
    return SizedBox(
      height: lineBox,
      child: ClipRect(
        // The roll stack is two line boxes tall inside a one-line
        // window: OverflowBox lets it exceed the window, ClipRect
        // crops it, and the translate rolls it up.
        child: OverflowBox(
          maxHeight: double.infinity,
          alignment: Alignment.topCenter,
          child: Transform.translate(
            offset: Offset(0, -lineBox * roll),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  height: lineBox,
                  child: Text(
                    '${data.oldCount}',
                    key: const Key('celebrationOldCount'),
                    style: style,
                  ),
                ),
                SizedBox(height: lineBox, child: settled),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The dismissal/share row. NORMAL days: the share icon (real
  /// path only) + the "LET'S GO!" primary. MILESTONE days: the
  /// "SHARE MILESTONE" primary (real path only) + the demoted
  /// "Continue" link, never gated (Juno §6c; copy update §2 keeps
  /// "Continue" verbatim).
  Widget _buttons(BuildContext context, StreakCelebrationData data) {
    if (data.isMilestoneDay) {
      return Column(
        children: [
          // B-APP-1: in the SIM preview the SHARE MILESTONE
          // primary button is suppressed entirely; only the
          // Continue dismissal below remains.
          if (!widget.isSimulation) ...[
            SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton(
                key: const Key('celebrationShareMilestone'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: NotelColors.primary,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: () => _share(),
                child: const Text(
                  'SHARE MILESTONE',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
          ],
          TextButton(
            key: const Key('celebrationContinue'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Continue',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: LabBlackColors.textSecondary,
              ),
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        // B-APP-1: in the SIM preview the share icon button is
        // suppressed entirely; only the LET'S GO! dismissal
        // remains (expanded full width).
        if (!widget.isSimulation) ...[
          SizedBox(
            width: 58,
            height: 58,
            child: OutlinedButton(
              key: const Key('celebrationShareIcon'),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF2A3560), width: 2),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                padding: EdgeInsets.zero,
              ),
              onPressed: () => _share(),
              child: const Icon(
                Icons.ios_share,
                color: NotelColors.primary,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: SizedBox(
            height: 58,
            child: ElevatedButton(
              key: const Key('celebrationYay'),
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                // Founder-dictated (Juno copy update §1): exactly
                // this, no name, on normal days — real and SIM.
                "LET'S GO!",
                style: TextStyle(
                  fontSize: 19,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The week row: the days LOAD IN one by one, left to right —
  /// each pops (fade + overshoot scale) in turn after the count
  /// settles. Freeze days keep the icy-blue snowflake treatment.
  Widget _weekRow(StreakCelebrationData data, double t) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < data.week.length; i++) _weekDay(data.week[i], i, t),
      ],
    );
  }

  Widget _weekDay(
    ({String label, bool counted, bool isToday, bool restored}) day,
    int index,
    double t,
  ) {
    final p = _phase(t, 0.58 + index * 0.045, 0.66 + index * 0.045);
    return Opacity(
      key: Key('celebrationWeekDay_$index'),
      opacity: p,
      child: Transform.scale(
        scale: 0.4 + 0.6 * Curves.easeOutBack.transform(p),
        child: Column(
          children: [
            Text(
              day.label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: day.isToday
                    ? const Color(0xFFFF6B4A)
                    : LabBlackColors.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            // Founder addition (Nov 18, 2026): a freeze-covered
            // day renders with the freeze treatment — icy-blue
            // filled circle + navy snowflake — never a check.
            if (day.restored)
              const StreakFreezeDayCircle(size: 40)
            else
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: day.isToday
                      ? const Color(0xFFFF6B4A)
                      : day.counted
                      ? const Color(0xFF1B2547)
                      : const Color(0xFF131C33),
                ),
                child: day.counted
                    ? Icon(
                        Icons.check,
                        size: 20,
                        color: day.isToday
                            ? Colors.white
                            : const Color(0xFFFF6B4A),
                      )
                    : null,
              ),
          ],
        ),
      ),
    );
  }
}
