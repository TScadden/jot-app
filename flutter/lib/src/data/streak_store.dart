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
///
/// [purchasedFreezes] is non-null ONLY when the settle being pushed
/// consumed a purchased freeze: the same profile push then carries
/// the decreased count as `purchased_freezes` (design A2; the
/// server applies a decrease only when the pushed blob justifies
/// it, and ignores any increase on this route — the column rises
/// only via the purchase-verify endpoint).
typedef StreakSyncPush = Future<bool> Function(
  int current,
  int best,
  String stateJson, {
  int? purchasedFreezes,
});

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

  /// Which seeding anchor an adoption uses (A6): the app-open
  /// path anchors the assumed run on the prior Tabs day; the
  /// completion path anchors it on the summary's own Tabs day.
  /// No code path adds a counted day for a day with no completed
  /// summary.
  static const int _seedAdoption = 0;
  static const int _seedCompletion = 1;

  /// The adoption half shared by [recordOpen] and
  /// [recordSummaryComplete] (the brief: the completion entry
  /// point reuses recordOpen's adoption / anti-fabrication /
  /// push-back machinery; only the evaluation differs, plus the
  /// A6 seeding anchor and the A2 purchased-freeze merge).
  ///
  /// Returns the state to evaluate from, or null when there is no
  /// local record and the pull did not succeed — the caller must
  /// fabricate NOTHING in that case.
  StreakState? _adopt({
    required bool pullSucceeded,
    required int? seedCurrent,
    required int? seedBest,
    required String? seedStateJson,
    required int? seedPurchasedFreezes,
    required DateTime now,
    required int seedMode,
    String? summaryTabsDay,
  }) {
    var s = _state;
    if (!pullSucceeded) return s;

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
      if (s == null) {
        s = server;
      } else if (serverDay.compareTo(localDay) >= 0) {
        // P0 fix (Defect B) — adoption MONOTONICITY: an equal- or
        // newer-stamp server blob no longer REPLACES the local
        // record wholesale. The completion push is fire-and-forget,
        // so a stale server blob (equal stamp) used to regress the
        // store after a completion — the celebration read one
        // adopted snapshot (28) and the streak screen another (27).
        // The day-level sets UNION-merge instead: no counted,
        // restored, or summary-completed day held locally is ever
        // lost to an equal-or-older-stamp adoption, and consumed /
        // spoiled months (freeze accounting) never un-consume.
        // Scalar fields (seeded counters, freeze inventory,
        // accrual) still come from the winning server record; the
        // A2 purchased-freeze formula below then applies on top.
        s = server.copyWith(
          countedDays: {...server.countedDays, ...s.countedDays},
          restoredDays: {...server.restoredDays, ...s.restoredDays},
          consumedSaveMonths: {
            ...server.consumedSaveMonths,
            ...s.consumedSaveMonths,
          },
          spoiledMonths: {...server.spoiledMonths, ...s.spoiledMonths},
          summaryCompletedDays: {
            ...server.summaryCompletedDays,
            ...s.summaryCompletedDays,
          },
        );
      }
      // A2 FIELD-LEVEL MERGE for the purchased freeze: the concrete
      // stamp-comparison formula governs (it takes precedence over
      // any max() read): purchasedFreezes_effective = serverColumn
      // when the server record's stamp is at least the local one,
      // else the local blob's value. A local settle that consumed
      // one pushes BOTH the blob and the decreased count in the
      // same profile write, so the two never diverge beyond one
      // in-flight push; a failed push leaves the column higher
      // (freeze appears unconsumed — fail-safe toward the user) and
      // the next settle re-pushes the justified decrease. No path
      // resurrects a consumed purchased freeze: the column rises
      // only via the purchase-verify endpoint (A9).
      if (seedPurchasedFreezes != null) {
        // s is promoted non-null here: the blob branch above
        // assigns the server state whenever the local one is absent.
        final adoptedState = s;
        final effectivePurchased = serverDay.compareTo(localDay) >= 0
            ? seedPurchasedFreezes
            : adoptedState.purchasedFreezes;
        if (adoptedState.purchasedFreezes != effectivePurchased) {
          s = adoptedState.copyWith(
            purchasedFreezes: effectivePurchased.clamp(0, 1),
          );
        }
      }
    } else if (seedCurrent != null && seedBest != null) {
      // 2) Counters-only record (every pre-VC100115 profile,
      //    including the founder's frozen 14/68): adopt the pair
      //    per the Lab pair rule — a differing pair re-seeds
      //    wholesale unless protected restore history exists
      //    (then the pull's best floors in); the same pair never
      //    re-seeds, so local opens grow past the adopted base.
      final base = s ?? StreakState.empty;
      final pairChanged =
          !base.seeded ||
          base.seededCurrent != seedCurrent ||
          base.seededBest != seedBest;
      if (pairChanged && base.hasProtectedHistory) {
        s = base.copyWith(
          seeded: true,
          seededCurrent: seedCurrent,
          seededBest: seedBest > base.seededBest ? seedBest : base.seededBest,
        );
      } else if (pairChanged) {
        s = seedMode == _seedCompletion
            ? streakSeedForCompletion(
                current: seedCurrent,
                best: seedBest,
                summaryTabsDay: summaryTabsDay!,
                purchasedFreezes: seedPurchasedFreezes ?? 0,
              )
            : streakSeedForAdoption(
                current: seedCurrent,
                best: seedBest,
                now: now,
                purchasedFreezes: seedPurchasedFreezes ?? 0,
              );
      } else {
        s = base;
      }
    } else {
      // 3) The server CONFIRMED it holds no streak record: a
      //    genuinely new account. Seeding an empty record is
      //    correct here — under v2 it counts NOTHING until the
      //    first Daily Summary completes (D1).
      s ??= seedMode == _seedCompletion
          ? streakSeedForCompletion(
              current: 0,
              best: 0,
              summaryTabsDay: summaryTabsDay!,
              purchasedFreezes: seedPurchasedFreezes ?? 0,
            )
          : streakSeedForAdoption(
              current: 0,
              best: 0,
              now: now,
              purchasedFreezes: seedPurchasedFreezes ?? 0,
            );
    }
    // Any state that survived a successful pull is seeded: its
    // numbers may be displayed. (Every branch above leaves s
    // non-null on the pullSucceeded path.)
    final adopted = s;
    if (!adopted.seeded) {
      s = adopted.copyWith(seeded: true);
    }
    return s;
  }

  /// Shared tail of both entry points: install the settled state,
  /// persist it when it changed, and push it back to the profile
  /// when it differs from what the server already holds. When the
  /// evaluation consumed a purchased freeze relative to the
  /// adopted state, the SAME push carries the decreased count
  /// (A2) — the only circumstance in which `purchased_freezes`
  /// is sent on this route.
  void _installAndPush({
    required StreakState effective,
    required StreakState next,
    required bool pullSucceeded,
    required int? seedCurrent,
    required int? seedBest,
    required String? seedStateJson,
    required DateTime now,
    required StreakSyncPush? push,
  }) {
    _state = next;
    if (next != effective) _dirty = true;
    if (_dirty) {
      _dirty = false;
      unawaited(_persist());
    }
    if (pullSucceeded && push != null) {
      final settledJson = jsonEncode(next.toJson());
      final anchor = tabsDayAnchor(now);
      final current = streakCurrent(next, anchor);
      final best = streakBest(next);
      final consumedPurchased =
          next.purchasedFreezes < effective.purchasedFreezes;
      if (settledJson != seedStateJson ||
          current != seedCurrent ||
          best != seedBest ||
          consumedPurchased) {
        unawaited(
          push(
            current,
            best,
            settledJson,
            purchasedFreezes: consumedPurchased ? next.purchasedFreezes : null,
          ).catchError((_) => false),
        );
      }
    }
  }

  /// One app-open settlement against the authoritative record.
  ///
  /// V2 (D1/D3): app-open runs rollover SETTLEMENT only — it
  /// bridges or breaks the gap since the last counted day, runs
  /// accrual rollover, and stamps the evaluation day — but it
  /// NEVER adds a counted day. The counted-day event is Daily
  /// Summary completion ([recordSummaryComplete]).
  ///
  /// [pullSucceeded] distinguishes "the server answered" from "the
  /// pull failed" — the distinction the anti-fabrication rule turns
  /// on. [seedCurrent]/[seedBest] are the pull's counters,
  /// [seedStateJson] its day-level blob, and
  /// [seedPurchasedFreezes] its server purchased-freeze column
  /// (any may be null: a pre-VC100115 profile carries counters
  /// only; a new account carries neither). [push] writes a settled
  /// record back to the profile; it fires only when the settled
  /// record differs from what the server already holds.
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
    int? seedPurchasedFreezes,
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

    final adopted = _adopt(
      pullSucceeded: pullSucceeded,
      seedCurrent: seedCurrent,
      seedBest: seedBest,
      seedStateJson: seedStateJson,
      seedPurchasedFreezes: seedPurchasedFreezes,
      now: now,
      seedMode: _seedAdoption,
    );
    if (adopted == null) {
      // No local record and no successful pull: NEVER fabricate a
      // run. The caller keeps its honest empty display.
      return StreakState.empty;
    }

    // P0 fix (Defect A1) — open-day revalidation at adoption: a
    // counted/restored mark for the still-open Tabs day with no
    // summary-completion record is a legacy app-open artifact and
    // is stripped before settlement (closed days untouched).
    final effective = revalidateOpenDay(adopted, tabsDayStr(now));
    // A strip is itself a state change: force the persist below
    // even when settlement turns out to be a no-op.
    if (effective != adopted) _dirty = true;

    final next = settle(effective, now);
    _installAndPush(
      effective: effective,
      next: next,
      pullSucceeded: pullSucceeded,
      seedCurrent: seedCurrent,
      seedBest: seedBest,
      seedStateJson: seedStateJson,
      now: now,
      push: push,
    );
    return next;
  }

  /// One Daily Summary completion (D1): the counted-day event.
  ///
  /// Adoption, anti-fabrication, and push-back are exactly
  /// [recordOpen]'s (shared [_adopt] / [_installAndPush]); only
  /// the evaluation differs — [completeDay] settles with the
  /// summary's own Tabs day as the anchor, then counts that day.
  /// [summaryDay] is any moment inside the summary's Tabs day
  /// (the feeling-day start is the natural value); the counted
  /// day is derived from it via the Tabs anchor (A7). Per A8 a
  /// summary can only complete while its Tabs day is open — the
  /// caller (summary_completeness' watcher) enforces that; this
  /// method counts the day it is given.
  ///
  /// Returns the settled state and, when a record existed (or was
  /// confirmed-empty by a successful pull), the completion result
  /// the UI celebrates with. An unseeded empty state with a null
  /// completion means "no record anywhere and no confirmation" —
  /// NOTHING was counted, persisted, or pushed.
  Future<({StreakState state, StreakCompletionResult? completion})>
  recordSummaryComplete({
    required bool pullSucceeded,
    required int? seedCurrent,
    required int? seedBest,
    required String? seedStateJson,
    int? seedPurchasedFreezes,
    required DateTime now,
    required DateTime summaryDay,
    StreakSyncPush? push,
  }) async {
    await ensureLoaded();
    if (!_loaded) {
      // C-04 parity with recordOpen: a failed disk read refuses.
      return (state: StreakState.empty, completion: null);
    }

    final summaryTabsDay = tabsDayStr(summaryDay);
    final adopted = _adopt(
      pullSucceeded: pullSucceeded,
      seedCurrent: seedCurrent,
      seedBest: seedBest,
      seedStateJson: seedStateJson,
      seedPurchasedFreezes: seedPurchasedFreezes,
      now: now,
      seedMode: _seedCompletion,
      summaryTabsDay: summaryTabsDay,
    );
    if (adopted == null) {
      // Anti-fabrication parity: no local record + no successful
      // pull = no counted day (the brief's pinned test case).
      return (state: StreakState.empty, completion: null);
    }

    // P0 fix (Defect A1) — same open-day revalidation as
    // recordOpen: a legacy mark for the open day is stripped
    // first, then the genuine completion below re-counts the day
    // AND records it, so the day is henceforth legitimate.
    final effective = revalidateOpenDay(adopted, tabsDayStr(now));
    if (effective != adopted) _dirty = true;

    final done = completeDay(
      effective,
      summaryTabsDay: summaryTabsDay,
      now: now,
    );
    // The completion record (P0 fix): this day's summary really
    // completed — the mark that protects the counted day from
    // every future adoption's open-day revalidation.
    var nextState = done.state;
    if (!nextState.summaryCompletedDays.contains(summaryTabsDay)) {
      nextState = nextState.copyWith(
        summaryCompletedDays: {
          ...nextState.summaryCompletedDays,
          summaryTabsDay,
        },
      );
    }
    _installAndPush(
      effective: effective,
      next: nextState,
      pullSucceeded: pullSucceeded,
      seedCurrent: seedCurrent,
      seedBest: seedBest,
      seedStateJson: seedStateJson,
      now: now,
      push: push,
    );
    return (state: nextState, completion: done.result);
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
