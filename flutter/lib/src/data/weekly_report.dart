import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/progress_report_pdf.dart'
    show availabilityPdfLabel;
import 'package:tabs_lab/src/data/report_ready_notification.dart';

/// Weekly Report — Package 1 (Team Session #2 decision,
/// 2026-11-09; Juno ruling 2026-11-19, JUNO-RULING.md §c).
///
/// Manual generation of a closed calendar Mon–Sun week through
/// the standard report pipeline, plus a persisted archive in
/// Progress Reports. This file owns: the Juno verbatim strings,
/// the week window math, the completeness evaluator, the archive
/// record + store, and the silent notifier that guarantees the
/// Package 1 zero-notification rule.
///
/// NO AI narrative is produced on this path (the pipeline runs
/// with forceRawFallback) and NO notification is ever posted:
/// the weekly generation service is a dedicated
/// [ReportGenerationService] whose only notifier is
/// [WeeklySilentNotifier].

// ── Juno verbatim strings (JUNO-RULING.md §c, Package 1) ───────

/// Row 1.1 — archive section header.
const weeklyArchiveHeader = 'Weekly reports';

/// Row 1.2 — manual generation action.
const weeklyGenerateLabel = 'Generate Weekly Report';

/// Row 1.3 — archive empty state (Premium, no reports yet).
const weeklyArchiveEmpty = 'No weekly reports yet.';

/// Row 1.9 — free-user locked row title (Session #2).
const weeklyLockedTitle = 'Weekly report';

/// Row 1.10 — free-user locked row body (Session #2).
const weeklyLockedBody =
    'Available with Premium. A weekly summary of your logs and Daily Score.';

/// Row 1.11 — lapsed-Premium line (Session #2).
const weeklyLapsedLine =
    'Weekly reports have stopped. Your existing reports remain available.';

/// Row 1.12 — permission-needed title (§a).
const weeklyPermissionTitle = 'Permission needed';

/// Row 1.13 — permission-needed body (§a).
const weeklyPermissionBody =
    "This report isn't complete. Tabs couldn't read the sections below because permission wasn't granted.";

/// Row 1.14 — blocked-sections label (§a).
const weeklyPermissionSectionsLabel = 'Needs permission:';

/// Row 1.15 — permission-needed guidance (§a).
const weeklyPermissionGuidance =
    'Grant access in Health Connect, then generate the report again.';

/// Row 1.16 — permission-needed primary action (§a; the Settings
/// surface's existing label for the same destination).
const weeklyPermissionPrimaryAction = 'Open Health Connect Settings';

/// Row 1.17 — permission-needed secondary action (§a).
const weeklyPermissionSecondaryAction = 'Not now';

/// Row 1.19 — low-data framing (Session #2).
const weeklyLowDataFraming =
    'Not enough complete days this week to show a trend.';

/// Row 1.20 — blocked-week PDF completeness line.
const weeklyBlockedPdfLine = 'This weekly report is incomplete.';

/// Row 1.18 — the receipt sentence (Session #2), the ONLY change
/// language in the package. [x]/[y] are Daily Score averages over
/// complete days (one decimal, the buildHealthSummary form);
/// [n] counts complete days only.
String weeklyReceiptSentence({
  required double thisWeekAvg,
  required double lastWeekAvg,
  required int completeDays,
}) =>
    'Your average Daily Score was ${thisWeekAvg.toStringAsFixed(1)}, '
    'compared with ${lastWeekAvg.toStringAsFixed(1)} last week. '
    'Based on $completeDays complete days.';

// ── Week window (calendar Mon–Sun) ─────────────────────────────

/// A fixed closed calendar week: Monday 00:00 local through
/// Sunday 23:59:59.999 local. Day definition is the CALENDAR day
/// (this package merges after the 04:00→midnight boundary
/// migration; nothing here routes through tabsDayAnchor).
class WeeklyWeekWindow {
  /// Monday of the week (local midnight).
  final DateTime start;

  /// Sunday of the week (local midnight).
  final DateTime end;

  const WeeklyWeekWindow(this.start, this.end);

