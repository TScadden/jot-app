import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/billing_models.dart';
import 'package:tabs_lab/src/data/billing_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/billing/billing_plans_panel.dart';
import 'package:tabs_lab/src/features/onboarding/membership_onboarding_screen.dart';

import 'test_helpers.dart';

/// Takeover Phase 2 — billing call-sequencing tests.
///
/// The fakes record ONE ordered event log shared by store and
/// backend, so the tests assert the native call sequence itself
/// (verify BEFORE acknowledge; sync WITHOUT verify on restore;
/// sync after cancel/failure), not just end states.
class FakeBillingStore implements BillingStore {
  final List<String> log;
  FakeBillingStore(this.log);

  bool available = true;
  List<BillingProduct> catalog = const [];
  List<BillingPurchase> owned = const [];
  bool launchResult = true;
  Object? queryError;
  Object? completeError;

  /// Every product-ID set passed to [queryProducts], in call
  /// order — lets tests pin the EXACT catalog query (set equality)
  /// the service makes, not just that a query happened.
  final List<Set<String>> queriedProductIdSets = [];

  final StreamController<List<BillingPurchase>> updates =
      StreamController<List<BillingPurchase>>.broadcast();

  @override
  Future<bool> isAvailable() async {
    log.add('store.isAvailable');
    return available;
  }

  @override
  Stream<List<BillingPurchase>> get purchaseUpdates => updates.stream;

  @override
  Future<List<BillingProduct>> queryProducts(Set<String> productIds) async {
    log.add('store.queryProducts');
    queriedProductIdSets.add(Set<String>.of(productIds));
    if (queryError != null) throw queryError!;
    return catalog;
  }

  @override
  Future<bool> launchPurchase(BillingProduct product, BillingOffer offer) async {
    log.add('store.launch:${product.id}:${offer.offerToken}');
    return launchResult;
  }

  @override
  Future<List<BillingPurchase>> queryOwnedPurchases() async {
    log.add('store.queryOwned');
    return owned;
  }

  @override
  Future<void> completePurchase(BillingPurchase purchase) async {
    log.add('store.complete:${purchase.purchaseToken}');
    if (completeError != null) throw completeError!;
  }

  void emit(List<BillingPurchase> purchases) => updates.add(purchases);
}

class FakeBillingBackend implements BillingBackend {
  final List<String> log;
  FakeBillingBackend(this.log);

  BillingVerifyOutcome verifyOutcome = const BillingVerifyOutcome(
      success: true, isUnlimited: true);
  bool? syncResult = false;
  Object? verifyError;

  /// When set, verify blocks on this completer (concurrency tests).
  Completer<void>? verifyGate;
  final List<String> verifiedTokens = [];
  final List<List<String>> syncedTokenLists = [];

  @override
  Future<BillingVerifyOutcome> verifyPurchase({
    required String productId,
    required String purchaseToken,
    int quantity = 1,
  }) async {
    log.add('backend.verify:$productId:$purchaseToken:$quantity');
    verifiedTokens.add(purchaseToken);
    if (verifyGate != null) await verifyGate!.future;
    if (verifyError != null) throw verifyError!;
    return verifyOutcome;
  }

  @override
  Future<bool?> syncSubscriptions(List<String> activeTokens) async {
    log.add('backend.sync:$activeTokens');
    syncedTokenLists.add(List.of(activeTokens));
    return syncResult;
  }
}

/// Minimal TabsBackend for the membership onboarding screen
/// (its only backend read is fetchIsUnlimited).
class FakeMembershipBackend extends TabsBackend {
  FakeMembershipBackend() : super(sessionStore: FakeSessionStore());

  @override
  Future<bool> fetchIsUnlimited() async => false;
}

// ── Fake-catalog builders ──────────────────────────────────────
//
// LESSON (verified Oct 27, 2026): the old two-product fake hid
// this defect. It modeled the catalog as TWO products
// (jot_membership_monthly + a second, invented yearly product),
// so the paywall's one-product modeling defect never showed up
// in tests. The fake now mirrors the LIVE shape: ONE product
// (jot_membership_monthly), TWO base plans (premium-monthly /
// premium-yearly), and offers carrying basePlanId — the grouping
// key the panel must use. Never reintroduce a second product
// here; plans differ by base plan and offer, not by product.

BillingOffer offer({
  String token = 'tok-offer-1',
  String? basePlan = 'base',
  String? offerId,
  List<BillingPricingPhase> phases = const [
    BillingPricingPhase(
        formattedPrice: '\$0.00',
        priceAmountMicros: 0,
        priceCurrencyCode: 'USD',
        billingPeriod: 'P7D'),
    BillingPricingPhase(
        formattedPrice: '\$5.99',
        priceAmountMicros: 5990000,
        priceCurrencyCode: 'USD',
        billingPeriod: 'P1M'),
  ],
}) =>
    BillingOffer(
      basePlanId: basePlan,
      offerId: offerId,
      offerToken: token,
      pricingPhases: phases,
    );

