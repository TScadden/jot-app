import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:tabs_lab/src/data/streak_engine.dart';

/// Persistence + the app-open evaluation entry point for the
/// streak engine (Lab streak package Nov 4, 2026; release-line
/// authoritative pipeline, VC 100115).
///
/// THE AUTHORITATIVE RECORD lives on the server profile:
/// `current_streak` / `best_streak` counters plus the `streak_state`
/// day-level blob, all read via /api/sync/pull and written via
/// POST /api/sync/profile. This store is the on-device working copy
/// of that record (the HomeDataCache pattern: one JSON blob in
/// flutter_secure_storage, injectable read/write for tests,
/// account-owner binding via [clearIfOwnerMismatch], registered
/// beside HomeDataCache's hooks in main.dart).
///
/// How a "streak of 1 on a 14-day account" is made IMPOSSIBLE here
/// (the Lab bug, founder report Nov 5, 2026): the engine evaluates
/// ONLY from (a) the adopted server record, (b) an existing local
/// record, or (c) a pull that CONFIRMED the server holds no record
/// (a genuinely new account, where a first open of 1 is correct).
/// No local record + no successful pull = NO evaluation and no
/// display value — Home keeps its honest "--" state. The Lab build
/// evaluated from empty whenever its seed had not landed, minting
/// a fresh 1-day run; that path does not exist in this store.
///
/// Sync discipline: every settle that changes the record pushes
/// the settled counters + blob back to the profile (the caller's
/// [StreakSyncPush]); a later pull adopts the server blob unless
/// the local record is strictly newer (a settle whose push never
/// landed), so devices converge on the same record.
/// Writes one settled streak record back to the server profile
/// (counters + day-level blob). Returns true when the server
/// accepted it; failures are the caller's silence — the local
/// record is strictly newer than the server's and re-pushes on
/// the next settle.
typedef StreakSyncPush = Future<bool> Function(
  int current,
  int best,
  String stateJson,
);

