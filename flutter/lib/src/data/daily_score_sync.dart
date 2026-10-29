/// Daily Score server sync (founder direction, Oct 28, 2026):
/// push the day's score to the server so it is saved and loaded
/// when the founder signs in on another device. Until now Daily
/// Scores were device-local only (persisted in
/// [HealthHistoryStore]); this file is the sync layer over them.
///
/// SERVER CONTRACT (built in parallel — coded against exactly
/// this):
/// - `POST /api/sync/daily-scores`, body `{scores: [record]}` →
///   `{success, inserted, replaced, ignored}`. Server write rules:
///   `auto` inserts only when no row exists (never overwrites);
///   `manual_refresh` replaces an `auto` row, or a
///   `manual_refresh` row with an older computedAt.
/// - `GET /api/sync/daily-scores` → `{success: true, scores:
///   [record]}`, the caller's rows only, date-ascending.
/// - Record keys: date ('YYYY-MM-DD'), score (int),
///   sleepScore/hrvScore/restingHrScore (int|null), asleepMinutes,
///   sleepNeedMinutes (int|null), hrvMs, hrvBaselineMs
///   (number|null), restingHrBpm (int|null),
///   restingHrBaselineBpm (number|null), source
///   ('auto'|'manual_refresh'), algorithmVersion (int),
///   computedAt (epoch ms int).
///
/// PUSH: every successful `persistScore` (the engine) and every
/// successful `replaceScore` (the refresher) enqueues a record
/// here. The queue is DURABLE (one JSON blob in
/// FlutterSecureStorage, the same storage family as the other
/// owner-bound stores) and OWNER-STAMPED: it survives process
/// death, and a queue stamped to account A is dropped WITHOUT
/// being sent when the session owner is account B — the VC
/// 100107 lesson: pending/unconfirmed data must be owner-bound
/// and must NEVER be flushed under a different account. An
/// unstamped queue carrying records is likewise unprovable, so a
/// known session owner drops it unsent rather than adopting it.
/// Flush is one batched POST; on success the sent records leave
/// the queue, on failure they stay for the next trigger. Flush
/// triggers: after enqueue, on sign-in completion (via
/// `main.dart`'s home-landing funnel), and when the score history
/// screen opens. All of it is fire-and-forget from the callers:
/// sync never blocks or delays score display.
///
/// QUEUE DEDUP mirrors the server rules, so the queue can never
/// resurrect a stale `auto` over a `manual_refresh`: a re-queued
/// record for a date replaces the queued one ONLY when the new
/// record is a `manual_refresh` over an `auto`, a
/// `manual_refresh` newer than a queued `manual_refresh`, or an
/// `auto` newer than a queued `auto` (the last is defensive —
/// write-once scoring produces at most one auto per day).
///
/// HYDRATION: GET the server scores and merge them into
/// [HealthHistoryStore] under this EXACT conflict rule:
///   * Local day missing a score → take the server record (fill).
///   * Both present → take the server record ONLY IF
///     server.source == 'manual_refresh' AND server.computedAt >
///     local computedAt. In every other case the local record
///     stands.
///   * Hydration writes the persisted score + the three component
///     subscores + source/computedAt/algorithmVersion metadata +
///     the raw inputs (asleepMinutes → the row's sleep minutes,
///     hrvMs → hrvRmssdMs, restingHrBpm) ONLY into fields that are
///     locally absent — it must NEVER overwrite a locally present
///     biometric value (Health Connect is the source of truth for
///     biometrics).
///   * Hydration runs only against the store's bound owner; on
///     owner mismatch it does nothing (the store's existing owner
///     logic governs).
/// A legacy local record (persisted before sync, no metadata)
/// has computedAt 0, so a server manual_refresh with any
/// computedAt wins over it. The rule itself is implemented in
/// [HealthHistoryStore.applyHydratedScores]; this service owns
/// the fetch, the owner checks, and the wipe-generation guard
/// (a hydration that started before a sign-out/deletion wipe
/// must not land after it and resurrect the wiped scores).
///
/// NO user-visible copy exists in this file and sync adds none
/// anywhere: v1 sync is invisible.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:tabs_lab/src/data/daily_score.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// One Daily Score record, in the exact JSON shape of the server
/// contract (see the file header). Also the queue's unit: the
/// blob stores these records verbatim.
class DailyScoreSyncRecord {
  final String date; // 'YYYY-MM-DD'
  final int score;
  final int? sleepScore;
  final int? hrvScore;
  final int? restingHrScore;
  final int? asleepMinutes;
  final int? sleepNeedMinutes;
  final double? hrvMs;
  final double? hrvBaselineMs;
  final int? restingHrBpm;
  final double? restingHrBaselineBpm;

