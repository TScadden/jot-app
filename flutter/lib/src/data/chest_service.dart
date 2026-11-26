import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:tabs_lab/src/data/crash_reporting.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Chests (founder-approved, Nov 26, 2026 — mock v5 "Build it").
///
/// A chest drops server-side when a genuinely completed day
/// increments the streak (20% roll, 7-day dry-spell guarantee;
/// grace/freeze days never roll). The client NEVER rolls and never
/// mints: it syncs the unopened inventory from `GET /api/chests`,
/// and opening is ONE idempotent `POST /api/chests/:id/open` call
/// made on ENTRY to the open flow — the server rolls the 3 tap
/// outcomes, grants the gems in the same transaction, and returns
/// the script ([ChestOpenResult]) the animation presents. Leaving
/// the flow early can never lose gems: they are already granted.
///
/// Copy: every user-facing chests string lives in [ChestCopy],
/// byte-exact from Juno's FINAL ruling (build-chests/JUNO-RULING.md,
/// Nov 26, 2026) — numbering below is the ruling's. Vera diffs the
/// build against that file.
abstract final class ChestCopy {
  // ── Inbox sheet ─────────────────────────────────────────────
  /// Ruling #1.
  static const String sheetTitle = 'Chests';

  /// Ruling #2.
  static const String emptyState =
      'No chests yet. Finish your day for a chance at a chest.';

  /// Ruling #6.
  static const String openAction = 'Open';

  /// Ruling #7 — shown when the inventory load fails, so a failed
  /// load never reads as an empty inventory.
  static const String loadError = "Couldn't load your chests.";

  /// Ruling #8.
  static const String loadRetry = 'Try again';

  // ── Drop prompt (post-celebration) ──────────────────────────
  /// Ruling #9.
  static const String dropTitle = 'You got a chest!';

  /// Ruling #10 — `{tier}` is Daily / Streak / MEGA (no suffix).
  static String dropBody(ChestTier tier) =>
      'A ${tier.dropName} chest dropped for finishing today.';

  /// Ruling #11.
  static const String dropOpenNow = 'Open now';

  /// Ruling #12.
  static const String dropLater = 'Later';

  // ── Open-flow error (ruling #21–#23) ────────────────────────
  static const String openError = "Couldn't open that chest.";
  static const String openRetry = 'Try again';
  static const String openLater = 'Later';

  // ── Open flow (founder-approved on screen in mock v5) ───────
  static const String tapTap = 'Tap! Tap!';
  static const String oneChanceLeft = '1 chance left!';
  static const String tapToOpen = 'Tap to open!';
  static String plusGems(int n) => '+$n gems';
  static const String rewardCaption =
      'You earned a reward for finishing your day!';
  static const String continueLabel = 'CONTINUE';
}

/// The three chest tiers. Server strings are the lowercase names;
/// payouts are the locked mechanics (founder, Nov 25, 2026):
/// Daily 10 / Streak 25 / MEGA 100 gems by FINAL tier.
enum ChestTier {
  daily,
  streak,
  mega;

  static ChestTier? tryParse(Object? raw) {
    if (raw is! String) return null;
    switch (raw.toLowerCase()) {
      case 'daily':
        return ChestTier.daily;
      case 'streak':
        return ChestTier.streak;
      case 'mega':
        return ChestTier.mega;
    }
    return null;
  }

  /// The wire name the server uses.
  String get wireName => name;

  /// The `{tier}` placeholder in the drop-prompt body (ruling
  /// #10): Daily / Streak / MEGA, no "Chest" suffix.
  String get dropName => switch (this) {
    ChestTier.daily => 'Daily',
    ChestTier.streak => 'Streak',
    ChestTier.mega => 'MEGA',
  };

  /// Inbox row name (ruling #3–#5).
  String get rowName => switch (this) {
    ChestTier.daily => 'Daily Chest',
    ChestTier.streak => 'Streak Chest',
    ChestTier.mega => 'MEGA Chest',
  };

  /// Open-flow stage label (caps, tier-colored).
  String get stageLabel => switch (this) {
    ChestTier.daily => 'DAILY',
    ChestTier.streak => 'STREAK',
    ChestTier.mega => 'MEGA',
  };

  /// Gems paid when a chest FINISHES at this tier.
  int get payout => switch (this) {
    ChestTier.daily => 10,
    ChestTier.streak => 25,
    ChestTier.mega => 100,
  };

  /// The next tier up on a successful upgrade tap; MEGA is
  /// terminal (null).
  ChestTier? get upgraded => switch (this) {
    ChestTier.daily => ChestTier.streak,
    ChestTier.streak => ChestTier.mega,
    ChestTier.mega => null,
  };

  String get spriteAsset => 'assets/chests/chest_$wireName.png';
  String get goldSpriteAsset => 'assets/chests/chest_${wireName}_gold.png';
}

/// One unopened chest from `GET /api/chests`.
class ChestItem {
  final String id;
  final ChestTier tier;
  final DateTime? createdAt;

