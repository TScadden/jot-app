import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/streak_purchase.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/home/streak_flame.dart';
import 'package:tabs_lab/src/features/home/streak_share_card.dart';
import 'package:tabs_lab/src/theme/animations.dart';
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

  /// Gems service for the buy-with-gems section. Tests inject a
  /// fake; production leaves null and the screen uses the shared
  /// [GemService.instance] (the same balance source as Home).
  final GemService? gemService;

  /// The account nickname, forwarded to the widget payload when a
  /// gem spend refreshes it. Optional; null omits the name slot.
  final String? nickname;

  /// The settled-record push used before a gem spend (Vera §3
  /// blob-before-spend discipline). Tests inject a no-op; null
  /// uses the real profile push through the backend.
  final StreakSyncPush? streakPush;

  const StreakScreen({
    super.key,
    required this.state,
    required this.now,
    this.purchaseService,
    this.gemService,
    this.nickname,
    this.streakPush,
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
    GemService? gemService,
    String? nickname,
  }) async {
    if (!context.mounted) return;
    await Navigator.of(context).push(
      SlidePageRoute<void>(
        builder: (_) => StreakScreen(
          state: state,
          now: DateTime.now(),
          purchaseService: purchaseService,
          gemService: gemService,
          nickname: nickname,
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

  /// The gems service (injected or the shared instance — never
  /// owned/disposed here).
  late final GemService _gems;

  /// True while a gem spend request is in flight.
  bool _gemSpendBusy = false;

  /// Juno §2c surface: the post-spend SERVER balance from the
  /// verified gem spend this session; null until one lands. The
  /// success copy renders only while this is set — never on a tap.
  int? _gemSuccessBalance;

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
        // A2 copy fix (Vera blocker): NO formatSuccess here. The
        // pre-existing §5b count formatter made the screen's
        // confirmation the §5b string and Juno §1a a dead fallback
        // (and on recovery §1a rendered IN ADDITION to §5b — two
        // stacked confirmations). Juno §1a is now the ONE visible
        // confirmation for a verified grant; the freeze counts
        // still render in the card's §4a status line above it.
      );
    }
    _purchase!.addListener(_onPurchaseChanged);
    unawaited(_initPurchase());
    _gems = widget.gemService ?? GemService.instance;
    _gems.addListener(_onGemsChanged);
    // The buy surface reads the SAME server balance as the Home
    // pill: refresh it from the profile pull on entry.
    unawaited(_gems.refreshBalance());
  }

  void _onGemsChanged() {
    if (mounted) setState(() {});
  }

  /// One gem spend (Juno §2): a unique spendId per tap intent is
  /// generated inside the service. Success/replay adopts the
  /// server freeze count into the streak store (every surface —
  /// this screen, Home, the widget — then reads the held freeze)
  /// and shows §2c ONLY on the verified spend. The three 409s
  /// refresh state from the server body (balance + freeze count
  /// ride along) and fall into the ruled surface state — held/cap
  /// hides the buy rows, insufficient shows §2d — with no raw
  /// error code and no dead end.
  /// Push the settled streak record before a gem spend (Vera
  /// §3 guidance, Nov 19, 2026): the server's freeze-cap check
  /// reads the pushed blob (its monthly-grant component is
  /// evaluated against the blob's lastEvaluatedDay month), so the
  /// blob the buy surface was computed from must be the one on
  /// the server when spend/freeze runs. Fail-soft: a failed push
  /// still attempts the spend, whose 409 handling re-syncs.
  Future<void> _pushSettledBeforeSpend() async {
    try {
      final effective = _effectiveState();
      final push = widget.streakPush ??
          (int c, int b, String j, {int? purchasedFreezes}) =>
              TabsBackend().pushStreakRecord(
                c,
                b,
                j,
                purchasedFreezes: purchasedFreezes,
              );
      await push(
        streakCurrent(effective, _anchor),
        streakBest(effective),
        jsonEncode(effective.toJson()),
      );
    } catch (_) {
      // The spend's own refresh handling covers a stale blob.
    }
  }

  Future<void> _spendGems() async {
    if (_gemSpendBusy) return;
    setState(() => _gemSpendBusy = true);
    try {
      await _pushSettledBeforeSpend();
      final result = await _gems.spendOnFreeze();
      if (!mounted) return;
      final freezes = result.purchasedFreezes;
      if (freezes != null) {
        _adoptedPurchased = freezes.clamp(0, 1);
        unawaited(StreakStore.instance.adoptPurchasedFreezes(freezes));
      }
      switch (result.status) {
        case GemSpendStatus.success:
        case GemSpendStatus.replay:
          _gemSuccessBalance = result.balance ?? _gems.balance ?? 0;
          // Juno §2c motion: the freeze icon animates once into
          // the freeze row, exactly as for a §1a money grant.
          _grantEpoch++;
          final adopted = StreakStore.instance.state;
          if (adopted != null) {
            unawaited(WidgetSync.pushStreak(
              adopted.copyWith(
                purchasedFreezes: (freezes ?? adopted.purchasedFreezes)
                    .clamp(0, 1),
              ),
              signedIn: true,
              nickname: widget.nickname,
              now: DateTime.now(),
            ));
          }
        case GemSpendStatus.capReached:
          // Vera §3: a cap refusal right at a month boundary can
          // be an artifact of the server's blob-month basis —
          // re-sync ONCE and let the user retry from the refreshed
          // state. The refusal itself is never cached or treated
          // as terminal.
          unawaited(_gems.refreshBalance());
        case GemSpendStatus.insufficient:
        case GemSpendStatus.alreadyHeld:
        case GemSpendStatus.failed:
          // No success copy (Juno §2 ruling): the refreshed
          // balance / held state below IS the surface.
          break;
      }
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _gemSpendBusy = false);
    }
  }

  Future<void> _initPurchase() async {
    try {
      await _purchase!.initialize();
    } catch (_) {
      // The buy row renders its unavailable state; the rest of the
      // screen is unaffected.
    }
  }

  /// Juno §1a motion trigger (A2 fix): increments exactly once
  /// per verified grant (first-try or recovered) so the freeze
  /// icon animates into the freeze row once per grant — never on
  /// ordinary rebuilds or repeated service notifications.
  /// [_grantEpochsPresented] remembers which epochs the icon has
  /// already animated: the freeze card is built lazily (ListView),
  /// so a grant can land before the icon exists — it then plays
  /// its entrance when first built, and never replays after.
  int _grantEpoch = 0;
  bool _grantSeen = false;
  final Set<int> _grantEpochsPresented = {};

  void _onPurchaseChanged() {
    final granted = _purchase?.successMessage != null;
    if (granted && !_grantSeen) _grantEpoch++;
    _grantSeen = granted;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _purchase?.removeListener(_onPurchaseChanged);
    if (_ownsPurchase) _purchase?.dispose();
    _gems.removeListener(_onGemsChanged);
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
    // Juno §1c state: the account already holds the purchased
    // freeze — known from the held inventory or from a verify
    // answered 409 purchased_already_held this session.
    final alreadyHeldKnown = heldPurchased || purchase?.alreadyHeld == true;

    return _sectionCard(
      label: 'Streak Freeze',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FreezeGrantIcon(
                grantEpoch: _grantEpoch,
                alreadyPresented: _grantEpochsPresented.contains(_grantEpoch),
                onPresented: (epoch) {
                  if (mounted) {
                    setState(() => _grantEpochsPresented.add(epoch));
                  }
                },
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
          // Juno §1a — THE confirmation surface for a verified
          // grant (A2 fix): exactly one confirmation renders. The
          // recovered-grant surface (restoredMessage) carries the
          // same §1a text and renders only when it is not already
          // the successMessage, so a recovery never stacks two.
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
          ] else if (purchase?.restoredMessage != null) ...[
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
          // Juno §1b — the verify-pending state. While it shows,
          // the generic §5c failure string must NOT also render
          // for the same event (A2 fix; the service no longer sets
          // it then either — this guard is belt-and-braces).
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
          ] else if (purchase?.failureMessage != null) ...[
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
          // Juno §1c — inline on the purchase card when the
          // already-held state is known (including a 409
          // purchased_already_held answer): in place of the buy
          // action (the buy row below is suppressed in this state,
          // so no purchase sheet can launch and no charge is
          // attempted).
          if (purchase != null &&
              (purchase.alreadyHeld ||
                  (heldPurchased &&
                      purchase.adoptedPurchasedFreezes == null &&
                      _adoptedPurchased == null))) ...[
            const SizedBox(height: 12),
            const Text(
              StreakPurchaseCopy.alreadyHeld,
              key: Key('streakPurchaseAlreadyHeld'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: LabBlackColors.textSecondary,
              ),
            ),
          ],
          if (!alreadyHeldKnown && purchase != null) ...[
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
          // Gems — the buy-with-gems section (Juno §2) + the
          // founder-addition explainer (§4), inside this card.
          _gemSection(
            heldPurchased: heldPurchased,
            available: available,
            max: max,
          ),
        ],
      ),
    );
  }

  /// The gem-buy section of the Streak Freeze card (Juno §2 + §4).
  ///
  /// Buy rows (balance line §2b, button §2a, insufficient line
  /// §2d) render only while the buy affordance is live: hidden in
  /// exactly the ruled states — a purchased-class freeze held or
  /// total cover at cap (the same rule as the $0.99 affordance) —
  /// and only once a server balance exists. Under 100 gems the
  /// button is present but DISABLED with the §2d line under it.
  /// The §2c success feedback renders only on a verified server
  /// spend. The §4 explainer is text-only and always renders as
  /// part of this section, under the buy rows: the screen stays
  /// information-only apart from the buy affordances.
  Widget _gemSection({
    required bool heldPurchased,
    required int available,
    required int max,
  }) {
    final balance = _gems.balance;
    final buyHidden = heldPurchased || available >= max;
    final showBuy = !buyHidden && balance != null;
    final insufficient = balance != null && balance < GemCopy.freezePrice;
    return Column(
      key: const Key('gemBuySection'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 16),
        const Divider(height: 1, thickness: 1, color: LabBlackColors.hairline),
        const SizedBox(height: 12),
        if (_gemSuccessBalance != null) ...[
          const Text(
            GemCopy.spendSuccessTitle,
            key: Key('gemSpendSuccessTitle'),
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: LabBlackColors.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            GemCopy.spendSuccessBody(_gemSuccessBalance!),
            key: const Key('gemSpendSuccessBody'),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: LabBlackColors.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (showBuy) ...[
          Text(
            GemCopy.balanceLine(balance),
            key: const Key('gemBalanceLine'),
            style: const TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              height: 1.45,
              color: Color(0xFFAAB3D0),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              key: const Key('gemBuyButton'),
              style: ElevatedButton.styleFrom(
                backgroundColor: NotelColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 13),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              onPressed: (insufficient || _gemSpendBusy)
                  ? null
                  : () => unawaited(_spendGems()),
              child: const Text(
                GemCopy.buyButtonLabel,
                style: TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          if (insufficient) ...[
            const SizedBox(height: 8),
            Text(
              GemCopy.insufficientLine(GemCopy.freezePrice - balance),
              key: const Key('gemInsufficientLine'),
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
                color: Color(0xFF59637F),
              ),
            ),
          ],
          const SizedBox(height: 12),
        ],
        // Juno §4 explainer — verbatim, text only, no buttons or
        // flows. Understandable from this block alone.
        const Text(
          GemCopy.explainerHeading,
          key: Key('gemExplainerHeading'),
          style: TextStyle(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            color: LabBlackColors.textPrimary,
          ),
        ),
        const SizedBox(height: 6),
        for (var i = 0; i < GemCopy.explainerLines.length; i++) ...[
          Text(
            GemCopy.explainerLines[i],
            key: Key('gemExplainerLine$i'),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.45,
              color: Color(0xFFAAB3D0),
            ),
          ),
          if (i < GemCopy.explainerLines.length - 1)
            const SizedBox(height: 6),
        ],
      ],
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

/// The freeze card's existing freeze icon, with Juno §1a's ruled
/// motion shape (A2 fix): on a verified grant ([grantEpoch]
/// increments) the icon animates ONCE into the freeze row — a
/// ~350 ms fade + slide with a slight scale-up as it lands, no
/// loop, no bounce — and one light haptic tap fires at the moment
/// it lands. The held state updates in the same moment (the
/// service adopts before notifying). With reduce-motion on, the
/// icon renders in place (no slide/scale) and the haptic still
/// fires once. No Bandit animation, no confetti (Juno §1a ruling;
/// Bandit preview-first rule).
class _FreezeGrantIcon extends StatefulWidget {
  final int grantEpoch;

  /// Whether this epoch's entrance has already been presented
  /// (owned by the screen, which outlives this lazily built icon).
  final bool alreadyPresented;

  /// Marks [grantEpoch] presented the moment its entrance starts.
  final void Function(int epoch) onPresented;

  const _FreezeGrantIcon({
    required this.grantEpoch,
    required this.alreadyPresented,
    required this.onPresented,
  });

  @override
  State<_FreezeGrantIcon> createState() => _FreezeGrantIconState();
}

class _FreezeGrantIconState extends State<_FreezeGrantIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
    value: 1,
  );

  @override
  void initState() {
    super.initState();
    // The freeze card builds lazily: a grant that landed while
    // the card was off-screen reaches this icon as a first build
    // with an unpresented epoch — play the entrance now (once;
    // the screen's presented set prevents any replay).
    if (widget.grantEpoch > 0 && !widget.alreadyPresented) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playEntrance();
      });
    }
  }

  @override
  void didUpdateWidget(_FreezeGrantIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.grantEpoch == oldWidget.grantEpoch) return;
    if (widget.alreadyPresented) return;
    // Deferred to post-frame (gems fix, Nov 19, 2026): playing
    // the entrance synchronously here calls the screen's
    // onPresented setState DURING the build phase, which throws.
    // This is the same hazard the initState path already avoids
    // via a post-frame callback; a grant that lands while the
    // freeze card is on screen (a gem spend, or a money verify
    // completing with the card visible) reaches this branch.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playEntrance();
    });
  }

  void _playEntrance() {
    widget.onPresented(widget.grantEpoch);
    if (animationsDisabled(context)) {
      // Reduce-motion: render in place, one light tap on landing.
      _controller.value = 1;
      HapticFeedback.lightImpact();
      return;
    }
    _controller.forward(from: 0).whenComplete(() {
      // One light haptic tap at the moment the icon lands.
      HapticFeedback.lightImpact();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOut.transform(_controller.value);
        return Opacity(
          opacity: 0.25 + 0.75 * t,
          child: Transform.translate(
            offset: Offset(-10 * (1 - t), 0),
            child: Transform.scale(
              scale: 0.85 + 0.15 * t,
              child: child,
            ),
          ),
        );
      },
      child: Container(
        key: const Key('streakFreezeGrantIcon'),
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
    );
  }
}
