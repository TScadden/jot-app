import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';

/// Round 19c — stale-while-revalidate cache for the Quick Log screen,
/// modeled directly on [HomeDataCache] (round 16).
///
/// Founder's directive: Quick Log must render on the first frame. The
/// last-known categories, recent suggestions, today's entry count, and
/// membership flags render instantly from this cache on every open,
/// and the server refresh runs quietly in the background, merging in
/// without blanking or flashing. A failed refresh keeps the cached
/// values — the screen never falls back to a spinner or a wrong gate
/// state.
///
/// Two layers, same as Home:
/// - **Memory** (process lifetime): synchronous first-frame render on
///   tab switches / re-entry. Outlives the `QuickLogScreen` widget.
/// - **Disk** (flutter_secure_storage, one JSON blob): cold starts
///   show last-known values instead of skeletons. Warmed before the
///   first frame in `main()` via [warmFromDisk].
///
/// Validity rules:
/// - Today's entry count is date-scoped: it applies only when it was
///   computed on the device-local calendar day it claims to count.
///   A new day drops it (the background refresh recomputes it within
///   seconds). The snapshot reports it as not-loaded in that case.
/// - Categories, recent suggestions, and membership persist across
///   days (they move slowly), but the screen still background-refreshes
///   them on EVERY open — persistence is a render seed, never a
///   substitute for the server truth.
///
/// The *absence* of data is cached too: a completed load with an
/// empty category list marks the section loaded, so the UI shows its
/// honest empty state instantly instead of a skeleton.
///
/// Honest-states rule holds: the cache only ever holds real values
/// from the last completed load. It never invents categories,
/// suggestions, counts, or membership.
///
/// Privacy (Juno): cached values live in flutter_secure_storage —
/// Android Keystore-backed EncryptedSharedPreferences, the same
/// encrypted-at-rest store as the auth session and the home cache.
/// Recent-suggestion rows are the user's own on-device log data,
/// already readable by any code in this process; this cache adds no
/// new transmission path.
///
/// Account binding (Round 19c fix, Vera BLOCKING 1): the snapshot is
/// owned by exactly one account. The owner's session email is stored
/// in the disk blob (`ownerEmail`) and in memory; [warmFromDisk] and
/// the login-success hook ([clearIfOwnerMismatch], called from
/// `main.dart`) drop the whole snapshot — memory AND disk — whenever
/// the cached owner differs from the current session account. A
/// blob with no owner (written before this binding existed) is
/// treated as untrusted and dropped the same way as soon as a
/// current account is known. After a drop, the first frame can only
/// show skeletons — never another account's rows. The new account is
/// bound in place of the old one, so the next completed load stamps
/// its loads with the new owner.
class QuickLogCache {
  /// Disk key for the JSON blob.
  static const String storageKey = 'quick_log_cache_v1';

  static final QuickLogCache instance = QuickLogCache._internal();
  QuickLogCache._internal();

