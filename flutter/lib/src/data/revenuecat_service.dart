/// RevenueCat — iOS subscription management for Tabs Premium.
///
/// The iOS counterpart of the Play billing module
/// (`billing_service.dart` / `billing_play_store.dart`), built to the
/// same seams and the same honesty rules:
///
/// - The store seam ([RevenueCatStore]) is plugin-free, so the
///   service's sequencing is unit-testable with a fake. The ONE file
///   that imports `purchases_flutter` is
///   `revenuecat_purchases_store.dart`.
/// - Verification is RevenueCat's: its servers validate purchases
///   with Apple (StoreKit 2). The client grants nothing by itself —
///   it reads RevenueCat's validated customer info and maps the
///   `premium` entitlement onto the SAME gate the app already uses
///   (the sync pull's `isUnlimited`): on iOS, effective unlimited =
///   server `isUnlimited` OR RevenueCat premium active. Android never
///   constructs this service and its gate expression is unchanged.
///   Parity analysis: `~/workspace/build-apple-readiness/revenuecat-parity-memo.md`.
/// - Identity (Juno build rules, signed privacy labels D10): the
///   RevenueCat app user ID is the Tabs server account ID — the
///   `userId` the auth API returns and `SessionStore` persists.
///   Anonymous only pre-login; [bindAccount] logs in on sign-in.
///   This module NEVER sets a RevenueCat customer attribute (the
///   seam does not even expose one), never enables an attribution /
///   advertising integration, and never configures
///   advertising-identifier collection.
/// - Configuration fails closed: the public API key comes from
///   `--dart-define=REVENUECAT_IOS_API_KEY` ([RevenueCatConfig],
///   the `SENTRY_DSN` pattern in `crash_reporting.dart`). With an
///   empty key the SDK is never configured, the store is never
///   touched, and every purchase entry point renders the honest
///   unavailable state — no crash, no fake paywall.
/// - Last-known state: the last validated premium verdict is cached
///   in secure storage (the `SessionStore`/`SettingsStore` pattern)
///   and seeds the state at initialize, so a relaunch paints the
///   last-known gate instantly while a fresh customer-info read
///   revalidates — the stale-while-revalidate shape the sync pull
///   cache uses for the server side of the same gate.
///
/// SINGLE APP-OWNED INSTANCE, exactly like `BillingService`:
/// one instance lives for the app's lifetime, owned by the app flow
/// via `RevenueCatAppSync` (revenuecat_purchases_store.dart).
/// Screens CONSUME it through their `revenueCatService` parameter;
/// they never construct or dispose their own.
library;

import 'dart:async';

/// Build-time RevenueCat configuration. Never a committed literal.
abstract final class RevenueCatConfig {
  /// The RevenueCat PUBLIC API key for the iOS app (starts with
  /// `appl_`), injected at build time:
  /// `--dart-define=REVENUECAT_IOS_API_KEY=appl_...`
  /// Public keys ship inside the app binary by design; the SECRET
  /// key (`sk_...`) must never appear here, in the repo, or in any
  /// client build.
  static const String apiKey =
      String.fromEnvironment('REVENUECAT_IOS_API_KEY');

  /// The ONE entitlement identifier. The founder creates exactly
  /// this in the RevenueCat dashboard and attaches both App Store
  /// products to it (see the founder checklist).
  static const String premiumEntitlementId = 'premium';

  static bool get isConfigured => apiKey.isNotEmpty;
}

/// One package from the current RevenueCat offering, plugin-free.
/// Prices and trial facts come from the store product the SDK
/// returned — never hardcoded (the `BillingOffer` rule).
class RevenueCatPackage {
  /// The offering package identifier (e.g. `$rc_monthly` /
  /// `$rc_annual`); the store implementation maps it back to the
  /// plugin object at purchase time.
  final String identifier;

  /// True for the annual package, false for the monthly package.
  final bool isYearly;

