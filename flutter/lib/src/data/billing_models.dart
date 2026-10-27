/// Takeover Phase 2 (Ari) — billing domain models.
///
/// Plain Dart mirrors of what the native `BillingManager.kt` reads
/// from Play's `ProductDetails` / `SubscriptionOfferDetails`, kept
/// free of any plugin type so the billing service's call sequencing
/// is unit-testable with a fake store (see billing_service.dart).
///
/// NOTHING in this file may hardcode a price, a trial length, or an
/// offer/base-plan ID: the repos contain no base-plan or offer IDs
/// (P0-billing §1.2 — a full-tree search found zero), and prices /
/// trials are whatever Play Console actually returns at runtime.
library;

/// The only two subscription product IDs that exist — verbatim from
/// native `BillingManager.kt` `subsProductList` and the only two the
/// server accepts (`jot-server/src/routes/billing.js:55,150`).
abstract final class BillingProducts {
  static const String monthly = 'jot_membership_monthly';
  static const String yearly = 'jot_membership_yearly';
  static const Set<String> subscriptionIds = {monthly, yearly};

  /// The production package billing belongs to. Billing activates
  /// ONLY when the running app's package is this one (native
  /// `applicationId = "com.notel.notel"`); the Flutter Lab package
  /// (`com.notel.notel.playground.flutter`) must never sell.
  static const String productionPackage = 'com.notel.notel';

  /// Deep link to this subscription's management page in Play's
  /// Subscription Center, in the form documented by Google Play
  /// Billing ("Link to a specific subscription management page"):
  /// `https://play.google.com/store/account/subscriptions?sku=<productId>&package=<app package>`,
  /// where `sku` is the subscription's productId.
  ///
  /// Play's catalog for Tabs is ONE subscription product —
  /// [monthly] (`jot_membership_monthly`) — carrying both base
  /// plans (`premium-monthly` and `premium-yearly`). So `sku` is
  /// that single product ID no matter which base plan the user
  /// picked: `jot_membership_yearly` is not a product ID in the
  /// catalog and does not resolve to the yearly subscription.
  /// (Conformance audit 2026-10-27, item 1c.)
  static const String subscriptionManagementUrl =
      'https://play.google.com/store/account/subscriptions'
      '?sku=$monthly&package=$productionPackage';
}

/// One pricing phase of an offer, mirroring Play's `PricingPhase`.
class BillingPricingPhase {
  /// Formatted price exactly as Play returns it (e.g. "$5.99").
  final String formattedPrice;

  /// Price in micros; 0 marks a free phase (free trial).
  final int priceAmountMicros;
  final String priceCurrencyCode;

  /// ISO 8601 billing period ("P1M", "P1Y", "P7D", ...).
  final String billingPeriod;

  const BillingPricingPhase({
    required this.formattedPrice,
    required this.priceAmountMicros,
    required this.priceCurrencyCode,
    required this.billingPeriod,
  });

  bool get isFree => priceAmountMicros == 0;
}

/// One subscription offer as Play returned it. [basePlanId] /
/// [offerId] come from the live catalog ONLY — they exist nowhere in
/// the repos and are never invented client-side. [offerToken] is the
/// opaque token Play requires at purchase time (native passes the
/// offer's token in `BillingFlowParams`).
class BillingOffer {
  final String? basePlanId;
  final String? offerId;
  final String offerToken;
  final List<BillingPricingPhase> pricingPhases;
  final List<String> offerTags;

  const BillingOffer({
    required this.basePlanId,
    required this.offerId,
    required this.offerToken,
    required this.pricingPhases,
    this.offerTags = const [],
  });

  /// Identity is the offer token: Play mints one per
  /// (product, base plan, offer) — two offers with the same token
  /// ARE the same offer.
  @override
  bool operator ==(Object other) =>
      other is BillingOffer && other.offerToken == offerToken;

  @override
  int get hashCode => offerToken.hashCode;

  /// The first free phase, if the offer carries one (a free trial or
  /// a free intro period). Native: `getFreeTrialPeriodIso` — the
  /// first zero-price phase of the offer.
  BillingPricingPhase? get freePhase {
    for (final phase in pricingPhases) {
      if (phase.isFree) return phase;
    }
    return null;
  }

  bool get hasFreeTrial => freePhase != null;