BillingProduct product(String id, List<BillingOffer> offers) => BillingProduct(
      id: id,
      title: id,
      description: '',
      offers: offers,
    );

/// The LIVE Play catalog shape (verified Oct 27, 2026): ONE
/// subscription product, [BillingProducts.monthly], with TWO base
/// plans — premium-monthly ($5.99/mo) and premium-yearly
/// ($39.99/yr) — and each base plan carrying a base offer
/// (offerId null) plus the free-trial-7-day offer (a P7D free
/// phase, then the plan's recurring price).
BillingProduct liveCatalog() => product(BillingProducts.monthly, [
      offer(
        token: 'tok-m-base',
        basePlan: 'premium-monthly',
        offerId: null,
        phases: const [
          BillingPricingPhase(
              formattedPrice: '\$5.99',
              priceAmountMicros: 5990000,
              priceCurrencyCode: 'USD',
              billingPeriod: 'P1M'),
        ],
      ),
      offer(
        token: 'tok-m-trial',
        basePlan: 'premium-monthly',
        offerId: 'free-trial-7-day',
        phases: const [
          BillingPricingPhase(
              formattedPrice: '\$0.00',
              priceAmountMicros: 0,
              priceCurrencyCode: 'USD',
              billingPeriod: 'P7D'),
          BillingPricingPhase(
              formattedPrice: '\$5.99',
              priceAmountMicros: 5990000,
              priceCurrencyCode: 'USD',
              billingPeriod: 'P1M'),
        ],
      ),
      offer(
        token: 'tok-y-base',
        basePlan: 'premium-yearly',
        offerId: null,
        phases: const [
          BillingPricingPhase(
              formattedPrice: '\$39.99',
              priceAmountMicros: 39990000,
              priceCurrencyCode: 'USD',
              billingPeriod: 'P1Y'),
        ],
      ),
      offer(
        token: 'tok-y-trial',
        basePlan: 'premium-yearly',
        offerId: 'free-trial-7-day',
        phases: const [
          BillingPricingPhase(
              formattedPrice: '\$0.00',
              priceAmountMicros: 0,
              priceCurrencyCode: 'USD',
              billingPeriod: 'P7D'),
          BillingPricingPhase(
              formattedPrice: '\$39.99',
              priceAmountMicros: 39990000,
              priceCurrencyCode: 'USD',
              billingPeriod: 'P1Y'),
        ],
      ),
    ]);

