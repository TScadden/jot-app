import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// R70 WS1 — the historical health store.
///
/// The founder's standing prescription (Sep 2026): a normalized local
/// health database, fed by Health Connect syncs, so the app can reach
/// ALL-TIME data instead of Health Connect's ~2–4 week retention
/// window.
///
/// The Sep 30, 2026 incident is the design constraint: the native
/// app's caches were truncated to 14 days because writers OVERWROTE
/// instead of merging. This store is therefore MERGE-ONLY, forever:
///
/// - [mergeRefresh] (Health Connect captures): a non-null incoming
///   field overwrites the stored field (HC is the source of truth
///   inside its window); a null/absent incoming field NEVER erases a
///   stored value; the stored date set NEVER shrinks.
/// - [mergeFillGaps] (imports): fills only fields that are currently
///   null; existing stored values always win.
///
/// Founder zero rule, enforced on the way in for BOTH modes (see
/// `health_data.dart`): incoming restingHr / sleep / deep / calories /
/// HRV values ≤ 0 are treated as ABSENT — never stored, never an
/// overwrite. A CSV "0" cell is a failed read, not data. `spikeCount`
/// is the exception: 0 is REAL data there (a sampled day with no
/// spikes) and is stored.
///
/// Persistence mirrors the sibling stores (HeartDataCache /
/// HomeDataCache / CoachMemoryStore): one JSON blob in
/// FlutterSecureStorage (Android Keystore-backed), an in-memory map
/// warmed lazily, `debugSetStore`/`debugReset` test hooks, and
/// account binding by normalized owner email — a snapshot owned by a
/// different account is guarded/dropped exactly as the sibling caches
/// do it; when no account is known, nothing is dropped.

/// One day of biometrics, keyed by [date] ("YYYY-MM-DD",
/// device-local). Immutable; every field nullable (null = no data,
/// never an invented value).
class DailyBiometrics {
  final String date; // "YYYY-MM-DD"

  /// Resting HR (bpm) as produced by `readRestingHrHistory` — the
  /// per-day HR series every reader uses.
  final int? restingHrBpm;

  /// Sleep minutes as produced by `readSleepHistory` (`{date, mins,
  /// deep}`).
  final int? sleepMinutes;
  final int? deepSleepMinutes;

  /// HR spike count as produced by `readSpikeCounts` /
  /// `computeDailyHrSummary`. 0 is REAL data here.
  final int? spikeCount;

  /// Calories (kcal) as produced by `readCaloriesHistory`.
  ///
  /// Definition note (verified against the bridge, MainActivity.kt
  /// `readCaloriesHistory`): the bridge aggregates BOTH
  /// ActiveCaloriesBurned and TotalCaloriesBurned per day and returns
  /// `active ?: total` (0 when both are null, which the zero rule
  /// then treats as absent). So despite the field's historical
  /// "total calories" naming in the brief, the stored value is the
  /// bridge's active-preferred figure — the SAME definition every
  /// other reader (Weekly Snapshot, Key Metrics, reports) uses.
  /// The definition is deliberately NOT changed here.
  final int? caloriesKcal;

  /// HRV RMSSD (ms) — the per-day value from `readHrvRmssd`, the
  /// mechanism the report collector uses today (no range HRV bridge
  /// read exists; the collector issues one read per date).
  final double? hrvRmssdMs;

  // ── R70 Daily Score fields (score engine ONLY) ───────────────
  //
  // Written exclusively by the Daily Score engine through
  // [HealthHistoryStore.persistScore], which is write-once: once
  // [dailyScore] is set it is never recomputed or rewritten, so
  // later baseline drift never rewrites history. Captures and
  // imports NEVER touch these fields: neither merge mode includes
  // them in its field set (the merges carry the EXISTING values
  // through untouched), and [sanitized] strips them from every
  // incoming row, so even a hand-built row carrying scores cannot
  // smuggle them in through a merge. 0 is a legitimate score here
  // — the biometric zero rule does NOT apply to score fields.
  // Which components contributed to a day's score is derived from
  // which of the component fields are non-null.

  /// The day's Daily Score, 0–100 (rounded whole number).
  final int? dailyScore;

  /// Sleep component score, 0–100, or null when the sleep
  /// component did not contribute to [dailyScore].
  final int? scoreSleep;