  /// Formatted recurring price exactly as the store returns it
  /// (e.g. "$5.99"). Null when the store product carried none —
  /// callers then show the honest fallback, never an invented price.
  final String? priceString;

  /// Trial label derived from the product's introductory price
  /// (e.g. "7-day free trial"), or null when the product has no
  /// free introductory phase — the UI must then NOT claim a trial.
  final String? trialLabel;

  const RevenueCatPackage({
    required this.identifier,
    required this.isYearly,
    this.priceString,
    this.trialLabel,
  });

  /// Short plan name for card titles / terms lines.
  String get planName => isYearly ? 'Yearly' : 'Monthly';

  /// Human summary built only from real store data, e.g.
  /// "7-day free trial, then $5.99/month". Null when there is no
  /// usable price data at all.
  String? get summaryLabel {
    final price = priceString;
    if (price == null) return null;
    final period = isYearly ? 'year' : 'month';
    final trial = trialLabel;
    if (trial == null) return '$price/$period';
    return '$trial, then $price/$period';
  }
}

/// The entitlement verdict from one validated customer-info read.
class RevenueCatCustomerInfo {
  /// Whether the `premium` entitlement is active right now
  /// (RevenueCat computes this from the validated receipt,
  /// including expiry — an expired entitlement reads false).
  final bool premiumActive;

  const RevenueCatCustomerInfo({required this.premiumActive});

  static const inactive = RevenueCatCustomerInfo(premiumActive: false);
}

/// A purchase attempt the user dismissed. Cancellation is a quiet
/// no-op in every Tabs purchase flow (Google/Apple sign-in parity):
/// the service returns to ready with NO error message.
class RevenueCatPurchaseCancelled implements Exception {
  const RevenueCatPurchaseCancelled();
}

/// A purchase / restore / catalog failure carrying ONLY a safe,
/// user-presentable message — never plugin exception text (the
/// `GoogleSignInOutcome` rule).
class RevenueCatFailure implements Exception {
  final String message;
  const RevenueCatFailure(this.message);
}

/// Store seam — the RevenueCat implementation is
/// `PurchasesRevenueCatStore` (revenuecat_purchases_store.dart);
/// tests drive a fake. There is deliberately NO attributes method
/// on this seam: the Juno D10 rule (no identifiable customer
/// attributes, ever) is enforced by construction, and a source-scan
/// test pins it.
abstract class RevenueCatStore {
  /// Configures the SDK. [appUserId] is the Tabs server account ID
  /// when a session already exists, null for anonymous.
  Future<void> configure({required String apiKey, String? appUserId});

  /// Binds the SDK identity to the Tabs account (sign-in).
  Future<RevenueCatCustomerInfo> logIn(String appUserId);

  /// Returns the SDK identity to anonymous (sign-out).
  Future<RevenueCatCustomerInfo> logOut();

  Future<RevenueCatCustomerInfo> getCustomerInfo();

  /// The current offering's monthly/yearly packages (empty when
  /// RevenueCat returns no current offering).
  Future<List<RevenueCatPackage>> getOfferingPackages();

  /// Purchases the package with [packageIdentifier] from the last
  /// fetched offering. Throws [RevenueCatPurchaseCancelled] on user
  /// cancellation, [RevenueCatFailure] on any other failure.
  Future<RevenueCatCustomerInfo> purchasePackage(String packageIdentifier);

  /// App Store restore: re-syncs the signed-in Apple account's
  /// purchases and returns the refreshed verdict.
  Future<RevenueCatCustomerInfo> restorePurchases();

  /// Validated customer-info updates (purchases, renewals,
  /// expirations, restores happening outside this service too).
  Stream<RevenueCatCustomerInfo> get customerInfoUpdates;
}

