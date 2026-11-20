import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/clinician_report.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/notification_service.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/summary_completeness.dart';
import 'package:tabs_lab/src/data/tabs_day.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';

/// Boundary migration seam battery (Tabs day 04:00 → midnight,
/// founder decision Nov 19, 2026; audit §4 seam proof).
///
/// Seam calendar used throughout: install/activation day
/// C = Thu 2026-11-05, cutover M = (C+1) 00:00 = 2026-11-06 00:00,
/// C+1 = 2026-11-06, C+2 = 2026-11-07. Day C is the truncated
/// 20-hour day [C 04:00, M). The seam week (Mon–Sun containing C)
/// is Mon 2026-11-02 – Sun 2026-11-08.
void main() {
  final m = DateTime(2026, 11, 6); // cutover M = (C+1) 00:00 local
  DateTime at(int day, int h, [int min = 0]) => DateTime(2026, 11, day, h, min);

  tearDown(() {
    // The singleton is process-global within this file's isolate:
    // never leak a pinned cutover into another group.
    TabsDayBoundary.instance.debugCutoverAt = null;
  });

  group('(a) seam enumeration — daytime activation', () {
    test('load at C 15:00 stamps cutover (C+1) 00:00 and persists it',
        () async {
      final disk = <String, String>{};
      final boundary = TabsDayBoundary(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        clock: () => at(5, 15),
      );
      await boundary.load();
      expect(boundary.cutoverAt, m);
      expect(disk[TabsDayBoundary.cutoverStorageKey],
          '${m.millisecondsSinceEpoch}');
    });

    test('a stored cutover is read back, never re-stamped', () async {
      final disk = <String, String>{
        TabsDayBoundary.cutoverStorageKey: '${m.millisecondsSinceEpoch}',
      };
      final boundary = TabsDayBoundary(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        clock: () => at(20, 15), // a much later load
      );
      await boundary.load();
      expect(boundary.cutoverAt, m);
    });

    test('keys across [C-1 04:00, C+2 00:00) are consecutive '
        'calendar dates, each opening exactly once', () {
      final keys = <String>[];
      var cursor = DateTime(2026, 11, 4, 4);
      while (cursor.isBefore(DateTime(2026, 11, 7))) {
        keys.add(keyFor(cursor, m));
        cursor = nextBoundaryFor(cursor, m);
      }
      expect(keys, ['2026-11-04', '2026-11-05', '2026-11-06']);
      expect(cursor, DateTime(2026, 11, 7));
      // Spot keys either side of every seam instant.
      expect(keyFor(at(5, 3, 59), m), '2026-11-04');
      expect(keyFor(at(5, 4), m), '2026-11-05');
      expect(keyFor(at(5, 23, 59), m), '2026-11-05');
      expect(keyFor(at(6, 0), m), '2026-11-06');
      expect(keyFor(at(6, 1, 30), m), '2026-11-06');
    });

    test('day C spans 20h: starts C 04:00, next boundary after '
        'C 12:00 is M', () {
      expect(dayStartFor(at(5, 12), m), DateTime(2026, 11, 5, 4));
      expect(nextBoundaryFor(at(5, 12), m), m);
      expect(nextBoundaryFor(at(5, 12), m).difference(dayStartFor(at(5, 12), m)),
          const Duration(hours: 20));
    });

    test('day C+1 spans [M, C+2 00:00) — a full 24h', () {
      expect(dayStartFor(at(6, 12), m), m);
      expect(nextBoundaryFor(at(6, 12), m), DateTime(2026, 11, 7));
      expect(
          nextBoundaryFor(at(6, 12), m).difference(dayStartFor(at(6, 12), m)),
          const Duration(hours: 24));
    });
  });

  group('(b) install in the small hours', () {
    test('activation at C 01:00 stamps cutover (C+1) 00:00; the '
        'open day at install (C-1) is NOT re-labeled mid-flight',
        () async {
      final disk = <String, String>{};
      final boundary = TabsDayBoundary(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        clock: () => at(5, 1),
      );
      await boundary.load();
      expect(boundary.cutoverAt, m);
      // At the install instant the still-open Tabs day is C-1.
      expect(keyFor(at(5, 1), boundary.cutoverAt), '2026-11-04');
    });

    test('day C-1 keeps its full 24h span; day C is the truncated '
        'one', () {
      expect(dayStartFor(at(4, 12), m), DateTime(2026, 11, 4, 4));
      expect(nextBoundaryFor(at(4, 12), m), DateTime(2026, 11, 5, 4));
      expect(
          nextBoundaryFor(at(4, 12), m).difference(dayStartFor(at(4, 12), m)),
          const Duration(hours: 24));
      expect(
          nextBoundaryFor(at(5, 12), m).difference(dayStartFor(at(5, 12), m)),
          const Duration(hours: 20));
    });

    test('a load exactly at midnight stamps the NEXT midnight '
        '(strictly after)', () async {
      final boundary = TabsDayBoundary(
        read: (k) async => null,
        write: (k, v) async {},
        clock: () => DateTime(2026, 11, 5),
      );
      await boundary.load();
      expect(boundary.cutoverAt, m);
    });
  });

  group('(c) freeze covering the seam — real StreakStore settle path',
      () {
    late Map<String, String> disk;
    late StreakStore store;
    late List<({int current, int best, String json, int? purchased})> pushes;

    Future<bool> recordingPush(int c, int b, String j,
        {int? purchasedFreezes}) async {
      pushes.add((current: c, best: b, json: j, purchased: purchasedFreezes));
      return true;
    }

    setUp(() {
      TabsDayBoundary.instance.debugCutoverAt = m;
      disk = {};
      pushes = [];
      store = StreakStore.instance;
      store.debugReset();
      store.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async {
          disk[key] = value;
        },
        delete: (key) async {
          disk.remove(key);
        },
      );
      // Run of Nov 2–4 completed; day C (Nov 5) never completed;
      // one purchased freeze held.
      disk[StreakStore.storageKey] = jsonEncode({
        'ownerEmail': null,
        'state': const StreakState(
          seeded: true,
          seededCurrent: 3,
          seededBest: 3,
          countedDays: {'2026-11-02', '2026-11-03', '2026-11-04'},
          summaryCompletedDays: {'2026-11-02', '2026-11-03', '2026-11-04'},
          lastEvaluatedDay: '2026-11-04',
          accrualMonth: '2026-11',
          purchasedFreezes: 1,
        ).toJson(),
      });
    });

    test('truncated day C missed, a freeze bridges it: C lands '
        'covered (restoredDays), freeze attributed to month(C), '
        'streak unbroken, lastEvaluatedDay advances past the seam '
        'exactly once, no day evaluated twice', () async {
      final settled = await store.recordOpen(
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: at(6, 12),
        push: recordingPush,
      );
      expect(settled.countedDays, contains('2026-11-05'));
      expect(settled.restoredDays, {'2026-11-05'},
          reason: 'the truncated day is freeze-covered, not completed');
      expect(settled.summaryCompletedDays, isNot(contains('2026-11-05')));
      // Purchased freeze drawn first (A5 order), attributed to
      // month(C) via spoiledMonths; the monthly grant is untouched.
      expect(settled.purchasedFreezes, 0);
      expect(settled.spoiledMonths, {'2026-11'});
      expect(settled.consumedSaveMonths, isEmpty);
      expect(settled.lastEvaluatedDay, '2026-11-06');
      // Streak unbroken: run ending yesterday (C) is 4.
      expect(streakCurrent(settled, tabsDayAnchor(at(6, 12))), 4);

      // A second settle on C+1 bridges nothing and consumes
      // nothing: no day is evaluated twice.
      final again = await store.recordOpen(
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: at(6, 13),
        push: recordingPush,
      );
      expect(again, settled);
      final detailed = settleDetailed(again, at(6, 14));
      expect(detailed.bridgedDays, isEmpty);
      expect(detailed.freezeUsedKinds, isEmpty);
      expect(detailed.state.lastEvaluatedDay, '2026-11-06');
    });
  });

  group('(d) Daily Summary completion on cutover night — real '
      'SummaryCompletionWatcher path', () {
    const medCat = 8;
    const moodCat = 6;
    const goalsCat = 4;

    late Map<String, String> disk;
    late Map<String, String> markers;
    late StreakStore store;
    late SummaryCompletionWatcher watcher;
    late List<StreakCompletionResult> events;

    QuickLogEntry checkIn(DateTime atTime, int id) => QuickLogEntry(
          id: id,
          categoryId: moodCat,
          body: 'Feeling: 4/5 Today',
          chips: jsonEncode(const [feelingCheckInTag]),
          manualText: '',
          timestamp: atTime.millisecondsSinceEpoch,
        );

    SummaryCompletionContext ctxFor(
            List<QuickLogEntry> entries, DateTime start) =>
        SummaryCompletionContext(
          attestedPlan: AttestedPlan(
            plan: buildPlanForFeelingDay(
              feelingDayStart: start,
              medications: const [],
              reminders: const [],
              habits: const [],
              localState: const TodayPlanLocalState(),
              entries: entries,
              medicationCategoryId: medCat,
              goalsCategoryId: goalsCat,
            ),
            attestation: const PlanAttestation(
              medicationsResolved: true,
              remindersResolved: true,
              habitsResolved: true,
            ),
          ),
          entries: entries,
          moodCategoryId: moodCat,
        );

    Future<bool> push(int c, int b, String j,
            {int? purchasedFreezes}) async =>
        true;

    setUp(() {
      TabsDayBoundary.instance.debugCutoverAt = m;
      disk = {};
      markers = {};
      events = [];
      store = StreakStore.instance;
      store.debugReset();
      store.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async {
          disk[key] = value;
        },
        delete: (key) async {
          disk.remove(key);
        },
      );
      watcher = SummaryCompletionWatcher(
        store: store,
        onCompletion: (r, s) => events.add(r),
      );
      watcher.debugSetMarkerStore(
        read: (key) async => markers[key],
        write: (key, value) async {
          markers[key] = value;
        },
      );
    });

    tearDown(() => watcher.dispose());

    test('completion at C 23:30 counts toward C; completion at '
        '(C+1) 01:30 counts toward C+1 — watcher open-day string '
        'and engine counted day AGREE on both sides of the seam',
        () async {
      final evening = at(5, 23, 30);
      final firedEvening = await watcher.maybeFireSummaryCompletion(
        context: ctxFor([checkIn(evening, 100)], feelingDayStart(evening)),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: evening,
      );
      expect(firedEvening, isTrue);
      expect(markers[SummaryCompletionWatcher.firedDayStorageKey],
          '2026-11-05');
      expect(tabsDayStr(evening), '2026-11-05',
          reason: 'engine key agrees with the watcher marker for C');
      expect(store.state!.countedDays, {'2026-11-05'});

      final smallHours = at(6, 1, 30);
      final entries = [checkIn(evening, 100), checkIn(smallHours, 101)];
      final firedSmall = await watcher.maybeFireSummaryCompletion(
        context: ctxFor(entries, feelingDayStart(smallHours)),
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        push: push,
        now: smallHours,
      );
      expect(firedSmall, isTrue);
      expect(markers[SummaryCompletionWatcher.firedDayStorageKey],
          '2026-11-06');
      expect(tabsDayStr(smallHours), '2026-11-06',
          reason: 'engine key agrees with the watcher marker for C+1');
      expect(store.state!.countedDays, {'2026-11-05', '2026-11-06'});
      expect(store.state!.summaryCompletedDays,
          {'2026-11-05', '2026-11-06'});
      expect(events, hasLength(2));
    });
  });

  group('(e) gems daily-grant keys across the seam', () {
    late _FakeGemServer server;
    late Map<String, String> disk;
    late GemService gems;

    GemService buildService() {
      final s = GemService(
        grant: server.grant,
        spend: server.spend,
        pullBalance: () async => server.balance,
      );
      s.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      return s;
    }

    StreakState stateWith(Set<String> completed) => StreakState(
          seeded: true,
          countedDays: completed,
          summaryCompletedDays: completed,
        );

    setUp(() {
      TabsDayBoundary.instance.debugCutoverAt = m;
      server = _FakeGemServer();
      disk = {};
      gems = buildService();
    });

    test('completion on day C mints daily:C; completion on C+1 '
        'mints daily:C+1 — distinct keys, each granted once',
        () async {
      final dayC = tabsDayStr(at(5, 23, 30));
      expect(dayC, '2026-11-05');
      await gems.processCompletion(
        summaryTabsDay: dayC,
        previousStreak: 0,
        newStreak: 1,
        settledState: stateWith({'2026-11-05'}),
        now: at(5, 23, 30),
      );
      // Replay of the same completion mints nothing new.
      await gems.processCompletion(
        summaryTabsDay: dayC,
        previousStreak: 0,
        newStreak: 1,
        settledState: stateWith({'2026-11-05'}),
        now: at(5, 23, 45),
      );
      final dayC1 = tabsDayStr(at(6, 1, 30));
      expect(dayC1, '2026-11-06');
      await gems.processCompletion(
        summaryTabsDay: dayC1,
        previousStreak: 1,
        newStreak: 2,
        settledState: stateWith({'2026-11-05', '2026-11-06'}),
        now: at(6, 1, 30),
      );
      expect(
          server.grantCalls.where((k) => k == 'daily:2026-11-05'), hasLength(1));
      expect(
          server.grantCalls.where((k) => k == 'daily:2026-11-06'), hasLength(1));
      expect(server.ledger,
          containsAll(['daily:2026-11-05', 'daily:2026-11-06']));
      expect(server.balance, 10);
    });

    test('a pending daily:C queued pre-cutover retries verbatim '
        'post-cutover (key text unchanged)', () async {
      server.failGrants = true;
      await gems.processCompletion(
        summaryTabsDay: '2026-11-05',
        previousStreak: 0,
        newStreak: 1,
        settledState: stateWith({'2026-11-05'}),
        now: at(5, 23, 30),
      );
      expect(gems.debugPending, ['daily:2026-11-05']);
      expect(server.ledger, isEmpty);

      server.failGrants = false;
      // Post-cutover retry (the cutover is already pinned in this
      // group; the queued key predates it and must not be re-minted
      // under the new derivation).
      await gems.retryPending();
      expect(server.grantCalls,
          ['daily:2026-11-05', 'daily:2026-11-05'],
          reason: 'the retry sends the queued key text verbatim');
      expect(server.ledger, {'daily:2026-11-05'});
      expect(gems.debugPending, isEmpty);
      expect(server.balance, 5);
    });

    test('perfect week: the seam week (Mon 2026-11-02 – Sun '
        '2026-11-08) with all 7 keys in summaryCompletedDays fires '
        'week:2026-11-02 exactly once', () async {
      final week = {
        '2026-11-02',
        '2026-11-03',
        '2026-11-04',
        '2026-11-05',
        '2026-11-06',
        '2026-11-07',
        '2026-11-08',
      };
      await gems.processCompletion(
        summaryTabsDay: '2026-11-08',
        previousStreak: 6,
        newStreak: 7,
        settledState: stateWith(week),
        now: at(8, 12),
      );
      // Replay: no second week grant.
      await gems.processCompletion(
        summaryTabsDay: '2026-11-08',
        previousStreak: 6,
        newStreak: 7,
        settledState: stateWith(week),
        now: at(8, 13),
      );
      expect(server.grantCalls.where((k) => k == 'week:2026-11-02'),
          hasLength(1));
      expect(server.ledger, contains('week:2026-11-02'));
    });
  });

  group('(f) countdown target across the seam', () {
    test('nextTabsDayBoundary(C 21:00) with the cutover pinned is '
        'M (midnight), not (C+1) 04:00', () {
      TabsDayBoundary.instance.debugCutoverAt = m;
      expect(nextTabsDayBoundary(at(5, 21)), m);
      expect(nextTabsDayBoundary(at(5, 21)), isNot(DateTime(2026, 11, 6, 4)));
      // The pure shared definition agrees.
      expect(nextBoundaryFor(at(5, 21), m), m);
      // Post-cutover the target is the next midnight.
      expect(nextTabsDayBoundary(at(6, 21)), DateTime(2026, 11, 7));
    });
  });

  group('(g) shared-definition unity across the seam window', () {
    test('tabsDayStr, feelingDayStart date, energyDayLabel and '
        'clinicianEnergyDayKey agree for every sampled instant',
        () {
      TabsDayBoundary.instance.debugCutoverAt = m;
      final samples = <DateTime, String>{
        at(4, 2): '2026-11-03',
        at(4, 5): '2026-11-04',
        at(5, 3, 59): '2026-11-04',
        at(5, 4): '2026-11-05',
        at(5, 12): '2026-11-05',
        at(5, 23, 30): '2026-11-05',
        at(6, 0): '2026-11-06',
        at(6, 1, 30): '2026-11-06',
        at(6, 3, 59): '2026-11-06',
        at(6, 5): '2026-11-06',
        at(7, 2): '2026-11-07',
      };
      for (final e in samples.entries) {
        final t = e.key;
        final expected = e.value;
        expect(tabsDayStr(t), expected, reason: 'tabsDayStr at $t');
        expect(streakDayStr(feelingDayStart(t)), expected,
            reason: 'feelingDayStart date at $t');
        expect(energyDayLabel(t.millisecondsSinceEpoch), expected,
            reason: 'energyDayLabel at $t');
        expect(clinicianEnergyDayKey(t.millisecondsSinceEpoch), expected,
            reason: 'clinicianEnergyDayKey at $t');
      }
    });
  });

  group('(h) multi-device _adopt union merge — counted vs bridged '
      'day X (audit §5.2, determined here)', () {
    const x = '2026-11-05';
    const run = {'2026-11-02', '2026-11-03', '2026-11-04'};

    late Map<String, String> disk;
    late StreakStore store;

    Future<bool> push(int c, int b, String j,
            {int? purchasedFreezes}) async =>
        true;

    StreakState countedVersion({required int purchased}) => StreakState(
          seeded: true,
          countedDays: {...run, x},
          summaryCompletedDays: {...run, x},
          lastEvaluatedDay: x,
          accrualMonth: '2026-11',
          purchasedFreezes: purchased,
        );

    StreakState bridgedMonthly() => StreakState(
          seeded: true,
          countedDays: {...run, x},
          restoredDays: {x},
          summaryCompletedDays: run,
          consumedSaveMonths: {'2026-11'},
          spoiledMonths: {'2026-11'},
          lastEvaluatedDay: x,
          accrualMonth: '2026-11',
        );

    StreakState bridgedPurchased() => StreakState(
          seeded: true,
          countedDays: {...run, x},
          restoredDays: {x},
          summaryCompletedDays: run,
          spoiledMonths: {'2026-11'},
          lastEvaluatedDay: x,
          accrualMonth: '2026-11',
          purchasedFreezes: 0,
        );

    void seedDisk(StreakState s) {
      disk[StreakStore.storageKey] = jsonEncode({
        'ownerEmail': null,
        'state': s.toJson(),
      });
    }

    setUp(() {
      TabsDayBoundary.instance.debugCutoverAt = m;
      disk = {};
      store = StreakStore.instance;
      store.debugReset();
      store.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async {
          disk[key] = value;
        },
        delete: (key) async {
          disk.remove(key);
        },
      );
    });

    test('monthly grant: X counted on one device, bridged with '
        'month(X)\'s grant on another — the merged day survives '
        'as counted+completed+restored, and the consumed grant '
        'is NOT restored by the merge', () async {
      seedDisk(bridgedMonthly());
      final merged = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: jsonEncode(countedVersion(purchased: 0).toJson()),
        now: at(6, 12),
        push: push,
      );
      expect(merged.countedDays, contains(x));
      expect(merged.summaryCompletedDays, contains(x));
      expect(merged.restoredDays, contains(x));
      expect(merged.consumedSaveMonths, {'2026-11'},
          reason: 'set-based freeze accounting unions — a consumed '
              'monthly grant is never un-consumed by the merge');
      expect(merged.spoiledMonths, {'2026-11'});
    });

    test('purchased freeze, bridging record is the server record: '
        'the consumed freeze is NOT restored', () async {
      seedDisk(countedVersion(purchased: 1));
      final merged = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: jsonEncode(bridgedPurchased().toJson()),
        seedPurchasedFreezes: 0, // B's justified decrease landed
        now: at(6, 12),
        push: push,
      );
      expect(merged.summaryCompletedDays, contains(x));
      expect(merged.restoredDays, contains(x));
      expect(merged.purchasedFreezes, 0,
          reason: 'the scalar follows the winning (server) record '
              'and the A2 column — both say consumed');
    });

    test('purchased freeze, counting record is the server record: '
        'the consumed freeze IS resurrected by the merge (the '
        'scalar follows the server record / A2 column, which '
        'still shows it held) — while the spoiled-month '
        'attribution stays consumed', () async {
      seedDisk(bridgedPurchased());
      final merged = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: jsonEncode(countedVersion(purchased: 1).toJson()),
        seedPurchasedFreezes: 1, // A's column never saw a decrease
        now: at(6, 12),
        push: push,
      );
      expect(merged.summaryCompletedDays, contains(x));
      expect(merged.restoredDays, contains(x));
      expect(merged.purchasedFreezes, 1,
          reason: 'OBSERVED: the purchased-freeze scalar is taken '
              'from the winning server record (A2 formula), so a '
              'freeze the other device consumed reappears when '
              'the counting device\'s record wins the merge');
      expect(merged.spoiledMonths, {'2026-11'},
          reason: 'set-based attribution still never un-consumes');
    });
  });

  group('(i) legacy-default guard — no cutover loaded', () {
    test('with no cutover, all four delegates reproduce the old '
        '04:00 behavior at 02:00 and 05:00', () {
      TabsDayBoundary.instance.debugCutoverAt = null;
      expect(TabsDayBoundary.instance.cutoverAt, isNull);
      // 02:00 — still yesterday's Tabs day under the legacy rule.
      expect(tabsDayAnchor(at(5, 2)), DateTime(2026, 11, 4, 22));
      expect(tabsDayStr(at(5, 2)), '2026-11-04');
      expect(feelingDayStart(at(5, 2)), DateTime(2026, 11, 4, 4));
      expect(energyDayLabel(at(5, 2).millisecondsSinceEpoch), '2026-11-04');
      expect(clinicianEnergyDayKey(at(5, 2).millisecondsSinceEpoch),
          '2026-11-04');
      // 05:00 — the new Tabs day under the legacy rule.
      expect(tabsDayAnchor(at(5, 5)), DateTime(2026, 11, 5, 1));
      expect(tabsDayStr(at(5, 5)), '2026-11-05');
      expect(feelingDayStart(at(5, 5)), DateTime(2026, 11, 5, 4));
      expect(energyDayLabel(at(5, 5).millisecondsSinceEpoch), '2026-11-05');
      expect(clinicianEnergyDayKey(at(5, 5).millisecondsSinceEpoch),
          '2026-11-05');
      // Pure forms with an explicit null cutover agree.
      expect(anchorFor(at(5, 2), null), DateTime(2026, 11, 4, 22));
      expect(dayStartFor(at(5, 2), null), DateTime(2026, 11, 4, 4));
      expect(keyFor(at(5, 2), null), '2026-11-04');
      expect(keyForMs(at(5, 5).millisecondsSinceEpoch, null), '2026-11-05');
      expect(nextBoundaryFor(at(5, 12), null), DateTime(2026, 11, 6, 4));
    });
  });
}