  /// HRV component score, 0–100, or null when it did not
  /// contribute.
  final int? scoreHrv;

  /// Resting-HR component score, 0–100, or null when it did not
  /// contribute.
  final int? scoreRestingHr;

  const DailyBiometrics({
    required this.date,
    this.restingHrBpm,
    this.sleepMinutes,
    this.deepSleepMinutes,
    this.spikeCount,
    this.caloriesKcal,
    this.hrvRmssdMs,
    this.dailyScore,
    this.scoreSleep,
    this.scoreHrv,
    this.scoreRestingHr,
  });

  bool get hasAnyValue =>
      restingHrBpm != null ||
      sleepMinutes != null ||
      deepSleepMinutes != null ||
      spikeCount != null ||
      caloriesKcal != null ||
      hrvRmssdMs != null ||
      dailyScore != null;

  DailyBiometrics copyWith({
    int? restingHrBpm,
    int? sleepMinutes,
    int? deepSleepMinutes,
    int? spikeCount,
    int? caloriesKcal,
    double? hrvRmssdMs,
  }) =>
      DailyBiometrics(
        date: date,
        restingHrBpm: restingHrBpm ?? this.restingHrBpm,
        sleepMinutes: sleepMinutes ?? this.sleepMinutes,
        deepSleepMinutes: deepSleepMinutes ?? this.deepSleepMinutes,
        spikeCount: spikeCount ?? this.spikeCount,
        caloriesKcal: caloriesKcal ?? this.caloriesKcal,
        hrvRmssdMs: hrvRmssdMs ?? this.hrvRmssdMs,
        dailyScore: dailyScore,
        scoreSleep: scoreSleep,
        scoreHrv: scoreHrv,
        scoreRestingHr: scoreRestingHr,
      );

  /// A copy with the four score fields set EXACTLY as given
  /// (nulls included — a non-contributing component stays null).
  /// Used only by the score engine's write path
  /// ([HealthHistoryStore.persistScore]); the biometric fields are
  /// carried through untouched.
  DailyBiometrics withScores({
    required int? dailyScore,
    required int? scoreSleep,
    required int? scoreHrv,
    required int? scoreRestingHr,
  }) =>
      DailyBiometrics(
        date: date,
        restingHrBpm: restingHrBpm,
        sleepMinutes: sleepMinutes,
        deepSleepMinutes: deepSleepMinutes,
        spikeCount: spikeCount,
        caloriesKcal: caloriesKcal,
        hrvRmssdMs: hrvRmssdMs,
        dailyScore: dailyScore,
        scoreSleep: scoreSleep,
        scoreHrv: scoreHrv,
        scoreRestingHr: scoreRestingHr,
      );

  Map<String, dynamic> toJson() => {
        'date': date,
        if (restingHrBpm != null) 'restingHrBpm': restingHrBpm,
        if (sleepMinutes != null) 'sleepMinutes': sleepMinutes,
        if (deepSleepMinutes != null) 'deepSleepMinutes': deepSleepMinutes,
        if (spikeCount != null) 'spikeCount': spikeCount,
        if (caloriesKcal != null) 'caloriesKcal': caloriesKcal,
        if (hrvRmssdMs != null) 'hrvRmssdMs': hrvRmssdMs,
        if (dailyScore != null) 'dailyScore': dailyScore,
        if (scoreSleep != null) 'scoreSleep': scoreSleep,
        if (scoreHrv != null) 'scoreHrv': scoreHrv,
        if (scoreRestingHr != null) 'scoreRestingHr': scoreRestingHr,
      };

  /// Tolerant parse; applies the zero rule on the way in so a blob
  /// written by any older path can never resurrect a failed read.
  static DailyBiometrics? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final date = raw['date']?.toString();
    if (date == null || date.isEmpty) return null;
    int? asPosInt(dynamic v) {
      final n = v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
      return (n != null && n > 0) ? n : null;
    }

    int? asSpike(dynamic v) {
      final n = v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
      return (n != null && n >= 0) ? n : null;
    }

    double? asPosDouble(dynamic v) {
      final n =
          v is num ? v.toDouble() : (v is String ? double.tryParse(v) : null);
      return (n != null && n > 0) ? n : null;
    }

