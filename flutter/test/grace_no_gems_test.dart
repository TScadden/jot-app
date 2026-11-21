import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/tabs_day.dart';

/// Midnight Grace no-gems fix (founder, Nov 21, 2026, 9:45 AM MST,
/// verbatim: "you shouldn't get gems for doing the grace period").
///
/// A Daily Summary completion that lands inside the Midnight Grace
/// window for the CLOSING day saves the streak but earns NO gems of
/// any kind: no +5 daily, no milestone crossing, no perfect-week
/// +20 for a week containing any grace-completed day (the strict
/// rule). Suppression keys off the per-day marker
/// (StreakState.graceCompletedDays), never the window — the C3
/// double-day case (closing day via grace + new day genuine) pays
/// the new day normally. Client-side only: the server stores the
/// streak blob verbatim and cannot distinguish a grace day, so the
/// client must simply never queue the key (Mason's survey, stage
/// log Nov 21, 2026).
void main() {
  group('GemService grace suppression (spy grants)', () {
    late _SpyGemServer server;
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

    StreakState stateWith({
      Set<String> counted = const {},
      Set<String> completed = const {},
      Set<String> grace = const {},
    }) =>
        StreakState(
          seeded: true,
          countedDays: counted,
          summaryCompletedDays: completed,
          graceCompletedDays: grace,
        );

    void seedDiskBlob(Map<String, dynamic> blob) {
      disk[GemService.storageKey] = jsonEncode(blob);
    }

    setUp(() {
      server = _SpyGemServer();
      disk = {};
      gems = buildService();
    });

    test('grace completion: zero grant calls, empty lines, the '
        'streak marker still advances (crossing consumed)', () async {
      final state = stateWith(
        counted: {'2026-11-05'},
        completed: {'2026-11-05'},
        grace: {'2026-11-05'},
      );
      final r = await gems.processCompletion(
        summaryTabsDay: '2026-11-05',
        previousStreak: 0,
        newStreak: 1,
        settledState: state,
        now: DateTime(2026, 11, 6, 0, 0, 45),
      );
      expect(server.grantCalls, isEmpty,
          reason: 'a grace completion must never request a grant');
      expect(r.lines, isEmpty,
          reason: 'no earn line of any kind on the celebration');
      expect(gems.debugPending, isEmpty);
      expect(gems.debugLastStreak, 1,
          reason: '_lastStreak advances even though nothing paid — '
              'the crossing is consumed permanently');
      // Relaunch + app-open replay must not resurrect anything.
      final relaunched = buildService();
      await relaunched.onAppOpen(
        state: state,
        now: DateTime(2026, 11, 6, 9),
      );
      expect(server.grantCalls, isEmpty);
      expect(server.balance, 0);
    });

    test('control: a normal completion pays the daily +5 exactly '
        'as before', () async {
      final state = stateWith(
        counted: {'2026-11-05'},
        completed: {'2026-11-05'},
      );
      final r = await gems.processCompletion(
        summaryTabsDay: '2026-11-05',
        previousStreak: 0,
        newStreak: 1,
        settledState: state,
        now: DateTime(2026, 11, 5, 12),
      );
      expect(server.grantCalls, ['daily:2026-11-05']);
      expect(r.lines, ['+5 gems']);
      expect(r.balance, 5);
    });

    test('milestone crossing on a grace day pays nothing and is '
        'never re-paid by the next normal completion', () async {
      final days = {
        '2026-10-30',
        '2026-10-31',
        '2026-11-01',
        '2026-11-02',
        '2026-11-03',
        '2026-11-04',
        '2026-11-05',
      };
      final graceState = stateWith(
        counted: days,
        completed: days,
        grace: {'2026-11-05'},
      );
      final r = await gems.processCompletion(
        summaryTabsDay: '2026-11-05',
        previousStreak: 6,
        newStreak: 7,
        settledState: graceState,
        now: DateTime(2026, 11, 6, 0, 0, 45),
      );
      expect(server.grantCalls, isEmpty,
          reason: 'no daily AND no milestone:7 for a grace day');
      expect(r.lines, isEmpty);
      expect(gems.debugLastStreak, 7,
          reason: 'the 7-day crossing is consumed, not deferred');

      // The next day completes normally: only its own daily pays.
      final nextState = stateWith(
        counted: {...days, '2026-11-06'},
        completed: {...days, '2026-11-06'},
        grace: {'2026-11-05'},
      );
      final r2 = await gems.processCompletion(
        summaryTabsDay: '2026-11-06',
        previousStreak: 7,
        newStreak: 8,
        settledState: nextState,
        now: DateTime(2026, 11, 6, 12),
      );
      expect(server.grantCalls, ['daily:2026-11-06'],
          reason: 'milestone:7 must NOT be re-evaluated later');
      expect(r2.lines, ['+5 gems']);
    });

    test('C3 double-day: closing day via grace pays 0, the new '
        'day genuinely completed pays its +5', () async {
      // One entry inside the window completed BOTH days: the
      // closing day (2026-11-05) via grace, the new day
      // (2026-11-06) by its own evidence within its own day.
      final closing = stateWith(
        counted: {'2026-11-05'},
        completed: {'2026-11-05'},
        grace: {'2026-11-05'},
      );
      final r1 = await gems.processCompletion(
        summaryTabsDay: '2026-11-05',
        previousStreak: 0,
        newStreak: 1,
        settledState: closing,
        now: DateTime(2026, 11, 6, 0, 0, 45),
      );
      expect(r1.lines, isEmpty);
      expect(server.grantCalls, isEmpty);

      final both = stateWith(
        counted: {'2026-11-05', '2026-11-06'},
        completed: {'2026-11-05', '2026-11-06'},
        grace: {'2026-11-05'},
      );
      final r2 = await gems.processCompletion(
        summaryTabsDay: '2026-11-06',
        previousStreak: 1,
        newStreak: 2,
        settledState: both,
        now: DateTime(2026, 11, 6, 12),
      );
      expect(server.grantCalls, ['daily:2026-11-06'],
          reason: 'suppression keys off the per-day marker, never '
              'the window — the new day is NOT over-suppressed');
      expect(r2.lines, ['+5 gems']);
      expect(server.balance, 5);
    });

    test('perfect week STRICT: processCompletion queues no week '
        'key when any day of the week was grace-completed', () async {
      // Week Mon 2026-11-16 .. Sun 2026-11-22, all 7 completed;
      // Wednesday 2026-11-18 was completed via grace. The Sunday
      // completion itself is genuine.
      final week = gemWeekDays('2026-11-16');
      final state = stateWith(
        counted: week.toSet(),
        completed: week.toSet(),
        grace: {'2026-11-18'},
      );
      final r = await gems.processCompletion(
        summaryTabsDay: '2026-11-22',
        previousStreak: 6,
        newStreak: 7,
        settledState: state,
        now: DateTime(2026, 11, 22, 12),
      );
      expect(server.grantCalls,
          containsAll(['daily:2026-11-22', 'milestone:7']));
      expect(server.grantCalls, isNot(contains('week:2026-11-16')),
          reason: 'a week containing ANY grace day does not pay');
      expect(r.lines, ['+5 gems', '+25 gems — 7-day streak bonus']);
    });

    test('perfect week STRICT: onAppOpen does not re-queue a week '
        'key for a grace-tainted week', () async {
      // Week Mon 2026-11-09 .. Sun 2026-11-15; Thursday
      // 2026-11-12 was grace-completed.
      final week = gemWeekDays('2026-11-09');
      final early = stateWith(
        counted: {'2026-11-09', '2026-11-10'},
        completed: {'2026-11-09', '2026-11-10'},
      );
      await gems.onAppOpen(state: early, now: DateTime(2026, 11, 10, 9));
      expect(server.grantCalls, isEmpty);
      final full = stateWith(
        counted: week.toSet(),
        completed: week.toSet(),
        grace: {'2026-11-12'},
      );
      await gems.onAppOpen(state: full, now: DateTime(2026, 11, 16, 9));
      expect(server.grantCalls, isNot(contains('week:2026-11-09')),
          reason: 'the reconcile path must apply the same strict '
              'predicate — suppression in processCompletion alone '
              'does not survive');
      expect(server.grantCalls, isEmpty);
    });

    test('flush hardening: a stale pending daily key for a grace '
        'day (queued by the shipped gem-paying build) is retired '
        'WITHOUT a request at app open', () async {
      // VC 100157 queued daily:2026-11-05 while offline; the new
      // build must never let that key reach the server.
      seedDiskBlob({
        'ownerEmail': null,
        'balance': null,
        'pending': ['daily:2026-11-05'],
        'granted': <String>[],
        'lastStreak': 1,
        'activatedDay': '2026-11-05',
      });
      final state = stateWith(
        counted: {'2026-11-05'},
        completed: {'2026-11-05'},
        grace: {'2026-11-05'},
      );
      await gems.onAppOpen(state: state, now: DateTime(2026, 11, 6, 9));
      expect(server.grantCalls, isEmpty,
          reason: 'the stale grace key is dropped, never requested');
      expect(gems.debugPending, isEmpty);
      expect(server.balance, 0);
    });

    test('flush hardening: a stale pending week key for a '
        'grace-tainted week is retired without a request on the '
        'retryPending path (adoption via a later completion)',
        () async {
      // Week Mon 2026-11-02 .. Sun 2026-11-08 contains the grace
      // day 2026-11-05. retryPending receives no state, so the
      // grace days must have been adopted into the service's own
      // persisted blob by an earlier settledState sighting.
      seedDiskBlob({
        'ownerEmail': null,
        'balance': null,
        'pending': ['week:2026-11-02'],
        'granted': <String>[],
        'lastStreak': 3,
        'activatedDay': '2026-11-02',
      });
      final later = stateWith(
        counted: {'2026-11-05', '2026-11-09'},
        completed: {'2026-11-05', '2026-11-09'},
        grace: {'2026-11-05'},
      );
      final r = await gems.processCompletion(
        summaryTabsDay: '2026-11-09',
        previousStreak: 3,
        newStreak: 4,
        settledState: later,
        now: DateTime(2026, 11, 9, 12),
      );
      expect(r.lines, ['+5 gems']);
      expect(server.grantCalls, ['daily:2026-11-09'],
          reason: 'the stale week key was dropped in the same '
              'flush, not requested');
      expect(gems.debugPending, isEmpty);
      await gems.retryPending();
      expect(server.grantCalls, ['daily:2026-11-09']);
    });

    test('flush hardening: adopted grace days persist in the '
        'service blob — a stale key landing after relaunch is '
        'still dropped by retryPending', () async {
      final state = stateWith(
        counted: {'2026-11-05'},
        completed: {'2026-11-05'},
        grace: {'2026-11-05'},
      );
      await gems.processCompletion(
        summaryTabsDay: '2026-11-05',
        previousStreak: 0,
        newStreak: 1,
        settledState: state,
        now: DateTime(2026, 11, 6, 0, 0, 45),
      );
      expect(server.grantCalls, isEmpty);
      // A VC 100157-era write lands the stale key in the blob
      // after the new build already adopted the grace day.
      final blob = jsonDecode(disk[GemService.storageKey]!)
          as Map<String, dynamic>;
      blob['pending'] = ['daily:2026-11-05'];
      disk[GemService.storageKey] = jsonEncode(blob);
      // Relaunch: retryPending sees NO state — only the persisted
      // adoption can save the key from being requested.
      final relaunched = buildService();
      await relaunched.retryPending();
      expect(server.grantCalls, isEmpty);
      expect(relaunched.debugPending, isEmpty);
    });
  });

  group('grace marker (engine)', () {
    test('completeDay viaGrace marks the newly counted day', () {
      const base = StreakState(accrualMonth: '2026-11');
      final via = completeDay(
        base,
        summaryTabsDay: '2026-11-05',
        now: DateTime(2026, 11, 5, 12),
        viaGrace: true,
      );
      expect(via.state.countedDays, contains('2026-11-05'));
      expect(via.state.graceCompletedDays, {'2026-11-05'});

      final normal = completeDay(
        base,
        summaryTabsDay: '2026-11-05',
        now: DateTime(2026, 11, 5, 12),
      );
      expect(normal.state.countedDays, contains('2026-11-05'));
      expect(normal.state.graceCompletedDays, isEmpty,
          reason: 'non-grace behavior is byte-identical: no marker');
    });

    test('toJson/fromJson round-trip preserves graceCompletedDays; '
        'a pre-fix blob deserializes with it empty', () {
      const s = StreakState(
        seeded: true,
        countedDays: {'2026-11-05'},
        summaryCompletedDays: {'2026-11-05'},
        graceCompletedDays: {'2026-11-05'},
        accrualMonth: '2026-11',
      );
      final back = StreakState.fromJson(s.toJson());
      expect(back.graceCompletedDays, {'2026-11-05'});
      expect(back, s);

      final legacy = Map<String, dynamic>.of(s.toJson())
        ..remove('graceCompletedDays');
      expect(StreakState.fromJson(legacy).graceCompletedDays, isEmpty);
    });
  });

  group('grace marker (store threading)', () {
    late Map<String, String> disk;
    late StreakStore store;

    Future<bool> push(int c, int b, String j,
            {int? purchasedFreezes}) async =>
        true;

    setUp(() {
      // Same calendar rule as the midnight grace suite: the
      // Tabs-day cutover is Nov 1, 2026, so Nov 5 00:00 is its
      // own Tabs day (under the legacy 04:00 rule it would still
      // belong to Nov 4).
      TabsDayBoundary.instance.debugCutoverAt = DateTime(2026, 11, 1);
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

    test('recordSummaryComplete(viaGrace: true) marks the day in '
        'the settled + pushed state', () async {
      final out = await store.recordSummaryComplete(
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: DateTime(2026, 11, 6, 0, 0, 45),
        summaryDay: DateTime(2026, 11, 5),
        push: push,
        viaGrace: true,
      );
      expect(out.completion, isNotNull);
      expect(out.state.countedDays, contains('2026-11-05'));
      expect(out.state.summaryCompletedDays, contains('2026-11-05'));
      expect(out.state.graceCompletedDays, {'2026-11-05'});
    });

    test('C1: a viaGrace re-fire does NOT re-mark a day already '
        'in summaryCompletedDays, while the counters-only seed '
        'case (counted, summaryCompletedDays empty) IS marked',
        () async {
      // Genuine case: Nov 5 completes normally, in its own day.
      final genuine = await store.recordSummaryComplete(
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: DateTime(2026, 11, 5, 12),
        summaryDay: DateTime(2026, 11, 5),
        push: push,
      );
      expect(genuine.state.summaryCompletedDays, contains('2026-11-05'));
      expect(genuine.state.graceCompletedDays, isEmpty);
      // The Vera hole, at store level: the same day re-fires
      // under grace (fired-marker write failed + cold restart
      // inside the same 90s window, per her review). The day was
      // already summary-completed before this call, so the grace
      // ensure must NOT mark it.
      final refire = await store.recordSummaryComplete(
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: DateTime(2026, 11, 6, 0, 0, 45),
        summaryDay: DateTime(2026, 11, 5),
        push: push,
        viaGrace: true,
      );
      expect(refire.state.summaryCompletedDays, contains('2026-11-05'));
      expect(refire.state.graceCompletedDays, isEmpty,
          reason: 'C1: a genuinely completed day must never gain '
              'the grace marker on a re-fire');

      // Seed case, on a fresh store: a counters-only completion
      // seed anchors the attested run ENDING at the summary day
      // (countedDays contains it) but leaves summaryCompletedDays
      // EMPTY, so this grace fire is the day\'s first summary
      // completion and the marker MUST land — the guard must not
      // close the case the ensure exists for.
      disk.clear();
      store.debugReset();
      final seeded = await store.recordSummaryComplete(
        pullSucceeded: true,
        seedCurrent: 3,
        seedBest: 3,
        seedStateJson: null,
        now: DateTime(2026, 11, 6, 0, 0, 45),
        summaryDay: DateTime(2026, 11, 5),
        push: push,
        viaGrace: true,
      );
      expect(seeded.state.countedDays, hasLength(3));
      expect(seeded.state.countedDays, contains('2026-11-05'));
      expect(seeded.state.graceCompletedDays, {'2026-11-05'},
          reason: 'C1: the counters-only seed case must still '
              'gain the grace marker');
    });

    tearDown(() {
      TabsDayBoundary.instance.debugCutoverAt = null;
    });

    test('recordSummaryComplete without the flag marks nothing '
        '(dev SIM / Restore / normal fires)', () async {
      final out = await store.recordSummaryComplete(
        pullSucceeded: true,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: DateTime(2026, 11, 5, 12),
        summaryDay: DateTime(2026, 11, 5),
        push: push,
      );
      expect(out.completion, isNotNull);
      expect(out.state.graceCompletedDays, isEmpty);
    });
  });
}

/// A spy grant server mirroring jot-server PR #41's shapes
/// (server-derived amounts, idempotent grants) that RECORDS every
/// request — the suppression assertions are about calls that must
/// never happen.
class _SpyGemServer {
  int balance = 0;
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
      (statusCode: 400, body: {'error': 'unused_in_these_tests'});
}