/// Minimal fake gem server (mirrors gems_service_test's): server-
/// derived amounts, idempotent ledger, grant-call recording.
class _FakeGemServer {
  int balance = 0;
  bool failGrants = false;
  final Set<String> ledger = {};
  final List<String> grantCalls = [];

  static int? _amountFor(String key) {
    if (key.startsWith('daily:')) return 5;
    if (key.startsWith('week:')) return 20;
    if (key.startsWith('milestone:')) {
      final n = int.tryParse(key.substring('milestone:'.length));
      if (n == null) return null;
      return gemMilestoneBonus(n);
    }
    return null;
  }

  Future<GemRequestResult> grant(String key) async {
    grantCalls.add(key);
    if (failGrants) return (statusCode: null, body: null);
    final amount = _amountFor(key);
    if (amount == null) {
      return (statusCode: 400, body: {'error': 'invalid_key'});
    }
    if (ledger.contains(key)) {
      return (
        statusCode: 200,
        body: {'gemBalance': balance, 'amount': amount, 'alreadyGranted': true},
      );
    }
    ledger.add(key);
    balance += amount;
    return (
      statusCode: 200,
      body: {'gemBalance': balance, 'amount': amount, 'alreadyGranted': false},
    );
  }

  Future<GemRequestResult> spend(String spendId) async =>
      (statusCode: null, body: null);
}