  const ChestItem({required this.id, required this.tier, this.createdAt});

  static ChestItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final tier = ChestTier.tryParse(raw['tier']);
    if (id is! String || id.isEmpty || tier == null) return null;
    final createdRaw = raw['createdAt'];
    return ChestItem(
      id: id,
      tier: tier,
      createdAt: createdRaw is String ? DateTime.tryParse(createdRaw) : null,
    );
  }
}

/// The scripted outcome of `POST /api/chests/:id/open`: the 3 tap
/// outcomes (true = that tap upgrades), the final tier, and the
/// gems the server already granted in the same transaction.
class ChestOpenResult {
  final List<bool> tapOutcomes;
  final ChestTier finalTier;
  final int gemsGranted;
  final int newBalance;

  const ChestOpenResult({
    required this.tapOutcomes,
    required this.finalTier,
    required this.gemsGranted,
    required this.newBalance,
  });

  static ChestOpenResult? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final outcomesRaw = raw['tapOutcomes'];
    if (outcomesRaw is! List || outcomesRaw.length != 3) return null;
    final outcomes = <bool>[];
    for (final o in outcomesRaw) {
      if (o is! bool) return null;
      outcomes.add(o);
    }
    final finalTier = ChestTier.tryParse(raw['finalTier']);
    final gems = raw['gemsGranted'];
    final balance = raw['newBalance'];
    if (finalTier == null || gems is! int || balance is! int) return null;
    return ChestOpenResult(
      tapOutcomes: outcomes,
      finalTier: finalTier,
      gemsGranted: gems,
      newBalance: balance,
    );
  }

  /// The tier the chest shows after [tapsUsed] chance taps from
  /// [start]: each scripted true upgrades one tier (MEGA stays).
  static ChestTier tierAfter(
    ChestTier start,
    List<bool> outcomes,
    int tapsUsed,
  ) {
    var tier = start;
    final n = tapsUsed.clamp(0, outcomes.length);
    for (var i = 0; i < n; i++) {
      if (outcomes[i]) tier = tier.upgraded ?? tier;
    }
    return tier;
  }
}

/// A fresh drop, as carried by the settlement payload's
/// `chestDropped: { id, tier } | null` contract (CHESTS UX/protocol
/// decision, Nov 26, 2026).
class ChestDrop {
  final String id;
  final ChestTier tier;

  const ChestDrop({required this.id, required this.tier});

  /// Parse the `chestDropped` field out of a settlement /
  /// daily-summary payload. Null when the field is absent, null,
  /// or malformed — a malformed drop must never prompt.
  static ChestDrop? parseChestDropped(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final raw = payload['chestDropped'];
    if (raw is! Map) return null;
    final id = raw['id'];
    final tier = ChestTier.tryParse(raw['tier']);
    if (id is! String || id.isEmpty || tier == null) return null;
    return ChestDrop(id: id, tier: tier);
  }
}

/// Network seams (the GemService idiom): production binds the
/// [TabsBackend] methods; tests inject fakes.
typedef ChestInventoryFetch = Future<List<ChestItem>?> Function();
typedef ChestOpenCall = Future<ChestOpenResult?> Function(String chestId);

/// Client state for chests: the unopened inventory (the Home gem
/// pill badge + the inbox sheet read it), plus the persisted set
/// of chest ids this device has already SEEN — the drop prompt
/// fires only for a chest that appears after a settlement and was
/// never seen before, never for a backlog discovered at first sync.
class ChestService extends ChangeNotifier {
  ChestService({
    ChestInventoryFetch? fetchInventory,
    ChestOpenCall? openCall,
    TabsBackend? backend,
    Future<String?> Function(String key)? readValue,
    Future<void> Function(String key, String value)? writeValue,
  }) : _fetchInventory =
           fetchInventory ?? _backendFetch(backend ?? TabsBackend()),
       _openCall = openCall ?? _backendOpen(backend ?? TabsBackend()),
       _readValue =
           readValue ?? ((key) => const FlutterSecureStorage().read(key: key)),
       _writeValue =
           writeValue ??
           ((key, value) =>
               const FlutterSecureStorage().write(key: key, value: value));

  ChestService._singleton() : this();

  /// The production inventory seam: `GET /api/chests`, parsed
  /// defensively — a malformed payload fails the sync (null), it
  /// never invents chests.
  static ChestInventoryFetch _backendFetch(TabsBackend backend) =>
      () async => parseInventory(await backend.fetchChestsRaw());

  static ChestOpenCall _backendOpen(TabsBackend backend) =>
      (id) async => ChestOpenResult.fromJson(await backend.openChestRaw(id));

  /// Parse a `GET /api/chests` body: `{ chests: [...] }`. Null
  /// when the body or its list is malformed; individual malformed
  /// rows are skipped, never fabricated.
  static List<ChestItem>? parseInventory(Map<String, dynamic>? body) {
    if (body == null) return null;
    final raw = body['chests'];
    if (raw is! List) return null;
    final items = <ChestItem>[];
    for (final row in raw) {
      final item = ChestItem.fromJson(row);
      if (item != null) items.add(item);
    }
    return items;
  }

