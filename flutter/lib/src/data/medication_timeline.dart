import 'dart:convert';

import 'package:tabs_lab/src/data/health_history_store.dart'
    show DailyBiometrics;
import 'package:tabs_lab/src/data/medication_change_events.dart';
import 'package:tabs_lab/src/data/medications.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/today_summary.dart'
    show dateStrOf, resolveSummaryCategoryId;

/// Phase 1, item 2b — the medication timeline's PURE derivation
/// layer (spec §3 + §5; Juno's item 2 rulings, 2026-10-28).
///
/// Everything here is a pure function over plain inputs: captured
/// change events (item 2a), the current medication rows, a score
/// map built from `HealthHistoryStore.readRange` output, and the
/// synced log entries + categories. The screen wires the real
/// sources; tests drive this layer directly. This layer READS the
/// score series only — nothing here writes the score store or
/// triggers score computation (spec standing rule: scores are
/// write-once; a timeline reads them, never recomputes them).
///
/// Honesty rules baked into the derivation:
/// - Averages are means over SCORED days only (null scores are
///   missing data, never zero-filled). A day whose score is 0 in
///   the map is a real stored score and counts — the store's own
///   zero rule already strips failed biometric reads upstream;
///   what reaches this layer as null is absent, and absent is
///   missing, never 0.
/// - The D1 shared floor (Juno): window averages are EXPOSED
///   only when before scored days ≥ 5 AND after scored days ≥ 5
///   AND the total ≥ 14. Below the floor the result carries the
///   real counts and NO averages — partial averages do not exist
///   in this layer's output, so no surface can render one.
/// - Juno R2: this layer computes NO difference, percent change,
///   or ordering between the two window averages, ever.
/// - The chart axis is calendar-continuous: every day in range
///   occupies a slot; unscored days are explicit gaps.

/// The marker classes the timeline renders (Juno's Draft 6 label
/// set). Captured `delete` and `dates_edit` events are NOT
/// markers — her label set has no label for them.
enum TimelineMarkerKind { start, stop, doseChange, frequencyChange, restore }

extension TimelineMarkerKindX on TimelineMarkerKind {
  /// The capture-contract event type string for this kind (the
  /// §5 handoff's `event type` field).
  String get eventType => switch (this) {
        TimelineMarkerKind.start => 'start',
        TimelineMarkerKind.stop => 'stop',
        TimelineMarkerKind.doseChange => 'dose_change',
        TimelineMarkerKind.frequencyChange => 'frequency_change',
        TimelineMarkerKind.restore => 'restore',
      };

  /// Start-class kinds count their change day in the AFTER
  /// window; stops count it in the BEFORE window (the R4 rule).
  /// Restore is start-class: the med is back on from that day.
  bool get countsChangeDayInAfter => this != TimelineMarkerKind.stop;
}

/// One dated medication-change marker on the timeline.
class TimelineMarker {
  final TimelineMarkerKind kind;

  /// The medication row id at capture/seed time; may be `''`.
  final String medId;

  /// The name exactly as recorded (event snapshot name, or the
  /// surviving row's name for a seed). A since-deleted med's
  /// markers keep their snapshot name.
  final String medName;

  /// The anchor day (local, date-only) the marker occupies.
  final DateTime date;

  /// The date as it renders: the recorded date STRING verbatim
  /// for declared/effective dates (a month-precision string like
  /// `Jun 2026` is never reformatted into a fake-exact day), or
  /// a plain `MMM d, yyyy` date for capture-time anchors
  /// (dose/frequency changes, restores).
  final String dateDisplay;

  /// True when [dateDisplay] carries month precision only;
  /// [date] is then the 1st of that month (the
  /// [parseMedicationDate] convention) and the precision is
  /// carried to the render via [dateDisplay].
  final bool monthPrecision;

  /// True for a pre-capture seed derived from the current
  /// medication list (carries Juno's Draft 7 provenance label);
  /// false for a captured event (no provenance label).
  final bool seeded;

  /// The dose in effect from this marker onward (new snapshot),
  /// or — for a stop — the dose that was stopped (old snapshot).
  /// This is the §5 handoff's "dose at event".
  final String doseAtEvent;

