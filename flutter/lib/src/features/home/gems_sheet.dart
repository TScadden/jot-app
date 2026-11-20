import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Gems sheet (added scope #6, Nov 20, 2026, founder direction as
/// amended): opened by tapping the Home gem pill. It is the new
/// home of the About-gems explainer, which MOVED here off the
/// streak screen (the streak screen keeps its buy-with-gems row
/// exactly as-is; the same buy action is duplicated here).
///
/// State discipline — NO forks:
/// - The balance is [GemService.balance] from the injected/shared
///   service — the same server value the Home pill displays, kept
///   live by the service listener. No second fetch path: the sheet
///   reads the service, and the service's only balance sources are
///   server payloads (pull / grant / spend).
/// - The spend is the service's existing POST /api/gems/spend/
///   freeze path ([GemService.spendOnFreeze]), preceded by the
///   same settled-record push the streak screen performs before a
///   spend, and a verified spend adopts the purchased-freeze count
///   into [StreakStore] exactly as the streak screen does — so the
///   pill balance, this sheet, and every freeze surface reflect
///   the buy through the one shared state path.
/// - Cap/held derivation reuses the streak screen's own rule and
///   helpers: the buy control is ABSENT when a purchased freeze is
///   held or total cover is at cap (`heldPurchased || available
///   >= max`, via [totalAvailableCover] / [streakCap]). There is
///   NO already-held/at-cap string for the gem buy (GEMS-MOVE-COPY
///   §3.3) — none is invented here, and the $0.99 row's
///   already-held string is not borrowed.
/// - Copy: every string is a [GemCopy] value shared with the
///   streak screen (balance line, buy label, insufficient line,
///   success title/body) — never a second hard-coded copy. The
///   explainer is lines 1–4 verbatim plus the coordinator-approved
///   line 5 ([GemCopy.sheetExplainerLines]); the heading
///   [GemCopy.explainerHeading] is the sheet title, used ONCE.

/// The settled-record push used before a gem spend (the streak
/// screen's Vera §3 blob-before-spend discipline). Tests inject a
/// no-op; null uses the real profile push through the backend.
typedef GemsSheetStreakPush = Future<bool> Function(
  int current,
  int best,
  String json, {
  int? purchasedFreezes,
});

Future<void> showGemsSheet({
  required BuildContext context,
  GemService? gemService,
  StreakState? streakState,
  String? nickname,
  GemsSheetStreakPush? streakPush,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NotelColors.surface,
    isScrollControlled: true,
    builder: (_) => GemsSheet(
      gemService: gemService,
      streakState: streakState,
      nickname: nickname,
      streakPush: streakPush,
    ),
  );
}

class GemsSheet extends StatefulWidget {
  /// Gems service. Tests inject a fake; production leaves null and
  /// the sheet uses the shared [GemService.instance] (the pill's
  /// own balance source).
  final GemService? gemService;

  /// The settled streak state the freeze-cap rule reads. Null
  /// falls back to [StreakStore.instance.state] — the same settled
  /// record the streak screen opens with.
  final StreakState? streakState;

  /// The account nickname, forwarded to the widget payload when a
  /// gem spend refreshes it (streak-screen parity). Optional.
  final String? nickname;

  /// See [GemsSheetStreakPush].
  final GemsSheetStreakPush? streakPush;

  const GemsSheet({
    super.key,
    this.gemService,
    this.streakState,
    this.nickname,
    this.streakPush,
  });

  @override
  State<GemsSheet> createState() => _GemsSheetState();
}

class _GemsSheetState extends State<GemsSheet> {
  late final GemService _gems;

  /// True while a gem spend request is in flight.
  bool _spendBusy = false;

  /// Juno §2c surface: the post-spend SERVER balance from the
  /// verified gem spend this session; null until one lands. The
  /// success copy renders only while this is set — never on a tap
  /// (same rule as the streak screen).
  int? _successBalance;

  /// The purchased-freeze count adopted from a successful spend
  /// this session (streak-screen parity: counts read after
  /// adoption; the server column + next settle are the durable
  /// record).
  int? _adoptedPurchased;

  @override
  void initState() {
    super.initState();
    _gems = widget.gemService ?? GemService.instance;
    _gems.addListener(_onGemsChanged);
    // Streak-screen parity: refresh the balance from the service's
    // own profile pull on entry (the service's one pull path — the
    // value the pill already shows stands until it lands).
    unawaited(_gems.refreshBalance());
  }

  @override
  void dispose() {
    _gems.removeListener(_onGemsChanged);
    super.dispose();
  }

  void _onGemsChanged() {
    if (mounted) setState(() {});
  }

  StreakState? get _baseState =>
      widget.streakState ?? StreakStore.instance.state;

  /// The state the cap rule reads: the settled state with any
  /// just-adopted purchased count applied (streak-screen parity).
  StreakState? get _effectiveState {
    final base = _baseState;
    if (base == null) return null;
    final adopted = _adoptedPurchased;
    if (adopted == null || adopted == base.purchasedFreezes) return base;
    return base.copyWith(purchasedFreezes: adopted.clamp(0, 1));
  }

  /// Push the settled streak record before a gem spend (the streak
  /// screen's exact discipline: the server's freeze-cap check
  /// reads the pushed blob). Fail-soft: a failed push still
  /// attempts the spend, whose 409 handling re-syncs.
  Future<void> _pushSettledBeforeSpend(StreakState effective) async {
    try {
      final push = widget.streakPush ??
          (int c, int b, String j, {int? purchasedFreezes}) =>
              TabsBackend().pushStreakRecord(
                c,
                b,
                j,
                purchasedFreezes: purchasedFreezes,
              );
      await push(
        streakCurrent(effective, tabsDayAnchor(DateTime.now())),
        streakBest(effective),
        jsonEncode(effective.toJson()),
      );
    } catch (_) {
      // The spend's own refresh handling covers a stale blob.
    }
  }

  /// One gem spend — the streak screen's flow, shared state paths:
  /// push settled record → [GemService.spendOnFreeze] (POST
  /// /api/gems/spend/freeze) → adopt the server freeze count into
  /// the streak store; §2c success copy only on a verified spend;
  /// the three 409s land silently in the re-derived surface state
  /// (held/cap hides the buy control, insufficient shows §2d) with
  /// no raw error code.
  Future<void> _spendGems() async {
    if (_spendBusy) return;
    setState(() => _spendBusy = true);
    try {
      final effective = _effectiveState;
      if (effective != null) await _pushSettledBeforeSpend(effective);
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
          if (result.balance != null) {
            _successBalance = result.balance;
          } else {
            unawaited(_gems.refreshBalance());
          }
          // Streak-screen parity: the adopted held freeze is
          // pushed to the home-screen widget payload too.
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
          unawaited(_gems.refreshBalance());
        case GemSpendStatus.insufficient:
        case GemSpendStatus.alreadyHeld:
        case GemSpendStatus.failed:
          break;
      }
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _spendBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final balance = _gems.balance;
    final effective = _effectiveState;
    // The streak screen's absence rule (GEMS-MOVE-COPY §3.3): the
    // buy control does not render at all while a purchased freeze
    // is held or total cover is at cap. With no settled state to
    // derive from, the control stays hidden rather than guessing —
    // the server remains the authority and the balance + explainer
    // still render.
    final buyHidden = effective == null ||
        effective.purchasedFreezes > 0 ||
        totalAvailableCover(effective, DateTime.now()) >=
            streakCap(effective);
    final showBuy = !buyHidden && balance != null;
    final insufficient = balance != null && balance < GemCopy.freezePrice;
    final lines = GemCopy.sheetExplainerLines;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
          child: Column(
            key: const Key('gemsSheet'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Sheet title — the moved explainer heading, used
              // ONCE (GEMS-MOVE-COPY §2): it is not repeated as an
              // in-sheet heading above the explainer body.
              const Text(
                GemCopy.explainerHeading,
                key: Key('gemsSheetTitle'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: NotelColors.textPrimary,
                ),
              ),
              // The current balance — the same server value the
              // pill displays, in the one approved wording (the
              // §3.1 balance line, reused verbatim even outside
              // the buy row per GEMS-MOVE-COPY §3.3).
              if (balance != null) ...[
                const SizedBox(height: 12),
                Text(
                  GemCopy.balanceLine(balance),
                  key: const Key('gemsSheetBalanceLine'),
                  style: const TextStyle(
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                    height: 1.45,
                    color: NotelColors.textSecondary,
                  ),
                ),
              ],
              // The moved explainer (earn rules included): lines
              // 1–4 verbatim + the approved line 5.
              const SizedBox(height: 16),
              for (var i = 0; i < lines.length; i++) ...[
                Text(
                  lines[i],
                  key: Key('gemsSheetExplainerLine$i'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    height: 1.45,
                    color: NotelColors.textSecondary,
                  ),
                ),
                if (i < lines.length - 1) const SizedBox(height: 6),
              ],
              // §2c success feedback — verified spends only.
              if (_successBalance != null) ...[
                const SizedBox(height: 16),
                const Text(
                  GemCopy.spendSuccessTitle,
                  key: Key('gemsSheetSpendSuccessTitle'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: NotelColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  GemCopy.spendSuccessBody(_successBalance!),
                  key: const Key('gemsSheetSpendSuccessBody'),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: NotelColors.textPrimary,
                  ),
                ),
              ],
              // The buy-with-gems action — same GemCopy strings,
              // same spend path, same states as the streak screen:
              // enabled ≥ 100, disabled < 100 with the §2d line
              // under it, ABSENT when held / at cap.
              if (showBuy) ...[
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    key: const Key('gemsSheetBuyButton'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: NotelColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: (insufficient || _spendBusy)
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
                    GemCopy.insufficientLine(
                        GemCopy.freezePrice - balance),
                    key: const Key('gemsSheetInsufficientLine'),
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: NotelColors.textSecondary,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
