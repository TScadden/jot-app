import 'dart:convert';

import 'package:tabs_lab/src/data/correlation_engine.dart';
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

// ── Phase 4 strings ruled by Juno on Nov 12 2026 (rulings 1 and 2) ────────

/// clinician Z1, all demographic fields absent
const String clinicianPatientProfileNotRecorded =
    'Patient profile details not recorded';

/// clinician Z2, sync pull failure
const String clinicianMedicationRecordsUnavailable =
    'Medication records unavailable';

/// clinician Z4, logs pull failure
const String clinicianLogEntriesUnavailable =
    'Log entries unavailable';

/// clinician Z5, no change lines
const String clinicianNoMedChangesRecorded =
    'No medication changes recorded in audit period';

/// clinician Z5, a captured change below the score window floor
const String clinicianInsufficientScoreData =
    'Insufficient score data for 14-day comparison';

/// clinician Z4, categories load failure
const String clinicianCategoriesUnavailable =
    'Categories could not be retrieved.';

/// clinician Z4, successful loads and an empty top categories list
const String clinicianTopCategoriesEmpty =
    'No category entries recorded in this range.';

/// clinician Sleep zone heading (ruled)
const String clinicianHeadingSleep = 'Sleep';

/// clinician Sleep zone, sleep duration data failure statuses (permissionDenied, stale, error)
const String clinicianSleepUnavailable =
    'Sleep data could not be retrieved for this period.';

/// clinician Sleep zone, clean read returning no sleep duration data
const String clinicianSleepNoData = 'No sleep recorded in this range.';

/// clinician Sleep zone, deep sleep data failure statuses (permissionDenied, stale, error)
const String clinicianDeepSleepUnavailable =
    'Deep sleep data could not be retrieved for this period.';

/// clinician Sleep zone, clean read returning no deep sleep data
const String clinicianDeepSleepNoData =
    'No deep sleep recorded in this range.';

/// clinician Sleep zone label, reusing approved wording
const String clinicianLabelSleepDuration = 'Sleep Duration';

/// clinician Sleep zone label, reusing approved wording
const String clinicianLabelDeepSleep = 'Deep Sleep';

/// clinician HRV zone heading
const String clinicianHeadingHrv = 'HRV (RMSSD)';

/// clinician Resting Heart Rate zone heading
const String clinicianHeadingRestingHeartRate = 'Resting Heart Rate';

/// clinician HRV zone, failure statuses (permissionDenied, stale, error)
const String clinicianHrvUnavailable =
    'HRV (RMSSD) data could not be retrieved for this period.';

/// clinician HRV zone, clean read returning no data
const String clinicianHrvNoData = 'No HRV (RMSSD) recorded in this range.';

/// clinician Resting Heart Rate zone, failure statuses (permissionDenied, stale, error)
const String clinicianRestingHrUnavailable =
    'Resting heart rate data could not be retrieved for this period.';

/// clinician Resting Heart Rate zone, clean read returning no data
const String clinicianRestingHrNoData =
    'No resting heart rate recorded in this range.';

/// clinician HR spikes zone, failure statuses (permissionDenied, stale, error)
const String clinicianHrSpikesUnavailable =
    'HR spike data could not be retrieved for this period.';

/// clinician HR spikes zone, clean read returning no data
const String clinicianHrSpikesNoData =
    'No heart rate spike data recorded in this range.';

/// clinician Patterns zone, clean read returning no printable patterns
const String clinicianNoPatternsDetected =
    'No patterns detected for this period';

/// clinician Patterns zone, insight store load failure
const String clinicianPatternsUnavailable =
    'Patterns data could not be retrieved.';

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

// ── Clinician metric summaries (sleep & biometrics) ──────────────

/// Summary statistics for a biometric integer series (e.g. sleep duration,
/// deep sleep).
class ClinicianMetricSummary {
  final int count;
  final double min;
  final double max;
  final double average;

  const ClinicianMetricSummary({
    required this.count,
    required this.min,
    required this.max,
    required this.average,
  });
}

/// Derives summary statistics from a date-keyed biometric integer series
/// (e.g. sleep minutes per day). Keeps only values greater than 0 (a zero
/// in biometric data is a failed read, never a measurement). Returns null
/// when nothing remains, and otherwise computes count, minimum, maximum,
/// and the arithmetic mean as a double.
ClinicianMetricSummary? deriveClinicianMetricSummary(
  List<(String, int)> series,
) {
  final positiveValues = <int>[];
  for (final record in series) {
    if (record.$2 > 0) {
      positiveValues.add(record.$2);
    }
  }
  if (positiveValues.isEmpty) return null;

  var minVal = positiveValues.first.toDouble();
  var maxVal = positiveValues.first.toDouble();
  var sum = 0.0;
  for (final v in positiveValues) {
    final d = v.toDouble();
    if (d < minVal) minVal = d;
    if (d > maxVal) maxVal = d;
    sum += d;
  }
  return ClinicianMetricSummary(
    count: positiveValues.length,
    min: minVal,
    max: maxVal,
    average: sum / positiveValues.length,
  );
}