/// Last-known premium cache seam (secure storage in production;
/// in-memory in tests). Mirrors the injectable-storage pattern of
/// `SettingsStore.withStorage`.
abstract class RevenueCatCache {
  Future<bool?> readPremium();
  Future<void> writePremium(bool value);
  Future<void> clearPremium();
}

enum RevenueCatPhase {
  idle,

  /// No API key in this build: the SDK was never configured and no
  /// purchase entry point may sell. The honest unavailable state.
  unavailableNotConfigured,
  loadingOfferings,
  ready,
  purchasing,
  restoring,
  error,
}

/// Observable RevenueCat state for the iOS membership surfaces.
/// `errorMessage` / `noticeMessage` are always user-presentable.
class RevenueCatState {
  final RevenueCatPhase phase;
  final List<RevenueCatPackage> packages;

  /// The last validated premium verdict; null until the first
  /// customer-info read lands (or a cached verdict seeds it).
  final bool? isPremium;
  final String? errorMessage;

  /// A truthful non-error outcome line (e.g. the restore-found-
  /// nothing result). Kept separate from [errorMessage] so a
  /// restore that correctly finds nothing never renders as a
  /// failure — and never as a fake success either.
  final String? noticeMessage;

  const RevenueCatState({
    this.phase = RevenueCatPhase.idle,
    this.packages = const [],
    this.isPremium,
    this.errorMessage,
    this.noticeMessage,
  });

  RevenueCatState copyWith({
    RevenueCatPhase? phase,
    List<RevenueCatPackage>? packages,
    bool? isPremium,
    String? errorMessage,
    String? noticeMessage,
    bool clearError = false,
    bool clearNotice = false,
  }) {
    return RevenueCatState(
      phase: phase ?? this.phase,
      packages: packages ?? this.packages,
      isPremium: isPremium ?? this.isPremium,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      noticeMessage:
          clearNotice ? null : (noticeMessage ?? this.noticeMessage),
    );
  }
}

// TODO_JUNO: restore-found-nothing copy — drafted to the house
// honesty rules (states the fact, names the account scope, no fake
// success); Juno pass required before merge, like the billing
// TODO_JUNO strings in billing_service.dart.
// ignore: constant_identifier_names
const String TODO_JUNO_RC_RESTORE_NOTHING_FOUND =
    'No previous purchase was found for this account.';

// TODO_JUNO: generic purchase-failure copy (never plugin text).
// ignore: constant_identifier_names
const String TODO_JUNO_RC_PURCHASE_FAILED =
    'The purchase could not be completed. Please try again.';

// TODO_JUNO: generic restore-failure copy.
// ignore: constant_identifier_names
const String TODO_JUNO_RC_RESTORE_FAILED =
    'Restore could not be completed. Please try again.';

// TODO_JUNO: catalog-failure copy.
// ignore: constant_identifier_names
const String TODO_JUNO_RC_CATALOG_FAILED =
    'Tabs Premium plans could not be loaded from the App Store. '
    'Please try again later.';

/// The RevenueCat module itself. See the file doc for the
/// ownership, identity, and fail-closed rules.
class RevenueCatService {
  final RevenueCatStore _store;
  final RevenueCatCache _cache;
  final String _apiKey;

  RevenueCatState _state = const RevenueCatState();
  final StreamController<RevenueCatState> _states =
      StreamController<RevenueCatState>.broadcast();
  StreamSubscription<RevenueCatCustomerInfo>? _updatesSub;
  bool _configured = false;

  /// The account this instance is currently bound to (null =
  /// anonymous / unbound). Guards [bindAccount] against redundant
  /// logIn calls on every resume.
  String? _boundUserId;

  // The store/cache parameters keep their public names (callers
  // and tests pass store:/cache:); an initializing formal would
  // rename them to the private field names, so the assignments
  // stay in the initializer list.
  RevenueCatService({
    required RevenueCatStore store,
    required RevenueCatCache cache,
    String? apiKeyOverride,
  })  :
        // ignore: prefer_initializing_formals
        _store = store,
        // ignore: prefer_initializing_formals
        _cache = cache,
        _apiKey = apiKeyOverride ?? RevenueCatConfig.apiKey;