    // Score fields: NO zero rule (0 is a real score), but bounded
    // to the 0–100 range the engine writes. Blobs written before
    // the Daily Score existed simply lack these keys → null.
    int? asScore(dynamic v) {
      final n = v is num ? v.toInt() : (v is String ? int.tryParse(v) : null);
      return (n != null && n >= 0 && n <= 100) ? n : null;
    }

    return DailyBiometrics(
      date: date,
      restingHrBpm: asPosInt(raw['restingHrBpm']),
      sleepMinutes: asPosInt(raw['sleepMinutes']),
      deepSleepMinutes: asPosInt(raw['deepSleepMinutes']),
      spikeCount: asSpike(raw['spikeCount']),
      caloriesKcal: asPosInt(raw['caloriesKcal']),
      hrvRmssdMs: asPosDouble(raw['hrvRmssdMs']),
      dailyScore: asScore(raw['dailyScore']),
      scoreSleep: asScore(raw['scoreSleep']),
      scoreHrv: asScore(raw['scoreHrv']),
      scoreRestingHr: asScore(raw['scoreRestingHr']),
    );
  }

  /// The zero rule, applied to an incoming row before any merge:
  /// restingHr / sleep / deep / calories / HRV ≤ 0 become absent;
  /// a negative spike count becomes absent (0 stays — it is real).
  ///
  /// The score fields are also STRIPPED here (set to null): this
  /// is the chokepoint every capture/import row passes through, so
  /// no merge can ever write a score — the score engine's
  /// [HealthHistoryStore.persistScore] is the only write path, and
  /// it does not go through [sanitized].
  DailyBiometrics sanitized() => DailyBiometrics(
        date: date,
        restingHrBpm:
            (restingHrBpm != null && restingHrBpm! > 0) ? restingHrBpm : null,
        sleepMinutes:
            (sleepMinutes != null && sleepMinutes! > 0) ? sleepMinutes : null,
        deepSleepMinutes: (deepSleepMinutes != null && deepSleepMinutes! > 0)
            ? deepSleepMinutes
            : null,
        spikeCount: (spikeCount != null && spikeCount! >= 0) ? spikeCount : null,
        caloriesKcal:
            (caloriesKcal != null && caloriesKcal! > 0) ? caloriesKcal : null,
        hrvRmssdMs:
            (hrvRmssdMs != null && hrvRmssdMs! > 0) ? hrvRmssdMs : null,
        // dailyScore / scoreSleep / scoreHrv / scoreRestingHr:
        // deliberately null — see the doc above.
      );

  @override
  bool operator ==(Object other) =>
      other is DailyBiometrics &&
      other.date == date &&
      other.restingHrBpm == restingHrBpm &&
      other.sleepMinutes == sleepMinutes &&
      other.deepSleepMinutes == deepSleepMinutes &&
      other.spikeCount == spikeCount &&
      other.caloriesKcal == caloriesKcal &&
      other.hrvRmssdMs == hrvRmssdMs &&
      other.dailyScore == dailyScore &&
      other.scoreSleep == scoreSleep &&
      other.scoreHrv == scoreHrv &&
      other.scoreRestingHr == scoreRestingHr;

  @override
  int get hashCode => Object.hash(
      date,
      restingHrBpm,
      sleepMinutes,
      deepSleepMinutes,
      spikeCount,
      caloriesKcal,
      hrvRmssdMs,
      dailyScore,
      scoreSleep,
      scoreHrv,
      scoreRestingHr);

  @override
  String toString() => 'DailyBiometrics($date, hr=$restingHrBpm, '
      'sleep=$sleepMinutes, deep=$deepSleepMinutes, spikes=$spikeCount, '
      'kcal=$caloriesKcal, hrv=$hrvRmssdMs)';
}

/// Outcome of one merge call.
class HealthHistoryMergeResult {
  /// Dates that were not in the store before this merge.
  final int daysAdded;

  /// Individual fields written (new-day fields + changed/filled
  /// fields on existing days).
  final int cellsFilled;

  /// Dates touched by the merge (added + updated).
  final int daysTouched;

  const HealthHistoryMergeResult({
    required this.daysAdded,
    required this.cellsFilled,
    required this.daysTouched,
  });