/// Derives summary statistics from a date-keyed biometric double series
/// (e.g. HRV RMSSD values). Keeps only values greater than 0 (a zero
/// in biometric data is a failed read, never a measurement). Returns null
/// when nothing remains, and otherwise computes count, minimum, maximum,
/// and the arithmetic mean as a double.
ClinicianMetricSummary? deriveClinicianMetricSummaryD(
  List<(String, double)> series,
) {
  final positiveValues = <double>[];
  for (final record in series) {
    if (record.$2 > 0) {
      positiveValues.add(record.$2);
    }
  }
  if (positiveValues.isEmpty) return null;

  var minVal = positiveValues.first;
  var maxVal = positiveValues.first;
  var sum = 0.0;
  for (final v in positiveValues) {
    if (v < minVal) minVal = v;
    if (v > maxVal) maxVal = v;
    sum += v;
  }
  return ClinicianMetricSummary(
    count: positiveValues.length,
    min: minVal,
    max: maxVal,
    average: sum / positiveValues.length,
  );
}

/// Summary statistics for heart rate spikes.
class ClinicianSpikeSummary {
  final int total;
  final int sampledDays;

  const ClinicianSpikeSummary({
    required this.total,
    required this.sampledDays,
  });
}

/// Derives summary statistics from a date-keyed spike count series. Returns null
/// when the list is empty and otherwise the sum of all values as total and the
/// list length as sampledDays. Days with 0 spikes are real sampled days and must
/// not be filtered.
ClinicianSpikeSummary? deriveClinicianSpikeSummary(
  List<(String, int)> series,
) {
  if (series.isEmpty) return null;
  var sum = 0;
  for (final record in series) {
    sum += record.$2;
  }
  return ClinicianSpikeSummary(
    total: sum,
    sampledDays: series.length,
  );
}

// Ruled by Juno in juno-rulings-4-p4-templates.md, Task 1 Items 1a/1b:
// APPROVED WITH EDIT — the day-word is 'day' at a count of exactly 1 and
// 'days' otherwise; every other character is verbatim as templated.

/// Sleep duration summary line:
/// Sleep Duration: average `<avg>` across 1 day (count 1)
/// Sleep Duration: average `<avg>` across `<count>` days [ · range `<min>` to `<max>`] (count > 1)
String clinicianSleepDurationLine(ClinicianMetricSummary summary) {
  final line =
      '$clinicianLabelSleepDuration: average ${formatSleepMinutes(summary.average.round())} across ${summary.count} ${summary.count == 1 ? 'day' : 'days'}';
  if (summary.count > 1) {
    return '$line \u00B7 range ${formatSleepMinutes(summary.min.round())} to ${formatSleepMinutes(summary.max.round())}';
  }
  return line;
}

/// Deep sleep summary line:
/// Deep Sleep: average `<avg>` across 1 day (count 1)
/// Deep Sleep: average `<avg>` across `<count>` days [ · range `<min>` to `<max>`] (count > 1)
String clinicianDeepSleepLine(ClinicianMetricSummary summary) {
  final line =
      '$clinicianLabelDeepSleep: average ${formatSleepMinutes(summary.average.round())} across ${summary.count} ${summary.count == 1 ? 'day' : 'days'}';
  if (summary.count > 1) {
    return '$line \u00B7 range ${formatSleepMinutes(summary.min.round())} to ${formatSleepMinutes(summary.max.round())}';
  }
  return line;
}

// Ruled by Juno in juno-rulings-4-p4-templates.md, Task 1 Item 2:
// APPROVED WITH EDIT — the day-word is 'day' at a count of exactly 1 and
// 'days' otherwise; every other character is verbatim as templated.

/// HRV summary line:
/// HRV (RMSSD): average `<avg>` ms across 1 day (count 1)
/// HRV (RMSSD): average `<avg>` ms across `<count>` days [ · range `<min>` ms to `<max>` ms] (count > 1)
String clinicianHrvLine(ClinicianMetricSummary summary) {
  final line =
      '$clinicianHeadingHrv: average ${summary.average.toStringAsFixed(1)} ms across ${summary.count} ${summary.count == 1 ? 'day' : 'days'}';
  if (summary.count > 1) {
    return '$line \u00B7 range ${summary.min.toStringAsFixed(1)} ms to ${summary.max.toStringAsFixed(1)} ms';
  }
  return line;
}

// Ruled by Juno in juno-rulings-4-p4-templates.md, Task 1 Item 3:
// APPROVED WITH EDIT — the day-word is 'day' at a count of exactly 1 and
// 'days' otherwise; every other character is verbatim as templated.

/// Resting heart rate summary line:
/// Resting Heart Rate: average `<avg>` bpm across 1 day (count 1)
/// Resting Heart Rate: average `<avg>` bpm across `<count>` days [ · range `<min>` bpm to `<max>` bpm] (count > 1)
String clinicianRestingHrLine(ClinicianMetricSummary summary) {
  final line =
      '$clinicianHeadingRestingHeartRate: average ${clinicianAverageText(summary.average)} bpm across ${summary.count} ${summary.count == 1 ? 'day' : 'days'}';
  if (summary.count > 1) {
    return '$line \u00B7 range ${clinicianAverageText(summary.min)} bpm to ${clinicianAverageText(summary.max)} bpm';
  }
  return line;
}

