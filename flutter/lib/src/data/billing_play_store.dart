import 'dart:async';

import 'package:flutter/services.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:tabs_lab/src/data/billing_models.dart';
import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Takeover Phase 2 (Ari) — [BillingStore] over Google Play via the
/// `in_app_purchase` plugin. All sequencing decisions live in
/// [BillingService]; this class only translates between plugin
/// types and the plugin-free models, and surfaces plugin failures
/// as thrown errors the service turns into user-visible states
/// (team lesson: no silent channel failures).
///
/// Plugin facts relied on (in_app_purchase 3.3.x /
/// in_app_purchase_android 0.5.x, verified against the resolved
/// package sources):
/// - `queryProductDetails` expands a subscription into ONE
///   [GooglePlayProductDetails] per offer, carrying the offer's
///   `subscriptionOfferDetails[subscriptionIndex]` (base plan ID,
///   offer ID, offer token, pricing phases) — that expansion is how
///   the user gets to pick an offer instead of native's silent
///   first-offer grab.
/// - Owned subscriptions come from the Android platform addition's
///   `queryPastPurchases()` (a direct `queryPurchases(SUBS)` —
///   native's `queryPurchasesAsync` parity), NOT from
///   `restorePurchases()`, so sync never re-delivers purchases
///   through the update stream and can never trigger a verify.
/// - A subscription purchase is acknowledged ONLY via
///   `completePurchase`, which the service calls strictly after
///   server verification succeeds. Subscriptions are never
///   consumed.
class PlayBillingStore implements BillingStore {
  final InAppPurchase _iap;

  PlayBillingStore({InAppPurchase? iap}) : _iap = iap ?? InAppPurchase.instance;

  /// The [GooglePlayProductDetails] behind each loaded offer, kept
  /// so [launchPurchase] can build the purchase param for exactly
  /// the offer instance the catalog handed out.
  final Map<BillingOffer, GooglePlayProductDetails> _detailsByOffer = {};

  /// Plugin purchase objects behind each delivered token, kept so
  /// [completePurchase] acknowledges the exact purchase the store
  /// delivered. Keyed by purchase token (unique per purchase).
  final Map<String, PurchaseDetails> _pluginPurchaseByToken = {};

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Stream<List<BillingPurchase>> get purchaseUpdates =>
      _iap.purchaseStream.map((list) => list.map(_mapPurchase).toList());

  BillingPurchase _mapPurchase(PurchaseDetails details) {
    final token = details.verificationData.serverVerificationData;
    if (token.isNotEmpty) _pluginPurchaseByToken[token] = details;
    return BillingPurchase(
      productId: details.productID,
      purchaseToken: token,
      status: switch (details.status) {
        PurchaseStatus.pending => BillingPurchaseStatus.pending,
        PurchaseStatus.purchased => BillingPurchaseStatus.purchased,
        PurchaseStatus.restored => BillingPurchaseStatus.restored,
        PurchaseStatus.canceled => BillingPurchaseStatus.canceled,
        PurchaseStatus.error => BillingPurchaseStatus.error,
      },
      errorMessage: details.error?.message,
    );
  }

  @override
  Future<List<BillingProduct>> queryProducts(Set<String> productIds) async {
    final response = await _iap.queryProductDetails(productIds);
    if (response.error != null) {
      throw StateError(
          'Google Play catalog query failed: ${response.error!.message}');
    }
    final byId = <String, List<BillingOffer>>{};
    final meta = <String, ProductDetails>{};
    for (final details in response.productDetails) {
      if (details is! GooglePlayProductDetails) continue;
      final wrapper = details.productDetails;
      final offers = wrapper.subscriptionOfferDetails;
      final index = details.subscriptionIndex;
      if (offers == null || index == null || index >= offers.length) {
        continue;
      }
      final offerWrapper = offers[index];
      final offer = BillingOffer(
        basePlanId: offerWrapper.basePlanId,
        offerId: offerWrapper.offerId,
        offerToken: offerWrapper.offerIdToken,
        offerTags: offerWrapper.offerTags,
        pricingPhases: [
          for (final phase in offerWrapper.pricingPhases)
            BillingPricingPhase(
              formattedPrice: phase.formattedPrice,
              priceAmountMicros: phase.priceAmountMicros,
              priceCurrencyCode: phase.priceCurrencyCode,
              billingPeriod: phase.billingPeriod,
            ),
        ],
      );
      _detailsByOffer[offer] = details;
      byId.putIfAbsent(details.id, () => []).add(offer);
      meta[details.id] = details;
    }
    return [
      for (final id in productIds)
        if (byId[id] != null)
          BillingProduct(
            id: id,
            title: meta[id]!.title,
            description: meta[id]!.description,
            offers: byId[id]!,
          ),
    ];
  }

