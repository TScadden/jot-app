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
    // Round 55 fix pass (Vera LOW): stored facts are cleaned on
    // the way in too — whitespace collapsed and the char cap
    // applied — so a hand-edited or legacy blob cannot smuggle
    // an oversized or control-laden fact into the context.
    final text = CoachMemoryStore.cleanFactText('${raw['text'] ?? ''}');
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
  String? _loadingEmail;

  // Round 55 fix pass (Vera): ownership epoch. clear() bumps it;
  // an in-flight disk load that observes a different epoch after
  // an await discards its result instead of resurrecting a prior
  // account's facts into the mirror.
  int _epoch = 0;

  /// Mirror-only invalidation for an EXTERNAL write to the disk
  /// blob (TAKEOVER Phase 4 fix — Vera BLOCK): the migration import
  /// writes the imported blob straight to secure storage, so a
  /// mirror warmed earlier in the session (Coach / History visited
  /// before the import) would otherwise keep serving the pre-import
  /// facts — and the next [recordFact] / [addFact] persist, which
  /// merges from the mirror, would silently overwrite the imported
  /// blob with the stale mirror. This resets ONLY the in-memory
  /// state: the disk key is neither deleted nor altered, the epoch
  /// bump makes any in-flight load or deferred persist captured
  /// before the external write discard itself instead of landing
  /// on top of it, and the next [load] re-reads the (imported)
  /// blob from disk. Never throws, never touches storage.
  void invalidateMirror() {
    _epoch++;
    _loading = null;
    _loadingEmail = null;
    _mirror = const [];
    _mirrorLoaded = false;
    _mirrorOwner = null;
    _diskLoaded = false;
  }

  /// The facts currently mirrored in memory (empty until the first
  /// [load] lands). Synchronous and never throws.
  List<CoachMemoryFact> get cachedFacts =>
      _mirrorLoaded ? _mirror : const [];

  /// The mirrored facts ONLY when the mirror is verified to
  /// belong to [email] (normalized). Any other owner — or an
  /// unverified owner — yields an empty list, so callers building
  /// per-account output never read another account's facts from
  /// an unguarded mirror.
  List<CoachMemoryFact> cachedFactsFor(String? email) {
    final expected = normalizeEmail(email);
    if (!_mirrorLoaded) return const [];
    if (_mirrorOwner != expected) return const [];
    return _mirror;
  }

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
    // Round 55 fix pass (Vera): persist a SNAPSHOT captured at
    // record time (merged with this caller's own load result),
    // never the live mirror at persist time — after an account
    // switch the live mirror holds another account's facts, and
    // writing those under this caller's owner would leak them
    // across accounts. A clear/switch since record time (epoch
    // change) skips the deferred persist entirely.
    final snapshot = List<CoachMemoryFact>.of(_mirror);
    final epochAtRecord = _epoch;
    final loading = _loading;
    if (loading != null) {
      unawaited(loading.then((loaded) {
        if (_epoch != epochAtRecord) return;
        unawaited(_persist(_dedupeCap([...snapshot, ...loaded]), email,
            epoch: epochAtRecord));
      }));
    } else if (_diskLoaded) {
      unawaited(_persist(snapshot, email, epoch: epochAtRecord));
    } else {
      unawaited(load(email).then((loaded) {
        if (_epoch != epochAtRecord) return;
        unawaited(_persist(_dedupeCap([...snapshot, ...loaded]), email,
            epoch: epochAtRecord));
      }));
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
    // Round 55 fix pass (Vera): the in-flight future is keyed by
    // normalized email — it is only ever shared with a caller for
    // the SAME account. A load for a different account supersedes
    // it (epoch bump, so the stale load discards its result).
    final inFlight = _loading;
    if (inFlight != null) {
      if (_loadingEmail == expected) return inFlight;
      _epoch++;
    }
    late final Future<List<CoachMemoryFact>> future;
    future = _loadFromDisk(email).whenComplete(() {
      if (identical(_loading, future)) {
        _loading = null;
        _loadingEmail = null;
      }
    });
    _loading = future;
    _loadingEmail = expected;
    return future;
  }

  Future<List<CoachMemoryFact>> _loadFromDisk(String? email) async {
    final expected = normalizeEmail(email);
    final epochAtStart = _epoch;
    final mirrorAtStart = _mirror;
    final ownerAtStart = _mirrorOwner;
    // A result captured before a clear/switch is stale: return
    // only what was already this caller's at capture time and
    // mutate nothing.
    List<CoachMemoryFact> discard() =>
        ownerAtStart == expected ? mirrorAtStart : const [];
    try {
      final raw = await _read(storageKey);
      if (epochAtStart != _epoch) return discard();
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
      if (epochAtStart != _epoch) return discard();
      // Round 55 fix pass (Vera): on a read failure the mirror is
      // only trustworthy when it already belongs to this caller
      // (or to no one). Another account's mirror is never
      // returned: the result is empty and ownership moves to the
      // expected account.
      if (_mirrorOwner == expected || _mirrorOwner == null) {
        _mirrorLoaded = true;
        _mirrorOwner = expected;
        _diskLoaded = true;
        return _mirror;
      }
      _mirror = const [];
      _mirrorLoaded = true;
      _mirrorOwner = expected;
      _diskLoaded = true;
      return const [];
    }
  }

  /// Writes [facts] as the disk blob. When [epoch] is given, the
  /// write is SKIPPED (returns false) if the epoch has moved since
  /// the caller captured it — a [clear] or an [invalidateMirror]
  /// (external write, e.g. a migration import) in between means the
  /// facts were merged from a mirror that is no longer known to
  /// match disk, and landing them would overwrite newer disk data
  /// with the stale merge. The check and the write call happen in
  /// the same synchronous turn, so no invalidation can slip between
  /// them. Returns true when the write was issued.
  Future<bool> _persist(List<CoachMemoryFact> facts, String? email,
      {int? epoch}) async {
    if (epoch != null && epoch != _epoch) return false;
    try {
      await _write(
        storageKey,
        jsonEncode({
          'ownerEmail': normalizeEmail(email),
          'facts': [for (final f in facts) f.toJson()],
        }),
      );
    } catch (_) {}
    return true;
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
    final fact = CoachMemoryFact(
      text: cleaned,
      createdAt: (now ?? DateTime.now()).millisecondsSinceEpoch,
      source: source,
    );
    final key = normalizeFactText(cleaned);
    // Epoch-guarded persist: if an external write (migration
    // import) or a clear lands between the load and the persist,
    // the merge base is stale — reload from disk and re-apply on
    // top of the fresh facts instead of overwriting them. The
    // loop is bounded in practice: the epoch only moves on those
    // rare events, never in a hot path.
    while (true) {
      final existing = await load(email);
      final epochAfterLoad = _epoch;
      // Revalidate the merge base: an invalidation that landed
      // while the load was completing replaced the mirror, so the
      // loaded list is no longer the mirror it claims to be —
      // reload and merge against the fresh base instead.
      if (!identical(existing, _mirror)) continue;
      final kept = [
        for (final f in existing)
          if (normalizeFactText(f.text) != key) f,
      ];
      final out = [fact, ...kept].take(maxFacts).toList();
      _mirror = out;
      if (await _persist(out, email, epoch: epochAfterLoad)) return out;
    }
  }

  /// Deletes the fact at [index] in the newest-first list for
  /// [email]. Returns the resulting list.
  Future<List<CoachMemoryFact>> deleteAt(int index, String? email) async {
    // Same epoch guard as [addFact]: a stale merge base reloads
    // and re-applies rather than overwriting newer disk data.
    while (true) {
      final existing = await load(email);
      final epochAfterLoad = _epoch;
      // Same merge-base revalidation as [addFact].
      if (!identical(existing, _mirror)) continue;
      if (index < 0 || index >= existing.length) return existing;
      final out = [...existing]..removeAt(index);
      _mirror = out;
      if (await _persist(out, email, epoch: epochAfterLoad)) return out;
    }
  }

  /// Clears every fact (the user's Clear all control). Never throws.
  Future<void> clearAll(String? email) => clear();

  /// Wipes the whole blob. Called on logout / account deletion /
  /// session expiry exactly like the other account-bound caches.
  /// Never throws.
  Future<void> clear() async {
    _epoch++;
    _loading = null;
    _loadingEmail = null;
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
    // Round 55 fix pass (Vera): a non-null mirror owner that
    // mismatches wipes regardless of what disk holds — the mirror
    // is what the UI reads, so a stale mirror alone is a leak.
    if (_mirrorOwner != null && _mirrorOwner != expected) {
      await clear();
      return true;
    }
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