  // Injectable storage (same seam as HomeDataCache): unit tests pass
  // in-memory fakes so no test touches platform channels.
  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  @visibleForTesting
  void debugSetStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) {
    _read = read;
    _write = write;
    if (delete != null) _delete = delete;
  }

  @visibleForTesting
  void debugReset() => _resetMemory();

  void _resetMemory() {
    _categories = const [];
    _categoriesLoaded = false;
    _recentSuggestions = const [];
    _recentsLoaded = false;
    _todayCount = 0;
    _countDate = null;
    _isUnlimited = false;
    _isAdmin = false;
    _membershipKnown = false;
    _fetchedAt = null;
    _ownerEmail = null;
  }

  /// The account this snapshot belongs to (normalized session email),
  /// or null when no load has ever been bound to an account.
  String? _ownerEmail;
  String? get ownerEmail => _ownerEmail;

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  /// Binds the (possibly empty) cache to [email] without dropping
  /// data. Used after [clearIfOwnerMismatch] has already enforced
  /// ownership, and by loads that carry the session email.
  void bindToAccount(String? email) {
    final normalized = _normalizeEmail(email);
    if (normalized != null) _ownerEmail = normalized;
  }

  /// Login-success / warm-time ownership enforcement (Vera BLOCKING
  /// 1). If the cached snapshot belongs to a different account than
  /// [email] — or carries data with no recorded owner at all — the
  /// whole snapshot is wiped (memory synchronously, disk
  /// asynchronously) and true is returned. The new account is bound
  /// either way, so the next [applyLoad] stamps its data with the
  /// new owner. A matching owner (or an empty, unowned cache) keeps
  /// everything and returns false. Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = _normalizeEmail(email);
    if (expected == null) return false;
    final hasData =
        _categoriesLoaded || _recentsLoaded || _membershipKnown;
    if (_ownerEmail == expected) return false;
    if (_ownerEmail == null && !hasData) {
      _ownerEmail = expected;
      return false;
    }
    await clear();
    _ownerEmail = expected;
    return true;
  }

  List<QuickLogCategory> _categories = const [];
  bool _categoriesLoaded = false;
  List<QuickLogEntry> _recentSuggestions = const [];
  bool _recentsLoaded = false;
  int _todayCount = 0;

  /// Local `yyyy-MM-dd` the cached [_todayCount] was computed for.
  String? _countDate;
  bool _isUnlimited = false;
  bool _isAdmin = false;
  bool _membershipKnown = false;
  DateTime? _fetchedAt;

  /// Synchronous first-frame snapshot for `QuickLogScreen.initState`.
  ///
  /// A section with its loaded flag false means "no cache" — the
  /// caller shows its skeleton. Loaded-but-empty values mean "loaded,
  /// honestly empty" — the caller shows its honest empty state.
  /// Membership with [QuickLogCacheSnapshot.membershipKnown] false
  /// means the gate state is unknown — the caller shows a skeleton,
  /// never a guessed gate (never flashes "Standard Access" at a
  /// member, or the AI tray at a non-member).
  QuickLogCacheSnapshot get snapshot {
    final today = _dayString(DateTime.now());
    final countFresh = _countDate != null && _countDate == today;
    return QuickLogCacheSnapshot(
      categories: _categoriesLoaded ? _categories : const [],
      categoriesLoaded: _categoriesLoaded,
      recentSuggestions: _recentsLoaded ? _recentSuggestions : const [],
      recentsLoaded: _recentsLoaded,
      todayCount: countFresh ? _todayCount : 0,
      todayCountLoaded: countFresh,
      isUnlimited: _isUnlimited,
      isAdmin: _isAdmin,
      membershipKnown: _membershipKnown,
      ownerEmail: _ownerEmail,
    );
  }

  /// Wipes memory + disk. Called by [clearIfOwnerMismatch] on an
  /// account change, and the hook for a future
  /// logout/account-deletion flow. Never throws.
  Future<void> clear() async {
    _resetMemory();
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  /// Stores one completed Quick Log load. Returns true when the
  /// in-memory snapshot changed (kept for parity with HomeDataCache;
  /// the screen's atomic setState already ran with the same values).
  bool applyLoad({
    required List<QuickLogCategory> categories,
    required List<QuickLogEntry> recentSuggestions,
    required int todayCount,
    required bool isUnlimited,
    required bool isAdmin,
    DateTime? now,
    String? ownerEmail,
  }) {
    final at = now ?? DateTime.now();
    final newOwner = _normalizeEmail(ownerEmail);
    final changed = !_categoriesLoaded ||
        !_listEqual(_categories, categories, (c) => c.toSyncJson()) ||
        !_recentsLoaded ||
        !_listEqual(
            _recentSuggestions, recentSuggestions, _entryJson) ||
        _countDate != _dayString(at) ||
        _todayCount != todayCount ||
        !_membershipKnown ||
        _isUnlimited != isUnlimited ||
        _isAdmin != isAdmin ||
        (newOwner != null && newOwner != _ownerEmail);
    if (newOwner != null) _ownerEmail = newOwner;
    _categories = categories;
    _categoriesLoaded = true;
    _recentSuggestions = recentSuggestions;
    _recentsLoaded = true;
    _todayCount = todayCount;
    _countDate = _dayString(at);
    _isUnlimited = isUnlimited;
    _isAdmin = isAdmin;
    _membershipKnown = true;
    _fetchedAt = at;
    return changed;
  }

  /// Stores a partial update after a local mutation the screen already
  /// knows the outcome of (save / repeat-from-recent): today's count
  /// (and recents, when the caller recomputed them) update in place so
  /// the next open seeds the fresh numbers, not the pre-mutation ones.
  void applyCounts({
    required int todayCount,
    List<QuickLogEntry>? recentSuggestions,
    DateTime? now,
  }) {
    _todayCount = todayCount;
    _countDate = _dayString(now ?? DateTime.now());
    if (recentSuggestions != null) {
      _recentSuggestions = recentSuggestions;
      _recentsLoaded = true;
    }
    _fetchedAt = now ?? DateTime.now();
  }

  /// Persists the current memory state to disk. No-op when nothing
  /// has ever loaded. Never throws — storage failures keep the memory
  /// cache and are silently dropped.
  Future<void> persist() async {
    if (!_categoriesLoaded && !_recentsLoaded && !_membershipKnown) {
      return;
    }
    try {
      await _write(storageKey, jsonEncode(_toJson()));
    } catch (_) {
      // Memory cache stays; disk just won't have this refresh.
    }
  }

  /// Cold-start warm: reads the disk blob into memory, applying the
  /// validity rules. Call once before `runApp()`. Never throws — a
  /// missing or corrupt cache starts empty.
  ///
  /// Sections already loaded in memory are left alone (warm is only
  /// meant to fill an empty cache).
  ///
  /// Account binding (Vera BLOCKING 1): when [currentEmail] (the
  /// stored session account) is known, a blob owned by a different
  /// account — or by no recorded account — is dropped entirely
  /// (memory + disk) instead of loaded, and the current account is
  /// bound in its place. Without a known current account the blob
  /// loads as before; the login-success hook enforces ownership
  /// again before any screen can mount.
  Future<void> warmFromDisk({DateTime? now, String? currentEmail}) async {
    final at = now ?? DateTime.now();
    final map = await _readCacheMap();
    if (map == null) return;
    final expected = _normalizeEmail(currentEmail);
    if (expected != null) {
      final rawOwner = map['ownerEmail'];
      final blobOwner = rawOwner is String ? _normalizeEmail(rawOwner) : null;
      if (blobOwner != expected) {
        _resetMemory();
        _ownerEmail = expected;
        try {
          await _delete(storageKey);
        } catch (_) {}
        return;
      }
    }
    try {
      _applyDiskMap(map, at);
    } catch (_) {
      // Malformed blob (wrong types): start empty. Never crash startup.
    }
  }

  void _applyDiskMap(Map<String, dynamic> map, DateTime at) {
    final fetchedAt = DateTime.tryParse(map['fetchedAt'] as String? ?? '');
    if (fetchedAt == null) return;
    final rawOwner = map['ownerEmail'];
    if (rawOwner is String) _ownerEmail = _normalizeEmail(rawOwner);

    if (!_categoriesLoaded && map['categoriesLoaded'] == true) {
      _categories = _parseList(
          map['categories'], (m) => QuickLogCategory.fromJson(m));
      _categoriesLoaded = true;
    }
    if (!_recentsLoaded && map['recentsLoaded'] == true) {
      _recentSuggestions =
          _parseList(map['recents'], (m) => QuickLogEntry.fromJson(m));
      _recentsLoaded = true;
    }
    if (!_membershipKnown && map['membershipKnown'] == true) {
      _isUnlimited = map['isUnlimited'] == true;
      _isAdmin = map['isAdmin'] == true;
      _membershipKnown = true;
    }
    // Today's count is date-scoped: only a count computed today
    // (device-local) seeds the first frame.
    final countDate = map['countDate'] as String?;
    if (countDate != null && countDate == _dayString(at)) {
      _todayCount = (map['todayCount'] as num?)?.toInt() ?? 0;
      _countDate = countDate;
    }
    if (_categoriesLoaded || _recentsLoaded || _membershipKnown) {
      _fetchedAt = fetchedAt;
    }
  }

  static List<T> _parseList<T>(
      dynamic raw, T Function(Map<String, dynamic>) fromJson) {
    if (raw is! List) return <T>[];
    final out = <T>[];
    for (final item in raw) {
      if (item is Map<String, dynamic>) {
        try {
          out.add(fromJson(item));
        } catch (_) {
          // Skip malformed rows — never fail the whole cache.
        }
      }
    }
    return out;
  }

  Future<Map<String, dynamic>?> _readCacheMap() async {
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _toJson() => {
        'ownerEmail': _ownerEmail,
        'fetchedAt': _fetchedAt?.toIso8601String(),
        'categoriesLoaded': _categoriesLoaded,
        'categories': _categories.map((c) => c.toSyncJson()).toList(),
        'recentsLoaded': _recentsLoaded,
        // Entry rows round-trip through _entryJson/fromJson. (Not
        // toSyncJson: that stamps a fresh updatedAt on every call,
        // which would defeat the equality check in applyLoad.)
        'recents': _recentSuggestions.map(_entryJson).toList(),
        'todayCount': _todayCount,
        'countDate': _countDate,
        'membershipKnown': _membershipKnown,
        'isUnlimited': _isUnlimited,
        'isAdmin': _isAdmin,
      };

  /// Stable serializer for a log entry (no volatile fields).
  static Map<String, dynamic> _entryJson(QuickLogEntry e) => {
        'id': e.id,
        'categoryId': e.categoryId,
        'body': e.body,
        'chips': e.chips,
        'manualText': e.manualText,
        'timestamp': e.timestamp,
      };

  static bool _listEqual<T>(
      List<T> a, List<T> b, Map<String, dynamic> Function(T) toJson) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (jsonEncode(toJson(a[i])) != jsonEncode(toJson(b[i]))) {
        return false;
      }
    }
    return true;
  }

  static String _dayString(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

/// First-frame snapshot handed to `QuickLogScreen.initState`. See
/// [QuickLogCache.snapshot] for the loaded-flag contract.
class QuickLogCacheSnapshot {
  final List<QuickLogCategory> categories;
  final bool categoriesLoaded;
  final List<QuickLogEntry> recentSuggestions;
  final bool recentsLoaded;
  final int todayCount;
  final bool todayCountLoaded;
  final bool isUnlimited;
  final bool isAdmin;
  final bool membershipKnown;

  /// Account that owns this snapshot (normalized session email), or
  /// null when the cache was never bound to an account.
  final String? ownerEmail;

  const QuickLogCacheSnapshot({
    required this.categories,
    required this.categoriesLoaded,
    required this.recentSuggestions,
    required this.recentsLoaded,
    required this.todayCount,
    required this.todayCountLoaded,
    required this.isUnlimited,
    required this.isAdmin,
    required this.membershipKnown,
    this.ownerEmail,
  });
}
