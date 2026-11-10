import 'dart:convert';

import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/medication_timeline.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart'
    show categoryIdByName;
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/today_summary.dart' hide dateStrOf;
import 'package:tabs_lab/src/features/home/vitals_strip.dart'
    show formatSleepMinutes;

/// Phase 1, item 3 — Clinician PDF v2 data layer (spec
/// `phase1-item3-clinician-pdf-spec.md`; copy per Juno's final
/// governing record, `2026-10-28-phase1-juno-rulings.md`, Item 3).
///
/// This file owns everything between the existing
/// [ReportDataCollector] snapshot and the one-page renderer
/// (`clinician_report_pdf.dart`): the score series read, the Z4
/// derivations, the Z5 medication-change lists (declared form
/// until captured events exist, captured form when they do), and
/// a generation pipeline that makes NO AI call and rides the
/// existing same-bytes Downloads contract.
///
/// Honesty rules (spec §5) bind here: stored scores only, never
/// computed at report time; missing data degrades per the §4.3
/// matrix (zone omitted or honestly labeled — never zero-filled);
/// Z2's medication list still comes from the collector's
/// double-filtered snapshot list (R5) — the declared-form Z5
/// derivation below reads the SEPARATE full list on
/// [ReportProfileInput.allMedications] and never touches the
/// printed list.

// ── Juno's final verbatim strings, Item 3 ────────────────────────

/// S1 — page title (Juno R5: v2 launches under this title; the
/// old "Tabs Clinical Audit Report" is rejected for v2).
const String clinicianReportTitle = 'Tabs Clinician Report';

/// S2 — footer, not a medical device.
const String clinicianDisclaimer =
    'Tabs is not a medical device. It does not diagnose, treat, cure, or prevent any condition. Information in this report is from your own logs. Consult a healthcare professional.';

/// S3 — meta line pattern (sentence case per Juno's replacement).
String clinicianMetaLine({
  required String rangeLabel,
  required int days,
  required String generatedStamp,
}) =>
    'Report range: $rangeLabel ($days days) · Generated: $generatedStamp';

/// S4 — zone headings.
const String clinicianHeadingMedications = 'Medications';
const String clinicianHeadingDailyScore = 'Daily Score';
const String clinicianHeadingFlareMigraine = 'Flare days and migraines';
const String clinicianHeadingMedChanges = 'Medication changes';
const String clinicianHeadingSaltFluids = 'Salt and fluids';

/// S5 — medication list empty.
const String clinicianNoMedications = 'No active medications recorded.';

/// S6 — score coverage disclosure (required whenever Z3 renders,
/// including at full coverage — Juno R4).
String clinicianScoreCoverage(int scoredDays, int rangeDays) =>
    'Daily Score recorded on $scoredDays of $rangeDays days in this range.';

/// S7 — summary empties ("recorded" is load-bearing: facts about
/// records, never assertions that events did not happen).
const String clinicianNoFlareDays = 'No flare days recorded in this range.';
const String clinicianNoMigraineEntries =
    'No migraine entries recorded in this range.';

/// S8 — change provenance labels; one prints on every Z5 line.
const String clinicianProvenanceCaptured = 'Recorded in Tabs';
const String clinicianProvenanceDeclared = 'Date as entered in Tabs';

/// S9 — overflow line pattern (Z2 and Z5 caps, spec §4.4).
String clinicianOverflowLine(int more) =>
    '+$more more — full list in the Tabs app.';

/// S10 — salt/fluid target line. Renders ONLY when Z6 renders
/// (timestamped item-4 data exists). Item 4 has not shipped, so
/// no caller passes targets yet and Z6 stays absent; the string
/// lives here so the zone lights up without a copy change.
String clinicianTargetsLine({
  required String electrolyteTarget,
  required String fluidTarget,
}) =>
    'Targets recorded in Tabs: $electrolyteTarget and $fluidTarget daily.';

// ── Phase 4 — clinician biometrics zone (Z3B) strings ────────────
//
// PROVISIONAL pending Juno's Phase 4 ruling
// (~/workspace/report-reliability-phase4/juno-ruling.md): the
// heading, the summary-line formats, and the per-metric
// unavailable presentation below are placeholders in Juno's
// established clinician register, to be replaced BYTE-EXACT with
// her ruled strings before this PR is finalized. The STRUCTURE
// (one line per metric, summary or availability statement, never
// a silent gap) is not provisional.

/// Phase 4 — biometric zone heading (provisional, see above).
const String clinicianHeadingBiometrics = 'Biometrics';

/// Phase 4 — per-metric line labels (provisional, see above).
const String clinicianBiometricLabelSleep = 'Sleep';
const String clinicianBiometricLabelDeepSleep = 'Deep sleep';
const String clinicianBiometricLabelHrv = 'Heart rate variability';
const String clinicianBiometricLabelRestingHeartRate =
    'Resting heart rate';
const String clinicianBiometricLabelHeartRateSpikes =
    'Heart rate spikes';
const String clinicianBiometricLabelBloodPressure = 'Blood pressure';

String _biometricDateLabel(String dayKey) {
  final d = DateTime.tryParse(dayKey);
  return d == null ? dayKey : formatMedArchiveDate(d);
}

String _recordedDaysText(int days) =>
    days == 1 ? '1 recorded day' : '$days recorded days';