  /// Label parts for change markers: the recorded old/new dose
  /// (doseChange) or old/new frequency (frequencyChange).
  final String oldValue;
  final String newValue;

  /// The regimen in effect from this marker until the next one
  /// for the same medication (the lane segment's governing
  /// snapshot): dose, frequency, and whether the med is being
  /// taken at all in that span.
  final String afterDose;
  final String afterFrequency;
  final bool afterIsPresent;

  /// Sequence key for ordering markers that share an anchor
  /// day: the capture time for captured events (two changes on
  /// one day order as they were recorded), the anchor day's
  /// start for seeds.
  final int recordedAtMs;

  const TimelineMarker({
    required this.kind,
    required this.medId,
    required this.medName,
    required this.date,
    required this.dateDisplay,
    required this.monthPrecision,
    required this.seeded,
    required this.doseAtEvent,
    this.oldValue = '',
    this.newValue = '',
    required this.afterDose,
    required this.afterFrequency,
    required this.afterIsPresent,
    this.recordedAtMs = 0,
  });

  /// Identity key for same-medication grouping: the row id when
  /// non-empty, else the recorded name (mirrors the dedup rule).
  String get medKey =>
      medId.isNotEmpty ? 'id:$medId' : 'name:${medName.trim().toLowerCase()}';
}

/// One calendar day on the timeline's continuous axis.
class TimelineDay {
  final DateTime date;

  /// The day's stored Daily Score, or null when the day is
  /// unscored — an EMPTY GAP on the chart, never a zero bar and
  /// never omitted from the axis.
  final int? score;

  final bool isFlareDay;
  final bool isMigraineDay;

  /// Per-day count of Symptoms-category log entries.
  final int symptomLogCount;

  /// Markers anchored on this day (may be several).
  final List<TimelineMarker> markers;

  const TimelineDay({
    required this.date,
    required this.score,
    required this.isFlareDay,
    required this.isMigraineDay,
    required this.symptomLogCount,
    required this.markers,
  });
}

/// Before/after window arithmetic for ONE marker at ONE selected
/// window length (spec §3; Juno R4 + D1).
///
/// Spans are the TRUNCATED calendar-day counts actually averaged
/// (windows truncate at the stored-series edges and at the
/// neighboring same-medication marker's regimen boundary); the
/// panel's label interpolates the span, which is how the
/// truncation is stated. Averages are non-null ONLY when
/// [floorMet] — below the floor there are counts and no averages.
class TimelineWindowResult {
  /// The selected window length (7 / 14 / 30).
  final int requestedDays;

  /// Actual calendar-day span of each truncated window.
  final int beforeSpanDays;
  final int afterSpanDays;

  /// Scored days (non-null scores) inside each truncated window.
  final int beforeScoredDays;
  final int afterScoredDays;

  /// Mean Daily Score over scored days only, rounded to a whole
  /// number (scores are whole 0–100). Non-null ONLY at the D1
  /// floor — see the class doc.
  final int? beforeAverage;
  final int? afterAverage;

  const TimelineWindowResult({
    required this.requestedDays,
    required this.beforeSpanDays,
    required this.afterSpanDays,
    required this.beforeScoredDays,
    required this.afterScoredDays,
    required this.beforeAverage,
    required this.afterAverage,
  });

  /// The D1 shared floor: ≥ 5 scored days in EACH window and
  /// ≥ 14 scored days in total. Identical at every window length.
  bool get floorMet =>
      beforeScoredDays >= 5 &&
      afterScoredDays >= 5 &&
      (beforeScoredDays + afterScoredDays) >= 14;
}

/// One medication's lane: its markers chronologically, plus the
/// dose/frequency segments between them.
class TimelineMedLane {
  /// Display name: the surviving row's name when the row exists,
  /// else the latest marker's snapshot name.
  final String medName;
  final String medId;
  final List<TimelineMarker> markers;

  /// Segment i is governed by marker i's after-snapshot and runs
  /// from marker i's day to marker i+1's day (or the range end
  /// for the last marker).
  final List<TimelineLaneSegment> segments;

