/// Takeover Phase 2 (Ari) — the Dart billing module.
///
/// Reproduces native `BillingManager.kt`'s exact call sequence
/// against the UNCHANGED server (P0-billing §3 — server verification
/// is complete and authoritative; zero endpoint changes):
///
/// 1. Query the two subscription products
///    (`jot_membership_monthly`, `jot_membership_yearly`).
/// 2. The user picks a plan AND an offer (real `ProductDetails`
///    data — never a hardcoded price/trial, never a silent
///    first-offer grab; native's `firstOrNull()` offer pick is the
///    one behavior Phase 2 deliberately does NOT reproduce).
/// 3. Launch the Play purchase flow with that offer's token.
/// 4. On a PURCHASED update: `POST /api/billing/verify`
///    `{productId, purchaseToken, quantity}` — and ONLY on server
///    success call `completePurchase` (Play's acknowledge). If
///    verification fails the purchase is NOT acknowledged and a
///    user-visible error state is emitted (native parity, plus the
///    error is surfaced instead of native's generic event).
///    One deliberate, documented deviation: when the server answers
///    "already been processed", the token was verified by an
///    earlier attempt whose acknowledge never landed (e.g. the app
///    died between verify and acknowledge). The server state is
///    already the success state, so the purchase IS completed —
///    otherwise Play auto-refunds the live subscription after 3
///    days unacknowledged.
/// 5. `POST /api/billing/sync-subscriptions` `{activeTokens}` runs
///    on app start, on app resume, after a canceled/failed purchase
///    flow, and on the Settings "Refresh Subscription Status"
///    action — mirroring native's triggers (BillingClient connect,
///    ON_RESUME, flow cancel/failure). This is the restore/revoke
///    path: it collects tokens from the store's owned purchases and
///    NEVER calls `/verify` for them — server tokens are single-use
///    (P0-billing §3.1), so verifying on restore would 400.
///    Native also re-syncs on a 7-second poll; that poll is NOT
///    reproduced (battery/noise) — start/resume/refresh triggers
///    cover the same reconciliation points a user can observe.
///
/// Every store/network failure lands in [BillingState.errorMessage]
/// or the purchase-result stream with a user-visible string — no
/// silent failures (team lesson: channel calls error-handled with
/// user-visible states).
///
/// PHASE 1 INTEGRATION (Bram — flavor/Gradle side):
/// billing must activate only in the production package
/// `com.notel.notel`. The gate is [BillingEnvironment.isProduction]:
/// it turns true only when BOTH (a) the production build passes
/// `--dart-define=TABS_PRODUCTION_BILLING=true` AND (b) the
/// `com.notel.notel/app_info` MethodChannel answers `getPackageName`
/// with `com.notel.notel`. Either signal alone is closed, and a
/// failed/absent probe is closed. Phase 1 wires the channel in the
/// production flavor, adds the `com.android.vending.BILLING`
/// manifest permission there (native manifest line 29), and sets
/// the flavor's applicationId to `com.notel.notel`. Until both
/// signals are present the Lab build (package
/// `com.notel.notel.playground.flutter`) honestly reports billing
/// as unavailable-in-this-build.
library;

import 'dart:async';

import 'package:tabs_lab/src/data/billing_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Store seam — the Play implementation is `PlayBillingStore`
/// (billing_play_store.dart); tests drive a fake.
abstract class BillingStore {
  Future<bool> isAvailable();

  /// The store's purchase-update stream (Play: `purchaseStream`).
  Stream<List<BillingPurchase>> get purchaseUpdates;

  Future<List<BillingProduct>> queryProducts(Set<String> productIds);

  /// Launches the store purchase flow for [offer] of [product].
  /// Returns false when the store refused to even launch.
  Future<bool> launchPurchase(BillingProduct product, BillingOffer offer);

  /// The purchases the store says this user currently owns
  /// (restore path). Implementations collect them WITHOUT any
  /// server call — tokens gathered here go to sync, never verify.
  Future<List<BillingPurchase>> queryOwnedPurchases();

