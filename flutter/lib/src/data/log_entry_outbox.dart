import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'quick_log_models.dart';
import 'tabs_backend.dart';

/// Local sync state for one not-yet-confirmed log-entry upsert.
enum LogEntrySyncStatus { pending, failed }

/// One durable pending upsert.
///
/// [serverKnown] distinguishes an edit of a row the server already
/// has from a brand-new row created locally. It matters when the row
/// is deleted before its first push lands: a server-known row still
/// needs the server DELETE, while a local-only row only needs its
/// pending upsert cancelled.
class LogEntryOutboxRecord {
  final QuickLogEntry entry;
  final bool serverKnown;
  final LogEntrySyncStatus status;

  const LogEntryOutboxRecord({
    required this.entry,
    required this.serverKnown,
    this.status = LogEntrySyncStatus.pending,
  });

  LogEntryOutboxRecord copyWith({
    QuickLogEntry? entry,
    bool? serverKnown,
    LogEntrySyncStatus? status,
  }) {
    return LogEntryOutboxRecord(
      entry: entry ?? this.entry,
      serverKnown: serverKnown ?? this.serverKnown,
      status: status ?? this.status,
    );
  }

  Map<String, dynamic> toJson() => {
        'entry': LogEntryOutbox.entryJson(entry),
        'serverKnown': serverKnown,
        'failed': status == LogEntrySyncStatus.failed,
      };