  const TimelineMedLane({
    required this.medName,
    required this.medId,
    required this.markers,
    required this.segments,
  });
}

/// One lane segment: the span between two consecutive events for
/// a medication, labeled with the governing snapshot's dose and
/// frequency.
class TimelineLaneSegment {
  final DateTime startDate;

  /// Exclusive end (the next marker's day), or the timeline
  /// range end for the final segment.
  final DateTime endDate;
  final String dose;
  final String frequency;

  /// Whether the med was being taken during this segment
  /// (false for the span after a stop).
  final bool isPresent;

  /// True when this segment's opening boundary is a seeded
  /// marker (carries the provenance label in the lane).
  final bool startsSeeded;

  const TimelineLaneSegment({
    required this.startDate,
    required this.endDate,
    required this.dose,
    required this.frequency,
    required this.isPresent,
    required this.startsSeeded,
  });
}

/// The §5 handoff shape (item 3's clinician PDF consumes exactly
/// this): one change in a range, with its provenance and the
/// SAME window computation the panel renders — one derivation,
/// no second implementation for print.
class MedicationChangeSummary {
  final DateTime date;

  /// The recorded date string verbatim (see [TimelineMarker]).
  final String dateDisplay;
  final String medName;

  /// The capture-contract type string (`start`, `stop`,
  /// `dose_change`, `frequency_change`, `restore`).
  final String eventType;
  final String doseAtEvent;

  /// Provenance: true = declared (seeded from the medication
  /// list), false = captured.
  final bool seeded;

  /// The panel's window computation for this change.
  final TimelineWindowResult windows;

  const MedicationChangeSummary({
    required this.date,
    required this.dateDisplay,
    required this.medName,
    required this.eventType,
    required this.doseAtEvent,
    required this.seeded,
    required this.windows,
  });
}

/// The full derived timeline.
class MedicationTimelineData {
  /// All markers, chronological (same-day markers keep input
  /// order: captured events before seeds on a tie).
  final List<TimelineMarker> markers;

  /// The calendar-continuous day axis, [rangeStart]..[rangeEnd]
  /// inclusive, one slot per day.
  final List<TimelineDay> days;
  final DateTime rangeStart;
  final DateTime rangeEnd;

  /// Seed candidates that produced no marker because their
  /// declared date string was blank or unparseable (spec §7
  /// test 10's accounting — counted, never silently dropped).
  /// There is NO approved UI string for this count; it is
  /// derivation accounting for tests and the handoff only.
  final int skippedSeedCount;

  /// Per-medication lanes (med list + drill-down), ordered by
  /// earliest marker, then name.
  final List<TimelineMedLane> lanes;

  /// The score map this timeline was derived from (date string
  /// → score or null), retained so the panel's window math runs
  /// the identical computation as the handoff (§5/§7 test 17).
  final Map<String, int?> scoresByDate;

  const MedicationTimelineData({
    required this.markers,
    required this.days,
    required this.rangeStart,
    required this.rangeEnd,
    required this.skippedSeedCount,
    required this.lanes,
    required this.scoresByDate,
  });

  /// The before/after windows for [marker] at [windowDays] —
  /// THE panel computation (and the handoff's, via
  /// [changeSummaries]).
  TimelineWindowResult windowsFor(TimelineMarker marker, int windowDays) =>
      computeMedicationWindows(
        marker: marker,
        allMarkers: markers,
        scoresByDate: scoresByDate,
        windowDays: windowDays,
      );

  /// The §5 handoff list for [start]..[end] (inclusive) at
  /// [windowDays]: every marker in range with its window result,
  /// computed by the same [windowsFor] the panel uses.
  List<MedicationChangeSummary> changeSummaries(
    DateTime start,
    DateTime end, {
    int windowDays = 14,
  }) {
    final s = _dayOnly(start);
    final e = _dayOnly(end);
    return [
      for (final m in markers)
        if (!m.date.isBefore(s) && !m.date.isAfter(e))
          MedicationChangeSummary(
            date: m.date,
            dateDisplay: m.dateDisplay,
            medName: m.medName,
            eventType: m.kind.eventType,
            doseAtEvent: m.doseAtEvent,
            seeded: m.seeded,
            windows: windowsFor(m, windowDays),
          ),
    ];
  }
}

DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

/// Builds the score map (date string → Daily Score or null) from
/// `HealthHistoryStore.readRange` output — the ONLY score input
/// the derivation consumes. Days present in the store without a
/// score map to null (present but unscored); days absent from
/// the store are absent from the map. Pure projection; the store
/// is never written.
Map<String, int?> scoreMapFromHistoryRows(
    Map<String, DailyBiometrics> rows) {
  final out = <String, int?>{};
  for (final e in rows.entries) {
    out[e.key] = e.value.dailyScore;
  }
  return out;
}

/// Whether a declared medication date string carries MONTH
/// precision only (month + year, no day) — the same grammar
/// [parseMedicationDate] accepts. Month-precision strings anchor
/// on the 1st and render verbatim.
bool medicationDateIsMonthOnly(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return false;
  final m = RegExp(r'^([A-Za-z]+)\.?\s+(?:(\d{1,2})\s*,?\s*)?(\d{4})$')
      .firstMatch(s);
  return m != null && m.group(2) == null;
}

/// Tolerant parse of an entry's chips JSON-array string into
/// labels (the History precedent, `parseEntryChips`): malformed
/// payloads are NO chips. Never throws.
List<String> parseTimelineChips(String chipsJson) {
  final raw = chipsJson.trim();
  if (raw.isEmpty) return const [];
  try {
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      return [
        for (final c in decoded)
          if (c != null && '$c'.trim().isNotEmpty) '$c'.trim(),
      ];
    }
  } catch (_) {
    // Malformed chips are no chips.
  }
  return const [];
}

/// The reserved chip that marks a flare day (spec §2.4: an entry
/// in the Symptoms category whose parsed chips contain it).
const String flareDayChip = 'Flare Day';

/// The chip that identifies a migraine Trends entry (the synced
/// form of an attack — `migraine_trends.dart` writes exactly
/// `["Migraine attack"]`; the local attack store is never used).
const String migraineTrendsChip = 'Migraine attack';

/// Same-medication identity for windowing/dedup: row-id match
/// when BOTH ids are non-empty, else a name match.
bool _sameMed(String aId, String aName, String bId, String bName) {
  if (aId.isNotEmpty && bId.isNotEmpty) return aId == bId;
  return aName.trim().toLowerCase() == bName.trim().toLowerCase();
}

/// The first day of [marker]'s AFTER regimen (the change day for
/// start-class kinds; the day after for a stop, whose change day
/// belongs to its before window).
DateTime _afterWindowStart(TimelineMarker m) =>
    m.kind.countsChangeDayInAfter ? m.date : m.date.add(const Duration(days: 1));

/// The last day of [marker]'s BEFORE regimen (the day before the
/// change for start-class kinds; the change day for a stop).
DateTime _beforeWindowEnd(TimelineMarker m) => m.kind.countsChangeDayInAfter
    ? m.date.subtract(const Duration(days: 1))
    : m.date;