  DateTime get endExclusive => end.add(const Duration(days: 1));
  int get startMs => start.millisecondsSinceEpoch;
  int get endExclusiveMs => endExclusive.millisecondsSinceEpoch;

  /// The 7 calendar dates of the week, Monday first.
  List<DateTime> get days =>
      [for (var i = 0; i < 7; i++) start.add(Duration(days: i))];

  /// The most recent CLOSED Mon–Sun week relative to [now]: if
  /// today is Monday, the week that ended yesterday; on any
  /// other day, the week ending the most recent Sunday.
  static WeeklyWeekWindow mostRecentClosed(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final mondayThisWeek =
        today.subtract(Duration(days: today.weekday - DateTime.monday));
    final end = mondayThisWeek.subtract(const Duration(days: 1));
    final start = end.subtract(const Duration(days: 6));
    return WeeklyWeekWindow(start, end);
  }

  /// The window containing [day] (its Monday..Sunday).
  static WeeklyWeekWindow containing(DateTime day) {
    final d = DateTime(day.year, day.month, day.day);
    final monday = d.subtract(Duration(days: d.weekday - DateTime.monday));
    return WeeklyWeekWindow(monday, monday.add(const Duration(days: 6)));
  }

  /// The window immediately before this one.
  WeeklyWeekWindow get previous =>
      WeeklyWeekWindow(start.subtract(const Duration(days: 7)),
          end.subtract(const Duration(days: 7)));

  String get startKey => dateStrOf(start);
  String get endKey => dateStrOf(end);

  @override
  bool operator ==(Object other) =>
      other is WeeklyWeekWindow && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Row 1.4 — archive week label: `[MMM d] – [MMM d, yyyy]` inside
/// one year; `[MMM d, yyyy] – [MMM d, yyyy]` across a year
/// boundary. Date names only — no weekday names.
String weeklyWeekLabel(WeeklyWeekWindow w) {
  if (w.start.year == w.end.year) {
    return '${formatMmmDyyyy(w.start).replaceAll(', ${w.start.year}', '')}'
        ' – ${formatMmmDyyyy(w.end)}';
  }
  return '${formatMmmDyyyy(w.start)} – ${formatMmmDyyyy(w.end)}';
}

/// Row 1.5 — archive generation line.
String weeklyGeneratedLine(int generatedAtMs) =>
    'Generated ${formatMmmDyyyy(DateTime.fromMillisecondsSinceEpoch(generatedAtMs))}';

// ── Completeness evaluator ─────────────────────────────────────

/// The archive completeness labels (Juno rows 1.6–1.8): the
/// complete display text is the single word.
enum WeeklyCompleteness {
  complete('Complete'),
  incomplete('Incomplete'),
  blocked('Blocked');

  final String label;
  const WeeklyCompleteness(this.label);

  static WeeklyCompleteness fromLabel(String? s) => switch (s) {
        'Complete' => WeeklyCompleteness.complete,
        'Blocked' => WeeklyCompleteness.blocked,
        _ => WeeklyCompleteness.incomplete,
      };
}

/// The completeness bar (Session #2 honesty policy): generation
/// completes ∧ no availability contradiction ∧ ≥5 of 7 Daily
/// Scores ∧ ≥4 nights of non-zero sleep ∧ ≥4 logged days. A
/// biometric 0 is a failed read, never data (the collector's
/// series are already zero-filtered; the evaluator re-checks).
///
/// A day is COMPLETE when it has closed AND holds a Daily Score
/// (> 0), a non-zero sleep night, and at least one logged entry —
/// all on that calendar day. A still-running day (Package 2's
/// Sunday-night case) is NEVER complete: [closedDays] bounds
/// which dates may count, and any date on/after it is excluded
/// from complete days and from the receipt average (Juno §d
/// Flag 1).
class WeeklyEvaluation {
  final WeeklyCompleteness label;
  final bool barMet;

  /// Section labels (PDF availability-block names, pipeline
  /// order) whose verified status is permissionDenied.
  final List<String> blockedSections;

  /// A permissionDenied claim contradicted by surviving data
  /// (the section's own series/record count is non-empty).
  final bool contradiction;

  final int dailyScoreDays;
  final int sleepNights;
  final int loggedDays;
  final int completeDays;

