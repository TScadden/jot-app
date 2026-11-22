import 'package:tabs_lab/src/data/health_history_queries.dart';

/// Report Reliability Phase 2 (§2/§3) — the availability home for
/// the per-metric permission map and grant derivation, shared by
/// every availability consumer (the report collector now; the
/// capture / Daily Score path in PR-3). The snapshot type itself
/// (HcAvailability) and the probe that produces it
/// (HealthConnectService.probeAvailability) live in
/// health_connect_service.dart.

/// The Health Connect permission(s) each report history metric
/// actually reads — traced from the bridge reads behind
/// [HealthHistoryQueries] (Kotlin record types per Dart read):
/// - sleep: `readSleepHistory` → SleepSessionRecord
/// - restingHr: `readRestingHrHistory` → RestingHeartRateRecord,
///   with the HeartRateRecord BPM_AVG aggregate as its per-day
///   fallback (the same call fails if either read is blocked)
/// - hrv: `readHrvSamples` → HeartRateVariabilityRmssdRecord
/// - calories: `readCaloriesHistory` → the ActiveCaloriesBurned +
///   TotalCaloriesBurned aggregate pair (`active ?: total`)
/// - spikes: `readSpikeCounts` → HeartRateRecord
///
/// This is deliberately NOT `HealthConnectService.requiredPermissions`:
/// a missing permission a metric never reads (e.g. Steps) must not
/// condemn that metric's section.
///
/// Phase 2: moved here from progress_report.dart (Phase 1's home)
/// with byte-identical contents — this is now THE metric→permissions
/// map; the report imports it from here.
const Map<HistoryMetric, Set<String>> reportMetricPermissions = {
  HistoryMetric.sleep: {'android.permission.health.READ_SLEEP'},
  HistoryMetric.restingHr: {
    'android.permission.health.READ_RESTING_HEART_RATE',
    'android.permission.health.READ_HEART_RATE',
  },
  HistoryMetric.hrv: {
    'android.permission.health.READ_HEART_RATE_VARIABILITY',
  },
  HistoryMetric.calories: {
    'android.permission.health.READ_ACTIVE_CALORIES_BURNED',
    'android.permission.health.READ_TOTAL_CALORIES_BURNED',
  },
  HistoryMetric.spikes: {'android.permission.health.READ_HEART_RATE'},
};

/// One metric's grant state, derived from the live missing set
/// via [reportMetricPermissions] (Phase 2 §3's `grant` input):
/// - [full]: every permission THIS metric reads is granted;
/// - [partial]: some of this metric's permissions are missing;
/// - [none]: every permission this metric reads is missing;
/// - [unknown]: the grant layer itself is unknown (the probe's
///   bridge read errored) — no grant claim may be derived.
enum HcMetricGrantState { full, partial, none, unknown }

/// HC Grant Hardening (Nov 20, 2026) — the GENERAL grant state for
/// an arbitrary permission set, the derivation [hcMetricGrantState]
/// is now built over. Same four values, same meaning, for ANY
/// feature's permission set (not just report metrics):
/// - [full]: every permission in the set is granted;
/// - [partial]: some of the set is missing;
/// - [none]: every permission in the set is missing (VERIFIED
///   missing — the grant layer answered and none of the set is in
///   it);
/// - [unknown]: the grant layer itself is unknown (the probe's
///   bridge read errored) — no grant claim may be derived.
enum HcGrantState { full, partial, none, unknown }

/// The grant state for [permissions] given the live
/// [missingPermissions] set (null = grant layer unknown, e.g. an
/// [HcAvailability] snapshot whose `grantKnown` is false).
HcGrantState hcGrantStateFor(
    Set<String> permissions, Set<String>? missingPermissions) {
  if (missingPermissions == null) return HcGrantState.unknown;
  final missingForSet = permissions.intersection(missingPermissions);
  if (missingForSet.isEmpty) return HcGrantState.full;
  if (missingForSet.length == permissions.length) {
    return HcGrantState.none;
  }
  return HcGrantState.partial;
}

