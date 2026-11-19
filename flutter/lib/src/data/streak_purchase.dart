import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';

import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Streak-freeze purchase flow (streak upgrade deliverable 5; D9/A9).
///
/// Product: ONE consumable, `streak_freeze_099`. Flow follows the
/// existing membership purchase patterns (billing_service.dart):
/// query the product from Play (the price is ALWAYS the listing's —
/// Juno §4b forbids a hardcoded price), launch the Play purchase
/// flow, and on a PURCHASED update POST the token to the server's
/// verify endpoint. The freeze is adopted ONLY from the server's
/// returned `purchasedFreezes` count (Juno §5b) — never from the
/// Play callback alone. A cancellation/error surfaces Juno §5c;
/// a paid purchase whose verify has not landed surfaces Juno §1b
/// (streak-bugs package — §1b is the sole message for that state);
/// an already-held answer surfaces Juno §1c; an unreachable
/// product surfaces Juno §5a.
///
/// The store and backend are injectable seams (the billing module's
/// test idiom) so the whole flow is unit-testable without Play.
class StreakFreezeProduct {
  final String id;
  final String price;

  const StreakFreezeProduct({required this.id, required this.price});
}

class StreakFreezePurchaseUpdate {
  final String productId;

  /// Play's purchase token (Android). Empty in fakes that model a
  /// cancellation/failure.
  final String purchaseToken;
  final String orderId;

  /// 'purchased' | 'canceled' | 'error' | 'pending' | 'restored'
  final String status;

  const StreakFreezePurchaseUpdate({
    required this.productId,
    required this.purchaseToken,
    required this.orderId,
    required this.status,
  });
}

abstract class StreakFreezeStore {
  Future<bool> isAvailable();
  Stream<List<StreakFreezePurchaseUpdate>> get purchaseUpdates;
  Future<StreakFreezeProduct?> queryProduct(String productId);
  Future<bool> buyConsumable(StreakFreezeProduct product);
  Future<void> completePurchase(StreakFreezePurchaseUpdate update);

  /// Asks Play to re-deliver any purchases it still holds for
  /// this product (the recovery path for a purchase whose server
  /// verify failed after payment — the purchase was never
  /// completed/consumed, so Play replays it on the stream).
  Future<void> restorePurchases();
}

/// Purchase-flow copy ruled by Juno (streak-bugs package,
/// Nov 19, 2026; JUNO-COPY.md §§1a/1b/1c — ship exactly, casing and
/// punctuation included). These constants are the ONE place this
/// copy lives; no other file hardcodes it. Each value is Juno's
/// ruled title over her ruled body, newline-joined for this
/// single-string slot. (§1a is THE purchase confirmation surface
/// as of the A2 fix: the streak screen no longer supplies the
/// pre-existing §5b count formatter, so a grant — first-try or
/// recovered — renders §1a exactly once. The §5c failure string
/// still covers cancellations/errors, but never the verify-
/// pending state §1b rules.)
abstract final class StreakPurchaseCopy {
  /// Juno §1a success — shown when a freeze grant lands and the
  /// caller supplied no count-formatted success string.
  static const String freezeGranted =
      'freeze added\nyou\'ve got a freeze now. it covers one missed day.';

  /// Shown when a restored (replayed) purchase verifies and the
  /// freeze lands. Juno §1 ruling: a recovery that succeeds shows
  /// the same §1a success confirmation as a first-try purchase.
  static const String freezeRestored =
      'freeze added\nyou\'ve got a freeze now. it covers one missed day.';

  /// Juno §1b — shown while a paid purchase is still awaiting a
  /// successful server verify (never completed/consumed in the
  /// meantime; the app re-checks automatically on the next open).
  static const String verifyPending =
      'freeze not added yet\nyour payment went through, but we couldn\'t add your freeze yet. your purchase is safe with google play — the app checks again automatically next time you open it. please don\'t buy it again.';