// Ruled by Juno in juno-rulings-4-p4-templates.md, Task 1 Item 4:
// APPROVED WITH EDIT — the day-word is 'day' at sampledDays exactly 1
// and 'days' otherwise; every other character is verbatim as templated.

/// Heart rate spikes summary line:
/// HR Spikes (>=100 BPM): `<total>` recorded across 1 day (sampledDays 1)
/// HR Spikes (>=100 BPM): `<total>` recorded across `<sampledDays>` days (sampledDays > 1)
String clinicianHrSpikesLine(ClinicianSpikeSummary summary) {
  return 'HR Spikes (>=100 BPM): ${summary.total} recorded across ${summary.sampledDays} ${summary.sampledDays == 1 ? 'day' : 'days'}';
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
  final bool categoriesLoadFailed;
  final List<InsightRecord> patternInsights;
  final bool patternsLoadFailed;

  const ClinicianReportData({
    required this.snapshot,
    required this.dailyScoreSeries,
    required this.medChanges,
    required this.medChangesCaptured,
    required this.flareDays,
    required this.flareSeverityMix,
    required this.migraineCount,
    required this.topCategories,
    this.categoriesLoadFailed = false,
    this.patternInsights = const [],
    this.patternsLoadFailed = false,
  });

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

/// Extends a base [ReportSnapshot] with clinician fields. A score load
/// failure is recorded as an error status in the snapshot sectionMetadata
/// under dailyScore. All sources are injectable and never throw.
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

    var scoreLoadFailed = false;
    Map<String, int> scores = const {};
    try {
      scores = await scoreLoader();
    } catch (_) {
      scoreLoadFailed = true;
      scores = const {};
    }
    final series = [
      for (final key in range.dayKeys)
        if ((scores[key] ?? 0) > 0) (key, scores[key]!),
    ];
    final effectiveSnapshot = scoreLoadFailed
        ? snapshot.withSectionStatus('dailyScore', DataSourceStatus.error, 0)
        : snapshot.withSectionStatus(
            'dailyScore',
            series.isEmpty ? DataSourceStatus.noData : DataSourceStatus.success,
            series.length,
          );

    var categoriesLoadFailed = false;
    List<QuickLogCategory> categories = const [];
    try {
      categories = await categoriesLoader();
    } catch (_) {
      categoriesLoadFailed = true;
      categories = [
        for (final entry in snapshot.categoriesMap.entries)
          QuickLogCategory(
            id: entry.key,
            name: entry.value,
            icon: '',
            colorHex: '',
            isDefault: false,
            sortOrder: 0,
          ),
      ];
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
      snapshot: effectiveSnapshot,
      dailyScoreSeries: series,
      medChanges: changes,
      medChangesCaptured: captured,
      flareDays: flare.flareDays,
      flareSeverityMix: flare.severityMix,
      migraineCount: migraines,
      topCategories: top,
      categoriesLoadFailed: categoriesLoadFailed,
      patternInsights: effectiveSnapshot.correlationInsights,
      patternsLoadFailed: effectiveSnapshot.correlationInsightsLoadFailed,
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

  /// VC 100129 (R-2 T1-2): the save-step journal hook, identical
  /// to the standard pipeline's — invoked with the exact file
  /// name and path the moment the PDF save lands, before the
  /// ReportReady outcome exists.
  final void Function(String fileName, String savedPath)? onArtifactSaved;

  const ClinicianReportPipeline({
    required this.collector,
    required this.clinicianCollector,
    this.onArtifactSaved,
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

    // VC 100130: the last stage the collector reported, kept so a
    // collection timeout's diagnostic record names where the
    // collection actually was when the deadline fired (this
    // pipeline shares the standard collector, so it inherits the
    // VC 100130 per-read / union-budget / fetch-cap bounds).
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
      return ReportFailed(reportExportFailureMessage,
          allowRawFallback: true,
          failureKind: ReportFailureKind.collectionTimeout,
          failureStage: lastCollectStage);
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
      return ReportFailed(reportExportFailureMessage,
          snapshot: snapshot,
          failureKind: ReportFailureKind.renderFailure,
          failureStage: ReportStage.renderingPdf);
    }
    onStage?.call(ReportStage.savingFile);
    final fileName = reportFileName(
        DateTime.fromMillisecondsSinceEpoch(snapshot.generationTimestampMs));
    String savedPath;
    try {
      savedPath = await savePdf(bytes, fileName);
    } catch (_) {
      return ReportFailed(reportExportFailureMessage,
          snapshot: snapshot,
          failureKind: ReportFailureKind.saveFailure,
          failureStage: ReportStage.savingFile);
    }
    try {
      onArtifactSaved?.call(fileName, savedPath);
    } catch (_) {
      // Journaling never breaks a generation.
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
