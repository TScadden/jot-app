import 'dart:async';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_purchase.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/features/home/streak_flame.dart';
import 'package:tabs_lab/src/features/home/streak_share_card.dart';
import 'package:tabs_lab/src/theme/lab_black_colors.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Streak detail screen (Lab streak package Nov 4, 2026; streak
/// upgrade rebuild Nov 18, 2026 — design SIGNED, STAGE-LOG items
/// 3–8 + Juno copy pass).
///
/// Layout per the signed mocks (gen_mocks.py): hero flame + big
/// count + "day streak!", week row, milestone line, month
/// calendar, Streak Goal card, Streak Freeze card, History. NO
/// bottom action button in either state (founder ruling).
///
/// Copy discipline: EVERY user-facing string is Juno's verbatim
/// (JUNO-COPY.md). The noun is "freeze" everywhere — "Restore" is
/// retired on this surface (§11). The displayed freeze count is
/// TOTAL AVAILABLE COVER (A1), never held-only. All display reads
/// anchor on the Tabs day (A7: `tabsDayAnchor`), never wall-clock
/// `now` directly.
class StreakScreen extends StatefulWidget {
  final StreakState state;
  final DateTime now;

  /// Purchase flow for the freeze card. Tests inject a fake;
  /// production (Home) passes a real service or leaves null, in
  /// which case the screen creates one against Play + the backend.
  final StreakFreezePurchaseService? purchaseService;

  const StreakScreen({
    super.key,
    required this.state,
    required this.now,
    this.purchaseService,
  });