/// Computes the before/after window result for [marker] at
/// [windowDays] (spec §3, Juno R4 + D1). Pure over [allMarkers]
/// (same-med neighbors truncate) and [scoresByDate] (the stored
/// series' edges truncate; the scored-day counts and spans are
/// always the truncated truth).
TimelineWindowResult computeMedicationWindows({
  required TimelineMarker marker,
  required List<TimelineMarker> allMarkers,
  required Map<String, int?> scoresByDate,
  required int windowDays,
}) {
  // Stored-series edges: the min/max days present in the map.
  DateTime? seriesStart;
  DateTime? seriesEnd;
  for (final k in scoresByDate.keys) {
    final d = DateTime.tryParse(k);
    if (d == null) continue;
    final day = _dayOnly(d);
    if (seriesStart == null || day.isBefore(seriesStart)) seriesStart = day;
    if (seriesEnd == null || day.isAfter(seriesEnd)) seriesEnd = day;
  }

  // Neighboring same-medication markers bound the regimen: the
  // before window never starts before the previous marker's
  // after-regimen begins, and the after window never ends after
  // the next marker's before-regimen ends. "Previous"/"next"
  // are sequence relations — by anchor day, then by capture
  // sequence within a day (a dose change recorded in the
  // morning and a stop recorded that evening bound each other
  // in that order, and only the NEAREST neighbor binds).
  int sequenceCompare(TimelineMarker a, TimelineMarker b) {
    final byDate = a.date.compareTo(b.date);
    if (byDate != 0) return byDate;
    return a.recordedAtMs.compareTo(b.recordedAtMs);
  }

  TimelineMarker? prevMarker;
  TimelineMarker? nextMarker;
  for (final other in allMarkers) {
    if (identical(other, marker)) continue;
    if (!_sameMed(other.medId, other.medName, marker.medId, marker.medName)) {
      continue;
    }
    final cmp = sequenceCompare(other, marker);
    if (cmp < 0) {
      if (prevMarker == null || sequenceCompare(other, prevMarker) > 0) {
        prevMarker = other;
      }
    } else if (cmp > 0) {
      if (nextMarker == null || sequenceCompare(other, nextMarker) < 0) {
        nextMarker = other;
      }
    }
  }
  final prevBound = prevMarker == null ? null : _afterWindowStart(prevMarker);
  final nextBound = nextMarker == null ? null : _beforeWindowEnd(nextMarker);

  (int span, int scored, int? average) window(
      DateTime wantStart, DateTime wantEnd) {
    var start = wantStart;
    var end = wantEnd;
    if (seriesStart == null || seriesEnd == null) {
      return (0, 0, null);
    }
    if (start.isBefore(seriesStart)) start = seriesStart;
    if (end.isAfter(seriesEnd)) end = seriesEnd;
    if (end.isBefore(start)) return (0, 0, null);
    final span = end.difference(start).inDays + 1;
    var scored = 0;
    var sum = 0;
    for (var i = 0; i < span; i++) {
      final key = dateStrOf(start.add(Duration(days: i)));
      final score = scoresByDate[key];
      if (score != null) {
        scored++;
        sum += score;
      }
    }
    return (span, scored, scored == 0 ? null : (sum / scored).round());
  }

  final beforeEnd = _beforeWindowEnd(marker);
  var beforeStart = beforeEnd.subtract(Duration(days: windowDays - 1));
  if (prevBound != null && beforeStart.isBefore(prevBound)) {
    beforeStart = prevBound;
  }
  final afterStart = _afterWindowStart(marker);
  var afterEnd = afterStart.add(Duration(days: windowDays - 1));
  if (nextBound != null && afterEnd.isAfter(nextBound)) {
    afterEnd = nextBound;
  }

  final before = window(beforeStart, beforeEnd);
  final after = window(afterStart, afterEnd);
  final floorMet = before.$2 >= 5 &&
      after.$2 >= 5 &&
      (before.$2 + after.$2) >= 14;
  return TimelineWindowResult(
    requestedDays: windowDays,
    beforeSpanDays: before.$1,
    afterSpanDays: after.$1,
    beforeScoredDays: before.$2,
    afterScoredDays: after.$2,
    // D1: below the floor there are NO averages to render —
    // the raw means are discarded here, not merely hidden.
    beforeAverage: floorMet ? before.$3 : null,
    afterAverage: floorMet ? after.$3 : null,
  );
}

