import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data.dart';

/// Round 25 — stale-while-revalidate cache for the Heart screen,
/// patterned on [HomeDataCache] (round 16):
///
/// - **Memory** (process lifetime): per-date sample series, so tab
///   switches and date re-picks render instantly while a quiet
///   background refresh runs.
/// - **Disk** (flutter_secure_storage, one JSON blob): the most
///   recently loaded date's series, so a cold start shows last-known
///   values instead of "--" everywhere. Warmed before first paint via
///   [warmFromDisk] when the Heart screen first mounts (the screen
///   also works memory-only if warm is skipped).
///
/// Founder rules:
/// - Only VALID samples (bpm > 0) are ever stored — a 0 is a failed
///   read and is never cached (enforced in [apply]: the series is run
///   through [validHrSamples] before it touches memory or disk).
/// - The cache only holds real values from a completed load; a failed
///   refresh keeps the old cache.
///
/// Account binding (parity with HomeDataCache / QuickLogCache, Vera
/// round-19c rule): the snapshot is owned by one account; a differing
/// or missing owner drops the whole snapshot as soon as a current
/// account is known. Health values are the user's own on-device data
/// in the same Keystore-backed store as the auth session; no new
/// transmission path.
class HeartDataCache {
  static const String storageKey = 'heart_data_cache_v1';

  static final HeartDataCache instance = HeartDataCache._internal();
  HeartDataCache._internal();

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
    _byDate.clear();
    _lastSyncAt = null;
    _ownerEmail = null;
    _diskDateStr = null;
  }

  String? _ownerEmail;
  String? get ownerEmail => _ownerEmail;

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  void bindToAccount(String? email) {
    final normalized = _normalizeEmail(email);
    if (normalized != null) _ownerEmail = normalized;
  }

  /// Ownership enforcement — same contract as HomeDataCache: a cache
  /// owned by a different account (or carrying data with no recorded
  /// owner) is wiped; a matching owner keeps everything. Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = _normalizeEmail(email);
    if (expected == null) return false;
    final hasData = _byDate.isNotEmpty;
    if (_ownerEmail == expected) return false;
    if (_ownerEmail == null && !hasData) {
      _ownerEmail = expected;
      return false;
    }
    await clear();
    _ownerEmail = expected;
    return true;
  }

  final Map<String, List<HrSample>> _byDate = {};
  DateTime? _lastSyncAt;
  String? _diskDateStr;

  /// When the last successful load completed (any date) — drives the
  /// Health Connect row's "Synced … ago" subtitle.
  DateTime? get lastSyncAt => _lastSyncAt;

  /// Synchronous snapshot for [dateStr] ("YYYY-MM-DD"), or null when
  /// nothing has loaded for that date yet.
  HeartDayData? snapshot(String dateStr) {
    final samples = _byDate[dateStr];
    if (samples == null) return null;
    return HeartDayData.fromSamples(samples);
  }

  bool hasDate(String dateStr) => _byDate.containsKey(dateStr);

  /// Stores a completed load for [dateStr]. The series is filtered to
  /// valid samples first — zeros never reach the cache. Returns the
  /// derived data the UI should render.
  HeartDayData apply(String dateStr, List<HrSample> raw,
      {DateTime? now, String? ownerEmail}) {
    final valid = validHrSamples(raw);
    _byDate[dateStr] = valid;
    _diskDateStr = dateStr;
    _lastSyncAt = now ?? DateTime.now();
    bindToAccount(ownerEmail);
    return HeartDayData.fromSamples(valid);
  }

  /// Persists the most recently applied date's series + sync time.
  /// Never throws.
  Future<void> persist() async {
    final dateStr = _diskDateStr;
    if (dateStr == null) return;
    final samples = _byDate[dateStr];
    if (samples == null) return;
    try {
      await _write(
        storageKey,
        jsonEncode({
          'ownerEmail': _ownerEmail,
          'dateStr': dateStr,
          'fetchedAt': _lastSyncAt?.toIso8601String(),
          'samples': [
            for (final s in samples) {'t': s.timeMs, 'bpm': s.bpm}
          ],
        }),
      );
    } catch (_) {
      // Memory cache stays; disk just won't have this refresh.
    }
  }

  /// Cold-start warm from the disk blob. Never throws — a missing or
  /// corrupt blob starts empty. Owner enforcement mirrors
  /// [clearIfOwnerMismatch].
  Future<void> warmFromDisk({String? currentEmail}) async {
    Map<String, dynamic>? map;
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) return;
      map = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
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
      final dateStr = map['dateStr'] as String?;
      final rawSamples = map['samples'];
      if (dateStr == null || rawSamples is! List) return;
      final samples = <HrSample>[];
      for (final item in rawSamples) {
        if (item is Map) {
          final t = item['t'];
          final bpm = item['bpm'];
          if (t is num && bpm is num) {
            samples.add(HrSample(timeMs: t.toInt(), bpm: bpm.toInt()));
          }
        }
      }
      // Zero rule applies to the disk path too: a blob written by any
      // older path can never resurrect a failed read.
      _byDate[dateStr] = validHrSamples(samples);
      _diskDateStr = dateStr;
      final fetchedAt = DateTime.tryParse(map['fetchedAt'] as String? ?? '');
      if (fetchedAt != null) _lastSyncAt = fetchedAt;
      final rawOwner = map['ownerEmail'];
      if (rawOwner is String) _ownerEmail = _normalizeEmail(rawOwner);
    } catch (_) {
      // Malformed blob: start empty.
    }
  }

  /// Wipes memory + disk (logout / account-deletion hook). Never throws.
  Future<void> clear() async {
    _resetMemory();
    try {
      await _delete(storageKey);
    } catch (_) {}
  }
}
