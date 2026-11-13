import 'dart:async';

import 'package:tabs_lab/src/data/correlation_copy.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/correlation_insight_store.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/hc_availability.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// Round 66 — Progress Reports: the Flutter port of the native
/// clinical-report pipeline.
///
/// Native ground truth (traced from source at flutter-app dace82f):
/// - Screen: `ui/screen/ProgressReportsScreen.kt` (ReportFocus,
///   preset slug sets, coverage math, share confirmation).
/// - Collector: `data/repository/ClinicalReportDataCollector.kt`
///   (parallel sections, per-section availability metadata).
/// - AI request: `data/remote/GeminiService.kt`
///   `getMedicalReportSummaryFromSnapshot` (profile text, health
///   summary string, availability block — byte formats reproduced
///   in [buildReportUserContext], [buildHealthSummary],
///   [buildDataAvailability]).
/// - Pipeline: `data/repository/LogRepository.kt`
///   `generateProfessionalReportWithSnapshot` (staged states, AI
///   retry policy, raw fallback) + `util/AiFailureReasons.kt`
///   (plain-language failure reasons).
/// - PDF: `util/ReportGenerator.kt` (see progress_report_pdf.dart).
///
/// Category-slug divergence (documented): the sync category DTO
/// carries NO slug (native `CategoryDtoModel`; see
/// today_summary.dart's category-resolution note), so presets
/// resolve through this port's [slugByIdFallback] — the native
/// `DefaultCategories.slugById` canonical map — applied by category
/// id, EXACTLY the fallback native itself uses for pre-slug rows
/// (`effectiveSlug`). A pulled category whose id is not a default
/// id has no slug and matches no preset (native's stored-slug rows
/// could match; the DTO simply never carries one — the same limit
/// the Round 21 feeling check-in and Round 35 Today Summary ports
/// already live with).
///
/// Health Connect divergence (documented): native's collector reads
/// cache-first series (daytime awake-average HR from its DataStore
/// caches). Flutter's series come from the R70 union helper
/// (`health_history_queries.dart`): the historical store (WS1) ∪
/// the SAME bridge range reads the Flutter screens use — sleep/deep
/// from `readSleepHistory`, calories from `readCaloriesHistory`,
/// spikes from `readSpikeCounts` (Key Metrics / HealthRepository),
/// HR from `readRestingHrHistory` (the per-day HR history source
/// HealthRepository, Today Summary, Coach and Key Metrics all use;
/// native's report HR is the daytime average, Flutter's range read
/// is resting HR — the values can differ), HRV per-day from
/// `readHrvRmssd`. R70 WS2: the
/// union means the series and the per-section availability counts
/// now reflect the store's full depth inside the requested range,
/// not just Health Connect's retention window; the request-body
/// format is unchanged (R66).
///
/// Knowledge documents: R65 landed during this round
/// (027a6c7) with `knowledge_documents.dart`; the page wires
/// [ReportDataCollector.documentsLoader] to its
/// KnowledgeExtractionStore (the pull's document rows + on-device
/// extracted texts, blank/failed skipped — native's DAO rule). The
/// collector's default loader (no store wired) returns no
/// documents, which is also the honest state for an account with
/// no extracted documents.

// ── Report focus / presets (ProgressReportsScreen.kt) ─────────────

enum ReportFocus {
  health('health', 'Health', 'Symptoms, meds, sleep, mood, and vitals'),
  training('training', 'Training', 'Habits, vitals, and food'),
  custom('custom', 'Custom', 'You pick the categories');

  final String key;
  final String label;
  final String description;
  const ReportFocus(this.key, this.label, this.description);

  static ReportFocus fromKey(String? key) => switch (key) {
        'training' => ReportFocus.training,
        'custom' => ReportFocus.custom,
        _ => ReportFocus.health,
      };
}

/// Native preset slug sets (ProgressReportsScreen.kt).
const healthSlugs = {'symptoms', 'medication', 'sleep', 'mood', 'heart_rate'};
const trainingSlugs = {'personal', 'heart_rate', 'calories'};

/// Native `DefaultCategories.slugById` — the canonical slug for each
/// default category id, native's own fallback for pre-slug rows.
const slugByIdFallback = <int, String>{
  1: 'symptoms',
  2: 'calories',
  3: 'heart_rate',
  8: 'medication',
  4: 'personal',
  5: 'sleep',
  6: 'mood',
  7: 'general',
};

/// Effective slug for preset matching: the Flutter DTO has no slug,
/// so this is always the canonical fallback by id (native's
/// `category.slug ?: slugById[id] ?: ""` with the first term absent).
String effectiveSlug(QuickLogCategory category) =>
    slugByIdFallback[category.id] ?? '';

/// Port of native `resolveReportCategories`.
List<QuickLogCategory> resolveReportCategories(
  List<QuickLogCategory> all,
  ReportFocus focus,
  Set<int> customIds,
) =>
    switch (focus) {
      ReportFocus.health =>
        all.where((c) => healthSlugs.contains(effectiveSlug(c))).toList(),
      ReportFocus.training =>
        all.where((c) => trainingSlugs.contains(effectiveSlug(c))).toList(),
      ReportFocus.custom => all.where((c) => customIds.contains(c.id)).toList(),
    };

// ── Coverage (ProgressReportsScreen.kt, Tess's feature) ───────────

/// Entries in [range] (native: `timestamp >= cutoff`, cutoff 0 for
/// All Time) whose category is selected.
List<QuickLogEntry> logsInRange(
  List<QuickLogEntry> all,
  Set<int> selectedIds, {
  required bool last30Days,
  required int nowMs,
}) {
  final cutoff = last30Days ? nowMs - 30 * 24 * 60 * 60 * 1000 : 0;
  return all
      .where((e) => e.timestamp >= cutoff && selectedIds.contains(e.categoryId))
      .toList();
}

/// Distinct days with entries: native divides the raw epoch ms by
/// the day length (`timestamp / dayMs`), NOT local calendar days.
int distinctDaysLogged(List<QuickLogEntry> logs) =>
    logs.map((e) => e.timestamp ~/ (24 * 60 * 60 * 1000)).toSet().length;

/// Coverage denominator: 30 for This Month; for All Time the actual
/// span from the oldest entry (ALL logs, unfiltered — native uses
/// `allLogs`), capped at 180, floored at 1.
int coverageDenominator(
  List<QuickLogEntry> allLogs, {
  required bool last30Days,
  required int nowMs,
}) {
  if (last30Days) return 30;
  if (allLogs.isEmpty) return 1;
  final oldest = allLogs.map((e) => e.timestamp).reduce((a, b) => a < b ? a : b);
  final span = ((nowMs - oldest) ~/ (24 * 60 * 60 * 1000)) + 1;
  return span < 1 ? 1 : (span > 180 ? 180 : span);
}

/// Entries per hour of day (local), native's preview chart data.
Map<int, int> hourlyCounts(List<QuickLogEntry> logs) {
  final out = <int, int>{};
  for (final e in logs) {
    final h = DateTime.fromMillisecondsSinceEpoch(e.timestamp).hour;
    out[h] = (out[h] ?? 0) + 1;
  }
  return out;
}

/// Native `formatHour` for the hourly chart's selected-hour label.
String formatHourLabel(int hour) => switch (hour) {
      0 => '12 AM',
      12 => '12 PM',
      _ when hour < 12 => '$hour AM',
      _ => '${hour - 12} PM',
    };

String hourBarLabel(int hour) => switch (hour) {
      0 => '12am',
      12 => '12pm',
      _ when hour < 12 => '${hour}am',
      _ => '${hour - 12}pm',
    };

// ── Appointment (ProgressReportsScreen.kt) ────────────────────────

/// "MMM d, yyyy" for an ISO `yyyy-MM-dd` date; the raw string when
/// unparsable (native `formatIsoDate`).
String formatIsoDate(String iso) {
  final d = DateTime.tryParse(iso);
  if (d == null) return iso;
  return '${_months[d.month - 1]} ${d.day}, ${d.year}';
}

/// "today" / "tomorrow" / "in N days", or null when past/unparsable
/// (native `appointmentCountdown`, UTC-normalized calendar days).
String? appointmentCountdown(String iso, {DateTime? now}) {
  final target = DateTime.tryParse(iso);
  if (target == null) return null;
  final n = now ?? DateTime.now();
  final t = DateTime.utc(target.year, target.month, target.day);
  final today = DateTime.utc(n.year, n.month, n.day);
  final days = t.difference(today).inDays;
  return switch (days) {
    < 0 => null,
    0 => 'today',
    1 => 'tomorrow',
    _ => 'in $days days',
  };
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "MMM d, yyyy" (native SimpleDateFormat, US locale).
String formatMmmDyyyy(DateTime d) =>
    '${_months[d.month - 1]} ${d.day}, ${d.year}';

/// "MMM d, h:mm a" — the Last exported line.
String formatExportTimestamp(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_months[d.month - 1]} ${d.day}, ${_hour12(d.hour)}:${d.minute.toString().padLeft(2, '0')} ${_amPm(d.hour)}';
}

/// "MMM dd, yyyy - hh:mm a" — the PDF meta line.
String formatPdfGenerated(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${_months[d.month - 1]} ${d.day.toString().padLeft(2, '0')}, ${d.year} - ${_hour12(d.hour).toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} ${_amPm(d.hour)}';
}

/// The generated artifact's file name. Native's form was
/// date-only (`Tabs_Report_<MMM_dd_yyyy>.pdf`), which made
/// same-day generations silently overwrite each other in the
/// app documents directory (the save truncates the same path)
/// and collide as duplicate Downloads display names. VC 100129:
/// the name is unique per generation — the generation timestamp
/// (both pipelines derive it from
/// `snapshot.generationTimestampMs`, millisecond precision)
/// is carried in the name, keeping the recognizable
/// `Tabs_Report_` prefix and `.pdf`:
/// `Tabs_Report_<MMM_dd_yyyy>_<HHmmss><fff>.pdf`.
String reportFileName(DateTime d) =>
    'Tabs_Report_${_months[d.month - 1]}_${d.day.toString().padLeft(2, '0')}_${d.year}'
    '_${d.hour.toString().padLeft(2, '0')}${d.minute.toString().padLeft(2, '0')}${d.second.toString().padLeft(2, '0')}${d.millisecond.toString().padLeft(3, '0')}.pdf';

int _hour12(int h) {
  final x = h % 12;
  return x == 0 ? 12 : x;
}

String _amPm(int h) => h < 12 ? 'AM' : 'PM';

/// "yyyy-MM-dd" for a date (bridge + HRV per-date keys).
String dateStrOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ── Snapshot model (ClinicalReportData.kt) ────────────────────────

enum DataSourceStatus {
  success,
  noData,
  permissionDenied,
  unavailable,
  timedOut,
  error,

  /// The metric's permission IS granted (live granted set) but its
  /// own fresh read was blocked with a SecurityException — the
  /// stale/wedged grant state for that metric. Never derived from
  /// a connection/status probe: only from the read's own failure
  /// detail (see [HistoryUnion.failedWithSecurityException]).
  stale,

  /// The section is populated from the on-device history store
  /// because the fresh Health Connect read failed: the union still
  /// yielded series data, and a failed fresh read contributes no
  /// rows, so every row present came from the store.
  storedOnly,
}

/// Phase 2 (§3) — THE shared per-metric availability derivation:
/// Phase 1's `hcStatus()` decision order, extracted into one
/// function consumed by the report collector now and asserted
/// against by the capture path in PR-3. The decision order is
/// exactly Phase 1's:
/// 1. a PARTIAL read → [DataSourceStatus.error] (B-02 preserved:
///    a partial read never derives its status from emptiness);
/// 2. a FAILED read with surviving union data →
///    [DataSourceStatus.storedOnly] (a failed read contributes no
///    fresh rows, so the data present came from the store);
/// 3. a FAILED read, no data, grant KNOWN and a permission THIS
///    metric reads is missing ([grant] is [HcMetricGrantState.partial]
///    or [HcMetricGrantState.none], derived from the metric's
///    permissions ∩ the live missing set) →
///    [DataSourceStatus.permissionDenied];
/// 4. a FAILED read, no data, grant known, and the metric's own
///    read failed with a SecurityException →
///    [DataSourceStatus.stale];
/// 5. any other FAILED read → [DataSourceStatus.error] —
///    including the grant-UNKNOWN case, which masks both the
///    denial and the stale claim exactly as Phase 1 did (an
///    unobtainable missing set is evidence of nothing);
/// 6. a CLEAN read → [DataSourceStatus.success] /
///    [DataSourceStatus.noData] from emptiness.
DataSourceStatus deriveMetricStatus({
  required HcMetricGrantState grant,
  required bool partialRead,
  required bool readFailed,
  required bool readSecurityException,
  required bool unionHasData,
}) {
  if (partialRead) return DataSourceStatus.error;
  if (readFailed) {
    if (unionHasData) return DataSourceStatus.storedOnly;
    if (grant == HcMetricGrantState.partial ||
        grant == HcMetricGrantState.none) {
      return DataSourceStatus.permissionDenied;
    }
    if (grant != HcMetricGrantState.unknown && readSecurityException) {
      return DataSourceStatus.stale;
    }
    return DataSourceStatus.error;
  }
  return unionHasData ? DataSourceStatus.success : DataSourceStatus.noData;
}