/// Phase 4 — sleep / deep-sleep summary line (provisional format,
/// see above). Averages and latest render through the shared
/// compact sleep formatter (`7h6m`, founder ruling Oct 15, 2026).
String clinicianSleepSummaryLine(
        String label, ClinicianMetricSummary summary) =>
    '$label: average ${formatSleepMinutes(summary.average.round())} '
    'over ${_recordedDaysText(summary.recordedDays)} · '
    'latest ${formatSleepMinutes(summary.latest.round())} '
    'on ${_biometricDateLabel(summary.latestDayKey)}';

/// Phase 4 — HRV summary line (provisional format, see above).
String clinicianHrvSummaryLine(ClinicianMetricSummary summary) =>
    '$clinicianBiometricLabelHrv: average '
    '${summary.average.toStringAsFixed(1)} ms '
    'over ${_recordedDaysText(summary.recordedDays)} · '
    'latest ${summary.latest.toStringAsFixed(1)} ms '
    'on ${_biometricDateLabel(summary.latestDayKey)}';

/// Phase 4 — resting heart rate summary line (provisional
/// format, see above). The snapshot carries per-day RESTING heart
/// rate only; intraday time-in-zone is not derivable from it and
/// is never fabricated — this line reports the supportable
/// summaries (average, latest, recorded-day range) only.
String clinicianRestingHeartRateSummaryLine(
        ClinicianMetricSummary summary) =>
    '$clinicianBiometricLabelRestingHeartRate: average '
    '${summary.average.round()} bpm '
    'over ${_recordedDaysText(summary.recordedDays)} · '
    'latest ${summary.latest.round()} bpm '
    'on ${_biometricDateLabel(summary.latestDayKey)} · '
    'range ${summary.min!.round()}–${summary.max!.round()} bpm';

/// Phase 4 — HR spike summary line (provisional format, see
/// above). A 0-count day is a real sampled day (the snapshot
/// keeps it), so the sampled-day count is the series length.
String clinicianHeartRateSpikesSummaryLine(
        ClinicianSpikeSummary summary) =>
    '$clinicianBiometricLabelHeartRateSpikes: '
    '${summary.totalSpikes} recorded over '
    '${summary.recordedDays == 1 ? '1 sampled day' : '${summary.recordedDays} sampled days'} '
    '(${summary.daysWithSpikes} '
    '${summary.daysWithSpikes == 1 ? 'day' : 'days'} with spikes)';

/// Phase 4 — blood pressure summary line (provisional format,
/// see above).
String clinicianBloodPressureSummaryLine(
        ClinicianBloodPressureSummary summary) =>
    '$clinicianBiometricLabelBloodPressure: average '
    '${summary.averageSystolic}/${summary.averageDiastolic} mmHg '
    'over ${summary.readingCount == 1 ? '1 reading' : '${summary.readingCount} readings'} · '
    'latest ${summary.latestSystolic}/${summary.latestDiastolic} mmHg '
    'on ${_biometricDateLabel(summary.latestDayKey)}';

// ── Caps (spec §4.4: fixed one page, enforced by caps) ──────────

/// Max medication lines printed in Z2 before the S9 overflow
/// line. The R5 diff always runs against the FULL snapshot list.
const int clinicianMedicationCap = 6;

/// Max change lines printed in Z5 (most recent first) before
/// the S9 overflow line.
const int clinicianChangeCap = 3;

// ── Date helpers ─────────────────────────────────────────────────