/// Anchors a captured marker-class event. Returns null for
/// non-marker types (`delete`, `dates_edit`, unknown).
TimelineMarker? _capturedMarker(MedicationChangeEvent e) {
  final kind = switch (e.type) {
    'start' => TimelineMarkerKind.start,
    'stop' => TimelineMarkerKind.stop,
    'dose_change' => TimelineMarkerKind.doseChange,
    'frequency_change' => TimelineMarkerKind.frequencyChange,
    'restore' => TimelineMarkerKind.restore,
    _ => null,
  };
  if (kind == null) return null;

  final recordedDay =
      _dayOnly(DateTime.fromMillisecondsSinceEpoch(e.recordedAt));
  // Anchor rule: the parsed effectiveDate when present, else the
  // local day of recordedAt. ONE deliberate exception — restore:
  // its effectiveDate is the erased stop date the unarchive
  // preserved (see the 2a capture code), NOT the day the med was
  // restarted; a restore anchors on its capture day.
  DateTime date;
  String dateDisplay;
  var monthPrecision = false;
  final effective = e.effectiveDate?.trim() ?? '';
  final parsedEffective =
      (kind == TimelineMarkerKind.restore || effective.isEmpty)
          ? null
          : parseMedicationDate(effective);
  if (parsedEffective != null) {
    date = _dayOnly(parsedEffective);
    // Verbatim recorded string — never reformatted.
    dateDisplay = effective;
    monthPrecision = medicationDateIsMonthOnly(effective);
  } else {
    date = recordedDay;
    dateDisplay = formatMedArchiveDate(recordedDay);
  }

  final newSnap = e.newSnapshot;
  final oldSnap = e.oldSnapshot;
  return TimelineMarker(
    kind: kind,
    medId: e.medId,
    medName: e.medName,
    date: date,
    dateDisplay: dateDisplay,
    monthPrecision: monthPrecision,
    seeded: false,
    doseAtEvent: kind == TimelineMarkerKind.stop
        ? (oldSnap?.dose ?? newSnap?.dose ?? '')
        : (newSnap?.dose ?? oldSnap?.dose ?? ''),
    oldValue: kind == TimelineMarkerKind.doseChange
        ? (oldSnap?.dose ?? '')
        : kind == TimelineMarkerKind.frequencyChange
            ? (oldSnap?.frequency ?? '')
            : '',
    newValue: kind == TimelineMarkerKind.doseChange
        ? (newSnap?.dose ?? '')
        : kind == TimelineMarkerKind.frequencyChange
            ? (newSnap?.frequency ?? '')
            : '',
    afterDose: newSnap?.dose ?? oldSnap?.dose ?? '',
    afterFrequency: newSnap?.frequency ?? oldSnap?.frequency ?? '',
    afterIsPresent: newSnap?.isPresent ?? kind != TimelineMarkerKind.stop,
    recordedAtMs: e.recordedAt,
  );
}

