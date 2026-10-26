import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
/// Blob shape: `{attacks: [...], activeAttackId: int|null}`. The
/// active attack survives app restart; elapsed is always recomputed
/// from the stored start timestamp.
///
/// Never throws: storage failures degrade to "no attacks" on reads,
/// and writes surface as a thrown [StateError] only from [save] so
/// the controller can show Juno's start-failure line (§F).
class MigraineAttackStore {
  static const String storageKey = 'migraine_attacks_v1';

  Future<String?> Function(String key) _read =
      (key) => const FlutterSecureStorage().read(key: key);
  Future<void> Function(String key, String value) _write =
      (key, value) =>
          const FlutterSecureStorage().write(key: key, value: value);
  Future<void> Function(String key) _delete =
      (key) => const FlutterSecureStorage().delete(key: key);

  MigraineAttackStore();

  MigraineAttackStore._(this._read, this._write, this._delete);

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
    final blob = jsonEncode({
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

  /// Test/reset helper: drops the whole blob.
  Future<void> clear() async {
    try {
      await _delete(storageKey);
    } catch (_) {}
  }
}