/// Phase 2 (§2/§3): the metric→permissions map moved to the
/// availability home (hc_availability.dart, imported above) as
/// THE shared `reportMetricPermissions` — contents byte-identical
/// to Phase 1's map here. The shared per-metric derivation that
/// consumes it is [deriveMetricStatus] below.

class SectionMetadata {
  final String sectionKey;
  final DataSourceStatus status;
  final int recordCount;
  const SectionMetadata(this.sectionKey, this.status, this.recordCount);
}

/// One BP reading in the snapshot (native `BloodPressureUiRecord`
/// fields the pipeline uses: systolic, diastolic, timeEpochMs).
class ReportBpRecord {
  final int systolic;
  final int diastolic;
  final int timeEpochMs;
  const ReportBpRecord(this.systolic, this.diastolic, this.timeEpochMs);
}

/// Immutable report snapshot — port of native `ClinicalReportData`.
class ReportSnapshot {
  final bool last30Days;

  /// Range duration in days: native `ClinicalReportRange.durationDays`
  /// — 30 for LAST_30_DAYS, 180 for FULL (its start is now−180d).
  int get durationDays => last30Days ? 30 : 180;

  String get rangeTypeName => last30Days ? 'LAST_30_DAYS' : 'FULL';

  final int generationTimestampMs;
  final List<QuickLogEntry> logEntries;
  final Map<int, String> categoriesMap;
  final String userContext;
  final int userAge;

  /// Stored in inches, as native (converted to cm in the request).
  final double userHeightIn;
  final double userWeightLbs;
  final String userGender;
  final List<String> conditions;
  final List<MedicationEntry> medications;

  /// VC 100132 (Round 4, Problem 1) — the FULL parsed profile
  /// medication list (active + archived, deleted excluded) for the
  /// structured `medications` channel of the /api/ai/report payload
  /// (see [buildAiReportRequest]). [medications] stays the ACTIVE
  /// list every local render uses; this list is what the server's
  /// structured-medications guard expects: current AND discontinued
  /// entries, each with name/dose/frequency/start/end + archived
  /// flag. Empty when the caller built the snapshot without it —
  /// the request builder then falls back to [medications].
  final List<MedicationEntry> profileMedications;
  final List<String> knowledgeDocuments;

  /// VC 100132 (Round 4, Problem 2) — stored Daily Scores in range,
  /// date keys `yyyy-MM-dd`, values > 0 (the clinician reader's
  /// filter, reused). Empty until the collector wires the store
  /// read in; the section metadata count is THIS list's length.
  final List<(String, int)> dailyScoreSeries;

  /// Per-day series, date keys `yyyy-MM-dd`, values > 0 only
  /// (the founder zero rule, applied at collection).
  final List<(String, int)> heartRateSeries;
  final List<(String, int)> sleepSeries;
  final List<(String, int)> deepSleepSeries;
  final List<(String, int)> caloriesSeries;
  final List<(String, double)> hrvSeries;

  /// Per-day HR spike counts (a 0 count is a real sampled day and
  /// is kept here; charts/sums apply native's own filters).
  final List<(String, int)> heartRateSpikes;
  final List<ReportBpRecord> bloodPressureSeries;

  /// Insertion-ordered per-section availability (native collector's
  /// section order; the specimen's rendered order follows the
  /// native concurrent completion order and may vary — the key SET
  /// and wording are the parity contract).
  final Map<String, SectionMetadata> sectionMetadata;
  final List<InsightRecord> correlationInsights;
  final bool correlationInsightsLoadFailed;

  const ReportSnapshot({
    required this.last30Days,
    required this.generationTimestampMs,
    required this.logEntries,
    required this.categoriesMap,
    this.userContext = '',
    this.userAge = 0,
    this.userHeightIn = 0,
    this.userWeightLbs = 0,
    this.userGender = '',
    this.conditions = const [],
    this.medications = const [],
    this.profileMedications = const [],
    this.dailyScoreSeries = const [],
    this.knowledgeDocuments = const [],
    this.heartRateSeries = const [],
    this.sleepSeries = const [],
    this.deepSleepSeries = const [],
    this.caloriesSeries = const [],
    this.hrvSeries = const [],
    this.heartRateSpikes = const [],
    this.bloodPressureSeries = const [],
    this.sectionMetadata = const {},
    this.correlationInsights = const [],
    this.correlationInsightsLoadFailed = false,
  });

  /// Native `hasAnyData`.
  bool get hasAnyData =>
      logEntries.isNotEmpty ||
      heartRateSeries.isNotEmpty ||
      sleepSeries.isNotEmpty ||
      caloriesSeries.isNotEmpty ||
      hrvSeries.isNotEmpty ||
      heartRateSpikes.isNotEmpty ||
      bloodPressureSeries.isNotEmpty ||
      conditions.isNotEmpty ||
      medications.isNotEmpty ||
      dailyScoreSeries.isNotEmpty ||
      knowledgeDocuments.isNotEmpty;

  /// Returns a new [ReportSnapshot] with updated section status.
  ///
  /// Exists so a later pipeline stage that learns a section outcome after
  /// collection (for example the clinician Daily Score read) can record that
  /// outcome in the snapshot metadata without rebuilding the snapshot by hand.
  ReportSnapshot withSectionStatus(
    String key,
    DataSourceStatus status,
    int recordCount,
  ) {
    final updatedMetadata = <String, SectionMetadata>{};
    var matched = false;
    for (final entry in sectionMetadata.entries) {
      if (entry.key == key) {
        updatedMetadata[key] = SectionMetadata(key, status, recordCount);
        matched = true;
      } else {
        updatedMetadata[entry.key] = entry.value;
      }
    }
    if (!matched) {
      updatedMetadata[key] = SectionMetadata(key, status, recordCount);
    }
    return ReportSnapshot(
      last30Days: last30Days,
      generationTimestampMs: generationTimestampMs,
      logEntries: logEntries,
      categoriesMap: categoriesMap,
      userContext: userContext,
      userAge: userAge,
      userHeightIn: userHeightIn,
      userWeightLbs: userWeightLbs,
      userGender: userGender,
      conditions: conditions,
      medications: medications,
      profileMedications: profileMedications,
      dailyScoreSeries: dailyScoreSeries,
      knowledgeDocuments: knowledgeDocuments,
      heartRateSeries: heartRateSeries,
      sleepSeries: sleepSeries,
      deepSleepSeries: deepSleepSeries,
      caloriesSeries: caloriesSeries,
      hrvSeries: hrvSeries,
      heartRateSpikes: heartRateSpikes,
      bloodPressureSeries: bloodPressureSeries,
      sectionMetadata: updatedMetadata,
      correlationInsights: correlationInsights,
      correlationInsightsLoadFailed: correlationInsightsLoadFailed,
    );
  }
}

// ── AI request assembly (GeminiService snapshot path, byte formats) ─

/// Kotlin `Float.toString()` for the profile weight: Dart's double
/// prints the same shortest round-trip form for the values involved
/// (e.g. 165.4, 161.0).
String _floatText(double v) => v.toString();

/// The enriched `userContext` body field, byte-for-byte native:
/// `<userContext>\n\nREPORT RANGE: <TYPE> (<days> days)\n` +
/// profile text.
String buildReportUserContext(ReportSnapshot s) {
  final heightCm = (s.userHeightIn * 2.54).toStringAsFixed(1);
  final b = StringBuffer()
    ..write('Profile Stats: Age ${s.userAge}, Height ${heightCm}cm, '
        'Weight ${_floatText(s.userWeightLbs)}lbs, Gender ${s.userGender}\n');
  if (s.conditions.isNotEmpty) {
    b.write('Medical Conditions: ${s.conditions.join(', ')}\n');
  }
  if (s.medications.isNotEmpty) {
    b.write(
        'Active Medications: ${s.medications.map((m) => '${m.name} ${m.dose} (${m.frequency})').join(', ')}\n');
  }
  return '${s.userContext}\n\nREPORT RANGE: ${s.rangeTypeName} '
      '(${s.durationDays} days)\n$b';
}

double _avgI(List<(String, int)> s) =>
    s.fold<int>(0, (a, e) => a + e.$2) / s.length;
double _avgD(List<(String, double)> s) =>
    s.fold<double>(0, (a, e) => a + e.$2) / s.length;

/// The `fitbitData` health-summary string, byte-for-byte native:
/// each clause only when its series is non-empty, in native order
/// (HR, sleep, spikes, BP, calories, HRV, HRV by date, deep sleep).
/// Sleep durations here keep native's decimal-hours server format
/// ("7.1 hrs/night") — the Oct 15 compact-format ruling applies to
/// Flutter-rendered text, never to this server contract string.
String buildHealthSummary(ReportSnapshot s) {
  final b = StringBuffer();
  if (s.heartRateSeries.isNotEmpty) {
    b.write(
        'Avg Heart Rate: ${_avgI(s.heartRateSeries).toInt()} bpm across ${s.heartRateSeries.length} days. ');
  }
  if (s.sleepSeries.isNotEmpty) {
    final avgHrs = s.sleepSeries.map((e) => e.$2 / 60.0).reduce((a, c) => a + c) /
        s.sleepSeries.length;
    b.write(
        'Avg Sleep: ${avgHrs.toStringAsFixed(1)} hrs/night across ${s.sleepSeries.length} days. ');
  }
  if (s.heartRateSpikes.isNotEmpty) {
    final total = s.heartRateSpikes.fold<int>(0, (a, e) => a + e.$2);
    b.write('Total HR Spikes: $total recorded. ');
  }
  if (s.bloodPressureSeries.isNotEmpty) {
    final sys = s.bloodPressureSeries.map((e) => e.systolic).reduce((a, c) => a + c) /
        s.bloodPressureSeries.length;
    final dia = s.bloodPressureSeries.map((e) => e.diastolic).reduce((a, c) => a + c) /
        s.bloodPressureSeries.length;
    b.write(
        'Blood Pressure Avg: ${sys.toInt()}/${dia.toInt()} mmHg across ${s.bloodPressureSeries.length} readings. ');
  }
  if (s.caloriesSeries.isNotEmpty) {
    b.write(
        'Avg Calories: ${_avgI(s.caloriesSeries).toInt()} kcal/day across ${s.caloriesSeries.length} days. ');
  }
  if (s.hrvSeries.isNotEmpty) {
    b.write(
        'Avg HRV (RMSSD): ${_avgD(s.hrvSeries).toStringAsFixed(1)} ms across ${s.hrvSeries.length} days. ');
    final perDate = s.hrvSeries
        .map((e) => '${e.$1}: ${e.$2.toStringAsFixed(1)} ms')
        .join('; ');
    b.write('HRV (RMSSD) by date (sensor data): $perDate. ');
  }
  if (s.deepSleepSeries.isNotEmpty) {
    final avgHrs =
        s.deepSleepSeries.map((e) => e.$2 / 60.0).reduce((a, c) => a + c) /
            s.deepSleepSeries.length;
    b.write(
        'Avg Deep Sleep: ${avgHrs.toStringAsFixed(1)} hrs/night across ${s.deepSleepSeries.length} days. ');
  }
  return b.toString();
}

/// The anti-hallucination `dataAvailability` block: per-section
/// `Label: Available (N records)` or `Label: Unavailable`, joined
/// "; ", with native's hardcoded disambiguated labels only.
String buildDataAvailability(ReportSnapshot s) {
  return s.sectionMetadata.entries.map((e) {
    final label = switch (e.key) {
      'medications' => 'Medications (profile list)',
      'conditions' => 'Conditions (profile list)',
      'documents' => 'Documents (knowledge base)',
      _ => e.key[0].toUpperCase() + e.key.substring(1),
    };
    // Stored-only data IS available (its series is in this very
    // snapshot) — it carries the success form here, exactly as a
    // fresh-read success does; its provenance is disclosed in the
    // PDF availability list (see availabilityStatusText).
    final status = e.value.status == DataSourceStatus.success ||
            e.value.status == DataSourceStatus.storedOnly
        ? 'Available (${e.value.recordCount} records)'
        : 'Unavailable';
    return '$label: $status';
  }).join('; ');
}