  /// Juno §1c — one line, rendered inline on the purchase card
  /// when the already-held state is known (including a verify
  /// answered 409 `purchased_already_held`): the account already
  /// holds the purchased freeze, so no purchase is launched.
  static const String alreadyHeld =
      'you\'ve already got a freeze — it covers one missed day.';
}

/// The real store: `in_app_purchase` over Google Play.
class PlayStreakFreezeStore implements StreakFreezeStore {
  final InAppPurchase _iap;
  final Map<String, PurchaseDetails> _pending = {};

  PlayStreakFreezeStore([InAppPurchase? iap])
      : _iap = iap ?? InAppPurchase.instance;

  @override
  Future<bool> isAvailable() => _iap.isAvailable();

  @override
  Stream<List<StreakFreezePurchaseUpdate>> get purchaseUpdates =>
      _iap.purchaseStream.map(
        (list) => list.map(_mapUpdate).toList(),
      );

  StreakFreezePurchaseUpdate _mapUpdate(PurchaseDetails p) {
    _pending[p.purchaseID ?? ''] = p;
    var orderId = '';
    var token = p.verificationData.serverVerificationData;
    if (p is GooglePlayPurchaseDetails) {
      orderId = p.billingClientPurchase.orderId;
      token = p.billingClientPurchase.purchaseToken;
    }
    return StreakFreezePurchaseUpdate(
      productId: p.productID,
      purchaseToken: token,
      orderId: orderId,
      status: switch (p.status) {
        PurchaseStatus.purchased => 'purchased',
        PurchaseStatus.canceled => 'canceled',
        PurchaseStatus.error => 'error',
        PurchaseStatus.pending => 'pending',
        PurchaseStatus.restored => 'restored',
      },
    );
  }

  @override
  Future<StreakFreezeProduct?> queryProduct(String productId) async {
    final response = await _iap.queryProductDetails({productId});
    if (response.error != null || response.productDetails.isEmpty) {
      return null;
    }
    final d = response.productDetails.first;
    return StreakFreezeProduct(id: d.id, price: d.price);
  }

  @override
  Future<bool> buyConsumable(StreakFreezeProduct product) async {
    final response = await _iap.queryProductDetails({product.id});
    if (response.productDetails.isEmpty) return false;
    final details = response.productDetails.first;
    return _iap.buyConsumable(
      purchaseParam: PurchaseParam(productDetails: details),
    );
  }

  @override
  Future<void> restorePurchases() => _iap.restorePurchases();

  @override
  Future<void> completePurchase(StreakFreezePurchaseUpdate update) async {
    // Acknowledge/consume by matching the raw details the stream
    // delivered for this product (the membership flow's
    // completePurchase step; the server has already consumed the
    // purchase via the Play API in the verify endpoint, so this is
    // the client-side completion of the same purchase).
    for (final entry in _pending.entries.toList()) {
      final raw = entry.value;
      if (raw.productID == update.productId && raw.pendingCompletePurchase) {
        await _iap.completePurchase(raw);
        _pending.remove(entry.key);
      }
    }
  }
}

/// The verify-endpoint seam: returns the server's authoritative
/// purchased-freeze count on success, null on any failure.
typedef StreakFreezeVerify = Future<int?> Function({
  required String productId,
  required String purchaseToken,
  required String orderId,
});

/// The detailed verify outcome (A2 fix): a grant count, an
/// already-held answer, or a failure. The server's real 409 shape
/// (jot-server PR #40, streak.js) is `{error:
/// 'purchased_already_held'}` with NO count field, so already-held
/// cannot ride the int? seam — it needs its own signal, and the
/// held count is resolved separately from the authoritative
/// profile state (never from the 409 body).
typedef StreakFreezeVerifyDetailed = Future<
    ({int? count, bool alreadyHeld})> Function({
  required String productId,
  required String purchaseToken,
  required String orderId,
});