  static final ChestService instance = ChestService._singleton();

  static const String _knownIdsKey = 'chests_known_ids_v1';

  final ChestInventoryFetch _fetchInventory;
  final ChestOpenCall _openCall;

  /// Known-ids persistence seams (the GemService idiom): default
  /// to secure storage; tests inject in-memory functions.
  final Future<String?> Function(String key) _readValue;
  final Future<void> Function(String key, String value) _writeValue;

  List<ChestItem> _inventory = const [];
  bool _loaded = false;
  Set<String>? _knownIds;

  /// Unopened chests, in server order (newest first within the
  /// payload's ordering). Empty until the first successful sync.
  List<ChestItem> get inventory => _inventory;
  bool get loaded => _loaded;
  int get totalCount => _inventory.length;

  Map<ChestTier, int> get countsByTier {
    final counts = <ChestTier, int>{};
    for (final chest in _inventory) {
      counts[chest.tier] = (counts[chest.tier] ?? 0) + 1;
    }
    return counts;
  }

  /// Inventory grouped for the inbox sheet: tiers in MEGA →
  /// Streak → Daily display order is NOT used; groups follow the
  /// locked brief (grouped by tier, newest first within a tier —
  /// the payload order is preserved inside each group).
  Map<ChestTier, List<ChestItem>> get groupedByTier {
    final groups = <ChestTier, List<ChestItem>>{};
    for (final chest in _inventory) {
      groups.putIfAbsent(chest.tier, () => []).add(chest);
    }
    return groups;
  }

  Future<Set<String>> _loadKnownIds() async {
    if (_knownIds != null) return _knownIds!;
    var ids = <String>{};
    try {
      final raw = await _readValue(_knownIdsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is List) {
          ids = decoded.whereType<String>().toSet();
        }
      }
    } catch (_) {
      ids = <String>{};
    }
    return _knownIds = ids;
  }

  Future<void> _persistKnownIds() async {
    final ids = _knownIds;
    if (ids == null) return;
    try {
      await _writeValue(_knownIdsKey, jsonEncode(ids.toList()));
    } catch (_) {
      // Persistence failure only weakens drop-prompt dedupe; the
      // inventory itself is unaffected.
    }
  }

  /// Sync the inventory from the server. Returns the fetched list,
  /// or null on failure (the previous inventory stands). Every id
  /// seen is recorded as known EXCEPT when [detectDrop] is armed by
  /// a settlement — see [syncAfterSettlement].
  Future<List<ChestItem>?> syncInventory() async {
    final fetched = await _fetchInventory();
    if (fetched == null) return null;
    _inventory = fetched;
    _loaded = true;
    final known = await _loadKnownIds();
    known.addAll(fetched.map((c) => c.id));
    await _persistKnownIds();
    notifyListeners();
    return fetched;
  }

  /// Settlement-time sync: returns the [ChestDrop] to prompt for
  /// when the inventory gained a chest this device has never seen
  /// (the server creates the row at settlement, so a post-settlement
  /// sync is where the contract's `chestDropped` becomes visible
  /// client-side), or null when nothing new dropped. New ids are
  /// recorded as known either way, so a drop prompts exactly once.
  Future<ChestDrop?> syncAfterSettlement() async {
    final knownBefore = Set<String>.of(await _loadKnownIds());
    final fetched = await _fetchInventory();
    if (fetched == null) return null;
    _inventory = fetched;
    _loaded = true;
    ChestDrop? drop;
    for (final chest in fetched) {
      if (!knownBefore.contains(chest.id)) {
        drop ??= ChestDrop(id: chest.id, tier: chest.tier);
      }
    }
    final known = await _loadKnownIds();
    known.addAll(fetched.map((c) => c.id));
    await _persistKnownIds();
    notifyListeners();
    return drop;
  }

  /// Open one chest: the single idempotent server call. On success
  /// the chest leaves the local inventory and the result script is
  /// returned; the caller adopts [ChestOpenResult.newBalance]
  /// through the gem balance source. Null on failure — the chest
  /// stays in the inbox and can be retried (a retry replays the
  /// recorded outcome server-side, never a second grant).
  Future<ChestOpenResult?> openChest(String chestId) async {
    ChestOpenResult? result;
    try {
      result = await _openCall(chestId);
    } catch (e, s) {
      CrashReporting.captureError(
        e,
        stackTrace: s,
        staticMessage: 'chest open failed',
      );
      return null;
    }
    if (result == null) return null;
    _inventory = _inventory.where((c) => c.id != chestId).toList();
    notifyListeners();
    return result;
  }

  @visibleForTesting
  void debugReset() {
    _inventory = const [];
    _loaded = false;
    _knownIds = null;
  }
}