  /// Average Daily Score over COMPLETE days only (null when no
  /// complete days) — the receipt's [X] source.
  final double? avgScoreCompleteDays;

  final bool chartsNonEmpty;

  /// Juno row 1.18 receipt, non-null only when every receipt
  /// condition holds (see [evaluateWeeklyCompleteness]).
  final String? receiptLine;

  /// The single weekly line the PDF carries: the blocked line,
  /// else the receipt, else the low-data framing, else null.
  final String? pdfLine;

  const WeeklyEvaluation({
    required this.label,
    required this.barMet,
    required this.blockedSections,
    required this.contradiction,
    required this.dailyScoreDays,
    required this.sleepNights,
    required this.loggedDays,
    required this.completeDays,
    required this.avgScoreCompleteDays,
    required this.chartsNonEmpty,
    required this.receiptLine,
    required this.pdfLine,
  });
}

WeeklyEvaluation evaluateWeeklyCompleteness({
  required ReportSnapshot snapshot,
  required WeeklyWeekWindow week,
  required bool generationCompleted,

  /// Dates strictly before this day may count as complete.
  /// Defaults to the day after the week's Sunday (the whole
  /// closed week counts — the Package 1 manual path). Package 2
  /// passes its Sunday-night generation day so the still-running
  /// Sunday never counts.
  DateTime? closedBefore,

  /// The previous week's archive record, for the receipt's
  /// both-weeks threshold (null = no receipt possible).
  WeeklyArchiveRecord? previousWeek,
}) {
  final closed = closedBefore ?? week.endExclusive;
  bool isClosedDay(String key) {
    final d = DateTime.tryParse(key);
    return d != null && d.isBefore(closed);
  }

  final inWeek = week.days.map(dateStrOf).toSet();

  final scores = <String, int>{
    for (final e in snapshot.dailyScoreSeries)
      if (inWeek.contains(e.$1) && e.$2 > 0) e.$1: e.$2,
  };
  final sleep = <String, int>{
    for (final e in snapshot.sleepSeries)
      if (inWeek.contains(e.$1) && e.$2 > 0) e.$1: e.$2,
  };
  final logged = <String>{};
  for (final e in snapshot.logEntries) {
    if (e.timestamp >= week.startMs && e.timestamp < week.endExclusiveMs) {
      logged.add(
          dateStrOf(DateTime.fromMillisecondsSinceEpoch(e.timestamp)));
    }
  }

  final completeDayKeys = <String>{
    for (final key in scores.keys)
      if (sleep.containsKey(key) && logged.contains(key) && isClosedDay(key))
        key,
  };
  final avgComplete = completeDayKeys.isEmpty
      ? null
      : completeDayKeys.map((k) => scores[k]!).reduce((a, b) => a + b) /
          completeDayKeys.length;

  // Blocked sections + contradiction, in the PDF availability
  // block's own order (the snapshot's insertion order) and with
  // its own labels (Juno §a: same names, same order).
  final blockedSections = <String>[];
  var contradiction = false;
  for (final entry in snapshot.sectionMetadata.entries) {
    if (entry.value.status != DataSourceStatus.permissionDenied) continue;
    blockedSections.add(availabilityPdfLabel(entry.key));
    if (entry.value.recordCount > 0) contradiction = true;
  }
  // A denied claim for a section whose series survived in this
  // very snapshot is the founder's Nov 9 contradiction shape.
  if (snapshot.sectionMetadata['dailyScore']?.status ==
          DataSourceStatus.permissionDenied &&
      scores.isNotEmpty) {
    contradiction = true;
  }
  if (snapshot.sectionMetadata['sleep']?.status ==
          DataSourceStatus.permissionDenied &&
      sleep.isNotEmpty) {
    contradiction = true;
  }

  final chartsNonEmpty = snapshot.dailyScoreSeries.isNotEmpty ||
      snapshot.sleepSeries.isNotEmpty ||
      snapshot.heartRateSeries.isNotEmpty ||
      snapshot.hrvSeries.isNotEmpty ||
      snapshot.bloodPressureSeries.isNotEmpty ||
      snapshot.caloriesSeries.isNotEmpty ||
      snapshot.heartRateSpikes.isNotEmpty ||
      snapshot.logEntries.isNotEmpty;

  final barMet = generationCompleted &&
      !contradiction &&
      blockedSections.isEmpty &&
      scores.length >= 5 &&
      sleep.length >= 4 &&
      logged.length >= 4;

  final label = (blockedSections.isNotEmpty || contradiction)
      ? WeeklyCompleteness.blocked
      : (barMet ? WeeklyCompleteness.complete : WeeklyCompleteness.incomplete);

  // Receipt (Juno row 1.18 + §d Flag 1): ONLY when the bar is
  // met, BOTH weeks hold ≥5 complete days, permissions are
  // verified (no blocked section this week; the previous week's
  // record was not blocked), and charts are non-empty. [n]
  // counts complete days only; [X] averages complete days only.
  String? receipt;
  if (barMet &&
      chartsNonEmpty &&
      completeDayKeys.length >= 5 &&
      previousWeek != null &&
      previousWeek.completeDays >= 5 &&
      previousWeek.avgScoreCompleteDays != null &&
      previousWeek.label != WeeklyCompleteness.blocked &&
      avgComplete != null) {
    receipt = weeklyReceiptSentence(
      thisWeekAvg: avgComplete,
      lastWeekAvg: previousWeek.avgScoreCompleteDays!,
      completeDays: completeDayKeys.length,
    );
  }

  final pdfLine = label == WeeklyCompleteness.blocked
      ? weeklyBlockedPdfLine
      : (receipt ?? (barMet ? null : weeklyLowDataFraming));

  return WeeklyEvaluation(
    label: label,
    barMet: barMet,
    blockedSections: blockedSections,
    contradiction: contradiction,
    dailyScoreDays: scores.length,
    sleepNights: sleep.length,
    loggedDays: logged.length,
    completeDays: completeDayKeys.length,
    avgScoreCompleteDays: avgComplete,
    chartsNonEmpty: chartsNonEmpty,
    receiptLine: receipt,
    pdfLine: pdfLine,
  );
}

// ── Archive record + store ─────────────────────────────────────

/// One archived weekly report: the generated PDF's location plus
/// its availability/completeness record (Session #2: "a generated
/// report carries its completeness record in the archive,
/// provenance included"). Regenerating the same week REPLACES
/// its entry (artifacts are user-invoked and regenerable).
class WeeklyArchiveRecord {
  final String weekStartKey;
  final String weekEndKey;
  final int generatedAtMs;
  final String fileName;
  final String savedPath;
  final WeeklyCompleteness label;
  final List<String> blockedSections;
  final int dailyScoreDays;
  final int sleepNights;
  final int loggedDays;
  final int completeDays;
  final double? avgScoreCompleteDays;

