import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tabs_lab/src/data/billing_models.dart';
import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Takeover Phase 2 (Ari) — the shared plan-picker used by Settings
/// → Membership and the onboarding paywall in the PRODUCTION build.
///
/// Everything price/trial-shaped on this panel comes from the real
/// Play catalog ([BillingState.products], loaded by
/// [BillingService]): prices, trial lengths, and offer labels are
/// read off the actual `ProductDetails` the store returned. There
/// is deliberately NO hardcoded trial label and NO hardcoded price
/// anywhere in this widget — when the catalog has not loaded (or an
/// offer carries no usable phase data) the panel falls back to
/// native's own honest line, "Pricing shown in Google Play", and a
/// plain "Subscribe" CTA that claims neither a trial nor a price.
///
/// Offer picking (Phase 2 requirement): when Play returns several
/// offers for the selected plan, each renders as its own selectable
/// row with its real summary, and the CTA stays disabled until the
/// user picks one. The code never silently takes the first offer —
/// the one native behavior (`firstOrNull()`) this port must not
/// reproduce.
class BillingPlansPanel extends StatefulWidget {
  final BillingService service;

  /// Fired once when the service reports the account is unlimited
  /// (onboarding auto-advances; Settings reloads its data).
  final VoidCallback? onUnlimited;

  /// Key for the subscribe CTA (Settings tests address it).
  final Key? ctaKey;

  const BillingPlansPanel({
    super.key,
    required this.service,
    this.onUnlimited,
    this.ctaKey,
  });

  @override
  State<BillingPlansPanel> createState() => _BillingPlansPanelState();
}

class _BillingPlansPanelState extends State<BillingPlansPanel> {
  StreamSubscription<BillingState>? _sub;
  String? _selectedBasePlanId;
  bool _hasSelectedGroup = false;
  String? _selectedOfferToken;
  bool _unlimitedFired = false;

  BillingService get _service => widget.service;
  BillingState get _state => _service.state;

