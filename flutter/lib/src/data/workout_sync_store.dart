/// Workout sync (Nov 27, 2026) — the session→entry link store
/// and delete tombstone for workouts synced from Health Connect
/// (DESIGN §1.4).
///
/// Why a dedicated store: the link must outlive the outbox
/// (records there are deleted on server confirmation), it is not
/// render cache (QuickLogCache is overwritten by loads), and it
/// is not per-day aggregates (HealthHistoryStore). One encrypted
/// JSON blob, owner-bound exactly like the sibling stores:
/// retained for the same account across logout, dropped when a
/// different account signs in (wired into the same main.dart
/// hooks as [LogEntryOutbox]).
///
/// The blob is keyed by the session's dedup key (DECISIONS
/// decision 3: `hc:<id>` → `hc:cr:<pkg>:<clientRecordId>` →
/// `hc:fp:<sha256>`). A LIVE link keeps its entryId/state/origin
/// plus the raw hcId (for re-keying). A TOMBSTONED link is
/// stripped to `{state: "tombstoned"}` ONLY (DECISIONS decision
/// 4, Juno privacy condition i): after deletion the store keeps
/// nothing but the session key itself + the tombstone flag.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A link record's lifecycle state. All three states mean "never
/// create an entry for this session again."
enum WorkoutLinkState { linked, adopted, tombstoned }

/// Where the linked entry came from: created by workout sync, or
/// a manual entry the merge rule adopted.
enum WorkoutLinkOrigin { synced, manual }

/// One session→entry link. A tombstoned link carries ONLY its
/// [state] (the strip — see the library doc): [entryId], [hcId]
/// and [origin] are null.
class WorkoutLink {
  final WorkoutLinkState state;
  final int? entryId;
  final WorkoutLinkOrigin? origin;

  /// The raw HC record id, kept while the link is live so a
  /// session first seen under a weaker dedup tier can be
  /// re-keyed if a stronger identifier appears later. Dropped by
  /// the tombstone strip.
  final String? hcId;

  const WorkoutLink({
    required this.state,
    this.entryId,
    this.origin,
    this.hcId,
  });

  bool get isTombstoned => state == WorkoutLinkState.tombstoned;

  Map<String, dynamic> toJson() {
    // DECISIONS decision 4 — the strip is structural, not a
    // serialization choice: a tombstoned record has no other
    // fields to write.
    if (isTombstoned) return {'state': 'tombstoned'};
    return {
      'state': state.name,
      if (entryId != null) 'entryId': entryId,
      if (origin != null) 'origin': origin!.name,
      if (hcId != null && hcId!.isNotEmpty) 'hcId': hcId,
    };
  }

  static WorkoutLink? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final stateName = '${raw['state'] ?? ''}';
    final state = WorkoutLinkState.values
        .where((s) => s.name == stateName)
        .firstOrNull;
    if (state == null) return null;
    if (state == WorkoutLinkState.tombstoned) {
      // The strip governs reads too: even a legacy/foreign blob
      // row that kept fields under a tombstone surfaces stripped.
      return const WorkoutLink(state: WorkoutLinkState.tombstoned);
    }
    final entryIdRaw = raw['entryId'];
    final originName = '${raw['origin'] ?? ''}';
    final hcIdRaw = raw['hcId'];
    return WorkoutLink(
      state: state,
      entryId: entryIdRaw is num ? entryIdRaw.toInt() : null,
      origin: WorkoutLinkOrigin.values
          .where((o) => o.name == originName)
          .firstOrNull,
      hcId: hcIdRaw is String && hcIdRaw.isNotEmpty ? hcIdRaw : null,
    );
  }
}

/// Diagnostics for ONE sync run (ROUND 3, FM-1/FM-4/FM-5): the
/// stage the run reached, the gate verdict, and the counts —
/// written on every exit path of `WorkoutSyncService._run` so a
/// silent fail-closed abort is distinguishable from an empty
/// read on-device. COUNTS AND CODES ONLY: no health values, no
/// session content, no exception messages (an exception
/// contributes its runtimeType string only) — the same privacy
/// posture as the rest of this blob.
class WorkoutSyncRunRecord {
  final int startedAtMs;
  final int finishedAtMs;

  /// One of warm/probe/gate/read/pull/loop/done — the furthest
  /// stage the run reached.
  final String stage;

