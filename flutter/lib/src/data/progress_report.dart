import 'dart:async';

import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
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

/// `Tabs_Report_<MMM_dd_yyyy>.pdf` (native ReportGenerator file name).
String reportFileName(DateTime d) =>
    'Tabs_Report_${_months[d.month - 1]}_${d.day.toString().padLeft(2, '0')}_${d.year}.pdf';

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
}

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
  final List<String> knowledgeDocuments;

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
    this.knowledgeDocuments = const [],
    this.heartRateSeries = const [],
    this.sleepSeries = const [],
    this.deepSleepSeries = const [],
    this.caloriesSeries = const [],
    this.hrvSeries = const [],
    this.heartRateSpikes = const [],
    this.bloodPressureSeries = const [],
    this.sectionMetadata = const {},
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
      knowledgeDocuments.isNotEmpty;
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
    final status = e.value.status == DataSourceStatus.success
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

/// The full `POST /api/ai/report` body (native `AiRequest` shape on
/// the snapshot path: entries, categories, userContext,
/// knowledgeBase, fitbitData, dataAvailability).
Map<String, dynamic> buildAiReportRequest(ReportSnapshot s) {
  final kb = s.knowledgeDocuments.join('\n\n');
  final availability = buildDataAvailability(s);
  return {
    'entries': s.logEntries.map(reportEntryJson).toList(),
    'categories': {
      for (final e in s.categoriesMap.entries) '${e.key}': e.value,
    },
    'userContext': buildReportUserContext(s),
    'knowledgeBase': kb.trim().isEmpty ? null : kb,
    'fitbitData': buildHealthSummary(s),
    'dataAvailability': availability.isEmpty ? null : availability,
  };
}

// ── AI failure reasons (AiFailureReasons.kt port) ────────────────

enum AiRetryClass { connection, serverError, fatal }

/// Port of native `AiFailureReasons`: maps a failure to its retry
/// class and a FIXED plain-language reason string. Only the HTTP
/// status is ever read — server/exception text never reaches the
/// UI or the PDF.
class AiFailure {
  final int? httpStatus;

  /// True when the call produced no HTTP response at all (no token,
  /// transport failure, or the backend's shared timeout).
  final bool noResponse;

  /// True when the attempt itself timed out before any response
  /// (native's `withTimeoutOrNull` null case).
  final bool timedOut;

  const AiFailure({this.httpStatus, this.noResponse = false, this.timedOut = false});

  AiRetryClass get retryClass {
    if (timedOut) return AiRetryClass.connection;
    final code = httpStatus;
    if (code != null) {
      return '$code'.startsWith('5')
          ? AiRetryClass.serverError
          : AiRetryClass.fatal;
    }
    // No HTTP status: native treats its IOException family as
    // connection failures.
    return AiRetryClass.connection;
  }

  int get maxAttempts => switch (retryClass) {
        AiRetryClass.connection => 4,
        AiRetryClass.serverError => 2,
        AiRetryClass.fatal => 1,
      };

  Duration backoffAfter(int completedAttempt) => switch (retryClass) {
        AiRetryClass.connection =>
          Duration(milliseconds: 2000 * (1 << (completedAttempt - 1).clamp(0, 10))),
        AiRetryClass.serverError => const Duration(seconds: 2),
        AiRetryClass.fatal => Duration.zero,
      };

  String get plainReason {
    if (timedOut) return 'network timeout after 60s';
    final code = httpStatus;
    if (code == 401) return 'HTTP 401 (signed out?)';
    if (code == 429) return 'HTTP 429 (try again later)';
    if (code != null && '$code'.startsWith('5')) {
      return 'HTTP $code (server error)';
    }
    if (code != null) return 'HTTP $code (request failed)';
    if (noResponse) return 'no connection';
    return 'unknown error';
  }
}

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

  const ReportProfileInput({
    this.userContext = '',
    this.age = 0,
    this.heightCm = 0,
    this.weightKg = 0,
    this.gender = '',
    this.conditions = const [],
    this.activeMedications = const [],
  });

  double get heightIn => heightCm <= 0 ? 0 : heightCm / 2.54;
  double get weightLbs => weightKg <= 0 ? 0 : weightKg * 2.20462;
}

/// Collects the report snapshot. All sources are injectable for
/// tests; production wires [TabsBackend] + [HealthConnectService].
class ReportDataCollector {
  final TabsBackend backend;
  final HealthConnectService hc;

  /// R70 WS2 — the local-first union reader (store ∪ fresh HC).
  final HealthHistoryQueries historyQueries;

  /// Extracted knowledge-document texts (R65's store, wired by
  /// the page; see the file header). Defaults to no documents.
  final Future<List<String>> Function() documentsLoader;

  ReportDataCollector({
    TabsBackend? backend,
    HealthConnectService? hc,
    HealthHistoryQueries? historyQueries,
    Future<List<String>> Function()? documentsLoader,
  }) : this._internal(
          backend ?? TabsBackend(),
          hc ?? HealthConnectService(),
          historyQueries,
          documentsLoader ?? (() async => const []),
        );