Future<void> settle() async {
  // Let broadcast-stream deliveries + chained futures run.
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  group('offer labels are built from real phases only', () {
    test('free phase + recurring → trial CTA and summary', () {
      final o = offer();
      expect(o.trialCtaLabel, '7-day free trial');
      expect(o.summaryLabel, 'Free for 7-day, then \$5.99/month');
      expect(o.recurringFormattedPrice, '\$5.99');
    });

    test('no free phase → no trial claim anywhere', () {
      final o = offer(phases: const [
        BillingPricingPhase(
            formattedPrice: '\$39.99',
            priceAmountMicros: 39990000,
            priceCurrencyCode: 'USD',
            billingPeriod: 'P1Y'),
      ]);
      expect(o.trialCtaLabel, isNull);
      expect(o.hasFreeTrial, isFalse);
      expect(o.summaryLabel, '\$39.99/year');
    });

    test('no phases → no label at all (honest fallback upstream)', () {
      final o = offer(phases: const []);
      expect(o.summaryLabel, isNull);
      expect(o.trialCtaLabel, isNull);
    });
  });

  group('BillingService sequencing', () {
    late List<String> log;
    late FakeBillingStore store;
    late FakeBillingBackend backend;
    late BillingService service;

    setUp(() {
      log = <String>[];
      store = FakeBillingStore(log);
      backend = FakeBillingBackend(log);
      service = BillingService(
          store: store, backend: backend, isProductionBuild: true);
    });

    tearDown(() async {
      await service.dispose();
      await store.updates.close();
    });

    test('initialize: catalog query, then start sync with owned tokens',
        () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      store.owned = const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: 'owned-tok',
            status: BillingPurchaseStatus.restored),
      ];
      backend.syncResult = true;

      await service.initialize();

      expect(service.state.phase, BillingPhase.ready);
      expect(service.state.products, hasLength(1));
      expect(service.state.isUnlimited, isTrue);
      // Start sync happened, with the owned token — and NO verify.
      expect(backend.syncedTokenLists, [
        ['owned-tok']
      ]);
      expect(backend.verifiedTokens, isEmpty);
      expect(log.indexOf('store.queryProducts'),
          lessThan(log.indexOf('store.queryOwned')));
    });

    test(
        'initialize queries exactly the one live product id '
        '(subscriptionIds is the monthly singleton)', () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];

      await service.initialize();

      // The contract: there is no yearly product id anymore —
      // the one live product is queried, and nothing else.
      expect(BillingProducts.subscriptionIds, {BillingProducts.monthly});
      expect(store.queriedProductIdSets, hasLength(1));
      expect(store.queriedProductIdSets.single, {'jot_membership_monthly'});
      expect(store.queriedProductIdSets.single,
          BillingProducts.subscriptionIds);
    });

    test('purchased update: verify runs BEFORE completePurchase', () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      await service.initialize();
      log.clear();

      store.emit(const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: 'new-tok',
            status: BillingPurchaseStatus.purchased),
      ]);
      await settle();

      final verifyAt = log.indexOf('backend.verify:jot_membership_monthly:new-tok:1');
      final completeAt = log.indexOf('store.complete:new-tok');
      expect(verifyAt, isNonNegative);
      expect(completeAt, greaterThan(verifyAt));
      expect(service.state.isUnlimited, isTrue);
    });

    test('verify failure: purchase is NOT acknowledged, error is visible',
        () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      backend.verifyOutcome = const BillingVerifyOutcome(
          success: false,
          isUnlimited: false,
          errorMessage: 'Subscription is not active.');
      await service.initialize();
      log.clear();

      store.emit(const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: 'bad-tok',
            status: BillingPurchaseStatus.purchased),
      ]);
      await settle();

      expect(log.where((e) => e.startsWith('store.complete')), isEmpty);
      expect(service.state.phase, BillingPhase.error);
      expect(service.state.errorMessage, contains('not active'));
    });

    test('already-processed verify still acknowledges (server state is success)',
        () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      backend.verifyOutcome = const BillingVerifyOutcome(
          success: false,
          isUnlimited: false,
          errorMessage: 'This purchase has already been processed.');
      await service.initialize();
      log.clear();

      store.emit(const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: 'dup-tok',
            status: BillingPurchaseStatus.purchased),
      ]);
      await settle();

      expect(log, contains('store.complete:dup-tok'));
      expect(service.state.isUnlimited, isTrue);
    });

    test('the same token is never verified twice', () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      await service.initialize();
      const purchase = BillingPurchase(
          productId: BillingProducts.monthly,
          purchaseToken: 'once-tok',
          status: BillingPurchaseStatus.purchased);
      store.emit(const [purchase]);
      await settle();
      store.emit(const [purchase]);
      await settle();
      expect(backend.verifiedTokens, ['once-tok']);
    });

    test('restored updates NEVER verify; sync carries their tokens',
        () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      store.owned = const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: 'restored-tok',
            status: BillingPurchaseStatus.restored),
      ];
      await service.initialize();
      log.clear();
      backend.verifiedTokens.clear();

      store.emit(const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: 'restored-tok',
            status: BillingPurchaseStatus.restored),
      ]);
      await settle();
      await service.syncSubscriptionStatus();

      expect(backend.verifiedTokens, isEmpty);
      expect(log.where((e) => e.startsWith('store.complete')), isEmpty);
      expect(backend.syncedTokenLists.last, ['restored-tok']);
    });

    test('cancel: visible message + sync runs (native trigger)', () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      await service.initialize();
      log.clear();

      store.emit(const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: '',
            status: BillingPurchaseStatus.canceled),
      ]);
      await settle();

      expect(service.state.errorMessage, contains('canceled'));
      expect(log, contains('store.queryOwned'));
      expect(backend.syncedTokenLists, isNotEmpty);
    });

    test('store error update: visible message + sync runs', () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      await service.initialize();
      log.clear();

      store.emit(const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: '',
            status: BillingPurchaseStatus.error,
            errorMessage: 'Billing unavailable'),
      ]);
      await settle();

      expect(service.state.phase, BillingPhase.error);
      expect(service.state.errorMessage, contains('Billing unavailable'));
      expect(backend.syncedTokenLists, isNotEmpty);
    });

    test('sync failure leaves last-known status untouched (null ≠ false)',
        () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      backend.syncResult = true;
      await service.initialize();
      expect(service.state.isUnlimited, isTrue);

      backend.syncResult = null;
      final result = await service.syncSubscriptionStatus();
      expect(result, isNull);
      expect(service.state.isUnlimited, isTrue);
      expect(service.state.errorMessage, isNotNull);
    });

    test('buy launches exactly the offer the user picked', () async {
      final picked = offer(token: 'tok-picked');
      final other = offer(token: 'tok-other', offerId: 'promo');
      store.catalog = [
        product(BillingProducts.monthly, [other, picked])
      ];
      await service.initialize();

      await service.buy(service.state.products.single, picked);
      expect(log, contains('store.launch:jot_membership_monthly:tok-picked'));
      expect(log.where((e) => e.startsWith('store.launch')), hasLength(1));
    });

    test('buy refuses an offer that is not in the loaded catalog', () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      await service.initialize();
      log.clear();

      await service.buy(
        product(BillingProducts.monthly, const []),
        offer(token: 'tok-not-in-catalog'),
      );
      expect(log.where((e) => e.startsWith('store.launch')), isEmpty);
      expect(service.state.phase, BillingPhase.error);
    });

    test('catalog failure is a visible error, never silent', () async {
      store.queryError = StateError('play down');
      await service.initialize();
      expect(service.state.phase, BillingPhase.error);
      expect(service.state.errorMessage, contains('play down'));
    });

    // ── Vera fix 2: in-session retry after a failed verify ──────

    test('failed verify: same token CAN retry in-session and succeed',
        () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      backend.verifyOutcome = const BillingVerifyOutcome(
          success: false,
          isUnlimited: false,
          errorMessage: 'Subscription is not active.');
      await service.initialize();
      const purchase = BillingPurchase(
          productId: BillingProducts.monthly,
          purchaseToken: 'retry-tok',
          status: BillingPurchaseStatus.purchased);
      store.emit(const [purchase]);
      await settle();
      expect(service.state.phase, BillingPhase.error);
      expect(backend.verifiedTokens, ['retry-tok']);
      expect(log.where((e) => e.startsWith('store.complete')), isEmpty);

      // Server now accepts — the SAME session re-emission must
      // retry (no app restart), verify again, and acknowledge.
      backend.verifyOutcome =
          const BillingVerifyOutcome(success: true, isUnlimited: true);
      store.emit(const [purchase]);
      await settle();
      expect(backend.verifiedTokens, ['retry-tok', 'retry-tok']);
      expect(log, contains('store.complete:retry-tok'));
      expect(service.state.isUnlimited, isTrue);
      expect(service.state.phase, BillingPhase.ready);
    });

    test('verify throws: token is un-guarded and retry succeeds',
        () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      backend.verifyError = StateError('network down');
      await service.initialize();
      const purchase = BillingPurchase(
          productId: BillingProducts.monthly,
          purchaseToken: 'throw-tok',
          status: BillingPurchaseStatus.purchased);
      store.emit(const [purchase]);
      await settle();
      expect(service.state.phase, BillingPhase.error);
      expect(service.state.errorMessage, contains('network down'));

      backend.verifyError = null;
      store.emit(const [purchase]);
      await settle();
      expect(backend.verifiedTokens, ['throw-tok', 'throw-tok']);
      expect(log, contains('store.complete:throw-tok'));
      expect(service.state.isUnlimited, isTrue);
    });

    test(
        'completePurchase throws: retry re-verifies (already-processed) '
        'and completes in-session', () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      store.completeError = StateError('ack failed');
      await service.initialize();
      const purchase = BillingPurchase(
          productId: BillingProducts.monthly,
          purchaseToken: 'ack-tok',
          status: BillingPurchaseStatus.purchased);
      store.emit(const [purchase]);
      await settle();
      expect(service.state.phase, BillingPhase.error);
      expect(service.state.errorMessage, contains('acknowledgement'));

      // Retry: the server answers already-processed (the first
      // verify landed) — that still acknowledges, and completion
      // now succeeds, all in the same session.
      store.completeError = null;
      backend.verifyOutcome = const BillingVerifyOutcome(
          success: false,
          isUnlimited: false,
          errorMessage: 'This purchase has already been processed.');
      store.emit(const [purchase]);
      await settle();
      expect(backend.verifiedTokens, ['ack-tok', 'ack-tok']);
      expect(
          log.where((e) => e == 'store.complete:ack-tok'), hasLength(2));
      expect(service.state.isUnlimited, isTrue);
    });

    test('successful verify still guards: no re-verify after success',
        () async {
      // Retry-un-guarding must NOT reopen the success path.
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      await service.initialize();
      const purchase = BillingPurchase(
          productId: BillingProducts.monthly,
          purchaseToken: 'done-tok',
          status: BillingPurchaseStatus.purchased);
      store.emit(const [purchase]);
      await settle();
      store.emit(const [purchase]);
      await settle();
      expect(backend.verifiedTokens, ['done-tok']);
      expect(log.where((e) => e == 'store.complete:done-tok'),
          hasLength(1));
    });

    // ── Vera fix 4: empty-token filter ───────────────────────────

    test('purchased update with empty token never reaches verify',
        () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      await service.initialize();
      log.clear();

      store.emit(const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: '',
            status: BillingPurchaseStatus.purchased),
      ]);
      await settle();

      expect(backend.verifiedTokens, isEmpty);
      expect(log.where((e) => e.startsWith('backend.verify')), isEmpty);
      expect(log.where((e) => e.startsWith('store.complete')), isEmpty);
      expect(service.state.phase, BillingPhase.error);
      expect(service.state.errorMessage,
          contains('without a verification token'));
    });

    // ── Vera fix 1: concurrent emissions on the shared instance ─

    test(
        'concurrent emissions of the same token verify only once '
        '(shared-instance guard)', () async {
      store.catalog = [product(BillingProducts.monthly, [offer()])];
      await service.initialize();
      backend.verifyGate = Completer<void>();
      const purchase = BillingPurchase(
          productId: BillingProducts.monthly,
          purchaseToken: 'race-tok',
          status: BillingPurchaseStatus.purchased);
      // Two emissions back to back while the first verify is still
      // in flight — the situation two live services (the old bug)
      // double-verified, and concurrent re-emissions on the one
      // shared instance must not.
      store.emit(const [purchase]);
      await settle();
      store.emit(const [purchase]);
      await settle();
      expect(backend.verifiedTokens, ['race-tok']);
      backend.verifyGate!.complete();
      backend.verifyGate = null;
      await settle();
      expect(backend.verifiedTokens, ['race-tok']);
      expect(log.where((e) => e == 'store.complete:race-tok'),
          hasLength(1));
    });
  });

  group('Lab gate', () {
    test('non-production service never touches the store', () async {
      final log = <String>[];
      final store = FakeBillingStore(log);
      final backend = FakeBillingBackend(log);
      final service = BillingService(
          store: store, backend: backend, isProductionBuild: false);

      await service.initialize();
      expect(service.state.phase, BillingPhase.unavailableInBuild);

      await service.buy(
          product(BillingProducts.monthly, [offer()]), offer());
      expect(service.state.errorMessage, isNotNull);
      expect(await service.syncSubscriptionStatus(), isNull);
      expect(log, isEmpty);
      await service.dispose();
      await store.updates.close();
    });

    // Vera fix 3: the production gate is AND, not OR.
    test('gate: define-only → closed', () async {
      // Define present, package probe reports the Lab package.
      expect(
          await BillingEnvironment.isProduction(
              defineOptInOverride: true,
              packageNameProbe: () async =>
                  'com.notel.notel.playground.flutter'),
          isFalse);
      // Define present, no probe at all.
      expect(
          await BillingEnvironment.isProduction(defineOptInOverride: true),
          isFalse);
      // Define present, probe answers null (channel missing).
      expect(
          await BillingEnvironment.isProduction(
              defineOptInOverride: true,
              packageNameProbe: () async => null),
          isFalse);
    });

    test('gate: package-only → closed', () async {
      expect(
          await BillingEnvironment.isProduction(
              defineOptInOverride: false,
              packageNameProbe: () async => 'com.notel.notel'),
          isFalse);
      // No override: the real test-environment define is false, so
      // a production package probe alone must stay closed too.
      expect(
          await BillingEnvironment.isProduction(
              packageNameProbe: () async => 'com.notel.notel'),
          isFalse);
    });

    test('gate: both define AND production package → open', () async {
      expect(
          await BillingEnvironment.isProduction(
              defineOptInOverride: true,
              packageNameProbe: () async => 'com.notel.notel'),
          isTrue);
    });

    test('gate: probe failure → closed (even with the define)',
        () async {
      expect(
          await BillingEnvironment.isProduction(
              defineOptInOverride: true,
              packageNameProbe: () async => throw StateError('no channel')),
          isFalse);
      expect(await BillingEnvironment.isProduction(), isFalse);
    });
  });

  group('TabsBackend billing endpoints', () {
    test('verify posts the native body and returns the raw outcome',
        () async {
      final store = FakeSessionStore()..token = 'test-token';
      final backend = TabsBackend(
        client: MockClient((request) async {
          expect(request.url.toString(),
              'https://api.jottracker.com/api/billing/verify');
          expect(request.headers['Authorization'], 'Bearer test-token');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body, {
            'productId': 'jot_membership_monthly',
            'purchaseToken': 'ptok',
            'quantity': 1,
          });
          return http.Response(
              jsonEncode({'success': true, 'isUnlimited': true}), 200);
        }),
        sessionStore: store,
      );
      final res = await backend.verifyBillingPurchase(
          productId: 'jot_membership_monthly', purchaseToken: 'ptok');
      expect(res.statusCode, 200);
      expect(res.body?['success'], isTrue);
      expect(res.body?['isUnlimited'], isTrue);
    });

    test('verify surfaces the server error body (already-processed case)',
        () async {
      final store = FakeSessionStore()..token = 'test-token';
      final backend = TabsBackend(
        client: MockClient((_) async => http.Response(
            jsonEncode({
              'success': false,
              'error': 'This purchase has already been processed.'
            }),
            400)),
        sessionStore: store,
      );
      final outcome = await TabsBillingBackend(backend).verifyPurchase(
          productId: 'jot_membership_monthly', purchaseToken: 'ptok');
      expect(outcome.success, isFalse);
      expect(outcome.isAlreadyProcessed, isTrue);
    });

    test('sync-subscriptions posts activeTokens and reads isUnlimited',
        () async {
      final store = FakeSessionStore()..token = 'test-token';
      final backend = TabsBackend(
        client: MockClient((request) async {
          expect(request.url.toString(),
              'https://api.jottracker.com/api/billing/sync-subscriptions');
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body, {
            'activeTokens': ['a', 'b']
          });
          return http.Response(
              jsonEncode({'success': true, 'isUnlimited': true}), 200);
        }),
        sessionStore: store,
      );
      expect(await backend.syncBillingSubscriptions(['a', 'b']), isTrue);
    });
  });

  group('BillingPlansPanel', () {
    Future<BillingService> pumpPanel(
      WidgetTester tester, {
      required List<BillingProduct> catalog,
      List<String>? eventLog,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final log = eventLog ?? <String>[];
      final store = FakeBillingStore(log)..catalog = catalog;
      final backend = FakeBillingBackend(log);
      final service = BillingService(
          store: store, backend: backend, isProductionBuild: true);
      addTearDown(() async {
        await service.dispose();
        await store.updates.close();
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: BillingPlansPanel(service: service)),
      ));
      await tester.pump();
      await tester.pump();
      return service;
    }

    // (a) Both cards come from grouping the ONE product's offers
    // by basePlanId — there is no second (yearly) product.
    testWidgets(
        '(a) both Monthly Plan and Yearly Plan cards render from '
        'the ONE product', (tester) async {
      final service = await pumpPanel(tester, catalog: [liveCatalog()]);
      expect(service.state.products, hasLength(1));
      expect(service.state.products.single.id, BillingProducts.monthly);
      expect(find.text('Monthly Plan'), findsOneWidget);
      expect(find.text('Yearly Plan'), findsOneWidget);
    });

    // (b) Savings are computed from the two GROUPS' recurring
    // prices: 1 - 39.99 / (5.99 * 12) ≈ 44%.
    testWidgets('(b) SAVE 44% • BEST VALUE renders on the yearly card',
        (tester) async {
      await pumpPanel(tester, catalog: [liveCatalog()]);
      expect(find.text('SAVE 44% • BEST VALUE'), findsOneWidget);
    });

    // (c) Any offer in the monthly group has a free phase, so the
    // monthly card carries the trial chip (derived from phases).
    testWidgets('(c) FREE TRIAL chip renders on the monthly card',
        (tester) async {
      await pumpPanel(tester, catalog: [liveCatalog()]);
      expect(find.text('FREE TRIAL'), findsOneWidget);
    });

    // (d) The monthly group is selected by default and holds two
    // offers, so the CTA waits for an explicit offer pick.
    testWidgets(
        '(d) multi-offer monthly group: CTA waits for a pick, then '
        'shows the picked trial label', (tester) async {
      await pumpPanel(tester, catalog: [liveCatalog()]);
      expect(find.text('Choose a plan option'), findsOneWidget);
      expect(find.text('Choose an offer'), findsOneWidget);
      // Only the SELECTED (monthly) group's offers are rows.
      expect(find.byKey(const ValueKey('billing_offer_tok-m-base')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('billing_offer_tok-m-trial')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('billing_offer_tok-y-trial')),
          findsNothing);
      expect(find.text('Free for 7-day, then \$5.99/month'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('billing_offer_tok-m-trial')));
      await tester.pump();
      expect(find.text('Choose a plan option'), findsNothing);
      expect(find.text('Start 7-day free trial'), findsOneWidget);
    });

    // (e) The CTA buys the ONE product with the picked yearly
    // offer's token — exactly one launch, of the pick.
    testWidgets(
        '(e) picking the yearly trial and tapping the CTA launches '
        'the one product with tok-y-trial', (tester) async {
      final log = <String>[];
      await pumpPanel(tester, catalog: [liveCatalog()], eventLog: log);

      await tester.tap(find.text('Yearly Plan'));
      await tester.pump();
      // The offer rows switched to the yearly group.
      expect(find.byKey(const ValueKey('billing_offer_tok-y-base')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('billing_offer_tok-y-trial')),
          findsOneWidget);
      expect(find.byKey(const ValueKey('billing_offer_tok-m-trial')),
          findsNothing);
      expect(find.text('Choose a plan option'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('billing_offer_tok-y-trial')));
      await tester.pump();
      expect(find.text('Start 7-day free trial'), findsOneWidget);

      await tester.tap(find.text('Start 7-day free trial'));
      await tester.pump();
      expect(log,
          contains('store.launch:jot_membership_monthly:tok-y-trial'));
      expect(log.where((e) => e.startsWith('store.launch')), hasLength(1));
    });

    // (f) The yearly group's offers disagree on the P1Y recurring
    // price, so the group's recurring price is ambiguous and no
    // savings / value claim may be shown.
    testWidgets(
        '(f) ambiguous yearly-group recurring price → no BEST VALUE',
        (tester) async {
      await pumpPanel(tester, catalog: [
        product(BillingProducts.monthly, [
          offer(
            token: 'tok-m-base',
            basePlan: 'premium-monthly',
            offerId: null,
            phases: const [
              BillingPricingPhase(
                  formattedPrice: '\$5.99',
                  priceAmountMicros: 5990000,
                  priceCurrencyCode: 'USD',
                  billingPeriod: 'P1M'),
            ],
          ),
          offer(
            token: 'tok-m-trial',
            basePlan: 'premium-monthly',
            offerId: 'free-trial-7-day',
            phases: const [
              BillingPricingPhase(
                  formattedPrice: '\$0.00',
                  priceAmountMicros: 0,
                  priceCurrencyCode: 'USD',
                  billingPeriod: 'P7D'),
              BillingPricingPhase(
                  formattedPrice: '\$5.99',
                  priceAmountMicros: 5990000,
                  priceCurrencyCode: 'USD',
                  billingPeriod: 'P1M'),
            ],
          ),
          offer(
            token: 'tok-y-base',
            basePlan: 'premium-yearly',
            offerId: null,
            phases: const [
              BillingPricingPhase(
                  formattedPrice: '\$39.99',
                  priceAmountMicros: 39990000,
                  priceCurrencyCode: 'USD',
                  billingPeriod: 'P1Y'),
            ],
          ),
          offer(
            token: 'tok-y-trial',
            basePlan: 'premium-yearly',
            offerId: 'free-trial-7-day',
            phases: const [
              BillingPricingPhase(
                  formattedPrice: '\$0.00',
                  priceAmountMicros: 0,
                  priceCurrencyCode: 'USD',
                  billingPeriod: 'P7D'),
              BillingPricingPhase(
                  formattedPrice: '\$49.99',
                  priceAmountMicros: 49990000,
                  priceCurrencyCode: 'USD',
                  billingPeriod: 'P1Y'),
            ],
          ),
        ]),
      ]);
      expect(find.text('Yearly Plan'), findsOneWidget);
      expect(find.textContaining('BEST VALUE'), findsNothing);
      expect(find.textContaining('SAVE '), findsNothing);
    });

    // (g) A catalog whose one product carries ONLY a yearly group:
    // the yearly card renders, but with no monthly group there is
    // nothing to compute savings against — no value chip at all
    // (takeover review fix — Juno).
    testWidgets(
        '(g) catalog with ONLY a yearly group → Yearly Plan renders, '
        'no BEST VALUE', (tester) async {
      await pumpPanel(tester, catalog: [
        product(BillingProducts.monthly, [
          offer(
            token: 'tok-y-base',
            basePlan: 'premium-yearly',
            offerId: null,
            phases: const [
              BillingPricingPhase(
                  formattedPrice: '\$39.99',
                  priceAmountMicros: 39990000,
                  priceCurrencyCode: 'USD',
                  billingPeriod: 'P1Y'),
            ],
          ),
          offer(
            token: 'tok-y-trial',
            basePlan: 'premium-yearly',
            offerId: 'free-trial-7-day',
            phases: const [
              BillingPricingPhase(
                  formattedPrice: '\$0.00',
                  priceAmountMicros: 0,
                  priceCurrencyCode: 'USD',
                  billingPeriod: 'P7D'),
              BillingPricingPhase(
                  formattedPrice: '\$39.99',
                  priceAmountMicros: 39990000,
                  priceCurrencyCode: 'USD',
                  billingPeriod: 'P1Y'),
            ],
          ),
        ]),
      ]);
      expect(find.text('Yearly Plan'), findsOneWidget);
      expect(find.text('Monthly Plan'), findsNothing);
      expect(find.textContaining('BEST VALUE'), findsNothing);
    });

    // (h) A single-offer monthly group with no free phase: the CTA
    // is the plain subscribe label earned from the real phase, and
    // no trial is claimed anywhere.
    testWidgets(
        '(h) single-offer monthly group with no free phase → plain '
        'subscribe CTA and no trial claim anywhere', (tester) async {
      await pumpPanel(tester, catalog: [
        product(BillingProducts.monthly, [
          offer(
            token: 'tok-m-base',
            basePlan: 'premium-monthly',
            offerId: null,
            phases: const [
              BillingPricingPhase(
                  formattedPrice: '\$5.99',
                  priceAmountMicros: 5990000,
                  priceCurrencyCode: 'USD',
                  billingPeriod: 'P1M'),
            ],
          ),
        ]),
      ]);
      expect(find.text('Monthly Plan'), findsOneWidget);
      expect(find.text('Yearly Plan'), findsNothing);
      expect(find.text('Subscribe — \$5.99/month'), findsOneWidget);
      expect(find.text('Start 7-day free trial'), findsNothing);
      expect(find.text('FREE TRIAL'), findsNothing);
      expect(find.textContaining('free trial'), findsNothing);
      expect(find.textContaining('Free for'), findsNothing);
    });

    // F-4 (rebased onto the one-product panel): the cancellation
    // METHOD line sits in the paywall block, adjacent to the CTA,
    // in the register's Q65-verified verbatim phrasing.
    testWidgets(
        'F-4: paywall block states the cancellation method adjacent '
        'to the CTA, with the offer-phase terms line untouched',
        (tester) async {
      await pumpPanel(tester, catalog: [liveCatalog()]);
      // Pick the monthly trial offer so the CTA and the full
      // offer-phase terms line render (the one-product panel waits
      // for an explicit pick in a multi-offer group).
      await tester
          .tap(find.byKey(const ValueKey('billing_offer_tok-m-trial')));
      await tester.pump();
      // Exact Q65-verified production phrasing, verbatim.
      final cancel = find.byKey(const ValueKey('paywall_cancel_method'));
      expect(cancel, findsOneWidget);
      expect(find.text('Cancel anytime in the Play Store'),
          findsOneWidget);
      // The offer-phase-built terms line is unchanged by F-4.
      expect(
          find.text('Monthly: Free for 7-day, then \$5.99/month. '
              'Auto-renews until canceled. Billed by Google Play.'),
          findsOneWidget);
      // Adjacency: the cancellation line sits below the subscribe
      // CTA and above the terms line in the rendered block.
      final ctaY = tester.getCenter(find.text('Start 7-day free trial')).dy;
      final cancelY = tester.getCenter(cancel).dy;
      final termsY = tester
          .getCenter(find.textContaining('Auto-renews until canceled'))
          .dy;
      expect(cancelY, greaterThan(ctaY));
      expect(cancelY, lessThan(termsY));
    });

    testWidgets(
        'F-4: cancellation method still shows when no offer data '
        'is available (bare honest state)', (tester) async {
      await pumpPanel(tester, catalog: const []);
      expect(find.text('Cancel anytime in the Play Store'),
          findsOneWidget);
      expect(
          find.text('Auto-renews until canceled. Billed by Google Play.'),
          findsOneWidget);
    });
  });

  group('Single app-owned instance (Vera fix 1)', () {
    testWidgets(
        'two consumers sharing the one instance verify a purchase '
        'only once', (tester) async {
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final log = <String>[];
      final store = FakeBillingStore(log)
        ..catalog = [product(BillingProducts.monthly, [offer()])];
      final backend = FakeBillingBackend(log);
      // ONE app-owned instance, consumed by two panels — the
      // Settings + onboarding situation after the fix (previously
      // each screen constructed its own service and both received
      // the same PURCHASED update).
      final shared = BillingService(
          store: store, backend: backend, isProductionBuild: true);
      addTearDown(() async {
        await shared.dispose();
        await store.updates.close();
      });
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ListView(children: [
            BillingPlansPanel(service: shared),
            BillingPlansPanel(service: shared),
          ]),
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();

      store.emit(const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: 'shared-tok',
            status: BillingPurchaseStatus.purchased),
      ]);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(backend.verifiedTokens, ['shared-tok']);
      expect(log.where((e) => e == 'store.complete:shared-tok'),
          hasLength(1));
    });

    testWidgets(
        'disposing the onboarding screen does NOT dispose the '
        'app-owned service', (tester) async {
      final log = <String>[];
      final store = FakeBillingStore(log)
        ..catalog = [product(BillingProducts.monthly, [offer()])];
      final backend = FakeBillingBackend(log);
      final shared = BillingService(
          store: store, backend: backend, isProductionBuild: true);
      addTearDown(() async {
        await shared.dispose();
        await store.updates.close();
      });
      await tester.pumpWidget(MaterialApp(
        home: MembershipOnboardingScreen(
          onBack: () {},
          onSkip: () {},
          backend: FakeMembershipBackend(),
          billingService: shared,
        ),
      ));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(BillingPlansPanel), findsOneWidget);

      // The screen goes away (its State disposes) — the app-owned
      // service must keep living: ownership ends at the app flow,
      // not at the screen.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();

      store.emit(const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: 'after-screen-tok',
            status: BillingPurchaseStatus.purchased),
      ]);
      // Flush the stream delivery + chained futures via pumps
      // (fake-async zone: no real Future.delayed here).
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(backend.verifiedTokens, ['after-screen-tok']);
      expect(log, contains('store.complete:after-screen-tok'));
    });

    test('disposing the app-owned service ends its subscription',
        () async {
      final log = <String>[];
      final store = FakeBillingStore(log)
        ..catalog = [product(BillingProducts.monthly, [offer()])];
      final backend = FakeBillingBackend(log);
      final service = BillingService(
          store: store, backend: backend, isProductionBuild: true);
      await service.initialize();
      // This is the disposal the app flow performs at ownership
      // end (BillingAppSync.dispose → service.dispose).
      await service.dispose();
      store.emit(const [
        BillingPurchase(
            productId: BillingProducts.monthly,
            purchaseToken: 'post-dispose-tok',
            status: BillingPurchaseStatus.purchased),
      ]);
      await settle();
      expect(backend.verifiedTokens, isEmpty);
      await store.updates.close();
    });
  });
}
