import 'dart:async';
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

  // ── In-memory mirror ─────────────────────────────────────────────
  // The screens' critical paths (chat send, proposal resolution,
  // history load) NEVER await this store's disk IO: they read
  // [cachedFacts] and record through [recordFact], while disk
  // reads/writes complete in the background. On device the warm
  // finishes in milliseconds (the history screen warms the mirror
  // before any chat opens); a wedged storage channel can therefore
  // never hang a send, an approval, or a logout. The awaited APIs
  // ([load], [addFact], [deleteAt]) remain for the memory screen
  // and for tests, where the injected IO completes normally.
  List<CoachMemoryFact> _mirror = const [];
  String? _mirrorOwner;
  bool _mirrorLoaded = false;
  Future<List<CoachMemoryFact>>? _loading;

  /// The facts currently mirrored in memory (empty until the first
  /// [load] lands). Synchronous and never throws.
  List<CoachMemoryFact> get cachedFacts =>
      _mirrorLoaded ? _mirror : const [];

  static List<CoachMemoryFact> _dedupeCap(List<CoachMemoryFact> facts) {
    final seen = <String>{};
    final out = <CoachMemoryFact>[];
    for (final f in facts) {
      if (seen.add(normalizeFactText(f.text))) out.add(f);
      if (out.length >= maxFacts) break;
    }
    return out;
  }

  /// Records one fact into the mirror IMMEDIATELY (dedupe + caps
  /// applied) and persists in the background, merging with the
  /// disk facts once the in-flight warm lands so a fact recorded
  /// during the first warm is never lost. Returns the mirror.
  List<CoachMemoryFact> recordFact({
    required String text,
    required String source,
    String? email,
    DateTime? now,
  }) {
    final cleaned = cleanFactText(text);
    if (cleaned.isEmpty) return cachedFacts;
    final fact = CoachMemoryFact(
      text: cleaned,
      createdAt: (now ?? DateTime.now()).millisecondsSinceEpoch,
      source: source,
    );
    final emailNorm = normalizeEmail(email);
    if (emailNorm != null &&
        _mirrorOwner != null &&
        _mirrorOwner != emailNorm) {
      _mirror = const [];
      _diskLoaded = false;
    }
    _mirror = _dedupeCap([fact, ..._mirror]);
    _mirrorLoaded = true;
    _mirrorOwner = normalizeEmail(email) ?? _mirrorOwner;
    final loading = _loading;
    if (loading != null) {
      unawaited(loading.then((_) => _persist(_mirror, email)));
    } else if (_diskLoaded) {
      unawaited(_persist(_mirror, email));
    } else {
      unawaited(load(email).then((_) => _persist(_mirror, email)));
    }
    return _mirror;
  }

  bool _diskLoaded = false;

  /// Reads the stored blob. When [email] is known and the blob is
  /// owned by a different account (or by no recorded account), the
  /// blob is wiped and an empty list is returned — one account's
  /// memory never surfaces for another. Never throws.
  Future<List<CoachMemoryFact>> load(String? email) {
    final expected = normalizeEmail(email);
    if (_mirrorLoaded && _diskLoaded && _mirrorOwner == expected) {
      return Future.value(_mirror);
    }
    final inFlight = _loading;
    if (inFlight != null) return inFlight;
    late final Future<List<CoachMemoryFact>> future;
    future = _loadFromDisk(email).whenComplete(() {
      if (identical(_loading, future)) _loading = null;
    });
    _loading = future;
    return future;
  }

  Future<List<CoachMemoryFact>> _loadFromDisk(String? email) async {
    final expected = normalizeEmail(email);
    try {
      final raw = await _read(storageKey);
      List<CoachMemoryFact> disk = const [];
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          if (expected != null) {
            final owner = normalizeEmail(decoded['ownerEmail']?.toString());
            if (owner != expected) {
              // Another account's blob: wipe it and start empty —
              // but facts recorded locally during this load (for
              // the CURRENT account) survive in the mirror.
              // Only facts recorded for THIS account during the
              // load may survive — a previous account's mirror is
              // dropped with its blob.
              final pending =
                  _mirrorOwner == expected ? _mirror : const <CoachMemoryFact>[];
              await clear();
              _mirror = _dedupeCap(pending);
              _mirrorLoaded = true;
              _mirrorOwner = expected;
              _diskLoaded = true;
              return _mirror;
            }
          }
          final factsRaw = decoded['facts'];
          if (factsRaw is List) {
            disk = [
              for (final f in factsRaw)
                if (CoachMemoryFact.fromJson(f) != null)
                  CoachMemoryFact.fromJson(f)!,
            ];
          }
        }
      }
      // Facts recorded while the disk read was in flight are the
      // newest and win the merge — unless the mirror still holds a
      // different account's facts, which never merge.
      final local = (_mirrorOwner == null ||
              expected == null ||
              _mirrorOwner == expected)
          ? _mirror
          : const <CoachMemoryFact>[];
      _mirror = _dedupeCap([...local, ...disk]);
      _mirrorLoaded = true;
      _mirrorOwner = expected;
      _diskLoaded = true;
      return _mirror;
    } catch (_) {
      _mirrorLoaded = true;
      _mirrorOwner = expected;
      _diskLoaded = true;
      return _mirror;
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
    _mirror = out;
    await _persist(out, email);
    return out;
  }

  /// Deletes the fact at [index] in the newest-first list for
  /// [email]. Returns the resulting list.
  Future<List<CoachMemoryFact>> deleteAt(int index, String? email) async {
    final existing = await load(email);
    if (index < 0 || index >= existing.length) return existing;
    final out = [...existing]..removeAt(index);
    _mirror = out;
    await _persist(out, email);
    return out;
  }

  /// Clears every fact (the user's Clear all control). Never throws.
  Future<void> clearAll(String? email) => clear();

  /// Wipes the whole blob. Called on logout / account deletion /
  /// session expiry exactly like the other account-bound caches.
  /// Never throws.
  Future<void> clear() async {
    _mirror = const [];
    _mirrorLoaded = false;
    _mirrorOwner = null;
    _diskLoaded = false;
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
