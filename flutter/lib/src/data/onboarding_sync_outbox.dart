/// C-08 (sub-claim 2) — DURABLE outbox for onboarding's finalize
/// posts.
///
/// The defect: `SetupLoadingScreen._finalize` awaited
/// [TabsBackend.postLogCategories] and [TabsBackend.postSyncProfile]
/// and DISCARDED both bool results. Both return `false` (they do
/// not throw) on transport failure / non-200, so a finalize that
/// ran offline — or against a 500ing server — lost the categories
/// and profile fields the user had just picked during signup:
/// no local copy, no retry, and the local `onboarding_complete`
/// flag was set anyway, so the step never ran again. Silent,
/// outright data loss (the Oct 28, 2026 data-loss class).
///
/// This queue is OPTION 1 of the Nov 9 C-08 options, modeled on
/// [MedicationChangeEventOutbox] (owner-stamped secure-storage
/// blob, stage durably, remove only on proven delivery) with the
/// [LogEntryOutbox] F2 retention treatment on logout:
///
/// - STAGE ON FAILURE: the success path is unchanged — finalize
///   posts directly and stages NOTHING. Only when a direct post
///   returns false is its payload staged here, durably and
///   owner-stamped, before finalize completes.
/// - TWO INDEPENDENT SLOTS: categories and profile fail and
///   recover independently; each slot leaves the queue only when
///   ITS delivery is proven (see the merge rules below).
/// - CATEGORIES FLUSH IS ADDITIVE, NEVER A REPLAY: the
///   categories endpoint is a FULL-LIST REPLACE (the server
///   deletes every row missing from the payload — see
///   [TabsBackend.postLogCategories]), so replaying finalize's
///   stale merged list would delete categories created after
///   onboarding. Only the categories finalize ADDED are staged;
///   a flush re-pulls the server's CURRENT list and posts
///   current ∪ additions (see [_flushCategories]).
/// - PROFILE FLUSH IS RECENCY-GUARDED: the profile endpoint is a
///   partial COALESCE upsert with no client-readable updated_at,
///   so a flush compares the server's CURRENT values against the
///   staged snapshot and never overwrites a differing non-empty
///   current value (see [_flushProfile]).
/// - OWNER-STAMPED: a queue staged under account A is dropped
///   UNSENT when the session owner is account B, and an
///   unstamped queue meeting a known owner is likewise
///   unprovable and dropped unsent (the medication-outbox rule).
/// - DISPATCH-WINDOW GUARDED (Vera E-condition 1): both flush
///   slots re-check slot identity, generation, and bound owner
///   after the attempts-persist await, immediately before
///   dispatch — a clear/owner-drop landing in that window
///   suppresses the post — and the persist write itself is
///   generation-guarded so it cannot resurrect a blob an
///   enforcement delete already removed.
/// - SUPERSESSION (Juno P4 condition, VC 100133): a successful
///   Settings push of `userContext` / `conditions` supersedes
///   the staged copy of exactly those fields (see
///   [supersedeStagedProfileFields]). A deliberate clear is an
///   edit whose value is empty; without this, the recency
///   guard would read the cleared server value as "nothing to
///   protect" and a later flush would silently resurrect
///   health data the user removed.
/// - LOGOUT DISPOSITION (stated, never silent): explicit logout
///   first attempts a bounded flush (AccountActions); whatever
///   remains unconfirmed is RETAINED owner-stamped for the same
///   account's return ([retainUnconfirmed]). Session expiry
///   likewise retains. Only account DELETION clears the queue —
///   the account is gone server-side, so no session could ever
///   legitimately receive the payload.
///
/// NO user-visible copy exists in this file and the queue adds
/// none anywhere: a queued onboarding sync is invisible, exactly
/// like the sync queues it is modeled on.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'quick_log_models.dart';
import 'tabs_backend.dart';

/// One staged categories payload: ONLY the categories finalize
/// added (see the library doc — the kept rows already exist
/// server-side, and staging them would invite a clobbering
/// full-list replay).
class OnboardingCategoriesSync {
  final List<QuickLogCategory> addedCategories;
  final int stagedAtMs;
  final int attempts;

