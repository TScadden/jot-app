import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/weekly_report.dart';

// ── Weekly Report Package 1 (Team Session #2 decision
// 2026-11-09; Juno ruling 2026-11-19) — Vera's test arc for
// the manual slice:
//   • Mon–Sun window math across month/year boundaries
//   • fail-closed entitlement (none + expired), pre-generation
//   • archive persistence + completeness labels
//   • receipt sentence presence/absence at the threshold,
//     incl. the Sunday-night partial-Sunday fixture (Flag 1)
//   • zero-notification sink proof
//   • throwing fixtures for the permission-needed gate: true
//     denial vs false denial (stale grant) vs revoked
//     mid-generation — the state fires ONLY on verified
//     permissionDenied (Juno §d Flag 3)
//
// Fixture week: Mon Nov 9 – Sun Nov 15, 2026 (weekdays verified
// against the calendar). Previous week: Nov 2 – Nov 8, 2026.

final _week = WeeklyWeekWindow(DateTime(2026, 11, 9), DateTime(2026, 11, 15));
final _prevWeek =
    WeeklyWeekWindow(DateTime(2026, 11, 2), DateTime(2026, 11, 8));

QuickLogEntry _entry(String id, DateTime day) => QuickLogEntry(
      id: id,
      categoryId: '1',
      body: 'entry $id',
      chips: '',
      manualText: '',
      timestamp:
          DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch,
    );

List<QuickLogEntry> _entriesOn(List<DateTime> days) =>
    [for (var i = 0; i < days.length; i++) _entry(i + 1, days[i])];

List<(String, int)> _seriesOn(List<DateTime> days, int value) =>
    [for (final d in days) (dateStrOf(d), value)];

ReportSnapshot _snap({
  WeeklyWeekWindow? week,
  List<(String, int)> scores = const [],
  List<(String, int)> sleep = const [],
  List<QuickLogEntry> entries = const [],
  Map<String, SectionMetadata> meta = const {},
}) {
  final w = week ?? _week;
  return ReportSnapshot(
    last30Days: false,
    weekStart: w.start,
    weekEnd: w.end,
    generationTimestampMs:
        DateTime(2026, 11, 18, 12).millisecondsSinceEpoch,
    logEntries: entries,
    categoriesMap: const {'1': 'Symptoms'},
    dailyScoreSeries: scores,
    sleepSeries: sleep,
    sectionMetadata: meta,
  );
}

WeeklyArchiveRecord _record(
  WeeklyWeekWindow w, {
  required WeeklyCompleteness label,
  required int completeDays,
  double? avg,
}) =>
    WeeklyArchiveRecord(
      weekStartKey: w.startKey,
      weekEndKey: w.endKey,
      generatedAtMs: DateTime(2026, 11, 16, 9).millisecondsSinceEpoch,
      fileName: 'report.pdf',
      savedPath: '/tmp/report.pdf',
      label: label,
      blockedSections: const [],
      dailyScoreDays: completeDays,
      sleepNights: completeDays,
      loggedDays: completeDays,
      completeDays: completeDays,
      avgScoreCompleteDays: avg,
    );

