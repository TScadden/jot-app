import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:tabs_lab/src/data/chest_service.dart';
import 'package:tabs_lab/src/data/cosmetics.dart';
import 'package:tabs_lab/src/data/cosmetics_service.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/home/chests_sheet.dart';
import 'package:tabs_lab/src/features/home/gems_sheet.dart'
    show GemsSheetStreakPush;
import 'package:tabs_lab/src/features/home/layered_bandit_view.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Gem Store (Nov 27, 2026): replaces the gem popup as the gem
/// pill's destination (the pill + its balance display stay on
/// Home). Structure per the founder-approved mock + Juno's FINAL
/// ruling (build-gem-store/JUNO-COPY.md — § numbers in comments):
/// header + balance pill; "Your Bandit" hero (preview selection,
/// animation playing); "Your Chests" row → the chest inbox;
/// Streak Freeze card (the EXISTING freeze spend path —
/// [GemService.spendOnFreeze] with the gems sheet's
/// push-settled-first discipline, not a rebuild); item sections
/// Bandit Colors / Chairs / Books / Sunglasses; and the
/// About-gems footer (§11 — the explainer's home after the popup
/// it replaces goes away).
///
/// Preview discipline: the hero shows the PREVIEW selection,
/// which starts at the equipped look. Tapping any item applies
/// it to the preview (try-on is free and unlimited, §14) and
/// opens its detail view. Preview ≠ equipped until an equip or
/// a purchase completes — buying equips immediately (§4 #25
/// "Buy & Equip", §8).
class GemStoreScreen extends StatefulWidget {
  final GemService? gemService;
  final CosmeticsService? cosmeticsService;
  final ChestService? chestService;
  final StreakState? streakState;
  final String? nickname;
  final GemsSheetStreakPush? streakPush;

  const GemStoreScreen({
    super.key,
    this.gemService,
    this.cosmeticsService,
    this.chestService,
    this.streakState,
    this.nickname,
    this.streakPush,
  });

  static Future<void> show(
    BuildContext context, {
    GemService? gemService,
    CosmeticsService? cosmeticsService,
    ChestService? chestService,
    StreakState? streakState,
    String? nickname,
    GemsSheetStreakPush? streakPush,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => GemStoreScreen(
          gemService: gemService,
          cosmeticsService: cosmeticsService,
          chestService: chestService,
          streakState: streakState,
          nickname: nickname,
          streakPush: streakPush,
        ),
      ),
    );
  }

  @override
  State<GemStoreScreen> createState() => _GemStoreScreenState();
}

class _GemStoreScreenState extends State<GemStoreScreen> {
  late final GemService _gems;
  late final CosmeticsService _cosmetics;
  late final ChestService _chests;

  BanditSelection? _preview;
  bool _previewTouched = false;
  bool _loadFailed = false;

  // Freeze card state (gems-sheet parity).
  bool _freezeBusy = false;
  int? _freezeSuccessBalance;
  int? _adoptedPurchased;

  // Equip failure banner (Juno §9 #45) for card-level equips;
  // the detail view carries its own failure row.
  CosmeticSlot? _equipErrorSlot;
  CosmeticItem? _equipErrorItem;

  @override
  void initState() {
    super.initState();
    _gems = widget.gemService ?? GemService.instance;
    _cosmetics = widget.cosmeticsService ?? CosmeticsService.instance;
    _chests = widget.chestService ?? ChestService.instance;
    _gems.addListener(_onChanged);
    _cosmetics.addListener(_onChanged);
    _chests.addListener(_onChanged);
    _preview = _cosmetics.equipped;
    unawaited(_load());
  }