  const OnboardingCategoriesSync({
    required this.addedCategories,
    required this.stagedAtMs,
    this.attempts = 0,
  });

  OnboardingCategoriesSync copyWith({int? attempts}) =>
      OnboardingCategoriesSync(
        addedCategories: addedCategories,
        stagedAtMs: stagedAtMs,
        attempts: attempts ?? this.attempts,
      );

  Map<String, dynamic> toJson() => {
    'addedCategories': addedCategories.map((c) => c.toSyncJson()).toList(),
    'stagedAtMs': stagedAtMs,
    'attempts': attempts,
  };

  static OnboardingCategoriesSync? fromJson(Map<String, dynamic> json) {
    final raw = json['addedCategories'];
    if (raw is! List) return null;
    final added = <QuickLogCategory>[];
    for (final row in raw) {
      if (row is Map<String, dynamic>) {
        try {
          added.add(QuickLogCategory.fromJson(row));
        } catch (_) {
          // Skip malformed rows — never fail the whole slot.
        }
      }
    }
    if (added.isEmpty) return null;
    final stagedAt = json['stagedAtMs'];
    final attempts = json['attempts'];
    return OnboardingCategoriesSync(
      addedCategories: added,
      stagedAtMs: stagedAt is num ? stagedAt.toInt() : 0,
      attempts: attempts is num ? attempts.toInt() : 0,
    );
  }
}

/// One staged profile payload: the exact field map finalize
/// tried to post (`userContext`, `conditions`,
/// `onboardingComplete`). No other profile fields are ever
/// staged.
class OnboardingProfileSync {
  final Map<String, dynamic> fields;
  final int stagedAtMs;
  final int attempts;

  const OnboardingProfileSync({
    required this.fields,
    required this.stagedAtMs,
    this.attempts = 0,
  });

  OnboardingProfileSync copyWith({
    int? attempts,
    Map<String, dynamic>? fields,
  }) => OnboardingProfileSync(
    fields: fields ?? this.fields,
    stagedAtMs: stagedAtMs,
    attempts: attempts ?? this.attempts,
  );

  Map<String, dynamic> toJson() => {
    'fields': fields,
    'stagedAtMs': stagedAtMs,
    'attempts': attempts,
  };

  static OnboardingProfileSync? fromJson(Map<String, dynamic> json) {
    final raw = json['fields'];
    if (raw is! Map<String, dynamic> || raw.isEmpty) return null;
    final stagedAt = json['stagedAtMs'];
    final attempts = json['attempts'];
    return OnboardingProfileSync(
      fields: Map<String, dynamic>.from(raw),
      stagedAtMs: stagedAt is num ? stagedAt.toInt() : 0,
      attempts: attempts is num ? attempts.toInt() : 0,
    );
  }
}

class OnboardingSyncOutbox {
  static const String storageKey = 'onboarding_sync_outbox_v1';

  /// The shared production instance: secure-storage queue IO.
  /// Backends are supplied per call (staging/flush call sites
  /// hold the session's backend), so the queue always acts
  /// through the caller's session — the medication-outbox
  /// pattern.
  static final OnboardingSyncOutbox instance = OnboardingSyncOutbox._(
    (key) => const FlutterSecureStorage().read(key: key),
    (key, value) => const FlutterSecureStorage().write(key: key, value: value),
    (key) => const FlutterSecureStorage().delete(key: key),
  );

  /// Test wiring: fake storage; backends are supplied per call.
  factory OnboardingSyncOutbox.withDeps({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) => OnboardingSyncOutbox._(
    read,
    write,
    delete ??
        (key) async {
          await write(key, '');
        },
  );

  OnboardingSyncOutbox._(this._read, this._write, this._delete);

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final Future<void> Function(String key) _delete;

  @visibleForTesting
  void debugSetStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) {
    _debugRead = read;
    _debugWrite = write;
    if (delete != null) _debugDelete = delete;
  }