  @override
  void initState() {
    super.initState();
    _sub = _service.states.listen((_) {
      if (!mounted) return;
      setState(() {});
      _maybeFireUnlimited();
    });
    if (_state.phase == BillingPhase.idle) {
      unawaited(_service.initialize());
    }
    _maybeFireUnlimited();
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel());
    super.dispose();
  }

  void _maybeFireUnlimited() {
    if (_state.isUnlimited == true && !_unlimitedFired) {
      _unlimitedFired = true;
      widget.onUnlimited?.call();
    }
  }

  /// The ONE product this panel works with: the verified catalog
  /// product, or the first product if Play returned products under
  /// any other shape. Monthly and yearly are base-plan groups
  /// WITHIN this product, not separate products.
  BillingProduct? get _theProduct =>
      _state.productById(BillingProducts.monthly) ??
      (_state.products.isEmpty ? null : _state.products.first);

  /// The product's offers grouped by base-plan ID, ordered: the
  /// group whose offers recur P1M (Monthly) first, then the P1Y
  /// group (Yearly), then any other groups in first-seen order.
  List<_PlanGroup> get _groups => _groupsFor(_theProduct);

  List<_PlanGroup> _groupsFor(BillingProduct? product) {
    if (product == null || product.offers.isEmpty) return const [];
    final byBasePlan = <String?, List<BillingOffer>>{};
    for (final offer in product.offers) {
      byBasePlan.putIfAbsent(offer.basePlanId, () => []).add(offer);
    }
    final groups = <_PlanGroup>[
      for (final entry in byBasePlan.entries)
        _PlanGroup(entry.key, entry.value),
    ];
    // Dart's sort is not stable, so decorate with the first-seen
    // index to keep unranked groups in their original order.
    final decorated = <(int, _PlanGroup)>[
      for (var i = 0; i < groups.length; i++) (i, groups[i]),
    ];
    decorated.sort((a, b) {
      final rank = a.$2.orderRank.compareTo(b.$2.orderRank);
      return rank != 0 ? rank : a.$1.compareTo(b.$1);
    });
    return [for (final d in decorated) d.$2];
  }

  /// The selected base-plan group: the user's explicit pick when
  /// it still exists, else the monthly (P1M) group if present,
  /// else the first group.
  _PlanGroup? get _selectedGroup {
    final groups = _groups;
    if (groups.isEmpty) return null;
    if (_hasSelectedGroup) {
      for (final group in groups) {
        if (group.basePlanId == _selectedBasePlanId) return group;
      }
    }
    for (final group in groups) {
      if (group.recursMonthly) return group;
    }
    return groups.first;
  }

  /// The user's pick for the selected group: the explicitly
  /// chosen offer WITHIN that group, or the group's ONLY offer
  /// (an unambiguous pick, not a silent first-grab). Null while a
  /// multi-offer group awaits the user's choice.
  BillingOffer? get _selectedOffer {
    final group = _selectedGroup;
    if (group == null || group.offers.isEmpty) return null;
    for (final offer in group.offers) {
      if (offer.offerToken == _selectedOfferToken) return offer;
    }
    return group.offers.length == 1 ? group.offers.single : null;
  }

  void _selectGroup(_PlanGroup group) {
    setState(() {
      _selectedBasePlanId = group.basePlanId;
      _hasSelectedGroup = true;
      _selectedOfferToken = null;
    });
  }

  String get _ctaLabel {
    final state = _state;
    if (state.phase == BillingPhase.loadingCatalog) return 'Loading plans…';
    if (state.phase == BillingPhase.purchasing) {
      return 'Waiting for Google Play…';
    }
    if (state.phase == BillingPhase.verifying) return 'Verifying purchase…';
    final offer = _selectedOffer;
    if (offer == null) {
      return state.products.isEmpty ? 'Plans unavailable' : 'Choose a plan option';
    }
    final trial = offer.trialCtaLabel;
    if (trial != null) return 'Start $trial';
    final recurring = offer.recurringPhase;
    if (recurring != null) {
      final noun = billingPeriodNoun(recurring.billingPeriod);
      if (noun != null) return 'Subscribe — ${recurring.formattedPrice}/$noun';
    }
    return 'Subscribe';
  }

  bool get _ctaEnabled {
    final phase = _state.phase;
    return _selectedOffer != null &&
        phase != BillingPhase.loadingCatalog &&
        phase != BillingPhase.purchasing &&
        phase != BillingPhase.verifying;
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    final product = _theProduct;
    final offer = _selectedOffer;
    final groups = _groups;
    final selectedGroup = _selectedGroup;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (product != null)
          for (final group in groups) ...[
            _planCard(product, group),
            const SizedBox(height: 12),
          ],
        if (state.products.isEmpty &&
            state.phase != BillingPhase.loadingCatalog)
          const Text(
            'Pricing shown in Google Play',
            textAlign: TextAlign.center,
            style: TextStyle(color: NotelColors.textSecondary, fontSize: 13),
          ),
        if (selectedGroup != null && selectedGroup.offers.length > 1) ...[
          const SizedBox(height: 4),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Choose an offer',
                style: TextStyle(
                    color: NotelColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(height: 8),
          for (final o in selectedGroup.offers) ...[
            _offerRow(selectedGroup, o),
            const SizedBox(height: 8),
          ],
        ],
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 54,
          child: FilledButton(
            key: widget.ctaKey,
            onPressed: _ctaEnabled
                ? () => unawaited(_service.buy(product!, offer!))
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: NotelColors.primary,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_state.phase == BillingPhase.purchasing ||
                    _state.phase == BillingPhase.verifying) ...[
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                  const SizedBox(width: 8),
                ] else ...[
                  const Icon(Icons.workspace_premium,
                      color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    _ctaLabel,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        // F-4 (legal-exposure register Q61/Q66) — the cancellation
        // METHOD belongs in the paywall block itself, adjacent to
        // the subscribe CTA, not only in Settings/Terms: ROSCA and
        // CA ARL require the cancellation policy in visual proximity
        // to the consent request. Wording is the register's
        // Q65-verified production statement, verbatim — no new
        // legal copy. It renders unconditionally (with or without
        // offer data) at the same size/contrast as the terms line
        // below it, so the block's conspicuousness is uniform.
        const Text(
          'Cancel anytime in the Play Store',
          key: ValueKey('paywall_cancel_method'),
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xBF7A8FAF), fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          _termsLine(offer),
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xBF7A8FAF), fontSize: 11),
        ),
        if (state.errorMessage != null) ...[
          const SizedBox(height: 10),
          Text(
            state.errorMessage!,
            key: const ValueKey('billing_error'),
            textAlign: TextAlign.center,
            style: const TextStyle(color: NotelColors.error, fontSize: 12),
          ),
        ],
      ],
    );
  }

  /// Terms from the SELECTED offer's real phases; the bare honest
  /// line when no offer data is available.
  String _termsLine(BillingOffer? offer) {
    final summary = offer?.summaryLabel;
    if (summary == null) {
      return 'Auto-renews until canceled. Billed by Google Play.';
    }
    final product = _theProduct;
    final group = _selectedGroup;
    final name = product == null
        ? 'Plan'
        : (group?.planName ?? product.title);
    return '$name: $summary. Auto-renews until canceled. '
        'Billed by Google Play.';
  }

  Widget _planCard(BillingProduct product, _PlanGroup group) {
    final selected = _selectedGroup?.basePlanId == group.basePlanId;
    final offer = selected ? _selectedOffer : null;
    // Price line: the chosen offer's real summary when this group
    // is selected; for a non-selected group, its single offer's
    // summary when it has exactly one (unambiguous), else the
    // honest fallback.
    final BillingOffer? displayOffer =
        offer ?? (group.offers.length == 1 ? group.offers.single : null);
    final priceLine = displayOffer?.summaryLabel ?? 'Pricing shown in Google Play';
    final chip = _chipFor(group);
    return GestureDetector(
      onTap: () => _selectGroup(group),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected
              ? NotelColors.primary.withValues(alpha: 0.08)
              : NotelColors.surfaceHigh,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? NotelColors.primary
                : NotelColors.primary.withValues(alpha: 0.15),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color:
                  selected ? NotelColors.primary : NotelColors.textSecondary,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    group.cardTitle(product.title),
                    style: const TextStyle(
                      color: NotelColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    priceLine,
                    style: const TextStyle(
                      color: NotelColors.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  if (group.offers.length > 1)
                    Text(
                      '${group.offers.length} offers — tap to choose',
                      style: const TextStyle(
                        color: NotelColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            if (chip != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: chip.$2.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  chip.$1,
                  style: TextStyle(
                    color: chip.$2,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Chips are data-driven too: "FREE TRIAL" on the monthly
  /// group only when ANY offer in that group Play returned
  /// actually has a free phase; the yearly savings chip only when
  /// both groups' recurring prices are really known within the
  /// one product (native computes it from live catalog prices).
  (String, Color)? _chipFor(_PlanGroup group) {
    if (group.recursMonthly) {
      if (group.offers.any((offer) => offer.hasFreeTrial)) {
        return ('FREE TRIAL', NotelColors.primary);
      }
      return null;
    }
    if (group.recursYearly) {
      final savings = _yearlySavingsPct();
      if (savings != null && savings > 0) {
        return ('SAVE $savings% • BEST VALUE', NotelColors.success);
      }
      // Takeover review fix (Juno): no "BEST VALUE" chip when the
      // savings are not computed from real catalog prices — an
      // unbacked value claim is not shown.
      return null;
    }
    return null;
  }

  int? _yearlySavingsPct() {
    _PlanGroup? monthly;
    _PlanGroup? yearly;
    for (final group in _groups) {
      if (group.recursMonthly) monthly = group;
      if (group.recursYearly) yearly = group;
    }
    if (monthly == null || yearly == null) return null;

    /// A group's recurring price: the UNIQUE price among its
    /// offers' recurring phases whose billing period matches the
    /// group's own recurring period. Null when no offer carries
    /// such a phase, or when the group's offers disagree on that
    /// price — ambiguous, so no savings claim (Juno's rule).
    int? recurringMicros(_PlanGroup group) {
      final period = group.recurringPeriod;
      if (period == null) return null;
      final prices = <int>{};
      for (final offer in group.offers) {
        final phase = offer.recurringPhase;
        if (phase != null && phase.billingPeriod == period) {
          prices.add(phase.priceAmountMicros);
        }
      }
      return prices.length == 1 ? prices.single : null;
    }

    final m = recurringMicros(monthly);
    final y = recurringMicros(yearly);
    if (m == null || y == null || m <= 0 || y <= 0) return null;
    final pct = (1 - y / (m * 12)) * 100;
    return pct.round();
  }

  Widget _offerRow(_PlanGroup group, BillingOffer offer) {
    final selected = _selectedOfferToken == offer.offerToken ||
        (group.offers.length == 1);
    return GestureDetector(
      key: ValueKey('billing_offer_${offer.offerToken}'),
      onTap: () => setState(() => _selectedOfferToken = offer.offerToken),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: NotelColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? NotelColors.primary
                : NotelColors.primary.withValues(alpha: 0.15),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color:
                  selected ? NotelColors.primary : NotelColors.textSecondary,
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                offer.summaryLabel ?? 'Plan option from Google Play',
                style: const TextStyle(
                  color: NotelColors.textPrimary,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One base-plan group within the single subscription product:
/// every offer Play returned that shares a base-plan ID. Monthly
/// vs yearly is derived from the group's recurring billing period
/// (P1M / P1Y) as returned in the offers' pricing phases — never
/// from hardcoded base-plan ID strings and never from a product ID.
class _PlanGroup {
  final String? basePlanId;
  final List<BillingOffer> offers;

  const _PlanGroup(this.basePlanId, this.offers);

  /// The group's recurring billing period: the billing period of
  /// the first recurring phase its offers carry (e.g. "P1M",
  /// "P1Y"). Null when no offer carries a recurring phase.
  String? get recurringPeriod {
    for (final offer in offers) {
      final period = offer.recurringPhase?.billingPeriod;
      if (period != null && period.isNotEmpty) return period;
    }
    return null;
  }

  bool get recursMonthly => recurringPeriod == 'P1M';
  bool get recursYearly => recurringPeriod == 'P1Y';

  /// Display order: monthly group first, then yearly, then any
  /// other group (ties keep first-seen order at the sort site).
  int get orderRank => recursMonthly ? 0 : (recursYearly ? 1 : 2);

  /// Short plan name from the group's period ("Monthly" /
  /// "Yearly"); null for any other period, so callers fall back
  /// to the product title.
  String? get planName =>
      recursMonthly ? 'Monthly' : (recursYearly ? 'Yearly' : null);

  String cardTitle(String productTitle) {
    final name = planName;
    return name == null ? productTitle : '$name Plan';
  }
}
