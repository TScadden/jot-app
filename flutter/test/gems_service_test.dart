import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';

/// Gems service (Nov 19, 2026) — behavioral pins for the earn
/// hooks, the milestone/week evaluation, the offline queue, and
/// the spend flow, against a fake server that mirrors jot-server
/// PR #41's shapes (server-derived amounts, idempotent grants,
/// spend 409 codes with balances in the body).
void main() {
  group('GemService earn hooks', () {
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

    StreakState stateWith({
      Set<String> counted = const {},
      Set<String> completed = const {},
    }) =>
        StreakState(
          seeded: true,
          countedDays: counted,
          summaryCompletedDays: completed,
        );

    setUp(() {
      server = _FakeGemServer();
      disk = {};
      gems = buildService();
    });

    test('daily grant fires exactly once across re-settlement, '
        'relaunch, and adoption replay', () async {
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
      );
      final args = (
        summaryTabsDay: '2026-11-19',
        previousStreak: 0,
        newStreak: 1,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      final first = await gems.processCompletion(
        summaryTabsDay: args.summaryTabsDay,
        previousStreak: args.previousStreak,
        newStreak: args.newStreak,
        settledState: args.settledState,
        now: args.now,
      );
      expect(first.lines, ['+5 gems']);
      expect(first.balance, 5);
      // Re-settlement / watcher replay of the SAME completion.
      final replay = await gems.processCompletion(
        summaryTabsDay: args.summaryTabsDay,
        previousStreak: args.previousStreak,
        newStreak: args.newStreak,
        settledState: args.settledState,
        now: args.now,
      );
      expect(replay.lines, isEmpty,
          reason: 'an already-granted day shows no earn line');
      // Relaunch: a fresh service over the same disk.
      final relaunched = buildService();
      final afterRelaunch = await relaunched.processCompletion(
        summaryTabsDay: args.summaryTabsDay,
        previousStreak: args.previousStreak,
        newStreak: args.newStreak,
        settledState: args.settledState,
        now: args.now,
      );
      expect(afterRelaunch.lines, isEmpty);
      // Adoption/open replay must not re-request either.
      await relaunched.onAppOpen(state: state, now: args.now);
      expect(server.grantCalls, ['daily:2026-11-19'],
          reason: 'exactly one grant request total — no spam');
      expect(server.balance, 5);
      expect(server.ledger.length, 1);
    });

    test('B1 regression (Vera probe): wiped local history + '
        'server alreadyGranted → NO earn line, key retired, '
        'balance adopted', () async {
      // Vera's probe at head 75461e9, replicated exactly: the
      // local gems_v1 history is GONE (owner-mismatch clear /
      // reinstall / storage loss — the disk starts empty), so
      // the completion re-requests its key and the server
      // answers 200 {alreadyGranted: true} with the unchanged
      // balance. At head this returned lines: ['+5 gems'] —
      // a false earn line, forbidden by Juno §3a.
      final wiped = <String, String>{};
      final calls = <String>[];
      final s = GemService(
        grant: (key) async {
          calls.add(key);
          return (
            statusCode: 200,
            body: {
              'gemBalance': 5,
              'amount': 5,
              'alreadyGranted': true,
            },
          );
        },
        spend: server.spend,
        pullBalance: () async => 5,
      );
      s.debugSetStore(
        read: (k) async => wiped[k],
        write: (k, v) async => wiped[k] = v,
        delete: (k) async => wiped.remove(k),
      );
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
      );
      final r = await s.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 0,
        newStreak: 1,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      expect(r.lines, isEmpty,
          reason: 'Juno §3a: an already-granted day shows no line');
      expect(r.balance, 5,
          reason: 'the response balance is adopted either way');
      expect(calls, ['daily:2026-11-19']);
      expect(s.debugPending, isEmpty,
          reason: 'an alreadyGranted key still retires');
      expect(s.debugGranted, contains('daily:2026-11-19'));
    });

    test('B1 regression, milestone leg: an alreadyGranted '
        'milestone crossing earns no line either', () async {
      final wiped = <String, String>{};
      final s = GemService(
        grant: (key) async => (
          statusCode: 200,
          body: {
            'gemBalance': 30,
            'amount': key.startsWith('milestone:') ? 25 : 5,
            'alreadyGranted': true,
          },
        ),
        spend: server.spend,
        pullBalance: () async => 30,
      );
      s.debugSetStore(
        read: (k) async => wiped[k],
        write: (k, v) async => wiped[k] = v,
        delete: (k) async => wiped.remove(k),
      );
      final days = {
        '2026-11-13',
        '2026-11-14',
        '2026-11-15',
        '2026-11-16',
        '2026-11-17',
        '2026-11-18',
        '2026-11-19',
      };
      final state = stateWith(counted: days, completed: days);
      final r = await s.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 6,
        newStreak: 7,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      expect(r.lines, isEmpty,
          reason: 'neither the daily nor the milestone line shows '
              'when both grants are replays');
      expect(r.balance, 30);
      expect(s.debugPending, isEmpty);
      expect(
        s.debugGranted,
        containsAll(['daily:2026-11-19', 'milestone:7']),
      );
    });

    test('B1 paired case: a FRESH grant after the same wipe '
        'earns its line', () async {
      final wiped = <String, String>{};
      final s = GemService(
        grant: (key) async => (
          statusCode: 200,
          body: {
            'gemBalance': 5,
            'amount': 5,
            'alreadyGranted': false,
          },
        ),
        spend: server.spend,
        pullBalance: () async => 5,
      );
      s.debugSetStore(
        read: (k) async => wiped[k],
        write: (k, v) async => wiped[k] = v,
        delete: (k) async => wiped.remove(k),
      );
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
      );
      final r = await s.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 0,
        newStreak: 1,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      expect(r.lines, ['+5 gems']);
      expect(r.balance, 5);
      expect(s.debugPending, isEmpty);
    });

    test('milestone crossing fires once, with the Juno §3 lines '
        'in order', () async {
      final days = {
        '2026-11-13',
        '2026-11-14',
        '2026-11-15',
        '2026-11-16',
        '2026-11-17',
        '2026-11-18',
        '2026-11-19',
      };
      final state = stateWith(counted: days, completed: days);
      final r = await gems.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 6,
        newStreak: 7,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      expect(r.lines, ['+5 gems', '+25 gems — 7-day streak bonus']);
      expect(r.balance, 30);
      expect(server.grantCalls,
          containsAll(['daily:2026-11-19', 'milestone:7']));
      // No re-fire after restart with the same transition replayed.
      final relaunched = buildService();
      final replay = await relaunched.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 6,
        newStreak: 7,
        settledState: state,
        now: DateTime(2026, 11, 19, 13),
      );
      expect(replay.lines, isEmpty);
      expect(server.grantCalls.where((k) => k == 'milestone:7').length, 1);
    });

    test('no backfill: a streak already past a milestone when the '
        'feature first runs never grants it', () async {
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
      );
      final r = await gems.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 10,
        newStreak: 11,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      expect(r.lines, ['+5 gems']);
      expect(server.grantCalls, ['daily:2026-11-19']);
      expect(server.balance, 5);
    });

    test('milestone amounts follow the server ladder: 30 → +50, '
        '100 → +100, 200 → +100', () async {
      for (final (prev, next, bonus) in [
        (29, 30, 50),
        (99, 100, 100),
        (199, 200, 100),
      ]) {
        server = _FakeGemServer();
        disk = {};
        gems = buildService();
        final day = '2026-11-19';
        final state = stateWith(counted: {day}, completed: {day});
        final r = await gems.processCompletion(
          summaryTabsDay: day,
          previousStreak: prev,
          newStreak: next,
          settledState: state,
          now: DateTime(2026, 11, 19, 12),
        );
        expect(r.lines, ['+5 gems', '+$bonus gems — $next-day streak bonus'],
            reason: 'crossing $next');
        expect(server.balance, 5 + bonus);
      }
    });

    test('restart between settlement and grant: the crossing is '
        'queued durably and lands exactly once at next open',
        () async {
      server.failGrants = true;
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
      );
      final r = await gems.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 6,
        newStreak: 7,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      // The completion flow is NOT broken by the failed grant:
      // no lines (nothing landed), no throw, balance unchanged.
      expect(r.lines, isEmpty);
      expect(r.balance, isNull);
      expect(gems.debugPending,
          containsAll(['daily:2026-11-19', 'milestone:7']));
      // Relaunch with the network back: the queue retries.
      server.failGrants = false;
      final relaunched = buildService();
      final bal = await relaunched.onAppOpen(
        state: state,
        now: DateTime(2026, 11, 20, 9),
      );
      expect(bal, 30);
      expect(server.ledger.length, 2);
      expect(server.grantCalls.where((k) => k == 'milestone:7').length,
          greaterThanOrEqualTo(1));
      // And the server never double-granted despite the retries.
      expect(server.balance, 30);
    });

    test('bound refusal is retry-later, never dropped and never '
        'user-visible: the grant lands once the blob catches up',
        () async {
      // Vera server-review bounds: until the settled blob is on
      // the server, the grant refuses with a retryable shape.
      // The client must keep the key queued (like a network
      // failure), show no line, and land it exactly once later.
      var bound = true;
      final disk2 = <String, String>{};
      final s2 = GemService(
        grant: (key) async {
          if (bound) {
            // Mason PR #41 Fix Round 1's published refusal shape.
            return (
              statusCode: 409,
              body: {
                'error': 'grant_not_ready',
                'retryable': true,
                'reason': 'daily_not_in_summary_completed_days',
              },
            );
          }
          return server.grant(key);
        },
        spend: server.spend,
        pullBalance: () async => server.balance,
      );
      s2.debugSetStore(
        read: (k) async => disk2[k],
        write: (k, v) async => disk2[k] = v,
        delete: (k) async => disk2.remove(k),
      );
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
      );
      final r = await s2.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 6,
        newStreak: 7,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      expect(r.lines, isEmpty,
          reason: 'a bound refusal is never a user-visible earn');
      expect(s2.debugPending,
          containsAll(['daily:2026-11-19', 'milestone:7']));
      expect(server.balance, 0);
      // The blob lands; the next app-open sync retries and the
      // grants land exactly once.
      bound = false;
      final bal = await s2.onAppOpen(
        state: state,
        now: DateTime(2026, 11, 20, 9),
      );
      expect(bal, 30);
      expect(server.ledger.length, 2);
      expect(s2.debugPending, isEmpty);
    });

    test('grant keys are canonical by construction '
        '(milestone:7, never milestone:07)', () async {
      final state = stateWith(
        counted: {'2026-11-19'},
        completed: {'2026-11-19'},
      );
      await gems.processCompletion(
        summaryTabsDay: '2026-11-19',
        previousStreak: 6,
        newStreak: 7,
        settledState: state,
        now: DateTime(2026, 11, 19, 12),
      );
      final keyShape = RegExp(
        r'^(daily:\d{4}-\d{2}-\d{2}|milestone:(7|30|[1-9]\d*00)|week:\d{4}-\d{2}-\d{2})$',
      );
      expect(server.grantCalls, isNotEmpty);
      for (final k in server.grantCalls) {
        expect(keyShape.hasMatch(k), isTrue, reason: 'key $k');
      }
      expect(server.grantCalls, contains('milestone:7'));
      expect(server.grantCalls, isNot(contains('milestone:07')));
    });

    test('perfect week fires once for a 7/7 Mon–Sun week, never '
        'for 6/7', () async {
      // Week of Mon 2026-11-16 .. Sun 2026-11-22.
      final week = gemWeekDays('2026-11-16');
      expect(week.first, '2026-11-16');
      expect(week.last, '2026-11-22');
      final full = stateWith(
        counted: week.toSet(),
        completed: week.toSet(),
      );
      final r = await gems.processCompletion(
        summaryTabsDay: '2026-11-22',
        previousStreak: 6,
        newStreak: 7,
        settledState: full,
        now: DateTime(2026, 11, 22, 12),
      );
      expect(
        r.lines,
        ['+5 gems', '+25 gems — 7-day streak bonus', '+20 gems — perfect week bonus'],
      );
      expect(server.grantCalls, contains('week:2026-11-16'));
      // Once per week: replaying the Sunday completion re-fires
      // nothing.
      final callsBefore = server.grantCalls.length;
      await gems.processCompletion(
        summaryTabsDay: '2026-11-22',
        previousStreak: 6,
        newStreak: 7,
        settledState: full,
        now: DateTime(2026, 11, 22, 13),
      );
      expect(server.grantCalls.length, callsBefore);

      // 6/7 week: no week grant.
      server = _FakeGemServer();
      disk = {};
      gems = buildService();
      final six = week.toSet()..remove('2026-11-18');
      final partial = stateWith(counted: six, completed: six);
      final r2 = await gems.processCompletion(
        summaryTabsDay: '2026-11-22',
        previousStreak: 5,
        newStreak: 6,
        settledState: partial,
        now: DateTime(2026, 11, 22, 12),
      );
      expect(r2.lines, ['+5 gems']);
      expect(server.grantCalls, ['daily:2026-11-22']);
    });

    test('perfect week also settles at app open for a closed week',
        () async {
      final week = gemWeekDays('2026-11-09'); // Mon Nov 9..Sun Nov 15
      final state = stateWith(
        counted: week.toSet(),
        completed: week.toSet(),
      );
      // Feature activates Nov 10 (mid-week) via an app open when
      // only Nov 9–10 are completed so far; the week completes
      // Nov 15 but no completion hook ran the week check (e.g. the
      // app was not opened on the Sunday) — the next app open
      // settles it.
      final early = stateWith(
        counted: {'2026-11-09', '2026-11-10'},
        completed: {'2026-11-09', '2026-11-10'},
      );
      await gems.onAppOpen(state: early, now: DateTime(2026, 11, 10, 9));
      expect(server.grantCalls, isEmpty);
      final bal = await gems.onAppOpen(
        state: state,
        now: DateTime(2026, 11, 16, 9),
      );
      expect(server.grantCalls, contains('week:2026-11-09'));
      expect(bal, 20);
      final calls = server.grantCalls.length;
      await gems.onAppOpen(state: state, now: DateTime(2026, 11, 17, 9));
      expect(server.grantCalls.length, calls,
          reason: 'the week grant fires once, not per open');
    });
  });

  group('GemService spend', () {
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

    setUp(() {
      server = _FakeGemServer();
      disk = {};
      gems = buildService();
    });

    test('success: -300, +1 freeze, balance adopted from server',
        () async {
      server.balance = 350;
      await gems.refreshBalance();
      expect(gems.balance, 350);
      final r = await gems.spendOnFreeze();
      expect(r.status, GemSpendStatus.success);
      expect(r.balance, 50);
      expect(r.purchasedFreezes, 1);
      expect(gems.balance, 50);
      expect(server.balance, 50);
      expect(server.purchasedFreezes, 1);
    });

    test('each spend intent generates a unique spendId', () async {
      server.balance = 700;
      await gems.spendOnFreeze();
      await gems.spendOnFreeze();
      // Both spends succeed under the current server rule (a held
      // purchased-class freeze no longer blocks a gem buy) — what
      // matters here is the two ids differ.
      expect(server.spendIds.toSet().length, 2);
    });

    test('gem-buy rule change: a spend succeeds while a '
        'purchased-class freeze is held — the count rises 1 → 2 '
        '→ 3 in the same bucket', () async {
      server.balance = 800;
      server.purchasedFreezes = 1;
      final r1 = await gems.spendOnFreeze();
      expect(r1.status, GemSpendStatus.success);
      expect(r1.purchasedFreezes, 2);
      expect(r1.balance, 500);
      final r2 = await gems.spendOnFreeze();
      expect(r2.status, GemSpendStatus.success);
      expect(r2.purchasedFreezes, 3);
      expect(r2.balance, 200);
      expect(server.purchasedFreezes, 3);
    });

    test('replay of the same spendId is a replay, never a double '
        'charge', () async {
      server.balance = 350;
      final a = await gems.spendOnFreeze(spendId: 'intent-1');
      final b = await gems.spendOnFreeze(spendId: 'intent-1');
      expect(a.status, GemSpendStatus.success);
      expect(b.status, GemSpendStatus.replay);
      expect(server.balance, 50);
      expect(server.purchasedFreezes, 1);
    });

    test('insufficient: 409 maps, balance refreshes, no freeze',
        () async {
      server.balance = 40;
      final r = await gems.spendOnFreeze();
      expect(r.status, GemSpendStatus.insufficient);
      expect(r.balance, 40);
      expect(gems.balance, 40);
      expect(server.purchasedFreezes, 0);
    });

    test('legacy already-held: a pre-change server answering 409 '
        'purchased_already_held maps to the silent capReached '
        're-sync — never a failure outcome — with the held count '
        'and balance adopted', () async {
      server.balance = 500;
      server.purchasedFreezes = 1;
      server.legacyAlreadyHeld = true;
      final r = await gems.spendOnFreeze();
      expect(r.status, GemSpendStatus.capReached);
      expect(r.status, isNot(GemSpendStatus.failed));
      expect(r.purchasedFreezes, 1);
      expect(r.balance, 500);
      expect(gems.balance, 500);
      // No freeze was granted and no gems were charged.
      expect(server.purchasedFreezes, 1);
      expect(server.balance, 500);
    });

    test('cap reached: 409 freeze_cap_reached maps', () async {
      server.balance = 500;
      server.capReached = true;
      final r = await gems.spendOnFreeze();
      expect(r.status, GemSpendStatus.capReached);
      expect(r.balance, 500);
    });

    test('transport failure is a failed spend with no state change',
        () async {
      server.balance = 150;
      server.failSpends = true;
      final r = await gems.spendOnFreeze();
      expect(r.status, GemSpendStatus.failed);
      expect(server.balance, 150);
    });
  });

  group('GemCopy verbatim pins (Juno §§1–4)', () {
    test('§1 pill label', () {
      expect(GemCopy.pillLabel(0), '0 gems');
      expect(GemCopy.pillLabel(1), '1 gem');
      expect(GemCopy.pillLabel(10), '10 gems');
      expect(GemCopy.pillLabel(1000), '1000 gems');
    });

    test('§2 buy surface strings', () {
      expect(GemCopy.buyButtonLabel, 'GET ONE MORE FREEZE · 300 GEMS');
      expect(GemCopy.buyButtonLabel.length, 30);
      expect(GemCopy.balanceLine(35), 'You have 35 gems.');
      expect(GemCopy.balanceLine(1), 'You have 1 gem.');
      expect(GemCopy.spendSuccessTitle, 'freeze added');
      expect(
        GemCopy.spendSuccessBody(35),
        "you've got a freeze now. it covers one missed day. you have 35 gems left.",
      );
      expect(
        GemCopy.spendSuccessBody(1),
        "you've got a freeze now. it covers one missed day. you have 1 gem left.",
      );
      expect(
        GemCopy.insufficientLine(65),
        'you need 65 more gems for a freeze — you earn 5 gems each time you finish your daily summary.',
      );
      expect(
        GemCopy.insufficientLine(1),
        'you need 1 more gem for a freeze — you earn 5 gems each time you finish your daily summary.',
      );
    });

    test('§3 celebration lines', () {
      expect(GemCopy.dailyEarnLine, '+5 gems');
      expect(GemCopy.milestoneEarnLine(25, 7), '+25 gems — 7-day streak bonus');
      expect(GemCopy.milestoneEarnLine(50, 30), '+50 gems — 30-day streak bonus');
      expect(GemCopy.milestoneEarnLine(100, 100), '+100 gems — 100-day streak bonus');
      expect(GemCopy.milestoneEarnLine(100, 200), '+100 gems — 200-day streak bonus');
      expect(GemCopy.weekEarnLine, '+20 gems — perfect week bonus');
    });

    test('§4 explainer block verbatim', () {
      expect(GemCopy.explainerHeading, 'About gems');
      expect(GemCopy.explainerLines, [
        "Gems are earned in Tabs. You can't buy them, and they have no cash value.",
        'Finish your Daily Summary: +5 gems.',
        'Streak bonuses pay when you reach them: +25 gems at 7 days, +50 at 30 days, +100 at 100 days, and +100 at each 100 days after that.',
        'Perfect week: +20 gems when you finish your Daily Summary all 7 days of a Monday–Sunday week.',
        '300 gems buys one streak freeze — the freeze on this screen.',
      ]);
    });

    test('scope #6 sheet explainer: lines 1–4 verbatim + the '
        'approved line 5 (GEMS-MOVE-COPY §1.3 Proposal A)', () {
      expect(GemCopy.sheetExplainerLine5,
          '300 gems buys one streak freeze.');
      expect(GemCopy.sheetExplainerLines, [
        "Gems are earned in Tabs. You can't buy them, and they have no cash value.",
        'Finish your Daily Summary: +5 gems.',
        'Streak bonuses pay when you reach them: +25 gems at 7 days, +50 at 30 days, +100 at 100 days, and +100 at each 100 days after that.',
        'Perfect week: +20 gems when you finish your Daily Summary all 7 days of a Monday–Sunday week.',
        '300 gems buys one streak freeze.',
      ]);
    });
  });
}