  Future<String?> Function(String key)? _debugRead;
  Future<void> Function(String key, String value)? _debugWrite;
  Future<void> Function(String key)? _debugDelete;

  Future<String?> _ioRead(String key) =>
      _debugRead != null ? _debugRead!(key) : _read(key);
  Future<void> _ioWrite(String key, String value) =>
      _debugWrite != null ? _debugWrite!(key, value) : _write(key, value);
  Future<void> _ioDelete(String key) =>
      _debugDelete != null ? _debugDelete!(key) : _delete(key);

  @visibleForTesting
  void debugReset() {
    _categories = null;
    _profile = null;
    _boundOwner = null;
    _loaded = false;
    _loadFuture = null;
    _flushFuture = null;
    _generation++;
  }

  OnboardingCategoriesSync? _categories;
  OnboardingProfileSync? _profile;

  /// The normalized owner this queue is stamped to, once known.
  String? _boundOwner;
  String? get boundOwner => _boundOwner;

  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<bool>? _flushFuture;

  /// Bumped by [clear] / owner-mismatch drops so a flush that
  /// started before the bump cannot land its slot removals
  /// against a queue that no longer holds those payloads (the
  /// removal paths re-check slot identity; the bump is the
  /// explicit marker, mirroring the medication outbox).
  int _generation = 0;

  bool get hasPending => _categories != null || _profile != null;

  /// The staged categories slot, loading the disk blob first so
  /// a fresh process sees what a previous one staged.
  Future<OnboardingCategoriesSync?> pendingCategories(
    TabsBackend backend,
  ) async {
    await _ensureLoaded(await _resolveOwner(backend));
    return _categories;
  }

  /// The staged profile slot (see [pendingCategories]).
  Future<OnboardingProfileSync?> pendingProfile(TabsBackend backend) async {
    await _ensureLoaded(await _resolveOwner(backend));
    return _profile;
  }

  static String? normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  Future<String?> _resolveOwner(TabsBackend backend) async {
    try {
      return normalizeEmail(await backend.readEmail());
    } catch (_) {
      return null;
    }
  }

  // ── Queue load / persist (owner-stamped blob) ──────────────────

  Future<void> _ensureLoaded(String? currentOwner) {
    if (_loaded) return _enforceLoadedOwner(currentOwner);
    final existing = _loadFuture;
    if (existing != null) return existing;
    late final Future<void> future;
    future = _doLoad(currentOwner).whenComplete(() {
      if (identical(_loadFuture, future)) _loadFuture = null;
    });
    _loadFuture = future;
    return future;
  }