  /// Play acknowledge (`completePurchase`). Called by the service
  /// ONLY after the server has verified the purchase.
  Future<void> completePurchase(BillingPurchase purchase);
}

/// Backend seam for the two billing endpoints.
abstract class BillingBackend {
  /// `POST /api/billing/verify` → outcome with the server's own
  /// success flag / error text (the error text matters: the
  /// already-processed case is distinguishable only by it).
  Future<BillingVerifyOutcome> verifyPurchase({
    required String productId,
    required String purchaseToken,
    int quantity = 1,
  });

  /// `POST /api/billing/sync-subscriptions` → the server's
  /// `isUnlimited`, or null when the call failed (unknown — callers
  /// must NOT treat null as "not premium").
  Future<bool?> syncSubscriptions(List<String> activeTokens);
}

class BillingVerifyOutcome {
  final bool success;
  final bool isUnlimited;
  final String? errorMessage;

  const BillingVerifyOutcome({
    required this.success,
    required this.isUnlimited,
    this.errorMessage,
  });

  /// Server's double-credit guard (P0-billing §3.1): this token was
  /// already verified once. For acknowledge purposes that IS the
  /// success state (see the class doc on [BillingService]).
  bool get isAlreadyProcessed =>
      !success &&
      (errorMessage?.toLowerCase().contains('already been processed') ??
          false);
}

/// [BillingBackend] over the real [TabsBackend] (which owns the
/// session token + 401→refresh→retry path).
class TabsBillingBackend implements BillingBackend {
  final TabsBackend _backend;
  TabsBillingBackend(this._backend);

  @override
  Future<BillingVerifyOutcome> verifyPurchase({
    required String productId,
    required String purchaseToken,
    int quantity = 1,
  }) async {
    final res = await _backend.verifyBillingPurchase(
      productId: productId,
      purchaseToken: purchaseToken,
      quantity: quantity,
    );
    final body = res.body;
    if (body == null) {
      return const BillingVerifyOutcome(
        success: false,
        isUnlimited: false,
        errorMessage: 'Could not reach the Tabs server to verify '
            'your purchase. Check your connection and reopen Tabs — '
            'your purchase is safe with Google Play.',
      );
    }
    return BillingVerifyOutcome(
      success: body['success'] == true,
      isUnlimited: body['isUnlimited'] == true,
      errorMessage: body['error'] is String ? body['error'] as String : null,
    );
  }

  @override
  Future<bool?> syncSubscriptions(List<String> activeTokens) =>
      _backend.syncBillingSubscriptions(activeTokens);
}

/// Runtime package/flavor detection for the production gate.
abstract final class BillingEnvironment {
  /// Compile-time opt-in the production build can pass
  /// (`--dart-define=TABS_PRODUCTION_BILLING=true`). Phase 1 owns
  /// the production build wiring; see the file doc.
  static const bool defineOptIn =
      bool.fromEnvironment('TABS_PRODUCTION_BILLING');

  /// Resolves whether THIS build may sell. BOTH signals are
  /// required (AND gate, Vera takeover review): the dart-define
  /// opt-in AND a runtime package-name probe reporting the
  /// production package. Define-only is closed, package-only is
  /// closed, a missing probe is closed, and a probe failure is
  /// closed. [packageNameProbe] is injectable for tests; the real
  /// probe is a try/catch MethodChannel read (see
  /// billing_play_store.dart `probePackageName`) that yields null in
  /// the Lab, where no such channel is registered.
  /// [defineOptInOverride] is injectable for tests only — production
  /// callers omit it and read the real compile-time define.
  static Future<bool> isProduction({
    Future<String?> Function()? packageNameProbe,
    bool? defineOptInOverride,
  }) async {
    final define = defineOptInOverride ?? defineOptIn;
    if (!define) return false;
    if (packageNameProbe == null) return false;
    try {
      final name = await packageNameProbe();
      return name == BillingProducts.productionPackage;
    } catch (_) {
      return false;
    }
  }
}

enum BillingPhase {
  /// Not yet initialized, or billing not usable in this build.
  idle,