const _monthNamesFull = [
  '', 'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// A declared medication date string at its TRUE precision:
/// the parsed day plus whether the string carried month
/// precision only ("April 2026"). Month precision resolves to
/// the 1st for sorting/window math, but renders at month
/// precision — the 1st is a parsing artifact and must never
/// print as an exact day (Juno Item 3 · R3 conditions).
({DateTime day, bool monthOnly})? parseDeclaredMedDate(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final m = RegExp(r'^([A-Za-z]+)\.?\s+(?:(\d{1,2})\s*,?\s*)?(\d{4})$')
      .firstMatch(s);
  if (m == null) {
    // Not a month-name form — fall back to the shared tolerant
    // parser (which also returns null for anything it cannot
    // recognize); such strings are treated as exact-day when
    // they parse at all.
    final d = parseMedicationDate(s);
    return d == null ? null : (day: d, monthOnly: false);
  }
  final parsed = parseMedicationDate(s);
  if (parsed == null) return null;
  return (day: parsed, monthOnly: m.group(2) == null);
}

/// The printed form of a declared date, at its true precision.
String declaredDateLabel(({DateTime day, bool monthOnly}) parsed) =>
    parsed.monthOnly
        ? '${_monthNamesFull[parsed.day.month]} ${parsed.day.year}'
        : formatMedArchiveDate(parsed.day);

DateTime _dayOf(int epochMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(epochMs);
  return DateTime(d.year, d.month, d.day);
}

String _dayKey(DateTime d) => dateStrOf(d);

// ── Z5 change model ──────────────────────────────────────────────

/// One printed medication-change line for Z5, with its optional
/// before/after window averages (captured form only, and only
/// when the D1 floor is met — Juno Item 2 · Draft 8 / D1).
class ClinicianMedChange {
  /// Sort/window day (device-local midnight). For a
  /// month-precision declared date this is the 1st — math only,
  /// never printed as an exact day.
  final DateTime day;

  /// The printed date, at the date's true precision.
  final String dateLabel;

  /// The change label (Juno Item 2 · Draft 6 patterns).
  final String label;

  /// True for captured events (S8 "Recorded in Tabs"); false for
  /// the declared form (S8 "Date as entered in Tabs").
  final bool captured;

  /// Window averages of stored Daily Scores (14 days either
  /// side, item 2 §3), computed by item 2's
  /// [computeMedicationWindows] — the exact panel computation,
  /// whole numbers, exactly as the panel formats them. Non-null
  /// ONLY when the D1 floor is met for both windows (each ≥ 5
  /// scored days, ≥ 14 in total); below the floor no average
  /// prints — there is no partial average and no zero average.
  final ({int average, int scoredDays})? beforeWindow;
  final ({int average, int scoredDays})? afterWindow;

  const ClinicianMedChange({
    required this.day,
    required this.dateLabel,
    required this.label,
    required this.captured,
    this.beforeWindow,
    this.afterWindow,
  });
}

// ── Z5 windows — UNIFIED onto item 2's computation ─────────────
//
// Z5 window-semantics fix (ship-checklist production gate):
// this file previously carried a private duplicate window
// computation (`computeMedChangeWindows`) whose semantics
// diverged from the item 2b panel — anchor-exclusive neighbor
// bounds and non-whole averages printed at one decimal, where
// the panel truncates at the neighboring change's REGIMEN
// boundary and prints whole numbers. That duplicate is REMOVED.
// Z5 now runs item 2's [computeMedicationWindows] over the
// markers built by [capturedTimelineMarker] — the same call,
// the same inputs (the full stored Daily Score map, the change
// marker, every captured marker as the neighbor set), and the
// same D1 floor semantics the panel and the correlation
// engine's F5 family already share (item 2 spec §5: "the exact
// §3 panel computation, reused, not recomputed differently for
// print"). What remains here is only the projection from
// [TimelineWindowResult] onto the printed line's shape.
//
// Juno condition (Z5 unification follow-up): the neighbor set
// above is the panel's FULL marker set — captured markers plus
// the seeded markers from the medication list, merged by the
// panel's own seeding/dedup functions in
// [deriveCapturedMedChanges]. A captured-only set let a window
// run across a declared-but-never-captured start the panel
// truncates at, printing a different average beside the same
// change.

/// The Z5 window length: item 2's panel default (14 days either
/// side), matching the printed "14 days before / after" wording.
const int clinicianWindowDays = 14;

/// Projects item 2's window result onto Z5's printed pair.
/// Below the D1 floor the canonical result carries NO averages
/// (they are discarded in item 2's layer, not merely hidden),
/// and Z5 prints none either — there is no partial average.
({
  ({int average, int scoredDays})? before,
  ({int average, int scoredDays})? after,
}) _z5WindowsFrom(TimelineWindowResult result) {
  if (!result.floorMet) return (before: null, after: null);
  return (
    before: (
      average: result.beforeAverage!,
      scoredDays: result.beforeScoredDays,
    ),
    after: (
      average: result.afterAverage!,
      scoredDays: result.afterScoredDays,
    ),
  );
}

/// Average formatting for the Z3 range average ONLY: whole
/// numbers print without a decimal, everything else at one
/// decimal. Z5 window averages do NOT use this — they are
/// item 2's whole-number averages and print as integers.
String clinicianAverageText(double average) =>
    average == average.roundToDouble()
        ? '${average.round()}'
        : average.toStringAsFixed(1);

// ── Z5 derivations ───────────────────────────────────────────────

/// The event types Z5 prints. `delete` has no Juno label pattern
/// (a row removal is not a recorded stop) and `dates_edit` is a
/// metadata correction, not a regimen change — neither prints.
const _printableEventTypes = {
  'start',
  'stop',
  'dose_change',
  'frequency_change',
  'restore',
};

String _capturedChangeLabel(MedicationChangeEvent e) {
  final name = e.medName;
  switch (e.type) {
    case 'start':
      // Blank-dose form (Juno micro-ruling, Oct 28 2026).
      final startDose = e.newSnapshot?.dose ?? '';
      return startDose.isEmpty
          ? 'Started $name'
          : 'Started $name · $startDose';
    case 'stop':
      return 'Stopped $name';
    case 'dose_change':
      return '$name dose changed from ${e.oldSnapshot?.dose ?? ''} to ${e.newSnapshot?.dose ?? ''}';
    case 'frequency_change':
      return '$name schedule changed from ${e.oldSnapshot?.frequency ?? ''} to ${e.newSnapshot?.frequency ?? ''}';
    case 'restore':
      final restoreDose = e.newSnapshot?.dose ?? '';
      return restoreDose.isEmpty
          ? 'Restarted $name'
          : 'Restarted $name · $restoreDose';
    default:
      return name;
  }
}

DateTime _capturedChangeDay(MedicationChangeEvent e) {
  // VC 100109 combine — Vera C1 restore exception (ratified on
  // item 2b, applied here): a restore's effectiveDate is the
  // ERASED STOP DATE the unarchive preserved, not the restart
  // day; a restore anchors on its capture day. Without this,
  // the report dates every restart on the day the med was
  // stopped and windows it around the wrong day.
  if (e.type == 'restore') return _dayOf(e.recordedAt);
  final eff = e.effectiveDate;
  if (eff != null && eff.trim().isNotEmpty) {
    final parsed = parseDeclaredMedDate(eff);
    if (parsed != null) return parsed.day;
  }
  return _dayOf(e.recordedAt);
}

String _capturedDateLabel(MedicationChangeEvent e) {
  // The C1 restore exception applies to the printed label too:
  // a restart is labeled with its capture day, never the erased
  // stop date carried in its effectiveDate.
  if (e.type == 'restore') return formatMedArchiveDate(_dayOf(e.recordedAt));
  final eff = e.effectiveDate;
  if (eff != null && eff.trim().isNotEmpty) {
    final parsed = parseDeclaredMedDate(eff);
    if (parsed != null) return declaredDateLabel(parsed);
  }
  return formatMedArchiveDate(_dayOf(e.recordedAt));
}

/// Z5, captured form: change lines from item 2a's captured
/// events (Juno Item 3 · R3: this form replaces the declared
/// form whenever captured events exist). Most recent first.
///
/// Window averages come from item 2's [computeMedicationWindows]
/// over the SAME marker set the panel bounds on: the captured
/// markers built by [capturedTimelineMarker] from ALL printable
/// events (not just in-range ones, so a window never silently
/// crosses a neighboring change) PLUS the seeded markers the
/// panel derives from the full medication list
/// ([seededTimelineMarkers] over [medications], merged with the
/// panel's captured-wins dedup,
/// [mergeTimelineMarkersCapturedWins]) — Juno condition on the
/// Z5 unification: a declared start that was never captured
/// still bounds a captured change's window, exactly as it does
/// on the panel. Seeded markers are BOUNDING ONLY: they never
/// print as Z5 lines here (the printed lines below iterate the
/// captured pairs only; declared-form rendering is
/// [deriveDeclaredMedChanges], unchanged). [scores] is the FULL
/// stored Daily Score map (`yyyy-MM-dd` → stored score or
/// null), not a range-truncated subset: a change near the range
/// edge windows over the stored days on both sides of it,
/// exactly as the panel does. The marker's anchor day is the
/// day the printed line carries ([_capturedChangeDay] implements
/// the same anchor rule, including the C1 restore exception, for
/// the label).
List<ClinicianMedChange> deriveCapturedMedChanges(
  List<MedicationChangeEvent> events, {
  required List<MedicationEntry> medications,
  required Map<String, int?> scores,
  required DateTime rangeStart,
  required DateTime rangeEnd,
}) {
  final printable = [
    for (final e in events)
      if (_printableEventTypes.contains(e.type)) e,
  ];
  // The neighbor/bounding set is item 2's marker set: one
  // marker per printable event, built by the timeline
  // derivation's own constructor. Non-marker types (`delete`,
  // `dates_edit`) are already excluded by _printableEventTypes
  // and would project to null here regardless.
  final paired = <({MedicationChangeEvent event, TimelineMarker marker})>[];
  for (final e in printable) {
    final marker = capturedTimelineMarker(e);
    if (marker != null) paired.add((event: e, marker: marker));
  }
  final allMarkers = mergeTimelineMarkersCapturedWins(
    captured: [for (final p in paired) p.marker],
    seeded: seededTimelineMarkers(medications).markers,
  );
  final out = <ClinicianMedChange>[];
  for (final p in paired) {
    final e = p.event;
    final day = _capturedChangeDay(e);
    if (day.isBefore(rangeStart) || day.isAfter(rangeEnd)) continue;
    final windows = _z5WindowsFrom(computeMedicationWindows(
      marker: p.marker,
      allMarkers: allMarkers,
      scoresByDate: scores,
      windowDays: clinicianWindowDays,
    ));
    out.add(ClinicianMedChange(
      day: day,
      dateLabel: _capturedDateLabel(e),
      label: _capturedChangeLabel(e),
      captured: true,
      beforeWindow: windows.before,
      afterWindow: windows.after,
    ));
  }
  out.sort((a, b) => b.day.compareTo(a.day));
  return out;
}

/// Z5, declared form (Juno Item 3 · R3, with her conditions):
/// start/stop lines from the declared `startDate` / `endDate`
/// strings on the FULL medication list — each labeled declared
/// (S8), month-precision strings at month precision, blank or
/// unparseable strings produce NO dated line, an `''` or
/// "Present" end date produces no stop line, and NEVER derived
/// from "Took Med" adherence entries (there is no adherence
/// input to this function at all). Most recent first.
List<ClinicianMedChange> deriveDeclaredMedChanges(
  List<MedicationEntry> allMedications, {
  required DateTime rangeStart,
  required DateTime rangeEnd,
}) {
  bool inRange(DateTime d) => !d.isBefore(rangeStart) && !d.isAfter(rangeEnd);
  final out = <ClinicianMedChange>[];
  for (final med in allMedications) {
    // Deleted rows are tombstones — no longer entries on the
    // profile (the medications.dart convention) — so they
    // produce no change lines on a clinician document.
    if (med.isDeleted) continue;
    final start = parseDeclaredMedDate(med.startDate);
    if (start != null && inRange(start.day)) {
      out.add(ClinicianMedChange(
        day: start.day,
        dateLabel: declaredDateLabel(start),
        // Blank-dose form (Juno micro-ruling, Oct 28 2026).
        label: med.dose.isEmpty
            ? 'Started ${med.name}'
            : 'Started ${med.name} · ${med.dose}',
        captured: false,
      ));
    }
    if (med.isArchived) {
      final endRaw = med.endDate.trim();
      if (endRaw.isNotEmpty && endRaw != 'Present') {
        final end = parseDeclaredMedDate(endRaw);
        if (end != null && inRange(end.day)) {
          out.add(ClinicianMedChange(
            day: end.day,
            dateLabel: declaredDateLabel(end),
            label: 'Stopped ${med.name}',
            captured: false,
          ));
        }
      }
    }
  }
  out.sort((a, b) {
    final byDay = b.day.compareTo(a.day);
    return byDay != 0 ? byDay : a.label.compareTo(b.label);
  });
  return out;
}

// ── Z4 derivations ───────────────────────────────────────────────

/// Item 1's reserved flare tag and vocabularies (spec §4.2).
/// The flare writer lives on its own branch; the chip parsing
/// here mirrors its rules exactly (JSON list, `', '`-joined, and
/// bare-list shapes all parse to the same list) so identity
/// checks never misclassify.
const String clinicianFlareTag = 'Flare Day';
const List<String> clinicianFlareSeverities = ['Rough', 'Bad', 'Really bad'];

List<String> parseClinicianChips(String chips) {
  final raw = chips.trim();
  if (raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return [
        for (final c in decoded)
          if ('$c'.trim().isNotEmpty) '$c'.trim(),
      ];
    }
  } catch (_) {
    // Fall through to the joined / bare-list shapes.
  }
  var body = raw;
  if (body.startsWith('[') && body.endsWith(']')) {
    body = body.substring(1, body.length - 1);
  }
  return [
    for (final part in body.split(','))
      if (part.trim().replaceAll('"', '').trim().isNotEmpty)
        part.trim().replaceAll('"', '').trim(),
  ];
}