  Future<void> _doLoad(String? currentOwner) async {
    String? raw;
    try {
      raw = await _ioRead(storageKey);
    } catch (_) {
      // D-T04/C-01 — a storage READ failure is neither an empty
      // disk nor a corrupt blob: the on-disk blob may be
      // perfectly valid. Leave state untouched and [_loaded]
      // false so the next trigger retries the read, and keep
      // [_persistQueue] gated off — treating this as an empty
      // queue would let the next stage overwrite the blob and
      // permanently destroy the staged payload.
      return;
    }
    Map<String, dynamic>? map;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) map = decoded;
      } catch (_) {
        // Corrupt blob: provably unusable — the one read outcome
        // besides a genuinely missing/empty blob that may be
        // treated as empty (PR #44 semantics).
        map = null;
      }
    }
    final expected = normalizeEmail(currentOwner);
    String? blobOwner;
    OnboardingCategoriesSync? blobCategories;
    OnboardingProfileSync? blobProfile;
    if (map != null) {
      blobOwner = normalizeEmail(map['ownerEmail']?.toString());
      final rawCategories = map['categories'];
      if (rawCategories is Map<String, dynamic>) {
        blobCategories = OnboardingCategoriesSync.fromJson(rawCategories);
      }
      final rawProfile = map['profile'];
      if (rawProfile is Map<String, dynamic>) {
        blobProfile = OnboardingProfileSync.fromJson(rawProfile);
      }
    }
    final blobHasPayload = blobCategories != null || blobProfile != null;
    if (expected != null && blobOwner != expected && blobHasPayload) {
      // Foreign (or unprovable) payload on disk: NEVER adopted
      // into this account, NEVER sent under its session — the
      // queue is dropped unsent and the blob deleted (the house
      // owner-bound rule; VC 100107).
      _categories = null;
      _profile = null;
      _boundOwner = expected;
      _loaded = true;
      _generation++;
      try {
        await _ioDelete(storageKey);
      } catch (_) {}
      return;
    }
    // Slots fill only when not already held — a payload staged
    // this session is at least as new as the blob's copy.
    _categories ??= blobCategories;
    _profile ??= blobProfile;
    _boundOwner = expected ?? blobOwner;
    _loaded = true;
  }

  /// Owner enforcement once the blob is already loaded: a newly
  /// learned owner that differs from the stamp (or any known
  /// owner meeting an unstamped non-empty queue) drops the queue
  /// unsent. Never throws.
  Future<void> _enforceLoadedOwner(String? currentOwner) async {
    // Enforcement DELETES the disk blob on a mismatch, so it
    // must never run off an unloaded queue: after a failed load
    // the blob's owner is unknown, and a blind delete could
    // destroy a staged payload the read never saw.
    if (!_loaded) return;
    final expected = normalizeEmail(currentOwner);
    if (expected == null) return;
    if (_boundOwner == expected) return;
    if (_boundOwner == null && !hasPending) {
      _boundOwner = expected;
      return;
    }
    _categories = null;
    _profile = null;
    _boundOwner = expected;
    _generation++;
    try {
      await _ioDelete(storageKey);
    } catch (_) {}
  }

  /// Persists (or, when drained, deletes) the blob. Returns
  /// false when the write was gated off or failed — memory
  /// stays either way and the next persist retries; a queue
  /// write failure must never break onboarding itself.
  ///
  /// GENERATION-GUARDED (Vera E-condition 1, blob-resurrection
  /// half): the snapshot (slot identities, bound owner,
  /// [_generation]) is captured BEFORE the storage await. A
  /// [clear] / owner-mismatch drop landing while the write is
  /// in flight bumps [_generation], nulls the slots and issues
  /// its own delete — but that delete can run BEFORE this
  /// write lands, so an unguarded write would resurrect the
  /// dropped blob on disk after the enforcement delete. After
  /// the await, a diverged snapshot is therefore never left
  /// on disk: an emptied queue is re-deleted, and a queue that
  /// now holds a DIFFERENT payload (a restage during the
  /// window) is re-persisted from current memory instead.
  Future<bool> _persistQueue() async {
    // D-T04 persist gate: a no-op until a load has SUCCEEDED in
    // this process. After a transient read failure the in-memory
    // queue is an incomplete image of the disk blob, and writing
    // it would erase the payload the failed read never loaded.
    // [clear] re-arms writes explicitly (it marks the queue
    // loaded over an authoritative-empty memory).
    if (!_loaded) return false;
    final genAtStart = _generation;
    final snapCategories = _categories;
    final snapProfile = _profile;
    final snapOwner = _boundOwner;
    bool snapshotCurrent() =>
        _generation == genAtStart &&
        identical(_categories, snapCategories) &&
        identical(_profile, snapProfile) &&
        _boundOwner == snapOwner;
    var repersist = false;
    try {
      if (snapCategories == null && snapProfile == null) {
        await _ioDelete(storageKey);
        if (snapshotCurrent()) return true;
        // A restage landed during the delete: its payload must
        // not be left deleted — persist the current image.
        if (!hasPending) return false;
        repersist = true;
      } else {
        await _ioWrite(
          storageKey,
          jsonEncode({
            'ownerEmail': snapOwner,
            'categories': snapCategories?.toJson(),
            'profile': snapProfile?.toJson(),
          }),
        );
        if (snapshotCurrent()) return true;
        // The queue was cleared, owner-dropped, or restaged
        // while this write was in flight, and the write may
        // have landed AFTER the enforcement's delete: do not
        // leave the stale snapshot blob resurrected on disk.
        if (!hasPending) {
          try {
            await _ioDelete(storageKey);
          } catch (_) {}
          return false;
        }
        repersist = true;
      }
    } catch (_) {
      return false;
    }
    if (repersist) return _persistQueue();
    return false;
  }

  // ── Stage ──────────────────────────────────────────────────────

  /// Durably stages a failed categories post: ONLY the
  /// categories finalize ADDED (see the library doc). A re-stage
  /// REPLACES the slot — a newer finalize supersedes an older
  /// one because it was computed from a fresher server pull.
  /// Returns true when the payload is durably queued. Never
  /// throws.
  Future<bool> stageCategories(
    TabsBackend backend,
    List<QuickLogCategory> addedCategories,
  ) async {
    if (addedCategories.isEmpty) return true;
    try {
      final owner = await _resolveOwner(backend);
      await _ensureLoaded(owner);
      await _enforceLoadedOwner(owner);
      if (!_loaded) return false;
      _categories = OnboardingCategoriesSync(
        addedCategories: List.unmodifiable(addedCategories),
        stagedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      // Staged means DURABLY staged: a gated/failed persist
      // reports false (the payload stays in memory for this
      // process, and the caller's failure is honest).
      return await _persistQueue();
    } catch (_) {
      return false;
    }
  }

  /// Durably stages a failed profile post: the exact field map
  /// finalize tried to send. Same replace-on-restage rule as
  /// [stageCategories]. Never throws.
  Future<bool> stageProfile(
    TabsBackend backend,
    Map<String, dynamic> fields,
  ) async {
    if (fields.isEmpty) return true;
    try {
      final owner = await _resolveOwner(backend);
      await _ensureLoaded(owner);
      await _enforceLoadedOwner(owner);
      if (!_loaded) return false;
      _profile = OnboardingProfileSync(
        fields: Map<String, dynamic>.from(fields),
        stagedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      return await _persistQueue();
    } catch (_) {
      return false;
    }
  }

  // ── Supersession (Juno P4 condition) ─────────────────────────

  /// Per-field supersession of the staged profile snapshot
  /// (Juno ruling §1.3.1, VC 100133 — BINDING condition on E).
  ///
  /// Semantics, exactly as ruled:
  /// - Only `userContext` and `conditions` are affected; every
  ///   other key is ignored. `onboardingComplete` is NEVER
  ///   removed by this operation — its monotonic-true delivery
  ///   obligation (and the Reset handling) is unchanged.
  /// - The named key(s) are removed from the staged profile
  ///   slot's field map. If fields remain (including the case
  ///   where ONLY `onboardingComplete` remains), the slot
  ///   persists so `onboardingComplete: true` still delivers;
  ///   if the field map becomes wholly empty, the slot drops.
  /// - No staged profile slot, or none of the named keys
  ///   present in it ⇒ no-op (no identity change, no generation
  ///   bump, no persist).
  ///
  /// Discipline: the in-memory amendment is SYNCHRONOUS — it
  /// runs in this method's synchronous prefix, before the
  /// first await, through the same slot-identity replacement +
  /// [_generation] bump as [clear] — and persistence goes
  /// through the generation-guarded [_persistQueue]. A flush
  /// already parked in its attempts-persist window therefore
  /// aborts at its existing dispatch-window re-check instead
  /// of posting a just-superseded field. Never throws (a
  /// persist failure leaves the amended memory authoritative
  /// for this process; the next persist retries the write).
  Future<void> supersedeStagedProfileFields(Iterable<String> keys) async {
    const supersedeable = {'userContext', 'conditions'};
    final targets = keys.where(supersedeable.contains).toSet();
    if (targets.isEmpty) return;
    final slot = _profile;
    if (slot == null) return;
    if (!targets.any(slot.fields.containsKey)) return;
    final remaining = Map<String, dynamic>.from(slot.fields)
      ..removeWhere((key, _) => targets.contains(key));
    _generation++;
    _profile = remaining.isEmpty ? null : slot.copyWith(fields: remaining);
    try {
      await _persistQueue();
    } catch (_) {
      // _persistQueue never throws by contract; this guard is
      // belt-and-braces so a supersession call site can never
      // surface an error into a Settings save that already
      // succeeded server-side.
    }
  }

  // ── Flush ──────────────────────────────────────────────────────

  /// Pushes whatever is queued, merge-safely (see the library
  /// doc). Single-flight: concurrent triggers join the same run.
  /// Returns true when the queue is fully drained. Never throws.
  Future<bool> flush(TabsBackend backend) {
    final existing = _flushFuture;
    if (existing != null) return existing;
    late final Future<bool> future;
    future = _flushInternal(backend).whenComplete(() {
      if (identical(_flushFuture, future)) _flushFuture = null;
    });
    _flushFuture = future;
    return future;
  }

  Future<bool> _flushInternal(TabsBackend backend) async {
    try {
      final owner = await _resolveOwner(backend);
      await _ensureLoaded(owner);
      // An unloaded queue cannot be pronounced flushed: the
      // disk may still hold a staged payload this process never
      // read. Report false so it stays queued for the next
      // trigger, when the load retries.
      if (!_loaded) return false;
      await _enforceLoadedOwner(owner);
      if (!hasPending) return true;
      if (_categories != null) {
        await _flushCategories(backend);
      }
      if (_profile != null) {
        await _flushProfile(backend);
      }
      return !hasPending;
    } catch (_) {
      return false;
    }
  }

  /// Additive-union categories flush (design §3a): re-pull the
  /// server's CURRENT categories, fold the staged additions in,
  /// and post current ∪ additions — the full-list-replace
  /// endpoint can then delete nothing that exists now.
  Future<void> _flushCategories(TabsBackend backend) async {
    final slot = _categories;
    if (slot == null) return;
    final generation = _generation;
    final boundOwnerAtStart = _boundOwner;
    List<QuickLogCategory>? current;
    try {
      current = await backend.fetchLogCategoriesOrNull();
    } catch (_) {
      current = null;
    }
    // A failed pull is NOT an empty account: merging against an
    // unknown state is how clobbers happen. Keep the slot.
    if (current == null) return;
    if (!identical(_categories, slot) || generation != _generation) {
      return; // slot replaced / queue cleared mid-flight
    }

    final merged = List<QuickLogCategory>.of(current);
    var maxId = 0;
    for (final c in merged) {
      if (c.id > maxId) maxId = c.id;
    }
    var appended = false;
    for (final staged in slot.addedCategories) {
      final nameKey = staged.name.trim().toLowerCase();
      var sameIdSameName = false;
      var nameTaken = false;
      for (final row in merged) {
        if (row.name.trim().toLowerCase() == nameKey) {
          nameTaken = true;
          if (row.id == staged.id) sameIdSameName = true;
        }
      }
      final idTaken =
          !sameIdSameName && merged.any((row) => row.id == staged.id);
      if (sameIdSameName || nameTaken) {
        // Already delivered, or the name already exists under
        // some id: never duplicate a name, never overwrite the
        // existing row.
        continue;
      }
      if (idTaken) {
        // The staged id now belongs to a DIFFERENT (post-
        // onboarding) category: keep the staged category under
        // a fresh id instead of overwriting or being deleted
        // into it.
        maxId += 1;
        merged.add(
          QuickLogCategory(
            id: maxId,
            name: staged.name,
            icon: staged.icon,
            colorHex: staged.colorHex,
            isDefault: staged.isDefault,
            sortOrder: staged.sortOrder,
          ),
        );
      } else {
        if (staged.id > maxId) maxId = staged.id;
        merged.add(staged);
      }
      appended = true;
    }

    if (!appended) {
      // Every addition is already on the server: delivery is
      // proven without a post (which would be a full-list
      // replace for no gain).
      if (identical(_categories, slot)) {
        _categories = null;
        await _persistQueue();
      }
      return;
    }

    final attempted = slot.copyWith(attempts: slot.attempts + 1);
    _categories = attempted;
    await _persistQueue();
    // Vera E-condition 1 — DISPATCH-WINDOW RE-CHECK: the
    // attempts-persist await above is a window in which a
    // clear() (Reset Account Status / account deletion) or an
    // owner-mismatch drop (logout + another account's sign-in)
    // can land. Those paths mutate exactly this identity —
    // they null the slot and bump [_generation] (and rebind
    // [_boundOwner] on a switch) — so re-check all three AFTER
    // the persist, immediately before dispatch. Without this,
    // the post below would still fire, and because
    // TabsBackend reads the CURRENT session token at dispatch
    // time, a stale full-list replace could land under the
    // NEW account's token and delete its categories.
    if (!identical(_categories, attempted) ||
        generation != _generation ||
        boundOwnerAtStart != _boundOwner) {
      return; // cleared / owner-dropped / restaged mid-window
    }
    var ok = false;
    try {
      ok = await backend.postLogCategories(merged);
    } catch (_) {
      ok = false;
    }
    if (!ok) return;
    backend.invalidateSyncPull();
    // Remove only if the slot is still the one we flushed — a
    // restage mid-flight keeps its newer payload queued.
    if (identical(_categories, attempted)) {
      _categories = null;
      await _persistQueue();
    }
  }

  /// Recency-guarded profile flush (design §3b): compare the
  /// server's CURRENT profile values against the staged
  /// snapshot; send only fields that are still empty server-side
  /// (plus the monotonic `onboardingComplete: true`), never a
  /// field whose current non-empty value differs — that value
  /// postdates the snapshot and wins.
  Future<void> _flushProfile(TabsBackend backend) async {
    final slot = _profile;
    if (slot == null) return;
    final generation = _generation;
    final boundOwnerAtStart = _boundOwner;
    Map<String, dynamic>? current;
    try {
      current = await backend.fetchProfile();
    } catch (_) {
      current = null;
    }
    // Recency is unprovable without a pull: keep the slot.
    if (current == null) return;
    if (!identical(_profile, slot) || generation != _generation) {
      return;
    }

    final payload = <String, dynamic>{};
    for (final entry in slot.fields.entries) {
      final key = entry.key;
      final staged = entry.value;
      if (key == 'onboardingComplete') {
        // Monotonic: only ever staged as true; send unless the
        // server already holds it.
        if (current[key] != true && staged == true) {
          payload[key] = true;
        }
        continue;
      }
      if (key == 'conditions') {
        if (_conditionsEqual(current[key], staged)) continue;
        if (_conditionsEmpty(current[key])) {
          payload[key] = staged;
        }
        // Differing non-empty current conditions are newer
        // (Settings edits them post-onboarding): never overwrite.
        continue;
      }
      final currentText = current[key]?.toString() ?? '';
      final stagedText = staged?.toString() ?? '';
      if (currentText == stagedText) continue;
      if (currentText.isEmpty && stagedText.isNotEmpty) {
        payload[key] = staged;
      }
      // Differing non-empty current value wins (see above).
    }

    if (payload.isEmpty) {
      // Every field is either already applied or superseded by
      // a newer server value: the slot's delivery obligation is
      // discharged without a post.
      if (identical(_profile, slot)) {
        _profile = null;
        await _persistQueue();
      }
      return;
    }

    final attempted = slot.copyWith(attempts: slot.attempts + 1);
    _profile = attempted;
    await _persistQueue();
    // Vera E-condition 1 — DISPATCH-WINDOW RE-CHECK: same
    // window and same identity as in [_flushCategories]. A
    // clear() landing in the persist window (notably Reset
    // Account Status, whose explicit `onboardingComplete:
    // false` this slot's stale `true` would silently undo) or
    // an owner switch must suppress this dispatch; the backend
    // reads the CURRENT token at dispatch, so an unchecked
    // post could also land in another account's profile.
    if (!identical(_profile, attempted) ||
        generation != _generation ||
        boundOwnerAtStart != _boundOwner) {
      return; // cleared / owner-dropped / restaged mid-window
    }
    var ok = false;
    try {
      ok = await backend.postSyncProfile(payload);
    } catch (_) {
      ok = false;
    }
    if (!ok) return;
    if (identical(_profile, attempted)) {
      _profile = null;
      await _persistQueue();
    }
  }

  /// Conditions equality on the DECODED name lists (set
  /// equality), so a formatting-only difference between the
  /// stored JSON strings is not mistaken for a user edit. Falls
  /// back to raw string equality when either side won't decode
  /// as a list.
  static bool _conditionsEqual(dynamic current, dynamic staged) {
    final a = _decodeConditions(current);
    final b = _decodeConditions(staged);
    if (a != null && b != null) {
      return a.length == b.length && a.containsAll(b);
    }
    return (current?.toString() ?? '') == (staged?.toString() ?? '');
  }

  static bool _conditionsEmpty(dynamic value) {
    final decoded = _decodeConditions(value);
    if (decoded != null) return decoded.isEmpty;
    final text = value?.toString().trim() ?? '';
    return text.isEmpty || text == '[]';
  }

  static Set<String>? _decodeConditions(dynamic value) {
    dynamic raw = value;
    if (raw is String) {
      if (raw.trim().isEmpty) return const {};
      try {
        raw = jsonDecode(raw);
      } catch (_) {
        return null;
      }
    }
    if (raw is List) {
      return raw.map((e) => '$e').where((e) => e.isNotEmpty).toSet();
    }
    if (raw == null) return const {};
    return null;
  }

  // ── Wipe / retention / owner hooks ─────────────────────────────

  /// Retains the owner-stamped blob across a logout or session
  /// expiry whose flush did not confirm delivery (the
  /// LogEntryOutbox F2 treatment): the payload restores and
  /// flushes when the SAME account signs back in, and a
  /// DIFFERENT account's sign-in drops it unsent via
  /// [clearIfOwnerMismatch]. Returns true when a payload was
  /// retained. Never throws.
  Future<bool> retainUnconfirmed([TabsBackend? backend]) async {
    try {
      final owner = backend == null ? null : await _resolveOwner(backend);
      // With nothing loaded and no owner to bind, leave memory
      // and disk exactly as they are — an ownerless first load
      // here could adopt an unowned blob and a clear below would
      // wipe it (the LogEntryOutbox C-01 reasoning).
      if (!_loaded && owner == null) return false;
      await _ensureLoaded(owner);
      if (!_loaded) return false;
      if (!hasPending) {
        await clear();
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Drops the whole queue and unbinds the owner. Called on
  /// account DELETION only (via AccountActions) — the account
  /// is gone server-side, so no session could ever legitimately
  /// receive the payload. Explicit logout and session expiry
  /// RETAIN instead (see [retainUnconfirmed]). Never throws.
  Future<void> clear() async {
    _generation++;
    _categories = null;
    _profile = null;
    _boundOwner = null;
    _loaded = true;
    try {
      await _ioDelete(storageKey);
    } catch (_) {}
  }

  /// Login/register/restore ownership enforcement: binds this
  /// queue to [email] and drops it UNSENT when it is stamped
  /// for a different account — or carries a payload with no
  /// stamp at all (unprovable ownership). Returns true when a
  /// drop happened. A null/blank [email] binds nothing and
  /// drops nothing. Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = normalizeEmail(email);
    if (expected == null) return false;
    final before = _generation;
    try {
      await _ensureLoaded(expected);
      await _enforceLoadedOwner(expected);
    } catch (_) {
      return false;
    }
    return _generation != before;
  }
}

/// Flush trigger helper mirroring `flushMedicationChangeEvents`:
/// pushes any staged onboarding payload through [backend]'s
/// session. Fire-and-forget safe — the outbox never throws.
Future<bool> flushOnboardingSync(
  TabsBackend backend, {
  OnboardingSyncOutbox? outbox,
}) => (outbox ?? OnboardingSyncOutbox.instance).flush(backend);
