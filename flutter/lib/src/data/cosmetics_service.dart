import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:tabs_lab/src/data/cosmetics.dart';
import 'package:tabs_lab/src/data/crash_reporting.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Gem Store cosmetics client state (Nov 27, 2026).
///
/// Mirrors the chest/gem service idiom: server state is the only
/// truth, network seams are typedefs so tests inject fakes, and
/// the production bindings are [TabsBackend] methods.
///
/// Discipline (Otto's contract):
/// - State arrives in the profile sync payload (`cosmetics`) and
///   in purchase/equip responses; [adoptCosmetics] is the single
///   adoption point.
/// - purchase() is NEVER optimistic: ownership/balance change
///   only when the server answers. Each user purchase ATTEMPT
///   gets ONE idempotency key ([newPurchaseAttempt]); a retry of
///   the same attempt reuses the key, so Juno §9's "Try again"
///   can never double-charge — and a retry whose original request
///   actually committed server-side replays into the granted
///   state. A NEW attempt (a later, separate tap after the
///   failure UI was dismissed) mints a fresh key.
/// - The balance always comes from server responses: a purchase
///   response's balance is adopted into [GemService] via
///   [GemService.adoptServerBalance] (the one balance source the
///   pill, the sheet and the store all read).
/// - equip() MAY be optimistic: the equipped selection flips
///   immediately and rolls back if the server call fails (the
///   caller then shows Juno §9's equip failure copy). A
///   successful response's cosmetics are adopted as truth.
/// - Buying equips (Juno §4 #25 / §8): after a verified purchase
///   the purchased item is equipped. The purchase response's
///   cosmetics are adopted first; if they don't already show the
///   item equipped, an equip call follows — the server remains
///   the authority either way.
typedef StorePurchaseCall =
    Future<({int? statusCode, Map<String, dynamic>? body})> Function(
      String itemId,
      String idempotencyKey,
    );
typedef StoreEquipCall =
    Future<({int? statusCode, Map<String, dynamic>? body})> Function(
      String slot,
      String? itemId,
    );
typedef StoreProfilePull = Future<Map<String, dynamic>?> Function();

enum StorePurchaseStatus {
  success,

  /// The server says the item is already owned (409
  /// already_owned — e.g. bought on another device, or an
  /// earlier attempt under a different key committed). The
  /// carried cosmetics/balance were adopted; no debit happened
  /// on this call, so no purchase-success copy fires — the
  /// caller just re-renders from the adopted state.
  alreadyOwned,
  insufficient,
  failed,
}

class StorePurchaseResult {
  final StorePurchaseStatus status;

  /// The server balance after the attempt, when one was carried.
  final int? balance;

  const StorePurchaseResult({required this.status, this.balance});
}

class CosmeticsService extends ChangeNotifier {
  CosmeticsService({
    StorePurchaseCall? purchase,
    StoreEquipCall? equip,
    StoreProfilePull? pullProfile,
    TabsBackend? backend,
    String Function()? keyGen,
  }) : _purchaseCall = purchase ?? _backendPurchase(backend ?? TabsBackend()),
       _equipCall = equip ?? _backendEquip(backend ?? TabsBackend()),
       _pullProfile = pullProfile ?? _backendPull(backend ?? TabsBackend()),
       _keyGen = keyGen ?? _defaultKeyGen();

  CosmeticsService._singleton() : this();

  static final CosmeticsService instance = CosmeticsService._singleton();

  static String Function() _defaultKeyGen() {
    var counter = 0;
    return () =>
        'store-purchase-${DateTime.now().microsecondsSinceEpoch}-${counter++}';
  }

  static StorePurchaseCall _backendPurchase(TabsBackend backend) =>
      (itemId, key) => backend.purchaseStoreItem(
        itemId: itemId,
        idempotencyKey: key,
      );

  static StoreEquipCall _backendEquip(TabsBackend backend) =>
      (slot, itemId) => backend.equipStoreItem(slot: slot, itemId: itemId);

