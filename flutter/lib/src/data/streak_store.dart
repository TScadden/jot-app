import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:tabs_lab/src/data/streak_engine.dart';

/// Lab (streak screen package, Nov 4, 2026) — persistence + the
/// app-open evaluation entry point for the streak engine.
///
/// Storage follows the HomeDataCache pattern: one JSON blob in
/// flutter_secure_storage (Android Keystore-backed
/// EncryptedSharedPreferences, the same encrypted-at-rest store as
/// the auth session and the home cache), injectable read/write for
/// tests, and account-owner binding. The blob records its owner's
/// session email; [clearIfOwnerMismatch] — registered beside
/// HomeDataCache's hooks in main.dart (login funnel AND the
/// cold-start restore claim) — stamps the claim synchronously,
/// wipes any in-memory state owned by a different account before
/// its first await, and drops the disk blob when its owner differs.
/// A blob with no owner is dropped as soon as a current account is
/// known.
///
/// The data is the user's own on-device streak record; it adds no
/// transmission path (nothing here is sent anywhere).
class StreakStore {
  static const String storageKey = 'streak_lab_v1';

  static final StreakStore instance = StreakStore._internal();
  StreakStore._internal();

  // HomeDataCache-style injectable storage: unit tests pass in-memory
  // fakes so no test touches platform channels.
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
  void debugReset() {
    _state = null;
    _ownerEmail = null;
    _claimedOwner = null;
    _loaded = false;
    _dirty = false;
  }

  StreakState? _state;
  String? _ownerEmail;

  /// The account claimed by the latest owner hook, stamped
  /// synchronously so a load that lands afterwards can enforce it.
  String? _claimedOwner;
  bool _loaded = false;
  bool _dirty = false;

  /// The in-memory state, once loaded. Null until [ensureLoaded].
  StreakState? get state => _state;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      final owner = decoded['ownerEmail'];
      _ownerEmail = owner is String ? owner : null;
      // Owner enforcement for a claim stamped before this load:
      // a blob owned by anyone else (or no one) never surfaces.
      if (_claimedOwner != null && _ownerEmail != _claimedOwner) {
        _state = null;
        _ownerEmail = _claimedOwner;
        unawaited(_deleteQuietly());
        return;
      }
      final blob = decoded['state'];
      if (blob is Map<String, dynamic>) {
        _state = StreakState.fromJson(blob);
      }
    } catch (_) {
      // A corrupt or unreadable blob must never wedge the streak:
      // start unseeded and let the next pull re-seed.
      _state = null;
      _ownerEmail = null;
    }
  }

  Future<void> _deleteQuietly() async {
    try {
      await _delete(storageKey);
    } catch (_) {
      // Best-effort: the next persist overwrites with the new
      // owner's state.
    }
  }

  /// Account binding (parity with HomeDataCache): called from the
  /// login funnel and the cold-start restore claim with the current
  /// session email. The claim + any in-memory wipe happen
  /// synchronously, before the first await. A null/empty [email]
  /// (no session) never drops anything.
  Future<void> clearIfOwnerMismatch(String? email) async {
    if (email == null || email.isEmpty) return;
    _claimedOwner = email;
    if (_ownerEmail != null && _ownerEmail != email) {
      _state = null;
      _dirty = false;
      unawaited(_deleteQuietly());
    }
    _ownerEmail = email;
    await ensureLoaded();
    // ensureLoaded enforces the claim against a not-yet-loaded
    // blob; an already-loaded blob whose state survived belongs to
    // this owner by the check above.
  }

  /// One app-open evaluation: seed/re-seed from the profile pull
  /// per the pair rule in the body, then apply the engine at [now].
  /// [seedCurrent]/[seedBest] are the pull's counters (either may be
  /// null — a failed pull seeds nothing and never erases local
  /// state). Returns the state to display. Storage failures degrade
  /// to in-memory only; this method never throws into the UI path.
  /// Callers in UI load paths must NOT await this (real platform
  /// I/O) — fire it and let it settle, the HomeDataCache idiom.
  Future<StreakState> recordOpen({
    required int? seedCurrent,
    required int? seedBest,
    required DateTime now,
  }) async {
    await ensureLoaded();
    var s = _state ?? StreakState.empty;
    if (seedCurrent != null && seedBest != null) {
      // Re-seed rule: a pull whose counters DIFFER from the pair
      // this state was seeded with is new server truth — adopt it
      // wholesale. The SAME pair never re-seeds (the pull is a
      // frozen native-era record; local opens must keep growing
      // the run past it). Protected Lab history (a restored day or
      // a consumed save exists only locally) is never overwritten:
      // the pull's best is taken as a floor and the pair is marked
      // seen.
      final pairChanged = !s.seeded ||
          s.seededCurrent != seedCurrent ||
          s.seededBest != seedBest;
      if (pairChanged && s.hasProtectedHistory) {
        s = s.copyWith(
          seeded: true,
          seededCurrent: seedCurrent,
          seededBest: seedBest > s.seededBest ? seedBest : s.seededBest,
        );
      } else if (pairChanged) {
        s = streakSeed(current: seedCurrent, best: seedBest, now: now);
      }
    }
    final next = streakEvaluate(s, now);
    _state = next;
    if (next != s) _dirty = true;
    if (_dirty) {
      _dirty = false;
      unawaited(_persist());
    }
    return next;
  }

  Future<void> _persist() async {
    final s = _state;
    if (s == null) return;
    try {
      await _write(
        storageKey,
        jsonEncode({'ownerEmail': _ownerEmail, 'state': s.toJson()}),
      );
    } catch (_) {
      // In-memory state survives; the next evaluation retries.
      _dirty = true;
    }
  }

  /// Persist now (tests + lifecycle hooks).
  Future<void> persist() async {
    _dirty = false;
    await _persist();
  }
}
