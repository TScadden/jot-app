import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/widget_sync.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';

/// Round 16 — stale-while-revalidate cache for the home screen's numbers
/// (vitals strip + streak pills).
///
/// Founder's complaint: after the initial count-up, switching tabs and
/// coming back flashed empty numbers for a second while the data
/// reloaded. Now the last-known numbers render instantly on every mount
/// and the refresh runs in the background, swapping in silently when it
/// differs.
///
/// Two layers:
/// - **Memory** (process lifetime): synchronous first-frame render on
///   tab switches. Outlives the `HomeScreen` widget, which is disposed
///   on every tab switch.
/// - **Disk** (flutter_secure_storage, one JSON blob): cold starts show
///   last-known numbers instead of "--" everywhere. Warmed before the
///   first frame in `main()` via [warmFromDisk].
///
/// Staleness policy (documented choice):
/// - Vitals are date-bound ("today's" metrics): the cached vitals apply
///   only when they were fetched on the device-local calendar day. A new
///   day drops them and the fresh load runs as usual.
/// - Streaks move slowly: cached streaks apply for up to
///   [streakMaxAge] (7 days), then drop. The background refresh corrects
///   them within seconds anyway.
///
/// The *absence* of data is cached too: a completed load that found no
/// data (e.g. Health Connect not connected) marks the section loaded, so
/// the UI shows "--" instantly instead of a loading shimmer.
///
/// Honest-states rule holds: the cache only ever holds real values from
/// the last completed load. A failed refresh keeps the old cache; it
/// never invents numbers.
///
/// Privacy (Juno-reviewed): cached health values live in
/// flutter_secure_storage — Android Keystore-backed
/// EncryptedSharedPreferences, the same encrypted-at-rest store as the
/// auth session (see `session_store.dart`). The values are the user's
/// own on-device data (already readable by any code in this process)
/// and this cache adds no new transmission path.
///
/// Account binding (Round 19c fix, Vera BLOCKING 1 — parity with
/// [QuickLogCache]): the snapshot is owned by exactly one account.
/// The owner's session email is stored in the disk blob
/// (`ownerEmail`) and in memory; [warmFromDisk] and the login-success
/// hook ([clearIfOwnerMismatch], called from `main.dart`) drop the
/// whole snapshot — memory AND disk — whenever the cached owner
/// differs from the current session account. A blob with no owner
/// (written before this binding existed) is dropped the same way as
/// soon as a current account is known.
class HomeDataCache {
  /// Disk key for the JSON blob.
  static const String storageKey = 'home_data_cache_v1';

  /// Streak cache max age. Vitals additionally require "fetched today".
  static const Duration streakMaxAge = Duration(days: 7);

  static final HomeDataCache instance = HomeDataCache._internal();
  HomeDataCache._internal();