/// The energy day (04:00 local boundary, item 1's rule) a
/// timestamp belongs to, as a `yyyy-MM-dd` key.
String clinicianEnergyDayKey(int timestampMs) {
  final d = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final shifted = d.hour < 4
      ? DateTime(d.year, d.month, d.day - 1)
      : DateTime(d.year, d.month, d.day);
  return _dayKey(shifted);
}

/// Z4 flare summary: distinct energy-days carrying the reserved
/// tag (in the resolved Symptoms category when it resolves),
/// plus the severity mix over those days.
({int flareDays, Map<String, int> severityMix}) deriveFlareSummary(
  List<QuickLogEntry> entries, {
  required int? symptomsCategoryId,
  required Set<String> rangeDayKeys,
}) {
  final byDay = <String, QuickLogEntry>{};
  for (final e in entries) {
    if (symptomsCategoryId != null && e.categoryId != symptomsCategoryId) {
      continue;
    }
    if (!parseClinicianChips(e.chips).contains(clinicianFlareTag)) continue;
    final key = clinicianEnergyDayKey(e.timestamp);
    if (!rangeDayKeys.contains(key)) continue;
    final existing = byDay[key];
    if (existing == null || e.timestamp > existing.timestamp) {
      byDay[key] = e;
    }
  }
  final mix = <String, int>{};
  for (final e in byDay.values) {
    for (final chip in parseClinicianChips(e.chips)) {
      if (clinicianFlareSeverities.contains(chip)) {
        mix[chip] = (mix[chip] ?? 0) + 1;
        break;
      }
    }
  }
  return (flareDays: byDay.length, severityMix: mix);
}

