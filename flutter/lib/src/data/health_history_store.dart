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

  /// HRV RMSSD (ms) — the per-day value. Since R71 the store's
  /// writers (capture + the WS2 union) fill it from the bridge
  /// range read `readHrvSamples` with Dart-side day attribution
  /// (see `attributeDailyHrv`); screen-level readers may still use
  /// the per-day `readHrvRmssd`.
  final double? hrvRmssdMs;

  // ── R70 Daily Score fields (score write paths ONLY) ──────────
  //
  // Written exclusively through the store's two score write paths:
  // [HealthHistoryStore.persistScore] (the engine's write-once
  // first scoring) and [HealthHistoryStore.replaceScore] (the
  // founder-directed, user-initiated refresh — the ONLY path that
  // may ever rewrite a score, and only on an explicit tap; see
  // replaceScore's doc). Automatic behavior stays write-once:
  // once [dailyScore] is set no capture, import, or engine run
  // recomputes or rewrites it, so later baseline drift never
  // rewrites history. Captures and imports NEVER touch these
  // fields: neither merge mode includes them in its field set
  // (the merges carry the EXISTING values through untouched), and
  // [sanitized] strips them from every incoming row, so even a
  // hand-built row carrying scores cannot smuggle them in through
  // a merge. 0 is a legitimate score here — the biometric zero
  // rule does NOT apply to score fields. Which components
  // contributed to a day's score is derived from which of the
  // component fields are non-null.

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
  /// Used only by the store's two score write paths
  /// ([HealthHistoryStore.persistScore] and
  /// [HealthHistoryStore.replaceScore]); the biometric fields are
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
  /// no merge can ever write a score — scores are written only by
  /// [HealthHistoryStore.persistScore] and
  /// [HealthHistoryStore.replaceScore], and neither goes through
  /// [sanitized].
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

/// One metric's last capture outcome, recorded by
/// [HealthHistoryStore.recordCaptureDiagnostics] (HRV capture
/// visibility fix). Contents are operational metadata only — the
/// bridge error CODE (never health values, never exception text;
/// Juno J1 rule), the partial-read code when some chunks failed,
/// and outcome COUNTS — plus when the capture ran.
///
/// A failure entry exists for any metric whose last capture read
/// failed; a metric's entry is cleared by its next successful
/// read. The HRV leg is the exception (Defect 1b): its entry is
/// written on EVERY capture, success included, carrying the raw
/// sample count returned by the bridge and the number of days
/// those samples attributed to — so a recurrence is diagnosable
/// from the record (and the Connected Apps diagnostics line)
/// instead of another code excavation.
class CaptureDiagnostic {
  /// Bridge error code of a FAILED read; null when the read
  /// returned (fully or partially).
  final String? errorCode;

  /// Partial-read code (`HRV_SAMPLES_PARTIAL`) when the read
  /// returned data with some chunks missing; null otherwise.
  final String? partialCode;

  /// Raw items the bridge read returned (HRV: samples). Counts
  /// are operational metadata, not biometric values.
  final int? sampleCount;

  /// Days the returned items attributed to (HRV: days with a
  /// daily value after Dart-side attribution).
  final int? dayCount;

  final int atMs; // epoch ms of the capture

  const CaptureDiagnostic({
    this.errorCode,
    this.partialCode,
    this.sampleCount,
    this.dayCount,
    required this.atMs,
  });

  Map<String, dynamic> toJson() => {
        if (errorCode != null) 'code': errorCode,
        if (partialCode != null) 'partialCode': partialCode,
        if (sampleCount != null) 'samples': sampleCount,
        if (dayCount != null) 'days': dayCount,
        'atMs': atMs,
      };

  static CaptureDiagnostic? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final at = raw['atMs'];
    if (at is! num) return null;
    String? asCode(dynamic v) {
      final s = v?.toString();
      return (s == null || s.isEmpty) ? null : s;
    }