/// Report-path entry serializer: identical to the sync shape
/// EXCEPT `updatedAt`, which native's report `toDto()`
/// (GeminiService) never sets — the DTO default is 0.
/// `QuickLogEntry.toSyncJson()` stamps `DateTime.now()` per entry
/// and must NOT be reused here.
Map<String, dynamic> reportEntryJson(QuickLogEntry e) => {
      'id': e.id,
      'categoryId': e.categoryId,
      'body': e.body,
      'chips': e.chips,
      'manualText': e.manualText,
      'timestamp': e.timestamp,
      'updatedAt': 0,
    };

/// Top-level cap on printed correlation insight lines in report requests.
const int correlationInsightsPrintCap = 3;

/// Formats up to [correlationInsightsPrintCap] correlation insight records
/// into ruled sentence strings using ruled builders from correlation_copy.dart.
List<String> correlationInsightPrintLines(List<InsightRecord> records) {
  final lines = <String>[];
  for (final record in records) {
    if (lines.length >= correlationInsightsPrintCap) break;
    if (record.state != InsightState.numbers) continue;

    final incidence = record.incidence;
    if (incidence != null) {
      if (record.splitId.contains('migraine')) {
        lines.add(correlationMigraineIncidenceSentence(
          x: incidence.x,
          n: incidence.n,
          y: incidence.y,
          m: incidence.m,
        ));
      } else {
        lines.add(correlationFlareIncidenceSentence(
          x: incidence.x,
          n: incidence.n,
          y: incidence.y,
          m: incidence.m,
        ));
      }
      continue;
    }

    if (record.familyId == 'F5') {
      if (record.groups.length >= 2) {
        final g0 = record.groups[0];
        final g1 = record.groups[1];
        final g0Mean = g0.mean;
        final g1Mean = g1.mean;
        // R-1 F3: a non-finite mean is skipped exactly as a null
        // mean is — _whole() rounds, and round() throws on
        // NaN/Infinity, which used to take down the whole AI leg.
        if (g0Mean != null &&
            g1Mean != null &&
            g0Mean.isFinite &&
            g1Mean.isFinite) {
          final header = record.headerLabel ?? record.subjectName;
          final prefix = header != null ? '$header: ' : '';
          lines.add(
            '$prefix$medWindowBeforeLabel ${medWindowValue(g0Mean, g0.n)} \u00B7 $medWindowAfterLabel ${medWindowValue(g1Mean, g1.n)}',
          );
        }
      }
      continue;
    }

    if (record.groups.length >= 2) {
      final g0 = record.groups[0];
      final g1 = record.groups[1];
      final g0Mean = g0.mean;
      final g1Mean = g1.mean;
      // R-1 F3: non-finite means skipped exactly as nulls (above).
      if (g0Mean != null &&
          g1Mean != null &&
          g0Mean.isFinite &&
          g1Mean.isFinite) {
        lines.add(correlationComparisonSentence(
          groupALabel: g0.label,
          groupAN: g0.n,
          groupAMean: g0Mean,
          groupBLabel: g1.label,
          groupBN: g1.n,
          groupBMean: g1Mean,
        ));
      }
    }
  }
  return lines;
}

/// The full `POST /api/ai/report` body (native `AiRequest` shape on
/// the snapshot path: entries, categories, userContext,
/// knowledgeBase, fitbitData, dataAvailability).
///
/// VC 100131 (Round 3): [reportGenerationId] — the generation's
/// stable wire identity (see report_generation_journal.dart) —
/// rides as one additional body field when present, on EVERY
/// attempt of the logical generation (in-leg retries and the
/// decision resume included: the pipeline builds each attempt's
/// body through this one function). Absent (null/empty), the
/// body is byte-for-byte the legacy shape and the server runs
/// the legacy path. NOTE (verified at the VC 100130 head): this
/// is the ONLY request-construction site in the Flutter tree —
/// the clinician pipeline makes no /report call at all (its
/// clinician_report_test fixtures assert aiCalls == 0), so the
/// clinician generation path carries the identity through the
/// generation journal instead (service-level, kind 'clinician').
/// VC 100132 (Round 4, Problem 1) — the structured profile
/// medications channel the server guard expects (jot-server
/// `src/routes/ai.js` `normalizeProfileMedications` + its
/// report_medications tests): an array of
/// `{name, dose, frequency, startDate, endDate, archived}` carrying
/// current AND discontinued entries. The source is the snapshot's
/// full profile list ([ReportSnapshot.profileMedications]); a
/// snapshot built without it falls back to its active list.
/// Deleted rows never travel. `frequency` is the entry's display
/// frequency (blank raw reads 'Once daily', the app's own pinned
/// view — medications.dart), so a blank never reaches the guard
/// as an empty frequency the model could refill from logs.
List<Map<String, dynamic>> structuredProfileMedications(ReportSnapshot s) {
  final source =
      s.profileMedications.isNotEmpty ? s.profileMedications : s.medications;
  return [
    for (final m in source)
      if (!m.isDeleted)
        {
          'name': m.name,
          'dose': m.dose,
          'frequency': m.frequency,
          'startDate': m.startDate,
          'endDate': m.endDate,
          'archived': m.isArchived,
        },
  ];
}

Map<String, dynamic> buildAiReportRequest(ReportSnapshot s,
    {String? reportGenerationId}) {
  final kb = s.knowledgeDocuments.join('\n\n');
  final availability = buildDataAvailability(s);
  final insightLines = s.correlationInsightsLoadFailed
      ? null
      : correlationInsightPrintLines(s.correlationInsights);
  final correlationInsights =
      (insightLines == null || insightLines.isEmpty)
          ? null
          : insightLines.join('\n');
  return {
    'entries': s.logEntries.map(reportEntryJson).toList(),
    'categories': {
      for (final e in s.categoriesMap.entries) '${e.key}': e.value,
    },
    'userContext': buildReportUserContext(s),
    'knowledgeBase': kb.trim().isEmpty ? null : kb,
    'fitbitData': buildHealthSummary(s),
    'dataAvailability': availability.isEmpty ? null : availability,
    // VC 100132: the structured medications channel (own field,
    // per the server contract — before this, the payload carried
    // medications ONLY as prose inside userContext, so the
    // server's structured guard never engaged:
    // medicationsStructured=false, medCurrentCount=0 on the
    // founder's VC 100131 report, and the narrative took doses /
    // frequencies from logs instead).
    'medications': structuredProfileMedications(s),
    'correlation_insights': correlationInsights,
    if (reportGenerationId != null && reportGenerationId.isNotEmpty)
      'reportGenerationId': reportGenerationId,
  };
}

// ── AI failure classification (AiFailureReasons.kt port, Phase 3) ──

/// The ONE classification of an AI attempt outcome (Report
/// Generation Reliability Phase 3). Every AI attempt outcome
/// classifies into exactly one class, and BOTH the retry policy
/// (retryable? / max attempts / backoff) and the recorded
/// user-facing reason read from that single classification —
/// [AiFailure] derives all of them from [AiFailure.failureClass]
/// and nothing else.
///
/// The pre-Phase-3 mapping let the two diverge, with named
/// consequences: an HTTP 200 whose body lacked a string `result`
/// was fatal (1 attempt) because only the status was classified;
/// HTTP 429 was fatal although its own reason text said "try
/// again later"; a missing session burned 4 futile connection-
/// class attempts because the retry class never read the
/// no-session signal; and an unclassified throw retried as a
/// connection failure while reporting "unknown error". A stale-
/// token 401 (curable by the shared backend client's refresh —
/// see tabs_backend.dart) and a client-side timeout were likewise
/// flattened into other classes. Each class below is one of those
/// cases, made first-class.
enum AiFailureClass {
  /// The server was reached and failed us: an HTTP 5xx, or an
  /// HTTP 200 whose body lacks a string `result` (a malformed
  /// success is a server failure, never a request failure).
  /// Retryable, 2 attempts.
  server,

  /// HTTP 429 — the server explicitly asked us to slow down; its
  /// own reason text has always said "try again later", and now
  /// the retry policy agrees. Retryable, 2 attempts.
  rateLimited,

  /// A request was attempted, no HTTP response arrived, and the
  /// attempt did not time out (socket/DNS/TLS/client failure).
  /// This is the ONLY class whose reason may say "no connection"
  /// (Juno Ruling 3). Retryable, 4 attempts, exponential backoff
  /// (native parity).
  connection,

  /// The CLIENT abandoned the attempt: the pipeline's per-attempt
  /// timeout fired, or the backend transport's own timeout did —
  /// both classify identically, and neither is a connection
  /// failure (the Nov 9, 2026 incident: the server generated the
  /// full narrative while the client had already walked away).
  /// Retryable, 2 attempts — a full timeout window has already
  /// been spent per attempt, so the budget is deliberately
  /// smaller than the connection class's.
  timeout,

  /// The session cannot authenticate this call: no stored session
  /// at all, or an HTTP 401 that reached the pipeline — which is
  /// by construction a POST-refresh 401 (or a failed refresh),
  /// because [TabsBackend.postAiDetailed] routes through the
  /// shared `_sendAuthedDetailed`, which refreshes once and
  /// retries before ever surfacing a 401. Fatal, 1 attempt:
  /// retrying cannot mint a session.
  session,

  /// Any other HTTP status actually received (a non-401/429 4xx):
  /// the request itself was rejected. Fatal, 1 attempt.
  fatalRequest,

  /// The attempt threw (or returned) something no signal
  /// classifies. Its own class: it does NOT retry under the
  /// connection class while reporting "unknown error" (the
  /// pre-Phase-3 divergence). Fatal, 1 attempt — an unclassified
  /// failure gets its honest failure surface immediately rather
  /// than silently burning attempts under a guessed class.
  unknown,

  /// VC 100129 (R-1 F2): the attempt failed BEFORE dispatch —
  /// the request was never sent (the body could not be encoded,
  /// or the stored session token could not be read). It is NOT
  /// a connection failure: no network was involved. Fatal,
  /// 1 attempt. Juno R5-7's surface label for this class is
  /// "Could not start the request in the app".
  preDispatch,
}

/// One attempt-outcome classification: the raw signals of a single
/// AI attempt, classified ONCE into [failureClass], from which the
/// retry policy and the plain-language reason both derive. Only
/// the HTTP status and the transport signals are ever read —
/// server/exception text never reaches the UI or the PDF.
class AiFailure {
  final int? httpStatus;

  /// True when a request was actually attempted, no HTTP response
  /// arrived, and the attempt did not time out (Juno Ruling 3:
  /// `no connection` is ONLY this case — never a default for
  /// unclassified failures, and timeout takes precedence).
  final bool noResponse;

  /// True when the attempt itself timed out before any response
  /// (the pipeline's per-attempt guard, or the backend transport's
  /// own timeout — both classify identically).
  final bool timedOut;

  /// True when no request was attempted because there is no stored
  /// session (Juno Ruling 3: a local no-token failure must never be
  /// labelled "no connection").
  final bool noSession;

  /// True when an HTTP response arrived (200) but its body lacks
  /// a string `result` or its result is an empty or whitespace-only
  /// string: a malformed success, classified
  /// [AiFailureClass.server].
  final bool missingResult;

  /// True when the attempt's outcome matched no other signal (the
  /// call threw, or returned a responseless, signalless result).
  final bool unclassified;

  /// True when the attempt failed before dispatch (R-1 F2):
  /// the request was never built or never sent for a local
  /// reason (encode failure, token-read failure).
  final bool preDispatch;

  const AiFailure(
      {this.httpStatus,
      this.noResponse = false,
      this.timedOut = false,
      this.noSession = false,
      this.missingResult = false,
      this.unclassified = false,
      this.preDispatch = false});

  /// THE classification. Precedence is by signal strength: a
  /// timeout is a timeout even when nothing came back; a missing
  /// session means no request was attempted at all; a received
  /// status outranks transport inference; a malformed 200 is a
  /// server outcome; only a genuinely attempted, unanswered,
  /// untimed-out request is a connection failure; anything left
  /// is honestly [AiFailureClass.unknown].
  AiFailureClass get failureClass {
    if (timedOut) return AiFailureClass.timeout;
    if (preDispatch) return AiFailureClass.preDispatch;
    if (noSession) return AiFailureClass.session;
    final code = httpStatus;
    if (code != null) {
      if (code == 401) return AiFailureClass.session;
      if (code == 429) return AiFailureClass.rateLimited;
      if ('$code'.startsWith('5')) return AiFailureClass.server;
      if (code == 200 && missingResult) return AiFailureClass.server;
      return AiFailureClass.fatalRequest;
    }
    if (missingResult) return AiFailureClass.server;
    if (noResponse) return AiFailureClass.connection;
    return AiFailureClass.unknown;
  }

  bool get retryable => switch (failureClass) {
        AiFailureClass.server ||
        AiFailureClass.rateLimited ||
        AiFailureClass.connection ||
        AiFailureClass.timeout =>
          true,
        AiFailureClass.session ||
        AiFailureClass.fatalRequest ||
        AiFailureClass.unknown ||
        AiFailureClass.preDispatch =>
          false,
      };