  static StoreProfilePull _backendPull(TabsBackend backend) =>
      () => backend.fetchSyncPull();

  final StorePurchaseCall _purchaseCall;
  final StoreEquipCall _equipCall;
  final StoreProfilePull _pullProfile;
  final String Function() _keyGen;

  CosmeticsState _state = CosmeticsState.defaults;
  bool _loaded = false;

  /// In-flight purchase attempts by item id → their idempotency
  /// key. An entry lives from the attempt's first request until
  /// the attempt resolves (success, or the caller abandons it via
  /// [abandonPurchaseAttempt] — the failure UI's "Later").
  final Map<String, String> _attemptKeys = {};

  CosmeticsState get state => _state;
  BanditSelection get equipped => _state.equipped;

  /// True once any server payload (profile pull or a purchase /
  /// equip response) has landed. The store's load-failure state
  /// (Juno §9 #47) keys off this: no payload yet + a failed pull
  /// = the ruled error, never an empty-looking store.
  bool get loaded => _loaded;

  bool owns(CosmeticItem item) => _state.ownsItem(item);
  bool isEquipped(CosmeticItem item) => _state.isEquipped(item);

  /// The single adoption point for server cosmetics payloads
  /// (profile sync, purchase responses, equip responses).
  void adoptCosmetics(Object? raw) {
    if (raw == null) return;
    _state = CosmeticsState.fromPayload(raw);
    _loaded = true;
    notifyListeners();
  }

  /// Adopt the cosmetics carried by a full profile payload (the
  /// sync pull body or its `profile` map).
  void adoptFromProfilePayload(Map<String, dynamic>? payload) {
    if (payload == null) return;
    final profile = payload['profile'];
    final source = profile is Map<String, dynamic> ? profile : payload;
    if (source.containsKey('cosmetics')) {
      adoptCosmetics(source['cosmetics']);
    }
  }

  /// Pull the profile and adopt its cosmetics. Returns true when
  /// a payload landed (the store's load gate). Never throws.
  Future<bool> refreshFromProfile() async {
    try {
      final body = await _pullProfile();
      if (body == null) return false;
      adoptFromProfilePayload(body);
      return _loaded;
    } catch (e, s) {
      CrashReporting.captureError(
        e,
        stackTrace: s,
        staticMessage: 'cosmetics profile refresh failed',
      );
      return false;
    }
  }

  /// Start (or continue) the purchase attempt for [itemId]:
  /// returns the attempt's idempotency key, minting one only when
  /// no attempt for this item is in flight. Retries of the same
  /// attempt MUST go through here so they reuse the key.
  String purchaseAttemptKey(String itemId) =>
      _attemptKeys.putIfAbsent(itemId, _keyGen);

  /// End the attempt for [itemId] without a purchase (the
  /// failure UI's "Later", or a resolved success): the next
  /// purchase of this item is a new attempt with a fresh key.
  void abandonPurchaseAttempt(String itemId) => _attemptKeys.remove(itemId);

  @visibleForTesting
  String? debugAttemptKey(String itemId) => _attemptKeys[itemId];

