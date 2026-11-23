import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:tabs_lab/src/data/revenuecat_service.dart';
import 'package:tabs_lab/src/data/session_store.dart';

/// RevenueCat — [RevenueCatStore] over the real `purchases_flutter`
/// SDK, plus the secure-storage cache and the app-lifetime owner.
///
/// This is the ONLY file that imports `purchases_flutter`
/// (mirroring how `billing_play_store.dart` is the only Play-plugin
/// file). All sequencing decisions live in [RevenueCatService];
/// this class only translates between plugin types and the
/// plugin-free models, and maps plugin failures onto the service's
/// typed outcomes — raw plugin exception text never crosses this
/// boundary (the house rule for every store seam).
///
/// Juno D10 build rules, enforced HERE by omission: this file never
/// calls any customer-attributes setter, never touches an
/// attribution or advertising integration, and never configures
/// advertising-identifier / tracking collection. A source-scan test
/// pins the absence (test/revenuecat_service_test.dart). The only
/// identity the SDK ever receives is the Tabs server account ID,
/// via [PurchasesConfiguration.appUserID] / `Purchases.logIn`.
class PurchasesRevenueCatStore implements RevenueCatStore {
  /// Plugin [Package] objects behind each loaded package
  /// identifier, kept so [purchasePackage] buys exactly the package
  /// instance the offering handed out (the `PlayBillingStore`
  /// `_detailsByOffer` pattern).
  final Map<String, Package> _pluginPackageById = {};

  final StreamController<RevenueCatCustomerInfo> _updates =
      StreamController<RevenueCatCustomerInfo>.broadcast();
  bool _listenerInstalled = false;

  RevenueCatCustomerInfo _mapCustomerInfo(CustomerInfo info) {
    // The entitlement verdict is RevenueCat's validated answer:
    // an entry in `entitlements.active` is active by definition
    // (expired entitlements are not in the active map).
    final entitlement =
        info.entitlements.active[RevenueCatConfig.premiumEntitlementId];
    return RevenueCatCustomerInfo(premiumActive: entitlement != null);
  }

  @override
  Future<void> configure({required String apiKey, String? appUserId}) async {
    final configuration = PurchasesConfiguration(apiKey);
    // Identity rule: the app user ID is the Tabs account ID when a
    // session exists; anonymous (SDK-generated) only pre-login.
    if (appUserId != null && appUserId.isNotEmpty) {
      configuration.appUserID = appUserId;
    }
    await Purchases.configure(configuration);
    if (!_listenerInstalled) {
      _listenerInstalled = true;
      Purchases.addCustomerInfoUpdateListener((info) {
        if (!_updates.isClosed) _updates.add(_mapCustomerInfo(info));
      });
    }
  }

  @override
  Future<RevenueCatCustomerInfo> logIn(String appUserId) async {
    final result = await Purchases.logIn(appUserId);
    return _mapCustomerInfo(result.customerInfo);
  }

  @override
  Future<RevenueCatCustomerInfo> logOut() async {
    final info = await Purchases.logOut();
    return _mapCustomerInfo(info);
  }

  @override
  Future<RevenueCatCustomerInfo> getCustomerInfo() async {
    final info = await Purchases.getCustomerInfo();
    return _mapCustomerInfo(info);
  }

  @override
  Future<List<RevenueCatPackage>> getOfferingPackages() async {
    final offerings = await Purchases.getOfferings();
    final current = offerings.current;
    if (current == null) return const [];
    final packages = <RevenueCatPackage>[];
    // Monthly / annual are the offering's typed package slots —
    // the founder attaches the two App Store products there (see
    // the checklist). Any other package in the offering is ignored
    // by design: Tabs sells exactly these two plans (Play parity).
    for (final slot in [current.monthly, current.annual]) {
      if (slot == null) continue;
      _pluginPackageById[slot.identifier] = slot;
      packages.add(_mapPackage(slot));
    }
    return packages;
  }

  RevenueCatPackage _mapPackage(Package package) {
    final product = package.storeProduct;
    return RevenueCatPackage(
      identifier: package.identifier,
      isYearly: package.packageType == PackageType.annual,
      priceString: product.priceString.isEmpty ? null : product.priceString,
      trialLabel: _trialLabel(product),
    );
  }

  /// The trial label from the product's REAL introductory price:
  /// a zero-price introductory phase is the free trial, and its
  /// length comes from the phase itself (the `BillingOffer`
  /// rule — a trial is claimed only when the store returns one).
  String? _trialLabel(StoreProduct product) {
    final intro = product.introductoryPrice;
    if (intro == null || intro.price > 0) return null;
    final count = intro.periodNumberOfUnits;
    return switch (intro.periodUnit) {
      PeriodUnit.day => count == 7 ? '7-day free trial' : '$count-day free trial',
      PeriodUnit.week => count == 1 ? '7-day free trial' : '${count * 7}-day free trial',
      PeriodUnit.month => count == 1 ? '1-month free trial' : '$count-month free trial',
      PeriodUnit.year => count == 1 ? '1-year free trial' : '$count-year free trial',
      _ => 'free trial',
    };
  }