/// Resolves the authoritative held purchased-freeze count from
/// the streak store / profile state (A2 fix): used when a verify
/// is answered 409 `purchased_already_held`, whose body carries
/// no count.
typedef StreakHeldCountResolver = Future<int?> Function();

enum StreakFreezeBuyState { unknown, available, unavailable, buying }

class StreakFreezePurchaseService extends ChangeNotifier {
  static const String productId = 'streak_freeze_099';

  final StreakFreezeStore _store;
  final StreakFreezeVerifyDetailed _verifyDetailed;
  final StreakHeldCountResolver? _resolveHeldCount;
  StreamSubscription<List<StreakFreezePurchaseUpdate>>? _sub;

  StreakFreezeBuyState state = StreakFreezeBuyState.unknown;
  StreakFreezeProduct? product;

  /// Juno §5b success string, set only after the server verify
  /// returns the grant and the count is adopted by the caller.
  String? successMessage;

  /// Juno §5c failure/cancel string.
  String? failureMessage;

  /// The server-adopted purchased-freeze count from the last
  /// successful verify (the caller writes it into the streak
  /// store's state via its own adoption path).
  int? adoptedPurchasedFreezes;

  /// Called after a successful verify+adopt so the UI can refresh
  /// its counts (available/max per Juno §4a definitions).
  final void Function(int purchasedFreezes)? onAdopted;

  /// Formats the §5b string from post-adoption counts.
  final String Function(int purchasedFreezes)? formatSuccess;

  StreakFreezePurchaseService({
    StreakFreezeStore? store,
    StreakFreezeVerify? verify,
    StreakFreezeVerifyDetailed? verifyDetailed,
    StreakHeldCountResolver? resolveHeldCount,
    TabsBackend? backend,
    this.onAdopted,
    this.formatSuccess,
  })  : _store = store ?? PlayStreakFreezeStore(),
        _resolveHeldCount = resolveHeldCount ??
            (verify == null && verifyDetailed == null
                ? _backendHeldCountResolver(backend ?? TabsBackend())
                : null),
        _verifyDetailed = verifyDetailed ??
            (verify != null
                ? _wrapVerify(verify)
                : _backendVerifyDetailed(backend ?? TabsBackend()));

  /// Adapts the int? verify seam (tests / simple fakes) to the
  /// detailed outcome: a count is a grant, null is a failure; the
  /// int? shape cannot express already-held.
  static StreakFreezeVerifyDetailed _wrapVerify(StreakFreezeVerify verify) {
    return ({
      required String productId,
      required String purchaseToken,
      required String orderId,
    }) async {
      final count = await verify(
        productId: productId,
        purchaseToken: purchaseToken,
        orderId: orderId,
      );
      return (count: count, alreadyHeld: false);
    };
  }

  /// The default held-count resolver for the backend path: the
  /// authoritative count is the profile's purchased-freeze column
  /// from /api/sync/pull (the same record the streak store adopts).
  static StreakHeldCountResolver _backendHeldCountResolver(
    TabsBackend backend,
  ) {
    return () async {
      final rec = await backend.fetchStreakRecord();
      return rec.succeeded ? rec.purchasedFreezes : null;
    };
  }

  static StreakFreezeVerifyDetailed _backendVerifyDetailed(
    TabsBackend backend,
  ) {
    return ({
      required String productId,
      required String purchaseToken,
      required String orderId,
    }) async {
      final r = await backend.verifyStreakFreezePurchase(
        productId: productId,
        purchaseToken: purchaseToken,
        orderId: orderId,
      );
      // A2 fix — the already-held check runs BEFORE any count is
      // demanded: jot-server PR #40's only 409 is
      // {error: 'purchased_already_held'} with NO purchasedFreezes
      // field, so the old order (count first) returned null here
      // and the 409 branch could never fire — a genuine
      // already-held answer was parked as a verify failure.
      if (r.statusCode == 409 &&
          r.body?['error'] == 'purchased_already_held') {
        return (count: null, alreadyHeld: true);
      }
      if (r.body == null) return (count: null, alreadyHeld: false);
      final count = r.body!['purchasedFreezes'];
      if (count is! int) return (count: null, alreadyHeld: false);
      if (r.statusCode == 200) return (count: count, alreadyHeld: false);
      // A server alreadyGranted answer is a grant, not a failure:
      // the freeze is held server-side for this purchase, so
      // adopting the count (and completing the Play purchase) is
      // correct and can never double-grant.
      if (r.statusCode == 409 && r.body!['alreadyGranted'] == true) {
        return (count: count, alreadyHeld: false);
      }
      return (count: null, alreadyHeld: false);
    };
  }