  /// Buy [item] with gems. NOT optimistic: state changes only
  /// from the server's answer. On success the response cosmetics
  /// + balance are adopted and the item is equipped (Juno §8 —
  /// via the response itself when the server equips on purchase,
  /// otherwise via a follow-up equip call).
  ///
  /// As-built server outcomes (Mason, jot-server PR #78 —
  /// SERVER-REPORT.md): 200 `{balance, cosmetics,
  /// alreadyPurchased}` (a replayed key returns the recorded
  /// result — the same success path); 400 `insufficient_gems`
  /// `{balance, cosmetics}` → [StorePurchaseStatus.insufficient]
  /// (NOTE: 400 here, unlike the freeze spend's 409); 409
  /// `already_owned` `{balance, cosmetics}` →
  /// [StorePurchaseStatus.alreadyOwned]; 404 `item_not_found`,
  /// 400 `invalid_request` and 500 → [StorePurchaseStatus.failed]
  /// with the attempt key KEPT so the failure UI's "Try again"
  /// retries the same attempt.
  Future<StorePurchaseResult> purchase(CosmeticItem item) async {
    final key = purchaseAttemptKey(item.id);
    ({int? statusCode, Map<String, dynamic>? body}) r;
    try {
      r = await _purchaseCall(item.id, key);
    } catch (e, s) {
      CrashReporting.captureError(
        e,
        stackTrace: s,
        staticMessage: 'store purchase request failed',
      );
      return const StorePurchaseResult(status: StorePurchaseStatus.failed);
    }
    final body = r.body;
    int? balance;
    if (body != null) {
      final b = body['balance'] ?? body['gemBalance'] ?? body['gem_balance'];
      if (b is int) balance = b;
      if (body.containsKey('cosmetics')) adoptCosmetics(body['cosmetics']);
    }
    if (balance != null) GemService.instance.adoptServerBalance(balance);
    if (r.statusCode == 200 && body != null) {
      _attemptKeys.remove(item.id);
      // Buy & Equip (Juno §4 #25, §8): the response cosmetics
      // usually already equip the item; equip explicitly when
      // they don't.
      if (!_state.isEquipped(item)) {
        await equip(item.slot, item);
      }
      return StorePurchaseResult(
        status: StorePurchaseStatus.success,
        balance: balance,
      );
    }
    if (body != null && body['error'] == 'insufficient_gems') {
      _attemptKeys.remove(item.id);
      return StorePurchaseResult(
        status: StorePurchaseStatus.insufficient,
        balance: balance,
      );
    }
    if (body != null && body['error'] == 'already_owned') {
      _attemptKeys.remove(item.id);
      // Owned is owned: complete the Buy & Equip intent from the
      // adopted state, but report alreadyOwned so no purchase
      // success copy fires for a debit that didn't happen here.
      if (!_state.isEquipped(item)) {
        await equip(item.slot, item);
      }
      return StorePurchaseResult(
        status: StorePurchaseStatus.alreadyOwned,
        balance: balance,
      );
    }
    return StorePurchaseResult(
      status: StorePurchaseStatus.failed,
      balance: balance,
    );
  }

  /// Equip [item] in [slot] (null item = clear the slot — the
  /// shades None path). Optimistic: the selection flips now and
  /// rolls back on failure. Returns true when the server
  /// confirmed (its cosmetics, when carried, are adopted as
  /// truth); false on failure, with the pre-call state restored.
  Future<bool> equip(CosmeticSlot slot, CosmeticItem? item) async {
    final before = _state;
    _state = before.copyWith(equipped: before.equipped.withItem(item, slot));
    notifyListeners();
    ({int? statusCode, Map<String, dynamic>? body}) r;
    try {
      r = await _equipCall(slot.wireName, item?.id);
    } catch (e, s) {
      CrashReporting.captureError(
        e,
        stackTrace: s,
        staticMessage: 'store equip request failed',
      );
      _state = before;
      notifyListeners();
      return false;
    }
    if (r.statusCode == 200) {
      final body = r.body;
      if (body != null && body.containsKey('cosmetics')) {
        adoptCosmetics(body['cosmetics']);
      }
      return true;
    }
    // Failure (as-built: 400 invalid_slot / item_not_in_slot /
    // invalid_request, 403 not_owned, 500): some error bodies
    // carry the current cosmetics — adopt them as the resync
    // truth; otherwise roll the optimistic flip back.
    final body = r.body;
    if (body != null && body.containsKey('cosmetics')) {
      adoptCosmetics(body['cosmetics']);
    } else {
      _state = before;
      notifyListeners();
    }
    return false;
  }

  @visibleForTesting
  void debugReset() {
    _state = CosmeticsState.defaults;
    _loaded = false;
    _attemptKeys.clear();
  }
}
