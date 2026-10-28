import 'dart:convert';

import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart'
    show categoryIdByName;
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/today_summary.dart' hide dateStrOf;

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
  /// side, item 2 §3). Non-null ONLY when the D1 floor is met
  /// for both windows (each ≥ 5 scored days, ≥ 14 in total);
  /// below the floor no average prints — there is no partial
  /// average and no zero average.
  final ({double average, int scoredDays})? beforeWindow;
  final ({double average, int scoredDays})? afterWindow;

  const ClinicianMedChange({
    required this.day,
    required this.dateLabel,
    required this.label,
    required this.captured,
    this.beforeWindow,
    this.afterWindow,
  });
}

/// Item 2 §3 window computation, shared with the (future) item
/// 2b panel — reused here, not recomputed differently for print
/// (item 2 spec §5).
///
/// [scores] maps device-local `yyyy-MM-dd` day keys to STORED
/// Daily Scores. The change day belongs to the AFTER window for
/// starts and dose/frequency changes and restores, and to the
/// BEFORE window for stops (Juno Item 2 · R4 rule). Windows are
/// 14 days, truncated at neighboring same-medication change
/// days ([neighborDays], exclusive bounds: a before window
/// starts after the previous change day; an after window ends
/// before the next change day) and at the edges of the stored
/// series. Returns null for a window pair unless the D1 floor
/// is met for BOTH windows.
({({double average, int scoredDays}) before, ({double average, int scoredDays}) after})?
    computeMedChangeWindows({
  required DateTime changeDay,
  required bool changeDayInAfter,
  required Map<String, int> scores,
  List<DateTime> neighborDays = const [],
}) {
  final beforeStartBound = neighborDays
      .where((d) => d.isBefore(changeDay))
      .fold<DateTime?>(null, (a, d) => a == null || d.isAfter(a) ? d : a);
  final afterEndBound = neighborDays
      .where((d) => d.isAfter(changeDay))
      .fold<DateTime?>(null, (a, d) => a == null || d.isBefore(a) ? d : a);

  List<int> windowScores(DateTime first, DateTime last) {
    final out = <int>[];
    for (var d = first;
        !d.isAfter(last);
        d = DateTime(d.year, d.month, d.day + 1)) {
      final v = scores[_dayKey(d)];
      if (v != null && v > 0) out.add(v);
    }
    return out;
  }

  final DateTime beforeFirst, beforeLast, afterFirst, afterLast;
  if (changeDayInAfter) {
    beforeLast = DateTime(changeDay.year, changeDay.month, changeDay.day - 1);
    beforeFirst =
        DateTime(changeDay.year, changeDay.month, changeDay.day - 14);
    afterFirst = changeDay;
    afterLast = DateTime(changeDay.year, changeDay.month, changeDay.day + 13);
  } else {
    beforeFirst =
        DateTime(changeDay.year, changeDay.month, changeDay.day - 13);
    beforeLast = changeDay;
    afterFirst =
        DateTime(changeDay.year, changeDay.month, changeDay.day + 1);
    afterLast = DateTime(changeDay.year, changeDay.month, changeDay.day + 14);
  }
  var bf = beforeFirst, al = afterLast;
  if (beforeStartBound != null &&
      !bf.isAfter(beforeStartBound)) {
    bf = DateTime(
        beforeStartBound.year, beforeStartBound.month, beforeStartBound.day + 1);
  }
  if (afterEndBound != null && !al.isBefore(afterEndBound)) {
    al = DateTime(
        afterEndBound.year, afterEndBound.month, afterEndBound.day - 1);
  }

  final before = windowScores(bf, beforeLast);
  final after = windowScores(afterFirst, al);
  // D1 floor (Juno): averages render only when each window has
  // at least 5 scored days and the two windows have 14 scored
  // days in total. Below the floor: no averages at all.
  if (before.length < 5 || after.length < 5 || before.length + after.length < 14) {
    return null;
  }
  double avg(List<int> xs) => xs.fold<int>(0, (a, b) => a + b) / xs.length;
  return (
    before: (average: avg(before), scoredDays: before.length),
    after: (average: avg(after), scoredDays: after.length),
  );
}

/// Average formatting for the window patterns: whole numbers
/// print without a decimal, everything else at one decimal.
String clinicianAverageText(double average) =>
    average == average.roundToDouble()
        ? '${average.round()}'
        : average.toStringAsFixed(1);

// ── Z5 derivations ───────────────────────────────────────────────

/// Whether a captured event type counts as a regimen change for
/// the change-day window rule's "after" side. Stops (and
/// deletes of present meds, which end a regimen the same way)
/// put the change day in the BEFORE window.
bool _changeDayInAfter(String type) =>
    type == 'start' ||
    type == 'dose_change' ||
    type == 'frequency_change' ||
    type == 'restore';

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
List<ClinicianMedChange> deriveCapturedMedChanges(
  List<MedicationChangeEvent> events, {
  required Map<String, int> scores,
  required DateTime rangeStart,
  required DateTime rangeEnd,
}) {
  final printable = [
    for (final e in events)
      if (_printableEventTypes.contains(e.type)) e,
  ];
  // Neighbor days per medication (identity: medId when both
  // sides carry one, else the recorded name) — across ALL
  // printable events, not just in-range ones, so a window never
  // silently crosses a neighboring change (item 2 §3).
  String medKey(MedicationChangeEvent e) =>
      e.medId.isNotEmpty ? 'id:${e.medId}' : 'name:${e.medName}';
  final daysByMed = <String, List<DateTime>>{};
  for (final e in printable) {
    daysByMed.putIfAbsent(medKey(e), () => []).add(_capturedChangeDay(e));
  }
  final out = <ClinicianMedChange>[];
  for (final e in printable) {
    final day = _capturedChangeDay(e);
    if (day.isBefore(rangeStart) || day.isAfter(rangeEnd)) continue;
    final neighbors = [
      for (final d in daysByMed[medKey(e)] ?? const <DateTime>[])
        if (d != day) d,
    ];
    final windows = computeMedChangeWindows(
      changeDay: day,
      changeDayInAfter: _changeDayInAfter(e.type),
      scores: scores,
      neighborDays: neighbors,
    );
    out.add(ClinicianMedChange(
      day: day,
      dateLabel: _capturedDateLabel(e),
      label: _capturedChangeLabel(e),
      captured: true,
      beforeWindow: windows?.before,
      afterWindow: windows?.after,
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

  const ClinicianReportData({
    required this.snapshot,
    required this.dailyScoreSeries,
    required this.medChanges,
    required this.medChangesCaptured,
    required this.flareDays,
    required this.flareSeverityMix,
    required this.migraineCount,
    required this.topCategories,
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
        scores: {for (final e in series) e.$1: e.$2},
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

    final snapshot = await collector.collect(
      selectedCategories: selectedCategories,
      last30Days: last30Days,
      profile: profile,
      now: now,
      onStage: (s) => onStage?.call(
          s == 'syncing' ? ReportStage.syncing : ReportStage.collecting),
    );
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
