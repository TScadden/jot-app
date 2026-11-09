/// H1-07 — DURABLE outbox for medication change events.
///
/// The original capture path (spec §2.6) was fire-and-forget:
/// `emitMedicationChangeEvents` awaited
/// [TabsBackend.postMedicationChangeEvents] and discarded its
/// result — and that method returns `false` (it does NOT throw)
/// on transport failure / timeout / 500, because the transport
/// layer swallows errors into a null response. Every later
/// medication edit diffs against the ALREADY-PUSHED medication
/// list, so a transition lost this way could never be
/// re-derived: a permanent silent gap in the Medication
/// Timeline, the Clinician Report, and Patterns F5.
///
/// This queue fixes that, modeled on the [DailyScoreSync]
/// queue skeleton (enqueue/flush, owner enforcement, records
/// leave only on verified success; [LogEntryOutbox] is the
/// second reference):
///
/// - STAGE BEFORE NETWORK: on emit, the ORIGINAL event objects
///   (with their ORIGINAL client-supplied ids) are persisted to
///   durable storage BEFORE any network attempt is made. An
///   isolate/process death after staging loses nothing.
/// - REMOVE ONLY ON TRUE: a flush POSTs the staged events via
///   [TabsBackend.postMedicationChangeEvents] and removes them
///   ONLY when it returns true. False/throw keeps them queued
///   for the next trigger.
/// - REPLAY IS SAFE: the server contract is insert-only
///   idempotent (`ON CONFLICT DO NOTHING` on the
///   client-supplied event id — see the doc on
///   [TabsBackend.postMedicationChangeEvents]), so re-sending
///   the original objects with their original ids is harmless.
///   Re-DIFFING later would NOT be safe (the diff base has
///   already moved), which is why the queue stores the events
///   themselves, never a marker to recompute them.
/// - OWNER-STAMPED: the blob carries the staging account's
///   email. A queue stamped to account A is dropped WITHOUT
///   being sent when the session owner is account B (the VC
///   100107 lesson, same as [DailyScoreSync]); an unstamped
///   queue carrying events is likewise unprovable, so a known
///   session owner drops it unsent rather than adopting it.
///
/// FLUSH TRIGGERS (mirroring [DailyScoreSync]'s): immediately
/// after staging, on sign-in landing / app resume (wired in
/// `main.dart` alongside the Daily Score trigger), and when the
/// Medications screen opens. Explicit logout / account deletion
/// clears the queue via `AccountActions` (the DailyScoreSync
/// treatment); session EXPIRY deliberately does NOT wipe it —
/// unlike Daily Scores, these events exist nowhere else locally,
/// so an expiry wipe would recreate the H1-07 loss. The retained
/// blob stays owner-stamped: the same account's next sign-in
/// flushes it, a different account's sign-in drops it unsent via
/// [clearIfOwnerMismatch] before any flush can run (the
/// [LogEntryOutbox] retention precedent).
///
/// NO user-visible copy exists in this file and the queue adds
/// none anywhere: a queued event is invisible, exactly like the
/// sync queues it is modeled on.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// The batched push: true only when the server accepted the
/// batch (see [TabsBackend.postMedicationChangeEvents]).
typedef MedicationChangeEventPoster = Future<bool> Function(
  List<MedicationChangeEvent> events,
);

class MedicationChangeEventOutbox {
  static const String storageKey = 'medication_change_event_outbox_v1';

  /// The shared production instance: secure-storage queue IO and
  /// a real backend (its session store is the source of the
  /// owner email and the session token). Call sites that hold
  /// their own backend (the three emit sites, `main.dart`'s
  /// triggers, the Medications screen) pass that backend's
  /// poster/owner in per call, so the queue always flushes
  /// through the caller's session — the instance defaults are
  /// only the fallback for poster-less flush calls.
  static final MedicationChangeEventOutbox instance =
      MedicationChangeEventOutbox._(
        (key) => const FlutterSecureStorage().read(key: key),
        (key, value) =>
            const FlutterSecureStorage().write(key: key, value: value),
        (key) => const FlutterSecureStorage().delete(key: key),
        poster: null,
        ownerProvider: null,
        backend: TabsBackend(),
      );

