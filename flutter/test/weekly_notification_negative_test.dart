import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/report_ready_notification.dart';
import 'package:tabs_lab/src/data/weekly_automation.dart';
import 'package:tabs_lab/src/data/weekly_notification.dart';
import 'package:tabs_lab/src/data/weekly_report.dart';

// ── Weekly Report Package 2 — P4 notification-negative proof
// (VERA-EVIDENCE-AUDIT.md §P4 closing work, verbatim shape).
//
// A recording notifier sink implementing the weekly notifier
// interface captures EVERY send attempt (count + title / body /
// channel). The blocked, low-data, and contradiction fixtures
// run the full automation path (trigger → entitlement →
// generation → Package 1 evaluator → archive → notification
// gate) and each asserts sends == 0 AND the held outcome. The
// positive control proves the sink can see a send: one
// bar-passing week → exactly one send, on the `Weekly reports`
// channel only, with Juno's verbatim title/body (rows 2.1–2.4).
//
// Fixture week: Mon Nov 9 – Sun Nov 15, 2026; the automation
// clock is pinned to Sunday Nov 15, 2026, 21:30 local — the
// founder-change trigger instant for that week.

final _week = WeeklyWeekWindow(DateTime(2026, 11, 9), DateTime(2026, 11, 15));
final _sundayNight = DateTime(2026, 11, 15, 21, 30);

/// One captured send attempt: everything the system would have
/// shown the user, verbatim.
class WeeklySendAttempt {
  final String channelId;
  final String channelName;
  final String title;
  final String body;
  const WeeklySendAttempt({
    required this.channelId,
    required this.channelName,
    required this.title,
    required this.body,
  });
}

/// The recording sink (Vera §P4.2): implements the weekly
/// notifier interface and records every send attempt instead of
/// posting. If the automation ever calls it, the attempt is
/// here — a fixture asserting zero sends is asserting this list
/// stayed empty through the whole run.
class RecordingWeeklyNotifier implements WeeklyNotifier {
  final List<WeeklySendAttempt> attempts = [];