  /// [dailyScoreSourceAuto] or [dailyScoreSourceManualRefresh].
  final String source;
  final int algorithmVersion;

  /// Epoch ms at persist time (the same stamp the local store's
  /// score metadata carries for this record).
  final int computedAt;

  const DailyScoreSyncRecord({
    required this.date,
    required this.score,
    this.sleepScore,
    this.hrvScore,
    this.restingHrScore,
    this.asleepMinutes,
    this.sleepNeedMinutes,
    this.hrvMs,
    this.hrvBaselineMs,
    this.restingHrBpm,
    this.restingHrBaselineBpm,
    required this.source,
    required this.algorithmVersion,
    required this.computedAt,
  });

  /// All contract keys are always present; absent values are
  /// explicit nulls, matching the contract's `int|null` /
  /// `number|null` fields.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'date': date,
        'score': score,
        'sleepScore': sleepScore,
        'hrvScore': hrvScore,
        'restingHrScore': restingHrScore,
        'asleepMinutes': asleepMinutes,
        'sleepNeedMinutes': sleepNeedMinutes,
        'hrvMs': hrvMs,
        'hrvBaselineMs': hrvBaselineMs,
        'restingHrBpm': restingHrBpm,
        'restingHrBaselineBpm': restingHrBaselineBpm,
        'source': source,
        'algorithmVersion': algorithmVersion,
        'computedAt': computedAt,
      };

  /// Tolerant parse (server numbers may arrive as strings).
  /// Null when the record is not contract-shaped (no usable date,
  /// score, source, or computedAt) — a malformed record is
  /// skipped, never repaired into an invented one.
  static DailyScoreSyncRecord? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    int? asInt(dynamic v) =>
        v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
    double? asDouble(dynamic v) =>
        v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
    final date = raw['date']?.toString();
    final score = asInt(raw['score']);
    final source = raw['source']?.toString();
    final computedAt = asInt(raw['computedAt']);
    if (date == null ||
        date.isEmpty ||
        score == null ||
        (source != dailyScoreSourceAuto &&
            source != dailyScoreSourceManualRefresh) ||
        computedAt == null) {
      return null;
    }
    return DailyScoreSyncRecord(
      date: date,
      score: score,
      sleepScore: asInt(raw['sleepScore']),
      hrvScore: asInt(raw['hrvScore']),
      restingHrScore: asInt(raw['restingHrScore']),
      asleepMinutes: asInt(raw['asleepMinutes']),
      sleepNeedMinutes: asInt(raw['sleepNeedMinutes']),
      hrvMs: asDouble(raw['hrvMs']),
      hrvBaselineMs: asDouble(raw['hrvBaselineMs']),
      restingHrBpm: asInt(raw['restingHrBpm']),
      restingHrBaselineBpm: asDouble(raw['restingHrBaselineBpm']),
      source: source!,
      algorithmVersion: asInt(raw['algorithmVersion']) ??
          dailyScoreAlgorithmVersion,
      computedAt: computedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DailyScoreSyncRecord &&
      other.date == date &&
      other.score == score &&
      other.sleepScore == sleepScore &&
      other.hrvScore == hrvScore &&
      other.restingHrScore == restingHrScore &&
      other.asleepMinutes == asleepMinutes &&
      other.sleepNeedMinutes == sleepNeedMinutes &&
      other.hrvMs == hrvMs &&
      other.hrvBaselineMs == hrvBaselineMs &&
      other.restingHrBpm == restingHrBpm &&
      other.restingHrBaselineBpm == restingHrBaselineBpm &&
      other.source == source &&
      other.algorithmVersion == algorithmVersion &&
      other.computedAt == computedAt;

  @override
  int get hashCode => Object.hash(
      date,
      score,
      sleepScore,
      hrvScore,
      restingHrScore,
      asleepMinutes,
      sleepNeedMinutes,
      hrvMs,
      hrvBaselineMs,
      restingHrBpm,
      restingHrBaselineBpm,
      source,
      algorithmVersion,
      computedAt);

  @override
  String toString() =>
      'DailyScoreSyncRecord($date, $score, $source @ $computedAt)';
}

