import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'coach_memory_store.dart';

/// One migraine attack record — the Lab `MigraineAttack` fields,
/// ported to production's local-store shape.
///
/// LOCAL-ONLY (Juno condition 4): attack records are stored on device
/// and are NEVER synced. There is deliberately no sync flag and no
/// sync path for attack records in this port — carrying one over
/// would void Juno §G(1) and require a new review. The companion
/// Trends entry (see `migraine_trends.dart`) is the only synced
/// artifact, and it rides the existing entries sync.
class MigraineAttack {
  /// Local id: the attack's start timestamp in epoch ms, assigned at
  /// start. Unique because only one attack can be active at a time
  /// and starts are strictly ordered.
  final int id;
  final int startTimestamp;

  /// Null while the attack is running.
  final int? endTimestamp;

  /// Uppercase Lab values: NONE / VISUAL / SENSORY / SPEECH / MOTOR.
  final String auraPhase;
  final String medsTaken;

  /// 0 = unset (never a real rating — the founder's zero-value rule;
  /// Juno §E renders unset as "Peak pain not logged.").
  final int painPeak;

  /// 0 = unset (Juno §E renders unset as "Relief not rated.").
  final int reliefRating;

  /// 0.0 = not captured (never a real reading).
  final double pressureAtStartHpa;
  final int updatedAt;

  /// The Trends (Quick Log) entry id for this attack, generated ONCE
  /// when the attack first ends and reused for the details-form
  /// update — exactly one Trends entry per attack (Juno condition 3).
  final int? trendsEntryId;

  /// True when the end-time Trends entry write has not yet landed
  /// (e.g. the end happened offline). Retried on app start and on
  /// details-form save; the entry must land exactly once (the write
  /// upserts on the persisted [trendsEntryId]).
  final bool trendsEntryPending;

  const MigraineAttack({
    required this.id,
    required this.startTimestamp,
    this.endTimestamp,
    this.auraPhase = 'NONE',
    this.medsTaken = '',
    this.painPeak = 0,
    this.reliefRating = 0,
    this.pressureAtStartHpa = 0.0,
    required this.updatedAt,
    this.trendsEntryId,
    this.trendsEntryPending = false,
  });

  bool get isActive => endTimestamp == null;

  /// Elapsed whole minutes at [nowMs] (or at the end, when ended).
  /// Always derived from timestamps — never accumulated ticks.
  int elapsedMinutes(int nowMs) {
    final end = endTimestamp ?? nowMs;
    final mins = (end - startTimestamp) ~/ 60000;
    return mins < 0 ? 0 : mins;
  }