  @override
  void dispose() {
    _gems.removeListener(_onChanged);
    _cosmetics.removeListener(_onChanged);
    _chests.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => _loadFailed = false);
    final ok = await _cosmetics.refreshFromProfile();
    unawaited(_gems.refreshBalance());
    unawaited(_chests.syncInventory());
    if (!mounted) return;
    setState(() {
      // §9 #47: a failed load with NO server payload yet shows
      // the ruled error + retry — never an empty store, a zero
      // balance, or prices from stale local state.
      _loadFailed = !ok && !_cosmetics.loaded;
      // Until the user previews anything, the hero follows the
      // equipped look the payload carries.
      if (!_previewTouched) _preview = _cosmetics.equipped;
    });
  }

  BanditSelection get _previewSelection => _preview ?? _cosmetics.equipped;

  // ── Freeze (existing spend path, gems-sheet discipline) ─────

  StreakState? get _baseState => widget.streakState ?? StreakStore.instance.state;

  StreakState? get _effectiveState {
    final base = _baseState;
    if (base == null) return null;
    final adopted = _adoptedPurchased;
    if (adopted == null || adopted == base.purchasedFreezes) return base;
    return base.copyWith(purchasedFreezes: adopted.clamp(0, 3));
  }

  Future<void> _pushSettledBeforeSpend(StreakState effective) async {
    try {
      final push =
          widget.streakPush ??
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

  Future<void> _buyFreeze() async {
    if (_freezeBusy) return;
    setState(() => _freezeBusy = true);
    try {
      final effective = _effectiveState;
      if (effective != null) await _pushSettledBeforeSpend(effective);
      final result = await _gems.spendOnFreeze();
      if (!mounted) return;
      final freezes = result.purchasedFreezes;
      if (freezes != null) {
        _adoptedPurchased = freezes.clamp(0, 3);
        unawaited(StreakStore.instance.adoptPurchasedFreezes(freezes));
      }
      switch (result.status) {
        case GemSpendStatus.success:
        case GemSpendStatus.replay:
          if (result.balance != null) {
            _freezeSuccessBalance = result.balance;
          } else {
            unawaited(_gems.refreshBalance());
          }
          final adopted = StreakStore.instance.state;
          if (adopted != null) {
            unawaited(
              WidgetSync.pushStreak(
                adopted.copyWith(
                  purchasedFreezes: (freezes ?? adopted.purchasedFreezes)
                      .clamp(0, 3),
                ),
                signedIn: true,
                nickname: widget.nickname,
                now: DateTime.now(),
              ),
            );
          }
        case GemSpendStatus.capReached:
          unawaited(_gems.refreshBalance());
        case GemSpendStatus.insufficient:
        case GemSpendStatus.failed:
          break;
      }
      if (mounted) setState(() {});
    } finally {
      if (mounted) setState(() => _freezeBusy = false);
    }
  }

  // ── Equip (card level) ──────────────────────────────────────

  Future<void> _equip(CosmeticSlot slot, CosmeticItem? item) async {
    setState(() {
      _equipErrorSlot = null;
      _equipErrorItem = null;
    });
    final ok = await _cosmetics.equip(slot, item);
    if (!mounted) return;
    if (ok) {
      setState(() => _preview = _cosmetics.equipped);
    } else {
      // §9 #45: the service already rolled the optimistic flip
      // back; surface the ruled failure + retry.
      setState(() {
        _equipErrorSlot = slot;
        _equipErrorItem = item;
      });
    }
  }

  // ── Detail ──────────────────────────────────────────────────

  Future<void> _openDetail(CosmeticItem? item, CosmeticSlot slot) async {
    // Tapping any item applies it to the preview first (the
    // hero tries it on behind the detail sheet).
    _previewTouched = true;
    setState(() => _preview = _previewSelection.withItem(item, slot));
    await showGemStoreItemDetail(
      context: context,
      item: item,
      slot: slot,
      gemService: _gems,
      cosmeticsService: _cosmetics,
      previewSelection: _previewSelection,
    );
    if (!mounted) return;
    // A purchase/equip inside the detail moves the equipped
    // look; the hero preview follows it.
    setState(() => _preview = _cosmetics.equipped);
  }

  @override
  Widget build(BuildContext context) {
    final balance = _gems.balance;
    return Scaffold(
      key: const Key('gemStoreScreen'),
      backgroundColor: NotelColors.background,
      appBar: AppBar(
        backgroundColor: NotelColors.background,
        title: Text(
          StoreCopy.storeTitle,
          style: TextStyle(
            fontSize: 19,
            fontWeight: FontWeight.w800,
            color: NotelColors.textPrimary,
          ),
        ),
        actions: [
          if (balance != null)
            Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Semantics(
                  label: GemCopy.pillLabel(balance),
                  child: Container(
                    key: const Key('gemStoreBalancePill'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: NotelColors.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: NotelColors.cardBorder),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          GemCopy.iconAsset,
                          width: 16,
                          height: 16,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '$balance',
                          style: TextStyle(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                            color: NotelColors.textPrimary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: _loadFailed ? _loadError() : _body(balance),
    );
  }

  Widget _loadError() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            StoreCopy.loadFailedLine,
            key: Key('gemStoreLoadError'),
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: NotelColors.textSecondary,
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            key: const Key('gemStoreLoadRetry'),
            onPressed: () => unawaited(_load()),
            child: const Text(StoreCopy.tryAgainLabel),
          ),
        ],
      ),
    );
  }

  Widget _body(int? balance) {
    final equipped = _cosmetics.equipped;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        _hero(equipped),
        if (_equipErrorSlot != null) ...[
          const SizedBox(height: 12),
          _equipErrorBanner(),
        ],
        const SizedBox(height: 12),
        _chestsRow(),
        const SizedBox(height: 12),
        _freezeCard(balance),
        _section(
          slot: CosmeticSlot.bandit,
          title: StoreCopy.banditSection,
          sub: StoreCopy.banditSectionSub,
          items: CosmeticCatalog.bandits,
          balance: balance,
        ),
        _section(
          slot: CosmeticSlot.chair,
          title: StoreCopy.chairsSection,
          sub: StoreCopy.chairsSectionSub,
          items: CosmeticCatalog.chairs,
          balance: balance,
        ),
        _section(
          slot: CosmeticSlot.book,
          title: StoreCopy.booksSection,
          sub: StoreCopy.booksSectionSub,
          items: CosmeticCatalog.books,
          balance: balance,
        ),
        _shadesSection(balance),
        const SizedBox(height: 28),
        _aboutFooter(),
      ],
    );
  }

  Widget _hero(BanditSelection equipped) {
    return Container(
      key: const Key('gemStoreHero'),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: SizedBox(
              width: 250,
              child: LayeredBanditView(
                selection: _previewSelection,
                animate: true,
                semanticLabel: StoreCopy.heroLabel(equipped),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  StoreCopy.heroTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: NotelColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  StoreCopy.heroLine,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: NotelColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    _chip(StoreCopy.chipBandit(equipped.bandit.name)),
                    _chip(StoreCopy.chipChair(equipped.chair.name)),
                    _chip(StoreCopy.chipBook(equipped.book.name)),
                    _chip(
                      StoreCopy.chipShades(
                        equipped.shades?.name ?? StoreCopy.noneName,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: NotelColors.surfaceHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: NotelColors.textSecondary,
        ),
      ),
    );
  }

  Widget _equipErrorBanner() {
    return Container(
      key: const Key('gemStoreEquipError'),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: NotelColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: NotelColors.cardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              StoreCopy.equipFailedLine,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: NotelColors.textPrimary,
              ),
            ),
          ),
          TextButton(
            key: const Key('gemStoreEquipErrorRetry'),
            onPressed: () =>
                unawaited(_equip(_equipErrorSlot!, _equipErrorItem)),
            child: const Text(StoreCopy.tryAgainLabel),
          ),
          TextButton(
            key: const Key('gemStoreEquipErrorLater'),
            onPressed: () => setState(() {
              _equipErrorSlot = null;
              _equipErrorItem = null;
            }),
            child: const Text(StoreCopy.laterLabel),
          ),
        ],
      ),
    );
  }

  Widget _chestsRow() {
    final count = _chests.totalCount;
    return Semantics(
      label: StoreCopy.chestsRowLabel(count),
      child: InkWell(
        key: const Key('gemStoreChestsRow'),
        borderRadius: BorderRadius.circular(18),
        onTap: () => unawaited(showChestsSheet(context: context)),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: NotelColors.cardBorder),
          ),
          child: Row(
            children: [
              Image.asset(
                'assets/chests/chest_daily.png',
                width: 44,
                height: 44,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox(width: 44, height: 44),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      StoreCopy.chestsRowTitle,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: NotelColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      StoreCopy.chestsRowSubtitle(count),
                      key: const Key('gemStoreChestsSubtitle'),
                      style: TextStyle(
                        fontSize: 12.5,
                        color: NotelColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: NotelColors.textSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Streak Freeze card (§3) ─────────────────────────────────

  Widget _freezeCard(int? balance) {
    final effective = _effectiveState;
    // §3 #20: {n} is TOTAL available cover (monthly grant +
    // earned + purchased) — the streak screen headline's number.
    final totalCover = effective == null
        ? null
        : totalAvailableCover(effective, DateTime.now());
    // §3 at-cap: enforced by ABSENCE — at cap the price + Buy do
    // not render; no at-cap string exists and none is invented.
    final atCap =
        effective != null && totalCover! >= streakCap(effective);
    final showBuy = effective != null && !atCap && balance != null;
    final insufficient = balance != null && balance < GemCopy.freezePrice;
    return Semantics(
      label: totalCover == null ? null : StoreCopy.freezeLabel(totalCover),
      child: Container(
        key: const Key('gemStoreFreezeCard'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: NotelColors.surface,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: NotelColors.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        StoreCopy.freezeTitle,
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w700,
                          color: NotelColors.textPrimary,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        StoreCopy.freezeSubtitle,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: NotelColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (showBuy) ...[
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Image.asset(GemCopy.iconAsset, width: 15, height: 15),
                      const SizedBox(width: 5),
                      Text(
                        '${GemCopy.freezePrice}',
                        style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: FontWeight.w800,
                          color: NotelColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  FilledButton(
                    key: const Key('gemStoreFreezeBuy'),
                    onPressed: (insufficient || _freezeBusy)
                        ? null
                        : () => unawaited(_buyFreeze()),
                    child: const Text(StoreCopy.freezeBuyLabel),
                  ),
                ],
              ],
            ),
            if (totalCover != null) ...[
              const SizedBox(height: 8),
              Text(
                StoreCopy.freezeOwnedLine(totalCover),
                key: const Key('gemStoreFreezeOwned'),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: NotelColors.textSecondary,
                ),
              ),
            ],
            // §3 feedback reuses GemCopy verbatim (success only on
            // a verified spend — the gems-sheet discipline).
            if (_freezeSuccessBalance != null) ...[
              const SizedBox(height: 10),
              Text(
                GemCopy.spendSuccessTitle,
                key: Key('gemStoreFreezeSuccessTitle'),
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                  color: NotelColors.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                GemCopy.spendSuccessBody(_freezeSuccessBalance!),
                key: const Key('gemStoreFreezeSuccessBody'),
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: NotelColors.textSecondary,
                ),
              ),
            ],
            if (showBuy && insufficient) ...[
              const SizedBox(height: 8),
              Text(
                GemCopy.insufficientLine(GemCopy.freezePrice - balance),
                key: const Key('gemStoreFreezeInsufficient'),
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: NotelColors.textSecondary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Item sections (§1, §4, §5) ──────────────────────────────

  Widget _section({
    required CosmeticSlot slot,
    required String title,
    required String sub,
    required List<CosmeticItem> items,
    required int? balance,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          title,
          key: Key('gemStoreSection-${slot.wireName}'),
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: NotelColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          sub,
          style: TextStyle(
            fontSize: 12.5,
            color: NotelColors.textSecondary,
          ),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.78,
          children: [
            for (final item in items) _itemCard(item, balance),
          ],
        ),
      ],
    );
  }

  /// Sunglasses (§5 + §12): FOUR cards — None first (the owned
  /// default / unequip path), then the purchasables in ascending
  /// price order.
  Widget _shadesSection(int? balance) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 24),
        Text(
          StoreCopy.shadesSection,
          key: const Key('gemStoreSection-shades'),
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            color: NotelColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          StoreCopy.shadesSectionSub,
          style: TextStyle(fontSize: 12.5, color: NotelColors.textSecondary),
        ),
        const SizedBox(height: 12),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.78,
          children: [
            _noneCard(),
            for (final item in CosmeticCatalog.shades)
              _itemCard(item, balance),
          ],
        ),
      ],
    );
  }

  Widget _noneCard() {
    final shadesEquipped = _cosmetics.equipped.shades != null;
    return Semantics(
      label: shadesEquipped
          ? StoreCopy.noneCardLabelEquipped
          : StoreCopy.cardLabel(
              name: StoreCopy.noneName,
              price: 0,
              owned: true,
              equipped: !shadesEquipped,
            ),
      child: InkWell(
        key: const Key('storeCard-none'),
        borderRadius: BorderRadius.circular(18),
        onTap: () => unawaited(_openDetail(null, CosmeticSlot.shades)),
        child: Container(
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: NotelColors.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(18),
                  ),
                  child: LayeredBanditView(
                    selection: _previewSelection.withItem(
                      null,
                      CosmeticSlot.shades,
                    ),
                    animate: false,
                    excludeSemantics: true,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      StoreCopy.noneName,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: NotelColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        Text(
                          StoreCopy.ownedLabel,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: NotelColors.textSecondary,
                          ),
                        ),
                        const Spacer(),
                        if (!shadesEquipped)
                          _stateChip(StoreCopy.equippedChip, filled: true)
                        else
                          _stateChip(
                            StoreCopy.equipChip,
                            filled: false,
                            onTap: () =>
                                unawaited(_equip(CosmeticSlot.shades, null)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _itemCard(CosmeticItem item, int? balance) {
    final owned = _cosmetics.owns(item);
    final equippedNow = _cosmetics.isEquipped(item);
    final insufficient =
        !owned && balance != null && balance < item.price;
    return Semantics(
      label: StoreCopy.cardLabel(
        name: item.name,
        price: item.price,
        owned: owned,
        equipped: equippedNow,
      ),
      child: InkWell(
        key: Key('storeCard-${item.id}'),
        borderRadius: BorderRadius.circular(18),
        onTap: () => unawaited(_openDetail(item, item.slot)),
        child: Container(
          decoration: BoxDecoration(
            color: NotelColors.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: NotelColors.cardBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Card preview (§ brief): the layered view with
              // motion OFF and the preview-selection-with-this-
              // item-applied — a Bandit color shows on the
              // current preview chair/book, per the mock's rules.
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(18),
                  ),
                  child: LayeredBanditView(
                    selection: _previewSelection.withItem(item, item.slot),
                    animate: false,
                    excludeSemantics: true,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: NotelColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Row(
                      children: [
                        if (!owned)
                          // §4 #21: gem icon + price, no "gems"
                          // word. Insufficient balance dims it
                          // (the buy itself disables in detail).
                          Opacity(
                            opacity: insufficient ? 0.45 : 1,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Image.asset(
                                  GemCopy.iconAsset,
                                  width: 15,
                                  height: 15,
                                ),
                                const SizedBox(width: 5),
                                Text(
                                  '${item.price}',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: NotelColors.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          Text(
                            StoreCopy.ownedLabel,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: NotelColors.textSecondary,
                            ),
                          ),
                        const Spacer(),
                        if (equippedNow)
                          _stateChip(StoreCopy.equippedChip, filled: true)
                        else if (owned)
                          _stateChip(
                            StoreCopy.equipChip,
                            filled: false,
                            onTap: () =>
                                unawaited(_equip(item.slot, item)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stateChip(String text, {required bool filled, VoidCallback? onTap}) {
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: filled ? NotelColors.primary : Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: NotelColors.primary),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: filled ? Colors.white : NotelColors.primaryText,
        ),
      ),
    );
    if (onTap == null) return chip;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: chip,
    );
  }

  // ── Footer (§11) ────────────────────────────────────────────

  /// The About-gems explainer, verbatim from GemCopy — the
  /// store replaces the gem popup, which was its only home, so
  /// it lives at the bottom of this scroll (Juno §11).
  Widget _aboutFooter() {
    final lines = GemCopy.sheetExplainerLines;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          GemCopy.explainerHeading,
          key: Key('gemStoreAboutHeading'),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: NotelColors.textPrimary,
          ),
        ),
        const SizedBox(height: 10),
        for (var i = 0; i < lines.length; i++) ...[
          Text(
            lines[i],
            key: Key('gemStoreAboutLine$i'),
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              height: 1.45,
              color: NotelColors.textSecondary,
            ),
          ),
          if (i < lines.length - 1) const SizedBox(height: 6),
        ],
      ],
    );
  }
}

/// Item detail view (Juno §6, per the approved detail mock):
/// header = the section name; eyebrow; item name; an animated
/// preview of the preview-selection-with-this-item; the §6 #33
/// caption; the item description (#35); the combine note (#34);
/// and the buy/equip bar (#25–#29) with the after-buying line
/// (#26), the insufficient line (§7), success (§8) and failure
/// (§9) states.
Future<void> showGemStoreItemDetail({
  required BuildContext context,
  required CosmeticItem? item,
  required CosmeticSlot slot,
  required GemService gemService,
  required CosmeticsService cosmeticsService,
  required BanditSelection previewSelection,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: NotelColors.surface,
    isScrollControlled: true,
    builder: (_) => GemStoreItemDetail(
      item: item,
      slot: slot,
      gemService: gemService,
      cosmeticsService: cosmeticsService,
      previewSelection: previewSelection,
    ),
  );
}

class GemStoreItemDetail extends StatefulWidget {
  /// Null = the shades None detail.
  final CosmeticItem? item;
  final CosmeticSlot slot;
  final GemService gemService;
  final CosmeticsService cosmeticsService;
  final BanditSelection previewSelection;

  const GemStoreItemDetail({
    super.key,
    required this.item,
    required this.slot,
    required this.gemService,
    required this.cosmeticsService,
    required this.previewSelection,
  });

  @override
  State<GemStoreItemDetail> createState() => _GemStoreItemDetailState();
}

class _GemStoreItemDetailState extends State<GemStoreItemDetail> {
  bool _busy = false;
  int? _successBalance;
  bool _purchaseFailed = false;
  bool _equipFailed = false;

  GemService get _gems => widget.gemService;
  CosmeticsService get _cosmetics => widget.cosmeticsService;

  @override
  void initState() {
    super.initState();
    _gems.addListener(_onChanged);
    _cosmetics.addListener(_onChanged);
  }

  @override
  void dispose() {
    _gems.removeListener(_onChanged);
    _cosmetics.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  String get _sectionTitle => switch (widget.slot) {
    CosmeticSlot.bandit => StoreCopy.banditSection,
    CosmeticSlot.chair => StoreCopy.chairsSection,
    CosmeticSlot.book => StoreCopy.booksSection,
    CosmeticSlot.shades => StoreCopy.shadesSection,
  };

  Future<void> _buy() async {
    final item = widget.item;
    if (item == null || _busy) return;
    setState(() {
      _busy = true;
      _purchaseFailed = false;
    });
    final result = await _cosmetics.purchase(item);
    if (!mounted) return;
    setState(() => _busy = false);
    switch (result.status) {
      case StorePurchaseStatus.success:
        // §8: fires only on the VERIFIED server purchase; the
        // balance is the response's server balance.
        setState(() => _successBalance = result.balance ?? _gems.balance);
      case StorePurchaseStatus.insufficient:
        // The balance moved under us; the insufficient line now
        // renders from the adopted server balance (the button
        // disables) — no separate failure state.
        break;
      case StorePurchaseStatus.alreadyOwned:
        // Already owned (adopted + equipped by the service):
        // the action bar re-renders as Equipped from state; no
        // success copy — no debit happened on this call (§8
        // fires only on a verified purchase).
        break;
      case StorePurchaseStatus.failed:
        // §9 #42: one string for server error and offline; the
        // attempt key survives in the service, so Try again
        // retries THIS attempt (same idempotency key).
        setState(() => _purchaseFailed = true);
    }
  }

  Future<void> _equip() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _equipFailed = false;
    });
    final ok = await _cosmetics.equip(widget.slot, widget.item);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _equipFailed = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final slot = widget.slot;
    final balance = _gems.balance;
    final owned = item == null || _cosmetics.owns(item);
    final equippedNow = item == null
        ? _cosmetics.equipped.shades == null
        : _cosmetics.isEquipped(item);
    final name = item?.name ?? StoreCopy.noneName;
    final description = item?.description ??
        CosmeticCatalog.noneShadesDescription;
    final preview = widget.previewSelection.withItem(item, slot);
    final insufficient =
        item != null && balance != null && balance < item.price;

    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            key: const Key('gemStoreDetail'),
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _sectionTitle,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: NotelColors.textSecondary,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              Center(
                child: SizedBox(
                  width: 230,
                  child: LayeredBanditView(
                    selection: preview,
                    animate: true,
                    excludeSemantics: true,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                detailCaption(previewed: slot, equipped: _cosmetics.equipped),
                key: const Key('detailCaption'),
                style: TextStyle(
                  fontSize: 12.5,
                  color: NotelColors.textSecondary,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                StoreCopy.eyebrow(slot),
                key: const Key('detailEyebrow'),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: NotelColors.primaryText,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                name,
                key: const Key('detailName'),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: NotelColors.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                description,
                key: const Key('detailDescription'),
                style: TextStyle(
                  fontSize: 14,
                  height: 1.45,
                  color: NotelColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                StoreCopy.combineNote,
                key: Key('detailCombineNote'),
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: NotelColors.textSecondary,
                ),
              ),
              const SizedBox(height: 18),
              if (_successBalance != null) ...[
                Text(
                  StoreCopy.purchaseSuccessTitle,
                  key: Key('detailSuccessTitle'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: NotelColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  StoreCopy.purchaseSuccessBody(name, _successBalance!),
                  key: const Key('detailSuccessBody'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: NotelColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (_purchaseFailed) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        StoreCopy.purchaseFailedLine,
                        key: Key('detailPurchaseFailure'),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: NotelColors.textPrimary,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('detailFailureRetry'),
                      onPressed: _busy ? null : () => unawaited(_buy()),
                      child: const Text(StoreCopy.tryAgainLabel),
                    ),
                    TextButton(
                      key: const Key('detailFailureLater'),
                      onPressed: () {
                        // "Later" ends the attempt: the next buy
                        // is a NEW attempt with a fresh key.
                        if (item != null) {
                          _cosmetics.abandonPurchaseAttempt(item.id);
                        }
                        Navigator.of(context).pop();
                      },
                      child: const Text(StoreCopy.laterLabel),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (_equipFailed) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        StoreCopy.equipFailedLine,
                        key: Key('detailEquipFailure'),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: NotelColors.textPrimary,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('detailEquipRetry'),
                      onPressed: _busy ? null : () => unawaited(_equip()),
                      child: const Text(StoreCopy.tryAgainLabel),
                    ),
                    TextButton(
                      key: const Key('detailEquipLater'),
                      onPressed: () =>
                          setState(() => _equipFailed = false),
                      child: const Text(StoreCopy.laterLabel),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              _actionBar(
                item: item,
                owned: owned,
                equippedNow: equippedNow,
                balance: balance,
                insufficient: insufficient,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _actionBar({
    required CosmeticItem? item,
    required bool owned,
    required bool equippedNow,
    required int? balance,
    required bool insufficient,
  }) {
    if (equippedNow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            key: const Key('detailEquippedButton'),
            onPressed: null,
            child: const Text(StoreCopy.equippedLabel),
          ),
          // §4 #29: the equipped pair's own Take off (shades
          // items only; the None card is the primary path).
          if (item != null && item.slot == CosmeticSlot.shades) ...[
            const SizedBox(height: 8),
            TextButton(
              key: const Key('detailTakeOffButton'),
              onPressed: _busy
                  ? null
                  : () async {
                      setState(() => _busy = true);
                      final ok = await _cosmetics.equip(
                        CosmeticSlot.shades,
                        null,
                      );
                      if (!mounted) return;
                      setState(() {
                        _busy = false;
                        _equipFailed = !ok;
                      });
                    },
              child: const Text(StoreCopy.takeOffLabel),
            ),
          ],
        ],
      );
    }
    if (owned) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          key: const Key('detailEquipButton'),
          onPressed: _busy ? null : () => unawaited(_equip()),
          child: const Text(StoreCopy.equipLabel),
        ),
      );
    }
    // Unowned: Buy & Equip (#25), disabled while the balance is
    // short (§7), with the after-buying line (#26) or the
    // insufficient line (§7) under the bar.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Image.asset(GemCopy.iconAsset, width: 17, height: 17),
            const SizedBox(width: 6),
            Text(
              '${item!.price}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: NotelColors.textPrimary,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: FilledButton(
                key: const Key('detailBuyButton'),
                onPressed: (_busy || insufficient)
                    ? null
                    : () => unawaited(_buy()),
                child: const Text(StoreCopy.buyAndEquipLabel),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (insufficient)
          Text(
            StoreCopy.insufficientForItem(item.price - balance!),
            key: const Key('detailInsufficient'),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: NotelColors.textSecondary,
            ),
          )
        else if (balance != null)
          Text(
            StoreCopy.afterBuyingLine(balance - item.price),
            key: const Key('detailAfterBuying'),
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: NotelColors.textSecondary,
            ),
          ),
      ],
    );
  }
}