  const WeeklyArchiveRecord({
    required this.weekStartKey,
    required this.weekEndKey,
    required this.generatedAtMs,
    required this.fileName,
    required this.savedPath,
    required this.label,
    required this.blockedSections,
    required this.dailyScoreDays,
    required this.sleepNights,
    required this.loggedDays,
    required this.completeDays,
    required this.avgScoreCompleteDays,
  });

  WeeklyWeekWindow get window => WeeklyWeekWindow(
        DateTime.parse(weekStartKey),
        DateTime.parse(weekEndKey),
      );

  Map<String, dynamic> toJson() => {
        'weekStart': weekStartKey,
        'weekEnd': weekEndKey,
        'generatedAtMs': generatedAtMs,
        'fileName': fileName,
        'savedPath': savedPath,
        'label': label.label,
        'blockedSections': blockedSections,
        'dailyScoreDays': dailyScoreDays,
        'sleepNights': sleepNights,
        'loggedDays': loggedDays,
        'completeDays': completeDays,
        'avgScoreCompleteDays': avgScoreCompleteDays,
      };

  static WeeklyArchiveRecord? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    try {
      return WeeklyArchiveRecord(
        weekStartKey: '${raw['weekStart']}',
        weekEndKey: '${raw['weekEnd']}',
        generatedAtMs: (raw['generatedAtMs'] as num?)?.toInt() ?? 0,
        fileName: '${raw['fileName'] ?? ''}',
        savedPath: '${raw['savedPath'] ?? ''}',
        label: WeeklyCompleteness.fromLabel(raw['label'] as String?),
        blockedSections: [
          if (raw['blockedSections'] is List)
            for (final e in raw['blockedSections'] as List) '$e',
        ],
        dailyScoreDays: (raw['dailyScoreDays'] as num?)?.toInt() ?? 0,
        sleepNights: (raw['sleepNights'] as num?)?.toInt() ?? 0,
        loggedDays: (raw['loggedDays'] as num?)?.toInt() ?? 0,
        completeDays: (raw['completeDays'] as num?)?.toInt() ?? 0,
        avgScoreCompleteDays:
            (raw['avgScoreCompleteDays'] as num?)?.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Archive persistence, following the report journal's pattern
/// (flutter_secure_storage JSON blob under one key; injectable
/// storage closures; an in-memory factory for tests — one shared
/// map simulates one device across a relaunch). The PDFs
/// themselves live in the app documents directory via the
/// pipeline's existing save step; the record carries the path.
class WeeklyReportStore {
  static const storeKey = 'weekly_report_archive_v1';

  final Future<String?> Function(String key) _read;
  final Future<void> Function(String key, String value) _write;

  WeeklyReportStore()
      : _read = ((key) => const FlutterSecureStorage().read(key: key)),
        _write = ((key, value) =>
            const FlutterSecureStorage().write(key: key, value: value));

  WeeklyReportStore.withStorage({
    required Future<String?> Function(String key) read,
    required Future<void> Function(String key, String value) write,
  })  : _read = read,
        _write = write;

  factory WeeklyReportStore.inMemory(Map<String, String> mem) =>
      WeeklyReportStore.withStorage(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
      );

  /// All records, newest week first.
  Future<List<WeeklyArchiveRecord>> readAll() async {
    try {
      final raw = await _read(storeKey);
      if (raw == null || raw.isEmpty) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final records = [
        for (final e in decoded) ?WeeklyArchiveRecord.fromJson(e),
      ]..sort((a, b) => b.weekStartKey.compareTo(a.weekStartKey));
      return records;
    } catch (_) {
      return const [];
    }
  }

  /// Inserts or replaces the record for its week.
  Future<List<WeeklyArchiveRecord>> upsert(WeeklyArchiveRecord record) async {
    final existing = await readAll();
    final next = [
      record,
      for (final r in existing)
        if (r.weekStartKey != record.weekStartKey) r,
    ]..sort((a, b) => b.weekStartKey.compareTo(a.weekStartKey));
    await _write(storeKey, jsonEncode([for (final r in next) r.toJson()]));
    return next;
  }

  /// The record for the week immediately before [week], if any.
  static WeeklyArchiveRecord? previousOf(
      List<WeeklyArchiveRecord> records, WeeklyWeekWindow week) {
    final prevKey = week.previous.startKey;
    for (final r in records) {
      if (r.weekStartKey == prevKey) return r;
    }
    return null;
  }
}

// ── Zero-notification guarantee ────────────────────────────────

/// The ONLY notifier the weekly generation service is ever
/// given. It records every post attempt and posts NOTHING —
/// Package 1 posts zero notifications anywhere (Session #2), and
/// PR #55's report-ready notifier is never used on this path.
/// The recording is the sink Vera's zero-notification proof runs
/// against: any code path that tried to announce a weekly
/// completion would land here and be counted.
class WeeklySilentNotifier implements ReportReadyNotifier {
  int calls = 0;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> showReportReady() async {
    calls++;
    return false;
  }
}

// ── Entitlement (fail-closed, PRE-GENERATION) ──────────────────

/// Weekly entitlement state, resolved BEFORE any generation work
/// begins (founder clarification, Session #2): no-entitlement and
/// expired alike produce no PDF, no archive entry, nothing.
enum WeeklyEntitlement {
  /// Active Premium (a running trial counts as Premium).
  premium,

  /// Never held Premium: exactly one locked row, no action.
  free,

  /// Held Premium before, no longer active: generation stops
  /// silently; existing archive entries stay readable forever.
  lapsed,
}
