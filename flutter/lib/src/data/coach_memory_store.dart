import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Round 55 Step 2 — Coach memory, device-local v1.
///
/// There is no synced storage for coach memory: the sync profile is
/// a server column whitelist and unknown keys are dropped, so these
/// facts live ONLY on this device, in the app's existing local
/// persistence pattern (flutter_secure_storage — Android Keystore
/// backed EncryptedSharedPreferences, the same store SettingsStore
/// and the account-bound caches use). The blob is account-bound:
/// it carries its owner's session email, a load for a different
/// account wipes it instead of returning another account's facts,
/// and logout / account deletion / session expiry clear it through
/// the same hooks as the R29b/R35 caches (AccountActions and
/// main.dart's session-expiry path).
///
/// A fact is bounded: at most [maxFacts] facts, each at most
/// [maxFactChars] characters, deduplicated on normalized text with
/// the newest copy winning.
class CoachMemoryFact {
  final String text;
  final int createdAt; // epoch ms
  final String source;

  const CoachMemoryFact({
    required this.text,
    required this.createdAt,
    required this.source,
  });

  Map<String, dynamic> toJson() => {
        'text': text,
        'createdAt': createdAt,
        'source': source,
      };

  static CoachMemoryFact? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final text = '${raw['text'] ?? ''}'.trim();
    if (text.isEmpty) return null;
    final ts = raw['createdAt'];
    return CoachMemoryFact(
      text: text,
      createdAt: ts is num ? ts.toInt() : (ts is String ? int.tryParse(ts) ?? 0 : 0),
      source: '${raw['source'] ?? ''}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CoachMemoryFact &&
      other.text == text &&
      other.createdAt == createdAt &&
      other.source == source;

  @override
  int get hashCode => Object.hash(text, createdAt, source);
}

class CoachMemoryStore {
  static const String storageKey = 'coach_memory_v1';
  static const int maxFacts = 40;
  static const int maxFactChars = 200;

  static final CoachMemoryStore instance = CoachMemoryStore._internal();
  CoachMemoryStore._internal();

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  CoachMemoryStore._(this._read, this._write, this._delete);

  @visibleForTesting
  factory CoachMemoryStore.withStorage({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    required Future<void> Function(String key) delete,
  }) =>
      CoachMemoryStore._(read, write, delete);

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

  static String? normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  static String normalizeFactText(String text) =>
      text.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static String cleanFactText(String text) {
    var t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.length > maxFactChars) t = t.substring(0, maxFactChars).trim();
    return t;
  }

  /// Reads the stored blob. When [email] is known and the blob is
  /// owned by a different account (or by no recorded account), the
  /// blob is wiped and an empty list is returned — one account's
  /// memory never surfaces for another. Never throws.
  Future<List<CoachMemoryFact>> load(String? email) async {
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const [];
      final expected = normalizeEmail(email);
      if (expected != null) {
        final owner = normalizeEmail(decoded['ownerEmail']?.toString());
        if (owner != expected) {
          await clear();
          return const [];
        }
      }
      final factsRaw = decoded['facts'];
      if (factsRaw is! List) return const [];
      final out = <CoachMemoryFact>[];
      for (final f in factsRaw) {
        final fact = CoachMemoryFact.fromJson(f);
        if (fact != null) out.add(fact);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  Future<void> _persist(List<CoachMemoryFact> facts, String? email) async {
    try {
      await _write(
        storageKey,
        jsonEncode({
          'ownerEmail': normalizeEmail(email),
          'facts': [for (final f in facts) f.toJson()],
        }),
      );
    } catch (_) {}
  }

  /// Adds one fact (newest first). Dedupes on normalized text —
  /// the newest copy wins — and enforces the caps. Returns the
  /// resulting list. An empty cleaned text is a no-op.
  Future<List<CoachMemoryFact>> addFact({
    required String text,
    required String source,
    String? email,
    DateTime? now,
  }) async {
    final cleaned = cleanFactText(text);
    if (cleaned.isEmpty) return load(email);
    final existing = await load(email);
    final key = normalizeFactText(cleaned);
    final kept = [
      for (final f in existing)
        if (normalizeFactText(f.text) != key) f,
    ];
    final fact = CoachMemoryFact(
      text: cleaned,
      createdAt: (now ?? DateTime.now()).millisecondsSinceEpoch,
      source: source,
    );
    final out = [fact, ...kept].take(maxFacts).toList();
    await _persist(out, email);
    return out;
  }

  /// Deletes the fact at [index] in the newest-first list for
  /// [email]. Returns the resulting list.
  Future<List<CoachMemoryFact>> deleteAt(int index, String? email) async {
    final existing = await load(email);
    if (index < 0 || index >= existing.length) return existing;
    final out = [...existing]..removeAt(index);
    await _persist(out, email);
    return out;
  }

  /// Clears every fact (the user's Clear all control). Never throws.
  Future<void> clearAll(String? email) => clear();

  /// Wipes the whole blob. Called on logout / account deletion /
  /// session expiry exactly like the other account-bound caches.
  /// Never throws.
  Future<void> clear() async {
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  /// Login/register ownership enforcement, mirroring the other
  /// caches: a blob owned by a different account is dropped.
  /// Returns true when a wipe happened. Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = normalizeEmail(email);
    if (expected == null) return false;
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) return false;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await clear();
        return true;
      }
      final owner = normalizeEmail(decoded['ownerEmail']?.toString());
      if (owner == expected) return false;
      await clear();
      return true;
    } catch (_) {
      return false;
    }
  }
}