  ReportDataCollector._internal(
    this.backend,
    this.hc,
    HealthHistoryQueries? queries,
    this.documentsLoader,
  ) : historyQueries = queries ?? HealthHistoryQueries(hc: hc);

  Future<ReportSnapshot> collect({
    required List<QuickLogCategory> selectedCategories,
    required bool last30Days,
    required ReportProfileInput profile,
    void Function(String stage)? onStage,
    DateTime? now,
  }) async {
    final n = now ?? DateTime.now();
    final nowMs = n.millisecondsSinceEpoch;
    final daysToFetch = last30Days ? 31 : 180;
    final cutoff = last30Days ? nowMs - 30 * 24 * 60 * 60 * 1000 : 0;
    final metadata = <String, SectionMetadata>{};
    void meta(String key, DataSourceStatus status, int count) =>
        metadata[key] = SectionMetadata(key, status, count);

    onStage?.call('collecting');

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

    // 3. Conditions (profile list).
    meta(
        'conditions',
        pullFailed ? DataSourceStatus.error : DataSourceStatus.success,
        profile.conditions.length);

    // 4. Medications — ACTIVE only (not deleted, isPresent), the
    // shared R39 model's own filter.
    meta(
        'medications',
        pullFailed ? DataSourceStatus.error : DataSourceStatus.success,
        profile.activeMedications.length);

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

    // 6. Blood pressure — manual logs filtered to range. (Server BP
    // storage is dropped on push/pull as of R62, so an empty result
    // is the honest reachable state; native reports SUCCESS with
    // the filtered count, including 0.)
    final allBp = await backend.fetchManualBpLogs();
    final bp = allBp
        .where((r) => !last30Days || r.timeEpochMs >= cutoff)
        .map((r) => ReportBpRecord(r.systolic, r.diastolic, r.timeEpochMs))
        .toList();
    meta('bloodPressure',
        pullFailed ? DataSourceStatus.error : DataSourceStatus.success,
        bp.length);

    // 7. Health Connect sections.
    onStage?.call('syncing');
    var connected = false;
    try {
      connected = await hc.isConnected();
    } catch (_) {
      connected = false;
    }

    List<(String, int)> sleep = const [];
    List<(String, int)> deep = const [];
    List<(String, int)> calories = const [];
    List<(String, int)> spikes = const [];
    List<(String, int)> hr = const [];
    List<(String, double)> hrv = const [];

    if (!connected) {
      for (final key in ['sleep', 'deepSleep', 'heartRate', 'hrv', 'calories', 'hrSpikes']) {
        meta(key, DataSourceStatus.permissionDenied, 0);
      }
    } else {
      // R70 WS2 — ONE union load for the whole HC block: store ∪
      // fresh HC over the requested window, every metric. The
      // union's maps are already zero-filtered (founder rule; a 0
      // spike count stays — it is a real sampled day), and the
      // series + availability counts below are built from them
      // exactly as they were built from the raw bridge reads, so
      // the counts are the UNION's honest day counts.
      final union = await historyQueries.loadDays(
        daysToFetch,
        end: n,
        metrics: HistoryMetric.values.toSet(),
      );
      sleep = [
        for (final e in union.sleepMinutes.entries) (e.key, e.value),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      deep = [
        for (final e in union.deepSleepMinutes.entries) (e.key, e.value),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      meta('sleep',
          sleep.isEmpty ? DataSourceStatus.noData : DataSourceStatus.success,
          sleep.length);
      meta(
          'deepSleep',
          deep.isEmpty ? DataSourceStatus.noData : DataSourceStatus.success,
          deep.length);

      hr = [
        for (final e in union.restingHr.entries) (e.key, e.value),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      meta('heartRate',
          hr.isEmpty ? DataSourceStatus.noData : DataSourceStatus.success,
          hr.length);

      hrv = [
        for (final e in union.hrv.entries) (e.key, e.value),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      meta('hrv',
          hrv.isEmpty ? DataSourceStatus.noData : DataSourceStatus.success,
          hrv.length);

      calories = [
        for (final e in union.calories.entries) (e.key, e.value),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      meta(
          'calories',
          calories.isEmpty
              ? DataSourceStatus.noData
              : DataSourceStatus.success,
          calories.length);

      spikes = [
        for (final e in union.spikes.entries) (e.key, e.value),
      ]..sort((a, b) => a.$1.compareTo(b.$1));
      meta(
          'hrSpikes',
          spikes.isEmpty
              ? DataSourceStatus.noData
              : DataSourceStatus.success,
          spikes.length);
    }

    // Re-key into the collector's canonical section order (the
    // metadata map above is filled in completion order).
    final ordered = <String, SectionMetadata>{};
    for (final key in const [
      'logs', 'conditions', 'medications', 'documents', 'bloodPressure',
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
      medications: profile.activeMedications,
      knowledgeDocuments: docs,
      heartRateSeries: hr,
      sleepSeries: sleep,
      deepSleepSeries: deep,
      caloriesSeries: calories,
      hrvSeries: hrv,
      heartRateSpikes: spikes,
      bloodPressureSeries: bp,
      sectionMetadata: ordered,
    );
  }
}

// ── Generation pipeline (LogRepository snapshot path port) ────────

enum ReportStage { collecting, syncing, buildingSummary, renderingPdf, savingFile }

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
  const ReportReady({
    required this.snapshot,
    required this.pdfBytes,
    required this.fileName,
    required this.savedPath,
    required this.isRawFallback,
    this.aiFailureReason,
  });
}

class ReportFailed extends ReportOutcome {
  final String message;
  final bool allowRawFallback;
  final ReportSnapshot? snapshot;
  const ReportFailed(this.message,
      {this.allowRawFallback = false, this.snapshot});
}

/// Runs the native snapshot pipeline: collect → (unless forced raw)
/// AI summary with native's retry policy → render. Rendering and
/// saving are injected so tests never touch the PDF/share layer.
class ReportGenerationPipeline {
  final ReportDataCollector collector;
  final TabsBackend backend;

  /// Injected AI call (defaults to the backend's detailed POST).
  final Future<({int? statusCode, Map<String, dynamic>? body, String? serverError})>
      Function(Map<String, dynamic> body)? aiCall;

  /// Injected backoff delay (tests pass a no-op).
  final Future<void> Function(Duration d) delay;

  ReportGenerationPipeline({
    required this.collector,
    required this.backend,
    this.aiCall,
    Future<void> Function(Duration d)? delay,
  }) : delay = delay ?? ((d) => Future.delayed(d));

  Future<ReportOutcome> generate({
    required List<QuickLogCategory> selectedCategories,
    required bool last30Days,
    required ReportProfileInput profile,
    bool forceRawFallback = false,
    required Future<List<int>> Function(
            ReportSnapshot snapshot, String? aiSummary,
            {required bool isRawFallback, String? aiFailureReason})
        renderPdf,
    required Future<String> Function(List<int> bytes, String fileName)
        savePdf,
    void Function(ReportStage stage)? onStage,
    bool Function()? isCancelled,
    DateTime? now,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;

    final snapshot = await collector.collect(
      selectedCategories: selectedCategories,
      last30Days: last30Days,
      profile: profile,
      now: now,
      onStage: (s) => onStage?.call(
          s == 'syncing' ? ReportStage.syncing : ReportStage.collecting),
    );
    if (cancelled()) return const ReportFailed('Cancelled');

    if (!snapshot.hasAnyData) {
      return const ReportFailed(
          'No patient logs or health data found in selected range.');
    }

    String? aiSummary;
    String? aiFailureReason;
    if (!forceRawFallback) {
      onStage?.call(ReportStage.buildingSummary);
      final call = aiCall ??
          (body) => backend.postAiDetailed('/api/ai/report', body);
      var attempt = 0;
      var maxAttempts = 1;
      while (attempt < maxAttempts) {
        attempt++;
        if (cancelled()) return const ReportFailed('Cancelled');
        ({int? statusCode, Map<String, dynamic>? body, String? serverError})
            res;
        var timedOut = false;
        try {
          // Native caps each attempt at 60s; the Flutter backend's
          // shared transport timeout (20s) fires first in practice
          // and surfaces as a no-response connection failure.
          res = await call(buildAiReportRequest(snapshot))
              .timeout(const Duration(seconds: 60));
        } on TimeoutException {
          timedOut = true;
          res = (statusCode: null, body: null, serverError: null);
        } catch (_) {
          res = (statusCode: null, body: null, serverError: null);
        }
        final result = res.body?['result'];
        if (res.statusCode == 200 && result is String) {
          aiSummary = result;
          break;
        }
        final failure = AiFailure(
          httpStatus: res.statusCode,
          noResponse: res.statusCode == null,
          timedOut: timedOut,
        );
        aiFailureReason = failure.plainReason;
        if (failure.retryClass == AiRetryClass.fatal) break;
        maxAttempts =
            failure.maxAttempts > maxAttempts ? failure.maxAttempts : maxAttempts;
        if (attempt < maxAttempts) {
          await delay(failure.backoffAfter(attempt));
        }
      }
    }

    if (cancelled()) return const ReportFailed('Cancelled');
    final isRaw = aiSummary == null;
    onStage?.call(ReportStage.renderingPdf);
    List<int> bytes;
    try {
      bytes = await renderPdf(snapshot, aiSummary,
          isRawFallback: isRaw,
          aiFailureReason: forceRawFallback ? null : aiFailureReason);
    } catch (_) {
      return ReportFailed(
        forceRawFallback
            ? 'Failed generating Raw Data report file.'
            : reportExportFailureMessage,
        allowRawFallback: true,
        snapshot: snapshot,
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
          allowRawFallback: true, snapshot: snapshot);
    }
    return ReportReady(
      snapshot: snapshot,
      pdfBytes: bytes,
      fileName: fileName,
      savedPath: savedPath,
      isRawFallback: isRaw,
      aiFailureReason: forceRawFallback ? null : aiFailureReason,
    );
  }
}