void main() {
  group('Mon–Sun window math', () {
    test('Wednesday: most recent closed week is the one that ended Sunday',
        () {
      final w = WeeklyWeekWindow.mostRecentClosed(DateTime(2026, 11, 18, 15));
      expect(w.start, DateTime(2026, 11, 9));
      expect(w.end, DateTime(2026, 11, 15));
    });

    test('Monday: the week that ended yesterday', () {
      final w = WeeklyWeekWindow.mostRecentClosed(DateTime(2026, 11, 16, 8));
      expect(w.start, DateTime(2026, 11, 9));
      expect(w.end, DateTime(2026, 11, 15));
    });

    test('Sunday: the current week is not closed yet', () {
      final w = WeeklyWeekWindow.mostRecentClosed(DateTime(2026, 11, 15, 21));
      expect(w.start, DateTime(2026, 11, 2));
      expect(w.end, DateTime(2026, 11, 8));
    });

    test('across a month boundary (Thu Jan 1, 2026 → Dec 22–28, 2025)', () {
      final w = WeeklyWeekWindow.mostRecentClosed(DateTime(2026, 1, 1, 10));
      expect(w.start, DateTime(2025, 12, 22));
      expect(w.end, DateTime(2025, 12, 28));
    });

    test('across a year boundary (Mon Jan 4, 2027 → Dec 28, 2026–Jan 3, 2027)',
        () {
      final w = WeeklyWeekWindow.mostRecentClosed(DateTime(2027, 1, 4, 9));
      expect(w.start, DateTime(2026, 12, 28));
      expect(w.end, DateTime(2027, 1, 3));
      expect(w.start.weekday, DateTime.monday);
      expect(w.end.weekday, DateTime.sunday);
    });

    test('month-crossing week: Mon Oct 26 – Sun Nov 1, 2026', () {
      final w = WeeklyWeekWindow.containing(DateTime(2026, 10, 29));
      expect(w.start, DateTime(2026, 10, 26));
      expect(w.end, DateTime(2026, 11, 1));
      expect(w.days.length, 7);
    });

    test('previous steps back exactly 7 days', () {
      expect(_week.previous.start, DateTime(2026, 11, 2));
      expect(_week.previous.end, DateTime(2026, 11, 8));
    });
  });

  group('DST boundary weeks (Vera MINOR 2)', () {
    // Boundaries must be built from calendar components so every
    // edge is TRUE local midnight in both DST directions. These
    // tests only bite in a DST-observing zone — the package suite
    // is run under TZ=America/Denver for them (fall-back:
    // Sun Nov 1, 2026; spring-forward: Sun Mar 8, 2026).
    QuickLogEntry entryAt(int id, DateTime at) => QuickLogEntry(
          id: id,
          categoryId: '1',
          body: 'entry $id',
          chips: '',
          manualText: '',
          timestamp: at.millisecondsSinceEpoch,
        );

    test('fall-back week (Mon Oct 26 – Sun Nov 1, 2026): boundaries '
        'are exactly 00:00 local at both ends', () {
      final w = WeeklyWeekWindow.containing(DateTime(2026, 10, 29));
      expect(w.start, DateTime(2026, 10, 26));
      expect(w.end, DateTime(2026, 11, 1));
      expect(w.start.hour, 0);
      expect(w.start.minute, 0);
      expect(w.end.hour, 0);
      expect(w.end.minute, 0);
      expect(w.endExclusive, DateTime(2026, 11, 2));
      expect(w.endExclusive.hour, 0);
      expect(w.days.first, DateTime(2026, 10, 26));
      expect(w.days.last, DateTime(2026, 11, 1));
      for (final d in w.days) {
        expect(d.hour, 0, reason: 'every day of the week at midnight');
        expect(d.minute, 0);
      }
      // mostRecentClosed from the following Wednesday agrees.
      final closed =
          WeeklyWeekWindow.mostRecentClosed(DateTime(2026, 11, 4, 12));
      expect(closed, w);
      // previous steps back across the transition at midnight too.
      expect(w.previous.start, DateTime(2026, 10, 19));
      expect(w.previous.end, DateTime(2026, 10, 25));
      expect(w.previous.start.hour, 0);
      expect(w.previous.end.hour, 0);
    });

    test('fall-back week: a Monday 00:30 log entry falls inside '
        'the window (and the edges stop exactly at midnight)', () {
      final w = WeeklyWeekWindow.containing(DateTime(2026, 10, 29));
      final monday0030 = entryAt(1, DateTime(2026, 10, 26, 0, 30));
      expect(monday0030.timestamp, greaterThanOrEqualTo(w.startMs));
      expect(monday0030.timestamp, lessThan(w.endExclusiveMs));
      // The evaluator counts that Monday as a logged day.
      final ev = evaluateWeeklyCompleteness(
        snapshot: _snap(week: w, entries: [monday0030]),
        week: w,
        generationCompleted: true,
      );
      expect(ev.loggedDays, 1);
      // Sunday's last hour is inside; next Monday 00:30 is not.
      final sunday2330 = entryAt(2, DateTime(2026, 11, 1, 23, 30));
      expect(sunday2330.timestamp, lessThan(w.endExclusiveMs));
      final nextMonday0030 = entryAt(3, DateTime(2026, 11, 2, 0, 30));
      expect(nextMonday0030.timestamp,
          greaterThanOrEqualTo(w.endExclusiveMs));
    });

    test('spring-forward week (Mon Mar 2 – Sun Mar 8, 2026): '
        'boundaries are exactly 00:00 local at both ends', () {
      final w = WeeklyWeekWindow.containing(DateTime(2026, 3, 5));
      expect(w.start, DateTime(2026, 3, 2));
      expect(w.end, DateTime(2026, 3, 8));
      expect(w.start.hour, 0);
      expect(w.start.minute, 0);
      expect(w.end.hour, 0);
      expect(w.end.minute, 0);
      expect(w.endExclusive, DateTime(2026, 3, 9));
      expect(w.endExclusive.hour, 0);
      for (final d in w.days) {
        expect(d.hour, 0, reason: 'every day of the week at midnight');
        expect(d.minute, 0);
      }
      final closed =
          WeeklyWeekWindow.mostRecentClosed(DateTime(2026, 3, 11, 12));
      expect(closed, w);
      // A Monday 00:30 log entry falls inside this window too.
      final monday0030 = entryAt(1, DateTime(2026, 3, 2, 0, 30));
      expect(monday0030.timestamp, greaterThanOrEqualTo(w.startMs));
      expect(monday0030.timestamp, lessThan(w.endExclusiveMs));
      final ev = evaluateWeeklyCompleteness(
        snapshot: _snap(week: w, entries: [monday0030]),
        week: w,
        generationCompleted: true,
      );
      expect(ev.loggedDays, 1);
    });
  });

  group('archive labels (Juno §c rows 1.4–1.5)', () {
    test('same-year week label: date names only, no weekday names', () {
      expect(weeklyWeekLabel(_week), 'Nov 9 – Nov 15, 2026');
    });

    test('year-crossing week label carries both years', () {
      final w =
          WeeklyWeekWindow(DateTime(2026, 12, 28), DateTime(2027, 1, 3));
      expect(weeklyWeekLabel(w), 'Dec 28, 2026 – Jan 3, 2027');
    });

    test('generation line', () {
      final ms = DateTime(2026, 11, 18, 12).millisecondsSinceEpoch;
      expect(weeklyGeneratedLine(ms), 'Generated Nov 18, 2026');
    });
  });

  group('completeness evaluator + receipt (Juno §c rows 1.18–1.20)', () {
    test('good week: Complete; receipt prints with exact wording', () {
      final days = _week.days;
      final snap = _snap(
        scores: _seriesOn(days, 60),
        sleep: _seriesOn(days, 420),
        entries: _entriesOn(days.sublist(0, 5)),
      );
      final prev = _record(_prevWeek,
          label: WeeklyCompleteness.complete, completeDays: 6, avg: 72.5);
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
        previousWeek: prev,
      );
      expect(ev.label, WeeklyCompleteness.complete);
      expect(ev.barMet, isTrue);
      expect(ev.completeDays, 5);
      expect(ev.receiptLine,
          'Your average Daily Score was 60.0, compared with 72.5 last '
          'week. Based on 5 complete days.');
      expect(ev.pdfLine, ev.receiptLine);
    });

    test('receipt absent when THIS week holds only 4 complete days '
        '(bar still met on the separate counts)', () {
      final days = _week.days;
      final snap = _snap(
        scores: _seriesOn(days, 60),
        sleep: _seriesOn(days, 420),
        entries: _entriesOn(days.sublist(0, 4)),
      );
      final prev = _record(_prevWeek,
          label: WeeklyCompleteness.complete, completeDays: 6, avg: 72.5);
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
        previousWeek: prev,
      );
      expect(ev.barMet, isTrue);
      expect(ev.label, WeeklyCompleteness.complete);
      expect(ev.completeDays, 4);
      expect(ev.receiptLine, isNull);
      expect(ev.pdfLine, isNull);
    });

    test('receipt absent when LAST week holds only 4 complete days', () {
      final days = _week.days;
      final snap = _snap(
        scores: _seriesOn(days, 60),
        sleep: _seriesOn(days, 420),
        entries: _entriesOn(days.sublist(0, 6)),
      );
      final prev = _record(_prevWeek,
          label: WeeklyCompleteness.incomplete, completeDays: 4, avg: 72.5);
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
        previousWeek: prev,
      );
      expect(ev.completeDays, 6);
      expect(ev.receiptLine, isNull);
    });

    test('receipt absent with no previous-week record at all', () {
      final days = _week.days;
      final snap = _snap(
        scores: _seriesOn(days, 60),
        sleep: _seriesOn(days, 420),
        entries: _entriesOn(days.sublist(0, 6)),
      );
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
      );
      expect(ev.label, WeeklyCompleteness.complete);
      expect(ev.receiptLine, isNull);
    });

    test('Sunday-night fixture (Flag 1): a partial Sunday is NEVER a '
        'complete day and contributes nothing to the average', () {
      final days = _week.days;
      final monSat = days.sublist(0, 6);
      final sunday = days[6];
      final snap = _snap(
        scores: [..._seriesOn(monSat, 60), (dateStrOf(sunday), 100)],
        sleep: [..._seriesOn(monSat, 420), (dateStrOf(sunday), 400)],
        entries: _entriesOn(days),
      );
      final prev = _record(_prevWeek,
          label: WeeklyCompleteness.complete, completeDays: 5, avg: 50.0);
      // Generation happens ON Sunday (Package 2's timing, applied
      // here to prove the evaluator's Flag 1 condition): only days
      // strictly before Sunday may count as complete.
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
        closedBefore: sunday,
        previousWeek: prev,
      );
      expect(ev.completeDays, 6);
      expect(ev.avgScoreCompleteDays, 60.0,
          reason: "Sunday's 100 must not leak into the average");
      expect(ev.receiptLine,
          'Your average Daily Score was 60.0, compared with 50.0 last '
          'week. Based on 6 complete days.');
    });

    test('2-of-7 low-data week: Incomplete + verbatim no-trend framing', () {
      final two = _week.days.sublist(0, 2);
      final snap = _snap(
        scores: _seriesOn(two, 55),
        sleep: _seriesOn(two, 400),
        entries: _entriesOn(two),
      );
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
      );
      expect(ev.label, WeeklyCompleteness.incomplete);
      expect(ev.barMet, isFalse);
      expect(ev.receiptLine, isNull);
      expect(ev.pdfLine, 'Not enough complete days this week to show a trend.');
    });

    test('all-zero biometrics are failed reads, never data', () {
      final days = _week.days;
      final snap = _snap(
        scores: _seriesOn(days, 60),
        sleep: _seriesOn(days, 0),
        entries: _entriesOn(days.sublist(0, 5)),
      );
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
      );
      expect(ev.sleepNights, 0);
      expect(ev.completeDays, 0);
      expect(ev.label, WeeklyCompleteness.incomplete);
    });
  });

  group('permission-needed gate (Juno §a + §d Flag 3)', () {
    test('TRUE denial: verified permissionDenied → Blocked, sections '
        'named in pipeline order, blocked PDF line, no receipt', () {
      final days = _week.days;
      final snap = _snap(
        scores: _seriesOn(days, 60),
        entries: _entriesOn(days.sublist(0, 5)),
        meta: const {
          'sleep': SectionMetadata('sleep', DataSourceStatus.permissionDenied, 0),
          'deepSleep':
              SectionMetadata('deepSleep', DataSourceStatus.permissionDenied, 0),
          'heartRate':
              SectionMetadata('heartRate', DataSourceStatus.success, 7),
        },
      );
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
      );
      expect(ev.label, WeeklyCompleteness.blocked);
      expect(ev.blockedSections, ['Sleep', 'DeepSleep']);
      expect(ev.contradiction, isFalse);
      expect(ev.receiptLine, isNull);
      expect(ev.pdfLine, 'This weekly report is incomplete.');
    });

    test('FALSE denial (stale grant — "shown as granted, but read '
        'blocked"): never Blocked, no blocked sections', () {
      final days = _week.days;
      final snap = _snap(
        scores: _seriesOn(days, 60),
        entries: _entriesOn(days.sublist(0, 5)),
        meta: const {
          'sleep': SectionMetadata('sleep', DataSourceStatus.stale, 0),
          'deepSleep': SectionMetadata('deepSleep', DataSourceStatus.stale, 0),
        },
      );
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
      );
      expect(ev.blockedSections, isEmpty);
      expect(ev.label, isNot(WeeklyCompleteness.blocked));
      expect(ev.pdfLine,
          'Not enough complete days this week to show a trend.');
    });

    test('absent data (noData) is not a denial either', () {
      final days = _week.days;
      final snap = _snap(
        scores: _seriesOn(days, 60),
        entries: _entriesOn(days.sublist(0, 5)),
        meta: const {
          'sleep': SectionMetadata('sleep', DataSourceStatus.noData, 0),
        },
      );
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
      );
      expect(ev.blockedSections, isEmpty);
      expect(ev.label, WeeklyCompleteness.incomplete);
    });

    test('contradiction: a denied claim refuted by surviving data '
        'labels Blocked but is flagged as a contradiction', () {
      final days = _week.days;
      final snap = _snap(
        scores: _seriesOn(days, 60),
        sleep: _seriesOn(days.sublist(0, 3), 420),
        entries: _entriesOn(days.sublist(0, 5)),
        meta: const {
          'sleep': SectionMetadata('sleep', DataSourceStatus.permissionDenied, 3),
        },
      );
      final ev = evaluateWeeklyCompleteness(
        snapshot: snap,
        week: _week,
        generationCompleted: true,
      );
      expect(ev.contradiction, isTrue);
      expect(ev.label, WeeklyCompleteness.blocked);
    });
  });

  group('archive store', () {
    test('persistence across a relaunch (shared backing map)', () async {
      final mem = <String, String>{};
      final store1 = WeeklyReportStore.inMemory(mem);
      await store1.upsert(_record(_week,
          label: WeeklyCompleteness.complete, completeDays: 6, avg: 61.0));
      await store1.upsert(_record(_prevWeek,
          label: WeeklyCompleteness.incomplete, completeDays: 3, avg: 40.0));

      final store2 = WeeklyReportStore.inMemory(mem);
      final all = await store2.readAll();
      expect(all.length, 2);
      expect(all.first.weekStartKey, _week.startKey,
          reason: 'newest week first');
      expect(all.first.label, WeeklyCompleteness.complete);
      expect(all.first.completeDays, 6);
      expect(all.first.avgScoreCompleteDays, 61.0);
      expect(all.last.label, WeeklyCompleteness.incomplete);
    });

    test('regenerating a week replaces its entry (new outcome, new label)',
        () async {
      final mem = <String, String>{};
      final store = WeeklyReportStore.inMemory(mem);
      await store.upsert(_record(_week,
          label: WeeklyCompleteness.blocked, completeDays: 0));
      final next = await store.upsert(_record(_week,
          label: WeeklyCompleteness.complete, completeDays: 6, avg: 61.0));
      expect(next.length, 1);
      expect(next.single.label, WeeklyCompleteness.complete);
    });

    test('previousOf finds the immediately preceding week only', () async {
      final records = [
        _record(_week,
            label: WeeklyCompleteness.complete, completeDays: 6, avg: 61.0),
        _record(_prevWeek,
            label: WeeklyCompleteness.complete, completeDays: 5, avg: 55.0),
      ];
      expect(WeeklyReportStore.previousOf(records, _week)?.weekStartKey,
          _prevWeek.startKey);
      expect(WeeklyReportStore.previousOf(records, _prevWeek), isNull);
    });

    test('corrupt stored blob reads as an empty archive, never a throw',
        () async {
      final mem = <String, String>{WeeklyReportStore.storeKey: '{not json'};
      expect(await WeeklyReportStore.inMemory(mem).readAll(), isEmpty);
    });
  });

  group('zero-notification sink', () {
    test('the silent notifier records attempts and posts nothing', () async {
      final sink = WeeklySilentNotifier();
      expect(await sink.showReportReady(), isFalse);
      expect(await sink.showReportReady(), isFalse);
      expect(sink.calls, 2);
    });
  });
}