    int? asCount(dynamic v) => v is num ? v.toInt() : null;
    return CaptureDiagnostic(
      errorCode: asCode(raw['code']),
      partialCode: asCode(raw['partialCode']),
      sampleCount: asCount(raw['samples']),
      dayCount: asCount(raw['days']),
      atMs: at.toInt(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CaptureDiagnostic &&
      other.errorCode == errorCode &&
      other.partialCode == partialCode &&
      other.sampleCount == sampleCount &&
      other.dayCount == dayCount &&
      other.atMs == atMs;

  @override
  int get hashCode =>
      Object.hash(errorCode, partialCode, sampleCount, dayCount, atMs);

  @override
  String toString() => 'CaptureDiagnostic(code=$errorCode, '
      'partial=$partialCode, samples=$sampleCount, days=$dayCount '
      '@ $atMs)';
}

/// Per-day Daily Score metadata (server sync, Oct 28, 2026):
/// which write path produced the day's persisted score, when it
/// was computed (epoch ms), and which algorithm version computed
/// it. Kept in a SIDECAR map in the store blob (keyed by date),
/// NOT as fields on [DailyBiometrics]: the row's shape, equality,
/// and serialization are a contract every reader and merge mode
/// already relies on, and unscored days have no metadata at all —
/// a sidecar entry exists exactly for scored days.
///
/// ABSENT entry = a LEGACY record: a score persisted before sync
/// existed (or by a caller that supplied no metadata). A legacy
/// record's computedAt is treated as 0 / unknown by the hydration
/// conflict rule, so a server `manual_refresh` record with ANY
/// computedAt wins over it (see
/// [HealthHistoryStore.applyHydratedScores]).
class DailyScoreMeta {
  /// `auto` or `manual_refresh` (the sync contract's values).
  final String source;
  final int computedAt; // epoch ms
  final int algorithmVersion;

  const DailyScoreMeta({
    required this.source,
    required this.computedAt,
    required this.algorithmVersion,
  });

  Map<String, dynamic> toJson() => {
        'source': source,
        'computedAt': computedAt,
        'algorithmVersion': algorithmVersion,
      };

  static DailyScoreMeta? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final source = raw['source']?.toString();
    final computedAt = raw['computedAt'];
    final version = raw['algorithmVersion'];
    if (source == null || source.isEmpty || computedAt is! num) {
      return null;
    }
    return DailyScoreMeta(
      source: source,
      computedAt: computedAt.toInt(),
      algorithmVersion: version is num ? version.toInt() : 1,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DailyScoreMeta &&
      other.source == source &&
      other.computedAt == computedAt &&
      other.algorithmVersion == algorithmVersion;

  @override
  int get hashCode => Object.hash(source, computedAt, algorithmVersion);

  @override
  String toString() =>
      'DailyScoreMeta($source @ $computedAt, v$algorithmVersion)';
}

/// One server Daily Score record, translated for hydration (see
/// [HealthHistoryStore.applyHydratedScores]). [sleepNeedMinutes]
/// is deliberately absent: Sleep Need is derived locally from
/// stored nights, never stored as a biometric — only the raw
/// inputs that map onto row fields travel ([asleepMinutes] →
/// `sleepMinutes`, [hrvMs] → `hrvRmssdMs`, [restingHrBpm]).
class HydratedScore {
  final String date;
  final int dailyScore;
  final int? scoreSleep;
  final int? scoreHrv;
  final int? scoreRestingHr;
  final String source;
  final int computedAt;
  final int algorithmVersion;
  final int? asleepMinutes;
  final double? hrvMs;
  final int? restingHrBpm;

  const HydratedScore({
    required this.date,
    required this.dailyScore,
    this.scoreSleep,
    this.scoreHrv,
    this.scoreRestingHr,
    required this.source,
    required this.computedAt,
    required this.algorithmVersion,
    this.asleepMinutes,
    this.hrvMs,
    this.restingHrBpm,
  });
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

  /// The current version of the rule that computes stored sleep
  /// totals (`sleepMinutes` / `deepSleepMinutes` per night).
  ///
  /// Version 1 is the legacy rule — a single best sleep bout per
  /// night — and is the IMPLICIT version of every blob written
  /// before this key existed (pre-change blobs carry no
  /// `sleepTotalsRuleVersion` key and warm as version 1).
  ///
  /// Version 2 is the Oct 28, 2026 sleep-bouts change: all bouts
  /// for a night are unioned/summed instead of keeping only the
  /// single best bout. A store still on version 1 holds stale
  /// single-bout totals for nights inside Health Connect's
  /// window, so the capture forces one full sleep backfill and
  /// stamps this version once that re-read completes cleanly
  /// (see [HealthHistorySync.captureFromHealthConnect]).
  ///
  /// Honest limit of that upgrade: the forced re-read only
  /// replaces totals for nights it actually returns, so a
  /// version 2 stamp does NOT guarantee every stored total was
  /// recomputed under the new rule. The full list of cases in
  /// which a legacy (version 1) total is kept under the
  /// version 2 stamp:
  /// - Nights older than the 90-day re-read window are never
  ///   re-read, so their stored totals stay as they were.
  /// - Nights inside the 90-day window that Health Connect no
  ///   longer returns — for example because their sessions were
  ///   deleted at the source — are not touched by the merge, so
  ///   their stored totals stay as they were.
  /// - A night whose re-read union total is 0 is treated as
  ///   absent data under the zero rule, so a previously stored
  ///   total for that night is kept; the store never erases a
  ///   stored total on a 0.
  /// - The same applies field by field to deep sleep: a night
  ///   whose re-read deep total is 0 keeps its previously
  ///   stored deep total.
  /// In each case there is no truer value to replace the stored
  /// one with, and clearing it would break the never-shrink
  /// rule — so the legacy value is kept on purpose, and this
  /// comment is the disclosure of that choice.
  static const int currentSleepTotalsRuleVersion = 2;

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
    _scoreMeta.clear();
    _ownerEmail = null;
    _lastCaptureMs = null;
    _captureDiagnostics.clear();
    _sleepTotalsRuleVersion = 1;
    _warmed = false;
  }

  final Map<String, DailyBiometrics> _days = {};

  /// Sidecar per-day Daily Score metadata (see [DailyScoreMeta]).
  /// Written only by the score write paths and by hydration;
  /// cleared with everything else by [_resetMemory] / [clear], so
  /// a sign-out / deletion / owner-mismatch wipe leaves no score
  /// metadata behind for hydration to resurrect from.
  final Map<String, DailyScoreMeta> _scoreMeta = {};

  /// The score metadata for [date], or null when the day is
  /// unscored or its score is a legacy record (see
  /// [DailyScoreMeta]).
  DailyScoreMeta? scoreMetaFor(String date) => _scoreMeta[date];

  /// All score metadata, keyed by date (unmodifiable).
  Map<String, DailyScoreMeta> get scoreMeta => Map.unmodifiable(_scoreMeta);
  bool _warmed = false;
  int? _lastCaptureMs;

  /// Epoch ms of the last successful Health Connect capture
  /// (persisted in the blob; drives the capture throttle).
  int? get lastCaptureMs => _lastCaptureMs;

  int _sleepTotalsRuleVersion = 1;

  /// The sleep-totals rule version the stored sleep values were
  /// computed under (see [currentSleepTotalsRuleVersion]).
  /// Version 1 is implicit for every blob written before the
  /// version key existed.
  int get sleepTotalsRuleVersion => _sleepTotalsRuleVersion;

  final Map<String, CaptureDiagnostic> _captureDiagnostics = {};

  /// Per-metric capture outcomes from the most recent captures,
  /// keyed by metric name (`restingHr`, `calories`, `sleep`,
  /// `spikes`, `hrv` — the capture's own names). Persisted in the
  /// blob so a failed read leaves a trace that survives a restart:
  /// before this record existed, a capture whose HRV read failed
  /// looked exactly like a capture that found no HRV. Non-HRV
  /// entries exist only for failures (cleared by the next
  /// successful read); the HRV entry is written every capture and
  /// carries its outcome counts (see [CaptureDiagnostic]).
  Map<String, CaptureDiagnostic> get lastCaptureDiagnostics =>
      Map.unmodifiable(_captureDiagnostics);

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
  /// When there is no usable blob to adopt (missing, corrupt, or
  /// empty), the store instead binds to [currentEmail] — the
  /// session-resume path's only binding opportunity (R70 fix D).
  Future<void> warmFromDisk({String? currentEmail}) async {
    final expected = _normalizeEmail(currentEmail);
    if (_warmed) {
      if (currentEmail != null) await clearIfOwnerMismatch(currentEmail);
      return;
    }
    Map<String, dynamic>? map;
    try {
      final raw = await _read(storageKey);
      if (raw == null || raw.isEmpty) {
        // R70 fix D — no blob exists to adopt, so there is no
        // foreign-owned data to guard against: bind to the known
        // session account (matching the empty-blob branch below).
        // Without this, the session-resume path (which never calls
        // the login/register callbacks) persists its first session's
        // captures with ownerEmail: null, and the next cold start
        // drops that unowned-but-populated blob in full.
        if (expected != null) _ownerEmail = expected;
        _sleepTotalsRuleVersion = 1;
        _warmed = true;
        return;
      }
      map = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      // R70 fix D — corrupt/unreadable blob: same as missing. No
      // usable blob to adopt, so bind to the known session account
      // instead of leaving the store unowned for its writes.
      if (expected != null) _ownerEmail = expected;
      _sleepTotalsRuleVersion = 1;
      _warmed = true;
      return;
    }
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
      // Sleep-totals rule version: a num is taken as-is
      // (int-truncated); absent / invalid / < 1 → version 1, the
      // implicit version of every pre-change blob.
      final srv = map['sleepTotalsRuleVersion'];
      _sleepTotalsRuleVersion =
          (srv is num && srv.toInt() >= 1) ? srv.toInt() : 1;
      final diag = map['lastCaptureDiagnostics'];
      if (diag is Map) {
        for (final entry in diag.entries) {
          final d = CaptureDiagnostic.fromJson(entry.value);
          if (d != null) _captureDiagnostics[entry.key.toString()] = d;
        }
      }
      // Score metadata sidecar: absent on every pre-sync blob
      // (those scores are legacy records — see [DailyScoreMeta]).
      // Entries for dates the blob does not hold are dropped: a
      // meta entry must never outlive its day in memory.
      final meta = map['scoreMeta'];
      if (meta is Map) {
        for (final entry in meta.entries) {
          final m = DailyScoreMeta.fromJson(entry.value);
          final date = entry.key.toString();
          if (m != null && _days.containsKey(date)) {
            _scoreMeta[date] = m;
          }
        }
      }
      final rawOwner = map['ownerEmail'];
      if (rawOwner is String) _ownerEmail = _normalizeEmail(rawOwner);
    } catch (_) {
      // Malformed blob: start empty.
      _days.clear();
    }
    // R70 fix D — reaching here with a known session account means
    // no foreign-owned data was loaded (a mismatched / unowned-
    // with-data blob was dropped above, before this point), so the
    // store must end bound to that account. This also covers the
    // malformed-blob catch above (days cleared, nothing loaded)
    // and a blob whose ownerEmail is an empty/blank string, whose
    // normalized owner would otherwise overwrite the empty-blob
    // stamp above with null.
    if (expected != null) _ownerEmail = expected;
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
          'sleepTotalsRuleVersion': _sleepTotalsRuleVersion,
          if (_captureDiagnostics.isNotEmpty)
            'lastCaptureDiagnostics': {
              for (final e in _captureDiagnostics.entries)
                e.key: e.value.toJson(),
            },
          'days': {for (final d in dates) d: _days[d]!.toJson()},
          if (_scoreMeta.isNotEmpty)
            'scoreMeta': {
              for (final d in (_scoreMeta.keys.toList()..sort()))
                if (_days.containsKey(d)) d: _scoreMeta[d]!.toJson(),
            },
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

  /// Stamps the sleep-totals rule version and persists it (see
  /// [currentSleepTotalsRuleVersion]). Only ever moves forward:
  /// a value at or below the current in-memory version is
  /// ignored, so a stale caller can never resurrect legacy
  /// single-bout semantics after the upgrade has landed.
  Future<void> markSleepTotalsRuleVersion(int version) async {
    await _ensureWarmed();
    if (version <= _sleepTotalsRuleVersion) return;
    _sleepTotalsRuleVersion = version;
    await persist();
  }

  /// Records one capture's per-metric read outcomes (HRV capture
  /// visibility fix): every metric in [failures] gets a
  /// [CaptureDiagnostic] with its bridge error code + [atMs], and
  /// every metric in [succeeded] has any earlier entry cleared.
  /// Codes only — callers pass `lastReadErrorCode`, never values
  /// or exception text. Persists only when something changed.
  /// Never throws (goes through [persist]).
  ///
  /// Defect 1b — the HRV outcome: when the capture ran its HRV leg
  /// it also passes [hrvPartialCode] (null unless the read came
  /// back partial), [hrvSampleCount] (raw samples the bridge
  /// returned) and [hrvDayCount] (days they attributed to). The
  /// `hrv` entry is then (re)written on EVERY capture — its
  /// errorCode comes from [failures] (absent = the read returned)
  /// — replacing, never stacking on, the previous capture's entry.
  Future<void> recordCaptureDiagnostics({
    required Map<String, String> failures,
    required Set<String> succeeded,
    required int atMs,
    String? hrvPartialCode,
    int? hrvSampleCount,
    int? hrvDayCount,
  }) async {
    await _ensureWarmed();
    var changed = false;
    for (final metric in succeeded) {
      if (metric == 'hrv') continue; // rewritten below, not cleared
      if (_captureDiagnostics.remove(metric) != null) changed = true;
    }
    for (final entry in failures.entries) {
      if (entry.key == 'hrv') continue; // rewritten below
      if (entry.value.isEmpty) continue;
      final next = CaptureDiagnostic(errorCode: entry.value, atMs: atMs);
      if (_captureDiagnostics[entry.key] != next) {
        _captureDiagnostics[entry.key] = next;
        changed = true;
      }
    }
    if (hrvSampleCount != null || failures.containsKey('hrv')) {
      final next = CaptureDiagnostic(
        errorCode: failures['hrv'],
        partialCode: hrvPartialCode,
        sampleCount: hrvSampleCount,
        dayCount: hrvDayCount,
        atMs: atMs,
      );
      if (_captureDiagnostics['hrv'] != next) {
        _captureDiagnostics['hrv'] = next;
        changed = true;
      }
    } else if (succeeded.contains('hrv')) {
      // A successful HRV read with no outcome counts reported
      // clears the failure entry like every other metric.
      if (_captureDiagnostics.remove('hrv') != null) changed = true;
    }
    if (changed) await persist();
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

  // ── Daily Score write paths ────────────────────────────────────
  //
  // Exactly two LOCAL methods may write the score fields:
  // [persistScore] (write-once, the engine's first scoring of a
  // day) and [replaceScore] (the user-initiated refresh overwrite
  // — see its doc; nothing automatic may call it). Server sync
  // adds a third, [applyHydratedScores] below, which writes only
  // under its documented conflict rule and never recomputes.

  /// Write-once score persistence: sets the four score fields on
  /// the stored day [date] and persists. Returns false — writing
  /// nothing — when the day is not in the store or already holds a
  /// score. A persisted score is never recomputed or rewritten by
  /// any AUTOMATIC path: later baseline drift must not rewrite
  /// history, and a day computed from a partial component set
  /// stays as computed. The single exception is the founder's
  /// explicit refresh tap, which goes through [replaceScore],
  /// never through here.
  Future<bool> persistScore(
    String date, {
    required int dailyScore,
    int? scoreSleep,
    int? scoreHrv,
    int? scoreRestingHr,
    String? scoreSource,
    int? scoreComputedAt,
    int? scoreAlgorithmVersion,
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
    // Score metadata (sync): recorded when the caller supplies
    // it (the engine always does). A caller that supplies none
    // leaves the day a legacy record — see [DailyScoreMeta].
    if (scoreSource != null && scoreComputedAt != null) {
      _scoreMeta[date] = DailyScoreMeta(
        source: scoreSource,
        computedAt: scoreComputedAt,
        algorithmVersion: scoreAlgorithmVersion ?? 1,
      );
    }
    await persist();
    return true;
  }

  /// ⚠ USER-INITIATED REFRESH ONLY — the one score overwrite path.
  ///
  /// Replaces the four score fields on the stored day [date] with
  /// the values given (nulls included, exactly as [persistScore]
  /// writes them) and persists. Returns false — writing nothing —
  /// when the day is not in the store.
  ///
  /// Founder direction (Oct 20, 2026): scores stay write-once for
  /// every automatic behavior, but the founder can tap Refresh on
  /// a day's detail screen to re-score THAT day from the data the
  /// store holds after a forced capture — the deliberate exception
  /// that lets him verify late-arriving HRV / resting HR / sleep
  /// actually lands. The Daily Score engine must NEVER call this
  /// method, and no capture, import, or background path may call
  /// it either: the only caller is the refresh orchestration
  /// (`DailyScoreRefresher`), invoked from the day detail's
  /// refresh button handler.
  Future<bool> replaceScore(
    String date, {
    required int dailyScore,
    int? scoreSleep,
    int? scoreHrv,
    int? scoreRestingHr,
    String? scoreSource,
    int? scoreComputedAt,
    int? scoreAlgorithmVersion,
  }) async {
    await _ensureWarmed();
    final existing = _days[date];
    if (existing == null) return false;
    _days[date] = existing.withScores(
      dailyScore: dailyScore,
      scoreSleep: scoreSleep,
      scoreHrv: scoreHrv,
      scoreRestingHr: scoreRestingHr,
    );
    // Score metadata (sync) — F1 fix (Vera, Oct 28, 2026):
    // restamp UNCONDITIONALLY whenever the caller supplies
    // metadata, even when the recomputation yields the SAME
    // four score values. The local stamp is the comparison
    // operand of the hydration conflict rule in
    // [applyHydratedScores] (server wins iff server
    // manual_refresh && server.computedAt > local computedAt),
    // and the refresher passes ONE computedAt to both this
    // method and its queued sync payload — the sync layer's
    // invariant is that the payload stamp == the store
    // metadata stamp. Keeping the old stamp on an
    // unchanged-score refresh broke that invariant (local
    // still read auto @ T1 while the payload/server carried
    // manual_refresh @ T2), so a stale local stamp could
    // cause over-adoption of a server record in a
    // POST-fails/GET-succeeds window. Callers that supply
    // no metadata keep the previous behavior (no restamp).
    if (scoreSource != null && scoreComputedAt != null) {
      _scoreMeta[date] = DailyScoreMeta(
        source: scoreSource,
        computedAt: scoreComputedAt,
        algorithmVersion:
            scoreAlgorithmVersion ?? _scoreMeta[date]?.algorithmVersion ?? 1,
      );
    }
    await persist();
    return true;
  }

  // ── Daily Score hydration (server sync) ────────────────────────
  //
  // The ONLY other score write path, used exclusively by
  // `DailyScoreSync.hydrate` to merge server records into this
  // store. The conflict rule is EXACTLY this (verbatim from the
  // sync spec, Oct 28, 2026):
  //
  //   * Local day missing a score → take the server record (fill).
  //   * Both present → take the server record ONLY IF
  //     server.source == 'manual_refresh' AND server.computedAt >
  //     local computedAt. In every other case the local record
  //     stands.
  //   * Hydration writes the persisted score + the three
  //     component subscores + source/computedAt/algorithmVersion
  //     metadata + the raw inputs (asleepMinutes → the row's
  //     sleep minutes, hrvMs → hrvRmssdMs, restingHrBpm) ONLY into
  //     fields that are locally absent — it must NEVER overwrite
  //     a locally present biometric value (Health Connect is the
  //     source of truth for biometrics).
  //   * Hydration runs only against the store's bound owner; on
  //     owner mismatch it does nothing (the store's existing
  //     owner logic governs).
  //
  // A legacy local record (no [DailyScoreMeta]) has computedAt 0,
  // so a server manual_refresh with any computedAt wins over it.
  // The biometric fill applies in every case (fill-absent only);
  // score + metadata change only when the server record is taken.
  // Returns how many days changed in any way. Never throws (a
  // persist failure leaves memory updated, exactly as [persist]
  // behaves everywhere else in this store).

  Future<int> applyHydratedScores(List<HydratedScore> records) async {
    await _ensureWarmed();
    var changed = 0;
    for (final rec in records) {
      if (rec.date.isEmpty) continue;
      final existing = _days[rec.date];
      // Raw inputs, zero rule applied (≤ 0 = absent, never a fill).
      final fillSleep = (rec.asleepMinutes != null && rec.asleepMinutes! > 0)
          ? rec.asleepMinutes
          : null;
      final fillHrv =
          (rec.hrvMs != null && rec.hrvMs! > 0) ? rec.hrvMs : null;
      final fillRhr = (rec.restingHrBpm != null && rec.restingHrBpm! > 0)
          ? rec.restingHrBpm
          : null;

      DailyBiometrics withFills(DailyBiometrics base) => DailyBiometrics(
            date: base.date,
            restingHrBpm: base.restingHrBpm ?? fillRhr,
            sleepMinutes: base.sleepMinutes ?? fillSleep,
            deepSleepMinutes: base.deepSleepMinutes,
            spikeCount: base.spikeCount,
            caloriesKcal: base.caloriesKcal,
            hrvRmssdMs: base.hrvRmssdMs ?? fillHrv,
            dailyScore: base.dailyScore,
            scoreSleep: base.scoreSleep,
            scoreHrv: base.scoreHrv,
            scoreRestingHr: base.scoreRestingHr,
          );

      if (existing == null) {
        // Local day missing entirely → take the server record.
        final row = withFills(DailyBiometrics(date: rec.date)).withScores(
          dailyScore: rec.dailyScore,
          scoreSleep: rec.scoreSleep,
          scoreHrv: rec.scoreHrv,
          scoreRestingHr: rec.scoreRestingHr,
        );
        _days[rec.date] = row;
        _scoreMeta[rec.date] = DailyScoreMeta(
          source: rec.source,
          computedAt: rec.computedAt,
          algorithmVersion: rec.algorithmVersion,
        );
        changed++;
        continue;
      }

      final localComputedAt = _scoreMeta[rec.date]?.computedAt ?? 0;
      final takeServer = existing.dailyScore == null ||
          (rec.source == 'manual_refresh' &&
              rec.computedAt > localComputedAt);
      if (takeServer) {
        _days[rec.date] = withFills(existing).withScores(
          dailyScore: rec.dailyScore,
          scoreSleep: rec.scoreSleep,
          scoreHrv: rec.scoreHrv,
          scoreRestingHr: rec.scoreRestingHr,
        );
        _scoreMeta[rec.date] = DailyScoreMeta(
          source: rec.source,
          computedAt: rec.computedAt,
          algorithmVersion: rec.algorithmVersion,
        );
        changed++;
        continue;
      }

      // Local record stands (score + metadata untouched): fill
      // only locally absent biometrics from the server record.
      final filled = withFills(existing);
      if (filled != existing) {
        _days[rec.date] = filled;
        changed++;
      }
    }
    if (changed > 0) await persist();
    return changed;
  }

  // NOTE: _fieldCount / _fieldCountChanged deliberately count the
  // six biometric fields ONLY — merges never gain or lose a day
  // because of score fields, and score writes go through
  // [persistScore] / [replaceScore], never through a merge.
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