  static LogEntryOutboxRecord? fromJson(Map<String, dynamic> json) {
    final rawEntry = json['entry'];
    if (rawEntry is! Map<String, dynamic>) return null;
    try {
      return LogEntryOutboxRecord(
        entry: QuickLogEntry.fromJson(rawEntry),
        serverKnown: json['serverKnown'] == true,
        status: json['failed'] == true
            ? LogEntrySyncStatus.failed
            : LogEntrySyncStatus.pending,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Durable local-first outbox for Quick Log entry upserts.
///
/// The write order is the integrity contract:
///
/// 1. [stage] replaces the in-memory record and writes the encrypted
///    on-device blob.
/// 2. Only a successful stage may start [flush].
/// 3. [flush] posts through the existing `/api/sync/entries` upsert
///    and removes the record only when the server confirms the exact
///    staged version. If the entry was edited again while the POST
///    was in flight, the newer staged version stays pending.
/// 4. A failed POST leaves the exact entry on disk, marked failed,
///    so an app kill cannot lose it and the next normal sync trigger
///    (Quick Log refresh, History load/revalidation, app resume) can
///    retry the same id.
///
/// Pulls are reconciled with [merge]: a stale server body can never
/// erase or roll back a pending local version merely because the
/// background push has not landed yet.
///
/// Account binding follows the app's cache pattern: the blob carries
/// its owner's normalized email; a known different owner drops the
/// whole outbox rather than rendering or pushing another account's
/// health entries. The data stays in FlutterSecureStorage, the same
/// encrypted-at-rest store used by the session and Quick Log cache.
///
/// The lock's storage rule: mutations are serialized, and inside
/// the lock only result-BEARING persists are awaited (stage, cancel,
/// restore, and the flush bookkeeping must know whether the blob is
/// durable before reporting an outcome). Result-free storage work
/// never parks the queue: the disk READ runs outside the lock (see
/// [_doLoad]) and blob deletes are sent detached and merely tracked
/// (see [_deleteBlobTracked]), because a storage-channel future
/// that cannot complete in the caller's async zone would otherwise
/// deadlock every later mutation behind it. Listeners are notified
/// only after a mutation's persist resolves, so a screen never
/// renders a change that is not yet durable.
class LogEntryOutbox extends ChangeNotifier {
  static const String storageKey = 'log_entry_outbox_v1';

  static final LogEntryOutbox instance = LogEntryOutbox._internal();
  LogEntryOutbox._internal();

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
  void debugReset() {
    _records.clear();
    _serverConfirmedIds.clear();
    _inFlightIds.clear();
    _deletingIds.clear();
    _ownerEmail = null;
    _loaded = false;
    _loadFuture = null;
    _flushFuture = null;
  }

  final Map<int, LogEntryOutboxRecord> _records = {};
  final Set<int> _inFlightIds = {};
  final Set<int> _deletingIds = {};
  final Set<int> _serverConfirmedIds = {};
  Future<void>? _deleteInFlight;
  String? _ownerEmail;
  int _epoch = 0;
  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<bool>? _flushFuture;

  String? get ownerEmail => _ownerEmail;

  List<LogEntryOutboxRecord> get records {
    final out = _records.values.toList();
    out.sort((a, b) => b.entry.timestamp.compareTo(a.entry.timestamp));
    return List.unmodifiable(out);
  }

  List<QuickLogEntry> get entries => [for (final r in records) r.entry];

  Set<int> get pendingIds => {
        for (final r in _records.values)
          if (r.status == LogEntrySyncStatus.pending) r.entry.id,
      };

  Set<int> get failedIds => {
        for (final r in _records.values)
          if (r.status == LogEntrySyncStatus.failed) r.entry.id,
      };

  bool get hasPending => _records.isNotEmpty;

  int get maxId {
    var out = 0;
    for (final id in _records.keys) {
      if (id > out) out = id;
    }
    return out;
  }

  LogEntryOutboxRecord? recordFor(int id) => _records[id];

  LogEntrySyncStatus? statusFor(int id) => _records[id]?.status;

  /// Whether the disk blob has been loaded in this process. Until
  /// it has, [statusFor] cannot see records staged by a previous
  /// session, so callers must treat a null status as UNKNOWN, never
  /// as confirmed (the History badge does exactly this).
  bool get isLoaded => _loaded;

  /// Ids whose upsert POST is on the wire right now.
  Set<int> get inFlightIds => Set.unmodifiable(_inFlightIds);

  /// Whether the server is known to hold this entry: either a
  /// queued record says so, or a push this session confirmed it
  /// (the record left the queue, but the fact must not be forgotten
  /// before the next pull lands — a delete in that window still
  /// owes the server a DELETE).
  bool isServerKnown(int id) =>
      _records[id]?.serverKnown == true ||
      _serverConfirmedIds.contains(id);

  /// Marks a row as being deleted: flush runs skip marked ids, so
  /// a push that starts while a delete is being resolved cannot
  /// carry the row. Callers (History's delete) mark before joining
  /// the in-flight push and unmark when the delete resolves.
  void markDeleting(int id) => _deletingIds.add(id);

  void unmarkDeleting(int id) => _deletingIds.remove(id);

  /// Joins the currently running push, if any. A delete that may
  /// race a push carrying the same row awaits this first: once the
  /// push settles, the row's server-side existence is known (the
  /// record was either confirmed and removed, or is back in the
  /// queue as failed), and the delete can classify it correctly.
  Future<void> settleInFlightPush() async {
    final inFlight = _flushFuture;
    if (inFlight == null) return;
    try {
      await inFlight;
    } catch (_) {}
  }

  bool isPending(int id) => _records.containsKey(id);

  static String? normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  static Map<String, dynamic> entryJson(QuickLogEntry e) => {
        'id': e.id,
        'categoryId': e.categoryId,
        'body': e.body,
        'chips': e.chips,
        'manualText': e.manualText,
        'timestamp': e.timestamp,
      };

  /// Serializes mutations through a completer queue — deliberately
  /// NOT a chained tail future. A `.then` chained onto a future born
  /// in another async zone is scheduled in THAT zone's microtask
  /// queue; when the singleton is first touched from test setUp (or
  /// any fire-and-forget call site) and later awaited from a
  /// different zone (a widget-test body, a runAsync block), the
  /// chained callback can starve indefinitely. A completer's
  /// listeners, by contrast, always run in the zone that registered
  /// them, so this lock advances in whichever zone is actually
  /// executing. Fairness is one-deep wake-up; the store's operations
  /// are individually version-checked (flush removals, load's epoch
  /// guard), so a woken waiter racing a new arrival cannot corrupt
  /// state.
  bool _lockBusy = false;
  final List<Completer<void>> _lockWaiters = [];

  Future<T> _runLocked<T>(Future<T> Function() operation) async {
    while (_lockBusy) {
      final waiter = Completer<void>();
      _lockWaiters.add(waiter);
      await waiter.future;
    }
    _lockBusy = true;
    try {
      return await operation();
    } finally {
      _lockBusy = false;
      // Every completed mutation advances the epoch; the disk
      // load's apply step uses it to spot a read that raced a
      // mutation (see _doLoad).
      _epoch++;
      if (_lockWaiters.isNotEmpty) {
        _lockWaiters.removeAt(0).complete();
      }
    }
  }

  /// Loads the disk blob if this process has not done so yet.
  Future<void> load({String? ownerEmail}) {
    if (_loaded) return _enforceLoadedOwner(ownerEmail);
    final existing = _loadFuture;
    if (existing != null) return existing;
    late final Future<void> future;
    future = _doLoad(ownerEmail).whenComplete(() {
      if (identical(_loadFuture, future)) _loadFuture = null;
    });
    _loadFuture = future;
    return future;
  }

  /// The disk read runs OUTSIDE the serialization lock: a storage
  /// future that never answers (a wedged platform channel — or, in
  /// widget tests, an unmocked one, whose futures cannot complete
  /// in the fake-async zone) must not park the queue and deadlock
  /// every later stage, flush, and clear behind it. The apply step
  /// is a short locked section, epoch-guarded: if a mutation landed
  /// while the read was in flight, the blob may predate that
  /// mutation's persist, so it is re-read rather than applied over
  /// newer in-memory state.
  Future<void> _doLoad(String? ownerEmail) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final epochAtRead = _epoch;
      Map<String, dynamic>? map;
      try {
        final raw = await _read(storageKey);
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) map = decoded;
        }
      } catch (_) {
        map = null;
      }
      var settled = false;
      var needsDelete = false;
      await _runLocked(() async {
        if (_loaded) {
          settled = true;
          return;
        }
        if (attempt < 2 && _epoch != epochAtRead) {
          return; // stale read — loop and re-read
        }
        needsDelete = _applyLoadedBlobLocked(map, currentEmail: ownerEmail);
        settled = true;
      });
      if (!settled) continue;
      if (needsDelete) {
        await _deleteBlobTracked();
      }
      return;
    }
  }

