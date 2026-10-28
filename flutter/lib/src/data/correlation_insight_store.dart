import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'correlation_engine.dart';

/// Phase 1, item 5 — the on-device insight-record cache (spec §6).
///
/// Engine records are computed statistics held on-device; they
/// are never filed in the server's AI-insights table (the
/// computed-vs-generated line §5's honesty rules depend on).
/// Storage follows the house pattern for derived local data
/// (HealthHistoryStore): one versioned JSON blob in
/// FlutterSecureStorage beside the history store, an in-memory
/// map warmed lazily, `debugSetStore`/`debugReset` test hooks,
/// and account binding by normalized owner email — a blob owned
/// by a different account is dropped, never served.
///
/// Records are keyed familyId+splitId (see
/// [correlationRecordKey]). A record is stale when a fresh
/// fingerprint (computeCorrelationFingerprints) differs from its
/// stored one; the store itself never computes anything.
class CorrelationInsightStore {
  static const String storageKey = 'correlation_insights_v1';
  static const int blobVersion = 1;

  static final CorrelationInsightStore instance =
      CorrelationInsightStore._internal();
  CorrelationInsightStore._internal();

  /// A fresh, non-singleton instance for tests, so seeded records
  /// never leak across cases through the singleton's memory.
  factory CorrelationInsightStore.testInstance() =>
      CorrelationInsightStore._internal();

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
    _records.clear();
    _ownerEmail = null;
    _warmed = false;
  }

  final Map<String, InsightRecord> _records = {};
  bool _warmed = false;

  // ── Account binding (sibling-cache contract) ───────────────────

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

  /// Ownership enforcement — same contract as HealthHistoryStore:
  /// a store owned by a different account (or carrying data with
  /// no recorded owner) is wiped as soon as a differing current
  /// account is known; a matching owner keeps everything; no
  /// known account → no drop. Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = _normalizeEmail(email);
    if (expected == null) return false;
    await _ensureWarmed();
    final hasData = _records.isNotEmpty;
    if (_ownerEmail == expected) return false;
    if (_ownerEmail == null && !hasData) {
      _ownerEmail = expected;
      return false;
    }
    await clear();
    _ownerEmail = expected;
    return true;
  }

  /// Wipes memory + disk (logout / account-deletion hook). Never
  /// throws.
  Future<void> clear() async {
    _resetMemory();
    _warmed = true; // memory is authoritative-empty until next write
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  // ── Warm / persist ─────────────────────────────────────────────

  /// Cold-start warm from the disk blob. Never throws — a missing
  /// or corrupt blob starts empty. When [currentEmail] is known,
  /// a blob owned by a different account (or by no recorded
  /// account while carrying data) is dropped exactly as the
  /// sibling caches do it; when there is no usable blob to adopt,
  /// the store binds to [currentEmail].
  Future<void> warmFromDisk({String? currentEmail}) async {
    final expected = _normalizeEmail(currentEmail);
    if (_warmed) {
      if (currentEmail != null) await clearIfOwnerMismatch(currentEmail);
      return;
    }
    Map<String, dynamic>? map;
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) {
        if (expected != null) _ownerEmail = expected;
        _warmed = true;
        return;
      }
      map = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      if (expected != null) _ownerEmail = expected;
      _warmed = true;
      return;
    }
    if (expected != null) {
      final blobOwner = _normalizeEmail(map['ownerEmail']?.toString());
      final recordsRaw = map['records'];
      final hasData = recordsRaw is List && recordsRaw.isNotEmpty;
      if (blobOwner != expected && (blobOwner != null || hasData)) {
        _resetMemory();
        _warmed = true;
        _ownerEmail = expected;
        try {
          await _delete(storageKey);
        } catch (_) {}
        return;
      }
      if (blobOwner == null && !hasData) _ownerEmail = expected;
    }
    try {
      final recordsRaw = map['records'];
      if (recordsRaw is List) {
        for (final raw in recordsRaw) {
          final record = InsightRecord.fromJson(raw);
          if (record != null && record.familyId.isNotEmpty) {
            _records[record.storeKey] = record;
          }
        }
      }
      final rawOwner = map['ownerEmail'];
      if (rawOwner is String) _ownerEmail = _normalizeEmail(rawOwner);
    } catch (_) {
      _records.clear();
    }
    if (expected != null) _ownerEmail = expected;
    _warmed = true;
  }

  Future<void> _ensureWarmed() async {
    if (!_warmed) await warmFromDisk();
  }

  /// Persists the current memory state. Never throws.
  Future<void> persist() async {
    try {
      final keys = _records.keys.toList()..sort();
      await _write(
        storageKey,
        jsonEncode({
          'version': blobVersion,
          'ownerEmail': _ownerEmail,
          'records': [for (final k in keys) _records[k]!.toJson()],
        }),
      );
    } catch (_) {
      // Memory stays; disk just won't have this refresh.
    }
  }

  // ── Read / write API ───────────────────────────────────────────

  /// All stored records, keyed familyId+splitId.
  Future<Map<String, InsightRecord>> readAll() async {
    await _ensureWarmed();
    final keys = _records.keys.toList()..sort();
    return {for (final k in keys) k: _records[k]!};
  }

  /// Replaces the whole stored set with [records] (keyed
  /// familyId+splitId) and persists. Never throws.
  Future<void> writeAll(Map<String, InsightRecord> records) async {
    await _ensureWarmed();
    _records
      ..clear()
      ..addAll(records);
    await persist();
  }

  /// Merges [records] into the stored set (per-key replace) and
  /// persists — the refresh path's write, so splits that were not
  /// recomputed keep their stored records untouched. Never throws.
  Future<void> writeRecords(List<InsightRecord> records) async {
    if (records.isEmpty) return;
    await _ensureWarmed();
    for (final record in records) {
      _records[record.storeKey] = record;
    }
    await persist();
  }
}