  /// Test wiring: fake storage, no backend. Poster/owner are
  /// supplied per call (the emit/flush helpers derive them from
  /// the caller's backend), exactly as in production.
  factory MedicationChangeEventOutbox.withDeps({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) => MedicationChangeEventOutbox._(
    read,
    write,
    delete ??
        (key) async {
          await write(key, '');
        },
    poster: null,
    ownerProvider: null,
    backend: null,
  );

  MedicationChangeEventOutbox._(
    this._read,
    this._write,
    this._delete, {
    required MedicationChangeEventPoster? poster,
    required Future<String?> Function()? ownerProvider,
    required TabsBackend? backend,
  }) : _defaultPoster = poster ?? backend?.postMedicationChangeEvents,
       _defaultOwnerProvider = ownerProvider ?? backend?.readEmail;

  final MedicationChangeEventPoster? _defaultPoster;
  final Future<String?> Function()? _defaultOwnerProvider;
  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;
  final Future<void> Function(String key) _delete;

  @visibleForTesting
  void debugSetStore({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) {
    // Only the singleton's IO is re-wireable this way (its
    // poster/owner stay per-call / the production backend's).
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
    _queue.clear();
    _boundOwner = null;
    _loaded = false;
    _loadFuture = null;
    _flushFuture = null;
    _generation++;
  }

  /// Pending events by id, in staging order. In memory once
  /// loaded; the blob is the durable copy.
  final Map<String, MedicationChangeEvent> _queue = {};

  /// The normalized owner this queue is stamped to, once known.
  String? _boundOwner;
  String? get boundOwner => _boundOwner;

  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<bool>? _flushFuture;

  /// Bumped by [clear] / owner-mismatch drops: a flush POST that
  /// started before the bump must not land its removals after it
  /// against a queue that no longer holds those events (the
  /// removal loop's identity check already no-ops then; the bump
  /// is the explicit marker, mirroring [DailyScoreSync]).
  int _generation = 0;

  /// Every tracked fire-and-forget operation, so tests (and only
  /// tests / careful callers) can settle the service with
  /// [drain]. Production callers never await these.
  final Set<Future<dynamic>> _ops = {};

  void _track(Future<dynamic> op) {
    _ops.add(op);
    unawaited(
      op.then(
        (_) {
          _ops.remove(op);
        },
        onError: (_) {
          _ops.remove(op);
        },
      ),
    );
  }

  /// Awaits every tracked operation until none remain (operations
  /// can spawn more — a flush after a stage). Never throws.
  Future<void> drain() async {
    while (_ops.isNotEmpty) {
      final pending = _ops.toList();
      for (final op in pending) {
        try {
          await op;
        } catch (_) {}
      }
    }
  }

  /// The queued events, in staging order (unmodifiable).
  Future<List<MedicationChangeEvent>> pendingEvents() async {
    await _ensureLoaded(await _resolveOwner(null));
    return List.unmodifiable(_queue.values);
  }

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  Future<String?> _resolveOwner(
    Future<String?> Function()? ownerProvider,
  ) async {
    final provider = ownerProvider ?? _defaultOwnerProvider;
    if (provider == null) return null;
    try {
      return _normalizeEmail(await provider());
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
    _track(future);
    return future;
  }

  Future<void> _doLoad(String? currentOwner) async {
    String? raw;
    try {
      raw = await _ioRead(storageKey);
    } catch (_) {
      // D-T04 — a storage READ failure is neither an empty disk
      // nor a corrupt blob (the H1-04 conflation PR #44 fixed in
      // HealthHistoryStore): the on-disk blob may be perfectly
      // valid. Leave the queue and owner untouched, leave
      // [_loaded] false so the next [_ensureLoaded] retries the
      // read, and keep [_persistQueue] gated off — treating this
      // like an empty queue would let the next stage overwrite
      // the blob with only the new event, permanently destroying
      // every previously staged event.
      return;
    }
    Map<String, dynamic>? map;
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) map = decoded;
      } catch (_) {
        // Corrupt blob: provably unusable, so — per PR #44's
        // semantics — it is the one read outcome besides a
        // genuinely missing/empty blob that may be treated as
        // empty (map stays null, the load completes).
        map = null;
      }
    }
    final expected = _normalizeEmail(currentOwner);
    String? blobOwner;
    final blobEvents = <MedicationChangeEvent>[];
    if (map != null) {
      blobOwner = _normalizeEmail(map['ownerEmail']?.toString());
      final rawEvents = map['events'];
      if (rawEvents is List) {
        for (final raw in rawEvents) {
          if (raw is Map<String, dynamic>) {
            try {
              final event = MedicationChangeEvent.fromJson(raw);
              if (event.id.isNotEmpty) blobEvents.add(event);
            } catch (_) {
              // Skip malformed rows — never fail the whole queue.
            }
          }
        }
      }
    }
    if (expected != null && blobOwner != expected && blobEvents.isNotEmpty) {
      // Foreign (or unprovable) events on disk: NEVER adopted
      // into this account, NEVER sent under its session — the
      // queue is dropped unsent and the blob deleted (the house
      // owner-bound rule; VC 100107).
      _queue.clear();
      _boundOwner = expected;
      _loaded = true;
      _generation++;
      try {
        await _ioDelete(storageKey);
      } catch (_) {}
      return;
    }
    for (final event in blobEvents) {
      _queue.putIfAbsent(event.id, () => event);
    }
    _boundOwner = expected ?? blobOwner;
    _loaded = true;
  }