/// Z4 migraine count: entries in the name-resolved "Migraine
/// Symptoms & Triggers" category (falling back to Symptoms by
/// name, then id 1 — the migraine_controller chain), in range.
int deriveMigraineCount(
  List<QuickLogEntry> entries, {
  required List<QuickLogCategory> categories,
  required Set<String> rangeDayKeys,
}) {
  final id = categoryIdByName(categories, 'Migraine Symptoms & Triggers') ??
      resolveSummaryCategoryId(categories, name: 'Symptoms', fallbackId: 1);
  if (id == null) return 0;
  var count = 0;
  for (final e in entries) {
    if (e.categoryId != id) continue;
    if (!rangeDayKeys.contains(_dayKey(_dayOf(e.timestamp)))) continue;
    count++;
  }
  return count;
}

/// Z4 top categories by entry count (names resolved from the
/// full category set, falling back to the snapshot's map),
/// capped at 3, ties broken by name for determinism.
List<({String name, int count})> deriveTopCategories(
  List<QuickLogEntry> entries, {
  required Map<int, String> names,
  required Set<String> rangeDayKeys,
}) {
  final counts = <int, int>{};
  for (final e in entries) {
    if (!rangeDayKeys.contains(_dayKey(_dayOf(e.timestamp)))) continue;
    if (!names.containsKey(e.categoryId)) continue;
    counts[e.categoryId] = (counts[e.categoryId] ?? 0) + 1;
  }
  final out = [
    for (final entry in counts.entries)
      (name: names[entry.key]!, count: entry.value),
  ]..sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.name.compareTo(b.name);
    });
  return out.take(3).toList();
}

// ── Phase 4 — biometric summaries (Z3B) ──────────────────────────
//
// Derived ONCE here, in [ClinicianReportCollector.extend], from
// the [ReportSnapshot] the standard pipeline already collected —
// the clinician pipeline runs the SAME [ReportDataCollector]
// collect, so there is no second collection path and no collector
// change. The renderer renders these summaries and nothing else.
//
// Calories are deliberately NOT carried onto the clinician
// one-pager: the zone's register is the autonomic/clinical vital
// set (sleep, deep sleep, HRV, resting heart rate, HR spikes,
// blood pressure) the clinician reviews for this patient, the
// page is hard-capped at one page, and calories remain fully
// reported in the standard report (and their availability status
// is still disclosed in Z8 from the section metadata).