  // CountUpGate-style injectable storage: unit tests pass in-memory
  // fakes so no test touches platform channels.
  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) => const FlutterSecureStorage().write(key: key, value: value);
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
    _vitals = null;
    _vitalsLoaded = false;
    _currentStreak = null;
    _bestStreak = null;
    _streakLoaded = false;
    _fetchedAt = null;
    _counters = const [];
    _countersLoaded = false;
    _countersFetchedAt = null;
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
  /// 1, parity with QuickLogCache). If the cached snapshot belongs
  /// to a different account than [email] — or carries data with no
  /// recorded owner at all — the whole snapshot is wiped (memory
  /// synchronously, disk asynchronously) and true is returned. The
  /// new account is bound either way, so the next load stamps its
  /// data with the new owner. A matching owner (or an empty, unowned
  /// cache) keeps everything and returns false. Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = _normalizeEmail(email);
    if (expected == null) return false;
    final hasData = _vitalsLoaded || _streakLoaded || _countersLoaded;
    if (_ownerEmail == expected) return false;
    if (_ownerEmail == null && !hasData) {
      _ownerEmail = expected;
      return false;
    }
    await clear();
    _ownerEmail = expected;
    return true;
  }

  TodayVitals? _vitals;
  bool _vitalsLoaded = false;
  int? _currentStreak;
  int? _bestStreak;
  bool _streakLoaded = false;
  DateTime? _fetchedAt;

  // ── Round 34: event counters ─────────────────────────────────────
  /// The ACTIVE counters from the last completed profile pull, in
  /// Settings list order. The day counts are NOT cached — they are
  /// recomputed from [EventCounterItem.targetDate] at render time,
  /// so a cached counter can never show a stale day count across a
  /// local-midnight rollover.
  List<EventCounterItem> _counters = const [];
  bool _countersLoaded = false;
  DateTime? _countersFetchedAt;

  /// Counters cache max age (same policy as streaks: the values move
  /// slowly — they change only when the user edits Settings — and the
  /// background refresh corrects them within seconds anyway).
  static const Duration countersMaxAge = Duration(days: 7);

  /// Synchronous first-frame snapshot for `HomeScreen.initState`.
  ///
  /// A section with its loaded flag false means "no cache" — the caller
  /// shows its normal loading state. Loaded-but-null values mean
  /// "loaded, honestly empty" — the caller shows "--" instantly.
  ///
  /// Juno (round 16): the staleness policy is enforced here too, not
  /// just on the disk path — if the process lives past local midnight,
  /// yesterday's in-memory vitals must not seed a remount.
  HomeCacheSnapshot get snapshot {
    final now = DateTime.now();
    final vitalsFresh = _vitalsLoaded &&
        _fetchedAt != null &&
        _dayString(_fetchedAt!) == _dayString(now);
    final streakFresh = _streakLoaded &&
        _fetchedAt != null &&
        now.difference(_fetchedAt!).abs() <= streakMaxAge;
    final countersFresh = _countersLoaded &&
        _countersFetchedAt != null &&
        now.difference(_countersFetchedAt!).abs() <= countersMaxAge;
    return HomeCacheSnapshot(
      vitals: vitalsFresh ? _vitals : null,
      vitalsLoaded: vitalsFresh,
      currentStreak: streakFresh ? _currentStreak : null,
      bestStreak: streakFresh ? _bestStreak : null,
      streakLoaded: streakFresh,
      counters: countersFresh ? _counters : const [],
      countersLoaded: countersFresh,
      ownerEmail: _ownerEmail,
    );
  }

  /// Wipes memory + disk. Hook for the future logout/account-deletion
  /// flow (privacy §5 promises users can purge all personal and health
  /// data on request). Never throws.
  Future<void> clear() async {
    _resetMemory();
    try {
      await _delete(storageKey);
    } catch (_) {}
    // Round 50 — every cache clear is also a widget clear: logout,
    // account delete, session expiry, and owner-mismatch all funnel
    // through here, and the home-screen widget must never keep a
    // signed-out (or previous) account's numbers. Fire-and-forget;
    // WidgetSync never throws.
    unawaited(WidgetSync.clear());
  }

  /// Stores a completed vitals load (the repository never throws, so
  /// every return is an honest result — including all-null biometrics
  /// when Health Connect isn't connected). Returns true when the
  /// in-memory snapshot changed.
  bool applyVitals(TodayVitals vitals,
      {DateTime? now, String? ownerEmail}) {
    final changed = !_vitalsLoaded || !_vitalsEqual(_vitals, vitals);
    _vitals = vitals;
    _vitalsLoaded = true;
    _fetchedAt = now ?? DateTime.now();
    bindToAccount(ownerEmail);
    return changed;
  }

  /// Round 59 — mirrors a JUST-CREATED entry's effect on today's
  /// log count into the snapshot, preserving every other vitals
  /// field, so the caller can [persist] (which pushes the widget)
  /// and the strip + widget move the moment an entry is created —
  /// not whenever Home next happens to reload.
  ///
  /// Why this exists: entry creation lives OUTSIDE Home (Quick Log's
  /// save / re-log, History's repeat / delete). Those paths updated
  /// only [QuickLogCache]; the Home snapshot kept the count from its
  /// last full load, and the widget kept showing it (founder,
  /// Round 58 phone test: strip 7 after a Home reload, widget 1).
  ///
  /// Staleness guard (same policy as [snapshot]): the preserved
  /// biometrics are carried over ONLY when the cached vitals are
  /// from today — a process living past local midnight must not
  /// resurrect yesterday's heart rate / calories / sleep as today's
  /// by re-stamping them. Stale or absent vitals seed a count-only
  /// vitals section (biometrics honestly null → "--"), which the
  /// next Home load replaces wholesale via [applyVitals].
  /// Returns true when the in-memory snapshot changed.
  bool applyLogCountToday(int count, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final vitalsFresh = _vitalsLoaded &&
        _fetchedAt != null &&
        _dayString(_fetchedAt!) == _dayString(at);
    final base = vitalsFresh ? _vitals : null;
    final next = TodayVitals(
      heartRate: base?.heartRate,
      activeCalories: base?.activeCalories,
      sleepMinutes: base?.sleepMinutes,
      logCountToday: count,
    );
    final changed = !vitalsFresh || !_vitalsEqual(_vitals, next);
    _vitals = next;
    _vitalsLoaded = true;
    _fetchedAt = at;
    return changed;
  }

  /// Stores a completed streak load. Nulls are honest (logged out or
  /// backend failure) and cached as "loaded, empty". Returns true when
  /// the in-memory snapshot changed.
  bool applyStreak(int? current, int? best,
      {DateTime? now, String? ownerEmail}) {
    final changed = !_streakLoaded ||
        _currentStreak != current ||
        _bestStreak != best;
    _currentStreak = current;
    _bestStreak = best;
    _streakLoaded = true;
    _fetchedAt = now ?? DateTime.now();
    bindToAccount(ownerEmail);
    return changed;
  }

  /// Stores a completed counters load (the ACTIVE counters only —
  /// the caller filters archived out via [activeEventCounters], so
  /// an archived counter is never persisted or rendered). An empty
  /// list is an honest completed load ("no active counters") and is
  /// cached as loaded. Returns true when the snapshot changed.
  bool applyCounters(List<EventCounterItem> counters,
      {DateTime? now, String? ownerEmail}) {
    final changed = !_countersLoaded || !_countersEqual(_counters, counters);
    _counters = List<EventCounterItem>.unmodifiable(counters);
    _countersLoaded = true;
    _countersFetchedAt = now ?? DateTime.now();
    bindToAccount(ownerEmail);
    return changed;
  }

  static bool _countersEqual(
      List<EventCounterItem> a, List<EventCounterItem> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Persists the current memory state to disk. No-op when nothing has
  /// ever loaded. Never throws — storage failures keep the memory
  /// cache and are silently dropped.
  Future<void> persist() async {
    if (!_vitalsLoaded && !_streakLoaded && !_countersLoaded) return;
    try {
      await _write(storageKey, jsonEncode(_toJson()));
    } catch (_) {
      // Memory cache stays; disk just won't have this refresh.
    }
    // Round 50 — persist() is the choke point every fresh Home load
    // lands through (HomeScreen's vitals/streak and counters loads
    // both end here), so the home-screen widget is pushed the SAME
    // snapshot Home renders from, every refresh. A completed load
    // reaching persist() only ever happens inside a signed-in Home
    // session (Home mounts post-login only), so the payload is
    // signed-in; the signed-out widget state is owned exclusively
    // by clear(). Fire-and-forget; WidgetSync never throws and
    // never blocks Home.
    unawaited(WidgetSync.pushSnapshot(snapshot, signedIn: true));
  }

  /// Cold-start warm: reads the disk blob into memory, applying the
  /// staleness policy. Call once before `runApp()`. Never throws — a
  /// missing or corrupt cache starts empty.
  ///
  /// Sections already loaded in memory are left alone (warm is only
  /// meant to fill an empty cache).
  ///
  /// Account binding (Vera BLOCKING 1): when [currentEmail] (the
  /// stored session account) is known, a blob owned by a different
  /// account — or by no recorded account — is dropped entirely
  /// (memory + disk) instead of loaded, and the current account is
  /// bound in its place.
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
        // Round 52 — this mismatch path bypasses clear() (it resets
        // memory inline), so it must clear the widget explicitly:
        // otherwise a dropped previous-account blob leaves that
        // account's numbers sitting in the widget store until Home
        // next mounts. Fire-and-forget; WidgetSync never throws.
        unawaited(WidgetSync.clear());
        return;
      }
    }
    try {
      _applyDiskMap(map, at);
    } catch (_) {
      // Malformed blob (wrong types): start empty. Never crash startup.
    }
  }

  /// Applies a decoded disk blob to memory, enforcing the staleness
  /// policy. May throw on malformed types — the caller guards it.
  void _applyDiskMap(Map<String, dynamic> map, DateTime at) {
    final fetchedAt = DateTime.tryParse(map['fetchedAt'] as String? ?? '');
    // Round 34: a counters-only blob carries no vitals/streak stamp
    // (fetchedAt) — it must not bail before the counters section,
    // which judges staleness on its own stamp.
    final countersAt =
        DateTime.tryParse(map['countersFetchedAt'] as String? ?? '') ??
            fetchedAt;
    if (fetchedAt == null && countersAt == null) return;
    final rawOwner = map['ownerEmail'];
    if (rawOwner is String) _ownerEmail = _normalizeEmail(rawOwner);

    // Vitals are date-bound: only today's cache applies.
    if (fetchedAt != null &&
        !_vitalsLoaded &&
        map['vitalsLoaded'] == true &&
        _dayString(fetchedAt) == _dayString(at)) {
      final v = map['vitals'] as Map<String, dynamic>?;
      _vitals = TodayVitals(
        heartRate: v?['heartRate'] as int?,
        activeCalories: v?['activeCalories'] as int?,
        sleepMinutes: v?['sleepMinutes'] as int?,
        logCountToday: (v?['logCountToday'] as int?) ?? 0,
      );
      _vitalsLoaded = true;
    }
    // Streaks: valid up to streakMaxAge.
    if (fetchedAt != null &&
        !_streakLoaded &&
        map['streakLoaded'] == true &&
        at.difference(fetchedAt).abs() <= streakMaxAge) {
      _currentStreak = map['currentStreak'] as int?;
      _bestStreak = map['bestStreak'] as int?;
      _streakLoaded = true;
    }
    // Counters (round 34): valid up to countersMaxAge, judged on
    // their own fetch stamp (falling back to the blob's stamp for
    // blobs written before the counters stamp existed — in practice
    // those blobs carry no counters at all).
    if (countersAt != null &&
        !_countersLoaded &&
        map['countersLoaded'] == true &&
        at.difference(countersAt).abs() <= countersMaxAge) {
      final raw = map['counters'] as List?;
      _counters = List<EventCounterItem>.unmodifiable([
        for (final e in raw ?? const [])
          if (e is Map<String, dynamic>) EventCounterItem.fromMap(e),
      ]);
      _countersLoaded = true;
      _countersFetchedAt = countersAt;
    }
    if (_vitalsLoaded || _streakLoaded) _fetchedAt = fetchedAt;
  }

  /// Reads and decodes the disk blob. Null on missing/corrupt —
  /// the caller starts empty.
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
        'vitalsLoaded': _vitalsLoaded,
        'vitals': _vitals == null
            ? null
            : {
                'heartRate': _vitals!.heartRate,
                'activeCalories': _vitals!.activeCalories,
                'sleepMinutes': _vitals!.sleepMinutes,
                'logCountToday': _vitals!.logCountToday,
              },
        'streakLoaded': _streakLoaded,
        'currentStreak': _currentStreak,
        'bestStreak': _bestStreak,
        'countersLoaded': _countersLoaded,
        'counters': _counters.map((c) => c.toMap()).toList(),
        'countersFetchedAt': _countersFetchedAt?.toIso8601String(),
      };

  static bool _vitalsEqual(TodayVitals? a, TodayVitals? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return false;
    return a.heartRate == b.heartRate &&
        a.activeCalories == b.activeCalories &&
        a.sleepMinutes == b.sleepMinutes &&
        a.logCountToday == b.logCountToday;
  }

  static String _dayString(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

/// First-frame snapshot handed to `HomeScreen.initState`. See
/// [HomeDataCache.snapshot] for the loaded-flag contract.
class HomeCacheSnapshot {
  final TodayVitals? vitals;
  final bool vitalsLoaded;
  final int? currentStreak;
  final int? bestStreak;
  final bool streakLoaded;

  /// Round 34 — the cached ACTIVE counters in Settings list order
  /// (empty when [countersLoaded] is false or no counters are
  /// active). Day counts are recomputed at render time.
  final List<EventCounterItem> counters;
  final bool countersLoaded;

  /// Account that owns this snapshot (normalized session email), or
  /// null when the cache was never bound to an account.
  final String? ownerEmail;

  const HomeCacheSnapshot({
    required this.vitals,
    required this.vitalsLoaded,
    required this.currentStreak,
    required this.bestStreak,
    required this.streakLoaded,
    this.counters = const [],
    this.countersLoaded = false,
    this.ownerEmail,
  });
}