  /// Applies a parsed disk blob to the in-memory state (called
  /// inside the serialization lock). Records fill only IDs not
  /// already held — a row staged this session is always at least as
  /// new as the blob's copy. A blob owned by a DIFFERENT account
  /// than [currentEmail] (or an unowned blob carrying rows) is
  /// dropped instead of leaking into this account: its records are
  /// not adopted, and the caller deletes the blob. Returns true
  /// when the blob must be deleted.
  bool _applyLoadedBlobLocked(
    Map<String, dynamic>? map, {
    String? currentEmail,
  }) {
    final expected = normalizeEmail(currentEmail);
    String? blobOwner;
    final blobRecords = <LogEntryOutboxRecord>[];
    if (map != null) {
      blobOwner = normalizeEmail(map['ownerEmail']?.toString());
      final rawRecords = map['records'];
      if (rawRecords is List) {
        for (final raw in rawRecords) {
          if (raw is Map<String, dynamic>) {
            final record = LogEntryOutboxRecord.fromJson(raw);
            if (record != null) blobRecords.add(record);
          }
        }
      }
    }
    var needsDelete = false;
    if (expected != null && blobOwner != expected && blobRecords.isNotEmpty) {
      // Foreign (or unowned) rows on disk: never adopt them into
      // this account. Session-staged rows, if any, stay; the blob
      // is deleted and the next persist rewrites it from memory.
      _ownerEmail = expected;
      needsDelete = true;
    } else {
      for (final record in blobRecords) {
        _records.putIfAbsent(record.entry.id, () => record);
      }
      _ownerEmail ??= blobOwner;
      if (expected != null && _ownerEmail != expected) {
        if (_ownerEmail == null && _records.isEmpty) {
          _ownerEmail = expected;
        } else if (blobOwner == null || _ownerEmail == blobOwner) {
          // Rows just filled came from an unowned or foreign blob
          // that slipped the guard above (empty-blob edge): drop
          // them rather than leak.
          _records.clear();
          _serverConfirmedIds.clear();
          _ownerEmail = expected;
          needsDelete = true;
        }
      }
    }
    _loaded = true;
    notifyListeners();
    return needsDelete;
  }