  static const empty =
      HealthHistoryMergeResult(daysAdded: 0, cellsFilled: 0, daysTouched: 0);
}

class HealthHistoryStore {
  static const String storageKey = 'health_history_store_v1';

  static final HealthHistoryStore instance = HealthHistoryStore._internal();
  HealthHistoryStore._internal();

  /// A fresh, non-singleton instance (the TodayPlanStore.testInstance
  /// pattern): tests inject one so seeded history never leaks across
  /// cases through the shared singleton's in-memory map.
  factory HealthHistoryStore.testInstance() => HealthHistoryStore._internal();

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
  void debugReset() => _resetMemory();

  void _resetMemory() {
    _days.clear();
    _ownerEmail = null;
    _lastCaptureMs = null;
    _warmed = false;
  }

  final Map<String, DailyBiometrics> _days = {};
  bool _warmed = false;
  int? _lastCaptureMs;

  /// Epoch ms of the last successful Health Connect capture
  /// (persisted in the blob; drives the capture throttle).
  int? get lastCaptureMs => _lastCaptureMs;

  // ── Account binding (sibling-cache contract) ───────────────────

  String? _ownerEmail;
  String? get ownerEmail => _ownerEmail;

  static String? _normalizeEmail(String? email) {
    final e = email?.trim().toLowerCase();
    return (e == null || e.isEmpty) ? null : e;
  }

  void bindToAccount(String? email) {
    final normalized = _normalizeEmail(email);
    if (normalized != null) _ownerEmail = normalized;
  }

  /// Ownership enforcement — same contract as HomeDataCache /
  /// HeartDataCache: a store owned by a different account (or
  /// carrying data with no recorded owner) is wiped as soon as a
  /// differing current account is known; a matching owner keeps
  /// everything; no known account → no drop. Never throws.
  Future<bool> clearIfOwnerMismatch(String? email) async {
    final expected = _normalizeEmail(email);
    if (expected == null) return false;
    await _ensureWarmed();
    final hasData = _days.isNotEmpty;
    if (_ownerEmail == expected) return false;
    if (_ownerEmail == null && !hasData) {
      _ownerEmail = expected;
      return false;
    }
    await clear();
    _ownerEmail = expected;
    return true;
  }

  /// Wipes memory + disk (logout / account-deletion hook). Never
  /// throws.
  Future<void> clear() async {
    _resetMemory();
    _warmed = true; // memory is authoritative-empty until next write
    try {
      await _delete(storageKey);
    } catch (_) {}
  }

  // ── Warm / persist ─────────────────────────────────────────────