  @override
  Future<RevenueCatCustomerInfo> purchasePackage(
      String packageIdentifier) async {
    final pluginPackage = _pluginPackageById[packageIdentifier];
    if (pluginPackage == null) {
      throw const RevenueCatFailure(TODO_JUNO_RC_PURCHASE_FAILED);
    }
    try {
      // purchases_flutter v11: purchasePackage is deprecated in
      // favor of purchase(PurchaseParams) — same PurchaseResult
      // back (verified against the resolved 11.0.4 at apply time).
      final result =
          await Purchases.purchase(PurchaseParams.package(pluginPackage));
      return _mapCustomerInfo(result.customerInfo);
    } on PlatformException catch (e) {
      // Map plugin codes to typed outcomes; e.message / details are
      // deliberately dropped, never surfaced or logged.
      final code = PurchasesErrorHelper.getErrorCode(e);
      // purchases_flutter v11 renamed the cancellation code:
      // PurchasesErrorCode.userCancelledError (≤ v10) is
      // purchaseCancelledError in the resolved 11.0.4 — verified
      // against the pub-cache sources at apply time.
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        throw const RevenueCatPurchaseCancelled();
      }
      throw const RevenueCatFailure(TODO_JUNO_RC_PURCHASE_FAILED);
    }
  }

  @override
  Future<RevenueCatCustomerInfo> restorePurchases() async {
    try {
      final info = await Purchases.restorePurchases();
      return _mapCustomerInfo(info);
    } on PlatformException {
      throw const RevenueCatFailure(TODO_JUNO_RC_RESTORE_FAILED);
    }
  }

  @override
  Stream<RevenueCatCustomerInfo> get customerInfoUpdates => _updates.stream;
}

/// [RevenueCatCache] over flutter_secure_storage — the same store
/// the session and the settings use (Android Keystore / iOS
/// Keychain backed). ONE key, device-level: it holds only the last
/// premium boolean (never an account ID, never a receipt), is
/// cleared on sign-out by the service, and is re-validated against
/// RevenueCat on every launch before it can open the gate beyond
/// the first paint.
class SecureRevenueCatCache implements RevenueCatCache {
  static const _premiumKey = 'revenuecat_premium_last_known';

  final FlutterSecureStorage _storage;

  SecureRevenueCatCache({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<bool?> readPremium() async {
    final raw = await _storage.read(key: _premiumKey);
    if (raw == 'true') return true;
    if (raw == 'false') return false;
    return null;
  }

  @override
  Future<void> writePremium(bool value) =>
      _storage.write(key: _premiumKey, value: value ? 'true' : 'false');

  @override
  Future<void> clearPremium() async {
    try {
      await _storage.delete(key: _premiumKey);
    } catch (_) {}
  }
}

/// App-lifetime owner of the ONE [RevenueCatService] instance,
/// mirroring `BillingAppSync`: the app flow starts it, forwards
/// account changes to it, and disposes it where ownership ends.
/// iOS ONLY — Android never constructs this (see
/// [startRevenueCatAppSync]).
class RevenueCatAppSync {
  final RevenueCatService service;

  RevenueCatAppSync(this.service);

  Future<void> start({String? accountUserId}) =>
      service.initialize(accountUserId: accountUserId);

  /// Sign-in / sign-out forwarding from the app flow.
  Future<void> bindAccount(String? accountUserId) =>
      service.bindAccount(accountUserId);

  void dispose() {
    unawaited(service.dispose());
  }
}

/// Builds the app-lifetime [RevenueCatAppSync] — the ONLY
/// production construction site for [RevenueCatService].
///
/// The caller (AppFlow) invokes this ONLY on iOS
/// (`defaultTargetPlatform == TargetPlatform.iOS`, the
/// `login_screen.dart` platform pattern), so Android never
/// configures RevenueCat and its billing behavior is untouched.
/// When the build carries no API key the returned sync still
/// exists but its service is in the honest unconfigured state —
/// that is what lets the iOS membership surfaces render their
/// unavailable path instead of branching on null.
Future<RevenueCatAppSync> startRevenueCatAppSync({
  required SessionStore sessionStore,
}) async {
  final sync = RevenueCatAppSync(
    RevenueCatService(
      store: PurchasesRevenueCatStore(),
      cache: SecureRevenueCatCache(),
    ),
  );
  String? accountUserId;
  try {
    accountUserId = await sessionStore.readUserId();
  } catch (_) {
    accountUserId = null;
  }
  await sync.start(accountUserId: accountUserId);
  return sync;
}