  /// A purchase Play delivered that has NOT yet verified with the
  /// server. It is deliberately never completed/consumed while it
  /// sits here (streak-bugs fix): completing a consumable on a
  /// failed verify consumed the founder's paid purchase with no
  /// grant and no way back. Recovery re-runs its verify.
  StreakFreezePurchaseUpdate? _pendingUpdate;

  StreakFreezePurchaseUpdate? get pendingVerification => _pendingUpdate;
  bool get hasPendingVerification => _pendingUpdate != null;

  /// Juno-placeholder surface for a restored purchase that landed
  /// (see [StreakPurchaseCopy.freezeRestored]).
  String? restoredMessage;

  /// Juno-placeholder surface while a paid purchase awaits verify
  /// (see [StreakPurchaseCopy.verifyPending]).
  String? pendingMessage;

  /// Juno §1c surface (A2 fix): set when the already-held state is
  /// known — a verify answered 409 `purchased_already_held`, whose
  /// held count is adopted from the profile state via the held-
  /// count resolver. An already-held answer is NOT a failure: the
  /// purchase is never parked in [_pendingUpdate] for it.
  String? alreadyHeldMessage;

  /// True when the already-held state is known this session.
  bool get alreadyHeld => alreadyHeldMessage != null;

  Future<void> initialize() async {
    _sub ??= _store.purchaseUpdates.listen(
      _onUpdates,
      onError: (_) {},
    );
    await refreshProduct();
    // Recovery (streak-bugs fix): replay anything Play still
    // holds and re-verify any purchase whose verify failed in a
    // previous session — a paid freeze can never silently vanish.
    await recoverPendingPurchases();
  }

  /// Re-runs recovery: asks the store to re-deliver held
  /// purchases (their stream updates re-verify through
  /// [_onUpdates]) and directly re-verifies the in-memory pending
  /// purchase, if any. Safe to call on app start and on streak
  /// screen entry (initialize calls it).
  Future<void> recoverPendingPurchases() async {
    try {
      await _store.restorePurchases();
    } catch (_) {
      // Play unreachable: the in-memory retry below still runs,
      // and the next initialize retries the replay.
    }
    final pending = _pendingUpdate;
    if (pending != null) {
      await _verifyAndAdopt(pending, isRestore: pending.status == 'restored');
    }
  }

  /// (Re)queries the Play listing. An unreachable product puts the
  /// buy row into Juno §5a's unavailable state.
  Future<void> refreshProduct() async {
    try {
      if (!await _store.isAvailable()) {
        product = null;
        state = StreakFreezeBuyState.unavailable;
        notifyListeners();
        return;
      }
      product = await _store.queryProduct(productId);
      state = product == null
          ? StreakFreezeBuyState.unavailable
          : StreakFreezeBuyState.available;
    } catch (_) {
      product = null;
      state = StreakFreezeBuyState.unavailable;
    }
    notifyListeners();
  }

  Future<void> buy() async {
    final p = product;
    if (p == null || state == StreakFreezeBuyState.buying) return;
    successMessage = null;
    failureMessage = null;
    restoredMessage = null;
    pendingMessage = null;
    alreadyHeldMessage = null;
    state = StreakFreezeBuyState.buying;
    notifyListeners();
    try {
      final launched = await _store.buyConsumable(p);
      if (!launched) _fail();
    } catch (_) {
      _fail();
    }
  }

