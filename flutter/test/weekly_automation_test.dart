import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/weekly_automation.dart';
import 'package:tabs_lab/src/data/weekly_notification.dart';
import 'package:tabs_lab/src/data/weekly_report.dart';

// ── Weekly Report Package 2 — automation behavior arc:
// trigger timing (founder change: Sunday 21:00 local),
// idempotency per Mon–Sun week (reopens, relaunches, races),
// fail-closed entitlement under automation, the missed-week
// rule, and the Flag 1 Sunday-partial fixture at the
// automation level. (The P4 notification-negative fixtures
// live in weekly_notification_negative_test.dart.)
//
// Weeks: W1 = Mon Nov 2 – Sun Nov 8, 2026; W2 = Mon Nov 9 –
// Sun Nov 15, 2026; W3 = Mon Nov 16 – Sun Nov 22, 2026.

final _w1 = WeeklyWeekWindow(DateTime(2026, 11, 2), DateTime(2026, 11, 8));
final _w2 = WeeklyWeekWindow(DateTime(2026, 11, 9), DateTime(2026, 11, 15));
final _w3 = WeeklyWeekWindow(DateTime(2026, 11, 16), DateTime(2026, 11, 22));

class _Sink implements WeeklyNotifier {
  int sends = 0;
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> showWeeklyReady() async {
    sends++;
    return true;
  }
}

QuickLogEntry _entry(String id, DateTime day) => QuickLogEntry(
      id: id,
      categoryId: '1',
      body: 'entry $id',
      chips: '',
      manualText: '',
      timestamp:
          DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch,
    );

List<(String, int)> _seriesOn(List<DateTime> days, int value) =>
    [for (final d in days) (dateStrOf(d), value)];

/// A bar-passing snapshot for [week] (7 score days, 7 sleep
/// nights, 5 logged days, no denials).
ReportSnapshot _goodSnap(WeeklyWeekWindow week) => ReportSnapshot(
      last30Days: false,
      weekStart: week.start,
      weekEnd: week.end,
      generationTimestampMs:
          DateTime(2026, 11, 15, 21, 30).millisecondsSinceEpoch,
      logEntries: [
        for (var i = 0; i < 5; i++) _entry(i + 1, week.days[i]),
      ],
      categoriesMap: const {1: 'Symptoms'},
      dailyScoreSeries: _seriesOn(week.days, 60),
      sleepSeries: _seriesOn(week.days, 420),
    );