/// A fake of the jot-server PR #41 gems endpoints: amounts are
/// derived from the key kind (client amounts ignored), grants are
/// idempotent per key, spends validate held → cap → balance in
/// order and are idempotent per spendId.
class _FakeGemServer {
  int balance = 0;
  int purchasedFreezes = 0;
  bool capReached = false;
  bool failGrants = false;
  bool failSpends = false;

  /// Models a PRE-rule-change server (Nov 21, 2026): one that
  /// still rejects a gem spend with `purchased_already_held`
  /// while a purchased-class freeze is held. The current server
  /// never returns that code for gem spends.
  bool legacyAlreadyHeld = false;
  final Set<String> ledger = {};
  final List<String> grantCalls = [];
  final List<String> spendIds = [];
  final Set<String> _spentIds = {};

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

  Future<GemRequestResult> spend(String spendId) async {
    spendIds.add(spendId);
    if (failSpends) return (statusCode: null, body: null);
    if (_spentIds.contains(spendId)) {
      return (
        statusCode: 200,
        body: {
          'gemBalance': balance,
          'purchasedFreezes': purchasedFreezes,
          'alreadyGranted': true,
        },
      );
    }
    Map<String, dynamic> refusal(String error) => {
          'error': error,
          'gemBalance': balance,
          'purchasedFreezes': purchasedFreezes,
        };
    if (legacyAlreadyHeld && purchasedFreezes > 0) {
      return (statusCode: 409, body: refusal('purchased_already_held'));
    }
    if (capReached) {
      return (statusCode: 409, body: refusal('freeze_cap_reached'));
    }
    if (balance < 300) {
      return (statusCode: 409, body: refusal('insufficient_gems'));
    }
    _spentIds.add(spendId);
    balance -= 300;
    purchasedFreezes += 1;
    return (
      statusCode: 200,
      body: {
        'gemBalance': balance,
        'purchasedFreezes': purchasedFreezes,
        'alreadyGranted': false,
      },
    );
  }
}