  int get maxAttempts => switch (failureClass) {
        AiFailureClass.connection => 4,
        AiFailureClass.server ||
        AiFailureClass.rateLimited ||
        AiFailureClass.timeout =>
          2,
        AiFailureClass.session ||
        AiFailureClass.fatalRequest ||
        AiFailureClass.unknown ||
        AiFailureClass.preDispatch =>
          1,
      };

  Duration backoffAfter(int completedAttempt) => switch (failureClass) {
        AiFailureClass.connection =>
          Duration(milliseconds: 2000 * (1 << (completedAttempt - 1).clamp(0, 10))),
        AiFailureClass.server ||
        AiFailureClass.rateLimited ||
        AiFailureClass.timeout =>
          const Duration(seconds: 2),
        AiFailureClass.session ||
        AiFailureClass.fatalRequest ||
        AiFailureClass.unknown ||
        AiFailureClass.preDispatch =>
          Duration.zero,
      };

  /// Juno Ruling 3's closed set, derived from the SAME single
  /// classification as the retry policy above — never from server
  /// error text or exception messages.
  String get plainReason => switch (failureClass) {
        AiFailureClass.timeout => 'network timeout',
        AiFailureClass.session => httpStatus == 401
            ? 'HTTP 401 (signed out?)'
            : 'not signed in',
        AiFailureClass.rateLimited => 'HTTP 429 (try again later)',
        AiFailureClass.server => httpStatus == null
            ? 'unknown error'
            : '$httpStatus'.startsWith('5')
                ? 'HTTP $httpStatus (server error)'
                : 'HTTP $httpStatus (request failed)',
        AiFailureClass.fatalRequest => 'HTTP $httpStatus (request failed)',
        AiFailureClass.connection => 'no connection',
        AiFailureClass.unknown => 'unknown error',
        AiFailureClass.preDispatch =>
          'could not start the request in the app',
      };
}

/// One recorded AI attempt (Phase 3, item 2): every attempt of a
/// generation — including client-side classes that never reach
/// the server (timeout, no-route) — is recorded on the outcome
/// the [ReportGenerationService] holds, so a failed generation is
/// inspectable after the fact instead of invisible. Generation-
/// scoped: the record rides the held outcome/failure, it is not
/// a persistent analytics store.
class AiAttemptRecord {
  /// 1-based attempt number, continuous across a held decision's
  /// retry (the retry's attempts continue the sequence).
  final int attempt;

  /// The single classification of this attempt; null on success.
  final AiFailureClass? failureClass;

  /// The HTTP status actually received, when one arrived.
  final int? httpStatus;

  final bool succeeded;

  /// When the attempt settled (the pipeline's clock).
  final DateTime at;

  const AiAttemptRecord({
    required this.attempt,
    required this.failureClass,
    required this.httpStatus,
    required this.succeeded,
    required this.at,
  });
}

/// Which raw-report banner a shipped raw PDF carries (Phase 3,
/// Juno's Phase 3 ruling strings 5/5b). The two states are
/// mutually exclusive and are selected by the state recorded at
/// ship time: a user who explicitly chose the data-only report
/// gets the choice banner; a raw report that ships WITHOUT that
/// decision (a fatal-class failure's raw fallback) gets the
/// failure banner. The rejected
/// cause-asserting suffix appears in neither.
enum RawReportBanner {
  /// "RAW DATA REPORT: DATA ONLY, NO AI ANALYSIS" /
  /// "You chose to make this report without AI analysis."
  explicitChoice,

  /// "RAW DATA REPORT: AI ANALYSIS UNAVAILABLE AT GENERATION
  /// TIME" / "AI analysis could not be completed."
  noChoiceFailure,
}

/// Juno's ruled decision-surface strings (Phase 3 ruling,
/// byte-exact — verified against the ruling by byte comparison,
/// never retyped from memory; see
/// report_ai_reliability_phase3_test.dart).
const aiDecisionTitle = "AI analysis couldn't be completed";
const aiDecisionBody =
    'Your data is safe, and the report data is ready. The AI analysis could not be completed. You can try the analysis again, or make the report with the data only and no AI analysis.';
const aiDecisionRetryLabel = 'Try AI analysis again';
const aiDecisionRawLabel = 'Make report without AI analysis';

// ── Raw fallback summary (ReportGenerator.kt, byte format) ────────

/// The fallback summary text native renders when the AI summary is
/// unavailable, EXACTLY as `ReportGenerator.generateReport` builds
/// it. Founder delta (Oct 15/16): Flutter-composed report text
/// renders sleep durations with the shared compact `7h6m` formatter;
/// native's fallback text contains no sleep duration, so this
/// string stays byte-identical to native. AI prose is never
/// post-edited, and the request's health-summary string keeps
/// native's decimal-hours server format.
String buildRawFallbackSummary(ReportSnapshot s) {
  final conditions =
      s.conditions.isNotEmpty ? s.conditions.join(', ') : 'None listed';
  final meds = s.medications.isNotEmpty
      ? s.medications.map((m) => '${m.name} ${m.dose}').join(', ')
      : 'None listed';
  return '[SECTION] RAW CLINICAL LOG SUMMARY\n'
      '[BOLD]Notice:[BOLD] AI summary generation was unavailable or non-responsive. '
      'The following report compiles raw longitudinal patient entries and measured biometrics snapshot directly.\n\n'
      '[SECTION] PATIENT OVERVIEW\n'
      '• Total Recorded Entries: ${s.logEntries.length}\n'
      '• Active Conditions: $conditions\n'
      '• Active Medications: $meds';
}

/// Friendly EXPORT banner (native `FriendlyErrors` Kind.EXPORT).
const reportExportFailureMessage =
    'Could not create your PDF. The report could not be generated. Your data is safe and nothing was deleted.';

// ── Data collector (ClinicalReportDataCollector.kt port) ──────────

/// Profile inputs for the collector, in Flutter's stored units
/// (the Settings pull: age, heightCm, weightKg, gender, userContext,
/// conditions blob, medications blob). The collector converts to
/// native's stored units (inches / lbs) for the snapshot.
class ReportProfileInput {
  final String userContext;
  final int age;
  final double heightCm;

  /// Weight in KILOGRAMS as the Flutter profile stores it.
  final double weightKg;
  final String gender;
  final List<String> conditions;
  final List<MedicationEntry> activeMedications;

  /// Phase 1, item 3 — the FULL parsed medication list (active +
  /// archived), used ONLY by the clinician report's declared-form
  /// medication-changes derivation (declared start/end strings).
  /// The v1 pipeline never reads it, and the clinician Z2 list
  /// still prints [activeMedications] through the collector's
  /// double filter — this field weakens no R5 gate.
  final List<MedicationEntry> allMedications;

  const ReportProfileInput({
    this.userContext = '',
    this.age = 0,
    this.heightCm = 0,
    this.weightKg = 0,
    this.gender = '',
    this.conditions = const [],
    this.activeMedications = const [],
    this.allMedications = const [],
  });

  double get heightIn => heightCm <= 0 ? 0 : heightCm / 2.54;
  double get weightLbs => weightKg <= 0 ? 0 : weightKg * 2.20462;
}

/// Collects the report snapshot. All sources are injectable for
/// tests; production wires [TabsBackend] + [HealthConnectService].
/// Thrown by [ReportDataCollector.collect] when the caller's
/// cancellation signal is found set at one of the collection's
/// stage boundaries. The generation pipelines translate it into
/// the same `ReportFailed('Cancelled')` outcome their
/// post-collection check produces. (Founder report, Nov 9, 2026:
/// the Cancel button set the page's flag, but collect() never
/// received the signal, so a cancel tapped during collection —
/// above all during the Health Connect sync stage — had no
/// effect until the entire collection had run to completion.)
class ReportCollectionCancelled implements Exception {
  const ReportCollectionCancelled();
}

/// R-1 F4: collection exceeded its overall deadline. A named
/// failure (never a session-long wedge): the pipelines map it
/// to the existing export-failure outcome.
class ReportCollectionTimeout implements Exception {
  const ReportCollectionTimeout();
}

class ReportDataCollector {
  final TabsBackend backend;
  final HealthConnectService hc;

  /// R70 WS2 — the local-first union reader (store ∪ fresh HC).
  final HealthHistoryQueries historyQueries;

  /// Extracted knowledge-document texts (R65's store, wired by
  /// the page; see the file header). Defaults to no documents.
  final Future<List<String>> Function() documentsLoader;

  /// Stored correlation insight records. Defaults to reading from
  /// [CorrelationInsightStore.instance.readAllOrThrow].
  final Future<List<InsightRecord>> Function() insightsLoader;

  /// R-1 F4 — the overall collection deadline. Derivation: a
  /// legitimate collection is a sync pull (20s transport bound),
  /// entry/BP fetches on the same bound, document/insight loads,
  /// and the Health Connect union load over up to 180 days —
  /// the slowest legitimate union loads observed complete in
  /// tens of seconds. 120s clears that whole stack with
  /// headroom, while a genuinely hung read can no longer wedge
  /// the generation service (and every later Export tap) for
  /// the rest of the session.
  static const Duration defaultCollectTimeout = Duration(seconds: 120);

  final Duration collectTimeout;

  ReportDataCollector({
    TabsBackend? backend,
    HealthConnectService? hc,
    HealthHistoryQueries? historyQueries,
    Future<List<String>> Function()? documentsLoader,
    Future<List<InsightRecord>> Function()? insightsLoader,
    Duration? collectTimeout,
  }) : this._internal(
          backend ?? TabsBackend(),
          hc ?? HealthConnectService(),
          historyQueries,
          documentsLoader ?? (() async => const []),
          insightsLoader ?? _defaultInsightsLoader,
          collectTimeout ?? defaultCollectTimeout,
        );

  ReportDataCollector._internal(
    this.backend,
    this.hc,
    HealthHistoryQueries? queries,
    this.documentsLoader,
    this.insightsLoader,
    this.collectTimeout,
  ) : historyQueries = queries ?? HealthHistoryQueries(hc: hc);

  static Future<List<InsightRecord>> _defaultInsightsLoader() async =>
      (await CorrelationInsightStore.instance.readAllOrThrow()).values.toList();

  Future<ReportSnapshot> collect({
    required List<QuickLogCategory> selectedCategories,
    required bool last30Days,
    required ReportProfileInput profile,
    void Function(String stage)? onStage,
    bool Function()? isCancelled,
    DateTime? now,
  }) {
    // R-1 F4: the whole collection runs under one deadline; a
    // timeout surfaces as the named [ReportCollectionTimeout],
    // never as a hung future.
    return _collectInner(
      selectedCategories: selectedCategories,
      last30Days: last30Days,
      profile: profile,
      onStage: onStage,
      isCancelled: isCancelled,
      now: now,
    ).timeout(collectTimeout,
        onTimeout: () => throw const ReportCollectionTimeout());
  }

