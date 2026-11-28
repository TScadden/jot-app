import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/progress_report.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/weekly_automation.dart';
import 'package:tabs_lab/src/data/weekly_generation_claim.dart';
import 'package:tabs_lab/src/data/weekly_notification.dart';
import 'package:tabs_lab/src/data/weekly_report.dart';
import 'package:tabs_lab/src/data/weekly_report_background.dart';

// ── Weekly Report Background Generation — Vera ruling §6 test
// obligations 1–11 (the cross-process claim), plus the
// background-runner gate arc and the background-path honesty
// fixtures. Obligation 12 (pre-existing suites green, assertions
// unmodified) is proven by those suites' own runs, not here.
//
// All claim tests run against a REAL temp directory on workspace
// disk (the worktree's own filesystem), so exclusive-create
// atomicity is exercised against a real filesystem, not a fake
// seam. Weeks: W2 = Mon Nov 9 – Sun Nov 15, 2026; the trigger
// clock is Sunday Nov 15, 2026, 21:30 local.

final _w2 = WeeklyWeekWindow(DateTime(2026, 11, 9), DateTime(2026, 11, 15));
final _now = DateTime(2026, 11, 15, 21, 30);

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
  timestamp: DateTime(day.year, day.month, day.day, 12).millisecondsSinceEpoch,
);

ReportSnapshot _snap(WeeklyWeekWindow week, {bool barPassing = true}) {
  final days = week.days;
  final scoreDays = barPassing ? days : days.sublist(0, 2);
  return ReportSnapshot(
    last30Days: false,
    weekStart: week.start,
    weekEnd: week.end,
    generationTimestampMs: _now.millisecondsSinceEpoch,
    logEntries: [
      for (var i = 0; i < (barPassing ? 5 : 2); i++) _entry(i + 1, days[i]),
    ],
    categoriesMap: const {'1': 'Symptoms'},
    dailyScoreSeries: [for (final d in scoreDays) (dateStrOf(d), 60)],
    sleepSeries: [for (final d in scoreDays) (dateStrOf(d), 420)],
  );
}

class _Harness {
  _Harness(this.claimDir);

  final Directory claimDir;
  final mem = <String, String>{};
  final sink = _Sink();
  int generateCalls = 0;

  /// Per-test generation behavior; defaults to a bar-passing
  /// result. Receives the harness so a test can act mid-generation
  /// (swap the claim file, write a record, …).
  Future<WeeklyGenerationResult?> Function(_Harness h, WeeklyWeekWindow week)?
  onGenerate;

  WeeklyGenerationClaim claim() => WeeklyGenerationClaim.inDirectory(claimDir);

  File get claimFile => File('${claimDir.path}/claim_${_w2.startKey}.json');

  WeeklyAutomationCoordinator coordinator({WeeklyGenerationClaim? claim}) =>
      WeeklyAutomationCoordinator(
        checkEntitlement: () async => WeeklyEntitlement.premium,
        store: WeeklyReportStore.inMemory(mem),
        generate: (week, now) async {
          generateCalls++;
          final impl = onGenerate;
          if (impl != null) return impl(this, week);
          return WeeklyGenerationResult(
            snapshot: _snap(week),
            fileName: 'weekly.pdf',
            savedPath: '/tmp/weekly-${week.startKey}.pdf',
          );
        },
        notifier: sink,
        claim: claim ?? this.claim(),
      );

  Future<List<WeeklyArchiveRecord>> archive() =>
      WeeklyReportStore.inMemory(mem).readAll();

  Future<void> seedClaim({
    required String token,
    required DateTime mtime,
    String? rawContent,
  }) async {
    await claimDir.create(recursive: true);
    await claimFile.writeAsString(
      rawContent ??
          jsonEncode({
            'token': token,
            'weekStartKey': _w2.startKey,
            'claimedAtMs': mtime.millisecondsSinceEpoch,
          }),
    );
    await claimFile.setLastModified(mtime);
  }
}

class _ThrowingClaim implements WeeklyGenerationClaim {
  @override
  Future<WeeklyClaimHandle?> tryAcquire(
    String weekStartKey,
    DateTime now,
  ) async {
    throw StateError('claim infrastructure unavailable');
  }
}