  RevenueCatState get state => _state;
  Stream<RevenueCatState> get states => _states.stream;

  /// True only when this build carries a key. When false the SDK
  /// is never configured and the store is never touched.
  bool get isConfigured => _apiKey.isNotEmpty;

  void _emit(RevenueCatState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  /// Adopts one validated verdict: updates the gate state and the
  /// last-known cache together, so what the UI shows and what a
  /// relaunch will seed can never diverge.
  Future<void> _adopt(RevenueCatCustomerInfo info) async {
    _emit(_state.copyWith(isPremium: info.premiumActive));
    try {
      await _cache.writePremium(info.premiumActive);
    } catch (_) {
      // The cache is a paint optimization; a write failure must
      // never fail the entitlement read itself.
    }
  }

  void _onCustomerInfoUpdate(RevenueCatCustomerInfo info) {
    unawaited(_adopt(info));
  }

  /// Configure (once) + seed last-known + load the catalog + take
  /// the first validated read. Safe to call more than once.
  /// [accountUserId] is the stored Tabs account ID when a session
  /// exists (AppFlow restore / post-login), null pre-login.
  Future<void> initialize({String? accountUserId}) async {
    if (!isConfigured) {
      _emit(_state.copyWith(
          phase: RevenueCatPhase.unavailableNotConfigured));
      return;
    }
    // Seed last-known BEFORE the first network read lands, so the
    // gate paints its previous verdict instantly on relaunch.
    try {
      final cached = await _cache.readPremium();
      if (cached != null && _state.isPremium == null) {
        _emit(_state.copyWith(isPremium: cached));
      }
    } catch (_) {}
    if (!_configured) {
      try {
        await _store.configure(apiKey: _apiKey, appUserId: accountUserId);
      } catch (_) {
        _emit(_state.copyWith(
          phase: RevenueCatPhase.error,
          errorMessage: TODO_JUNO_RC_CATALOG_FAILED,
        ));
        return;
      }
      _configured = true;
      _boundUserId = accountUserId;
      await _updatesSub?.cancel();
      _updatesSub = _store.customerInfoUpdates.listen(
        _onCustomerInfoUpdate,
        onError: (Object _) {},
      );
    } else if (accountUserId != null && accountUserId != _boundUserId) {
      await bindAccount(accountUserId);
    }
    await _refresh();
  }

  /// Binds the SDK identity to a Tabs account (sign-in) or back to
  /// anonymous (sign-out, null). The verdict that comes back is
  /// adopted immediately — a different account's entitlement must
  /// never render under this session.
  Future<void> bindAccount(String? accountUserId) async {
    if (!isConfigured || !_configured) {
      _boundUserId = accountUserId;
      return;
    }
    try {
      final RevenueCatCustomerInfo info;
      if (accountUserId == null) {
        info = await _store.logOut();
        _boundUserId = null;
        try {
          await _cache.clearPremium();
        } catch (_) {}
        _emit(_state.copyWith(isPremium: info.premiumActive));
      } else {
        info = await _store.logIn(accountUserId);
        _boundUserId = accountUserId;
        await _adopt(info);
      }
    } catch (_) {
      // Identity binding failure leaves the previous verdict in
      // place and is retried at the next initialize/resume; it
      // must never crash or fake a state change.
    }
  }

  /// Loads the current offering's packages, then takes a fresh
  /// validated read. Catalog failure is a visible error, never a
  /// silent empty paywall.
  Future<void> _refresh() async {
    _emit(_state.copyWith(
        phase: RevenueCatPhase.loadingOfferings, clearError: true));
    try {
      final packages = await _store.getOfferingPackages();
      final info = await _store.getCustomerInfo();
      await _adopt(info);
      _emit(_state.copyWith(
        phase: RevenueCatPhase.ready,
        packages: packages,
        clearError: true,
      ));
      if (packages.isEmpty) {
        _emit(_state.copyWith(
          phase: RevenueCatPhase.error,
          errorMessage: TODO_JUNO_RC_CATALOG_FAILED,
        ));
      }
    } catch (_) {
      _emit(_state.copyWith(
        phase: RevenueCatPhase.error,
        errorMessage: TODO_JUNO_RC_CATALOG_FAILED,
      ));
    }
  }

  /// Purchases [package] (one of the loaded offering packages —
  /// refused visibly when it is not, so a stale UI can never buy
  /// something the catalog did not return; the `BillingService.buy`
  /// rule). Success adopts the returned verdict immediately, so
  /// the gate flips in-session. Cancellation is silent.
  Future<void> buy(RevenueCatPackage package) async {
    if (!isConfigured || !_configured) {
      _emit(_state.copyWith(
          phase: RevenueCatPhase.unavailableNotConfigured));
      return;
    }
    final inCatalog =
        _state.packages.any((p) => p.identifier == package.identifier);
    if (!inCatalog) {
      _emit(_state.copyWith(
        phase: RevenueCatPhase.error,
        errorMessage: TODO_JUNO_RC_PURCHASE_FAILED,
      ));
      return;
    }
    _emit(_state.copyWith(
        phase: RevenueCatPhase.purchasing,
        clearError: true,
        clearNotice: true));
    try {
      final info = await _store.purchasePackage(package.identifier);
      await _adopt(info);
      _emit(_state.copyWith(phase: RevenueCatPhase.ready));
    } on RevenueCatPurchaseCancelled {
      // Silent by design: back to ready, no message at all.
      _emit(_state.copyWith(phase: RevenueCatPhase.ready));
    } on RevenueCatFailure catch (e) {
      _emit(_state.copyWith(
          phase: RevenueCatPhase.error, errorMessage: e.message));
    } catch (_) {
      _emit(_state.copyWith(
        phase: RevenueCatPhase.error,
        errorMessage: TODO_JUNO_RC_PURCHASE_FAILED,
      ));
    }
  }

  /// Restore Purchases (App Store review requirement): re-syncs
  /// the Apple account's purchases and re-evaluates the gate from
  /// the refreshed verdict. An active entitlement opens the gate;
  /// finding nothing leaves the gate closed and reports exactly
  /// that — never a fake success.
  Future<void> restore() async {
    if (!isConfigured || !_configured) {
      _emit(_state.copyWith(
          phase: RevenueCatPhase.unavailableNotConfigured));
      return;
    }
    _emit(_state.copyWith(
        phase: RevenueCatPhase.restoring,
        clearError: true,
        clearNotice: true));
    try {
      final info = await _store.restorePurchases();
      await _adopt(info);
      if (info.premiumActive) {
        _emit(_state.copyWith(phase: RevenueCatPhase.ready));
      } else {
        _emit(_state.copyWith(
          phase: RevenueCatPhase.ready,
          noticeMessage: TODO_JUNO_RC_RESTORE_NOTHING_FOUND,
        ));
      }
    } catch (_) {
      _emit(_state.copyWith(
        phase: RevenueCatPhase.error,
        errorMessage: TODO_JUNO_RC_RESTORE_FAILED,
      ));
    }
  }

  /// Account-switch hygiene, mirroring
  /// `BillingService.resetErrorMessageForAccountChange`: clears
  /// ONLY the messages. The verdict itself is re-bound by
  /// [bindAccount] on the same account-change path.
  void resetMessagesForAccountChange() {
    if (_state.errorMessage == null && _state.noticeMessage == null) {
      return;
    }
    _emit(_state.copyWith(clearError: true, clearNotice: true));
  }

  Future<void> dispose() async {
    await _updatesSub?.cancel();
    await _states.close();
  }
}