  /// Push the streak screen with an already-settled [state].
  ///
  /// VC 100115 anti-fabrication rule: this NEVER evaluates the
  /// engine itself. Callers (Home) settle the engine against the
  /// server profile first and only open the screen with a seeded
  /// state; an unseeded state is never displayed.
  static Future<void> openWith(
    BuildContext context, {
    required StreakState state,
    StreakFreezePurchaseService? purchaseService,
  }) async {
    if (!context.mounted) return;
    await Navigator.of(context).push(
      SlidePageRoute<void>(
        builder: (_) => StreakScreen(
          state: state,
          now: DateTime.now(),
          purchaseService: purchaseService,
        ),
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

  @override
  State<StreakScreen> createState() => _StreakScreenState();
}

class _StreakScreenState extends State<StreakScreen> {
  StreakFreezePurchaseService? _purchase;
  bool _ownsPurchase = false;

  /// The purchased-freeze count adopted from a successful verify
  /// this session (Juno §5b: counts read AFTER adoption). The
  /// server column + next settle remain the durable record; this
  /// override only makes the just-granted freeze visible now.
  int? _adoptedPurchased;

  final GlobalKey _cardKey = GlobalKey();

  StreakState get state => widget.state;
  DateTime get now => widget.now;
  DateTime get _anchor => tabsDayAnchor(now);

  @override
  void initState() {
    super.initState();
    _purchase = widget.purchaseService;
    if (_purchase == null) {
      _ownsPurchase = true;
      _purchase = StreakFreezePurchaseService(
        onAdopted: (count) {
          // Streak-bugs fix: the grant also lands in the streak
          // store, so every surface reading the settled state
          // (Home, widget, a reopened streak screen) sees the held
          // freeze immediately — not just this screen's override.
          unawaited(StreakStore.instance.adoptPurchasedFreezes(count));
          if (mounted) setState(() => _adoptedPurchased = count);
        },
        formatSuccess: (count) {
          final s = _effectiveState();
          final available = totalAvailableCover(s, now);
          final max = streakCap(s);
          return "You've got an extra freeze. You now have $available of $max freezes available.";
        },
      );
    }
    _purchase!.addListener(_onPurchaseChanged);
    unawaited(_initPurchase());
  }

  Future<void> _initPurchase() async {
    try {
      await _purchase!.initialize();
    } catch (_) {
      // The buy row renders its unavailable state; the rest of the
      // screen is unaffected.
    }
  }

  void _onPurchaseChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _purchase?.removeListener(_onPurchaseChanged);
    if (_ownsPurchase) _purchase?.dispose();
    super.dispose();
  }

  /// The state the freeze card reads: the settled state with any
  /// just-adopted purchased count applied.
  StreakState _effectiveState() {
    final adopted = _adoptedPurchased ?? _purchase?.adoptedPurchasedFreezes;
    if (adopted == null || adopted == state.purchasedFreezes) return state;
    return state.copyWith(purchasedFreezes: adopted.clamp(0, 1));
  }

  String _rangeLabel(({String start, String end}) range) {
    final a = DateTime.parse(range.start);
    final b = DateTime.parse(range.end);
    if (a.year == b.year && a.month == b.month) {
      return '${StreakScreen._monthAbbr[a.month - 1]} ${a.day}–${b.day}';
    }
    if (a.year == b.year) {
      return '${StreakScreen._monthAbbr[a.month - 1]} ${a.day}–'
          '${StreakScreen._monthAbbr[b.month - 1]} ${b.day}';
    }
    return '${StreakScreen._monthAbbr[a.month - 1]} ${a.day}, ${a.year}–'
        '${StreakScreen._monthAbbr[b.month - 1]} ${b.day}, ${b.year}';
  }

  String _days(int n) => n == 1 ? '1 day' : '$n days';
  String _streakDays(int n) => n == 1 ? '1 streak day' : '$n streak days';

  @override
  Widget build(BuildContext context) {
    final current = streakCurrent(state, _anchor);
    final best = streakBest(state);
    final range = streakBestRange(state);
    final todayStr = tabsDayStr(now);
    final todayDone = state.countedDays.contains(todayStr);
    final monthCount =
        streakCountedDaysInMonth(state, _anchor.year, _anchor.month);

    return Scaffold(
      backgroundColor: LabBlackColors.background,
      body: Stack(
        children: [
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
                          const Color(0xFFF26B1D).withValues(alpha: 0.55),
                          const Color(0xFFF26B1D).withValues(alpha: 0),
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
                          const Color(0xFF2E6BFF).withValues(alpha: 0.55),
                          const Color(0xFF2E6BFF).withValues(alpha: 0),
                        ],
                      ),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ],
              ),
            ),
          ),
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
                      LabBlackColors.background.withValues(alpha: 0.05),
                      LabBlackColors.background.withValues(alpha: 0.55),
                      LabBlackColors.background,
                    ],
                    stops: const [0.0, 0.62, 1.0],
                  ),
                ),
              ),
            ),
          ),
          StreakShareCardHost(boundaryKey: _cardKey, count: current),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                _header(context, current),
                const SizedBox(height: 16),
                _hero(current, best, todayDone),
                const SizedBox(height: 20),
                _weekRow(todayStr),
                const SizedBox(height: 16),
                _milestoneLine(current),
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
                          color: LabBlackColors.hairline,
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
                _goalCard(),
                const SizedBox(height: 16),
                _freezeCard(),
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

  Widget _header(BuildContext context, int current) {
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
              color: LabBlackColors.textPrimary,
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
                        color: LabBlackColors.card,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.chevron_left,
                        size: 22,
                        color: LabBlackColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: const Key('streakShareButton'),
              tooltip: 'Share',
              icon: const Icon(
                Icons.ios_share,
                size: 22,
                color: LabBlackColors.textSecondary,
              ),
              onPressed: () => unawaited(
                StreakShareService.shareFromBoundary(
                  _cardKey,
                  count: current,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hero(int current, int best, bool todayDone) {
    final heroColor =
        todayDone ? const Color(0xFFFF6A3D) : const Color(0xFF8E97B8);
    return Column(
      children: [
        StreakFlame(lit: todayDone, size: 84),
        const SizedBox(height: 6),
        Semantics(
          container: true,
          label: '$current day streak',
          child: ExcludeSemantics(
            child: Column(
              children: [
                Text(
                  '$current',
                  key: const Key('streakHeroNumber'),
                  style: TextStyle(
                    fontSize: 86,
                    fontWeight: FontWeight.w900,
                    height: 1.0,
                    color: heroColor,
                  ),
                ),
                Text(
                  'day streak!',
                  style: TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w900,
                    color: heroColor,
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
            color: LabBlackColors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _weekRow(String todayStr) {
    final todayDate = DateTime.parse(todayStr);
    final monday = todayDate.subtract(Duration(days: todayDate.weekday - 1));
    const labels = ['Mo', 'Tu', 'We', 'Th', 'Fr', 'Sa', 'Su'];
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < 7; i++)
          _weekDay(
            labels[i],
            monday.add(Duration(days: i)),
            todayStr,
          ),
      ],
    );
  }

  Widget _weekDay(String label, DateTime day, String todayStr) {
    final ds = streakDayStr(day);
    final counted = state.countedDays.contains(ds);
    // Founder addition (Nov 18, 2026): a freeze-covered day
    // renders with the freeze treatment on every rebuilt surface
    // — checked BEFORE counted (restored days are a subset of
    // counted days) so it never shows as a plain check.
    final restored = state.restoredDays.contains(ds);
    final isToday = ds == todayStr;
    final Color bg;
    final Widget? child;
    if (isToday && counted) {
      bg = const Color(0xFFFF6A3D);
      child = const Icon(Icons.check, size: 19, color: Colors.white);
    } else if (counted) {
      bg = NotelColors.primary;
      child = const Icon(Icons.check, size: 19, color: Colors.white);
    } else if (isToday) {
      bg = const Color(0xFF131C33);
      child = null;
    } else {
      bg = const Color(0xFF1A2338);
      child = null;
    }
    return SizedBox(
      width: 44,
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: isToday
                  ? const Color(0xFFFF7A59)
                  : LabBlackColors.textSecondary,
            ),
          ),
          const SizedBox(height: 7),
          if (restored)
            const StreakFreezeDayCircle(size: 42)
          else
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: bg,
                border: isToday && !counted
                    ? Border.all(
                        color: const Color(0xFF4A5470),
                        width: 2,
                      )
                    : null,
              ),
              child: child,
            ),
        ],
      ),
    );
  }

  /// Juno §2 — distance form, never a prediction. Suppressed when
  /// the distance would be 0 (nextMilestone is strictly greater,
  /// so this is a belt-and-braces guard only).
  Widget _milestoneLine(int current) {
    final distance = nextMilestone(current) - current;
    if (distance <= 0) return const SizedBox.shrink();
    return Text(
      distance == 1
          ? '1 day to your next milestone'
          : '$distance days to your next milestone',
      key: const Key('streakMilestoneLine'),
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontSize: 16.5,
        fontWeight: FontWeight.w700,
        color: Color(0xFFAAB3D0),
      ),
    );
  }

  /// Streak Goal card — Juno §3a (normal + spoiled variants), §3b
  /// progress (hidden when spoiled; pinned full for the completed
  /// month when pending), §3c pause texts (pending vs not-pending).
  Widget _goalCard() {
    final monthName = StreakScreen._monthNames[_anchor.month - 1];
    final nextMonth = DateTime(_anchor.year, _anchor.month + 1, 1);
    final nextMonthName = StreakScreen._monthNames[nextMonth.month - 1];
    final monthKey = streakMonthKey(_anchor);
    final spoiled = state.spoiledMonths.contains(monthKey) ||
        state.consumedSaveMonths.contains(monthKey);
    final pending = state.earnedPending;

    final int progressN;
    final int progressDenom;
    final String progressMonth;
    if (pending) {
      // §3b pending: the COMPLETED month's day count, pinned full.
      final completed = DateTime(_anchor.year, _anchor.month, 0);
      progressN = completed.day;
      progressDenom = completed.day;
      progressMonth = StreakScreen._monthNames[completed.month - 1];
    } else {
      progressN = _anchor.day;
      progressDenom = DateTime(_anchor.year, _anchor.month + 1, 0).day;
      progressMonth = monthName;
    }

    return _sectionCard(
      label: 'Streak Goal',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            spoiled
                ? "A freeze was used in $monthName, so there's no extra freeze to earn this month. Your next chance starts in $nextMonthName."
                : "Finish $monthName without using a freeze, and you'll earn an extra freeze — on top of your free monthly freeze.",
            key: const Key('streakGoalCopy'),
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              height: 1.45,
              color: Color(0xFFAAB3D0),
            ),
          ),
          if (!spoiled) ...[
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: progressDenom == 0 ? 0 : progressN / progressDenom,
                minHeight: 16,
                backgroundColor: const Color(0xFF1A2338),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  NotelColors.primary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '$progressN / $progressDenom DAYS freeze-free in $progressMonth',
              key: const Key('streakGoalProgress'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w800,
                color: Color(0xFFAAB3D0),
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            pending
                ? "Your earned freeze is ready and waiting. It lands as soon as there's room for it: you aren't already holding an earned freeze, and your total freezes are under your max (2, or 3 while you hold a purchased freeze)."
                : "If you finish $monthName with no freezes used, you earn one extra freeze. If you're at your max when it comes due, it waits — pending — until there's room for it. Max 2 freezes, or 3 while you hold a purchased freeze.",
            key: const Key('streakGoalPauseCopy'),
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              height: 1.4,
              color: Color(0xFF59637F),
            ),
          ),
        ],
      ),
    );
  }

  /// Streak Freeze card — Juno §4a ready/used variants (displayed
  /// count = total available cover / cap), §4b buy button (price
  /// from the Play listing; hidden while a purchased freeze is
  /// held), §4c buy note, §5a unavailable, §5b/§5c outcomes.
  Widget _freezeCard() {
    final effective = _effectiveState();
    final monthName = StreakScreen._monthNames[_anchor.month - 1];
    final monthlyUsed =
        effective.consumedSaveMonths.contains(streakMonthKey(_anchor));
    final available = totalAvailableCover(effective, now);
    final max = streakCap(effective);
    final purchase = _purchase;
    final heldPurchased = effective.purchasedFreezes > 0;

    return _sectionCard(
      label: 'Streak Freeze',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF12314F),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(
                  Icons.ac_unit,
                  size: 32,
                  color: Color(0xFF6EC6FF),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  monthlyUsed
                      ? 'Your free monthly freeze for $monthName has been used. You have $available of $max freezes available. A freeze can cover one missed day automatically when you have one available.'
                      : 'Your free monthly freeze is ready for $monthName. You have $available of $max freezes available. A freeze can cover one missed day automatically when you have one available.',
                  key: const Key('streakFreezeStatus'),
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.45,
                    color: Color(0xFFAAB3D0),
                  ),
                ),
              ),
            ],
          ),
          if (purchase?.successMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              purchase!.successMessage!,
              key: const Key('streakPurchaseSuccess'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: LabBlackColors.textPrimary,
              ),
            ),
          ],
          if (purchase?.failureMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              purchase!.failureMessage!,
              key: const Key('streakPurchaseFailure'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: LabBlackColors.textSecondary,
              ),
            ),
          ],
          // Streak-bugs fix — recovery feedback surfaces (copy is
          // Juno-placeholder, ruled in StreakPurchaseCopy): a paid
          // purchase still being confirmed, and a restored
          // purchase that landed, are both VISIBLE here instead of
          // the founder's silent no-feedback purchase.
          if (purchase?.pendingMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              purchase!.pendingMessage!,
              key: const Key('streakPurchasePending'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: LabBlackColors.textSecondary,
              ),
            ),
          ],
          if (purchase?.restoredMessage != null) ...[
            const SizedBox(height: 12),
            Text(
              purchase!.restoredMessage!,
              key: const Key('streakPurchaseRestored'),
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: LabBlackColors.textPrimary,
              ),
            ),
          ],
          if (!heldPurchased && purchase != null) ...[
            const SizedBox(height: 12),
            if (purchase.state == StreakFreezeBuyState.unavailable) ...[
              const Text(
                'EXTRA FREEZE — NOT AVAILABLE RIGHT NOW',
                key: Key('streakBuyUnavailable'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF59637F),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "We can't reach Google Play right now, so extra freezes can't be bought at the moment. Try again later.",
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF59637F),
                ),
              ),
            ] else if (purchase.product != null) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  key: const Key('streakBuyButton'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: NotelColors.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: purchase.state == StreakFreezeBuyState.buying
                      ? null
                      : () => unawaited(purchase.buy()),
                  child: Text(
                    'GET ONE MORE FREEZE · ${purchase.product!.price}',
                    style: const TextStyle(
                      fontSize: 16.5,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "Not a subscription — you pay once for this freeze. While you hold it, your max is 3. Once it's used, your max goes back to 2.",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF59637F),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _sectionCard({required String label, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: LabBlackColors.card,
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
              color: LabBlackColors.textSecondary,
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
        color: LabBlackColors.nested,
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
                    color: LabBlackColors.textPrimary,
                  ),
                ),
                if (subCaption != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subCaption,
                    style: const TextStyle(
                      fontSize: 13,
                      color: LabBlackColors.textSecondary,
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
              color: LabBlackColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _historyCalendar(int monthCount) {
    final year = _anchor.year;
    final month = _anchor.month;
    final first = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final leadBlanks = first.weekday % 7;
    final cells = <DateTime?>[
      for (var i = 0; i < leadBlanks; i++) null,
      for (var d = 1; d <= daysInMonth; d++) DateTime(year, month, d),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    final todayStr = tabsDayStr(now);
    final hasRestoredThisMonth = state.restoredDays.any(
      (d) => d.startsWith(streakMonthKey(_anchor)),
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
                  StreakScreen._monthNames[month - 1],
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: LabBlackColors.textPrimary,
                  ),
                ),
              ),
              Text(
                _streakDays(monthCount),
                style: const TextStyle(
                  fontSize: 13,
                  color: LabBlackColors.textSecondary,
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
                      color: LabBlackColors.textSecondary,
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
            // Juno §11: the verb is "covered" — "restored" is
            // retired from user-facing copy with "Restore". The
            // marker named here is the founder's freeze treatment
            // (Nov 18, 2026): the purple-ring wording retired
            // with the purple-ring rendering.
            'A day with a snowflake was covered by a freeze.',
            style: TextStyle(
              fontSize: 12,
              color: LabBlackColors.textSecondary,
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

    // Founder addition (Nov 18, 2026): a freeze-covered day is
    // the icy-blue snowflake circle — the legacy purple-ring
    // Restore treatment is retired on this surface. The date
    // stays identifiable without color via the semantics label
    // wrapped below (Juno C6).
    if (restored) {
      final cell = SizedBox(
        height: 40,
        child: Center(
          child: StreakFreezeDayCircle(
            key: Key('streakRestoredDay-$ds'),
            size: 32,
          ),
        ),
      );
      return Semantics(
        container: true,
        label:
            '${StreakScreen._monthNames[day.month - 1]} ${day.day}, covered by a freeze',
        child: ExcludeSemantics(child: cell),
      );
    }

    BoxDecoration decoration;
    Color numberColor;
    FontWeight numberWeight = FontWeight.w500;
    if (counted) {
      decoration = const BoxDecoration(
        shape: BoxShape.circle,
        color: LabBlackColors.segmentedSelected,
      );
      numberColor =
          isToday ? NotelColors.primaryText : LabBlackColors.textPrimary;
      numberWeight = isToday ? FontWeight.w800 : FontWeight.w600;
    } else {
      decoration = const BoxDecoration(shape: BoxShape.circle);
      numberColor = LabBlackColors.textSecondary.withValues(alpha: 0.55);
    }

    return SizedBox(
      height: 40,
      child: Center(
        child: Container(
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
  }
}