void main() {
  late Directory root;
  var counter = 0;

  setUp(() async {
    root = await Directory(
      '${Directory.current.path}/.claim_test_tmp/${DateTime.now().millisecondsSinceEpoch}-${counter++}',
    ).create(recursive: true);
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  group('Vera §6 — claim obligations', () {
    test('1. forced-overlap two-coordinator race on a real '
        'filesystem: generate == 1, records == 1, sends == 1', () async {
      final h = _Harness(root);
      final entered = Completer<void>();
      final gate = Completer<void>();
      h.onGenerate = (hh, week) async {
        if (!entered.isCompleted) entered.complete();
        await gate.future;
        return WeeklyGenerationResult(
          snapshot: _snap(week),
          fileName: 'weekly.pdf',
          savedPath: '/tmp/weekly.pdf',
        );
      };
      final a = h.coordinator();
      final b = h.coordinator();
      final futureA = a.maybeGenerate(now: _now);
      // The barrier: A is INSIDE generation (claim held) before B
      // checks. Removing the claim makes B enter generation too
      // (generateCalls == 2) and this test fail.
      await entered.future;
      final outcomeB = await b.maybeGenerate(now: _now);
      expect(outcomeB.kind, WeeklyAutoKind.notDue);
      expect(h.generateCalls, 1);
      gate.complete();
      final outcomeA = await futureA;
      expect(outcomeA.kind, WeeklyAutoKind.generatedNotified);
      expect(h.generateCalls, 1, reason: 'exactly one generation');
      expect(
        (await h.archive()).length,
        1,
        reason: 'exactly one archive record',
      );
      expect(h.sink.sends, 1, reason: 'exactly one send');
      expect(
        await h.claimFile.exists(),
        isFalse,
        reason: 'the holder released its claim',
      );
    });

    test('2. stale-claim steal (mtime > TTL): generates, '
        'sends == 1, claim absent at end', () async {
      final h = _Harness(root);
      await h.seedClaim(
        token: 'dead-holder-token',
        mtime: _now.subtract(const Duration(minutes: 11)),
      );
      final outcome = await h.coordinator().maybeGenerate(now: _now);
      expect(outcome.kind, WeeklyAutoKind.generatedNotified);
      expect(h.generateCalls, 1);
      expect(h.sink.sends, 1);
      expect((await h.archive()).length, 1);
      expect(await h.claimFile.exists(), isFalse);
    });

    test('3. fresh claim respected: notDue, generate == 0, '
        'sends == 0, claim file byte-unchanged', () async {
      final h = _Harness(root);
      await h.seedClaim(token: 'live-holder-token', mtime: _now);
      final before = await h.claimFile.readAsBytes();
      final outcome = await h.coordinator().maybeGenerate(now: _now);
      expect(outcome.kind, WeeklyAutoKind.notDue);
      expect(h.generateCalls, 0);
      expect(h.sink.sends, 0);
      expect(await h.archive(), isEmpty);
      expect(
        await h.claimFile.readAsBytes(),
        before,
        reason: 'a non-holder never deletes or rewrites it',
      );
    });

    test('4. steal contention: exactly one proceeds, '
        'generate == 1, sends <= 1, records == 1', () async {
      final h = _Harness(root);
      await h.seedClaim(
        token: 'stale-token',
        mtime: _now.subtract(const Duration(minutes: 30)),
      );
      final a = h.coordinator();
      final b = h.coordinator();
      final outcomes = await Future.wait([
        a.maybeGenerate(now: _now),
        b.maybeGenerate(now: _now),
      ]);
      expect(h.generateCalls, 1);
      expect(h.sink.sends, lessThanOrEqualTo(1));
      expect(h.sink.sends, 1);
      expect((await h.archive()).length, 1);
      expect(
        outcomes.where((o) => o.kind == WeeklyAutoKind.generatedNotified),
        hasLength(1),
      );
    });

    test('5a. failure release (seam returns null): claim absent; '
        'immediate retry generates + sends exactly 1', () async {
      final h = _Harness(root);
      h.onGenerate = (hh, week) async => null;
      final failed = await h.coordinator().maybeGenerate(now: _now);
      expect(failed.kind, WeeklyAutoKind.generationFailed);
      expect(
        await h.claimFile.exists(),
        isFalse,
        reason: 'a failed run releases its claim immediately',
      );
      h.onGenerate = null;
      final retried = await h.coordinator().maybeGenerate(now: _now);
      expect(retried.kind, WeeklyAutoKind.generatedNotified);
      expect(h.generateCalls, 2);
      expect(h.sink.sends, 1);
      expect((await h.archive()).length, 1);
    });

    test('5b. failure release (seam throws): claim absent; '
        'immediate retry generates + sends exactly 1', () async {
      final h = _Harness(root);
      h.onGenerate = (hh, week) async => throw StateError('hc blew up');
      final failed = await h.coordinator().maybeGenerate(now: _now);
      expect(failed.kind, WeeklyAutoKind.generationFailed);
      expect(await h.claimFile.exists(), isFalse);
      expect(await h.archive(), isEmpty);
      expect(h.sink.sends, 0);
      h.onGenerate = null;
      final retried = await h.coordinator().maybeGenerate(now: _now);
      expect(retried.kind, WeeklyAutoKind.generatedNotified);
      expect(h.sink.sends, 1);
    });

    test('6. token-loss suppression: foreign token swapped in '
        'before send ⇒ record archived once, sends == 0, '
        'suppressed (notDue) outcome, foreign claim NOT deleted', () async {
      final h = _Harness(root);
      h.onGenerate = (hh, week) async {
        // Simulated steal mid-generation: the claim file now
        // carries a foreign token.
        await hh.claimFile.writeAsString(
          jsonEncode({
            'token': 'foreign-token',
            'weekStartKey': week.startKey,
            'claimedAtMs': _now.millisecondsSinceEpoch,
          }),
        );
        return WeeklyGenerationResult(
          snapshot: _snap(week),
          fileName: 'weekly.pdf',
          savedPath: '/tmp/weekly.pdf',
        );
      };
      final outcome = await h.coordinator().maybeGenerate(now: _now);
      expect(
        outcome.kind,
        WeeklyAutoKind.notDue,
        reason: 'the suppressed kind (Vera §3 step 9)',
      );
      expect(h.sink.sends, 0);
      expect(
        (await h.archive()).length,
        1,
        reason: 'the record is archived exactly once',
      );
      expect(
        await h.claimFile.exists(),
        isTrue,
        reason: 'the foreign claim must NOT be deleted',
      );
      final content = jsonDecode(await h.claimFile.readAsString()) as Map;
      expect(content['token'], 'foreign-token');
    });

    test('7. record-appeared suppression: a record written '
        'mid-generation survives byte-for-byte, sends == 0, '
        'no upsert-over', () async {
      final h = _Harness(root);
      final preExisting = WeeklyArchiveRecord(
        weekStartKey: _w2.startKey,
        weekEndKey: _w2.endKey,
        generatedAtMs: 12345,
        fileName: 'manual.pdf',
        savedPath: '/tmp/manual.pdf',
        label: WeeklyCompleteness.incomplete,
        blockedSections: const ['Sleep'],
        dailyScoreDays: 3,
        sleepNights: 2,
        loggedDays: 2,
        completeDays: 1,
        avgScoreCompleteDays: 42.5,
      );
      h.onGenerate = (hh, week) async {
        await WeeklyReportStore.inMemory(hh.mem).upsert(preExisting);
        return WeeklyGenerationResult(
          snapshot: _snap(week),
          fileName: 'weekly.pdf',
          savedPath: '/tmp/weekly.pdf',
        );
      };
      final outcome = await h.coordinator().maybeGenerate(now: _now);
      expect(outcome.kind, WeeklyAutoKind.notDue);
      expect(h.sink.sends, 0);
      final records = await h.archive();
      expect(records.length, 1);
      expect(
        records.single.toJson(),
        preExisting.toJson(),
        reason: 'the pre-existing record survives byte-for-byte',
      );
      expect(
        await h.claimFile.exists(),
        isFalse,
        reason: 'the suppressed run still releases its claim',
      );
    });

    test('8. kill-window regression: archive has the week + an '
        'orphan fresh claim ⇒ notDue from the archive, '
        'generate == 0, sends == 0', () async {
      final h = _Harness(root);
      await WeeklyReportStore.inMemory(h.mem).upsert(
        WeeklyArchiveRecord(
          weekStartKey: _w2.startKey,
          weekEndKey: _w2.endKey,
          generatedAtMs: 999,
          fileName: 'weekly.pdf',
          savedPath: '/tmp/weekly.pdf',
          label: WeeklyCompleteness.complete,
          blockedSections: const [],
          dailyScoreDays: 7,
          sleepNights: 7,
          loggedDays: 5,
          completeDays: 6,
          avgScoreCompleteDays: 60.0,
        ),
      );
      await h.seedClaim(token: 'orphan-token', mtime: _now);
      final outcome = await h.coordinator().maybeGenerate(now: _now);
      expect(outcome.kind, WeeklyAutoKind.notDue);
      expect(h.generateCalls, 0);
      expect(h.sink.sends, 0);
    });

    test('9. held week under claim: held record archived exactly '
        'as first-open, sends == 0, claim released, next check '
        'notDue via the archive', () async {
      final h = _Harness(root);
      h.onGenerate = (hh, week) async => WeeklyGenerationResult(
        snapshot: _snap(week, barPassing: false),
        fileName: 'weekly.pdf',
        savedPath: '/tmp/weekly.pdf',
      );
      final c = h.coordinator();
      final outcome = await c.maybeGenerate(now: _now);
      expect(outcome.kind, WeeklyAutoKind.generatedHeld);
      expect(h.sink.sends, 0);
      final records = await h.archive();
      expect(records.single.label, WeeklyCompleteness.incomplete);
      expect(await h.claimFile.exists(), isFalse);
      final next = await c.maybeGenerate(now: _now);
      expect(next.kind, WeeklyAutoKind.notDue);
      expect(h.generateCalls, 1);
    });

    test('10. claim-infrastructure failure: acquire throws ⇒ '
        'generate == 0, sends == 0, nothing archived, '
        'generationFailed, week still due on a healthy retry', () async {
      final h = _Harness(root);
      final outcome = await h
          .coordinator(claim: _ThrowingClaim())
          .maybeGenerate(now: _now);
      expect(outcome.kind, WeeklyAutoKind.generationFailed);
      expect(h.generateCalls, 0);
      expect(h.sink.sends, 0);
      expect(await h.archive(), isEmpty);
      final retried = await h.coordinator().maybeGenerate(now: _now);
      expect(retried.kind, WeeklyAutoKind.generatedNotified);
      expect(h.sink.sends, 1);
    });

    test('11a. corrupt claim, fresh mtime ⇒ treated as a live '
        'claim (test-3 behavior)', () async {
      final h = _Harness(root);
      await h.seedClaim(
        token: 'unused',
        mtime: _now,
        rawContent: 'not json {{{',
      );
      final before = await h.claimFile.readAsBytes();
      final outcome = await h.coordinator().maybeGenerate(now: _now);
      expect(outcome.kind, WeeklyAutoKind.notDue);
      expect(h.generateCalls, 0);
      expect(h.sink.sends, 0);
      expect(await h.claimFile.readAsBytes(), before);
    });

    test('11b. corrupt claim, stale mtime ⇒ stealable '
        '(test-2 behavior)', () async {
      final h = _Harness(root);
      await h.seedClaim(
        token: 'unused',
        mtime: _now.subtract(const Duration(minutes: 15)),
        rawContent: 'not json {{{',
      );
      final outcome = await h.coordinator().maybeGenerate(now: _now);
      expect(outcome.kind, WeeklyAutoKind.generatedNotified);
      expect(h.generateCalls, 1);
      expect(h.sink.sends, 1);
      expect(await h.claimFile.exists(), isFalse);
    });
  });

  group('background runner gates', () {
    WeeklyReportBackgroundRunner runner({
      String? email = 'user@example.com',
      bool channel = true,
      bool? grant = true,
      bool grantThrows = false,
      required Future<WeeklyAutomationCoordinator> Function() build,
      List<String>? logs,
    }) => WeeklyReportBackgroundRunner(
      readSessionEmail: () async => email,
      warmHistoryStore: (e) async {},
      probeChannel: () async => channel,
      hasBackgroundAccess: () async {
        if (grantThrows) throw StateError('bridge down');
        return grant!;
      },
      buildCoordinator: build,
      now: () => _now,
      log: logs?.add ?? (_) {},
    );

    test('grant-absent: silent no-op — coordinator never built, '
        'nothing generated', () async {
      var builds = 0;
      final r = runner(
        grant: false,
        build: () async {
          builds++;
          throw StateError('must not be built');
        },
      );
      final outcome = await r.run();
      expect(outcome.skippedReason, 'grant-absent');
      expect(builds, 0);
      expect(outcome.coordinatorOutcome, isNull);
    });

    test('probe failure (channel unavailable): unknown ⇒ no HC '
        'read — coordinator never built', () async {
      var builds = 0;
      final r = runner(
        channel: false,
        build: () async {
          builds++;
          throw StateError('must not be built');
        },
      );
      final outcome = await r.run();
      expect(outcome.skippedReason, 'grant-unknown');
      expect(builds, 0);
    });

    test('grant probe throws: unknown ⇒ no HC read', () async {
      var builds = 0;
      final r = runner(
        grantThrows: true,
        build: () async {
          builds++;
          throw StateError('must not be built');
        },
      );
      final outcome = await r.run();
      expect(outcome.skippedReason, 'grant-unknown');
      expect(builds, 0);
    });

    test('owner unverified (no stored session email): writes '
        'nothing — coordinator never built', () async {
      var builds = 0;
      final r = runner(
        email: null,
        build: () async {
          builds++;
          throw StateError('must not be built');
        },
      );
      final outcome = await r.run();
      expect(outcome.skippedReason, 'owner-unverified');
      expect(builds, 0);
    });

    test('granted + verified owner: the coordinator runs, '
        'generates, sends once, and the wall-time is recorded', () async {
      final h = _Harness(root);
      final logs = <String>[];
      final r = runner(build: () async => h.coordinator(), logs: logs);
      final outcome = await r.run();
      expect(outcome.skippedReason, isNull);
      expect(
        outcome.coordinatorOutcome!.kind,
        WeeklyAutoKind.generatedNotified,
      );
      expect(h.generateCalls, 1);
      expect(h.sink.sends, 1);
      expect(outcome.duration, isNotNull);
      expect(outcome.exceededAssumedBound, isFalse);
      expect(logs.single, contains('outcome generatedNotified'));
    });

    test('HC failure mid-run: no partial report, no '
        'notification, week stays due, clean retry', () async {
      final h = _Harness(root);
      h.onGenerate = (hh, week) async => throw StateError('HC read failed');
      final r = runner(build: () async => h.coordinator());
      final outcome = await r.run();
      expect(outcome.coordinatorOutcome!.kind, WeeklyAutoKind.generationFailed);
      expect(
        await h.archive(),
        isEmpty,
        reason: 'no partial report is archived',
      );
      expect(h.sink.sends, 0, reason: 'no notification');
      h.onGenerate = null;
      final retry = await r.run();
      expect(retry.coordinatorOutcome!.kind, WeeklyAutoKind.generatedNotified);
      expect(h.sink.sends, 1);
      expect((await h.archive()).length, 1);
    });

    test('honesty on the background path: bar-unmet ⇒ held, '
        'silent, no send', () async {
      final h = _Harness(root);
      h.onGenerate = (hh, week) async => WeeklyGenerationResult(
        snapshot: _snap(week, barPassing: false),
        fileName: 'weekly.pdf',
        savedPath: '/tmp/weekly.pdf',
      );
      final r = runner(build: () async => h.coordinator());
      final outcome = await r.run();
      expect(outcome.coordinatorOutcome!.kind, WeeklyAutoKind.generatedHeld);
      expect(h.sink.sends, 0);
      expect((await h.archive()).single.label, WeeklyCompleteness.incomplete);
    });
  });
}