  /// One of granted/denied/unknown/notChecked.
  final String grantVerdict;

  /// Sessions the rich read returned; null when the run never
  /// got a successful read.
  final int? sessionsRead;
  final int entriesCreated;
  final int entriesAdopted;
  final int sessionsSkipped;

  /// The read succeeded but enrichment was partial.
  final bool readPartial;

  /// The abort/skip code: a bridge errorCode, a fixed service
  /// code (CATEGORIES_UNAVAILABLE / STAGE_FAILED / READ_FAILED),
  /// or an exception's runtimeType string. Null on a clean run.
  final String? abortCode;

  const WorkoutSyncRunRecord({
    required this.startedAtMs,
    required this.finishedAtMs,
    required this.stage,
    required this.grantVerdict,
    required this.sessionsRead,
    required this.entriesCreated,
    required this.entriesAdopted,
    required this.sessionsSkipped,
    required this.readPartial,
    required this.abortCode,
  });

  Map<String, dynamic> toJson() => {
        'startedAtMs': startedAtMs,
        'finishedAtMs': finishedAtMs,
        'stage': stage,
        'grantVerdict': grantVerdict,
        if (sessionsRead != null) 'sessionsRead': sessionsRead,
        'entriesCreated': entriesCreated,
        'entriesAdopted': entriesAdopted,
        'sessionsSkipped': sessionsSkipped,
        'readPartial': readPartial,
        if (abortCode != null) 'abortCode': abortCode,
      };

  /// Lenient parse: a bad shape yields NO record (null), never a
  /// throw and never a half-record.
  static WorkoutSyncRunRecord? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final started = raw['startedAtMs'];
    final finished = raw['finishedAtMs'];
    final stage = raw['stage'];
    final verdict = raw['grantVerdict'];
    if (started is! num ||
        finished is! num ||
        stage is! String ||
        verdict is! String) {
      return null;
    }
    int count(String key) {
      final v = raw[key];
      return v is num ? v.toInt() : 0;
    }

    final sessionsReadRaw = raw['sessionsRead'];
    final abortRaw = raw['abortCode'];
    return WorkoutSyncRunRecord(
      startedAtMs: started.toInt(),
      finishedAtMs: finished.toInt(),
      stage: stage,
      grantVerdict: verdict,
      sessionsRead: sessionsReadRaw is num ? sessionsReadRaw.toInt() : null,
      entriesCreated: count('entriesCreated'),
      entriesAdopted: count('entriesAdopted'),
      sessionsSkipped: count('sessionsSkipped'),
      readPartial: raw['readPartial'] == true,
      abortCode: abortRaw is String && abortRaw.isNotEmpty ? abortRaw : null,
    );
  }
}

class WorkoutSyncStore {
  static const String storageKey = 'workout_sync_v1';

  static final WorkoutSyncStore instance = WorkoutSyncStore._internal();
  WorkoutSyncStore._internal();