/// One per-day biometric series reduced to its printed summary:
/// recorded-day count, mean, latest value (by day), and the
/// recorded-day min/max where the register prints a range.
class ClinicianMetricSummary {
  final int recordedDays;
  final double average;
  final double latest;
  final String latestDayKey;
  final double? min;
  final double? max;

  const ClinicianMetricSummary({
    required this.recordedDays,
    required this.average,
    required this.latest,
    required this.latestDayKey,
    this.min,
    this.max,
  });
}

/// HR spike days reduced to their printed summary. Unlike the
/// value series, a 0-count day is a real sampled day and counts
/// toward [recordedDays] (the snapshot's own rule).
class ClinicianSpikeSummary {
  final int recordedDays;
  final int totalSpikes;
  final int daysWithSpikes;

  const ClinicianSpikeSummary({
    required this.recordedDays,
    required this.totalSpikes,
    required this.daysWithSpikes,
  });
}

/// Blood pressure readings reduced to their printed summary:
/// mean and latest (by timestamp) systolic/diastolic pairs.
class ClinicianBloodPressureSummary {
  final int readingCount;
  final int averageSystolic;
  final int averageDiastolic;
  final int latestSystolic;
  final int latestDiastolic;
  final String latestDayKey;

  const ClinicianBloodPressureSummary({
    required this.readingCount,
    required this.averageSystolic,
    required this.averageDiastolic,
    required this.latestSystolic,
    required this.latestDiastolic,
    required this.latestDayKey,
  });
}