  MigraineAttack copyWith({
    int? endTimestamp,
    bool clearEndTimestamp = false,
    String? auraPhase,
    String? medsTaken,
    int? painPeak,
    int? reliefRating,
    double? pressureAtStartHpa,
    int? updatedAt,
    int? trendsEntryId,
    bool? trendsEntryPending,
  }) {
    return MigraineAttack(
      id: id,
      startTimestamp: startTimestamp,
      endTimestamp:
          clearEndTimestamp ? null : (endTimestamp ?? this.endTimestamp),
      auraPhase: auraPhase ?? this.auraPhase,
      medsTaken: medsTaken ?? this.medsTaken,
      painPeak: painPeak ?? this.painPeak,
      reliefRating: reliefRating ?? this.reliefRating,
      pressureAtStartHpa: pressureAtStartHpa ?? this.pressureAtStartHpa,
      updatedAt: updatedAt ?? this.updatedAt,
      trendsEntryId: trendsEntryId ?? this.trendsEntryId,
      trendsEntryPending: trendsEntryPending ?? this.trendsEntryPending,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'startTimestamp': startTimestamp,
        'endTimestamp': endTimestamp,
        'auraPhase': auraPhase,
        'medsTaken': medsTaken,
        'painPeak': painPeak,
        'reliefRating': reliefRating,
        'pressureAtStartHpa': pressureAtStartHpa,
        'updatedAt': updatedAt,
        'trendsEntryId': trendsEntryId,
        'trendsEntryPending': trendsEntryPending,
      };

  static MigraineAttack? fromJson(Map<String, dynamic> j) {
    try {
      int asInt(dynamic v) => v is num ? v.toInt() : int.tryParse('$v') ?? 0;
      int? asIntOrNull(dynamic v) =>
          v == null ? null : (v is num ? v.toInt() : int.tryParse('$v'));
      final id = asInt(j['id']);
      final start = asInt(j['startTimestamp']);
      if (id == 0 || start == 0) return null;
      return MigraineAttack(
        id: id,
        startTimestamp: start,
        endTimestamp: asIntOrNull(j['endTimestamp']),
        auraPhase: '${j['auraPhase'] ?? 'NONE'}',
        medsTaken: '${j['medsTaken'] ?? ''}',
        painPeak: asInt(j['painPeak']),
        reliefRating: asInt(j['reliefRating']),
        pressureAtStartHpa: (j['pressureAtStartHpa'] as num?)?.toDouble() ??
            double.tryParse('${j['pressureAtStartHpa'] ?? ''}') ??
            0.0,
        updatedAt: asInt(j['updatedAt']),
        trendsEntryId: asIntOrNull(j['trendsEntryId']),
        trendsEntryPending: j['trendsEntryPending'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Local-only store for migraine attack records, following the
/// production store pattern (one JSON blob in flutter_secure_storage
/// — Android Keystore-backed EncryptedSharedPreferences, the same
/// store as [TodayPlanStore] / [OnboardingStore] — with injectable
/// read/write/delete for tests).
///
/// Blob shape: `{ownerEmail: String|null, attacks: [...],
/// activeAttackId: int|null}`. The active attack survives app
/// restart; elapsed is always recomputed from the stored start
/// timestamp.
///
/// Audit 4e (Oct 27, 2026): the blob is account-bound, mirroring
/// [CoachMemoryStore] — it carries its owner's normalized email,
/// logout / account deletion / session expiry clear it, and a
/// login by a different owner wipes it instead of serving the
/// previous account's records. An in-progress attack is the
/// departing owner's data and wipes with the rest.
///
/// Never throws on reads / clears: storage failures degrade to
/// "no attacks" on reads, and writes surface as a thrown
/// [StateError] only from [save] so the controller can show
/// Juno's start-failure line (§F).
class MigraineAttackStore {
  static const String storageKey = 'migraine_attacks_v1';

  /// The one shared instance lifecycle code and the controller act
  /// on (coach-style): [MigraineAttackStore.new] returns this, so
  /// the controller's default store and the wipe paths in
  /// `AccountActions` / `main.dart` share the same bound owner and
  /// the same storage IO (including test-injected IO).
  static final MigraineAttackStore instance =
      MigraineAttackStore._internal();

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  /// The account this instance is bound to (normalized), set by
  /// [clearIfOwnerMismatch]. Writes stamp it; a load whose blob
  /// carries a different stamp is wiped instead of served. Null
  /// while unbound (no login has bound this instance yet).
  String? _boundOwner;

  /// The shared instance (see [instance]).
  factory MigraineAttackStore() => instance;

  MigraineAttackStore._internal();

  MigraineAttackStore._(this._read, this._write, this._delete);

  static String? _normalizeEmail(String? email) =>
      CoachMemoryStore.normalizeEmail(email);

  @visibleForTesting
  factory MigraineAttackStore.withStorage({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
    Future<void> Function(String key)? delete,
  }) =>
      MigraineAttackStore._(
        read,
        write,
        delete ??
            (key) async {
              await write(key, '');
            },
      );

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

  Future<({List<MigraineAttack> attacks, int? activeId})> _loadBlob() async {
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) {
        return (attacks: <MigraineAttack>[], activeId: null);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return (attacks: <MigraineAttack>[], activeId: null);
      }
      // Load enforcement (audit 4e): a stamped blob served to a
      // differently-bound instance is another account's data —
      // wipe the key and serve empty. When unbound, serve: the
      // stamp's owner is the only account whose session could
      // have written it, and every path into a different account
      // binds first (login/register owner-mismatch, or a wipe).
      final stamp = _normalizeEmail(decoded['ownerEmail']?.toString());
      if (stamp != null &&
          _boundOwner != null &&
          stamp != _boundOwner) {
        try {
          await _delete(storageKey);
        } catch (_) {}
        return (attacks: <MigraineAttack>[], activeId: null);
      }
      final attacks = <MigraineAttack>[];
      final rawList = decoded['attacks'];
      if (rawList is List) {
        for (final row in rawList) {
          if (row is Map<String, dynamic>) {
            final a = MigraineAttack.fromJson(row);
            if (a != null) attacks.add(a);
          }
        }
      }
      final activeRaw = decoded['activeAttackId'];
      final activeId =
          activeRaw is num ? activeRaw.toInt() : int.tryParse('$activeRaw');
      return (attacks: attacks, activeId: activeId);
    } catch (_) {
      return (attacks: <MigraineAttack>[], activeId: null);
    }
  }

  Future<void> _writeBlob(List<MigraineAttack> attacks, int? activeId) async {
    // Owner stamp (audit 4e): the bound owner when known; when
    // unbound, preserve any existing stamp — a write must never
    // erase the stamp that binds the blob to its account.
    var stamp = _boundOwner;
    if (stamp == null) {
      try {
        final raw = await _read(storageKey);
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) {
            stamp = _normalizeEmail(decoded['ownerEmail']?.toString());
          }
        }
      } catch (_) {}
    }
    final blob = jsonEncode({
      'ownerEmail': stamp,
      'attacks': attacks.map((a) => a.toJson()).toList(),
      'activeAttackId': activeId,
    });
    await _write(storageKey, blob);
  }

  /// All attacks, newest first.
  Future<List<MigraineAttack>> loadAll() async {
    final blob = await _loadBlob();
    final list = blob.attacks.toList()
      ..sort((a, b) => b.startTimestamp.compareTo(a.startTimestamp));
    return list;
  }

  /// The running attack, if any: the blob's active id when it still
  /// names a running attack, otherwise the newest running row (Lab
  /// `getActiveAttack` fallback semantics).
  Future<MigraineAttack?> loadActive() async {
    final blob = await _loadBlob();
    if (blob.activeId != null) {
      for (final a in blob.attacks) {
        if (a.id == blob.activeId && a.isActive) return a;
      }
    }
    MigraineAttack? latest;
    for (final a in blob.attacks) {
      if (a.isActive &&
          (latest == null || a.startTimestamp > latest.startTimestamp)) {
        latest = a;
      }
    }
    return latest;
  }

  Future<MigraineAttack?> loadById(int id) async {
    final blob = await _loadBlob();
    for (final a in blob.attacks) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// Upserts [attack] and moves the active pointer: a running attack
  /// becomes the active one; an ended attack clears the pointer when
  /// it names this attack.
  Future<void> save(MigraineAttack attack) async {
    final blob = await _loadBlob();
    final attacks = blob.attacks.toList();
    final idx = attacks.indexWhere((a) => a.id == attack.id);
    if (idx >= 0) {
      attacks[idx] = attack;
    } else {
      attacks.add(attack);
    }
    var activeId = blob.activeId;
    if (attack.isActive) {
      activeId = attack.id;
    } else if (activeId == attack.id) {
      activeId = null;
    }
    await _writeBlob(attacks, activeId);
  }

  /// Drops the whole blob and unbinds the owner. Called on
  /// logout / account deletion (via `AccountActions`) and on
  /// session expiry (via `main.dart`), exactly like the other
  /// account-bound stores. Never throws.
  Future<void> clear() async {
    _boundOwner = null;
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  /// Login/register ownership enforcement, mirroring
  /// [CoachMemoryStore.clearIfOwnerMismatch]: binds this instance
  /// to [email] and wipes the blob when it is stamped for a
  /// different account — or carries no stamp at all (coach
  /// semantics: no recorded account → wipe; unstamped legacy
  /// blobs predate audit 4e). Returns true when a wipe happened.
  /// A null/blank [email] binds nothing and wipes nothing.
  /// Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = _normalizeEmail(email);
    if (expected == null) return false;
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) {
        _boundOwner = expected;
        return false;
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        await clear();
        _boundOwner = expected;
        return true;
      }
      final owner = _normalizeEmail(decoded['ownerEmail']?.toString());
      if (owner == expected) {
        _boundOwner = expected;
        return false;
      }
      await clear();
      _boundOwner = expected;
      return true;
    } catch (_) {
      return false;
    }
  }
}