  Future<void> warmFromDisk({String? currentEmail}) =>
      load(ownerEmail: currentEmail);

  Future<void> _enforceLoadedOwner(String? ownerEmail) async {
    final expected = normalizeEmail(ownerEmail);
    if (expected == null) return;
    await _runLocked(() async {
      if (_ownerEmail == expected) return;
      if (_ownerEmail == null && _records.isEmpty) {
        _ownerEmail = expected;
        return;
      }
      // A known account must never inherit an unowned or differently
      // owned health-entry queue.
      _records.clear();
      _serverConfirmedIds.clear();
      _ownerEmail = expected;
      _loaded = true;
      notifyListeners();
      // Result-free blob delete, outside the lock (see clear()):
      // scheduled, not awaited, so this operation stays storage-free.
      _deleteBlobTracked();
    });
  }

  Future<bool> _persistLocked() async {
    try {
      // A blob delete sent earlier (account clear / owner drop)
      // must land before this write, or the delete could erase the
      // blob this write is about to create. Deletes are enqueued on
      // the same channel in send order; awaiting the in-flight one
      // here makes that ordering structural rather than assumed.
      final pendingDelete = _deleteInFlight;
      if (pendingDelete != null) await pendingDelete;
      await _write(storageKey, jsonEncode(_toJson()));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Sends the blob delete WITHOUT parking the serialization lock
  /// on it (deletes are result-free), and tracks it so the next
  /// persist can order itself after it (see [_persistLocked]).
  Future<void> _deleteBlobTracked() {
    final future = _delete(storageKey).catchError((_) {});
    _deleteInFlight = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_deleteInFlight, future)) _deleteInFlight = null;
      }),
    );
    return future;
  }

  Map<String, dynamic> _toJson() => {
        'ownerEmail': _ownerEmail,
        'records': records.map((r) => r.toJson()).toList(),
      };

  /// Durably stages [entry] locally. Returns false when the local
  /// write itself failed; in that case the previous in-memory queue
  /// is restored and callers must not pretend the change was saved.
  Future<bool> stage(
    QuickLogEntry entry, {
    required bool serverKnown,
    String? ownerEmail,
  }) async {
    await load(ownerEmail: ownerEmail);
    final ok = await _runLocked(() async {
      final previous = Map<int, LogEntryOutboxRecord>.from(_records);
      final existing = _records[entry.id];
      _records[entry.id] = LogEntryOutboxRecord(
        entry: entry,
        // A queued row's nature can only ever upgrade, never revoke:
        // once any push confirms the row server-side — including a
        // superseded version's push (see _removeIfCurrent) — it
        // stays server-known, even if the caller, working from a
        // not-yet-revalidated pull, says otherwise. A local-only
        // creation stays a creation until such a confirmation.
        serverKnown: (existing?.serverKnown ?? false) ||
            serverKnown ||
            _serverConfirmedIds.contains(entry.id),
        status: LogEntrySyncStatus.pending,
      );
      if (await _persistLocked()) return true;
      _records
        ..clear()
        ..addAll(previous);
      return false;
    });
    // Notify AFTER the persist resolves, never before: listeners
    // (the Quick Log and History screens) merge on notify, and a
    // screen must never display a change that is not yet durable —
    // a kill in that window would lose a change the UI had already
    // presented as saved. The caller's own post-stage setState is
    // separately gated on this return value.
    notifyListeners();
    return ok;
  }

  /// Convenience wrapper for screens, which already hold the backend
  /// that owns the current session store.
  Future<bool> stageForBackend(
    QuickLogEntry entry, {
    required TabsBackend backend,
    required bool serverKnown,
  }) async {
    String? email;
    try {
      email = await backend.readEmail();
    } catch (_) {
      email = null;
    }
    return stage(entry, serverKnown: serverKnown, ownerEmail: email);
  }

  /// Removes a pending upsert and persists the removal. Returns the
  /// removed record, or null when it was absent or the local write
  /// failed (in which case the record is restored).
  Future<LogEntryOutboxRecord?> cancel(int id) async {
    await load();
    final result = await _runLocked(() async {
      final removed = _records.remove(id);
      if (removed == null) return null;
      if (await _persistLocked()) return removed;
      _records[id] = removed;
      return null;
    });
    // Notify after the persist resolves (see stage).
    notifyListeners();
    return result;
  }

  /// Restores a previously cancelled record exactly (used when a
  /// delete that cancelled a pending edit itself fails).
  Future<bool> restore(LogEntryOutboxRecord record) async {
    await load();
    final ok = await _runLocked(() async {
      final previous = _records[record.entry.id];
      _records[record.entry.id] = record;
      if (await _persistLocked()) return true;
      if (previous == null) {
        _records.remove(record.entry.id);
      } else {
        _records[record.entry.id] = previous;
      }
      return false;
    });
    // Notify after the persist resolves (see stage).
    notifyListeners();
    return ok;
  }

  /// Pushes every pending/failed record through the existing entry
  /// upsert. Single-flight: concurrent sync triggers join the same
  /// run. A record is removed only when the POST confirms the exact
  /// version that was sent; a newer edit staged mid-flight stays
  /// queued. Failures are persisted as failed and remain visible.
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
    String? email;
    try {
      email = await backend.readEmail();
    } catch (_) {
      email = null;
    }
    await load(ownerEmail: email);
    final attemptedVersions = <String>{};

    while (true) {
      LogEntryOutboxRecord? next;
      for (final record in _records.values) {
        // A row whose delete is being resolved is never carried by
        // a push that starts now (see markDeleting).
        if (_deletingIds.contains(record.entry.id)) continue;
        final version = _versionKey(record);
        if (!attemptedVersions.contains(version)) {
          next = record;
          break;
        }
      }
      if (next == null) break;
      attemptedVersions.add(_versionKey(next));

      // A retry visibly returns the row to pending while the attempt
      // is in flight; it is only marked failed if this exact version
      // is still current when the result lands.
      if (next.status == LogEntrySyncStatus.failed) {
        await _setStatusIfCurrent(next, LogEntrySyncStatus.pending);
      }

      var ok = false;
      _inFlightIds.add(next.entry.id);
      try {
        ok = await backend.postLogEntries([next.entry]);
      } catch (_) {
        ok = false;
      } finally {
        _inFlightIds.remove(next.entry.id);
      }
      if (ok) {
        // The cached sync pull predates this upsert; the next pull
        // must not resurrect the pre-push snapshot.
        backend.invalidateSyncPull();
      }
      if (ok) {
        await _removeIfCurrent(next);
      } else {
        await _setStatusIfCurrent(next, LogEntrySyncStatus.failed);
      }
    }
    return _records.isEmpty;
  }

  String _versionKey(LogEntryOutboxRecord record) =>
      '${record.entry.id}:${jsonEncode(entryJson(record.entry))}:${record.serverKnown}';

  Future<void> _setStatusIfCurrent(
    LogEntryOutboxRecord attempted,
    LogEntrySyncStatus status,
  ) async {
    await _runLocked(() async {
      final current = _records[attempted.entry.id];
      if (current == null || _versionKey(current) != _versionKey(attempted)) {
        return;
      }
      final previous = current;
      _records[current.entry.id] = current.copyWith(status: status);
      if (!await _persistLocked()) {
        _records[current.entry.id] = previous;
        // Converge the disk to the restored in-memory state, so a
        // reload cannot resurrect the intermediate status.
        await _persistLocked();
      }
    });
    // Listeners are notified only after the persist resolves (see
    // stage): a screen must never render a state that is not yet
    // durable.
    notifyListeners();
  }

  Future<void> _removeIfCurrent(LogEntryOutboxRecord attempted) async {
    await _runLocked(() async {
      // The POST for [attempted] succeeded, so the server now holds
      // this row NO MATTER what the queue holds: record the
      // confirmation BEFORE the version check, never after it. A
      // newer version staged while the POST was in flight keeps its
      // queue slot (it still needs its own push), but its
      // classification upgrades below — the row exists server-side,
      // so a later delete must issue the server DELETE and a later
      // edit is an edit, not a create (Vera round-2 closure).
      _serverConfirmedIds.add(attempted.entry.id);
      final current = _records[attempted.entry.id];
      if (current == null) return;
      if (_versionKey(current) != _versionKey(attempted)) {
        if (!current.serverKnown) {
          _records[attempted.entry.id] =
              current.copyWith(serverKnown: true);
          // Best effort: the session set above already carries the
          // fact even if this persist fails.
          await _persistLocked();
        }
        return;
      }
      _records.remove(attempted.entry.id);
      if (!await _persistLocked()) {
        // The queue removal did not persist, but the push DID land:
        // the restored record carries the upgraded classification
        // so a reload cannot re-classify the row as local-only.
        _records[attempted.entry.id] =
            attempted.copyWith(serverKnown: true);
        // Converge the disk to the restored in-memory state.
        await _persistLocked();
      }
    });
    notifyListeners();
  }

  /// Overlays pending local versions over a server pull. The result
  /// is timestamp-descending, matching the History/Quick Log lists.
  List<QuickLogEntry> merge(List<QuickLogEntry> serverEntries) {
    if (_records.isEmpty) {
      final out = serverEntries.toList();
      out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      return out;
    }
    final byId = <int, QuickLogEntry>{};
    for (final entry in serverEntries) {
      byId[entry.id] = entry;
    }
    for (final record in _records.values) {
      byId[record.entry.id] = record.entry;
    }
    final out = byId.values.toList();
    out.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return out;
  }

  Future<void> clear() async {
    await _runLocked(() async {
      _records.clear();
      _serverConfirmedIds.clear();
      _ownerEmail = null;
      _loaded = true;
      notifyListeners();
    });
    // The blob delete runs OUTSIDE the lock. The lock's storage
    // rule (see the class doc): result-free operations — disk
    // reads and blob deletes — never park the queue, because a
    // channel future that cannot complete in the caller's async
    // zone would deadlock every later mutation behind them.
    // Result-BEARING persists are the deliberate exception: stage
    // and friends await their write inside the lock because the
    // caller must not be told "saved" before the blob is durable.
    // The delete is tracked so the next persist orders after it.
    _deleteBlobTracked();
  }

  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = normalizeEmail(email);
    if (expected == null) return false;
    await load();
    var dropped = false;
    await _runLocked(() async {
      if (_ownerEmail == expected) return;
      if (_ownerEmail == null && _records.isEmpty) {
        _ownerEmail = expected;
        return;
      }
      _records.clear();
      _serverConfirmedIds.clear();
      _ownerEmail = expected;
      _loaded = true;
      dropped = true;
      notifyListeners();
    });
    if (dropped) {
      // Result-free blob delete, outside the lock (see clear()).
      _deleteBlobTracked();
    }
    return dropped;
  }
}