class StreakStore {
  static const String storageKey = 'streak_v1';

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
    final String? raw;
    try {
      raw = await _read(storageKey);
    } catch (_) {
      // C-04 — a storage READ failure is neither an empty disk nor
      // a corrupt blob (the conflation PR #44 fixed in
      // HealthHistoryStore): the on-disk blob may be perfectly
      // valid. Leave [_loaded] false so the next call retries the
      // read, leave [_state] untouched, and do NOT null
      // [_ownerEmail] — a claim/bind stamped by
      // [clearIfOwnerMismatch] just before this load must survive
      // it. Until a load succeeds, [_persist] stays gated off and
      // [recordOpen] refuses to adopt, so the degraded server-side
      // record can never overwrite the true local one (nor be
      // persisted stamped ownerEmail: null, which the next cold
      // start would delete as foreign).
      return;
    }
    _loaded = true;
    if (raw == null || raw.isEmpty) return;
    try {
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
      // A corrupt blob must never wedge the streak: start unseeded
      // and let the next pull re-seed. The read itself succeeded,
      // so the load stands — and [_ownerEmail] is left as decoded
      // (or as claimed), never nulled by the parse failure.
      _state = null;
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

  /// One app-open evaluation against the authoritative record.
  ///
  /// [pullSucceeded] distinguishes "the server answered" from "the
  /// pull failed" — the distinction the anti-fabrication rule turns
  /// on. [seedCurrent]/[seedBest] are the pull's counters and
  /// [seedStateJson] its day-level blob (either may be null: a
  /// pre-VC100115 profile carries counters only; a new account
  /// carries neither). [push] writes a settled record back to the
  /// profile; it fires only when the settled record differs from
  /// what the server already holds.
  ///
  /// Returns the state to display. An UNSEEDED empty state means
  /// "no record anywhere and no confirmation" — callers must not
  /// display numbers from it. Storage failures degrade to
  /// in-memory only; this method never throws into the UI path.
  /// Callers in UI load paths must NOT await this (real platform
  /// I/O) — fire it and let it settle, the HomeDataCache idiom;
  /// the streak screen's open path awaits the stored future.
  Future<StreakState> recordOpen({
    required bool pullSucceeded,
    required int? seedCurrent,
    required int? seedBest,
    required String? seedStateJson,
    required DateTime now,
    StreakSyncPush? push,
  }) async {
    await ensureLoaded();
    if (!_loaded) {
      // C-04 — the disk read failed, so there is no trustworthy
      // local record to evaluate from: refuse exactly like the
      // pullSucceeded: false path below (no adoption from the
      // server side, no persist, no push, no fabricated state).
      // The caller keeps its honest empty display and the next
      // open retries the read.
      return StreakState.empty;
    }
    var s = _state;

    if (pullSucceeded) {
      // 1) The server blob is the authoritative day-level record:
      //    adopt it unless the local record is strictly newer (its
      //    settle push never landed — keep it and re-push below).
      StreakState? server;
      if (seedStateJson != null && seedStateJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(seedStateJson);
          if (decoded is Map<String, dynamic>) {
            server = StreakState.fromJson(decoded);
          }
        } catch (_) {
          server = null; // A corrupt blob falls back to the counters.
        }
      }
      if (server != null) {
        final serverDay = server.lastEvaluatedDay ?? '';
        final localDay = s?.lastEvaluatedDay ?? '';
        if (s == null || serverDay.compareTo(localDay) >= 0) {
          s = server;
        }
      } else if (seedCurrent != null && seedBest != null) {
        // 2) Counters-only record (every pre-VC100115 profile,
        //    including the founder's frozen 14/68): adopt the pair
        //    per the Lab pair rule — a differing pair re-seeds
        //    wholesale unless protected restore history exists
        //    (then the pull's best floors in); the same pair never
        //    re-seeds, so local opens grow past the adopted base.
        final base = s ?? StreakState.empty;
        final pairChanged = !base.seeded ||
            base.seededCurrent != seedCurrent ||
            base.seededBest != seedBest;
        if (pairChanged && base.hasProtectedHistory) {
          s = base.copyWith(
            seeded: true,
            seededCurrent: seedCurrent,
            seededBest: seedBest > base.seededBest ? seedBest : base.seededBest,
          );
        } else if (pairChanged) {
          s = streakSeed(current: seedCurrent, best: seedBest, now: now);
        } else {
          s = base;
        }
      } else {
        // 3) The server CONFIRMED it holds no streak record: a
        //    genuinely new account. Seeding an empty record is
        //    correct here — the evaluation below makes the first
        //    open count 1, as the legacy rule defines.
        s ??= streakSeed(current: 0, best: 0, now: now);
      }
      // Any state that survived a successful pull is seeded: its
      // numbers may be displayed. (Every adoption branch above
      // leaves s non-null: the blob branch assigns or keeps a
      // non-null local, the counters branch assigns base, and the
      // confirmed-empty branch ??= seeds.)
      final adopted = s;
      if (!adopted.seeded) {
        s = adopted.copyWith(seeded: true);
      }
    }

    final effective = s;
    if (effective == null) {
      // No local record and no successful pull: NEVER fabricate a
      // run. The caller keeps its honest empty display.
      return StreakState.empty;
    }

    final next = streakEvaluate(effective, now);
    _state = next;
    if (next != effective) _dirty = true;
    if (_dirty) {
      _dirty = false;
      unawaited(_persist());
    }

    // Push-back: the settled record returns to the server profile
    // whenever it differs from what the server already holds, so
    // the next device (or reinstall) adopts THIS record.
    if (pullSucceeded && push != null) {
      final settledJson = jsonEncode(next.toJson());
      final current = streakCurrent(next, now);
      final best = streakBest(next);
      if (settledJson != seedStateJson ||
          current != seedCurrent ||
          best != seedBest) {
        unawaited(
          push(current, best, settledJson).catchError((_) => false),
        );
      }
    }
    return next;
  }

  Future<void> _persist() async {
    // C-04 — gated on a successful load, mirroring
    // HealthHistoryStore's `if (!_warmed) return;`: after a failed
    // read the in-memory image is not the disk record, and writing
    // it would overwrite the true blob (stamped ownerEmail: null).
    if (!_loaded) return;
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