  @override
  Future<bool> launchPurchase(BillingProduct product, BillingOffer offer) {
    final details = _detailsByOffer[offer];
    if (details == null) {
      throw StateError(
          'No Google Play product details for the selected offer.');
    }
    // Native passes the offer token in BillingFlowParams and sets no
    // obfuscated account/profile IDs (P0-billing §2.4) — parity.
    return _iap.buyNonConsumable(
      purchaseParam: GooglePlayPurchaseParam(
        productDetails: details,
        offerToken: offer.offerToken,
      ),
    );
  }

  @override
  Future<List<BillingPurchase>> queryOwnedPurchases() async {
    final addition =
        _iap.getPlatformAddition<InAppPurchaseAndroidPlatformAddition>();
    final response = await addition.queryPastPurchases();
    if (response.error != null) {
      throw StateError(
          'Google Play owned-purchase query failed: ${response.error!.message}');
    }
    return [
      for (final purchase in response.pastPurchases)
        if (BillingProducts.subscriptionIds.contains(purchase.productID))
          _mapPurchase(purchase),
    ];
  }

  @override
  Future<void> completePurchase(BillingPurchase purchase) async {
    final pluginPurchase = _pluginPurchaseByToken[purchase.purchaseToken];
    if (pluginPurchase == null) {
      throw StateError(
          'The purchase to acknowledge is no longer available.');
    }
    if (!pluginPurchase.pendingCompletePurchase) return;
    await _iap.completePurchase(pluginPurchase);
  }
}

/// Runtime package-name probe for [BillingEnvironment].
///
/// PHASE 1 INTEGRATION (Bram): register a MethodChannel named
/// `com.notel.notel/app_info` in the production app's MainActivity
/// answering `getPackageName` with `context.packageName`. The
/// production build must ALSO pass
/// `--dart-define=TABS_PRODUCTION_BILLING=true` — the gate is AND,
/// so neither signal alone opens billing. In the Lab neither
/// exists: this probe's [MissingPluginException] is caught and
/// billing honestly stays in its unavailable-in-this-build state.
/// Every failure mode (missing channel, timeout, wrong type)
/// resolves to null — never to "production".
Future<String?> probePackageName() async {
  try {
    const channel = MethodChannel('com.notel.notel/app_info');
    // No Future.timeout here on purpose: a MethodChannel call on a
    // real device always completes (value or MissingPluginException),
    // and a timeout Timer would leak into fake-async widget tests as
    // a pending-timer failure. A probe that never answers simply
    // never resolves — the callers treat billing as not-yet-known,
    // which fails closed the same way.
    final result = await channel.invokeMethod<String>('getPackageName');
    return result;
  } catch (_) {
    return null;
  }
}

/// App-lifetime owner of the ONE [BillingService] instance
/// (Vera takeover review: single-instance fix), plus its sync
/// triggers, mirroring native: BillingClient connect runs a sync
/// (here: [start] → `initialize`), and `MainActivity` ON_RESUME
/// runs one (here: the app flow forwards every resume to
/// [onResumed] — exactly one sync per resume).
/// Cancel/failure-triggered syncs live in [BillingService] itself.
///
/// Screens consume [service] through their `billingService`
/// parameter — threaded AppFlow → MainShell/OnboardingFlow → the
/// selling screens — and never construct or dispose their own.
/// [dispose] is where ownership actually ends: the app flow calls
/// it from its own dispose, and only then is the service disposed.
class BillingAppSync {
  final BillingService service;

  BillingAppSync(this.service);

  Future<void> start() async {
    await service.initialize();
  }

  /// Native ON_RESUME trigger.
  void onResumed() {
    unawaited(service.syncSubscriptionStatus());
  }

  void dispose() {
    unawaited(service.dispose());
  }
}

/// Builds the app-lifetime [BillingAppSync] — the ONLY production
/// construction site for [BillingService] — when, and only when,
/// this build passes the production gate (see
/// [BillingEnvironment]: BOTH the dart-define AND the production
/// package probe). Returns null in the Lab, where billing must
/// stay inert.
Future<BillingAppSync?> startBillingAppSync({
  required TabsBackend backend,
}) async {
  final isProduction =
      await BillingEnvironment.isProduction(packageNameProbe: probePackageName);
  if (!isProduction) return null;
  final sync = BillingAppSync(
    BillingService(
      store: PlayBillingStore(),
      backend: TabsBillingBackend(backend),
      isProductionBuild: true,
    ),
  );
  await sync.start();
  return sync;
}