/// Builds the contract record for one computation — the payload
/// builder every push goes through. Component scores are the
/// computation's ROUNDED values (exactly what was persisted);
/// [algorithmVersion] comes from [dailyScoreAlgorithmVersion];
/// [computedAt] is the persist-time stamp the caller also wrote
/// into the store's score metadata.
DailyScoreSyncRecord buildDailyScoreRecord(
  DailyScoreComputation computation, {
  required String source,
  required int computedAt,
}) =>
    DailyScoreSyncRecord(
      date: computation.date,
      score: computation.dailyScore,
      sleepScore: computation.sleepScoreRounded,
      hrvScore: computation.hrvScoreRounded,
      restingHrScore: computation.restingHrScoreRounded,
      asleepMinutes: computation.asleepMinutes,
      sleepNeedMinutes: computation.sleepNeedMinutes,
      hrvMs: computation.hrvMs,
      hrvBaselineMs: computation.hrvBaselineMs,
      restingHrBpm: computation.restingHrBpm,
      restingHrBaselineBpm: computation.restingHrBaselineBpm,
      source: source,
      algorithmVersion: dailyScoreAlgorithmVersion,
      computedAt: computedAt,
    );

/// Whether [incoming] may replace the already-queued [existing]
/// record for the same date — the queue mirror of the server
/// write rules (see the file header). A stale auto can never
/// displace a queued manual_refresh, and an older manual_refresh
/// can never displace a newer one.
bool dailyScoreQueueShouldReplace(
  DailyScoreSyncRecord existing,
  DailyScoreSyncRecord incoming,
) {
  if (incoming.source == dailyScoreSourceManualRefresh) {
    if (existing.source == dailyScoreSourceAuto) return true;
    return incoming.computedAt > existing.computedAt;
  }
  // Incoming auto: never over a manual_refresh; over an auto
  // only when newer.
  if (existing.source == dailyScoreSourceManualRefresh) return false;
  return incoming.computedAt > existing.computedAt;
}

/// The batched push: true only when the server accepted the whole
/// batch (see [TabsBackend.postDailyScores]).
typedef DailyScorePoster = Future<bool> Function(
    List<DailyScoreSyncRecord> records);

/// The hydration pull: the caller's server records, date
/// ascending; an empty list on any failure (unknown == nothing to
/// merge, never an invented record).
typedef DailyScoreFetcher = Future<List<DailyScoreSyncRecord>> Function();

class DailyScoreSync {
  static const String storageKey = 'daily_score_sync_queue_v1';

  /// The shared production instance: the shared store, a real
  /// backend (its session store is the source of the owner email
  /// and the session token), and secure-storage queue IO.
  static final DailyScoreSync instance = DailyScoreSync._(
    (key) => const FlutterSecureStorage().read(key: key),
    (key, value) =>
        const FlutterSecureStorage().write(key: key, value: value),
    (key) => const FlutterSecureStorage().delete(key: key),
    store: HealthHistoryStore.instance,
    poster: null,
    fetcher: null,
    ownerProvider: null,
    backend: TabsBackend(),
  );