  /// The recurring (last non-free) phase — the price the user pays
  /// once any intro/free phase ends. Native:
  /// `getSubscriptionFormattedPrice` prices off the recurring phase.
  BillingPricingPhase? get recurringPhase {
    for (final phase in pricingPhases.reversed) {
      if (!phase.isFree) return phase;
    }
    return pricingPhases.isEmpty ? null : pricingPhases.last;
  }

  String? get recurringFormattedPrice => recurringPhase?.formattedPrice;

  /// Short human label for ONE offer, built only from its real
  /// phases: e.g. "Free for 7 days, then $5.99/month", or
  /// "$39.99/year", or "Intro $1.99/month for 3 months, then
  /// $5.99/month". Null when the offer carries no phase data at
  /// all — callers must then show the honest fallback, never a
  /// made-up label.
  String? get summaryLabel {
    if (pricingPhases.isEmpty) return null;
    final parts = <String>[];
    for (final phase in pricingPhases) {
      final period = billingPeriodNoun(phase.billingPeriod);
      if (phase.isFree) {
        final length = isoPeriodLengthLabel(phase.billingPeriod);
        parts.add(length == null ? 'Free intro' : 'Free for $length');
      } else if (period != null) {
        parts.add('${phase.formattedPrice}/$period');
      } else {
        parts.add(phase.formattedPrice);
      }
    }
    if (parts.length == 1) return parts.single;
    return '${parts.sublist(0, parts.length - 1).join(', ')}, '
        'then ${parts.last}';
  }

  /// The trial part of the label for CTA copy, e.g. "7-day free
  /// trial" — derived from the offer's actual free phase. Null when
  /// this offer has no free phase (the CTA must then NOT claim a
  /// trial). Mirrors native's ISO→label mapping
  /// (`SettingsScreen.kt` trial label: P7D/P1W → "7-day free
  /// trial", P14D, P1M), generalized to any period Play returns.
  String? get trialCtaLabel {
    final free = freePhase;
    if (free == null) return null;
    final length = isoPeriodLengthLabel(free.billingPeriod);
    if (length == null) return 'free trial';
    return '$length free trial';
  }
}

/// A subscription product as Play returned it, with ALL of its
/// offers. The user picks the offer (Phase 2 requirement); when a
/// product has exactly one offer that pick is unambiguous, and when
/// it has several the UI must present them — code must never
/// silently take `offers.first` the way native did.
class BillingProduct {
  final String id;
  final String title;
  final String description;
  final List<BillingOffer> offers;

  const BillingProduct({
    required this.id,
    required this.title,
    required this.description,
    required this.offers,
  });

  bool get isMonthly => id == BillingProducts.monthly;
  bool get isYearly => id == BillingProducts.yearly;
}

enum BillingPurchaseStatus { pending, purchased, restored, canceled, error }

/// One purchase-store update, plugin-free mirror of
/// `PurchaseDetails`.
class BillingPurchase {
  final String productId;

  /// The Play purchase token — the value the server verifies. Never
  /// logged, never persisted client-side.
  final String purchaseToken;
  final BillingPurchaseStatus status;

  /// Store error detail for [BillingPurchaseStatus.error] updates.
  final String? errorMessage;

  const BillingPurchase({
    required this.productId,
    required this.purchaseToken,
    required this.status,
    this.errorMessage,
  });
}

/// Human noun for a recurring ISO period: P1M → "month", P1Y →
/// "year", P1W → "week", P1D → "day". Null for periods that are not
/// a single-unit recurrence (callers fall back to the raw price).
String? billingPeriodNoun(String iso) {
  switch (iso) {
    case 'P1D':
      return 'day';
    case 'P1W':
      return 'week';
    case 'P1M':
      return 'month';
    case 'P1Y':
      return 'year';
  }
  return null;
}

/// Human length for an ISO 8601 period: P7D → "7-day", P1W →
/// "7-day", P14D → "14-day", P1M → "1-month", P2W → "14-day",
/// P3M → "3-month", P1Y → "1-year". Null when unparseable.
String? isoPeriodLengthLabel(String iso) {
  final match = RegExp(r'^P(\d+)([DWMY])$').firstMatch(iso.trim());
  if (match == null) return null;
  final n = int.tryParse(match.group(1)!);
  if (n == null) return null;
  switch (match.group(2)) {
    case 'D':
      return '$n-day';
    case 'W':
      return '${n * 7}-day';
    case 'M':
      return '$n-month';
    case 'Y':
      return '$n-year';
  }
  return null;
}