  int get sends => attempts.length;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> showWeeklyReady() async {
    attempts.add(const WeeklySendAttempt(
      channelId: LocalWeeklyNotifier.channelId,
      channelName: LocalWeeklyNotifier.channelName,
      title: LocalWeeklyNotifier.title,
      body: LocalWeeklyNotifier.body,
    ));
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

ReportSnapshot _snap({
  List<(String, int)> scores = const [],
  List<(String, int)> sleep = const [],
  List<QuickLogEntry> entries = const [],
  Map<String, SectionMetadata> meta = const {},
}) =>
    ReportSnapshot(
      last30Days: false,
      weekStart: _week.start,
      weekEnd: _week.end,
      generationTimestampMs: _sundayNight.millisecondsSinceEpoch,
      logEntries: entries,
      categoriesMap: const {'1': 'Symptoms'},
      dailyScoreSeries: scores,
      sleepSeries: sleep,
      sectionMetadata: meta,
    );

/// Runs one staged snapshot through the whole automation path
/// at the Sunday-night trigger, with Premium entitlement.
class _Run {
  _Run(this.snapshot) {
    coordinator = WeeklyAutomationCoordinator(
      checkEntitlement: () async => WeeklyEntitlement.premium,
      store: WeeklyReportStore.inMemory(mem),
      generate: (week, now) async {
        generateCalls++;
        return WeeklyGenerationResult(
          snapshot: snapshot,
          fileName: 'weekly.pdf',
          savedPath: '/tmp/weekly.pdf',
        );
      },
      notifier: sink,
    );
  }

  final ReportSnapshot snapshot;
  final mem = <String, String>{};
  final sink = RecordingWeeklyNotifier();
  late final WeeklyAutomationCoordinator coordinator;
  int generateCalls = 0;

  Future<WeeklyAutoOutcome> run() =>
      coordinator.maybeGenerate(now: _sundayNight);

  Future<List<WeeklyArchiveRecord>> archive() =>
      WeeklyReportStore.inMemory(mem).readAll();
}

void main() {
  group('P4 — notification-negative fixtures (zero sends)', () {
    test('(a) Blocked: a verified permissionDenied section with '
        'otherwise bar-passing numbers → labeled Blocked, zero '
        'sends, permission-needed state data present, never ready',
        () async {
      final days = _week.days;
      // Staged via the availability-truth fake shape: heart
      // rate's own permission is the missing one, its read
      // failed, and it holds no data (recordCount 0, no series)
      // — a verified denial. Every bar input is otherwise
      // passing (7 score days, 5 sleep nights, 5 logged days),
      // so the ONLY thing holding this week is the denial.
      final run = _Run(_snap(
        scores: _seriesOn(days, 60),
        sleep: _seriesOn(days.sublist(0, 5), 420),
        entries: [
          for (var i = 0; i < 5; i++) _entry(i + 1, days[i]),
        ],
        meta: const {
          'dailyScore':
              SectionMetadata('dailyScore', DataSourceStatus.success, 7),
          'sleep': SectionMetadata('sleep', DataSourceStatus.success, 5),
          'heartRate': SectionMetadata(
              'heartRate', DataSourceStatus.permissionDenied, 0),
        },
      ));
      final outcome = await run.run();

      expect(run.generateCalls, 1);
      expect(run.sink.sends, 0,
          reason: 'a blocked week must never post the ready send');
      expect(outcome.kind, WeeklyAutoKind.generatedHeld);
      expect(outcome.notified, isFalse);
      final ev = outcome.evaluation!;
      expect(ev.label, WeeklyCompleteness.blocked);
      expect(ev.barMet, isFalse);
      expect(ev.contradiction, isFalse);
      expect(ev.receiptLine, isNull,
          reason: 'no receipt / ready language for a blocked week');
      expect(ev.pdfLine, 'This weekly report is incomplete.');

      // The held outcome IS the Juno §a permission-needed state
      // data (Package 1 rows 1.12–1.17 inputs): the blocked
      // sections, named as the PDF availability block names
      // them, ready for the page to render the state verbatim.
      expect(ev.blockedSections, ['HeartRate']);
      expect(weeklyPermissionTitle, 'Permission needed');
      expect(weeklyPermissionBody,
          "This report isn't complete. Tabs couldn't read the sections below because permission wasn't granted.");
      expect(weeklyPermissionSectionsLabel, 'Needs permission:');
      expect(weeklyPermissionGuidance,
          'Grant access in Health Connect, then generate the report again.');
      expect(weeklyPermissionPrimaryAction, 'Open Health Connect Settings');
      expect(weeklyPermissionSecondaryAction, 'Not now');

      final records = await run.archive();
      expect(records.single.label, WeeklyCompleteness.blocked);
      expect(records.single.blockedSections, ['HeartRate']);
    });

    test('(b) Low-data: a 2-of-7 week, all permissions granted, '
        'no contradiction → labeled Incomplete, zero sends, '
        'verbatim low-data framing, no trend/change language',
        () async {
      final two = _week.days.sublist(0, 2);
      final run = _Run(_snap(
        scores: _seriesOn(two, 55),
        sleep: _seriesOn(two, 400),
        entries: [for (var i = 0; i < 2; i++) _entry(i + 1, two[i])],
        meta: const {
          'dailyScore':
              SectionMetadata('dailyScore', DataSourceStatus.success, 2),
          'sleep': SectionMetadata('sleep', DataSourceStatus.success, 2),
          'heartRate':
              SectionMetadata('heartRate', DataSourceStatus.success, 2),
        },
      ));
      final outcome = await run.run();

      expect(run.sink.sends, 0,
          reason: 'a low-data week must never post the ready send');
      expect(outcome.kind, WeeklyAutoKind.generatedHeld);
      final ev = outcome.evaluation!;
      expect(ev.label, WeeklyCompleteness.incomplete);
      expect(ev.barMet, isFalse);
      expect(ev.blockedSections, isEmpty);
      expect(ev.contradiction, isFalse);
      expect(ev.receiptLine, isNull);
      // Row 1.19 framing, verbatim, attached to the outcome.
      expect(ev.pdfLine,
          'Not enough complete days this week to show a trend.');
      expect(weeklyLowDataFraming,
          'Not enough complete days this week to show a trend.');

      // No trend/change language anywhere in the outcome
      // (Juno banned constructions, both packages).
      final outcomeText = [
        ev.label.label,
        ev.pdfLine ?? '',
        ev.receiptLine ?? '',
        ...ev.blockedSections,
      ].join(' ').toLowerCase();
      for (final banned in [
        'rose',
        'fell',
        'improved',
        'declined',
        'better week',
        'quieter week',
        'worse week',
        'health has changed',
        'see how your health',
      ]) {
        expect(outcomeText, isNot(contains(banned)),
            reason: 'banned trend/change language in a held outcome');
      }

      final records = await run.archive();
      expect(records.single.label, WeeklyCompleteness.incomplete);
    });

    test('(c) Contradiction: Daily Scores present for ≥5 days '
        'while the staged collection claims permissionDenied '
        'for data the score path consumed → cross-check '
        'suppresses the send, labeled Blocked, zero sends',
        () async {
      final days = _week.days;
      // The founder's original shape: the store holds ≥5 days
      // of Daily Scores (and the sleep series survived in this
      // very snapshot) while the collection claims sleep is
      // permissionDenied — with the denied section's own record
      // count non-zero, refuting the claim from its own inputs.
      final run = _Run(_snap(
        scores: _seriesOn(days.sublist(0, 6), 60),
        sleep: _seriesOn(days.sublist(0, 5), 420),
        entries: [
          for (var i = 0; i < 5; i++) _entry(i + 1, days[i]),
        ],
        meta: const {
          'dailyScore':
              SectionMetadata('dailyScore', DataSourceStatus.success, 6),
          'sleep': SectionMetadata(
              'sleep', DataSourceStatus.permissionDenied, 5),
        },
      ));
      final outcome = await run.run();

      expect(run.sink.sends, 0,
          reason: 'a contradiction must suppress the send');
      expect(outcome.kind, WeeklyAutoKind.generatedHeld);
      final ev = outcome.evaluation!;
      expect(ev.contradiction, isTrue);
      expect(ev.label, WeeklyCompleteness.blocked);
      expect(ev.barMet, isFalse);
      expect(ev.receiptLine, isNull);

      final records = await run.archive();
      expect(records.single.label, WeeklyCompleteness.blocked);
    });
  });

  group('P4 — positive control', () {
    test('one bar-passing good week → exactly one send, on the '
        '`Weekly reports` channel only, Juno title/body verbatim',
        () async {
      final days = _week.days;
      final run = _Run(_snap(
        scores: _seriesOn(days, 60),
        sleep: _seriesOn(days, 420),
        entries: [
          for (var i = 0; i < 5; i++) _entry(i + 1, days[i]),
        ],
        meta: const {
          'dailyScore':
              SectionMetadata('dailyScore', DataSourceStatus.success, 7),
          'sleep': SectionMetadata('sleep', DataSourceStatus.success, 7),
        },
      ));
      final outcome = await run.run();

      expect(outcome.kind, WeeklyAutoKind.generatedNotified);
      expect(outcome.evaluation!.label, WeeklyCompleteness.complete);
      expect(outcome.evaluation!.barMet, isTrue);
      expect(run.sink.sends, 1, reason: 'exactly one send, ever');
      final attempt = run.sink.attempts.single;
      // Juno §c rows 2.1–2.4, byte-for-byte.
      expect(attempt.channelName, 'Weekly reports');
      expect(LocalWeeklyNotifier.channelDescription,
          'Shows when your automatic weekly report has finished generating.');
      expect(attempt.title, 'Your weekly report is ready');
      expect(attempt.body, 'Tap to open Tabs to view it.');
      // Flag 5: the weekly send must NOT ride the requested-
      // report channel or carry its strings.
      expect(attempt.channelId, LocalWeeklyNotifier.channelId);
      expect(attempt.channelId,
          isNot(LocalReportReadyNotifier.channelId));
      expect(attempt.title, isNot(LocalReportReadyNotifier.title));
      expect(attempt.body, isNot(LocalReportReadyNotifier.body));

      final records = await run.archive();
      expect(records.single.label, WeeklyCompleteness.complete);
    });
  });
}
