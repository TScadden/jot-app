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
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Streak detail screen (Lab streak package Nov 4, 2026; streak
/// upgrade rebuild Nov 18, 2026; Duolingo-modeled rebuild Nov 22,
/// 2026 to founder-approved mock v3 — streak-mock/make_streak_mock_v3.py).
///
/// Layout per mock v3: header (close / "Streak" / share),
/// PERSONAL / FRIENDS tabs, hero (PERSONAL BEST pill + big count
/// + "day streak!" + purple flame), freeze status card with a
/// GET MORE scroll action, week-bar month calendar with chevron
/// month nav, the gem-milestone Streak Goal track, the Perks /
/// Monthly Freeze card, the Get More Freezes buy card, and the
/// buy card below it. The old Streak Goal card's Juno §3 copy
/// (the monthly-freeze earning rule) lives in the Perks goal
/// block directly under the Monthly Freeze card (JUNO-COPY
/// A-10…A-14 placements). NO Premium card anywhere (founder
/// ruling). NO bottom action button (founder ruling).
///
/// Copy discipline: user-facing strings are Juno's verbatim
/// (JUNO-COPY.md) where she has ruled; new mock-v3 strings follow
/// the approved mock. The noun is "freeze" everywhere — "Restore"
/// is retired on this surface (§11). The displayed freeze count
/// is TOTAL AVAILABLE COVER (A1), never held-only. All display
/// reads anchor on the Tabs day (A7: `tabsDayAnchor`), never
/// wall-clock `now` directly.

// ── Mock v3 design tokens ──────────────────────────────────────
const Color _duoBg = Color(0xFF0A0A0B);
const Color _duoPrimary = Color(0xFF7C6EFF);
const Color _duoPrimaryLt = Color(0xFF9D8FFF);
const Color _duoFreeze = Color(0xFF6EC6FF);
const Color _duoFreezeChip = Color(0xFF12314F);
const Color _duoText = Color(0xFFF0EEFF);
const Color _duoMuted = Color(0xFF9A9AA3);
const Color _duoCaption = Color(0xFF7E8898);
const Color _duoBorder = Color(0xFF39434E);
const Color _duoBarDark = Color(0xFF251B42);
const Color _duoNavyBtn = Color(0xFF152040);
const Color _duoOnBright = Color(0xFF150F24);

/// The mock's heavy rounded type: bundled Nunito (OFL, variable)
/// scoped to this screen only. [wght] is the variable-font axis
/// value (700–1000 in the mock).
TextStyle _duo(
  double size,
  double wght,
  Color color, {
  double? letterSpacing,
  double? height,
}) {
  final index = ((wght / 100).round() - 1).clamp(0, 8);
  return TextStyle(
    fontFamily: 'Nunito',
    fontSize: size,
    fontWeight: FontWeight.values[index],
    fontVariations: [FontVariation('wght', wght)],
    color: color,
    letterSpacing: letterSpacing,
    height: height,
  );
}

/// The last gem milestone at or below [current], from the shipped
/// gem table ([gemMilestoneBonus]: 7, 30, then each 100); null
/// before the first milestone.
@visibleForTesting
int? gemGoalLastCrossed(int current) {
  int? crossed;
  for (var m = 7; m <= current; m = m < 30 ? 30 : m + (m < 100 ? 70 : 100)) {
    if (gemMilestoneBonus(m) != null) crossed = m;
  }
  return crossed;
}

/// The next three gem milestones strictly above [current].
@visibleForTesting
List<int> gemGoalUpcoming(int current) {
  final out = <int>[];
  var m = current < 7
      ? 7
      : current < 30
      ? 30
      : ((current ~/ 100) + 1) * 100;
  if (m <= current) m += 100;
  while (out.length < 3) {
    if (gemMilestoneBonus(m) != null) out.add(m);
    m = m < 30 ? 30 : m + (m < 100 ? 70 : 100);
  }
  return out;
}

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

  /// Friends loader for the FRIENDS tab. Tests inject a fake;
  /// production leaves null and the tab uses
  /// [TabsBackend.fetchFriendsList] — the same Community payload
  /// (nickname + currentStreak) the Community screen renders.
  final Future<List<FriendDto>> Function()? friendsLoader;

  /// Preloaded friends for the FRIENDS tab (tests / captures);
  /// null loads through [friendsLoader] on first tab open.
  final List<FriendDto>? initialFriends;

  const StreakScreen({
    super.key,
    required this.state,
    required this.now,
    this.purchaseService,
    this.gemService,
    this.nickname,
    this.streakPush,
    this.friendsLoader,
    this.initialFriends,
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

  /// PERSONAL (0) / FRIENDS (1) tab selection (mock v3 §1).
  int _tabIndex = 0;

  /// The calendar's visible month (presentation-level nav state;
  /// opens on the Tabs-day anchor's month).
  late DateTime _visibleMonth;

  final ScrollController _scrollController = ScrollController();

  /// Anchor for the GET MORE scroll-to-buy action.
  final GlobalKey _buyCardKey = GlobalKey();

  /// FRIENDS tab payload (Community friends, sorted by streak
  /// desc); null until loaded.
  List<FriendDto>? _friends;
  bool _friendsLoading = false;

  /// True when the FRIENDS load actually failed (Juno B-25 line
  /// renders only then — never for an empty list).
  bool _friendsFailed = false;

  StreakState get state => widget.state;
  DateTime get now => widget.now;
  DateTime get _anchor => tabsDayAnchor(now);

  @override
  void initState() {
    super.initState();
    _visibleMonth = DateTime(_anchor.year, _anchor.month, 1);
    if (widget.initialFriends != null) {
      _friends = List<FriendDto>.of(widget.initialFriends!)
        ..sort((a, b) => b.currentStreak.compareTo(a.currentStreak));
    }
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
  /// and shows §2c ONLY on the verified spend. The 409s refresh
  /// state from the server body (balance + freeze count ride
  /// along) and fall into the ruled surface state — at-cap hides
  /// the buy rows, insufficient shows §2d — with no raw error
  /// code and no dead end.
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
      final push =
          widget.streakPush ??
          (int c, int b, String j, {int? purchasedFreezes}) => TabsBackend()
              .pushStreakRecord(c, b, j, purchasedFreezes: purchasedFreezes);
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
        // 0..3 (gem-buy rule change, Nov 21, 2026): a verified
        // gem spend can return a purchased-class count of 2–3.
        _adoptedPurchased = freezes.clamp(0, 3);
        unawaited(StreakStore.instance.adoptPurchasedFreezes(freezes));
      }
      switch (result.status) {
        case GemSpendStatus.success:
        case GemSpendStatus.replay:
          // Juno §2c prints the post-spend balance FROM the spend
          // body (PR #41's contract always sends gemBalance). If
          // a body ever lacked it, suppress the success body and
          // re-sync state instead of displaying an invented
          // number (Vera M2, Fix Round 1).
          if (result.balance != null) {
            _gemSuccessBalance = result.balance;
          } else {
            unawaited(_gems.refreshBalance());
          }
          // Juno §2c motion: the freeze icon animates once into
          // the freeze row, exactly as for a §1a money grant.
          _grantEpoch++;
          final adopted = StreakStore.instance.state;
          if (adopted != null) {
            unawaited(
              WidgetSync.pushStreak(
                adopted.copyWith(
                  purchasedFreezes: (freezes ?? adopted.purchasedFreezes).clamp(
                    0,
                    3,
                  ),
                ),
                signedIn: true,
                nickname: widget.nickname,
                now: DateTime.now(),
              ),
            );
          }
        case GemSpendStatus.capReached:
          // Vera §3: a cap refusal right at a month boundary can
          // be an artifact of the server's blob-month basis —
          // re-sync ONCE and let the user retry from the refreshed
          // state. The refusal itself is never cached or treated
          // as terminal.
          unawaited(_gems.refreshBalance());
        case GemSpendStatus.insufficient:
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
    _scrollController.dispose();
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
    return state.copyWith(purchasedFreezes: adopted.clamp(0, 3));
  }

  @override
  Widget build(BuildContext context) {
    final current = streakCurrent(state, _anchor);
    final best = streakBest(state);

    return Scaffold(
      backgroundColor: _duoBg,
      body: Stack(
        children: [
          StreakShareCardHost(boundaryKey: _cardKey, count: current),
          SafeArea(
            child: Column(
              children: [
                _header(context, current),
                _tabBar(),
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(16, 20, 16, 32),
                    child: _tabIndex == 0
                        ? _personalTab(current, best)
                        : _friendsTab(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _personalTab(int current, int best) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _hero(current, best),
        const SizedBox(height: 24),
        _freezeStatusCard(),
        const SizedBox(height: 16),
        // Juno A-8: the streak-ladder milestone line keeps its
        // verbatim distance form, directly under the freeze card.
        // It is a different ladder from the gem-milestone line in
        // the Streak Goal card (B-14) — never merged.
        _milestoneLine(current),
        const SizedBox(height: 28),
        _sectionTitle('Streak Calendar'),
        const SizedBox(height: 12),
        _calendarCard(),
        _legendRow(),
        if (_visibleMonthHasRestored()) ...[
          const SizedBox(height: 10),
          const Text(
            // Juno A-32 (§11): the verb is "covered" — "restored"
            // is retired from user-facing copy with "Restore".
            'A day with a snowflake was covered by a freeze.',
            style: TextStyle(fontSize: 12, color: _duoMuted),
          ),
        ],
        const SizedBox(height: 28),
        _sectionTitle('Streak Goal'),
        const SizedBox(height: 12),
        _goalTrackCard(current),
        const SizedBox(height: 28),
        _sectionTitle('Perks'),
        const SizedBox(height: 12),
        _perksCard(),
        const SizedBox(height: 16),
        _goalBlock(),
        const SizedBox(height: 16),
        _buyCard(),
      ],
    );
  }

  bool _visibleMonthHasRestored() {
    return state.restoredDays.any(
      (d) => d.startsWith(streakMonthKey(_visibleMonth)),
    );
  }

  /// Juno A-8 — distance form, never a prediction. Suppressed when
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
      style: _duo(16.5, 700, const Color(0xFFAAB3D0)),
    );
  }

  Widget _sectionTitle(String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 2),
      child: Text(label, style: _duo(25, 900, _duoText)),
    );
  }

  Widget _outlinedCard({Key? key, required Widget child, EdgeInsets? padding}) {
    return Container(
      key: key,
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: _duoBorder, width: 1.2),
        borderRadius: BorderRadius.circular(13),
      ),
      padding: padding ?? const EdgeInsets.all(20),
      child: child,
    );
  }

  Widget _header(BuildContext context, int current) {
    return SizedBox(
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text('Streak', style: _duo(19.5, 900, _duoText)),
          Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              tooltip: 'Back',
              icon: const Icon(Icons.close, size: 24, color: _duoText),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: IconButton(
              key: const Key('streakShareButton'),
              tooltip: 'Share',
              icon: const Icon(Icons.ios_share, size: 22, color: _duoText),
              onPressed: () => unawaited(
                StreakShareService.shareFromBoundary(_cardKey, count: current),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tabBar() {
    Widget tab(int index, String label, Key key) {
      final active = _tabIndex == index;
      return Expanded(
        child: InkWell(
          key: key,
          onTap: () {
            if (_tabIndex == index) return;
            setState(() => _tabIndex = index);
            if (index == 1) unawaited(_loadFriends());
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              label,
              textAlign: TextAlign.center,
              style: _duo(
                16.5,
                900,
                active ? _duoPrimary : _duoText,
                letterSpacing: 1.2,
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            tab(0, 'PERSONAL', const Key('streakTabPersonal')),
            tab(1, 'FRIENDS', const Key('streakTabFriends')),
          ],
        ),
        Stack(
          children: [
            Container(height: 1, color: const Color(0xFF2A343C)),
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 3.4,
                    decoration: BoxDecoration(
                      color: _tabIndex == 0 ? _duoPrimary : Colors.transparent,
                      borderRadius: BorderRadius.circular(1.7),
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    height: 3.4,
                    decoration: BoxDecoration(
                      color: _tabIndex == 1 ? _duoPrimary : Colors.transparent,
                      borderRadius: BorderRadius.circular(1.7),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _loadFriends() async {
    if (_friends != null || _friendsLoading) return;
    _friendsLoading = true;
    try {
      final loader =
          widget.friendsLoader ?? () => TabsBackend().fetchFriendsList();
      final list = await loader();
      final sorted = List<FriendDto>.of(list)
        ..sort((a, b) => b.currentStreak.compareTo(a.currentStreak));
      if (mounted) setState(() => _friends = sorted);
    } catch (_) {
      if (mounted) setState(() => _friendsFailed = true);
    } finally {
      _friendsLoading = false;
    }
  }

  Widget _friendsTab() {
    final friends = _friends;
    if (friends == null) {
      if (_friendsFailed) {
        return Padding(
          padding: const EdgeInsets.only(top: 48),
          child: Center(
            child: Text(
              // Juno B-25: the one approved load-failure line.
              "Couldn't load your friends right now. Try again later.",
              key: const Key('streakFriendsError'),
              textAlign: TextAlign.center,
              style: _duo(15, 700, _duoMuted),
            ),
          ),
        );
      }
      return const Padding(
        padding: EdgeInsets.only(top: 48),
        child: Center(child: CircularProgressIndicator(color: _duoPrimary)),
      );
    }
    if (friends.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 48),
        child: Center(
          child: Text(
            // Juno B-24: Community's empty state, verbatim — one
            // empty state app-wide.
            'No friends added yet. Add friends using their Nickname#ID!',
            key: const Key('streakFriendsEmpty'),
            textAlign: TextAlign.center,
            style: _duo(15, 700, _duoMuted),
          ),
        ),
      );
    }
    return _outlinedCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Column(
        children: [
          for (var i = 0; i < friends.length; i++) ...[
            if (i > 0)
              const Divider(height: 1, thickness: 1, color: Color(0xFF2A343C)),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: _duoNavyBtn,
                    ),
                    child: Center(
                      child: Text(
                        friends[i].nickname.isEmpty
                            ? '?'
                            : friends[i].nickname[0].toUpperCase(),
                        style: _duo(16, 900, _duoText),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            friends[i].nickname,
                            style: _duo(16, 700, _duoText),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '#${friends[i].tag}',
                          style: _duo(13, 700, _duoMuted),
                        ),
                      ],
                    ),
                  ),
                  // Juno B-23: the Community screen's shipped stat
                  // formats — flame + settled currentStreak with
                  // "{N} day streak" semantics, gem icon + count
                  // with GemCopy.pillLabel semantics. No rank, no
                  // level/points, no comparative copy on this tab.
                  Semantics(
                    container: true,
                    label: '${friends[i].currentStreak} day streak',
                    child: ExcludeSemantics(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.local_fire_department,
                            size: 16,
                            color: _duoPrimary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${friends[i].currentStreak}',
                            style: _duo(13, 900, _duoPrimary),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Semantics(
                    container: true,
                    label: GemCopy.pillLabel(friends[i].gemBalance),
                    child: ExcludeSemantics(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Image.asset(
                            GemCopy.iconAsset,
                            width: 16,
                            height: 16,
                            fit: BoxFit.contain,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${friends[i].gemBalance}',
                            style: _duo(13, 900, _duoPrimaryLt),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hero(int current, int best) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [_duoPrimaryLt, _duoPrimary],
                    ),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      // Juno B-1: the pill carries its unit — it
                      // must be true read alone.
                      best == 1
                          ? 'PERSONAL BEST · 1 DAY'
                          : 'PERSONAL BEST · $best DAYS',
                      softWrap: false,
                      style: _duo(
                        12,
                        800,
                        const Color(0xFF17102E),
                        letterSpacing: 1.6,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Semantics(
                  container: true,
                  label: '$current day streak',
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$current',
                          key: const Key('streakHeroNumber'),
                          style: _duo(88, 1000, _duoPrimary, height: 1.0),
                        ),
                        Text('day streak!', style: _duo(29, 900, _duoPrimary)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          width: 118,
          height: 128,
          child: Stack(
            alignment: Alignment.topCenter,
            children: [
              const Positioned(
                bottom: 6,
                child: SizedBox(
                  width: 74,
                  height: 11,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Color(0xFF1D1533),
                      borderRadius: BorderRadius.all(
                        Radius.elliptical(37, 5.5),
                      ),
                    ),
                  ),
                ),
              ),
              const Icon(
                Icons.local_fire_department,
                size: 112,
                color: _duoPrimary,
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _scrollToBuy() {
    final ctx = _buyCardKey.currentContext;
    if (ctx != null) {
      unawaited(
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
          alignment: 0.02,
        ),
      );
    } else if (_scrollController.hasClients) {
      unawaited(
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeOut,
        ),
      );
    }
  }

  /// Freeze status card (mock §4): the existing freeze-grant chip
  /// treatment, the available-cover headline from real state, and
  /// GET MORE wired to scroll to the Get More Freezes card.
  Widget _freezeStatusCard() {
    final effective = _effectiveState();
    final available = totalAvailableCover(effective, now);
    final max = streakCap(effective);
    return _outlinedCard(
      child: Row(
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
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'You have $available of $max Streak Freezes ready',
                  key: const Key('streakFreezeHeadline'),
                  style: _duo(18.5, 700, _duoText, height: 1.35),
                ),
                const SizedBox(height: 4),
                InkWell(
                  key: const Key('streakGetMoreButton'),
                  onTap: _scrollToBuy,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'GET MORE',
                      style: _duo(15.5, 900, _duoFreeze, letterSpacing: 1.4),
                    ),
                  ),
                ),
                // Juno A-18: §4a sentence 3, kept verbatim as the
                // small caption under GET MORE.
                const Text(
                  'A freeze can cover one missed day automatically when you have one available.',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                    color: _duoCaption,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The bright-bar week for the visible month: the week containing
  /// today when it has counted days, else the most recent week with
  /// counted days, else -1 (mock: brighter gradient on the current
  /// partial week, darker tint on the other completed weeks).
  int _brightWeekIndex(List<List<DateTime?>> weeks, String todayStr) {
    var lastCounted = -1;
    for (var w = 0; w < weeks.length; w++) {
      var hasCounted = false;
      var hasToday = false;
      for (final day in weeks[w]) {
        if (day == null) continue;
        final ds = streakDayStr(day);
        if (state.countedDays.contains(ds)) hasCounted = true;
        if (ds == todayStr) hasToday = true;
      }
      if (hasCounted) {
        lastCounted = w;
        if (hasToday) return w;
      }
    }
    return lastCounted;
  }

  Widget _calendarCard() {
    final year = _visibleMonth.year;
    final month = _visibleMonth.month;
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
    final weeks = <List<DateTime?>>[
      for (var r = 0; r < cells.length ~/ 7; r++)
        cells.sublist(r * 7, r * 7 + 7),
    ];
    final todayStr = tabsDayStr(now);
    final brightWeek = _brightWeekIndex(weeks, todayStr);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _outlinedCard(
          padding: const EdgeInsets.fromLTRB(12, 14, 12, 16),
          child: Column(
            children: [
              Row(
                children: [
                  IconButton(
                    key: const Key('streakCalPrevMonth'),
                    tooltip: 'Previous month',
                    icon: const Icon(
                      Icons.chevron_left,
                      size: 24,
                      color: _duoMuted,
                    ),
                    onPressed: () => setState(() {
                      _visibleMonth = DateTime(year, month - 1, 1);
                    }),
                  ),
                  Expanded(
                    child: Text(
                      '${StreakScreen._monthNames[month - 1]} $year',
                      textAlign: TextAlign.center,
                      style: _duo(19, 800, _duoText),
                    ),
                  ),
                  IconButton(
                    key: const Key('streakCalNextMonth'),
                    tooltip: 'Next month',
                    icon: const Icon(
                      Icons.chevron_right,
                      size: 24,
                      color: _duoMuted,
                    ),
                    onPressed: () => setState(() {
                      _visibleMonth = DateTime(year, month + 1, 1);
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    for (final w in const [
                      'Su',
                      'Mo',
                      'Tu',
                      'We',
                      'Th',
                      'Fr',
                      'Sa',
                    ])
                      Expanded(
                        child: Center(
                          child: Text(
                            w,
                            style: _duo(14.5, 800, const Color(0xFF71808F)),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              for (var r = 0; r < weeks.length; r++)
                _calendarWeek(weeks[r], todayStr, bright: r == brightWeek),
            ],
          ),
        ),
      ],
    );
  }

  Widget _calendarWeek(
    List<DateTime?> week,
    String todayStr, {
    required bool bright,
  }) {
    // Maximal runs of counted days in this week render as one
    // rounded bar (mock §5). Grace-completed days are counted days
    // with no distinct visual treatment today (their set only
    // suppresses gem earnings), so they join bars exactly like any
    // counted day. Freeze-covered days keep the
    // StreakFreezeDayCircle treatment ON the bar.
    final runs = <({int start, int len})>[];
    var i = 0;
    while (i < 7) {
      final day = week[i];
      if (day != null && state.countedDays.contains(streakDayStr(day))) {
        var j = i;
        while (j < 7 &&
            week[j] != null &&
            state.countedDays.contains(streakDayStr(week[j]!))) {
          j++;
        }
        runs.add((start: i, len: j - i));
        i = j;
      } else {
        i++;
      }
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: SizedBox(
        height: 39,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final colW = constraints.maxWidth / 7;
            return Stack(
              children: [
                for (final run in runs)
                  Positioned(
                    left: run.start * colW + 1,
                    top: 4,
                    width: run.len * colW - 2,
                    height: 31,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: bright ? null : _duoBarDark,
                        gradient: bright
                            ? const LinearGradient(
                                colors: [_duoPrimaryLt, _duoPrimary],
                              )
                            : null,
                        borderRadius: BorderRadius.circular(15.5),
                      ),
                    ),
                  ),
                Row(
                  children: [
                    for (var c = 0; c < 7; c++)
                      Expanded(
                        child: _calendarDay(week[c], todayStr, bright: bright),
                      ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _calendarDay(DateTime? day, String todayStr, {required bool bright}) {
    if (day == null) return const SizedBox(height: 39);
    final ds = streakDayStr(day);
    final counted = state.countedDays.contains(ds);
    final restored = state.restoredDays.contains(ds);
    final isToday = ds == todayStr;

    // Founder addition (Nov 18, 2026): a freeze-covered day is the
    // icy-blue snowflake circle on every rebuilt surface — checked
    // before the today/completed treatments. The date stays
    // identifiable without color via the semantics label (Juno C6).
    if (restored) {
      final cell = SizedBox(
        height: 39,
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
    if (isToday) {
      return SizedBox(
        height: 39,
        child: Center(
          child: Container(
            width: 33,
            height: 33,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: _duoPrimary,
            ),
            child: Center(
              child: Text('${day.day}', style: _duo(17.5, 900, _duoOnBright)),
            ),
          ),
        ),
      );
    }
    return SizedBox(
      height: 39,
      child: Center(
        child: Text(
          '${day.day}',
          style: _duo(
            17.5,
            800,
            counted
                ? (bright ? _duoOnBright : _duoPrimary)
                : const Color(0xFF5F6874),
          ),
        ),
      ),
    );
  }

  Widget _legendRow() {
    Widget item(Widget swatch, String label) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          swatch,
          const SizedBox(width: 7),
          Text(label, style: _duo(13.5, 700, const Color(0xFFC8CDDA))),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
      child: Wrap(
        spacing: 22,
        runSpacing: 8,
        children: [
          item(
            Container(
              width: 19,
              height: 10,
              decoration: BoxDecoration(
                color: _duoPrimary,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            'Completed',
          ),
          item(
            Container(
              width: 13,
              height: 13,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: _duoPrimary,
              ),
            ),
            'Today',
          ),
          item(const StreakFreezeDayCircle(size: 14), 'Freeze day'),
        ],
      ),
    );
  }

  /// Streak Goal card (mock §6): the gem-milestone track. The
  /// check marker sits at the last crossed gem milestone; the next
  /// three milestones render as calendar markers with their gem
  /// bonuses from [gemMilestoneBonus]. Generalized from real state.
  Widget _goalTrackCard(int current) {
    final crossed = gemGoalLastCrossed(current);
    final upcoming = gemGoalUpcoming(current);
    final next = upcoming.first;
    return _outlinedCard(
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final w = constraints.maxWidth;
                final centers = <double>[0, w / 3, 2 * w / 3, w];
                return SizedBox(
                  height: 88,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 20,
                        child: Container(
                          height: 23,
                          decoration: BoxDecoration(
                            color: const Color(0xFF252B38),
                            borderRadius: BorderRadius.circular(11.5),
                          ),
                        ),
                      ),
                      if (crossed != null)
                        Positioned(
                          left: 0,
                          top: 20,
                          child: Container(
                            width: centers[0] + 21,
                            height: 23,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [_duoPrimaryLt, _duoPrimary],
                              ),
                              borderRadius: BorderRadius.circular(11.5),
                            ),
                          ),
                        ),
                      // Slot 0: the check marker (last crossed), or a
                      // dim start marker before the first milestone.
                      Positioned(
                        left: centers[0] - 20.5,
                        top: 11,
                        child: crossed != null
                            ? Container(
                                key: const Key('streakGoalCheck'),
                                width: 41,
                                height: 41,
                                decoration: BoxDecoration(
                                  color: _duoPrimary,
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: const Icon(
                                  Icons.check,
                                  size: 24,
                                  color: Colors.white,
                                ),
                              )
                            : Container(
                                key: const Key('streakGoalStart'),
                                width: 41,
                                height: 41,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: _duoBorder,
                                    width: 2,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.radio_button_unchecked,
                                  size: 20,
                                  color: _duoCaption,
                                ),
                              ),
                      ),
                      for (var s = 0; s < 3; s++) ...[
                        Positioned(
                          left: centers[s + 1] - 20.5,
                          top: 11,
                          child: _goalMarker(upcoming[s]),
                        ),
                        // The label group is ~61 CSS wide at
                        // 9pt (Vera flag 4b fit pass: font 10->9,
                        // icon 12->11, box 72->60 so adjacent
                        // groups keep >=5px at 360 and 390); its
                        // center clamps inside the card so edge
                        // labels never cross the border or each
                        // other.
                        Positioned(
                          top: 62,
                          left: (centers[s + 1] - 30)
                              .clamp(-10.0, w - 50)
                              .toDouble(),
                          width: 60,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Image.asset(
                                  GemCopy.iconAsset,
                                  width: 11,
                                  height: 11,
                                ),
                                const SizedBox(width: 3),
                                Text(
                                  '+${gemMilestoneBonus(upcoming[s])} gems',
                                  style: _duo(9, 800, _duoPrimaryLt),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '$current / $next DAYS',
                    key: const Key('streakGoalCaption'),
                    style: _duo(14.5, 800, _duoCaption, letterSpacing: 1.4),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    // Juno B-14: the word "gem" is what makes this
                    // true — on the streak ladder nextMilestone(30)
                    // is 60, not 100.
                    'Next gem milestone: $next days',
                    key: const Key('streakGoalNext'),
                    style: _duo(14, 800, _duoPrimary),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _goalMarker(int milestone) {
    return Container(
      key: Key('streakGoalMarker-$milestone'),
      width: 41,
      height: 41,
      decoration: BoxDecoration(
        color: const Color(0xFFEDEFF5),
        borderRadius: BorderRadius.circular(9),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Column(
          children: [
            Container(height: 12.5, color: _duoPrimary),
            Expanded(
              child: Center(
                child: Text(
                  '$milestone',
                  style: _duo(15.5, 900, const Color(0xFF1B1430)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Perks / Monthly Freeze card (mock §7; copy per JUNO-COPY
  /// B-17/B-18): Juno's amended description verbatim — per-month
  /// grant, no stacking, use-based test, alive condition, cap →
  /// waits — and the REFILLS IN status line, which renders ONLY
  /// when the current month's monthly grant has been used
  /// (monthlyUsed): while the grant is ready a refill countdown
  /// would be false, because nothing is coming to add to it.
  Widget _perksCard() {
    final effective = _effectiveState();
    final monthlyUsed = effective.consumedSaveMonths.contains(
      streakMonthKey(_anchor),
    );
    final refillDays = _refillDays();

    return _outlinedCard(
      padding: const EdgeInsets.all(22),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              color: _duoFreezeChip,
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(Icons.ac_unit, size: 38, color: _duoFreeze),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Monthly Freeze', style: _duo(20, 900, _duoText)),
                const SizedBox(height: 8),
                Text(
                  "One free streak freeze comes with each new month — an unused one doesn't add up. Finish a month without using any freeze while your streak is going, and you earn one extra freeze. If you're at your max when it comes due, it waits until there's room.",
                  key: const Key('streakPerksDesc'),
                  style: _duo(15.5, 600, const Color(0xFFC6CBD8), height: 1.42),
                ),
                if (monthlyUsed) ...[
                  const SizedBox(height: 12),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: 'REFILLS IN ',
                          style: _duo(
                            14.5,
                            900,
                            const Color(0xFF7A8494),
                            letterSpacing: 1.2,
                          ),
                        ),
                        TextSpan(
                          text: refillDays == 1 ? '1 DAY' : '$refillDays DAYS',
                          style: _duo(
                            14.5,
                            900,
                            _duoFreeze,
                            letterSpacing: 1.2,
                          ),
                        ),
                      ],
                    ),
                    key: const Key('streakRefillLine'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The Perks goal block (JUNO-COPY §4 item 6): the shipped
  /// Streak Goal card's Juno §3 copy — §3a state-swapped copy,
  /// §3b progress (hidden when spoiled; pinned full for the
  /// completed month when pending), §3c pause texts — directly
  /// under the Monthly Freeze card, above the Get More Freezes
  /// card. The Streak Goal card is the gem-milestone track now;
  /// this block is where the monthly earning rule lives.
  Widget _goalBlock() {
    final monthName = StreakScreen._monthNames[_anchor.month - 1];
    final nextMonth = DateTime(_anchor.year, _anchor.month + 1, 1);
    final nextMonthName = StreakScreen._monthNames[nextMonth.month - 1];
    final monthKey = streakMonthKey(_anchor);
    final spoiled =
        state.spoiledMonths.contains(monthKey) ||
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

    return _outlinedCard(
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
                valueColor: const AlwaysStoppedAnimation<Color>(_duoPrimary),
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
                ? "Your earned freeze is ready and waiting. It lands as soon as there's room for it: you aren't already holding an earned freeze, and your total freezes are under your max (2, or 3 while you hold a freeze you bought)."
                : "If you finish $monthName with no freezes used, you earn one extra freeze. If you're at your max when it comes due, it waits — pending — until there's room for it. Max 2 freezes, or 3 while you hold a freeze you bought.",
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

  /// Days from the Tabs-day anchor to the next monthly-grant
  /// refill: the grant renews on the 1st of the next calendar
  /// month (an unused grant expires with its month — no rollover).
  int _refillDays() {
    final a = DateTime(_anchor.year, _anchor.month, _anchor.day);
    final next = DateTime(a.year, a.month + 1, 1);
    return next.difference(a).inDays;
  }

  /// Get More Freezes card (mock §8; copy per JUNO-COPY): the gem
  /// buy and the money buy side by side, wired to the EXISTING
  /// purchase paths (GemService.spendOnFreeze;
  /// StreakFreezePurchaseService.buy) with their ruled states:
  ///
  /// - Gem button (B-20): `GemCopy.freezePrice` GEMS — hidden when
  ///   total cover is at cap (shipped rule, unchanged), hidden
  ///   until a server balance has loaded, present but disabled
  ///   under 100 gems with the §2d line under it.
  /// - Money button (B-21): the live Play listing price — never a
  ///   typed literal; §1c already-held text takes its place while
  ///   a purchased freeze is held; §5a takes its place while Play
  ///   is unreachable.
  /// - §4c note (A-25) directly under BOTH buttons, above the
  ///   state line, whenever the money button is visible.
  /// - Outcomes (§1a/§1b/§5c gem §2c) under the buy buttons.
  Widget _buyCard() {
    final effective = _effectiveState();
    final available = totalAvailableCover(effective, now);
    final max = streakCap(effective);
    final purchase = _purchase;
    final heldPurchased = effective.purchasedFreezes > 0;
    final alreadyHeldKnown = heldPurchased || purchase?.alreadyHeld == true;
    final balance = _gems.balance;
    final atCap = available >= max;
    final insufficient = balance != null && balance < GemCopy.freezePrice;
    final gemVisible = !atCap && balance != null;
    final gemEnabled = gemVisible && !insufficient && !_gemSpendBusy;
    final moneyVisible =
        purchase == null || purchase.state != StreakFreezeBuyState.unavailable;
    final moneySlot = _moneySlot(
      purchase: purchase,
      alreadyHeldKnown: alreadyHeldKnown,
      heldPurchased: heldPurchased,
    );

    return Container(
      key: _buyCardKey,
      child: _outlinedCard(
        key: const Key('streakBuyCard'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Get More Freezes', style: _duo(19.5, 900, _duoText)),
            const SizedBox(height: 14),
            Column(
              key: const Key('gemBuySection'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (purchase != null &&
                    purchase.state == StreakFreezeBuyState.unavailable)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (gemVisible)
                        Expanded(child: _gemButton(gemEnabled: gemEnabled)),
                      if (gemVisible) const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
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
                            // §1c renders independently of the §5a
                            // state, exactly as on the shipped
                            // screen: both can hold at once.
                            if (_alreadyHeldSlot(
                              purchase: purchase,
                              heldPurchased: heldPurchased,
                            )) ...[
                              const SizedBox(height: 12),
                              const Text(
                                StreakPurchaseCopy.alreadyHeld,
                                key: Key('streakPurchaseAlreadyHeld'),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700,
                                  color: _duoMuted,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  )
                else
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (gemVisible)
                        Expanded(child: _gemButton(gemEnabled: gemEnabled)),
                      if (gemVisible) const SizedBox(width: 10),
                      Expanded(child: moneySlot),
                    ],
                  ),
                if (insufficient && !atCap) ...[
                  const SizedBox(height: 10),
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
                // Gem §2c success — verified server spends only;
                // the body prints the post-spend server balance.
                if (_gemSuccessBalance != null) ...[
                  const SizedBox(height: 12),
                  const Text(
                    GemCopy.spendSuccessTitle,
                    key: Key('gemSpendSuccessTitle'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _duoText,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    GemCopy.spendSuccessBody(_gemSuccessBalance!),
                    key: const Key('gemSpendSuccessBody'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _duoText,
                    ),
                  ),
                ],
                // Juno §1a — THE confirmation surface for a verified
                // money grant: exactly one confirmation renders.
                if (purchase?.successMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    purchase!.successMessage!,
                    key: const Key('streakPurchaseSuccess'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _duoText,
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
                      color: _duoText,
                    ),
                  ),
                ],
                if (purchase?.pendingMessage != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    purchase!.pendingMessage!,
                    key: const Key('streakPurchasePending'),
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: _duoMuted,
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
                      color: _duoMuted,
                    ),
                  ),
                ],
                // Juno A-25 (§4c): directly under BOTH buy buttons,
                // above the state line, whenever the money button
                // is visible.
                if (moneyVisible) ...[
                  const SizedBox(height: 12),
                  const Text(
                    "Not a subscription — you pay once for this freeze. While you hold a freeze you bought, your max is 3; otherwise it's 2.",
                    key: Key('streakBuyNote'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF59637F),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  // Juno B-22: the cap clause is the VC 100159
                  // wording verbatim; the "Gems:" segment is
                  // omitted entirely until a server balance loads.
                  'Max 2 freezes, or 3 while you hold a purchased freeze'
                  ' · You hold $available'
                  '${balance != null ? ' · Gems: $balance' : ''}',
                  key: const Key('streakBuyCaption'),
                  style: _duo(13, 600, _duoMuted, height: 1.45),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _gemButton({required bool gemEnabled}) {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        key: const Key('gemBuyButton'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _duoNavyBtn,
          foregroundColor: _duoText,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
        ),
        onPressed: gemEnabled ? () => unawaited(_spendGems()) : null,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image.asset(GemCopy.iconAsset, width: 21, height: 21),
              const SizedBox(width: 7),
              // Juno B-20: the number renders from
              // GemCopy.freezePrice, never a literal.
              Text(
                '${GemCopy.freezePrice} GEMS',
                style: _duo(16, 900, _duoText),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Whether Juno §1c's already-held state is known this session
  /// (the shipped condition: a 409 already-held answer, or a held
  /// purchased freeze with no adoption this session).
  bool _alreadyHeldSlot({
    required StreakFreezePurchaseService? purchase,
    required bool heldPurchased,
  }) {
    return purchase != null &&
        (purchase.alreadyHeld ||
            (heldPurchased &&
                purchase.adoptedPurchasedFreezes == null &&
                _adoptedPurchased == null));
  }

  /// The money-buy slot: the price button (price ALWAYS from the
  /// Play listing — Juno B-21), or Juno §1c's already-held text in
  /// its place while a purchased freeze is held (no purchase sheet
  /// can launch and no charge is attempted in that state).
  Widget _moneySlot({
    required StreakFreezePurchaseService? purchase,
    required bool alreadyHeldKnown,
    required bool heldPurchased,
  }) {
    if (_alreadyHeldSlot(purchase: purchase, heldPurchased: heldPurchased)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 4),
        child: Text(
          StreakPurchaseCopy.alreadyHeld,
          key: Key('streakPurchaseAlreadyHeld'),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w700,
            color: _duoMuted,
          ),
        ),
      );
    }
    if (purchase == null || purchase.product == null) {
      return const SizedBox(height: 48);
    }
    final buying = purchase.state == StreakFreezeBuyState.buying;
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        key: const Key('streakBuyButton'),
        style: ElevatedButton.styleFrom(
          backgroundColor: _duoNavyBtn,
          foregroundColor: _duoText,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(11),
          ),
        ),
        onPressed: buying ? null : () => unawaited(purchase.buy()),
        child: Text(purchase.product!.price, style: _duo(16.5, 900, _duoText)),
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
            child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
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
        child: const Icon(Icons.ac_unit, size: 32, color: Color(0xFF6EC6FF)),
      ),
    );
  }
}
