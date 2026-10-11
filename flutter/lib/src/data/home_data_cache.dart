import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/health_repository.dart';

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
  }

  TodayVitals? _vitals;
  bool _vitalsLoaded = false;
  int? _currentStreak;
  int? _bestStreak;
  bool _streakLoaded = false;
  DateTime? _fetchedAt;

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
    return HomeCacheSnapshot(
      vitals: vitalsFresh ? _vitals : null,
      vitalsLoaded: vitalsFresh,
      currentStreak: streakFresh ? _currentStreak : null,
      bestStreak: streakFresh ? _bestStreak : null,
      streakLoaded: streakFresh,
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
  }

  /// Stores a completed vitals load (the repository never throws, so
  /// every return is an honest result — including all-null biometrics
  /// when Health Connect isn't connected). Returns true when the
  /// in-memory snapshot changed.
  bool applyVitals(TodayVitals vitals, {DateTime? now}) {
    final changed = !_vitalsLoaded || !_vitalsEqual(_vitals, vitals);
    _vitals = vitals;
    _vitalsLoaded = true;
    _fetchedAt = now ?? DateTime.now();
    return changed;
  }

  /// Stores a completed streak load. Nulls are honest (logged out or
  /// backend failure) and cached as "loaded, empty". Returns true when
  /// the in-memory snapshot changed.
  bool applyStreak(int? current, int? best, {DateTime? now}) {
    final changed = !_streakLoaded ||
        _currentStreak != current ||
        _bestStreak != best;
    _currentStreak = current;
    _bestStreak = best;
    _streakLoaded = true;
    _fetchedAt = now ?? DateTime.now();
    return changed;
  }

  /// Persists the current memory state to disk. No-op when nothing has
  /// ever loaded. Never throws — storage failures keep the memory
  /// cache and are silently dropped.
  Future<void> persist() async {
    if (!_vitalsLoaded && !_streakLoaded) return;
    try {
      await _write(storageKey, jsonEncode(_toJson()));
    } catch (_) {
      // Memory cache stays; disk just won't have this refresh.
    }
  }

  /// Cold-start warm: reads the disk blob into memory, applying the
  /// staleness policy. Call once before `runApp()`. Never throws — a
  /// missing or corrupt cache starts empty.
  ///
  /// Sections already loaded in memory are left alone (warm is only
  /// meant to fill an empty cache).
  Future<void> warmFromDisk({DateTime? now}) async {
    final at = now ?? DateTime.now();
    final map = await _readCacheMap();
    if (map == null) return;
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
    if (fetchedAt == null) return;

    // Vitals are date-bound: only today's cache applies.
    if (!_vitalsLoaded &&
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
    if (!_streakLoaded &&
        map['streakLoaded'] == true &&
        at.difference(fetchedAt).abs() <= streakMaxAge) {
      _currentStreak = map['currentStreak'] as int?;
      _bestStreak = map['bestStreak'] as int?;
      _streakLoaded = true;
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

  const HomeCacheSnapshot({
    required this.vitals,
    required this.vitalsLoaded,
    required this.currentStreak,
    required this.bestStreak,
    required this.streakLoaded,
  });
}