  /// This build cannot sell (Lab package / no production wiring).
  unavailableInBuild,
  loadingCatalog,
  ready,
  purchasing,
  verifying,
  error,
}

/// Observable billing state for the Settings Membership page and
/// the onboarding paywall. `errorMessage` is always user-presentable.
class BillingState {
  final BillingPhase phase;
  final List<BillingProduct> products;
  final bool? isUnlimited;
  final String? errorMessage;

  const BillingState({
    this.phase = BillingPhase.idle,
    this.products = const [],
    this.isUnlimited,
    this.errorMessage,
  });

  BillingProduct? productById(String id) {
    for (final p in products) {
      if (p.id == id) return p;
    }
    return null;
  }

  BillingState copyWith({
    BillingPhase? phase,
    List<BillingProduct>? products,
    bool? isUnlimited,
    String? errorMessage,
    bool clearError = false,
  }) {
    return BillingState(
      phase: phase ?? this.phase,
      products: products ?? this.products,
      isUnlimited: isUnlimited ?? this.isUnlimited,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

/// The billing module itself.
///
/// SINGLE APP-OWNED INSTANCE (Vera takeover review): exactly one
/// instance lives for the app's lifetime, owned by the app flow
/// via `BillingAppSync` (see billing_play_store.dart) — it owns the
/// one purchase-updates subscription and the one
/// [_verifyAttemptedTokens] guard. Screens (Settings Membership,
/// onboarding paywall) CONSUME that instance through their
/// `billingService` parameter; they never construct their own and
/// never dispose it. Disposal happens only where ownership ends:
/// the app flow disposing its `BillingAppSync`. The public
/// constructor remains for that owner and for tests, which may
/// construct isolated instances against fakes.
class BillingService {
  final BillingStore _store;
  final BillingBackend _backend;
  final bool _isProductionBuild;

  BillingState _state = const BillingState();
  final StreamController<BillingState> _states =
      StreamController<BillingState>.broadcast();
  StreamSubscription<List<BillingPurchase>>? _updatesSub;

  /// Tokens with a verify currently in flight or already
  /// succeeded on this (single, app-owned) instance. The store
  /// re-emits unacknowledged purchases on every listen; the server
  /// rejects a token's second verify, so re-sending is guarded
  /// against here as well. A token is REMOVED again when its
  /// verify/complete attempt fails (after the error is surfaced),
  /// so a failed purchase can retry in-session — see
  /// [_verifyThenComplete].
  final Set<String> _verifyAttemptedTokens = {};

  BillingService({
    required this._store,
    required this._backend,
    required this._isProductionBuild,
  });

  BillingState get state => _state;
  Stream<BillingState> get states => _states.stream;
  bool get isProductionBuild => _isProductionBuild;

  void _emit(BillingState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  /// Connect + load the catalog + run the start-of-session sync
  /// (native: BillingClient connect → queryAvailableProducts +
  /// checkSubscriptionStatus). Safe to call more than once.
  Future<void> initialize() async {
    if (!_isProductionBuild) {
      _emit(_state.copyWith(phase: BillingPhase.unavailableInBuild));
      return;
    }
    _emit(_state.copyWith(phase: BillingPhase.loadingCatalog, clearError: true));
    try {
      final available = await _store.isAvailable();
      if (!available) {
        _emit(_state.copyWith(
          phase: BillingPhase.error,
          errorMessage: 'Google Play billing is not available on '
              'this device right now.',
        ));
        return;
      }
      await _updatesSub?.cancel();
      _updatesSub = _store.purchaseUpdates.listen(
        _onPurchaseUpdates,
        onError: (Object e) {
          _emit(_state.copyWith(
            phase: BillingPhase.error,
            errorMessage: 'Google Play reported a problem: $e',
          ));
        },
      );
      final products =
          await _store.queryProducts(BillingProducts.subscriptionIds);
      _emit(_state.copyWith(phase: BillingPhase.ready, products: products));
      if (products.isEmpty) {
        _emit(_state.copyWith(
          phase: BillingPhase.error,
          errorMessage: 'Tabs Premium plans could not be loaded '
              'from Google Play. Please try again later.',
        ));
        return;
      }
    } catch (e) {
      _emit(_state.copyWith(
        phase: BillingPhase.error,
        errorMessage: 'Could not load Tabs Premium plans from '
            'Google Play: $e',
      ));
      return;
    }
    // Native trigger: sync on connect (restore/revoke reconcile).
    await syncSubscriptionStatus();
  }

  /// Launch the Play flow for the offer THE USER PICKED. Refuses —
  /// visibly — when the offer is not part of the loaded catalog, so
  /// a stale UI can never buy an offer Play didn't return.
  Future<void> buy(BillingProduct product, BillingOffer offer) async {
    if (!_isProductionBuild) {
      _emit(_state.copyWith(
        phase: BillingPhase.unavailableInBuild,
        errorMessage: 'Subscriptions are purchased through Google '
            'Play in the production Tabs app. This build cannot '
            'start a subscription.',
      ));
      return;
    }
    final catalogProduct = _state.productById(product.id);
    if (catalogProduct == null ||
        !catalogProduct.offers.contains(offer)) {
      _emit(_state.copyWith(
        phase: BillingPhase.error,
        errorMessage: 'That plan option is no longer available. '
            'Please pick from the plans shown.',
      ));
      return;
    }
    _emit(_state.copyWith(phase: BillingPhase.purchasing, clearError: true));
    try {
      final launched = await _store.launchPurchase(product, offer);
      if (!launched) {
        _emit(_state.copyWith(
          phase: BillingPhase.error,
          errorMessage: 'Google Play could not open the purchase '
              'screen. Please try again.',
        ));
        // Native trigger: sync after a failed purchase flow.
        await syncSubscriptionStatus();
      }
    } catch (e) {
      _emit(_state.copyWith(
        phase: BillingPhase.error,
        errorMessage: 'Google Play could not open the purchase '
            'screen: $e',
      ));
      await syncSubscriptionStatus();
    }
  }

  /// The purchase-update pipeline — the heart of the native call
  /// sequence. PURCHASED → verify → (server success only) →
  /// completePurchase. RESTORED → token collection only, NEVER
  /// verify. CANCELED / ERROR → visible state + sync (native
  /// trigger).
  Future<void> _onPurchaseUpdates(List<BillingPurchase> purchases) async {
    for (final purchase in purchases) {
      switch (purchase.status) {
        case BillingPurchaseStatus.pending:
          _emit(_state.copyWith(phase: BillingPhase.purchasing));
        case BillingPurchaseStatus.purchased:
          // Filter before verify: a purchased update with no
          // verification token (empty serverVerificationData in
          // the Play store mapping) has nothing the server could
          // verify — surface it visibly instead of sending an
          // empty token to /verify or burning the token guard.
          if (purchase.purchaseToken.trim().isEmpty) {
            _emit(_state.copyWith(
              phase: BillingPhase.error,
              errorMessage: 'Google Play delivered a purchase '
                  'without a verification token, so it could not '
                  'be verified. Your purchase is safe with Google '
                  'Play — reopen Tabs to try again.',
            ));
            break;
          }
          await _verifyThenComplete(purchase);
        case BillingPurchaseStatus.restored:
          // Restore path: the token joins the owned set for the
          // next sync; /verify is NEVER called for it (single-use
          // tokens, P0-billing §3.1/§3.2).
          break;
        case BillingPurchaseStatus.canceled:
          _emit(_state.copyWith(
            phase: BillingPhase.ready,
            errorMessage: 'Purchase canceled. No charge was made.',
          ));
          // Native trigger: sync after cancel.
          await syncSubscriptionStatus();
        case BillingPurchaseStatus.error:
          _emit(_state.copyWith(
            phase: BillingPhase.error,
            errorMessage: 'Google Play reported a purchase problem'
                '${purchase.errorMessage == null ? '' : ': ${purchase.errorMessage}'}',
          ));
          // Native trigger: sync after failure.
          await syncSubscriptionStatus();
      }
    }
  }

  Future<void> _verifyThenComplete(BillingPurchase purchase) async {
    if (purchase.purchaseToken.trim().isEmpty) return;
    if (_verifyAttemptedTokens.contains(purchase.purchaseToken)) return;
    _verifyAttemptedTokens.add(purchase.purchaseToken);
    _emit(_state.copyWith(phase: BillingPhase.verifying, clearError: true));
    final BillingVerifyOutcome outcome;
    try {
      outcome = await _backend.verifyPurchase(
        productId: purchase.productId,
        purchaseToken: purchase.purchaseToken,
        quantity: 1,
      );
    } catch (e) {
      _emit(_state.copyWith(
        phase: BillingPhase.error,
        errorMessage: 'Verification could not reach the Tabs '
            'server: $e. Your purchase is safe with Google Play — '
            'reopen Tabs to finish activating Premium.',
      ));
      // In-session retry (Vera takeover review): the attempt is
      // over and its error is surfaced, so un-guard the token —
      // a re-emission later in THIS session must be able to retry
      // without an app restart. Safe because the server's
      // already-processed handling covers a verify that actually
      // landed server-side before the failure.
      _verifyAttemptedTokens.remove(purchase.purchaseToken);
      return;
    }
    if (!outcome.success && !outcome.isAlreadyProcessed) {
      // Native parity: NOT acknowledged on verification failure.
      _emit(_state.copyWith(
        phase: BillingPhase.error,
        errorMessage: outcome.errorMessage ??
            'The Tabs server could not verify your purchase. '
                'Your purchase is safe with Google Play — reopen '
                'Tabs to finish activating Premium.',
      ));
      // In-session retry: see the catch branch above.
      _verifyAttemptedTokens.remove(purchase.purchaseToken);
      return;
    }
    // Server success (or the token already recorded server-side):
    // NOW acknowledge, and only now.
    try {
      await _store.completePurchase(purchase);
    } catch (e) {
      _emit(_state.copyWith(
        phase: BillingPhase.error,
        errorMessage: 'Your membership is active, but Google Play '
            'acknowledgement failed: $e. Reopen Tabs to retry it.',
      ));
      // In-session retry: the retry re-verifies (the server will
      // answer already-processed, which still acknowledges) and
      // re-attempts completion — no app restart needed.
      _verifyAttemptedTokens.remove(purchase.purchaseToken);
      return;
    }
    _emit(_state.copyWith(
      phase: BillingPhase.ready,
      isUnlimited: outcome.isUnlimited || outcome.isAlreadyProcessed
          ? true
          : _state.isUnlimited,
      clearError: true,
    ));
  }

  /// Restore/revoke reconciliation — native `checkSubscriptionStatus`:
  /// collect the store's owned-purchase tokens, POST them to
  /// `/api/billing/sync-subscriptions`, adopt the server's
  /// `isUnlimited`. Runs on app start, app resume, after
  /// cancel/failure, and from the Settings refresh action. NEVER
  /// verifies a token. Returns the server's verdict (null = the
  /// call failed; current state is left untouched).
  Future<bool?> syncSubscriptionStatus() async {
    if (!_isProductionBuild) return null;
    try {
      final owned = await _store.queryOwnedPurchases();
      final tokens = <String>{
        for (final p in owned)
          if (p.status == BillingPurchaseStatus.purchased ||
              p.status == BillingPurchaseStatus.restored)
            p.purchaseToken,
      }.toList();
      final isUnlimited = await _backend.syncSubscriptions(tokens);
      if (isUnlimited != null) {
        _emit(_state.copyWith(isUnlimited: isUnlimited));
      } else {
        _emit(_state.copyWith(
          errorMessage: 'Could not refresh subscription status '
              'from the Tabs server. Your last known status is '
              'still shown.',
        ));
      }
      return isUnlimited;
    } catch (e) {
      _emit(_state.copyWith(
        errorMessage: 'Could not refresh subscription status: $e',
      ));
      return null;
    }
  }

  Future<void> dispose() async {
    await _updatesSub?.cancel();
    await _states.close();
  }
}