  /// A fresh, non-singleton instance (the HealthHistoryStore
  /// .testInstance pattern): tests inject one so seeded links
  /// never leak across cases through the shared singleton.
  factory WorkoutSyncStore.testInstance() => WorkoutSyncStore._internal();

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write = (key, value) =>
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
    _links.clear();
    _reverse.clear();
    _ownerEmail = null;
    _lastSyncMs = null;
    _lastRun = null;
    _warmed = false;
    _warmLoadedUnownedData = false;
  }

  final Map<String, WorkoutLink> _links = {};

  /// In-memory reverse index entryId → session key, rebuilt on
  /// load and maintained on every mutation. The History delete
  /// hook looks links up by entry.
  final Map<int, String> _reverse = {};

  String? _ownerEmail;
  String? get ownerEmail => _ownerEmail;

  int? _lastSyncMs;

  /// Epoch ms of the last completed sync run (a successful rich
  /// read, including a genuinely-empty one). Never stamped on a
  /// failed read or a failed gate (DESIGN §3.3).
  int? get lastSyncMs => _lastSyncMs;

  WorkoutSyncRunRecord? _lastRun;

  /// The most recent sync run's diagnostics record (ROUND 3),
  /// or null when no run has recorded one yet.
  WorkoutSyncRunRecord? get lastRun => _lastRun;

  bool _warmed = false;
  bool get isWarmed => _warmed;

  bool _warmLoadedUnownedData = false;

  /// True when the disk warm adopted populated data with no
  /// verified owner (the H1-04 state): callers that cannot prove
  /// the owner must treat the store as read-only — a persist from
  /// this state would re-stamp `ownerEmail: null` over the blob
  /// and the next account-bound warm would drop it as foreign.
  bool get warmLoadedUnownedData =>
      _warmLoadedUnownedData && _ownerEmail == null && _links.isNotEmpty;

  /// All links, keyed by dedup key (unmodifiable).
  Map<String, WorkoutLink> get links => Map.unmodifiable(_links);

  WorkoutLink? linkForKey(String key) => _links[key];

  /// The link for an entry id (reverse lookup — the delete
  /// hook's entry point), or null when the entry is not linked.
  WorkoutLink? linkForEntry(int entryId) {
    final key = _reverse[entryId];
    return key == null ? null : _links[key];
  }

  /// The dedup key an entry id is linked under, or null.
  String? keyForEntry(int entryId) => _reverse[entryId];

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  // ── Warm / owner binding (HealthHistoryStore contract) ───────

  /// Cold-start warm from the disk blob. Never throws — a missing
  /// or corrupt blob starts empty. When [currentEmail] is known,
  /// a blob owned by a different account (or by no recorded
  /// account while carrying links) is dropped, exactly as the
  /// sibling stores do it; an unowned blob warmed WITHOUT a known
  /// account is readable but flagged [warmLoadedUnownedData] —
  /// never adopted as ownerless-owned data.
  ///
  /// A storage READ failure is neither missing nor corrupt
  /// (H1-04 part B / C-01): the warm does not complete, the store
  /// stays unwarmed, and [persist] stays gated off, so a
  /// transient failure can never be mistaken for an empty blob
  /// and overwritten. The next warm retries the read.
  Future<void> warmFromDisk({String? currentEmail}) async {
    final expected = _normalizeEmail(currentEmail);
    if (_warmed) {
      if (currentEmail != null) await clearIfOwnerMismatch(currentEmail);
      return;
    }
    String? raw;
    try {
      raw = await _read(storageKey);
    } catch (_) {
      return; // stay unwarmed; persist stays gated (see doc)
    }
    if (raw == null || raw.isEmpty) {
      // No blob exists to adopt: bind to the known session
      // account (the R70 fix D reasoning — otherwise the first
      // persist would stamp ownerEmail: null and the next
      // account-bound warm would drop the populated blob).
      if (expected != null) _ownerEmail = expected;
      _warmed = true;
      return;
    }
    Map<String, dynamic>? map;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) map = decoded;
    } catch (_) {
      map = null;
    }
    if (map == null) {
      // Corrupt blob: provably unusable — same as missing.
      if (expected != null) _ownerEmail = expected;
      _warmed = true;
      return;
    }
    final blobOwner = _normalizeEmail(map['ownerEmail']?.toString());
    final linksRaw = map['links'];
    final hasData = linksRaw is Map && linksRaw.isNotEmpty;
    if (expected != null &&
        blobOwner != expected &&
        (blobOwner != null || hasData)) {
      // Foreign-owned (or unowned-but-populated under a known
      // account): drop rather than leak one account's links
      // into another's session.
      _resetMemory();
      _warmed = true;
      _ownerEmail = expected;
      try {
        await _delete(storageKey);
      } catch (_) {}
      return;
    }
    if (linksRaw is Map) {
      for (final entry in linksRaw.entries) {
        final link = WorkoutLink.fromJson(entry.value);
        if (link == null) continue;
        final key = entry.key.toString();
        _links[key] = link;
        final entryId = link.entryId;
        if (entryId != null) _reverse[entryId] = key;
      }
    }
    final ls = map['lastSyncMs'];
    if (ls is num) _lastSyncMs = ls.toInt();
    _lastRun = WorkoutSyncRunRecord.fromJson(map['lastRun']);
    _ownerEmail = blobOwner;
    if (expected != null) _ownerEmail = expected;
    _warmLoadedUnownedData = _links.isNotEmpty && _ownerEmail == null;
    _warmed = true;
  }

  Future<void> _ensureWarmed() async {
    if (!_warmed) await warmFromDisk();
  }

  /// Ownership enforcement — the sibling-store contract: a store
  /// owned by a different account (or carrying data with no
  /// recorded owner) is wiped as soon as a differing current
  /// account is known; a matching owner keeps everything; no
  /// known account → no drop. Never throws. Returns true when a
  /// populated foreign/unowned store was dropped.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = _normalizeEmail(email);
    if (expected == null) return false;
    await _ensureWarmed();
    final hasData = _links.isNotEmpty;
    if (_ownerEmail == expected) return false;
    if (_ownerEmail == null && !hasData) {
      _ownerEmail = expected;
      return false;
    }
    await clear();
    _ownerEmail = expected;
    return true;
  }

  /// Wipes memory + disk (owner-mismatch drop). Never throws.
  Future<void> clear() async {
    _resetMemory();
    _warmed = true; // memory is authoritative-empty until next write
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  /// Persists the current memory state. Never throws.
  ///
  /// Gated on a completed warm (H1-04 part B / C-01): after a
  /// transient storage read failure the in-memory image may be
  /// an incomplete picture of the disk blob, and writing it
  /// would erase links the failed read never loaded. [clear]
  /// re-arms writes explicitly over an authoritative-empty
  /// memory.
  Future<void> persist() async {
    if (!_warmed) return;
    try {
      await _write(
        storageKey,
        jsonEncode({
          'ownerEmail': _ownerEmail,
          if (_lastSyncMs != null) 'lastSyncMs': _lastSyncMs,
          if (_lastRun != null) 'lastRun': _lastRun!.toJson(),
          'links': {
            for (final e in _links.entries) e.key: e.value.toJson(),
          },
        }),
      );
    } catch (_) {
      // Memory stays; disk just won't have this refresh.
    }
  }

  // ── Mutations ────────────────────────────────────────────────

  /// Records (or replaces) the link for [key] and persists.
  /// Writing a live link over a tombstone is possible only via
  /// [restoreLink]-style restores of a captured prior record —
  /// the sync service never calls this for a key that already
  /// has any link.
  Future<void> recordLink({
    required String key,
    required int entryId,
    required WorkoutLinkState state,
    required WorkoutLinkOrigin origin,
    String? hcId,
  }) async {
    await _ensureWarmed();
    final prior = _links[key];
    if (prior?.entryId != null && prior!.entryId != entryId) {
      _reverse.remove(prior.entryId);
    }
    _links[key] = WorkoutLink(
      state: state,
      entryId: entryId,
      origin: origin,
      hcId: hcId,
    );
    _reverse[entryId] = key;
    await persist();
  }

  /// Tombstones the link for [entryId] (the History delete
  /// hook): the record is reduced to `{state: tombstoned}` only
  /// (decision 4 strip) and the reverse entry is dropped.
  /// Returns the key + PRIOR link so a failed delete can restore
  /// it exactly (via [restoreLink]), or null when the entry was
  /// never linked.
  Future<({String key, WorkoutLink link})?> tombstoneForEntry(
      int entryId) async {
    await _ensureWarmed();
    final key = _reverse[entryId];
    if (key == null) return null;
    final prior = _links[key];
    if (prior == null) return null;
    if (!prior.isTombstoned) {
      _links[key] = const WorkoutLink(state: WorkoutLinkState.tombstoned);
      _reverse.remove(entryId);
      await persist();
    }
    return (key: key, link: prior);
  }

  /// Restores a link captured by [tombstoneForEntry] (a delete
  /// that itself failed and restored the entry restores the link
  /// with it — DESIGN §1.4 failure symmetry).
  Future<void> restoreLink(String key, WorkoutLink prior) async {
    await _ensureWarmed();
    _links[key] = prior;
    final entryId = prior.entryId;
    if (entryId != null) _reverse[entryId] = key;
    await persist();
  }

  /// Records the diagnostics for a finished sync run and
  /// persists (ROUND 3). Counts/codes only — see
  /// [WorkoutSyncRunRecord].
  Future<void> recordRun(WorkoutSyncRunRecord record) async {
    await _ensureWarmed();
    _lastRun = record;
    await persist();
  }

  /// Stamps the last completed sync run and persists.
  Future<void> markSynced(int nowMs) async {
    await _ensureWarmed();
    _lastSyncMs = nowMs;
    await persist();
  }
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
