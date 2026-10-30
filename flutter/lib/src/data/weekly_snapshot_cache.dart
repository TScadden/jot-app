import 'package:flutter/foundation.dart';
import 'package:tabs_lab/src/data/weekly_snapshot.dart';

/// App-session cache for Weekly Snapshot results (founder defect,
/// Oct 30, 2026: "Every time I leave the home screen and come back it
/// refreshes the weekly snapshot and has to load again").
///
/// Why this exists: `MainShell` has no IndexedStack / keep-alive, so
/// every tab switch destroys the Home widget tree — including the
/// `WeeklySnapshotCard` State that used to own the per-metric result
/// cache. The cache now lives here, in an app-lifetime owner modeled
/// on HealthHistoryStore.instance / HomeDataCache (memory-only:
/// nothing is persisted, so a cold start still runs the normal
/// foreground load). The card's State keeps only per-visit UI state
/// (selection, timers, generation guards) and reads/writes this cache.
///
/// Staleness policy — day-boundary correctness: every entry is
/// stamped at store time with the local calendar day AND the local
/// week (the Monday of that week) it belongs to, both derived from
/// the load time. [lookup] serves an entry only when BOTH stamps
/// match the current day/week; an entry from a previous day is a
/// miss (and is evicted), so yesterday's week can never paint as the
/// current week. Same-day hits are still revalidated in the
/// background by the card on every return.
///
/// Only successful loads are stored — the card writes here only on
/// its success path, so a throwing loader never poisons an entry.
///
/// Account binding (parity with HomeDataCache, Vera BLOCKING 1
/// pattern): the cache is owned by one account. `main.dart` calls
/// [clearIfOwnerMismatch] on login/register success and [clear] on
/// session expiry, alongside the other home caches, so one account's
/// week never paints under another account on the same device.
class WeeklySnapshotCache {
  static final WeeklySnapshotCache instance = WeeklySnapshotCache._();

  WeeklySnapshotCache._();

  /// A fresh, non-singleton instance (the HealthHistoryStore
  /// testInstance pattern): tests inject one so seeded entries never
  /// leak across cases through the shared singleton's map.
  factory WeeklySnapshotCache.testInstance() => WeeklySnapshotCache._();

  final Map<SnapshotMetric, WeeklySnapshotCacheEntry> _entries = {};

  /// The account this cache belongs to (normalized session email),
  /// or null when no login hook has bound an owner yet.
  String? _ownerEmail;
  String? get ownerEmail => _ownerEmail;

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  /// Stores a successful load for [metric], stamped with the local
  /// day and week of [loadedAt] (defaults to now).
  void store(
    SnapshotMetric metric,
    WeeklySnapshotMetricData data, {
    DateTime? loadedAt,
  }) {
    final at = loadedAt ?? DateTime.now();
    _entries[metric] = WeeklySnapshotCacheEntry(
      data: data,
      dayKey: dayKeyFor(at),
      weekKey: weekKeyFor(at),
      loadedAt: at,
    );
  }

  /// The cached data for [metric] when its entry belongs to the
  /// current local day/week; otherwise null (a miss). A stale entry
  /// is evicted on the way out so it can never be served later.
  WeeklySnapshotMetricData? lookup(SnapshotMetric metric, {DateTime? now}) {
    final entry = _entries[metric];
    if (entry == null) return null;
    final at = now ?? DateTime.now();
    if (entry.dayKey != dayKeyFor(at) || entry.weekKey != weekKeyFor(at)) {
      _entries.remove(metric);
      return null;
    }
    return entry.data;
  }

  /// Drops every entry (session expiry / logout). Never throws.
  void clear() {
    _entries.clear();
    _ownerEmail = null;
  }

  /// Login-success ownership enforcement (parity with
  /// HomeDataCache.clearIfOwnerMismatch): if entries are bound to
  /// a different account than [email] — or carry data with no
  /// recorded owner — they are dropped and the new account is bound.
  /// A matching owner (or an empty, unowned cache) keeps everything.
  /// Returns true when entries were dropped.
  bool clearIfOwnerMismatch(String? email) {
    final expected = _normalizeEmail(email);
    if (expected == null) return false;
    if (_ownerEmail == expected) return false;
    if (_ownerEmail == null && _entries.isEmpty) {
      _ownerEmail = expected;
      return false;
    }
    _entries.clear();
    _ownerEmail = expected;
    return true;
  }

  @visibleForTesting
  void debugReset() => clear();

  /// Local calendar day stamp, `YYYY-MM-DD`.
  static String dayKeyFor(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Local week stamp: the [dayKeyFor] of the Monday of [dt]'s week.
  static String weekKeyFor(DateTime dt) {
    final monday = DateTime(dt.year, dt.month, dt.day)
        .subtract(Duration(days: dt.weekday - DateTime.monday));
    return dayKeyFor(monday);
  }
}

/// One cached Weekly Snapshot result plus the local day/week it
/// belongs to. See [WeeklySnapshotCache] for the staleness policy.
class WeeklySnapshotCacheEntry {
  final WeeklySnapshotMetricData data;

  /// Local `YYYY-MM-DD` of the load.
  final String dayKey;

  /// Local `YYYY-MM-DD` of the Monday of the load's week.
  final String weekKey;

  /// When the load completed.
  final DateTime loadedAt;

  const WeeklySnapshotCacheEntry({
    required this.data,
    required this.dayKey,
    required this.weekKey,
    required this.loadedAt,
  });
}