  /// Owner enforcement once the blob is already loaded: a newly
  /// learned owner that differs from the stamp (or any known
  /// owner meeting an unstamped non-empty queue) drops the queue
  /// unsent. Never throws.
  Future<void> _enforceLoadedOwner(String? currentOwner) async {
    // D-T04 — enforcement DELETES the disk blob on a mismatch,
    // so it must never run off an unloaded queue: after a failed
    // load the disk blob's owner is unknown, and a blind delete
    // could destroy staged events the read never saw.
    if (!_loaded) return;
    final expected = _normalizeEmail(currentOwner);
    if (expected == null) return;
    if (_boundOwner == expected) return;
    if (_boundOwner == null && _queue.isEmpty) {
      _boundOwner = expected;
      return;
    }
    _queue.clear();
    _boundOwner = expected;
    _generation++;
    try {
      await _ioDelete(storageKey);
    } catch (_) {}
  }

  Future<void> _persistQueue() async {
    // D-T04 — persist gate, mirroring PR #44's
    // HealthHistoryStore.persist: a no-op until a load has
    // SUCCEEDED in this isolate. After a transient read failure
    // the in-memory queue is an incomplete image of the disk
    // blob, and writing it would erase the events the failed
    // read never loaded. [clear] re-arms writes explicitly (it
    // marks the queue loaded over an authoritative-empty memory).
    if (!_loaded) return;
    try {
      await _ioWrite(
        storageKey,
        jsonEncode({
          'ownerEmail': _boundOwner,
          'events': _queue.values.map((e) => e.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Memory stays; the next persist retries. A queue write
      // failure must never break a completed medication save.
    }
  }

  // ── Stage + flush (push) ───────────────────────────────────────

  /// Stages [events] DURABLY (persisted, owner-stamped), then
  /// triggers a flush. The persist is awaited BEFORE any network
  /// attempt is made, so a caller that fires this unawaited still
  /// gets the ordering guarantee: the POST cannot start until
  /// the events are on disk. Re-staging an id that is already
  /// queued is a no-op (the original object stands — the server
  /// dedups on that same id). Never throws; returns true when
  /// every event is durably queued after this call (false when
  /// the disk load never succeeded — see the D-T04 gate in
  /// [_persistQueue]).
  Future<bool> stageAndFlush(
    List<MedicationChangeEvent> events, {
    MedicationChangeEventPoster? poster,
    Future<String?> Function()? ownerProvider,
  }) async {
    try {
      final owner = await _resolveOwner(ownerProvider);
      await _ensureLoaded(owner);
      await _enforceLoadedOwner(owner);
      var changed = false;
      for (final event in events) {
        if (event.id.isEmpty) continue;
        if (!_queue.containsKey(event.id)) {
          _queue[event.id] = event;
          changed = true;
        }
      }
      if (changed) await _persistQueue();
      // D-T04 — queued in memory is not staged: when the load
      // never succeeded (transient read failure) the persist
      // above was gated off, so report false. The events stay in
      // the in-memory queue, and a later successful load merges
      // the disk blob around them (putIfAbsent) instead of the
      // gated persist having overwritten it.
      final staged =
          _loaded &&
          events.every((e) => e.id.isEmpty || _queue.containsKey(e.id));
      // Flush trigger: immediately after staging — and AFTER
      // the durable persist above, so no network attempt can
      // start (let alone settle) before the events are on disk.
      // The flush is awaited here so a caller that awaits the
      // emit gets the old emit's semantics (the POST attempt has
      // settled); a caller that fires the emit unawaited still
      // gets the ordering guarantee, because the persist
      // precedes the flush inside this future either way.
      await flush(poster: poster, ownerProvider: ownerProvider);
      return staged;
    } catch (_) {
      return false;
    }
  }

  /// Pushes the whole queue as ONE batched POST through [poster]
  /// (or the instance default). Single-flight: concurrent
  /// triggers join the same run. On a TRUE return the sent
  /// events leave the queue; on false/throw everything stays
  /// for the next trigger. Before sending, the queue is
  /// re-checked against the CURRENT session owner: a queue
  /// stamped to a different account is dropped unsent. Never
  /// throws; returns true when the queue is fully flushed.
  Future<bool> flush({
    MedicationChangeEventPoster? poster,
    Future<String?> Function()? ownerProvider,
  }) {
    final existing = _flushFuture;
    if (existing != null) return existing;
    late final Future<bool> future;
    future = _flushInternal(poster: poster, ownerProvider: ownerProvider)
        .whenComplete(() {
          if (identical(_flushFuture, future)) _flushFuture = null;
        });
    _flushFuture = future;
    _track(future);
    return future;
  }

  Future<bool> _flushInternal({
    MedicationChangeEventPoster? poster,
    Future<String?> Function()? ownerProvider,
  }) async {
    try {
      final owner = await _resolveOwner(ownerProvider);
      await _ensureLoaded(owner);
      // D-T04 — an unloaded queue cannot be pronounced flushed:
      // the disk may still hold staged events this isolate never
      // read. Report false so the events stay queued for the
      // next trigger, when the load retries.
      if (!_loaded) return false;
      await _enforceLoadedOwner(owner);
      if (_queue.isEmpty) return true;
      final effectivePoster = poster ?? _defaultPoster;
      if (effectivePoster == null) return false;
      // After enforcement, a non-empty queue is either stamped to
      // the current owner or to no known owner with no session to
      // check against (tests / pre-login): the latter still goes
      // through the backend, whose missing token fails the POST
      // honestly and keeps the queue.
      final sent = _queue.values.toList();
      var ok = false;
      try {
        ok = await effectivePoster(sent);
      } catch (_) {
        ok = false;
      }
      if (!ok) return false;
      var removedAny = false;
      for (final event in sent) {
        if (identical(_queue[event.id], event)) {
          _queue.remove(event.id);
          removedAny = true;
        }
      }
      if (removedAny) await _persistQueue();
      return _queue.isEmpty;
    } catch (_) {
      return false;
    }
  }

  // ── Wipe / owner hooks (DailyScoreSync precedent) ──────────────

  /// Drops the whole queue and unbinds the owner. Called on
  /// explicit logout / account deletion (via `AccountActions`),
  /// exactly like the other account-bound stores. Never throws.
  Future<void> clear() async {
    _generation++;
    _queue.clear();
    _boundOwner = null;
    _loaded = true;
    try {
      await _ioDelete(storageKey);
    } catch (_) {}
  }

  /// Login/register ownership enforcement: binds this queue to
  /// [email] and drops it UNSENT when it is stamped for a
  /// different account — or carries events with no stamp at all
  /// (unprovable ownership). Returns true when a drop happened.
  /// A null/blank [email] binds nothing and drops nothing. Never
  /// throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = _normalizeEmail(email);
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
