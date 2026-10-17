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
  String _selectedProductId = BillingProducts.monthly;
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

  BillingProduct? get _selectedProduct =>
      _state.productById(_selectedProductId) ??
      (_state.products.isEmpty ? null : _state.products.first);

  /// The user's pick for the selected product: the explicitly
  /// chosen offer, or the product's ONLY offer (an unambiguous
  /// pick, not a silent first-grab). Null while a multi-offer
  /// product awaits the user's choice.
  BillingOffer? get _selectedOffer {
    final product = _selectedProduct;
    if (product == null || product.offers.isEmpty) return null;
    for (final offer in product.offers) {
      if (offer.offerToken == _selectedOfferToken) return offer;
    }
    return product.offers.length == 1 ? product.offers.single : null;
  }

  void _selectProduct(String productId) {
    setState(() {
      _selectedProductId = productId;
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
    final product = _selectedProduct;
    final offer = _selectedOffer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in state.products) ...[
          _planCard(p),
          const SizedBox(height: 12),
        ],
        if (state.products.isEmpty &&
            state.phase != BillingPhase.loadingCatalog)
          const Text(
            'Pricing shown in Google Play',
            textAlign: TextAlign.center,
            style: TextStyle(color: NotelColors.textSecondary, fontSize: 13),
          ),
        if (product != null && product.offers.length > 1) ...[
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
          for (final o in product.offers) ...[
            _offerRow(product, o),
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
    final product = _selectedProduct;
    final name = product == null
        ? 'Plan'
        : (product.isMonthly
            ? 'Monthly'
            : product.isYearly
                ? 'Yearly'
                : product.title);
    return '$name: $summary. Auto-renews until canceled. '
        'Billed by Google Play.';
  }

  Widget _planCard(BillingProduct product) {
    final selected = _selectedProduct?.id == product.id;
    final bool isSelectedProduct = selected;
    final offer = isSelectedProduct ? _selectedOffer : null;
    // Price line: the chosen offer's real summary; for the
    // non-selected plan, its single offer's summary when it has
    // exactly one (unambiguous), else the honest fallback.
    final BillingOffer? displayOffer = offer ??
        (product.offers.length == 1 ? product.offers.single : null);
    final priceLine = displayOffer?.summaryLabel ?? 'Pricing shown in Google Play';
    final chip = _chipFor(product, displayOffer);
    return GestureDetector(
      onTap: () => _selectProduct(product.id),
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
                    product.isMonthly
                        ? 'Monthly Plan'
                        : product.isYearly
                            ? 'Yearly Plan'
                            : product.title,
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
                  if (product.offers.length > 1)
                    Text(
                      '${product.offers.length} offers — tap to choose',
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

  /// Chips are data-driven too: "FREE TRIAL" only when the offer
  /// Play returned actually has a free phase; the yearly savings
  /// chip only when both recurring prices are really known
  /// (native computes it from live catalog prices).
  (String, Color)? _chipFor(BillingProduct product, BillingOffer? offer) {
    if (product.isMonthly) {
      if (offer?.hasFreeTrial ?? false) {
        return ('FREE TRIAL', NotelColors.primary);
      }
      return null;
    }
    if (product.isYearly) {
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
    final monthly = _state.productById(BillingProducts.monthly);
    final yearly = _state.productById(BillingProducts.yearly);
    if (monthly == null || yearly == null) return null;
    int? recurringMicros(BillingProduct p) {
      if (p.offers.length != 1) return null;
      return p.offers.single.recurringPhase?.priceAmountMicros;
    }

    final m = recurringMicros(monthly);
    final y = recurringMicros(yearly);
    if (m == null || y == null || m <= 0 || y <= 0) return null;
    final pct = (1 - y / (m * 12)) * 100;
    return pct.round();
  }

  Widget _offerRow(BillingProduct product, BillingOffer offer) {
    final selected = _selectedOfferToken == offer.offerToken ||
        (product.offers.length == 1);
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