/// The full derivation: captured markers + seeded markers
/// (deduped, captured wins), the calendar-continuous day axis
/// with the score/flare/migraine/symptom series, and the
/// per-medication lanes.
MedicationTimelineData buildMedicationTimeline({
  required List<MedicationChangeEvent> events,
  required List<MedicationEntry> medications,
  required Map<String, int?> scoresByDate,
  required List<QuickLogEntry> entries,
  required List<QuickLogCategory> categories,
  required DateTime today,
}) {
  final todayDay = _dayOnly(today);

  // ── Captured markers ────────────────────────────────────────
  final captured = <TimelineMarker>[];
  for (final e in events) {
    final m = _capturedMarker(e);
    if (m != null) captured.add(m);
  }

  // ── Seeds from surviving (not deleted) rows ─────────────────
  var skippedSeeds = 0;
  final seeds = <TimelineMarker>[];
  for (final row in medications) {
    if (row.isDeleted) continue;
    final rowSnap = MedicationFieldSnapshot.fromEntry(row);

    // Declared start (active and archived rows alike).
    final startRaw = row.startDate.trim();
    final startDate = startRaw.isEmpty ? null : parseMedicationDate(startRaw);
    if (startDate == null) {
      // Blank or unparseable — no marker, counted (test 10).
      skippedSeeds++;
    } else {
      seeds.add(TimelineMarker(
        kind: TimelineMarkerKind.start,
        medId: row.id,
        medName: row.name,
        date: _dayOnly(startDate),
        dateDisplay: startRaw,
        monthPrecision: medicationDateIsMonthOnly(startRaw),
        seeded: true,
        doseAtEvent: row.dose,
        afterDose: rowSnap.dose,
        afterFrequency: rowSnap.frequency,
        afterIsPresent: true,
        recordedAtMs: _dayOnly(startDate).millisecondsSinceEpoch,
      ));
    }

    // Declared stop (archived rows only).
    if (row.isArchived) {
      // endedDate is null for '' and the 'Present' sentinel.
      final endRaw = row.endedDate ?? '';
      final endDate = endRaw.isEmpty ? null : parseMedicationDate(endRaw);
      if (endDate == null) {
        skippedSeeds++;
      } else {
        seeds.add(TimelineMarker(
          kind: TimelineMarkerKind.stop,
          medId: row.id,
          medName: row.name,
          date: _dayOnly(endDate),
          dateDisplay: endRaw.trim(),
          monthPrecision: medicationDateIsMonthOnly(endRaw),
          seeded: true,
          doseAtEvent: row.dose,
          afterDose: rowSnap.dose,
          afterFrequency: rowSnap.frequency,
          afterIsPresent: false,
          recordedAtMs: _dayOnly(endDate).millisecondsSinceEpoch,
        ));
      }
    }
  }

  // Dedup: a captured marker suppresses a seed for the same med
  // (id match when both non-empty, else name match) + same class
  // (start/stop) + same declared date string. Captured wins.
  bool capturedSuppresses(TimelineMarker seed) {
    for (final c in captured) {
      if (c.kind != seed.kind) continue;
      if (c.kind != TimelineMarkerKind.start &&
          c.kind != TimelineMarkerKind.stop) {
        continue;
      }
      if (!_sameMed(c.medId, c.medName, seed.medId, seed.medName)) continue;
      if (c.dateDisplay.trim() == seed.dateDisplay.trim()) return true;
    }
    return false;
  }

  final markers = <TimelineMarker>[
    ...captured,
    for (final s in seeds)
      if (!capturedSuppresses(s)) s,
  ]..sort((a, b) {
      final byDate = a.date.compareTo(b.date);
      if (byDate != 0) return byDate;
      // Same-day order is capture sequence (the windowing
      // sequence rule); then captured before seeded, then name.
      final bySequence = a.recordedAtMs.compareTo(b.recordedAtMs);
      if (bySequence != 0) return bySequence;
      if (a.seeded != b.seeded) return a.seeded ? 1 : -1;
      return a.medName.compareTo(b.medName);
    });

  // ── Range: earliest of (score coverage start, earliest
  // marker) through today (or the latest data day if later). ──
  DateTime? scoreStart;
  DateTime? scoreEnd;
  for (final k in scoresByDate.keys) {
    final d = DateTime.tryParse(k);
    if (d == null) continue;
    final day = _dayOnly(d);
    if (scoreStart == null || day.isBefore(scoreStart)) scoreStart = day;
    if (scoreEnd == null || day.isAfter(scoreEnd)) scoreEnd = day;
  }
  var rangeStart = todayDay;
  if (scoreStart != null && scoreStart.isBefore(rangeStart)) {
    rangeStart = scoreStart;
  }
  for (final m in markers) {
    if (m.date.isBefore(rangeStart)) rangeStart = m.date;
  }
  var rangeEnd = todayDay;
  if (scoreEnd != null && scoreEnd.isAfter(rangeEnd)) rangeEnd = scoreEnd;
  for (final m in markers) {
    if (m.date.isAfter(rangeEnd)) rangeEnd = m.date;
  }

  // ── Per-day log series ──────────────────────────────────────
  final symptomsId = resolveSummaryCategoryId(categories,
      name: 'Symptoms', fallbackId: 1);
  int? migraineCategoryId;
  for (final c in categories) {
    if (c.name.trim().toLowerCase() == 'migraine symptoms & triggers') {
      migraineCategoryId = c.id;
      break;
    }
  }
  migraineCategoryId ??= symptomsId;

  final flareDays = <String>{};
  final migraineDays = <String>{};
  final symptomCounts = <String, int>{};
  DateTime? latestEntryDay;
  for (final e in entries) {
    final day = _dayOnly(DateTime.fromMillisecondsSinceEpoch(e.timestamp));
    if (latestEntryDay == null || day.isAfter(latestEntryDay)) {
      latestEntryDay = day;
    }
    // Series values are keyed by day and read back only inside
    // the final axis range, so out-of-range entries are harmless
    // here; their one range effect is latestEntryDay below.
    final key = dateStrOf(day);
    final chips = parseTimelineChips(e.chips);
    final inSymptoms = symptomsId != null && e.categoryId == symptomsId;
    // countSymptomLogs' legacy fallback (today_summary.dart):
    // categoryId 0 entries whose body names headache/nausea/
    // fatigue count as symptom logs.
    final body = e.body.toLowerCase();
    final legacySymptom = e.categoryId == 0 &&
        (body.contains('headache') ||
            body.contains('nausea') ||
            body.contains('fatigue'));
    if (inSymptoms || legacySymptom) {
      symptomCounts[key] = (symptomCounts[key] ?? 0) + 1;
    }
    if (inSymptoms && chips.contains(flareDayChip)) {
      flareDays.add(key);
    }
    if (migraineCategoryId != null &&
        e.categoryId == migraineCategoryId &&
        chips.contains(migraineTrendsChip)) {
      migraineDays.add(key);
    }
  }
  if (latestEntryDay != null && latestEntryDay.isAfter(rangeEnd)) {
    rangeEnd = latestEntryDay;
  }

  // ── Calendar-continuous axis ────────────────────────────────
  final markersByDay = <String, List<TimelineMarker>>{};
  for (final m in markers) {
    markersByDay.putIfAbsent(dateStrOf(m.date), () => []).add(m);
  }
  final dayCount = rangeEnd.difference(rangeStart).inDays + 1;
  final days = <TimelineDay>[
    for (var i = 0; i < dayCount; i++)
      () {
        final day = rangeStart.add(Duration(days: i));
        final key = dateStrOf(day);
        return TimelineDay(
          date: day,
          // Absent or null = unscored GAP (never zero-filled).
          score: scoresByDate[key],
          isFlareDay: flareDays.contains(key),
          isMigraineDay: migraineDays.contains(key),
          symptomLogCount: symptomCounts[key] ?? 0,
          markers: markersByDay[key] ?? const [],
        );
      }(),
  ];

  // ── Lanes ───────────────────────────────────────────────────
  final rowByKey = <String, MedicationEntry>{};
  for (final row in medications) {
    if (row.isDeleted) continue;
    final key = row.id.isNotEmpty
        ? 'id:${row.id}'
        : 'name:${row.name.trim().toLowerCase()}';
    rowByKey[key] = row;
  }
  final markersByMed = <String, List<TimelineMarker>>{};
  for (final m in markers) {
    markersByMed.putIfAbsent(m.medKey, () => []).add(m);
  }
  final lanes = <TimelineMedLane>[];
  for (final entry in markersByMed.entries) {
    final medMarkers = entry.value; // already chronological
    final row = rowByKey[entry.key];
    final segments = <TimelineLaneSegment>[
      for (var i = 0; i < medMarkers.length; i++)
        TimelineLaneSegment(
          startDate: medMarkers[i].date,
          endDate: i + 1 < medMarkers.length
              ? medMarkers[i + 1].date
              : rangeEnd.add(const Duration(days: 1)),
          dose: medMarkers[i].afterDose,
          frequency: medMarkers[i].afterFrequency,
          isPresent: medMarkers[i].afterIsPresent,
          startsSeeded: medMarkers[i].seeded,
        ),
    ];
    lanes.add(TimelineMedLane(
      medName: row?.name ?? medMarkers.last.medName,
      medId: medMarkers.first.medId,
      markers: medMarkers,
      segments: segments,
    ));
  }
  lanes.sort((a, b) {
    final byFirst = a.markers.first.date.compareTo(b.markers.first.date);
    if (byFirst != 0) return byFirst;
    return a.medName.compareTo(b.medName);
  });

  return MedicationTimelineData(
    markers: markers,
    days: days,
    rangeStart: rangeStart,
    rangeEnd: rangeEnd,
    skippedSeedCount: skippedSeeds,
    lanes: lanes,
    scoresByDate: scoresByDate,
  );
}