/// Reduces a per-day integer series (sleep minutes, deep-sleep
/// minutes, resting HR) to its summary, or null when the series
/// carries no usable day. Non-positive values are excluded (the
/// founder zero rule: a 0 biometric is a failed read, never data).
ClinicianMetricSummary? summarizeClinicianIntSeries(
    List<(String, int)> series) {
  final rows = [
    for (final e in series)
      if (e.$2 > 0) e,
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  if (rows.isEmpty) return null;
  final total = rows.fold<int>(0, (a, e) => a + e.$2);
  var min = rows.first.$2;
  var max = rows.first.$2;
  for (final e in rows) {
    if (e.$2 < min) min = e.$2;
    if (e.$2 > max) max = e.$2;
  }
  return ClinicianMetricSummary(
    recordedDays: rows.length,
    average: total / rows.length,
    latest: rows.last.$2.toDouble(),
    latestDayKey: rows.last.$1,
    min: min.toDouble(),
    max: max.toDouble(),
  );
}

/// Reduces a per-day double series (HRV RMSSD, ms) to its
/// summary, or null when it carries no usable day.
ClinicianMetricSummary? summarizeClinicianDoubleSeries(
    List<(String, double)> series) {
  final rows = [
    for (final e in series)
      if (e.$2 > 0) e,
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  if (rows.isEmpty) return null;
  final total = rows.fold<double>(0, (a, e) => a + e.$2);
  var min = rows.first.$2;
  var max = rows.first.$2;
  for (final e in rows) {
    if (e.$2 < min) min = e.$2;
    if (e.$2 > max) max = e.$2;
  }
  return ClinicianMetricSummary(
    recordedDays: rows.length,
    average: total / rows.length,
    latest: rows.last.$2,
    latestDayKey: rows.last.$1,
    min: min,
    max: max,
  );
}

/// Reduces the per-day HR spike counts to their summary, or null
/// when no day was sampled. Zero-count days are kept: they are
/// real sampled days (the snapshot's own rule).
ClinicianSpikeSummary? summarizeClinicianSpikes(
    List<(String, int)> series) {
  if (series.isEmpty) return null;
  return ClinicianSpikeSummary(
    recordedDays: series.length,
    totalSpikes: series.fold<int>(0, (a, e) => a + e.$2),
    daysWithSpikes: series.where((e) => e.$2 > 0).length,
  );
}

/// Reduces the snapshot's BP readings to their summary, or null
/// when there are no readings. Latest is by timestamp.
ClinicianBloodPressureSummary? summarizeClinicianBloodPressure(
    List<ReportBpRecord> records) {
  if (records.isEmpty) return null;
  final rows = [...records]
    ..sort((a, b) => a.timeEpochMs.compareTo(b.timeEpochMs));
  final sys =
      rows.fold<int>(0, (a, e) => a + e.systolic) / rows.length;
  final dia =
      rows.fold<int>(0, (a, e) => a + e.diastolic) / rows.length;
  final latest = rows.last;
  return ClinicianBloodPressureSummary(
    readingCount: rows.length,
    averageSystolic: sys.round(),
    averageDiastolic: dia.round(),
    latestSystolic: latest.systolic,
    latestDiastolic: latest.diastolic,
    latestDayKey: dateStrOf(_dayOf(latest.timeEpochMs)),
  );
}

// ── The clinician report data (the renderer's only input) ───────

class ClinicianReportData {
  /// The base snapshot from the existing collector, untouched
  /// (Z2 prints `snapshot.medications` — the double-filtered
  /// verified active list, R5).
  final ReportSnapshot snapshot;

  /// Stored Daily Scores in range, date-sorted, values > 0.
  final List<(String, int)> dailyScoreSeries;

  /// Z5 lines, most recent first (uncapped — the line model
  /// applies the §4.4 cap + overflow).
  final List<ClinicianMedChange> medChanges;

  /// True when Z5 is in captured form (the item 2a events fetch
  /// succeeded); false for the declared form.
  final bool medChangesCaptured;

  final int flareDays;
  final Map<String, int> flareSeverityMix;
  final int migraineCount;
  final List<({String name, int count})> topCategories;

  /// Phase 4 — biometric summaries for Z3B, derived from the
  /// snapshot's own series in [ClinicianReportCollector.extend].
  /// Null means the snapshot carried no usable data for that
  /// metric; the zone then prints the metric's availability
  /// statement instead of a summary — never a silent gap and
  /// never a zero-filled summary.
  final ClinicianMetricSummary? sleepSummary;
  final ClinicianMetricSummary? deepSleepSummary;
  final ClinicianMetricSummary? hrvSummary;
  final ClinicianMetricSummary? restingHeartRateSummary;
  final ClinicianSpikeSummary? heartRateSpikeSummary;
  final ClinicianBloodPressureSummary? bloodPressureSummary;

  const ClinicianReportData({
    required this.snapshot,
    required this.dailyScoreSeries,
    required this.medChanges,
    required this.medChangesCaptured,
    required this.flareDays,
    required this.flareSeverityMix,
    required this.migraineCount,
    required this.topCategories,
    this.sleepSummary,
    this.deepSleepSummary,
    this.hrvSummary,
    this.restingHeartRateSummary,
    this.heartRateSpikeSummary,
    this.bloodPressureSummary,
  });

  /// Phase 4 — truthful emptiness for the clinician output: true
  /// when ANY evidence exists on the page — the snapshot's own
  /// data (logs, biometric series, conditions, medications,
  /// documents), the stored Daily Score series, the Z4/Z5
  /// derivations, AND the Phase 4 biometric summaries explicitly
  /// (a data object carrying only a biometric summary is not
  /// empty, whatever its snapshot holds). No consumer gates on
  /// this today — the clinician pipeline intentionally still
  /// renders the honest empty page (the empty-fixture contract) —
  /// so the getter is pinned by tests for the consumer that
  /// adopts it.
  bool get hasAnyData =>
      snapshot.hasAnyData ||
      dailyScoreSeries.isNotEmpty ||
      medChanges.isNotEmpty ||
      flareDays > 0 ||
      migraineCount > 0 ||
      topCategories.isNotEmpty ||
      sleepSummary != null ||
      deepSleepSummary != null ||
      hrvSummary != null ||
      restingHeartRateSummary != null ||
      heartRateSpikeSummary != null ||
      bloodPressureSummary != null;

  /// The range's day span (device-local), from the snapshot's
  /// range machinery.
  ({DateTime start, DateTime end, List<String> dayKeys}) get range {
    final end = _dayOf(snapshot.generationTimestampMs);
    final start = DateTime(
        end.year, end.month, end.day - (snapshot.durationDays - 1));
    final keys = <String>[];
    for (var d = start;
        !d.isAfter(end);
        d = DateTime(d.year, d.month, d.day + 1)) {
      keys.add(_dayKey(d));
    }
    return (start: start, end: end, dayKeys: keys);
  }

  int get rangeDays => snapshot.durationDays;
  int get scoredDays => dailyScoreSeries.length;

  Map<String, int> get scoreMap => {
        for (final e in dailyScoreSeries) e.$1: e.$2,
      };
}

// ── Collector extension ──────────────────────────────────────────

/// Extends a base [ReportSnapshot] with the clinician fields.
/// All sources are injectable; every loader failure degrades
/// honestly (scores → empty series; events → declared form;
/// categories → the snapshot's map) and never throws.
class ClinicianReportCollector {
  /// Stored Daily Scores by `yyyy-MM-dd` day key (from
  /// HealthHistoryStore in production — stored, write-once
  /// values only; §5.3's completeness gate).
  final Future<Map<String, int>> Function() scoreLoader;

  /// Captured medication change events, or null when the fetch
  /// failed (null ≠ "no events": a failed fetch degrades Z5 to
  /// the declared form, per §4.5).
  final Future<List<MedicationChangeEvent>?> Function() eventsLoader;

  /// The account's full category set (name resolution for the
  /// Z4 derivations).
  final Future<List<QuickLogCategory>> Function() categoriesLoader;

  const ClinicianReportCollector({
    required this.scoreLoader,
    required this.eventsLoader,
    required this.categoriesLoader,
  });

  Future<ClinicianReportData> extend(
    ReportSnapshot snapshot, {
    required List<MedicationEntry> allMedications,
  }) async {
    final range = ClinicianReportData(
      snapshot: snapshot,
      dailyScoreSeries: const [],
      medChanges: const [],
      medChangesCaptured: false,
      flareDays: 0,
      flareSeverityMix: const {},
      migraineCount: 0,
      topCategories: const [],
    ).range;
    final rangeKeys = range.dayKeys.toSet();

    Map<String, int> scores = const {};
    try {
      scores = await scoreLoader();
    } catch (_) {
      scores = const {};
    }
    final series = [
      for (final key in range.dayKeys)
        if ((scores[key] ?? 0) > 0) (key, scores[key]!),
    ];

    List<QuickLogCategory> categories = const [];
    try {
      categories = await categoriesLoader();
    } catch (_) {
      categories = const [];
    }
    final names = <int, String>{
      for (final c in categories) c.id: c.name,
      ...snapshot.categoriesMap,
    };
    final symptomsId =
        resolveSummaryCategoryId(categories, name: 'Symptoms', fallbackId: 1);

    final flare = deriveFlareSummary(
      snapshot.logEntries,
      symptomsCategoryId: symptomsId,
      rangeDayKeys: rangeKeys,
    );
    final migraines = deriveMigraineCount(
      snapshot.logEntries,
      categories: categories,
      rangeDayKeys: rangeKeys,
    );
    final top = deriveTopCategories(
      snapshot.logEntries,
      names: names,
      rangeDayKeys: rangeKeys,
    );

    List<MedicationChangeEvent>? events;
    try {
      events = await eventsLoader();
    } catch (_) {
      events = null;
    }
    final List<ClinicianMedChange> changes;
    final bool captured;
    if (events != null) {
      captured = true;
      changes = deriveCapturedMedChanges(
        events,
        // The FULL medication list — the panel's seeding source
        // for the bounding marker set (bounding only; seeded
        // changes never print in captured form).
        medications: allMedications,
        // The FULL stored score map — the same input the panel
        // windows over — not the range-truncated Z3 series: a
        // change near the range edge needs its stored days from
        // both sides of the edge.
        scores: scores,
        rangeStart: range.start,
        rangeEnd: range.end,
      );
    } else {
      captured = false;
      changes = deriveDeclaredMedChanges(
        allMedications,
        rangeStart: range.start,
        rangeEnd: range.end,
      );
    }

    return ClinicianReportData(
      snapshot: snapshot,
      dailyScoreSeries: series,
      medChanges: changes,
      medChangesCaptured: captured,
      flareDays: flare.flareDays,
      flareSeverityMix: flare.severityMix,
      migraineCount: migraines,
      topCategories: top,
      // Phase 4 — biometric summaries derive from the snapshot
      // this same collect produced (no second collection path).
      sleepSummary: summarizeClinicianIntSeries(snapshot.sleepSeries),
      deepSleepSummary:
          summarizeClinicianIntSeries(snapshot.deepSleepSeries),
      hrvSummary: summarizeClinicianDoubleSeries(snapshot.hrvSeries),
      restingHeartRateSummary:
          summarizeClinicianIntSeries(snapshot.heartRateSeries),
      heartRateSpikeSummary:
          summarizeClinicianSpikes(snapshot.heartRateSpikes),
      bloodPressureSummary:
          summarizeClinicianBloodPressure(snapshot.bloodPressureSeries),
    );
  }
}

// ── Generation pipeline (no AI call) ─────────────────────────────

/// The v2 generation path: base collect → clinician extension →
/// fixed-layout render → app-private save → Downloads copy over
/// the SAME bytes before the ready outcome (the Juno Ruling 2
/// contract, identical to the v1 pipeline's tail). There is no
/// AI call anywhere in this path (spec §4.5 / G8).
class ClinicianReportPipeline {
  final ReportDataCollector collector;
  final ClinicianReportCollector clinicianCollector;

  const ClinicianReportPipeline({
    required this.collector,
    required this.clinicianCollector,
  });

  Future<ReportOutcome> generate({
    required List<QuickLogCategory> selectedCategories,
    required bool last30Days,
    required ReportProfileInput profile,
    required Future<List<int>> Function(ClinicianReportData data) renderPdf,
    required Future<String> Function(List<int> bytes, String fileName)
        savePdf,
    Future<bool> Function(List<int> bytes, String fileName)? saveToDownloads,
    void Function(ReportStage stage)? onStage,
    bool Function()? isCancelled,
    DateTime? now,
  }) async {
    bool cancelled() => isCancelled?.call() ?? false;

    final ReportSnapshot snapshot;
    try {
      snapshot = await collector.collect(
        selectedCategories: selectedCategories,
        last30Days: last30Days,
        profile: profile,
        now: now,
        onStage: (s) => onStage?.call(
            s == 'syncing' ? ReportStage.syncing : ReportStage.collecting),
        isCancelled: isCancelled,
      );
    } on ReportCollectionCancelled {
      return const ReportFailed('Cancelled');
    }
    if (cancelled()) return const ReportFailed('Cancelled');

    final data = await clinicianCollector.extend(
      snapshot,
      allMedications: profile.allMedications,
    );
    if (cancelled()) return const ReportFailed('Cancelled');

    onStage?.call(ReportStage.renderingPdf);
    List<int> bytes;
    try {
      bytes = await renderPdf(data);
    } catch (_) {
      return ReportFailed(reportExportFailureMessage, snapshot: snapshot);
    }
    onStage?.call(ReportStage.savingFile);
    final fileName = reportFileName(
        DateTime.fromMillisecondsSinceEpoch(snapshot.generationTimestampMs));
    String savedPath;
    try {
      savedPath = await savePdf(bytes, fileName);
    } catch (_) {
      return ReportFailed(reportExportFailureMessage, snapshot: snapshot);
    }
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
      isRawFallback: false,
      downloadsSaved: downloadsSaved,
    );
  }
}