  void _fail() {
    failureMessage =
        "Purchase didn't finish — no freeze was added. Try again whenever you're ready, or come back later.";
    state = product == null
        ? StreakFreezeBuyState.unavailable
        : StreakFreezeBuyState.available;
    notifyListeners();
  }

  Future<void> _onUpdates(List<StreakFreezePurchaseUpdate> updates) async {
    for (final u in updates) {
      if (u.productId != productId) continue;
      switch (u.status) {
        case 'purchased':
          await _verifyAndAdopt(u, isRestore: false);
        case 'restored':
          // Streak-bugs fix: a restored update for this product is
          // a real paid purchase Play is replaying — verify it
          // through the same path instead of ignoring it.
          await _verifyAndAdopt(u, isRestore: true);
        case 'canceled':
        case 'error':
          _fail();
        default:
          break; // pending: nothing to surface yet.
      }
    }
  }

  /// Verify one delivered purchase and adopt the grant. The Play
  /// purchase is completed (consumed) ONLY after a successful
  /// server verify (or an alreadyGranted answer, which the verify
  /// seam returns as a count): on failure the purchase stays
  /// pending — unconsumed in Play, recorded in [_pendingUpdate] —
  /// so recovery can re-verify it and the freeze can still land.
  Future<void> _verifyAndAdopt(
    StreakFreezePurchaseUpdate u, {
    required bool isRestore,
  }) async {
    final result = await _verifyDetailed(
      productId: u.productId,
      purchaseToken: u.purchaseToken,
      orderId: u.orderId,
    );
    if (result.alreadyHeld) {
      // A2 fix — 409 purchased_already_held: the account already
      // holds the purchased freeze. Adopt the held state
      // truthfully: the authoritative count comes from the streak
      // store / profile state via the held-count resolver, NEVER
      // from the 409 body (which carries no count). This is not a
      // failure and is NOT parked as pending: §1c is the surface.
      _pendingUpdate = null;
      pendingMessage = null;
      failureMessage = null;
      successMessage = null;
      restoredMessage = null;
      alreadyHeldMessage = StreakPurchaseCopy.alreadyHeld;
      int? held;
      try {
        held = await _resolveHeldCount?.call();
      } catch (_) {
        held = null;
      }
      if (held != null) {
        adoptedPurchasedFreezes = held.clamp(0, 1);
        onAdopted?.call(adoptedPurchasedFreezes!);
      }
      state = StreakFreezeBuyState.available;
      notifyListeners();
      try {
        await _store.completePurchase(u);
      } catch (_) {}
      return;
    }
    final count = result.count;
    if (count == null) {
      // Verify-pending (Juno §1b): the purchase stays parked —
      // unconsumed — for automatic recovery. §1b is THE message
      // for this event: the generic §5c failure string must not
      // also be set for it (the two contradict: "try again" next
      // to "please don't buy it again").
      _pendingUpdate = u;
      pendingMessage = StreakPurchaseCopy.verifyPending;
      failureMessage = null;
      successMessage = null;
      restoredMessage = null;
      alreadyHeldMessage = null;
      state = product == null
          ? StreakFreezeBuyState.unavailable
          : StreakFreezeBuyState.available;
      notifyListeners();
      return;
    }
    _pendingUpdate = null;
    pendingMessage = null;
    alreadyHeldMessage = null;
    adoptedPurchasedFreezes = count;
    onAdopted?.call(count);
    if (isRestore) restoredMessage = StreakPurchaseCopy.freezeRestored;
    successMessage = formatSuccess?.call(count) ?? StreakPurchaseCopy.freezeGranted;
    failureMessage = null;
    state = StreakFreezeBuyState.available;
    notifyListeners();
    try {
      await _store.completePurchase(u);
    } catch (_) {}
  }

  @override
  void dispose() {
    unawaited(_sub?.cancel() ?? Future<void>.value());
    super.dispose();
  }
}
