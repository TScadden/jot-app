import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/features/home/streak_flame.dart';
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

  /// The week row: the Tabs days of the current week (Mon-first)
  /// with their counted state; today is the last counted day.
  /// [restored] marks a freeze-covered day (a subset of counted)
  /// — it renders with the freeze treatment, never a check.
  final List<({String label, bool counted, bool isToday, bool restored})>
      week;

  /// True when [count] is exactly a milestone ladder rung.
  final bool isMilestoneDay;

  /// Juno §5e freeze-used notice, when this completion's
  /// settlement bridged missed days; otherwise null.
  final String? freezeUsedNotice;

  /// Juno §5d earned-landed notice, when an earned freeze landed
  /// during this completion; otherwise null.
  final String? earnedLandedNotice;

  const StreakCelebrationData({
    required this.count,
    required this.week,
    required this.isMilestoneDay,
    this.freezeUsedNotice,
    this.earnedLandedNotice,
  });

  /// Builds the display state from a settled completion: the count
  /// is the completion's settled count, the week is derived from
  /// the settled state's counted days, and the notices follow
  /// Juno §5d/§5e verbatim (counts read AFTER the settlement).
  factory StreakCelebrationData.fromCompletion({
    required StreakCompletionResult result,
    required StreakState state,
    required DateTime now,
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
      week: week,
      isMilestoneDay: result.isMilestone,
      freezeUsedNotice: freezeNotice,
      earnedLandedNotice: result.earnedLanded
          ? 'Your earned freeze is here. You now have $available of $max freezes available.'
          : null,
    );
  }

  static const _monthNames = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];
}

/// The first name for Juno §6a: the first whitespace-delimited
/// token of the Settings nickname, exactly as typed. Null when the
/// nickname is unset, blank, or whitespace-only (the button then
/// reads exactly "YAY!"). No other name source is ever substituted.
String? streakFirstName(String? nickname) {
  if (nickname == null) return null;
  final trimmed = nickname.trim();
  if (trimmed.isEmpty) return null;
  return trimmed.split(RegExp(r'\s+')).first;
}

/// The celebration screen (streak upgrade deliverable 2).
///
/// Fired ONCE per completion by the data layer's completion event
/// (the watcher's fired marker governs). Hero flame lit + flicker,
/// the big NEW settled count, "day streak", the week row with
/// today checked, and the milestone line — Juno §2's distance form
/// on normal days, Juno §7's line on milestone days.
///
/// Buttons: NORMAL days — a share icon button + "YAY, {FIRSTNAME}"
/// ("YAY!" when unset), which dismisses. MILESTONE days — the
/// primary button is "SHARE MILESTONE" (Juno §6b) and "Continue"
/// is a demoted text link, visible and tappable WITHOUT sharing
/// first (Juno §6c — never gated). Both share actions hand the
/// generated card PNG to the system share sheet.
class StreakCelebrationScreen extends StatefulWidget {
  final StreakCelebrationData data;
  final String? nickname;

  /// Test seam: replaces the share-sheet invocation.
  final Future<bool> Function(GlobalKey boundaryKey, int count)? shareFn;

  const StreakCelebrationScreen({
    super.key,
    required this.data,
    this.nickname,
    this.shareFn,
  });

  static Future<void> show(
    BuildContext context, {
    required StreakCelebrationData data,
    String? nickname,
  }) async {
    if (!context.mounted) return;
    await Navigator.of(context).push(
      SlidePageRoute<void>(
        builder: (_) =>
            StreakCelebrationScreen(data: data, nickname: nickname),
      ),
    );
  }

  @override
  State<StreakCelebrationScreen> createState() =>
      _StreakCelebrationScreenState();
}

class _StreakCelebrationScreenState extends State<StreakCelebrationScreen> {
  final GlobalKey _cardKey = GlobalKey();
  bool _sharing = false;

  Future<void> _share() async {
    if (_sharing) return;
    _sharing = true;
    try {
      final share = widget.shareFn ??
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

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final firstName = streakFirstName(widget.nickname);
    final next = nextMilestone(data.count);
    final distance = next - data.count;
    return Scaffold(
      backgroundColor: LabBlackColors.background,
      body: Stack(
        children: [
          StreakShareCardHost(boundaryKey: _cardKey, count: data.count),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(22, 60, 22, 26),
              child: Column(
                children: [
                  const StreakFlame(lit: true, size: 110),
                  const SizedBox(height: 8),
                  Text(
                    '${data.count}',
                    key: const Key('celebrationCount'),
                    style: const TextStyle(
                      fontSize: 96,
                      fontWeight: FontWeight.w900,
                      height: 1.05,
                      color: Color(0xFFFF6B4A),
                    ),
                  ),
                  const Text(
                    'day streak',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFFF6B4A),
                    ),
                  ),
                  const SizedBox(height: 40),
                  _weekRow(data),
                  const SizedBox(height: 16),
                  if (data.isMilestoneDay)
                    Text(
                      'You reached a milestone today: ${data.count} days.',
                      key: const Key('celebrationMilestoneLine'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 16.5,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFC9CEEA),
                      ),
                    )
                  else if (distance > 0)
                    Text(
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
                  if (data.freezeUsedNotice != null) ...[
                    const SizedBox(height: 16),
                    Text(
                      data.freezeUsedNotice!,
                      key: const Key('celebrationFreezeNotice'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: LabBlackColors.textSecondary,
                      ),
                    ),
                  ],
                  if (data.earnedLandedNotice != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      data.earnedLandedNotice!,
                      key: const Key('celebrationEarnedNotice'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: LabBlackColors.textSecondary,
                      ),
                    ),
                  ],
                  const Spacer(),
                  if (data.isMilestoneDay) ...[
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
                  ] else
                    Row(
                      children: [
                        SizedBox(
                          width: 58,
                          height: 58,
                          child: OutlinedButton(
                            key: const Key('celebrationShareIcon'),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(
                                color: Color(0xFF2A3560),
                                width: 2,
                              ),
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
                              child: Text(
                                // Juno §6a: the first word EXACTLY as
                                // the user typed it — no case change.
                                firstName == null
                                    ? 'YAY!'
                                    : 'YAY, $firstName',
                                style: const TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _weekRow(StreakCelebrationData data) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (final day in data.week)
          Column(
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
      ],
    );
  }
}
