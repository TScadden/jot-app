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

/// The grant state for [metric] given the live [missingPermissions]
/// set (null = grant layer unknown, e.g. an [HcAvailability]
/// snapshot whose `grantKnown` is false).
HcMetricGrantState hcMetricGrantState(
    HistoryMetric metric, Set<String>? missingPermissions) {
  if (missingPermissions == null) return HcMetricGrantState.unknown;
  final metricPermissions =
      reportMetricPermissions[metric] ?? const <String>{};
  final missingForMetric =
      metricPermissions.intersection(missingPermissions);
  if (missingForMetric.isEmpty) return HcMetricGrantState.full;
  if (missingForMetric.length == metricPermissions.length) {
    return HcMetricGrantState.none;
  }
  return HcMetricGrantState.partial;
}
