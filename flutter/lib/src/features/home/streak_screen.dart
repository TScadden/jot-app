import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Streak detail screen (Lab streak package Nov 4, 2026, ported to
/// the release line in VC 100115) — built in the reference video's
/// form (tiktok-ui-lab STREAK_SPEC.md; frame f_011) and skinned in
/// the PRODUCTION NotelColors tokens:
///
/// - Aurora wash bleeding from the top edge (violet → purple →
///   blue fields in the production palette) behind the header
///   and hero.
/// - Circular back button top-left, centered title "Streak".
/// - Hero card: pale flame glyph, 64sp extra-bold numeral with
///   "day streak" on its baseline, "Best N days" caption.
/// - Section cards with their labels INSIDE the card top —
///   "Streaks" (Current / Longest rows in a darker nested card),
///   "Restore" (the monthly save: status row + explainer caption),
///   "History" (current-month calendar in a nested card; counted
///   days filled, restored days ringed in Tabs purple, today
///   ringed).
///
/// All copy is Juno-signed (JUNO_REVIEW_STREAK.md, carried verbatim
/// from the Lab package; re-signed for the release line in the
/// VC 100115 Juno pass). Data is the authoritative streak record:
/// the engine state settled against the server profile on app
/// open (see streak_store.dart).
class StreakScreen extends StatelessWidget {
  final StreakState state;
  final DateTime now;

  const StreakScreen({super.key, required this.state, required this.now});

  /// Push the streak screen with an already-settled [state].
  ///
  /// VC 100115 anti-fabrication rule: this NEVER evaluates the
  /// engine itself. The Lab build's defensive "one evaluation with
  /// no seed" minted a fresh 1-day run on any device whose settle
  /// had not landed yet — on a device whose server streak was 14
  /// the screen showed 1. Callers (Home) settle the engine against
  /// the server profile first and only open the screen with a
  /// seeded state; an unseeded state is never displayed.
  static Future<void> openWith(
    BuildContext context, {
    required StreakState state,
  }) async {
    if (!context.mounted) return;
    await Navigator.of(context).push(
      SlidePageRoute<void>(
        builder: (_) => StreakScreen(state: state, now: DateTime.now()),
      ),
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
  static const _monthAbbr = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  String _rangeLabel(({String start, String end}) range) {
    final a = DateTime.parse(range.start);
    final b = DateTime.parse(range.end);
    if (a.year == b.year && a.month == b.month) {
      return '${_monthAbbr[a.month - 1]} ${a.day}–${b.day}';
    }
    if (a.year == b.year) {
      // Juno C8 correction (Nov 5, 2026): tight en dash in every
      // range form, matching the signed "Sep 1–8" — "Sep 28–Oct 5".
      return '${_monthAbbr[a.month - 1]} ${a.day}–'
          '${_monthAbbr[b.month - 1]} ${b.day}';
    }
    // Cross-year signed form: "Dec 28, 2025–Jan 4, 2026".
    return '${_monthAbbr[a.month - 1]} ${a.day}, ${a.year}–'
        '${_monthAbbr[b.month - 1]} ${b.day}, ${b.year}';
  }

  String _days(int n) => n == 1 ? '1 day' : '$n days';

  /// Juno-signed (string 11): the History month count is streak
  /// days, never bare days.
  String _streakDays(int n) => n == 1 ? '1 streak day' : '$n streak days';

  @override
  Widget build(BuildContext context) {
    final current = streakCurrent(state, now);
    final best = streakBest(state);
    final range = streakBestRange(state);
    final savesLeft = streakSavesLeft(state, now);
    final monthCount = streakCountedDaysInMonth(state, now.year, now.month);

    return Scaffold(
      backgroundColor: NotelColors.background,
      body: Stack(
        children: [
          // Aurora wash (f_011): ember → violet → blue bleeding
          // from the top edge. Painted as three radial gradients —
          // soft-edged color fields that read as a blurred glow
          // with NO blur filter (a full-width high-sigma blur layer
          // is prohibitively slow in the software renderer and a
          // needless battery cost on device).
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 300,
            child: IgnorePointer(
              child: Stack(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(-0.95, -1.0),
                        radius: 1.15,
                        colors: [
                          NotelColors.chipPurple.withValues(alpha: 0.55),
                          NotelColors.chipPurple.withValues(alpha: 0),
                        ],
                      ),
                    ),
                    child: const SizedBox.expand(),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0, -1.0),
                        radius: 1.15,
                        colors: [
                          NotelColors.primary.withValues(alpha: 0.55),
                          NotelColors.primary.withValues(alpha: 0),
                        ],
                      ),
                    ),
                    child: const SizedBox.expand(),
                  ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: const Alignment(0.95, -1.0),
                        radius: 1.15,
                        colors: [
                          NotelColors.info.withValues(alpha: 0.55),
                          NotelColors.info.withValues(alpha: 0),
                        ],
                      ),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ],
              ),
            ),
          ),
          // Fade the wash into the page background toward the hero's
          // foot, as in the frame.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: 300,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      NotelColors.background.withValues(alpha: 0.05),
                      NotelColors.background.withValues(alpha: 0.55),
                      NotelColors.background,
                    ],
                    stops: const [0.0, 0.62, 1.0],
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _header(context),
                const SizedBox(height: 16),
                _heroCard(current, best),
                const SizedBox(height: 16),
                _sectionCard(
                  label: 'Streaks',
                  child: _nested(
                    child: Column(
                      children: [
                        _statRow('Current Streak', _days(current)),
                        const Divider(
                          height: 1,
                          thickness: 1,
                          color: NotelColors.legacyDarkHairline,
                        ),
                        _statRow(
                          'Longest Streak',
                          _days(best),
                          subCaption:
                              range == null ? null : _rangeLabel(range),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _sectionCard(
                  label: 'Restore',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _nested(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.autorenew,
                                size: 20,
                                color: NotelColors.textPrimary,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  savesLeft == 1
                                      ? '1 restore left this month'
                                      : 'No restores left this month',
                                  key: const Key('streakRestoreStatus'),
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: NotelColors.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        // Juno-signed verbatim (JUNO_REVIEW_STREAK.md
                        // §4, string 9).
                        'One restore a month. Streaks count days you '
                        'open Tabs. If you miss a day, your restore is '
                        'used automatically and that day counts toward '
                        'your streak. It does not add steps or other '
                        'health data for that day.',
                        style: TextStyle(
                          fontSize: 14,
                          height: 1.35,
                          color: NotelColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _sectionCard(
                  label: 'History',
                  child: _nested(
                    child: _historyCalendar(monthCount),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return SizedBox(
      height: 48,
      child: Stack(
        alignment: Alignment.center,
        children: [
          const Text(
            'Streak',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: NotelColors.textPrimary,
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: 'Back',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => Navigator.of(context).pop(),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: const BoxDecoration(
                        color: NotelColors.surface,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chevron_left,
                        size: 22,
                        color: NotelColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _heroCard(int current, int best) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      child: Column(
        children: [
          const Icon(
            Icons.local_fire_department,
            size: 46,
            color: NotelColors.textPrimary,
          ),
          const SizedBox(height: 10),
          // Juno C6: numeral + unit are exposed to assistive
          // technology as ONE value ("8 day streak").
          Semantics(
            container: true,
            label: '$current day streak',
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$current',
                    key: const Key('streakHeroNumber'),
                    style: const TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.w800,
                      height: 1.0,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'day streak',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                      color: NotelColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            best == 1 ? 'Best 1 day' : 'Best $best days',
            style: const TextStyle(
              fontSize: 14,
              color: NotelColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({required String label, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: NotelColors.textSecondary,
            ),
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }

  Widget _nested({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: NotelColors.background,
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: child,
    );
  }

  Widget _statRow(String label, String value, {String? subCaption}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: NotelColors.textPrimary,
                  ),
                ),
                if (subCaption != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subCaption,
                    style: const TextStyle(
                      fontSize: 13,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: NotelColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyCalendar(int monthCount) {
    final year = now.year;
    final month = now.month;
    final first = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    // Sunday-first grid, as in the frame (S M T W T F S).
    final leadBlanks = first.weekday % 7;
    final cells = <DateTime?>[
      for (var i = 0; i < leadBlanks; i++) null,
      for (var d = 1; d <= daysInMonth; d++) DateTime(year, month, d),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    final todayStr = streakDayStr(now);
    final hasRestoredThisMonth = state.restoredDays.any(
      (d) => d.startsWith(streakMonthKey(now)),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  _monthNames[month - 1],
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: NotelColors.textPrimary,
                  ),
                ),
              ),
              Text(
                _streakDays(monthCount),
                style: const TextStyle(
                  fontSize: 13,
                  color: NotelColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            for (final w in const ['S', 'M', 'T', 'W', 'T', 'F', 'S'])
              Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        for (var r = 0; r < cells.length ~/ 7; r++)
          Row(
            children: [
              for (var c = 0; c < 7; c++)
                Expanded(child: _dayCell(cells[r * 7 + c], todayStr)),
            ],
          ),
        if (hasRestoredThisMonth) ...[
          const SizedBox(height: 10),
          const Text(
            // Juno-signed verbatim (string 12).
            'A day with a purple ring was restored.',
            style: TextStyle(
              fontSize: 12,
              color: NotelColors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }

  Widget _dayCell(DateTime? day, String todayStr) {
    if (day == null) return const SizedBox(height: 40);
    final ds = streakDayStr(day);
    final counted = state.countedDays.contains(ds);
    final restored = state.restoredDays.contains(ds);
    final isToday = ds == todayStr;

    BoxDecoration decoration;
    Color numberColor;
    FontWeight numberWeight = FontWeight.w500;
    if (restored) {
      // A restored day is visibly marked with a purple RING (the
      // Juno-signed legend's own words, string 12) — a form cue,
      // not color alone; its semantics label also states it (C6).
      decoration = BoxDecoration(
        shape: BoxShape.circle,
        color: NotelColors.surfaceHigh,
        border: Border.all(color: NotelColors.primary, width: 2),
      );
      numberColor = NotelColors.textPrimary;
      numberWeight = FontWeight.w700;
    } else if (counted) {
      decoration = const BoxDecoration(
        shape: BoxShape.circle,
        color: NotelColors.surfaceHigh,
      );
      // Today reads by its numeral color (the ring is reserved for
      // restored days so the two marks can never be confused).
      numberColor =
          isToday ? NotelColors.primaryText : NotelColors.textPrimary;
      numberWeight = isToday ? FontWeight.w800 : FontWeight.w600;
    } else {
      decoration = const BoxDecoration(shape: BoxShape.circle);
      numberColor = NotelColors.textSecondary.withValues(alpha: 0.55);
    }

    final cell = SizedBox(
      height: 40,
      child: Center(
        child: Container(
          key: restored ? Key('streakRestoredDay-$ds') : null,
          width: 32,
          height: 32,
          decoration: decoration,
          child: Center(
            child: Text(
              '${day.day}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: numberWeight,
                color: numberColor,
              ),
            ),
          ),
        ),
      ),
    );
    if (!restored) return cell;
    // Juno C6: a restored day is identifiable without color alone.
    return Semantics(
      container: true,
      label: '${_monthNames[day.month - 1]} ${day.day}, restored',
      child: ExcludeSemantics(child: cell),
    );
  }
}