  /// Cold-start warm from the disk blob. Never throws — a missing or
  /// corrupt blob starts empty. When [currentEmail] is known, a blob
  /// owned by a different account (or by no recorded account while
  /// carrying data) is dropped exactly as the sibling caches do it.
  Future<void> warmFromDisk({String? currentEmail}) async {
    if (_warmed) {
      if (currentEmail != null) await clearIfOwnerMismatch(currentEmail);
      return;
    }
    Map<String, dynamic>? map;
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) {
        _warmed = true;
        return;
      }
      map = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      _warmed = true;
      return;
    }
    final expected = _normalizeEmail(currentEmail);
    if (expected != null) {
      final blobOwner = _normalizeEmail(map['ownerEmail']?.toString());
      final daysRaw = map['days'];
      final hasData = daysRaw is Map && daysRaw.isNotEmpty;
      if (blobOwner != expected && (blobOwner != null || hasData)) {
        _resetMemory();
        _warmed = true;
        _ownerEmail = expected;
        try {
          await _delete(storageKey);
        } catch (_) {}
        return;
      }
      if (blobOwner == null && !hasData) _ownerEmail = expected;
    }
    try {
      final daysRaw = map['days'];
      if (daysRaw is Map) {
        for (final entry in daysRaw.entries) {
          final row = DailyBiometrics.fromJson(entry.value);
          if (row != null && row.hasAnyValue) _days[row.date] = row;
        }
      }
      final lc = map['lastCaptureMs'];
      if (lc is num) _lastCaptureMs = lc.toInt();
      final rawOwner = map['ownerEmail'];
      if (rawOwner is String) _ownerEmail = _normalizeEmail(rawOwner);
    } catch (_) {
      // Malformed blob: start empty.
      _days.clear();
    }
    _warmed = true;
  }

  Future<void> _ensureWarmed() async {
    if (!_warmed) await warmFromDisk();
  }

  /// Persists the current memory state. Never throws.
  Future<void> persist() async {
    try {
      final dates = _days.keys.toList()..sort();
      await _write(
        storageKey,
        jsonEncode({
          'ownerEmail': _ownerEmail,
          'lastCaptureMs': _lastCaptureMs,
          'days': {for (final d in dates) d: _days[d]!.toJson()},
        }),
      );
    } catch (_) {
      // Memory stays; disk just won't have this refresh.
    }
  }

  /// Stamps the last-successful-capture time and persists it.
  Future<void> markCaptured(int epochMs) async {
    await _ensureWarmed();
    _lastCaptureMs = epochMs;
    await persist();
  }

  // ── Merges (merge-only, per-field, never-shrink) ───────────────

  /// Health Connect capture merge: a non-null incoming field
  /// overwrites the stored field; a null/absent incoming field
  /// NEVER erases a stored value; the stored date set NEVER
  /// shrinks. The zero rule is applied to incoming rows first.
  Future<HealthHistoryMergeResult> mergeRefresh(
      Iterable<DailyBiometrics> rows) async {
    await _ensureWarmed();
    var daysAdded = 0;
    var cellsFilled = 0;
    var daysTouched = 0;
    for (final raw in rows) {
      final incoming = raw.sanitized();
      if (!incoming.hasAnyValue) continue;
      final existing = _days[incoming.date];
      if (existing == null) {
        _days[incoming.date] = incoming;
        daysAdded++;
        daysTouched++;
        cellsFilled += _fieldCount(incoming);
        continue;
      }
      final merged = DailyBiometrics(
        date: incoming.date,
        restingHrBpm: incoming.restingHrBpm ?? existing.restingHrBpm,
        sleepMinutes: incoming.sleepMinutes ?? existing.sleepMinutes,
        deepSleepMinutes:
            incoming.deepSleepMinutes ?? existing.deepSleepMinutes,
        spikeCount: incoming.spikeCount ?? existing.spikeCount,
        caloriesKcal: incoming.caloriesKcal ?? existing.caloriesKcal,
        hrvRmssdMs: incoming.hrvRmssdMs ?? existing.hrvRmssdMs,
        // Score fields are NOT part of this merge's field set: the
        // existing day's scores are carried through untouched
        // (incoming rows carry none — see [DailyBiometrics.sanitized]).
        dailyScore: existing.dailyScore,
        scoreSleep: existing.scoreSleep,
        scoreHrv: existing.scoreHrv,
        scoreRestingHr: existing.scoreRestingHr,
      );
      final changed = _fieldCountChanged(existing, merged);
      if (changed > 0) {
        _days[incoming.date] = merged;
        cellsFilled += changed;
        daysTouched++;
      }
    }
    if (daysTouched > 0) await persist();
    return HealthHistoryMergeResult(
        daysAdded: daysAdded,
        cellsFilled: cellsFilled,
        daysTouched: daysTouched);
  }

  /// Import merge: fills only fields that are currently null;
  /// existing stored values always win. The zero rule is applied
  /// to incoming rows first (a CSV "0" never fills anything).
  Future<HealthHistoryMergeResult> mergeFillGaps(
      Iterable<DailyBiometrics> rows) async {
    await _ensureWarmed();
    var daysAdded = 0;
    var cellsFilled = 0;
    var daysTouched = 0;
    for (final raw in rows) {
      final incoming = raw.sanitized();
      if (!incoming.hasAnyValue) continue;
      final existing = _days[incoming.date];
      if (existing == null) {
        _days[incoming.date] = incoming;
        daysAdded++;
        daysTouched++;
        cellsFilled += _fieldCount(incoming);
        continue;
      }
      final merged = DailyBiometrics(
        date: incoming.date,
        restingHrBpm: existing.restingHrBpm ?? incoming.restingHrBpm,
        sleepMinutes: existing.sleepMinutes ?? incoming.sleepMinutes,
        deepSleepMinutes:
            existing.deepSleepMinutes ?? incoming.deepSleepMinutes,
        spikeCount: existing.spikeCount ?? incoming.spikeCount,
        caloriesKcal: existing.caloriesKcal ?? incoming.caloriesKcal,
        hrvRmssdMs: existing.hrvRmssdMs ?? incoming.hrvRmssdMs,
        // Score fields are NOT part of this merge's field set: the
        // existing day's scores are carried through untouched
        // (incoming rows carry none — see [DailyBiometrics.sanitized]).
        dailyScore: existing.dailyScore,
        scoreSleep: existing.scoreSleep,
        scoreHrv: existing.scoreHrv,
        scoreRestingHr: existing.scoreRestingHr,
      );
      final changed = _fieldCountChanged(existing, merged);
      if (changed > 0) {
        _days[incoming.date] = merged;
        cellsFilled += changed;
        daysTouched++;
      }
    }
    if (daysTouched > 0) await persist();
    return HealthHistoryMergeResult(
        daysAdded: daysAdded,
        cellsFilled: cellsFilled,
        daysTouched: daysTouched);
  }

  // ── Daily Score write path (score engine ONLY) ─────────────────

  /// Write-once score persistence: sets the four score fields on
  /// the stored day [date] and persists. Returns false — writing
  /// nothing — when the day is not in the store or already holds a
  /// score. A persisted score is NEVER recomputed or rewritten:
  /// later baseline drift must not rewrite history, and a day
  /// computed from a partial component set stays as computed.
  Future<bool> persistScore(
    String date, {
    required int dailyScore,
    int? scoreSleep,
    int? scoreHrv,
    int? scoreRestingHr,
  }) async {
    await _ensureWarmed();
    final existing = _days[date];
    if (existing == null || existing.dailyScore != null) return false;
    _days[date] = existing.withScores(
      dailyScore: dailyScore,
      scoreSleep: scoreSleep,
      scoreHrv: scoreHrv,
      scoreRestingHr: scoreRestingHr,
    );
    await persist();
    return true;
  }

  // NOTE: _fieldCount / _fieldCountChanged deliberately count the
  // six biometric fields ONLY — merges never gain or lose a day
  // because of score fields, and score writes go through
  // [persistScore], never through a merge.
  static int _fieldCount(DailyBiometrics d) =>
      (d.restingHrBpm != null ? 1 : 0) +
      (d.sleepMinutes != null ? 1 : 0) +
      (d.deepSleepMinutes != null ? 1 : 0) +
      (d.spikeCount != null ? 1 : 0) +
      (d.caloriesKcal != null ? 1 : 0) +
      (d.hrvRmssdMs != null ? 1 : 0);

  static int _fieldCountChanged(DailyBiometrics a, DailyBiometrics b) =>
      (a.restingHrBpm != b.restingHrBpm ? 1 : 0) +
      (a.sleepMinutes != b.sleepMinutes ? 1 : 0) +
      (a.deepSleepMinutes != b.deepSleepMinutes ? 1 : 0) +
      (a.spikeCount != b.spikeCount ? 1 : 0) +
      (a.caloriesKcal != b.caloriesKcal ? 1 : 0) +
      (a.hrvRmssdMs != b.hrvRmssdMs ? 1 : 0);

  // ── Query API (WS2 builds against exactly these names) ─────────

  Future<Map<String, DailyBiometrics>> readAll() async {
    await _ensureWarmed();
    final dates = _days.keys.toList()..sort();
    return {for (final d in dates) d: _days[d]!};
  }

  /// Inclusive range read, dates "YYYY-MM-DD" (lexicographic order
  /// is chronological for this format).
  Future<Map<String, DailyBiometrics>> readRange(
      String startDate, String endDate) async {
    await _ensureWarmed();
    final out = <String, DailyBiometrics>{};
    final dates = _days.keys.toList()..sort();
    for (final d in dates) {
      if (d.compareTo(startDate) >= 0 && d.compareTo(endDate) <= 0) {
        out[d] = _days[d]!;
      }
    }
    return out;
  }

  Future<int> dayCount() async {
    await _ensureWarmed();
    return _days.length;
  }

  Future<({String? earliest, String? latest})> coverage() async {
    await _ensureWarmed();
    if (_days.isEmpty) return (earliest: null, latest: null);
    final dates = _days.keys.toList()..sort();
    return (earliest: dates.first, latest: dates.last);
  }
}