  /// Production-shaped construction over an explicit backend
  /// (tests of the backend wiring use [withDeps] instead).
  factory DailyScoreSync({
    required HealthHistoryStore store,
    required TabsBackend backend,
  }) =>
      DailyScoreSync._(
        (key) => const FlutterSecureStorage().read(key: key),
        (key, value) =>
            const FlutterSecureStorage().write(key: key, value: value),
        (key) => const FlutterSecureStorage().delete(key: key),
        store: store,
        poster: null,
        fetcher: null,
        ownerProvider: null,
        backend: backend,
      );

  /// Test wiring: fake poster/fetcher/storage/owner, no backend.
  factory DailyScoreSync.withDeps({
    required HealthHistoryStore store,
    required DailyScorePoster poster,
    required DailyScoreFetcher fetcher,
    Future<String?> Function()? ownerProvider,
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) =>
      DailyScoreSync._(
        read,
        write,
        delete ??
            (key) async {
              await write(key, '');
            },
        store: store,
        poster: poster,
        fetcher: fetcher,
        ownerProvider: ownerProvider,
        backend: null,
      );

  DailyScoreSync._(
    this._read,
    this._write,
    this._delete, {
    required this.store,
    required DailyScorePoster? poster,
    required DailyScoreFetcher? fetcher,
    required Future<String?> Function()? ownerProvider,
    required TabsBackend? backend,
  })  : _poster = poster ?? backend!.postDailyScores,
        _fetcher = fetcher ?? backend!.fetchDailyScores,
        _ownerProvider = ownerProvider ?? backend!.readEmail;

  final HealthHistoryStore store;
  final DailyScorePoster _poster;
  final DailyScoreFetcher _fetcher;
  final Future<String?> Function() _ownerProvider;
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
    // poster/fetcher/owner stay the production backend's).
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

  /// Pending records by date. In memory once loaded; the blob is
  /// the durable copy.
  final Map<String, DailyScoreSyncRecord> _queue = {};

  /// The normalized owner this queue is stamped to, once known.
  String? _boundOwner;
  String? get boundOwner => _boundOwner;

  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<bool>? _flushFuture;

  /// Bumped by [clear] / owner-mismatch drops: work that started
  /// before the bump (a hydration fetch, a flush POST) must not
  /// land its effects after it.
  int _generation = 0;

  /// Every tracked fire-and-forget operation, so tests (and only
  /// tests / careful callers) can settle the service with
  /// [drain]. Production callers never await these.
  final Set<Future<dynamic>> _ops = {};

  void _track(Future<dynamic> op) {
    _ops.add(op);
    unawaited(op.then((_) {
      _ops.remove(op);
    }, onError: (_) {
      _ops.remove(op);
    }));
  }

  /// Awaits every tracked operation until none remain (operations
  /// can spawn more — a flush after an enqueue). Never throws.
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

  /// The queued records, date-ascending (unmodifiable).
  Future<List<DailyScoreSyncRecord>> pendingRecords() async {
    await _ensureLoaded(await _resolveOwner());
    final out = _queue.values.toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return List.unmodifiable(out);
  }

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  /// The session owner for this call: the provider (the backend's
  /// stored session email) first, the store's bound owner as the
  /// fallback — the store is bound at warm/login before any
  /// scoring runs, so in production one of the two always knows.
  Future<String?> _resolveOwner() async {
    try {
      final fromProvider = _normalizeEmail(await _ownerProvider());
      if (fromProvider != null) return fromProvider;
    } catch (_) {}
    return _normalizeEmail(store.ownerEmail);
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
    Map<String, dynamic>? map;
    try {
      final raw = await _ioRead(storageKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) map = decoded;
      }
    } catch (_) {
      map = null;
    }
    final expected = _normalizeEmail(currentOwner);
    String? blobOwner;
    final blobRecords = <DailyScoreSyncRecord>[];
    if (map != null) {
      blobOwner = _normalizeEmail(map['ownerEmail']?.toString());
      final rawRecords = map['records'];
      if (rawRecords is List) {
        for (final raw in rawRecords) {
          final record = DailyScoreSyncRecord.fromJson(raw);
          if (record != null) blobRecords.add(record);
        }
      }
    }
    if (expected != null && blobOwner != expected && blobRecords.isNotEmpty) {
      // Foreign (or unprovable) records on disk: NEVER adopted
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
    for (final record in blobRecords) {
      _queue.putIfAbsent(record.date, () => record);
    }
    _boundOwner = expected ?? blobOwner;
    _loaded = true;
  }

  /// Owner enforcement once the blob is already loaded: a newly
  /// learned owner that differs from the stamp (or any known
  /// owner meeting an unstamped non-empty queue) drops the queue
  /// unsent. Never throws.
  Future<void> _enforceLoadedOwner(String? currentOwner) async {
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
    try {
      final records = _queue.values.toList()
        ..sort((a, b) => a.date.compareTo(b.date));
      await _ioWrite(
        storageKey,
        jsonEncode({
          'ownerEmail': _boundOwner,
          'records': records.map((r) => r.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Memory stays; the next persist retries. A queue write
      // failure must never break scoring.
    }
  }

  // ── Enqueue + flush (push) ─────────────────────────────────────

  /// Enqueues [record] durably, then triggers a flush
  /// (fire-and-forget). The dedup rule is
  /// [dailyScoreQueueShouldReplace]. Returns true when the record
  /// is queued after this call (a stale record that may not
  /// replace the queued one returns false — it was correctly
  /// refused, not lost: the queued newer/manual record is the one
  /// that will be sent). Never throws.
  Future<bool> enqueueRecord(
    DailyScoreSyncRecord record, {
    String? ownerEmail,
  }) async {
    try {
      final owner =
          _normalizeEmail(ownerEmail) ?? await _resolveOwner();
      await _ensureLoaded(owner);
      await _enforceLoadedOwner(owner);
      final existing = _queue[record.date];
      if (existing != null &&
          !dailyScoreQueueShouldReplace(existing, record)) {
        return false;
      }
      _queue[record.date] = record;
      await _persistQueue();
      // Flush trigger: after enqueue. Tracked, never awaited
      // here — a slow or dead connection must not delay the
      // score that was just persisted.
      _track(flush());
      return true;
    } catch (_) {
      return false;
    }
  }

  /// The engine/refresher hook shape: builds the contract record
  /// from a JUST-PERSISTED computation and enqueues it,
  /// fire-and-forget. This is the call the score write paths make
  /// — it returns immediately and can never throw into them.
  void queueComputation(
    DailyScoreComputation computation, {
    required String source,
    required int computedAt,
  }) {
    final record = buildDailyScoreRecord(
      computation,
      source: source,
      computedAt: computedAt,
    );
    _track(enqueueRecord(record));
  }

  /// Pushes the whole queue as ONE batched POST. Single-flight:
  /// concurrent triggers join the same run. On success the sent
  /// records leave the queue (a record re-queued mid-flight with
  /// a newer payload stays — only the exact sent version is
  /// removed); on failure everything stays for the next trigger.
  /// Before sending, the queue is re-checked against the CURRENT
  /// session owner: a queue stamped to a different account is
  /// dropped unsent. Never throws; returns true when the queue is
  /// fully flushed.
  Future<bool> flush() {
    final existing = _flushFuture;
    if (existing != null) return existing;
    late final Future<bool> future;
    future = _flushInternal().whenComplete(() {
      if (identical(_flushFuture, future)) _flushFuture = null;
    });
    _flushFuture = future;
    _track(future);
    return future;
  }

  Future<bool> _flushInternal() async {
    try {
      final owner = await _resolveOwner();
      await _ensureLoaded(owner);
      await _enforceLoadedOwner(owner);
      if (_queue.isEmpty) return true;
      // After enforcement, a non-empty queue is either stamped to
      // the current owner or to no known owner with no session to
      // check against (tests / pre-login): the latter still goes
      // through the backend, whose missing token fails the POST
      // honestly and keeps the queue.
      final sent = _queue.values.toList()
        ..sort((a, b) => a.date.compareTo(b.date));
      var ok = false;
      try {
        ok = await _poster(sent);
      } catch (_) {
        ok = false;
      }
      if (!ok) return false;
      var removedAny = false;
      for (final record in sent) {
        if (_queue[record.date] == record) {
          _queue.remove(record.date);
          removedAny = true;
        }
      }
      if (removedAny) await _persistQueue();
      return _queue.isEmpty;
    } catch (_) {
      return false;
    }
  }

  // ── Hydration (pull) ───────────────────────────────────────────

  /// Fetches the server's scores and merges them into the store
  /// under the conflict rule in the file header (implemented by
  /// [HealthHistoryStore.applyHydratedScores]). Returns how many
  /// local days changed. Never throws.
  ///
  /// Owner discipline: when both the session owner and the
  /// store's bound owner are known and differ, hydration does
  /// NOTHING (the store's existing owner logic governs — the
  /// mismatch wipe runs through the login hooks). A wipe that
  /// lands while the fetch is in flight (generation bump via
  /// [clear] / an owner drop) aborts the merge, so hydration can
  /// never resurrect scores after a sign-out/deletion wipe.
  Future<int> hydrate() async {
    final generation = _generation;
    try {
      final owner = await _resolveOwner();
      await _ensureLoaded(owner);
      await _enforceLoadedOwner(owner);
      final storeOwner = _normalizeEmail(store.ownerEmail);
      if (owner != null && storeOwner != null && owner != storeOwner) {
        return 0;
      }
      final records = await _fetcher();
      if (generation != _generation) return 0; // wiped mid-fetch
      if (records.isEmpty) return 0;
      // The session may have changed while the GET was in
      // flight: re-resolve and refuse to merge under a different
      // owner than the one the fetch started with.
      final ownerNow = await _resolveOwner();
      if (owner != null && ownerNow != null && ownerNow != owner) {
        return 0;
      }
      if (ownerNow != null &&
          storeOwner != null &&
          ownerNow != storeOwner) {
        return 0;
      }
      if (generation != _generation) return 0;
      return await store.applyHydratedScores([
        for (final r in records)
          HydratedScore(
            date: r.date,
            dailyScore: r.score,
            scoreSleep: r.sleepScore,
            scoreHrv: r.hrvScore,
            scoreRestingHr: r.restingHrScore,
            source: r.source,
            computedAt: r.computedAt,
            algorithmVersion: r.algorithmVersion,
            asleepMinutes: r.asleepMinutes,
            hrvMs: r.hrvMs,
            restingHrBpm: r.restingHrBpm,
          ),
      ]);
    } catch (_) {
      return 0;
    }
  }

  /// The sign-in / screen-open trigger shape: flush what is
  /// queued, then hydrate from the server. Returns the hydration
  /// change count. Never throws.
  Future<int> flushAndHydrate() async {
    await flush();
    return hydrate();
  }

  // ── Wipe / owner hooks (migraine-store precedent) ──────────────

  /// Drops the whole queue and unbinds the owner. Called on
  /// logout / account deletion (via `AccountActions`) and on
  /// session expiry (via `main.dart`), exactly like the other
  /// account-bound stores; the generation bump also aborts any
  /// in-flight hydration merge. Never throws.
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
  /// different account — or carries records with no stamp at all
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