  Future<ReportSnapshot> _collectInner({
    required List<QuickLogCategory> selectedCategories,
    required bool last30Days,
    required ReportProfileInput profile,
    void Function(String stage)? onStage,
    bool Function()? isCancelled,
    DateTime? now,
  }) async {
    // Cancellation is honored at the collection's stage
    // boundaries: on entry, before the documents stage, and
    // before the Health Connect block (the long 'syncing'
    // stage). A cancel that lands inside a stage takes effect
    // at the next boundary — in-flight reads are never torn
    // down mid-flight.
    void throwIfCancelled() {
      if (isCancelled?.call() ?? false) {
        throw const ReportCollectionCancelled();
      }
    }

    final n = now ?? DateTime.now();
    final nowMs = n.millisecondsSinceEpoch;
    final daysToFetch = last30Days ? 31 : 180;
    final cutoff = last30Days ? nowMs - 30 * 24 * 60 * 60 * 1000 : 0;
    final metadata = <String, SectionMetadata>{};
    void meta(String key, DataSourceStatus status, int count) =>
        metadata[key] = SectionMetadata(key, status, count);

    onStage?.call('collecting');
    throwIfCancelled();

    // Backend sections (native sections 1–6). The Flutter backend's
    // fetch layer folds transport failures into empty results, so a
    // null sync pull is the one detectable failure signal: it maps
    // every backend section to ERROR, exactly the honest outcome.
    final pull = await backend.fetchSyncPull();
    final pullFailed = pull == null;

    // 1. Logs — native: range query for This Month; the most recent
    // 2000 for All Time. NOT filtered by category (native's DAO
    // range query has no category filter; the selection restricts
    // only the categories map sent to the AI).
    var entries = await backend.fetchLogEntryDtos();
    if (last30Days) {
      entries = entries.where((e) => e.timestamp >= cutoff).toList();
    } else {
      entries = entries.toList()
        ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
      if (entries.length > 2000) entries = entries.sublist(0, 2000);
    }
    meta('logs', pullFailed ? DataSourceStatus.error : DataSourceStatus.success,
        entries.length);

    // 2. Daily score.
    meta(
        'dailyScore',
        pullFailed ? DataSourceStatus.error : DataSourceStatus.success,
        0);

    // 3. Conditions (profile list).
    meta(
        'conditions',
        pullFailed ? DataSourceStatus.error : DataSourceStatus.success,
        profile.conditions.length);

    // 4. Medications — ACTIVE only under the shared R39 model's
    // own filter: not deleted and not archived
    // (`!isDeleted && !isArchived`, where isArchived is the
    // explicit stamp OR `!isPresent` — medications.dart). Applied
    // HERE as well as at the page's profile-input build, so a
    // caller that hands the collector an unfiltered list still
    // cannot leak an archived/deleted row into the snapshot, and
    // the Data Availability count below counts this same filtered
    // list (Juno Ruling 1).
    final activeMedications =
        activeMedicationEntries(profile.activeMedications);
    meta(
        'medications',
        pullFailed ? DataSourceStatus.error : DataSourceStatus.success,
        activeMedications.length);

    // VC 100132 (Problem 1): the full profile list for the
    // structured payload channel — active + archived, deleted
    // excluded. Source is the profile input's full parsed list;
    // a caller that supplied only the active list degrades to
    // exactly that list (never an invented discontinued set).
    final profileMedications = [
      for (final m
          in (profile.allMedications.isNotEmpty
              ? profile.allMedications
              : profile.activeMedications))
        if (!m.isDeleted) m,
    ];

    throwIfCancelled();

    // 5. Knowledge documents.
    List<String> docs = const [];
    var docsFailed = false;
    try {
      docs = (await documentsLoader())
          .where((t) => t.trim().isNotEmpty)
          .toList();
    } catch (_) {
      docsFailed = true;
    }
    meta(
        'documents',
        docsFailed ? DataSourceStatus.error : DataSourceStatus.success,
        docs.length);

    List<InsightRecord> correlationInsights = const [];
    var correlationInsightsLoadFailed = false;
    try {
      correlationInsights = await insightsLoader();
    } catch (_) {
      correlationInsights = const [];
      correlationInsightsLoadFailed = true;
    }

    // 6. Blood pressure — manual logs filtered to range. Server BP
    // storage was dropped on push/pull as of R62; per Juno Phase 4
    // ruling B19, status is error since deprecated storage cannot
    // establish that the patient recorded nothing.
    final allBp = await backend.fetchManualBpLogs();
    final bp = allBp
        .where((r) => !last30Days || r.timeEpochMs >= cutoff)
        .map((r) => ReportBpRecord(r.systolic, r.diastolic, r.timeEpochMs))
        .toList();
    meta('bloodPressure', DataSourceStatus.error, bp.length);

    // 7. Health Connect sections.
    onStage?.call('syncing');
    // The boundary that matters most: a cancel requested during
    // the backend stages above stops the generation BEFORE the
    // Health Connect union load — the longest stage — starts.
    throwIfCancelled();

    List<(String, int)> sleep = const [];
    List<(String, int)> deep = const [];
    List<(String, int)> calories = const [];
    List<(String, int)> spikes = const [];
    List<(String, int)> hr = const [];
    List<(String, double)> hrv = const [];

    // Report availability truth (Phase 1): there is NO
    // isConnected() gate here. That gate flattened every failure
    // of the 15-permission all-granted check — a partial grant
    // missing a permission no report reads (e.g. Steps), or a
    // stale Steps probe — into a blanket permissionDenied for all
    // six sections without attempting a read or consulting the
    // history store. The union load ALWAYS runs and the store is
    // always consulted; each section's status below is derived
    // from that metric's own evidence.
    //
    // R70 WS2 — ONE union load for the whole HC block: store ∪
    // fresh HC over the requested window, every metric. The
    // union's maps are already zero-filtered (founder rule; a 0
    // spike count stays — it is a real sampled day), and the
    // series + availability counts below are built from them
    // exactly as they were built from the raw bridge reads, so
    // the counts are the UNION's honest day counts.
    // VC 100130 (Round 2 root-cause fix): the union load is
    // BOUNDED. Before this fix the five sequential bridge reads
    // were individually unbounded, so on founder-scale data their
    // sum crossed the 120 s F4 collection deadline and the report
    // failed with ReportCollectionTimeout before any AI attempt
    // existed (see ~/workspace/mega-100127/round2-mason-repro.md).
    // Now: each read is capped at the HC service's own 30 s
    // readTimeout (a wedged read fails its metric solo and the
    // union falls back to store data for it), the union carries a
    // 90 s soft budget (later loaders are skipped once it is
    // exhausted, surfacing as failed metrics over store data),
    // and the fresh HC scan is capped at 42 days. The report
    // window stays 180 days of STORE data; only the fresh HC scan
    // is capped — HC retention is weeks, the store carries the
    // rest. Arithmetic: the heavy-band founder model scaled to a
    // 42-day scan is spikes ≈18 s + HRV ≈22 s + sleep ≈7 s +
    // resting HR ≈3 s + calories ≈2 s ≈ 52 s total, every read
    // under 30 s and the sum under the 90 s budget, so a healthy
    // heavy collect completes fresh; one wedged read costs 30 s
    // solo; five wedged reads return from the union by ~90 s —
    // all inside the 120 s F4 deadline. The clinician pipeline
    // shares this collector, so it inherits all three bounds.
    final union = await historyQueries.loadDays(
      daysToFetch,
      end: n,
      metrics: HistoryMetric.values.toSet(),
      readTimeout: HealthConnectService.readTimeout,
      unionBudget: const Duration(seconds: 90),
      maxFetchDays: 42,
    );

    // Phase 2 (§2/§3): the per-metric grant evidence comes from
    // ONE probeAvailability() snapshot per collect — fetched
    // lazily (only a metric whose fresh read failed with no
    // surviving data needs it, exactly where Phase 1 fetched its
    // missing set) and at most once. When the snapshot's grant
    // layer is UNKNOWN (its bridge read errored), the missing set
    // is null and the affected metrics fall back to error rather
    // than claiming a denial or a stale grant — Phase 1's
    // stale-masking semantics, preserved exactly.
    Future<HcAvailability>? availabilitySnapshot;
    Future<HcAvailability> loadAvailability() =>
        availabilitySnapshot ??= hc.probeAvailability();

    // Per-metric availability from real evidence, through the ONE
    // shared derivation ([deriveMetricStatus] — Phase 1's decision
    // order, unchanged):
    // - PARTIAL fresh read → error (B-02, preserved exactly: a
    //   partial read never derives its status from emptiness, and
    //   the surviving series is still collected).
    // - FAILED fresh read with surviving series data → storedOnly:
    //   a failed read contributes no fresh rows, so the data the
    //   union yields came from the history store.
    // - FAILED fresh read, no data → permissionDenied only when
    //   the snapshot's missing set contains a permission THIS
    //   metric actually reads ([reportMetricPermissions], via
    //   [hcMetricGrantState]); stale when the metric's grant is
    //   present but its own read's failure detail names a
    //   SecurityException; otherwise error.
    // - Clean read → success / noData from emptiness, now truthful
    //   because a read actually happened.
    Future<DataSourceStatus> hcStatus(
        HistoryMetric metric, bool isEmpty) async {
      if (!union.failed(metric) || !isEmpty) {
        // The partial / storedOnly / clean outcomes never consult
        // the grant layer (Phase 1's order): derive directly.
        return deriveMetricStatus(
          grant: HcMetricGrantState.unknown,
          partialRead: union.partial(metric),
          readFailed: union.failed(metric),
          readSecurityException: union.failedWithSecurityException(metric),
          unionHasData: !isEmpty,
        );
      }
      final availability = await loadAvailability();
      final missing =
          availability.grantKnown ? availability.missingPermissions : null;
      return deriveMetricStatus(
        grant: hcMetricGrantState(metric, missing),
        partialRead: union.partial(metric),
        readFailed: union.failed(metric),
        readSecurityException: union.failedWithSecurityException(metric),
        unionHasData: !isEmpty,
      );
    }

    sleep = [
      for (final e in union.sleepMinutes.entries) (e.key, e.value),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    deep = [
      for (final e in union.deepSleepMinutes.entries) (e.key, e.value),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    meta('sleep', await hcStatus(HistoryMetric.sleep, sleep.isEmpty),
        sleep.length);
    // deepSleep mirrors sleep's evidence (one read, one grant —
    // Juno's Phase 1 ruling §3), with its own emptiness/count.
    meta('deepSleep', await hcStatus(HistoryMetric.sleep, deep.isEmpty),
        deep.length);

    hr = [
      for (final e in union.restingHr.entries) (e.key, e.value),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    meta('heartRate', await hcStatus(HistoryMetric.restingHr, hr.isEmpty),
        hr.length);

    hrv = [
      for (final e in union.hrv.entries) (e.key, e.value),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    meta('hrv', await hcStatus(HistoryMetric.hrv, hrv.isEmpty), hrv.length);

    calories = [
      for (final e in union.calories.entries) (e.key, e.value),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    meta('calories', await hcStatus(HistoryMetric.calories, calories.isEmpty),
        calories.length);

    spikes = [
      for (final e in union.spikes.entries) (e.key, e.value),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    meta('hrSpikes', await hcStatus(HistoryMetric.spikes, spikes.isEmpty),
        spikes.length);

    // Re-key into the collector's canonical section order (the
    // metadata map above is filled in completion order).
    final ordered = <String, SectionMetadata>{};
    for (final key in const [
      'logs', 'dailyScore', 'conditions', 'medications', 'documents', 'bloodPressure',
      'sleep', 'deepSleep', 'heartRate', 'hrv', 'calories', 'hrSpikes',
    ]) {
      final m = metadata[key];
      if (m != null) ordered[key] = m;
    }

    return ReportSnapshot(
      last30Days: last30Days,
      generationTimestampMs: nowMs,
      logEntries: entries,
      categoriesMap: {for (final c in selectedCategories) c.id: c.name},
      userContext: profile.userContext,
      userAge: profile.age,
      userHeightIn: profile.heightIn,
      userWeightLbs: profile.weightLbs,
      userGender: profile.gender,
      conditions: profile.conditions,
      medications: activeMedications,
      profileMedications: profileMedications,
      knowledgeDocuments: docs,
      heartRateSeries: hr,
      sleepSeries: sleep,
      deepSleepSeries: deep,
      caloriesSeries: calories,
      hrvSeries: hrv,
      heartRateSpikes: spikes,
      bloodPressureSeries: bp,
      sectionMetadata: ordered,
      correlationInsights: correlationInsights,
      correlationInsightsLoadFailed: correlationInsightsLoadFailed,
    );
  }
}

// ── Generation pipeline (LogRepository snapshot path port) ────────

enum ReportStage { collecting, syncing, buildingSummary, renderingPdf, savingFile }

/// VC 100130 (Round 2): the diagnostic classification of a failed
/// generation — WHICH stage family produced the failure. Recorded
/// on [ReportFailed] by the pipelines, persisted by the generation
/// journal (failureKindName / failureStageName), and surfaced to
/// the user only through Juno's ruled plain-language line (see
/// report_generation_journal.dart) — the raw kind/stage names are
/// diagnostic record, never UI copy.
enum ReportFailureKind {
  collectionTimeout,
  collectionFailure,
  renderFailure,
  saveFailure,
}

const reportStageLabels = <ReportStage, String>{
  ReportStage.collecting: 'Collecting patient data...',
  ReportStage.syncing: 'Syncing health metrics...',
  ReportStage.buildingSummary: 'Generating AI clinical summary...',
  ReportStage.renderingPdf: 'Rendering charts and PDF document...',
  ReportStage.savingFile: 'Saving PDF file...',
};

sealed class ReportOutcome {
  const ReportOutcome();
}

class ReportReady extends ReportOutcome {
  final ReportSnapshot snapshot;

  /// The PDF bytes + file name; null summary means raw fallback.
  final List<int> pdfBytes;
  final String fileName;
  final String savedPath;
  final bool isRawFallback;
  final String? aiFailureReason;

  /// Which banner the raw PDF carries (Phase 3): set exactly when
  /// [isRawFallback] is true — the user's explicit choice vs. a
  /// no-choice failure ship, recorded at ship time.
  final RawReportBanner? rawBanner;

  /// The generation's AI attempt history (Phase 3): every attempt
  /// made for this report, including the failed attempts a held
  /// decision's successful retry followed. Empty when no AI leg
  /// ran (forced raw, clinician report).
  final List<AiAttemptRecord> aiAttempts;

  /// Whether the automatic Downloads copy of these exact bytes
  /// landed (Juno Ruling 2: the attempt finishes before the share
  /// confirmation is shown and its outcome is carried here). Null
  /// when no Downloads attempt was wired for this generation.
  final bool? downloadsSaved;

  /// VC 100131: the server's `completedAt` (epoch ms) when this
  /// report's narrative was collected by PICKUP — carried to the
  /// journal's terminal record (heldCompletedAtMs) by the
  /// service. Never displayed (Juno silent pickup).
  final int? heldCompletedAtMs;
  const ReportReady({
    required this.snapshot,
    required this.pdfBytes,
    required this.fileName,
    required this.savedPath,
    required this.isRawFallback,
    this.aiFailureReason,
    this.rawBanner,
    this.aiAttempts = const [],
    this.downloadsSaved,
    this.heldCompletedAtMs,
  });
}

class ReportFailed extends ReportOutcome {
  final String message;
  final bool allowRawFallback;
  final ReportSnapshot? snapshot;

  /// The generation's AI attempt history (Phase 3), when the
  /// failure came from the AI leg.
  final List<AiAttemptRecord> aiAttempts;

  /// The final AI classification's plain reason (Phase 3), when
  /// the failure came from the AI leg.
  final String? aiFailureReason;

  /// The banner a raw ship reached from THIS failure carries
  /// (Phase 3): a fatal AI class's raw fallback is a no-choice
  /// failure ship; other failures (export/render) leave the raw
  /// ship to the user's explicit tap, which is a choice.
  final RawReportBanner rawFallbackBanner;

  /// VC 100130 diagnostic record: the failure's classification
  /// and the pipeline stage that produced it, when the producer
  /// knows them. Null for failures outside the classified
  /// producers (AI-leg failures carry their own Phase 3 records;
  /// [ReportAiDecision] is unaffected and leaves both null).
  final ReportFailureKind? failureKind;
  final ReportStage? failureStage;

  const ReportFailed(this.message,
      {this.allowRawFallback = false,
      this.snapshot,
      this.aiAttempts = const [],
      this.aiFailureReason,
      this.rawFallbackBanner = RawReportBanner.explicitChoice,
      this.failureKind,
      this.failureStage});
}

/// The held AI-failure decision (Phase 3): the AI leg exhausted a
/// RETRYABLE class, so NO PDF ships and no notification fires —
/// the generation holds on the service as a failure until the
/// user decides: retry ONLY the AI analysis on the already-
/// collected data ([ReportAiDecision.resume] with retryAi true),
/// or make the data-only report as their explicit choice
/// (retryAi false). Juno's ruled surface (title/body/buttons) is
/// [aiDecisionTitle] / [aiDecisionBody] / [aiDecisionRetryLabel] /
/// [aiDecisionRawLabel]; [message] carries the final
/// classification's plain reason for the existing failure
/// plumbing, never as decision-surface copy.
class ReportAiDecision extends ReportFailed {
  /// The final attempt's single classification.
  final AiFailureClass failureClass;

  /// The continuation, built by the pipeline with the generation's
  /// render/save/Downloads callbacks captured: re-runs ONLY the
  /// AI leg (retryAi) on the held snapshot, or renders the raw
  /// report with the explicit-choice banner — never re-collects.
  /// Driven through [ReportGenerationService.resumeAiDecision],
  /// so the resumed run keeps the service's stage/cancel/hold
  /// lifecycle.
  final Future<ReportOutcome> Function({
    required bool retryAi,
    required void Function(ReportStage stage) onStage,
    required bool Function() isCancelled,
  }) resume;

  ReportAiDecision({
    required String failureReason,
    required this.failureClass,
    required List<AiAttemptRecord> attempts,
    required ReportSnapshot snapshot,
    required this.resume,
  }) : super(
          failureReason,
          allowRawFallback: false,
          snapshot: snapshot,
          aiAttempts: attempts,
          aiFailureReason: failureReason,
        );
}

/// VC 100131 (Round 3) — the EXPIRED terminal outcome: a pickup
/// answered 410 (Juno R8-1). The generation FINISHED server-side
/// but its held narrative passed the 24 h ceiling and was
/// deleted, so there is nothing to render, nothing to resume,
/// and — R7-7 / R8-1 condition 4 — NO regeneration under this
/// identity: no POST, no retry, no decision surface. The
/// service journals it as outcomeKind `expired` and the page
/// presents Juno's signed expired copy; its only action starts
/// a NEW logical generation (new identity). Deliberately NOT a
/// [ReportFailed]: a failure presentation ("didn't finish")
/// would be false, and the failed path's raw-fallback affordance
/// must not attach to it.
class ReportGenerationExpired extends ReportOutcome {
  /// The generation's AI attempt history up to the pickup that
  /// discovered the expiry (the 410 itself records no attempt —
  /// it is not an attempt outcome).
  final List<AiAttemptRecord> aiAttempts;

  /// The collected snapshot, when the leg ran in-session (a
  /// restored generation's re-collect); informational only —
  /// the expired presentation never renders from it.
  final ReportSnapshot? snapshot;

  const ReportGenerationExpired({
    this.aiAttempts = const [],
    this.snapshot,
  });
}

/// The injected render step: builds the PDF bytes for a collected
/// snapshot. [rawBanner] is set exactly when [isRawFallback] is
/// true and selects which of Juno's two ruled banners the raw PDF
/// carries (see [RawReportBanner]).
typedef ReportRenderPdf = Future<List<int>> Function(
  ReportSnapshot snapshot,
  String? aiSummary, {
  required bool isRawFallback,
  RawReportBanner? rawBanner,
});

/// How one run of the AI leg ended (Phase 3): the leg is a unit
/// the decision's retry can re-run on its own, so its endings are
/// distinct from the generation's.
enum _AiLegKind { success, exhausted, fatal, cancelled, expired }

class _AiLegResult {
  final _AiLegKind kind;

  /// The AI summary (success only).
  final String? summary;

  /// The full attempt history, prior attempts included.
  final List<AiAttemptRecord> attempts;

  /// The final attempt's classification (exhausted/fatal only).
  final AiFailure? failure;

  /// VC 100131: the server's completion time when the success
  /// was collected by PICKUP (Vera Item 4 condition — journaled
  /// as heldCompletedAtMs, never displayed). Null for a
  /// POST-delivered success.
  final DateTime? heldCompletedAt;

  const _AiLegResult(this.kind,
      {this.summary,
      this.attempts = const [],
      this.failure,
      this.heldCompletedAt});
}

/// Runs the native snapshot pipeline: collect → (unless forced raw)
/// AI summary under the Phase 3 classification → render. Rendering
/// and saving are injected so tests never touch the PDF/share
/// layer.
///
/// Phase 3 (AI-leg reliability): the AI leg NEVER falls back to a
/// silent raw ship. Its endings are: success (render the AI
/// report); a FATAL class (the honest failure surfaces through
/// the existing failure path, raw only via the user's fallback
/// tap); exhaustion of a RETRYABLE class (the generation HOLDS as
/// a [ReportAiDecision] — no PDF, no notification — until the
/// user retries the AI leg on the collected data or explicitly
/// chooses the data-only report); or cancellation.
class ReportGenerationPipeline {
  final ReportDataCollector collector;
  final TabsBackend backend;

  /// The per-attempt client timeout for the AI leg (Phase 3).
  ///
  /// Derivation: the largest supported generation (a full
  /// 180-day payload) was observed server-side completing in up
  /// to ~31s (Oct 22, 2026 evidence), and the server is being
  /// capped at ~50s per attempt with its own retries (the Phase
  /// 3 server PR), so a client attempt must comfortably exceed
  /// ONE full server attempt: 90s is 1.8× that cap and ~3× the
  /// largest observed successful generation — long enough that a
  /// healthy generation is never abandoned (the Nov 9, 2026
  /// incident: the client walked away from a generation the
  /// server completed), short enough that a dead attempt surfaces
  /// while the user is still looking at the spinner. The backend
  /// transport budget ([TabsBackend.aiRequestTimeout]) carries
  /// the same value, so whichever bound fires first, the
  /// classification is the same: [AiFailureClass.timeout].
  static const Duration aiAttemptTimeout = Duration(seconds: 90);

  /// Injected AI call (defaults to the backend's detailed POST).
  /// `transportFailure` carries the backend's classification of a
  /// no-response outcome (timeout / no-response / no-session — see
  /// [AiTransportFailure]); null when a response arrived or the
  /// outcome is unclassified.
  final Future<
      ({
        int? statusCode,
        Map<String, dynamic>? body,
        String? serverError,
        AiTransportFailure? transportFailure,
      })> Function(Map<String, dynamic> body)? aiCall;

  /// Injected backoff delay (tests pass a no-op).
  final Future<void> Function(Duration d) delay;

  /// The per-attempt timeout actually applied (test seam;
  /// production uses [aiAttemptTimeout]).
  final Duration attemptTimeout;

  /// Clock for attempt records (test seam).
  final DateTime Function() clock;

  /// VC 100129 (R-2 T1-2): invoked with the exact file name and
  /// path the moment the PDF save lands — inside the pipeline,
  /// BEFORE the ReportReady outcome exists — so the generation
  /// journal can record the artifact reference and a process
  /// death in the post-save window restores the finished report
  /// instead of orphaning the file.
  final void Function(String fileName, String savedPath)? onArtifactSaved;

  // ── VC 100131 (Round 3) — server-completion pickup ──────────

  /// Injected pickup call (defaults to the backend's pickup GET).
  /// Test seam, mirroring [aiCall].
  final Future<ReportPickupOutcome> Function(String generationId)?
      pickupCall;

  /// Where the leg reads the generation's stable wire identity
  /// (see buildAiReportRequest's note). The page wires this to
  /// the generation service, which owns the mint/reuse rule and
  /// rotates the value per start(); a generate() argument of the
  /// same name overrides it (unit tests drive it directly).
  final String? Function()? reportGenerationIdProvider;

  /// Where the leg reads whether THIS run must check pickup
  /// before its first dispatch (a resume or a restore — the
  /// service decides; a fresh start never checks, because no
  /// server row can exist for a new identity). A generate()
  /// argument overrides it. The decision-resume closure always
  /// checks, by construction.
  final bool Function()? checkPickupFirstProvider;

  /// The decision-restore pairing identity: when a restored
  /// decision's "Start a new report" starts its re-collect
  /// generation, the leg checks pickup for the RESTORED
  /// generation's identity before its first dispatch (the new
  /// generation's own identity is fresh — nothing can be held
  /// under it). A 410 on that check replaces the decision
  /// surface with the expired state (Juno R8-1).
  final String? Function()? pickupCheckIdProvider;

  /// The cancel tombstone, read at every pickup call site: while
  /// the journal entry for the current generation carries
  /// generationInvalidated, NO pickup is ever attempted for its
  /// identity (Juno R8-2 — the app never picks up and never
  /// re-POSTs a cancelled identity).
  final bool Function()? generationInvalidatedProvider;

  /// Pickup poll cadence while the server answers `running`
  /// (wire contract: every 5 s).
  final Duration pickupPollInterval;

  /// Pickup poll cap (~7 min ≈ the server generation's worst-case
  /// ceiling + slack): still running at the cap falls through to
  /// a POST dispatch, which the server's duplicate-POST matrix
  /// makes safe (waiter/serve — never a double generation).
  final Duration pickupPollCap;

  /// Poll cadence/cap defaults (production values; tests inject
  /// smaller via the constructor).
  static const Duration defaultPickupPollInterval = Duration(seconds: 5);
  static const Duration defaultPickupPollCap = Duration(minutes: 7);

  ReportGenerationPipeline({
    required this.collector,
    required this.backend,
    this.aiCall,
    Future<void> Function(Duration d)? delay,
    Duration? attemptTimeout,
    DateTime Function()? clock,
    this.onArtifactSaved,
    this.pickupCall,
    this.reportGenerationIdProvider,
    this.checkPickupFirstProvider,
    this.pickupCheckIdProvider,
    this.generationInvalidatedProvider,
    Duration? pickupPollInterval,
    Duration? pickupPollCap,
  })  : delay = delay ?? ((d) => Future.delayed(d)),
        attemptTimeout = attemptTimeout ?? aiAttemptTimeout,
        clock = clock ?? DateTime.now,
        pickupPollInterval =
            pickupPollInterval ?? defaultPickupPollInterval,
        pickupPollCap = pickupPollCap ?? defaultPickupPollCap;

  /// SINGLE-FLIGHT gate for AI report requests (Phase 3): at most
  /// one AI attempt is in flight app-wide, ever. Static for the
  /// same reason as [TabsBackend]'s shared slots: pipeline
  /// instances are minted per generation (the page builds one per
  /// Export tap, a held decision resumes through another), all
  /// over one account — a per-instance gate would guard nothing.
  /// A queued attempt fires only after the in-flight attempt has
  /// FULLY settled; a queued attempt whose generation was
  /// cancelled while it waited never fires at all.
  ///
  /// Incident trace (Nov 9, 2026): the server saw two report
  /// requests in the same second. That pair was ONE
  /// [TabsBackend.postAiDetailed] call — its first send raced an
  /// in-flight token refresh (fired with the stale token, got a
  /// 401), and its internal refresh-retry followed in the same
  /// second because the refresh had already landed; only the 401
  /// kept the first from burning a second Gemini generation. The
  /// backend now waits out an in-flight refresh before its first
  /// send (tabs_backend.dart), and this gate makes the pipeline's
  /// own guarantee independent of any caller: no second AI
  /// request fires while one is running.
  /// The in-flight attempt's slot, or null when the gate is
  /// idle. The slot exists ONLY while an attempt runs and is
  /// cleared as it settles (the [TabsBackend] slot discipline):
  /// a queued attempt awaits the CURRENT slot, never a chain of
  /// settled futures.
  static Completer<void>? _aiSlot;

  Future<T> _singleFlight<T>(
    Future<T> Function() task, {
    required bool Function() isCancelled,
  }) async {
    while (true) {
      final slot = _aiSlot;
      if (slot == null) break;
      await slot.future;
      if (isCancelled()) throw const _AiAttemptCancelled();
    }
    final mine = Completer<void>();
    _aiSlot = mine;
    try {
      return await task();
    } finally {
      if (identical(_aiSlot, mine)) _aiSlot = null;
      mine.complete();
    }
  }

  Future<ReportOutcome> generate({
    required List<QuickLogCategory> selectedCategories,
    required bool last30Days,
    required ReportProfileInput profile,
    bool forceRawFallback = false,

    /// The banner a forced-raw ship carries. The page passes the
    /// held failure's [ReportFailed.rawFallbackBanner]: a fatal
    /// AI class's raw fallback is a no-choice failure ship; the
    /// default (an export/render failure's raw tap) is the user's
    /// explicit choice.
    RawReportBanner forceRawBanner = RawReportBanner.explicitChoice,
    required ReportRenderPdf renderPdf,
    required Future<String> Function(List<int> bytes, String fileName)
        savePdf,

    /// The automatic Downloads copy (Juno Ruling 2): invoked with
    /// the SAME bytes + file name right after [savePdf] succeeds —
    /// the PDF is never regenerated for it — and awaited before
    /// the ready outcome returns, so the share confirmation can
    /// disclose its result. A false return or a throw is a failed
    /// copy only: generation still completes, and the failure
    /// never becomes the generic export-failure message.
    Future<bool> Function(List<int> bytes, String fileName)?
        saveToDownloads,
    void Function(ReportStage stage)? onStage,
    bool Function()? isCancelled,
    DateTime? now,

    /// VC 100131 (Round 3): the generation's wire identity /
    /// pickup controls. Each overrides its constructor provider
    /// when non-null (unit tests drive these directly; the page
    /// relies on the providers wired to the generation service).
    String? reportGenerationId,
    bool? checkPickupFirst,
    String? pickupCheckGenerationId,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;

    // VC 100130: the last stage the collector reported, kept so a
    // collection timeout's diagnostic record names where the
    // collection actually was when the deadline fired.
    var lastCollectStage = ReportStage.collecting;
    final ReportSnapshot snapshot;
    try {
      snapshot = await collector.collect(
        selectedCategories: selectedCategories,
        last30Days: last30Days,
        profile: profile,
        now: now,
        onStage: (s) {
          lastCollectStage =
              s == 'syncing' ? ReportStage.syncing : ReportStage.collecting;
          onStage?.call(lastCollectStage);
        },
        isCancelled: isCancelled,
      );
    } on ReportCollectionCancelled {
      return const ReportFailed('Cancelled');
    } on ReportCollectionTimeout {
      // R-1 F4: a bounded collection that ran out of time is a
      // named failure with the existing export-failure copy —
      // not a wedge and not a silent idle.
      // VC 100130: it also carries its diagnostic record.
      return ReportFailed(reportExportFailureMessage,
          allowRawFallback: true,
          failureKind: ReportFailureKind.collectionTimeout,
          failureStage: lastCollectStage);
    }
    if (cancelled()) return const ReportFailed('Cancelled');

    if (!snapshot.hasAnyData) {
      return const ReportFailed(
          'No patient logs or health data found in selected range.');
    }

    if (forceRawFallback) {
      return _renderAndFinish(
        snapshot,
        aiSummary: null,
        rawBanner: forceRawBanner,
        aiAttempts: const [],
        renderPdf: renderPdf,
        savePdf: savePdf,
        saveToDownloads: saveToDownloads,
        onStage: onStage,
        isCancelled: cancelled,
      );
    }

    onStage?.call(ReportStage.buildingSummary);
    final leg = await _runAiLeg(
      snapshot,
      priorAttempts: const [],
      isCancelled: cancelled,
      generationId: reportGenerationId ?? reportGenerationIdProvider?.call(),
      checkPickupFirst:
          checkPickupFirst ?? checkPickupFirstProvider?.call() ?? false,
      pickupCheckId: pickupCheckGenerationId ?? pickupCheckIdProvider?.call(),
    );
    return _finishAiLeg(
      leg,
      snapshot: snapshot,
      renderPdf: renderPdf,
      savePdf: savePdf,
      saveToDownloads: saveToDownloads,
      onStage: onStage,
      isCancelled: cancelled,
    );
  }

  /// Maps an AI leg's ending to the generation outcome. Shared by
  /// [generate] and by a held decision's retry, so both paths
  /// classify, hold, and fail identically.
  Future<ReportOutcome> _finishAiLeg(
    _AiLegResult leg, {
    required ReportSnapshot snapshot,
    required ReportRenderPdf renderPdf,
    required Future<String> Function(List<int> bytes, String fileName)
        savePdf,
    required Future<bool> Function(List<int> bytes, String fileName)?
        saveToDownloads,
    required void Function(ReportStage stage)? onStage,
    required bool Function() isCancelled,
  }) async {
    switch (leg.kind) {
      case _AiLegKind.cancelled:
        return const ReportFailed('Cancelled');
      case _AiLegKind.expired:
        // VC 100131 (Juno R8-1): the held narrative expired —
        // terminal expired state, never a failure/decision
        // surface, no render, no raw fallback.
        return ReportGenerationExpired(
          aiAttempts: leg.attempts,
          snapshot: snapshot,
        );
      case _AiLegKind.success:
        return _renderAndFinish(
          snapshot,
          aiSummary: leg.summary,
          rawBanner: null,
          aiAttempts: leg.attempts,
          renderPdf: renderPdf,
          savePdf: savePdf,
          saveToDownloads: saveToDownloads,
          onStage: onStage,
          isCancelled: isCancelled,
          heldCompletedAtMs: leg.heldCompletedAt?.millisecondsSinceEpoch,
        );
      case _AiLegKind.fatal:
        // A fatal class surfaces its honest failure state through
        // the existing failure path — no decision UI (there is
        // nothing a retry could cure), no silent raw ship. The
        // raw fallback stays available through the page's existing
        // affordance, and a raw ship from here is a NO-CHOICE
        // failure ship (the user was never offered Juno's
        // decision), so it carries the failure banner.
        final failure = leg.failure!;
        return ReportFailed(
          failure.plainReason,
          allowRawFallback: true,
          snapshot: snapshot,
          aiAttempts: leg.attempts,
          aiFailureReason: failure.plainReason,
          rawFallbackBanner: RawReportBanner.noChoiceFailure,
        );
      case _AiLegKind.exhausted:
        return _decisionOutcome(
          leg,
          snapshot: snapshot,
          renderPdf: renderPdf,
          savePdf: savePdf,
          saveToDownloads: saveToDownloads,
        );
    }
  }

  /// Builds the held decision outcome for an exhausted retryable
  /// leg, with its resume continuation captured. A retry that
  /// exhausts again builds a FRESH decision over the extended
  /// history (through [_finishAiLeg], like any leg ending).
  ReportAiDecision _decisionOutcome(
    _AiLegResult leg, {
    required ReportSnapshot snapshot,
    required ReportRenderPdf renderPdf,
    required Future<String> Function(List<int> bytes, String fileName)
        savePdf,
    required Future<bool> Function(List<int> bytes, String fileName)?
        saveToDownloads,
  }) {
    final failure = leg.failure!;
    return ReportAiDecision(
      failureReason: failure.plainReason,
      failureClass: failure.failureClass,
      attempts: leg.attempts,
      snapshot: snapshot,
      resume: ({
        required bool retryAi,
        required void Function(ReportStage stage) onStage,
        required bool Function() isCancelled,
      }) async {
        if (!retryAi) {
          // The user's explicit choice: render the data-only
          // report over the ALREADY-COLLECTED snapshot, with the
          // choice banner recorded at ship time.
          return _renderAndFinish(
            snapshot,
            aiSummary: null,
            rawBanner: RawReportBanner.explicitChoice,
            aiAttempts: leg.attempts,
            renderPdf: renderPdf,
            savePdf: savePdf,
            saveToDownloads: saveToDownloads,
            onStage: onStage,
            isCancelled: isCancelled,
          );
        }
        // Retry ONLY the AI analysis on the already-collected
        // data — no re-collection (Juno's ruling assumption,
        // verified against this architecture: the snapshot is
        // held on the decision outcome itself).
        // VC 100131: a resumed leg ALWAYS checks pickup before
        // its first dispatch (check point (ii)) — the original
        // generation may have completed server-side after the
        // client's socket died. The identity is the service's
        // current one: resumeAiDecision reuses the held
        // generation's persisted identity, and the provider the
        // page wired reads exactly that value during this run.
        onStage(ReportStage.buildingSummary);
        final retryLeg = await _runAiLeg(
          snapshot,
          priorAttempts: leg.attempts,
          isCancelled: isCancelled,
          generationId: reportGenerationIdProvider?.call(),
          checkPickupFirst: true,
        );
        return _finishAiLeg(
          retryLeg,
          snapshot: snapshot,
          renderPdf: renderPdf,
          savePdf: savePdf,
          saveToDownloads: saveToDownloads,
          onStage: onStage,
          isCancelled: isCancelled,
        );
      },
    );
  }

  /// One pickup resolution: a single pickup fetch, plus — while
  /// the server answers `running` — a poll every
  /// [pickupPollInterval] up to [pickupPollCap]. Returns the
  /// terminal pickup outcome ([PickupRunning] itself when the
  /// cap is reached still-running), or null when the generation
  /// was cancelled mid-poll. A throwing pickup call is a pickup
  /// TRANSPORT failure ([PickupUnreachable]) — never a
  /// generation failure.
  Future<ReportPickupOutcome?> _resolvePickup(
    Future<ReportPickupOutcome> Function(String generationId) pickup,
    String generationId,
    bool Function() isCancelled,
  ) async {
    Future<ReportPickupOutcome> safe() async {
      try {
        return await pickup(generationId);
      } catch (_) {
        return const PickupUnreachable();
      }
    }

    var outcome = await safe();
    var waited = Duration.zero;
    while (outcome is PickupRunning && waited < pickupPollCap) {
      await delay(pickupPollInterval);
      waited += pickupPollInterval;
      if (isCancelled()) return null;
      outcome = await safe();
    }
    return outcome;
  }

  /// The retry/exhaustion policy after a recorded failure
  /// (shared by POST outcomes and pickup-Failed outcomes — both
  /// are attempt outcomes under the ONE classification): returns
  /// the leg's terminal result (fatal / exhausted / cancelled
  /// during the backoff), or null when the policy says retry —
  /// the backoff has then already been applied.
  Future<_AiLegResult?> _policyAfterFailure(
    AiFailure failure, {
    required int attemptNo,
    required int priorCount,
    required List<AiAttemptRecord> attempts,
    required bool Function() isCancelled,
  }) async {
    if (!failure.retryable) {
      return _AiLegResult(_AiLegKind.fatal,
          attempts: attempts, failure: failure);
    }
    if (attemptNo - priorCount >= failure.maxAttempts) {
      return _AiLegResult(_AiLegKind.exhausted,
          attempts: attempts, failure: failure);
    }
    await delay(failure.backoffAfter(attemptNo - priorCount));
    if (isCancelled()) {
      return _AiLegResult(_AiLegKind.cancelled, attempts: attempts);
    }
    return null;
  }

  /// The AI leg: attempts under the single classification, each
  /// recorded. Attempt numbers continue from [priorAttempts] (a
  /// held decision's retry extends the same history).
  ///
  /// VC 100131 (Round 3) — server-completion pickup integration.
  /// Pickup check points: (i) before dispatching any retry
  /// attempt (attempt ≥ 2); (ii) at the head of a resumed leg
  /// (the decision-resume closure passes checkPickupFirst); (iii)
  /// at the head of a RESTORE generation (decision-restore
  /// re-collect pairing via [pickupCheckId], and the interrupted
  /// auto-rerun / interrupted retry via checkPickupFirst). A
  /// fresh start never checks (no row can exist for a new
  /// identity). Outcomes: Ready → the leg SUCCEEDS with the held
  /// narrative (a succeeded attempt is recorded; the render/save
  /// finish path is the normal one); Failed → recorded as the
  /// attempt outcome through the existing AiFailure mapping and
  /// the existing policy proceeds (a subsequent dispatch is a
  /// POST); Running → polled (see [_resolvePickup]); still
  /// running at the cap → fall through to a POST dispatch;
  /// NotFound → POST dispatch (normal); Expired → the leg STOPS
  /// — no POST, no retry — in the expired terminal state
  /// (Juno R8-1); Unreachable → POST dispatch (pickup is
  /// best-effort recovery, never a gate). NO pickup is ever
  /// attempted while the generation's cancel tombstone is set.
  ///
  /// Vera Stage 2 addenda: a duplicate/waiter POST can answer
  /// 202 {status:'running'} (the server caps its waiter at 55 s)
  /// — a 202 is NEVER an attempt failure and is never recorded;
  /// it enters the same pickup-poll path as [PickupRunning]. A
  /// 409 {status:'generation_in_progress'} (a DIFFERENT identity
  /// is running; this identity has NO row, so there is nothing
  /// to poll for) and a 429 {status:'generation_start_limit'}
  /// need no special casing: both flow through the existing
  /// AiFailure mapping with their true httpStatus (409 →
  /// fatalRequest, fatal, exactly 1 recorded attempt; 429 →
  /// rateLimited as always), existing copy unchanged.
  Future<_AiLegResult> _runAiLeg(
    ReportSnapshot snapshot, {
    required List<AiAttemptRecord> priorAttempts,
    required bool Function() isCancelled,
    String? generationId,
    bool checkPickupFirst = false,
    String? pickupCheckId,
  }) async {
    final call = aiCall ??
        (body) => backend.postAiDetailed('/api/ai/report', body);
    final pickup = pickupCall ?? backend.fetchReportPickup;
    final attempts = List<AiAttemptRecord>.of(priorAttempts);
    var attempt = priorAttempts.length;
    final String? effectivePickupId =
        (pickupCheckId != null && pickupCheckId.isNotEmpty)
            ? pickupCheckId
            : (generationId != null && generationId.isNotEmpty)
                ? generationId
                : null;
    bool tombstoned() => generationInvalidatedProvider?.call() ?? false;

    /// Handles a resolved (terminal or cap-reached) pickup
    /// outcome. Returns the leg result when the outcome ends the
    /// leg (Ready / Expired / a Failed whose policy is terminal),
    /// or null when the leg should proceed to a POST dispatch —
    /// NotFound, Unreachable, still-Running at the cap, or a
    /// Failed whose policy says retry (its backoff has been
    /// applied; the subsequent dispatch is a POST, per the
    /// brief — the pickup is not re-checked in between).
    Future<_AiLegResult?> handlePickup(ReportPickupOutcome outcome) async {
      switch (outcome) {
        case PickupReady(:final result, :final completedAt):
          attempt++;
          attempts.add(AiAttemptRecord(
            attempt: attempt,
            failureClass: null,
            httpStatus: 200,
            succeeded: true,
            at: clock(),
          ));
          return _AiLegResult(_AiLegKind.success,
              summary: result,
              attempts: attempts,
              heldCompletedAt: completedAt);
        case PickupExpired():
          // Juno R8-1: no POST, no retry, no decision surface —
          // the generation ends in the expired state.
          return _AiLegResult(_AiLegKind.expired, attempts: attempts);
        case PickupFailed(:final httpStatus):
          attempt++;
          final failure = AiFailure(httpStatus: httpStatus);
          attempts.add(AiAttemptRecord(
            attempt: attempt,
            failureClass: failure.failureClass,
            httpStatus: httpStatus,
            succeeded: false,
            at: clock(),
          ));
          return _policyAfterFailure(
            failure,
            attemptNo: attempt,
            priorCount: priorAttempts.length,
            attempts: attempts,
            isCancelled: isCancelled,
          );
        case PickupNotFound() || PickupUnreachable() || PickupRunning():
          return null;
      }
    }

    var pickupBeforeDispatch = checkPickupFirst;
    while (true) {
      if (isCancelled()) {
        return _AiLegResult(_AiLegKind.cancelled, attempts: attempts);
      }
      // ── Pickup phase (check points (i)/(ii)/(iii)) ──────────
      if (pickupBeforeDispatch) {
        pickupBeforeDispatch = false;
        if (effectivePickupId != null && !tombstoned()) {
          final outcome =
              await _resolvePickup(pickup, effectivePickupId, isCancelled);
          if (outcome == null) {
            return _AiLegResult(_AiLegKind.cancelled, attempts: attempts);
          }
          final handled = await handlePickup(outcome);
          if (handled != null) return handled;
          if (isCancelled()) {
            return _AiLegResult(_AiLegKind.cancelled, attempts: attempts);
          }
          // Fall through: this slot's dispatch is a POST.
        }
      }
      // ── POST dispatch phase ─────────────────────────────────
      attempt++;
      ({
        int? statusCode,
        Map<String, dynamic>? body,
        String? serverError,
        AiTransportFailure? transportFailure,
      }) res;
      var timedOut = false;
      var threw = false;
      try {
        // Single-flight + the per-attempt timeout: the guard is
        // the attempt's bound (see [aiAttemptTimeout] for its
        // derivation). When it fires, the attempt classifies as
        // [AiFailureClass.timeout] — the client's own abandonment
        // is a first-class outcome, never a "no connection". A
        // generate cancelled while its attempt waited at the gate
        // (or while the attempt ran) ends as cancelled: the
        // attempt's late result, if any, is discarded and no
        // retry fires.
        res = await _singleFlight(
          () => call(buildAiReportRequest(snapshot,
                  reportGenerationId: generationId))
              .timeout(attemptTimeout),
          isCancelled: isCancelled,
        );
      } on _AiAttemptCancelled {
        return _AiLegResult(_AiLegKind.cancelled, attempts: attempts);
      } on TimeoutException {
        timedOut = true;
        threw = true;
        res = (
          statusCode: null,
          body: null,
          serverError: null,
          transportFailure: null,
        );
      } catch (_) {
        threw = true;
        res = (
          statusCode: null,
          body: null,
          serverError: null,
          transportFailure: null,
        );
      }
      if (isCancelled()) {
        return _AiLegResult(_AiLegKind.cancelled, attempts: attempts);
      }
      // Vera Stage 2 addendum 1 — a duplicate/waiter POST may
      // answer 202 {status:'running'} (the server caps its
      // waiter at 55 s). A 202 is NEVER an attempt failure and
      // is never recorded as one: this dispatch consumed no
      // attempt outcome, so the attempt number is handed back
      // and the leg enters the SAME pickup-poll path as a
      // PickupRunning answer. Still running at the poll cap →
      // fall back to a fresh POST dispatch (the duplicate-POST
      // matrix makes that safe). With no identity there is
      // nothing to poll — wait one poll interval and re-dispatch.
      if (res.statusCode == 202 && res.body?['status'] == 'running') {
        attempt--;
        if (effectivePickupId != null && !tombstoned()) {
          final outcome =
              await _resolvePickup(pickup, effectivePickupId, isCancelled);
          if (outcome == null) {
            return _AiLegResult(_AiLegKind.cancelled, attempts: attempts);
          }
          final handled = await handlePickup(outcome);
          if (handled != null) return handled;
        } else {
          await delay(pickupPollInterval);
        }
        if (isCancelled()) {
          return _AiLegResult(_AiLegKind.cancelled, attempts: attempts);
        }
        pickupBeforeDispatch = false;
        continue;
      }
      final result = res.body?['result'];
      if (res.statusCode == 200 &&
          result is String &&
          result.trim().isNotEmpty) {
        attempts.add(AiAttemptRecord(
          attempt: attempt,
          failureClass: null,
          httpStatus: 200,
          succeeded: true,
          at: clock(),
        ));
        return _AiLegResult(_AiLegKind.success,
            summary: result, attempts: attempts);
      }
      // THE classification: one object, from which the retry
      // decision below and the recorded reason both read.
      final failure = AiFailure(
        httpStatus: res.statusCode,
        noResponse: res.transportFailure == AiTransportFailure.noResponse,
        noSession: res.transportFailure == AiTransportFailure.noSession,
        timedOut: timedOut ||
            res.transportFailure == AiTransportFailure.timeout,
        missingResult: res.statusCode == 200,
        unclassified: threw && !timedOut,
        preDispatch:
            res.transportFailure == AiTransportFailure.preDispatch,
      );
      attempts.add(AiAttemptRecord(
        attempt: attempt,
        failureClass: failure.failureClass,
        httpStatus: res.statusCode,
        succeeded: false,
        at: clock(),
      ));
      final terminal = await _policyAfterFailure(
        failure,
        attemptNo: attempt,
        priorCount: priorAttempts.length,
        attempts: attempts,
        isCancelled: isCancelled,
      );
      if (terminal != null) return terminal;
      // The policy says retry: pickup check point (i) — before
      // the retry dispatch, ask the server whether the detached
      // generation already finished (its socket may have died
      // while the server kept working).
      pickupBeforeDispatch = true;
    }
  }

  /// Render → save → Downloads, shared by every ship path (AI
  /// success, forced raw, decision ship-raw). Cancellation is
  /// honored at the stage boundaries exactly as PR #55 built it.
  Future<ReportOutcome> _renderAndFinish(
    ReportSnapshot snapshot, {
    required String? aiSummary,
    required RawReportBanner? rawBanner,
    required List<AiAttemptRecord> aiAttempts,
    required ReportRenderPdf renderPdf,
    required Future<String> Function(List<int> bytes, String fileName)
        savePdf,
    required Future<bool> Function(List<int> bytes, String fileName)?
        saveToDownloads,
    required void Function(ReportStage stage)? onStage,
    required bool Function() isCancelled,
    int? heldCompletedAtMs,
  }) async {
    bool cancelled() => isCancelled();
    if (cancelled()) return const ReportFailed('Cancelled');
    final isRaw = aiSummary == null;
    onStage?.call(ReportStage.renderingPdf);
    List<int> bytes;
    try {
      bytes = await renderPdf(snapshot, aiSummary,
          isRawFallback: isRaw, rawBanner: rawBanner);
    } catch (_) {
      return ReportFailed(
        isRaw
            ? 'Failed generating Raw Data report file.'
            : reportExportFailureMessage,
        allowRawFallback: true,
        snapshot: snapshot,
        aiAttempts: aiAttempts,
        failureKind: ReportFailureKind.renderFailure,
        failureStage: ReportStage.renderingPdf,
      );
    }
    onStage?.call(ReportStage.savingFile);
    final fileName = reportFileName(
        DateTime.fromMillisecondsSinceEpoch(snapshot.generationTimestampMs));
    String savedPath;
    try {
      savedPath = await savePdf(bytes, fileName);
    } catch (_) {
      return ReportFailed(reportExportFailureMessage,
          allowRawFallback: true,
          snapshot: snapshot,
          aiAttempts: aiAttempts,
          failureKind: ReportFailureKind.saveFailure,
          failureStage: ReportStage.savingFile);
    }
    // The save has landed: record the exact artifact reference
    // NOW (T1-2 save hook), before the Downloads copy and before
    // the outcome exists — this is the orphan-adoption window.
    try {
      onArtifactSaved?.call(fileName, savedPath);
    } catch (_) {
      // Journaling never breaks a generation.
    }
    // Juno Ruling 2: the Downloads attempt finishes BEFORE the
    // ready outcome (and therefore before the share confirmation),
    // over the same bytes — never a regeneration. Its failure is
    // carried on the outcome, never a generation failure.
    bool? downloadsSaved;
    final downloads = saveToDownloads;
    if (downloads != null) {
      try {
        downloadsSaved = await downloads(bytes, fileName);
      } catch (_) {
        downloadsSaved = false;
      }
    }
    return ReportReady(
      snapshot: snapshot,
      pdfBytes: bytes,
      fileName: fileName,
      savedPath: savedPath,
      isRawFallback: isRaw,
      aiFailureReason: null,
      rawBanner: rawBanner,
      aiAttempts: aiAttempts,
      downloadsSaved: downloadsSaved,
      heldCompletedAtMs: heldCompletedAtMs,
    );
  }
}

/// Thrown inside the single-flight gate when a queued attempt's
/// generation was cancelled before the attempt could fire: the
/// request is never sent.
class _AiAttemptCancelled implements Exception {
  const _AiAttemptCancelled();
}