WeeklyArchiveRecord _record(WeeklyWeekWindow w,
        {WeeklyCompleteness label = WeeklyCompleteness.complete,
        int completeDays = 6,
        double? avg = 50.0}) =>
    WeeklyArchiveRecord(
      weekStartKey: w.startKey,
      weekEndKey: w.endKey,
      generatedAtMs: DateTime(2026, 11, 9, 9).millisecondsSinceEpoch,
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

class _Harness {
  _Harness({
    this._entitlement = WeeklyEntitlement.premium,
    this._entitlementThrows = false,
    ReportSnapshot Function(WeeklyWeekWindow week)? snapshotFor,
    this._generateGate,
  })  : _snapshotFor = snapshotFor ?? _goodSnap;

  final mem = <String, String>{};
  final sink = _Sink();
  final generatedWeeks = <WeeklyWeekWindow>[];
  int generateCalls = 0;
  bool generateFails = false;

  final WeeklyEntitlement _entitlement;
  final bool _entitlementThrows;
  final ReportSnapshot Function(WeeklyWeekWindow week) _snapshotFor;
  final Completer<void>? _generateGate;

  WeeklyAutomationCoordinator coordinator() => WeeklyAutomationCoordinator(
        checkEntitlement: () async {
          if (_entitlementThrows) throw StateError('check failed');
          return _entitlement;
        },
        store: WeeklyReportStore.inMemory(mem),
        generate: (week, now) async {
          generateCalls++;
          generatedWeeks.add(week);
          if (_generateGate != null) await _generateGate.future;
          if (generateFails) return null;
          return WeeklyGenerationResult(
            snapshot: _snapshotFor(week),
            fileName: 'weekly.pdf',
            savedPath: '/tmp/weekly-${week.startKey}.pdf',
          );
        },
        notifier: sink,
      );

  Future<List<WeeklyArchiveRecord>> archive() =>
      WeeklyReportStore.inMemory(mem).readAll();

  Future<void> seed(WeeklyArchiveRecord r) =>
      WeeklyReportStore.inMemory(mem).upsert(r);
}

void main() {
  group('trigger timing (Sunday 21:00 local)', () {
    test('due-week math: the most recent Sunday 21:00 governs', () {
      // Sunday before 21:00 → last week's trigger is the live one.
      expect(weeklyDueWeek(DateTime(2026, 11, 15, 20, 59)), _w1);
      // Sunday 21:00 sharp → the current week is due.
      expect(weeklyDueWeek(DateTime(2026, 11, 15, 21, 0)), _w2);
      expect(weeklyDueWeek(DateTime(2026, 11, 15, 21, 30)), _w2);
      // Monday / Wednesday → the week that ended Sunday.
      expect(weeklyDueWeek(DateTime(2026, 11, 16, 9)), _w2);
      expect(weeklyDueWeek(DateTime(2026, 11, 18, 12)), _w2);
      // Next Sunday before 21:00 → still W2; at 21:00 → W3.
      expect(weeklyDueWeek(DateTime(2026, 11, 22, 20, 0)), _w2);
      expect(weeklyDueWeek(DateTime(2026, 11, 22, 21, 0)), _w3);
    });

    test('no generation before Sunday 21:00 for the current week '
        '(previous week already generated)', () async {
      final h = _Harness();
      await h.seed(_record(_w1));
      final outcome =
          await h.coordinator().maybeGenerate(now: DateTime(2026, 11, 15, 20, 59));
      expect(outcome.kind, WeeklyAutoKind.notDue);
      expect(h.generateCalls, 0);
      expect(h.sink.sends, 0);
    });

    test('generation on the first open at Sunday 21:00', () async {
      final h = _Harness();
      await h.seed(_record(_w1));
      final outcome =
          await h.coordinator().maybeGenerate(now: DateTime(2026, 11, 15, 21, 0));
      expect(outcome.kind, WeeklyAutoKind.generatedNotified);
      expect(h.generatedWeeks, [_w2]);
      expect(h.sink.sends, 1);
    });

    test('first open AFTER the trigger (Sunday 23:15) generates '
        'the same week, covering it through generation time',
        () async {
      final h = _Harness();
      final outcome =
          await h.coordinator().maybeGenerate(now: DateTime(2026, 11, 15, 23, 15));
      expect(outcome.kind, WeeklyAutoKind.generatedNotified);
      expect(h.generatedWeeks, [_w2]);
    });

    test('a week missed entirely — unopened from before its '
        'Sunday 21:00 through the FOLLOWING Sunday 21:00 — is '
        'never generated or notified for as if fresh: only the '
        'new due week generates', () async {
      final h = _Harness();
      // First open is W3's trigger (Nov 22, 21:30). W2 (Nov 9–15)
      // was missed entirely; the archive is empty.
      final outcome =
          await h.coordinator().maybeGenerate(now: DateTime(2026, 11, 22, 21, 30));
      expect(outcome.kind, WeeklyAutoKind.generatedNotified);
      expect(h.generateCalls, 1, reason: 'exactly one generation');
      expect(h.generatedWeeks, [_w3],
          reason: 'the missed week is superseded, never generated');
      final records = await h.archive();
      expect(records.map((r) => r.weekStartKey), [_w3.startKey]);
      expect(h.sink.sends, 1,
          reason: 'the one send belongs to the fresh week only');
    });
  });

  group('idempotency — exactly one automatic generation per week', () {
    test('no re-trigger after the week is generated (reopens)',
        () async {
      final h = _Harness();
      final c = h.coordinator();
      final now = DateTime(2026, 11, 15, 21, 30);
      expect((await c.maybeGenerate(now: now)).kind,
          WeeklyAutoKind.generatedNotified);
      expect((await c.maybeGenerate(now: now)).kind,
          WeeklyAutoKind.notDue);
      expect(
          (await c.maybeGenerate(now: DateTime(2026, 11, 16, 8))).kind,
          WeeklyAutoKind.notDue);
      expect(h.generateCalls, 1);
      expect(h.sink.sends, 1);
      expect((await h.archive()).length, 1);
    });

    test('idempotent across a relaunch (new coordinator, same '
        'on-device archive)', () async {
      final h = _Harness();
      final now = DateTime(2026, 11, 15, 21, 30);
      await h.coordinator().maybeGenerate(now: now);
      // A relaunch constructs a fresh coordinator over the same
      // persisted archive — the week is already there.
      final relaunched = h.coordinator();
      final outcome = await relaunched.maybeGenerate(now: now);
      expect(outcome.kind, WeeklyAutoKind.notDue);
      expect(h.generateCalls, 1);
      expect(h.sink.sends, 1);
    });

    test('concurrent checks (load + resume racing) start at '
        'most one generation', () async {
      final gate = Completer<void>();
      final h = _Harness(generateGate: gate);
      final c = h.coordinator();
      final now = DateTime(2026, 11, 15, 21, 30);
      final first = c.maybeGenerate(now: now);
      final second = c.maybeGenerate(now: now);
      gate.complete();
      final outcomes = await Future.wait([first, second]);
      expect(h.generateCalls, 1);
      expect(h.sink.sends, 1);
      expect(
          outcomes.where((o) => o.kind == WeeklyAutoKind.generatedNotified).length,
          1);
      expect((await h.archive()).length, 1);
    });

    test('a failed generation archives nothing, notifies '
        'nothing, and the week stays due for a later open',
        () async {
      final h = _Harness()..generateFails = true;
      final c = h.coordinator();
      final now = DateTime(2026, 11, 15, 21, 30);
      final failed = await c.maybeGenerate(now: now);
      expect(failed.kind, WeeklyAutoKind.generationFailed);
      expect(await h.archive(), isEmpty);
      expect(h.sink.sends, 0);
      h.generateFails = false;
      final retried = await c.maybeGenerate(now: now);
      expect(retried.kind, WeeklyAutoKind.generatedNotified);
      expect(h.generateCalls, 2);
      expect(h.sink.sends, 1);
    });
  });

  group('entitlement under automation — fail-closed, pre-generation', () {
    test('free: zero generations, zero sends, archive untouched',
        () async {
      final h = _Harness(entitlement: WeeklyEntitlement.free);
      final outcome = await h
          .coordinator()
          .maybeGenerate(now: DateTime(2026, 11, 15, 21, 30));
      expect(outcome.kind, WeeklyAutoKind.notEntitled);
      expect(h.generateCalls, 0);
      expect(h.sink.sends, 0);
      expect(await h.archive(), isEmpty);
    });

    test('lapsed: zero generations, zero sends, and the existing '
        'archive is left exactly as it was', () async {
      final h = _Harness(entitlement: WeeklyEntitlement.lapsed);
      await h.seed(_record(_w1, label: WeeklyCompleteness.incomplete));
      final outcome = await h
          .coordinator()
          .maybeGenerate(now: DateTime(2026, 11, 15, 21, 30));
      expect(outcome.kind, WeeklyAutoKind.notEntitled);
      expect(h.generateCalls, 0);
      expect(h.sink.sends, 0);
      final records = await h.archive();
      expect(records.length, 1);
      expect(records.single.weekStartKey, _w1.startKey);
      expect(records.single.label, WeeklyCompleteness.incomplete);
    });

    test('an entitlement check that throws is never Premium',
        () async {
      final h = _Harness(entitlementThrows: true);
      final outcome = await h
          .coordinator()
          .maybeGenerate(now: DateTime(2026, 11, 15, 21, 30));
      expect(outcome.kind, WeeklyAutoKind.notEntitled);
      expect(h.generateCalls, 0);
      expect(h.sink.sends, 0);
    });
  });

  group('Flag 1 at the automation level', () {
    test('Sunday-night generation: the still-running Sunday is '
        'never a complete day and contributes no score to the '
        'receipt average', () async {
      final days = _w2.days;
      final monSat = days.sublist(0, 6);
      final sunday = days[6];
      final h = _Harness(snapshotFor: (week) => ReportSnapshot(
            last30Days: false,
            weekStart: week.start,
            weekEnd: week.end,
            generationTimestampMs:
                DateTime(2026, 11, 15, 21, 30).millisecondsSinceEpoch,
            logEntries: [
              for (var i = 0; i < 7; i++) _entry(i + 1, days[i]),
            ],
            categoriesMap: const {1: 'Symptoms'},
            dailyScoreSeries: [
              ..._seriesOn(monSat, 60),
              (dateStrOf(sunday), 100),
            ],
            sleepSeries: [
              ..._seriesOn(monSat, 420),
              (dateStrOf(sunday), 400),
            ],
          ));
      await h.seed(_record(_w1, completeDays: 5, avg: 50.0));
      final outcome = await h
          .coordinator()
          .maybeGenerate(now: DateTime(2026, 11, 15, 21, 30));
      expect(outcome.kind, WeeklyAutoKind.generatedNotified);
      final ev = outcome.evaluation!;
      expect(ev.completeDays, 6,
          reason: 'Sunday is partial at 21:00 — Mon–Sat only');
      expect(ev.avgScoreCompleteDays, 60.0,
          reason: "Sunday's 100 must not move the average");
      expect(ev.receiptLine,
          'Your average Daily Score was 60.0, compared with 50.0 last '
          'week. Based on 6 complete days.');
      final record = (await h.archive())
          .firstWhere((r) => r.weekStartKey == _w2.startKey);
      expect(record.completeDays, 6);
      expect(record.avgScoreCompleteDays, 60.0);
      expect(h.sink.sends, 1);
    });
  });
}