/// The read-attempt rule (HC Grant Hardening §3.1, generalizing the
/// badges §9 verified-denial pattern): a feature attempts its read
/// UNLESS its permission set is VERIFIED missing. Unknown grant
/// layer ⇒ attempt (the read fails closed to its honest empty
/// state, and its outcome feeds wedge detection). For a
/// multi-permission read, [anySufficient] states whether ONE
/// granted permission from the set lets the read proceed (the
/// calories pair, native `active ?: total`): then a [HcGrantState
/// .partial] still attempts. When every permission in the set is
/// required for the read to proceed as designed (the resting-HR
/// pair — the bridge call fails if either leg is blocked), a
/// partial skips the read, exactly like a verified-missing set.
bool hcShouldAttemptRead(
  Set<String> permissions,
  Set<String>? missingPermissions, {
  bool anySufficient = false,
}) {
  final state = hcGrantStateFor(permissions, missingPermissions);
  return switch (state) {
    HcGrantState.full || HcGrantState.unknown => true,
    HcGrantState.partial => anySufficient,
    HcGrantState.none => false,
  };
}

/// The grant state for [metric] given the live [missingPermissions]
/// set (null = grant layer unknown, e.g. an [HcAvailability]
/// snapshot whose `grantKnown` is false).
HcMetricGrantState hcMetricGrantState(
    HistoryMetric metric, Set<String>? missingPermissions) {
  final state = hcGrantStateFor(
      reportMetricPermissions[metric] ?? const <String>{},
      missingPermissions);
  return switch (state) {
    HcGrantState.full => HcMetricGrantState.full,
    HcGrantState.partial => HcMetricGrantState.partial,
    HcGrantState.none => HcMetricGrantState.none,
    HcGrantState.unknown => HcMetricGrantState.unknown,
  };
}

/// HC Grant Hardening §3.1 — the per-feature permission sets. Each
/// feature gates its reads on ONLY the permissions its reads
/// actually consume — never on
/// `HealthConnectService.requiredPermissions` as a whole. A missing
/// or wedged permission degrades only its own data type.
const Set<String> heartPermissions = {
  'android.permission.health.READ_HEART_RATE',
};

/// Sleep reads (vitals sleep minutes, the Sleep screen's union).
const Set<String> sleepPermissions = {
  'android.permission.health.READ_SLEEP',
};

/// Blood Pressure tool / snapshot BP half.
const Set<String> bloodPressurePermissions = {
  'android.permission.health.READ_BLOOD_PRESSURE',
};

/// The availability probe's own read (StepsRecord).
const Set<String> stepsPermissions = {
  'android.permission.health.READ_STEPS',
};

/// HRV reads (Key Metrics tile, coach context).
const Set<String> hrvPermissions = {
  'android.permission.health.READ_HEART_RATE_VARIABILITY',
};

/// Resting heart rate per-day read (Key Metrics tile). The resting
/// HISTORY union keeps the report map's pair semantics (see
/// [reportMetricPermissions]).
const Set<String> restingHeartRatePermissions = {
  'android.permission.health.READ_RESTING_HEART_RATE',
};

/// Latest weight read (Key Metrics tile).
const Set<String> weightPermissions = {
  'android.permission.health.READ_WEIGHT',
};

/// Respiratory rate read (Key Metrics tile).
const Set<String> respiratoryRatePermissions = {
  'android.permission.health.READ_RESPIRATORY_RATE',
};

/// Oxygen saturation read (Key Metrics tile).
const Set<String> oxygenSaturationPermissions = {
  'android.permission.health.READ_OXYGEN_SATURATION',
};

/// The vitals calories read's set: the report map's pair (the
/// bridge read is native `active ?: total`, so ONE granted leg
/// lets it proceed — attempt with [hcShouldAttemptRead]'s
/// `anySufficient: true`).
const Set<String> vitalsCaloriesPermissions = {
  'android.permission.health.READ_ACTIVE_CALORIES_BURNED',
  'android.permission.health.READ_TOTAL_CALORIES_BURNED',
};
