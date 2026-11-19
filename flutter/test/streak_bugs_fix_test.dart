import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_purchase.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/settings/streak_restore.dart';
import 'package:tabs_lab/src/data/settings_store.dart';

import 'test_helpers.dart';

/// Streak-bugs package (Nov 19, 2026) — regression pins for the
/// founder's VC 100142 report:
///
/// Bug 1: a purchased freeze whose server verify failed was
/// completed (consumed) in Play anyway — paid, no grant, no way
/// back, no feedback. Pins: verify gates completion; a failed
/// verify leaves the purchase pending and recoverable; restored
/// updates verify like purchased ones; a server alreadyGranted
/// answer adopts.
///
/// Bug 2: the Nov 18 flip-flop — a legacy app-open-counted day
/// with an incomplete summary and no freeze cover was stripped
/// by a strict evaluation (streak screen 0), then RESURRECTED by
/// the adoption union-merge and pushed back (27). Pins: strips
/// are tombstoned and merges never resurrect them; the day that
/// was open at the last evaluation is re-validated when it
/// closes; a freeze-covered closed day is kept.
///
/// Bug 3: Home's pills sat on raw pulled counters (27/68) while
/// the streak screen read the settled state (0). Pin: after a
/// settlement that breaks the run, Home's pills, the Home cache,
/// and the store state the streak screen renders from all read
/// the settled value.
///
/// Feature: dev Restore Streak — repairs a one-day break as a
/// NORMAL completed day through the authoritative store path,
/// idempotent, no-op with feedback when nothing is broken, and
/// never rendered for non-dev accounts.
void main() {
  Set<String> runEnding(String endDay, int length) {
    final end = DateTime.parse(endDay);
    return {
      for (var i = 0; i < length; i++)
        streakDayStr(end.subtract(Duration(days: i))),
    };
  }

  // ── Bug 1: purchase verify gating + recovery ─────────────────

  group('Bug 1 — purchase verify gates completion', () {
    late _FakePurchaseStore store;
    int? verifyResult;
    late StreakFreezePurchaseService service;

    StreakFreezePurchaseUpdate update(String status) =>
        StreakFreezePurchaseUpdate(
          productId: StreakFreezePurchaseService.productId,
          purchaseToken: 'token-1',
          orderId: 'GPA.1234',
          status: status,
        );

    Future<void> flush() async {
      for (var i = 0; i < 6; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    setUp(() {
      store = _FakePurchaseStore();
      verifyResult = null;
      service = StreakFreezePurchaseService(
        store: store,
        verify: ({
          required String productId,
          required String purchaseToken,
          required String orderId,
        }) async =>
            verifyResult,
      );
    });

    tearDown(() => service.dispose());

    test('verify FAILURE: the purchase is NOT completed/consumed, '
        'stays pending, and failure feedback is set', () async {
      await service.initialize();
      store.emit(update('purchased'));
      await flush();
      expect(store.completeCalls, 0,
          reason: 'a failed verify must never consume the purchase');
      expect(service.hasPendingVerification, isTrue);
      expect(service.pendingVerification!.orderId, 'GPA.1234');
      // A2 copy fix: §1b is THE message for the verify-pending
      // event — the generic §5c failure string must not also be
      // set for the same event (they contradict).
      expect(service.failureMessage, isNull,
          reason: '§5c must not accompany §1b for a verify-pending');
      expect(service.pendingMessage, StreakPurchaseCopy.verifyPending);
      expect(service.adoptedPurchasedFreezes, isNull);
    });

    test('verify SUCCESS: adopted first, completed exactly once, '
        'visible confirmation set', () async {
      verifyResult = 1;
      await service.initialize();
      store.emit(update('purchased'));
      await flush();
      expect(service.adoptedPurchasedFreezes, 1);
      expect(store.completeCalls, 1);
      expect(service.hasPendingVerification, isFalse);
      // No caller-supplied formatter → the ONE placeholder
      // constant is the visible confirmation surface.
      expect(service.successMessage, StreakPurchaseCopy.freezeGranted);
    });

    test('RESTORED update verifies and lands like a purchase '
        '(base code ignored restored updates entirely)', () async {
      verifyResult = 1;
      await service.initialize();
      store.emit(update('restored'));
      await flush();
      expect(service.adoptedPurchasedFreezes, 1);
      expect(store.completeCalls, 1);
      expect(service.restoredMessage, StreakPurchaseCopy.freezeRestored);
    });

    test('recovery: a purchase left pending by a failed verify '
        're-verifies and lands on recoverPendingPurchases',
        () async {
      await service.initialize();
      store.emit(update('purchased'));
      await flush();
      expect(service.hasPendingVerification, isTrue);
      expect(store.completeCalls, 0);

      verifyResult = 1; // the server can verify it now
      await service.recoverPendingPurchases();
      await flush();
      expect(service.hasPendingVerification, isFalse);
      expect(service.adoptedPurchasedFreezes, 1);
      expect(store.completeCalls, 1);
      expect(service.successMessage, isNotNull);
    });

    test('initialize asks Play to replay held purchases '
        '(restorePurchases) so a paid freeze cannot vanish',
        () async {
      await service.initialize();
      expect(store.restoreCalls, greaterThanOrEqualTo(1));
    });

    test('server alreadyGranted (409) adopts the held count and '
        'completes — a grant, not a failure', () async {
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path.contains('streak/purchase/verify')) {
            return http.Response(
              jsonEncode({'purchasedFreezes': 1, 'alreadyGranted': true}),
              409,
            );
          }
          return http.Response('{}', 200);
        }),
        sessionStore: FakeSessionStore()..token = 'tok',
      );
      final svc = StreakFreezePurchaseService(store: store, backend: backend);
      addTearDown(svc.dispose);
      await svc.initialize();
      store.emit(update('purchased'));
      await flush();
      expect(svc.adoptedPurchasedFreezes, 1);
      expect(store.completeCalls, 1);
      expect(svc.hasPendingVerification, isFalse);
    });

    test('A2 pin: the server REAL 409 shape '
        '{error: purchased_already_held} (NO purchasedFreezes '
        'field — jot-server PR #40 streak.js) adopts the held '
        'state from the profile pull and is NOT parked as a '
        'pending failure', () async {
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path.contains('streak/purchase/verify')) {
            // The ONLY 409 the server produces (PR #40).
            return http.Response(
              jsonEncode({'error': 'purchased_already_held'}),
              409,
            );
          }
          if (request.url.path.contains('sync/pull')) {
            // The authoritative held count lives in the profile
            // state, not in the 409 body.
            return http.Response(
              jsonEncode({
                'profile': {
                  'currentStreak': 27,
                  'bestStreak': 68,
                  'purchased_freezes': 1,
                },
              }),
              200,
            );
          }
          return http.Response('{}', 200);
        }),
        sessionStore: FakeSessionStore()..token = 'tok-a2',
      );
      final svc = StreakFreezePurchaseService(store: store, backend: backend);
      addTearDown(svc.dispose);
      await svc.initialize();
      store.emit(update('purchased'));
      await flush();
      expect(svc.adoptedPurchasedFreezes, 1,
          reason: 'held count must come from the profile state');
      expect(svc.hasPendingVerification, isFalse,
          reason: 'an already-held answer is not a pending failure');
      expect(svc.pendingMessage, isNull);
      expect(svc.failureMessage, isNull);
      expect(store.completeCalls, 1);
      // Juno §1c is the surface for this state, byte-exact.
      expect(svc.alreadyHeldMessage, StreakPurchaseCopy.alreadyHeld);
      expect(
        StreakPurchaseCopy.alreadyHeld,
        'you\'ve already got a freeze — it covers one missed day.',
      );
    });

    test('A2: an injected detailed verify answering alreadyHeld '
        'adopts the resolver count and never parks', () async {
      final svc = StreakFreezePurchaseService(
        store: store,
        verifyDetailed: ({
          required String productId,
          required String purchaseToken,
          required String orderId,
        }) async =>
            (count: null, alreadyHeld: true),
        resolveHeldCount: () async => 1,
      );
      addTearDown(svc.dispose);
      await svc.initialize();
      store.emit(update('purchased'));
      await flush();
      expect(svc.alreadyHeld, isTrue);
      expect(svc.alreadyHeldMessage, StreakPurchaseCopy.alreadyHeld);
      expect(svc.adoptedPurchasedFreezes, 1);
      expect(svc.hasPendingVerification, isFalse);
      expect(svc.pendingMessage, isNull);
      expect(svc.failureMessage, isNull);
      expect(store.completeCalls, 1);
    });
  });

  // ── Bug 2: deterministic settlement ──────────────────────────

  group('Bug 2 — settlement is deterministic, merges never '
      'resurrect a stripped day', () {
    late Map<String, String> disk;
    late StreakStore store;
    final pushes = <({int current, int best, String json})>[];

    Future<bool> push(int c, int b, String j,
        {int? purchasedFreezes}) async {
      pushes.add((current: c, best: b, json: j));
      return true;
    }

    /// The founder's shape: a 27-day run ending Nov 18 counted
    /// under legacy app-open semantics — Nov 18 never
    /// summary-completed (summaryCompletedDays empty), November's
    /// monthly grant already consumed by Nov 7 (a restored day),
    /// earned 0, purchased 0.
    String founderBlob({required String stamp}) => jsonEncode(
          StreakState(
            seeded: true,
            seededCurrent: 27,
            seededBest: 68,
            countedDays: runEnding('2026-11-18', 27),
            restoredDays: const {'2026-11-07'},
            consumedSaveMonths: const {'2026-11'},
            spoiledMonths: const {'2026-11'},
            accrualMonth: '2026-11',
            lastEvaluatedDay: stamp,
          ).toJson(),
        );

    setUp(() {
      disk = {};
      pushes.clear();
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

    tearDown(() => store.debugReset());

    test('flip-flop reproduction: open-day strip on Nov 18, then '
        'the stale server blob can NEVER resurrect Nov 18 after '
        'it closes — the run stays broken', () async {
      final blob = founderBlob(stamp: '2026-11-18');
      // Nov 18, evening: the strict evaluation strips the legacy
      // mark (P0 behavior, unchanged).
      final s1 = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: blob,
        now: DateTime(2026, 11, 18, 19),
        push: push,
      );
      expect(s1.countedDays, isNot(contains('2026-11-18')));
      expect(streakCurrent(s1, DateTime(2026, 11, 18, 19)), 26);
      expect(s1.invalidatedDays, contains('2026-11-18'));

      // Nov 19: the server STILL holds the stale blob (the strip's
      // push never landed / an older client re-pushed it). The
      // union-merge must not resurrect Nov 18: no summary
      // completion, November's grant is spent, so settlement
      // breaks the run and it stays broken on every later open.
      for (final at in [
        DateTime(2026, 11, 19, 10),
        DateTime(2026, 11, 19, 18),
        DateTime(2026, 11, 20, 9),
      ]) {
        final s = await store.recordOpen(
          pullSucceeded: true,
          seedCurrent: 27,
          seedBest: 68,
          seedStateJson: blob,
          now: at,
          push: push,
        );
        expect(s.countedDays, isNot(contains('2026-11-18')),
            reason: 'Nov 18 resurrected at $at');
        expect(streakCurrent(s, at), 0,
            reason: 'run must stay broken at $at');
      }
    });

    test('just-closed revalidation: a legacy mark that arrives '
        'after the open-day evaluation is stripped when the day '
        'closes, and the run breaks (no freeze left)', () async {
      // Local record evaluated on Nov 18 (stamp Nov 18) with the
      // run ending Nov 17; the stale blob carrying Nov 18's legacy
      // mark is what adoption sees on Nov 19.
      disk[StreakStore.storageKey] = jsonEncode({
        'ownerEmail': null,
        'state': StreakState(
          seeded: true,
          seededCurrent: 26,
          seededBest: 68,
          countedDays: runEnding('2026-11-17', 26),
          restoredDays: const {'2026-11-07'},
          consumedSaveMonths: const {'2026-11'},
          spoiledMonths: const {'2026-11'},
          accrualMonth: '2026-11',
          lastEvaluatedDay: '2026-11-18',
        ).toJson(),
      });
      final s = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: founderBlob(stamp: '2026-11-18'),
        now: DateTime(2026, 11, 19, 10),
        push: push,
      );
      expect(s.countedDays, isNot(contains('2026-11-18')));
      expect(streakCurrent(s, DateTime(2026, 11, 19, 10)), 0);
    });

    test('a freeze-covered closed day is KEPT by just-closed '
        'revalidation and stays a freeze day', () async {
      final blob = jsonEncode(
        StreakState(
          seeded: true,
          seededCurrent: 27,
          seededBest: 68,
          countedDays: runEnding('2026-11-18', 27),
          restoredDays: const {'2026-11-07', '2026-11-18'},
          consumedSaveMonths: const {'2026-11'},
          spoiledMonths: const {'2026-11'},
          accrualMonth: '2026-11',
          lastEvaluatedDay: '2026-11-18',
        ).toJson(),
      );
      final s = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: blob,
        now: DateTime(2026, 11, 19, 10),
        push: push,
      );
      expect(s.countedDays, contains('2026-11-18'));
      expect(s.restoredDays, contains('2026-11-18'));
      expect(streakCurrent(s, DateTime(2026, 11, 19, 10)), 27);
    });

    test('A1 pin (Vera repro): tombstone → purchased freeze '
        'adopted → settlement bridges the tombstoned day → the '
        'next adoption merge must NOT eat the bridged day; the '
        'freeze stays spent exactly once and current never '
        'returns to 0', () async {
      final blob = founderBlob(stamp: '2026-11-18');
      // 1) Nov 19 10:00 — strict evaluation strips + tombstones
      // Nov 18 (no completion, no cover): current 0.
      final s1 = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: blob,
        seedPurchasedFreezes: 0,
        now: DateTime(2026, 11, 19, 10),
        push: push,
      );
      expect(s1.countedDays, isNot(contains('2026-11-18')));
      expect(s1.invalidatedDays, contains('2026-11-18'));
      expect(streakCurrent(s1, DateTime(2026, 11, 19, 10)), 0);

      // 2) The Bug 1 grant-adoption path lands a purchased freeze.
      await store.adoptPurchasedFreezes(1);
      final withFreeze = jsonEncode(store.state!.toJson());

      // 3) Nov 19 18:00 — settlement bridges Nov 18 with the
      // purchased freeze: counted + restored, freeze spent,
      // current back to 27.
      final s3 = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: withFreeze,
        seedPurchasedFreezes: 1,
        now: DateTime(2026, 11, 19, 18),
        push: push,
      );
      expect(s3.countedDays, contains('2026-11-18'),
          reason: 'settlement must bridge Nov 18 with the freeze');
      expect(s3.restoredDays, contains('2026-11-18'));
      expect(s3.purchasedFreezes, 0,
          reason: 'the bridging freeze is spent');
      expect(streakCurrent(s3, DateTime(2026, 11, 19, 18)), 27);

      // 4) Nov 19 20:00 — re-adopt the blob step 3 pushed. The
      // freeze-bridged day must SURVIVE the adoption merge.
      final bridgedBlob = jsonEncode(s3.toJson());
      final s4 = await store.recordOpen(
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: bridgedBlob,
        seedPurchasedFreezes: 0,
        now: DateTime(2026, 11, 19, 20),
        push: push,
      );
      expect(s4.countedDays, contains('2026-11-18'),
          reason: 'freeze-covered Nov 18 was eaten by the merge');
      expect(s4.restoredDays, contains('2026-11-18'));
      expect(s4.purchasedFreezes, 0,
          reason: 'the freeze stays spent exactly once');
      expect(streakCurrent(s4, DateTime(2026, 11, 19, 20)), 27,
          reason: 'current must never flip back to 0');
    });

    test('engine: revalidateOpenDay tombstones; a genuine '
        'completion clears the tombstone', () {
      var s = StreakState(
        seeded: true,
        countedDays: runEnding('2026-11-18', 3),
        accrualMonth: '2026-11',
      );
      s = revalidateOpenDay(s, '2026-11-18');
      expect(s.countedDays, isNot(contains('2026-11-18')));
      expect(s.invalidatedDays, contains('2026-11-18'));
      final done = completeDay(
        s,
        summaryTabsDay: '2026-11-18',
        now: DateTime(2026, 11, 18, 20),
      );
      expect(done.state.countedDays, contains('2026-11-18'));
      expect(done.state.invalidatedDays, isNot(contains('2026-11-18')));
    });
  });

  // ── Feature: dev Restore Streak ──────────────────────────────

  group('Feature — dev Restore Streak (engine)', () {
    test('repairs a one-day break as a NORMAL completed day and '
        'recomputes current/best', () {
      final s = StreakState(
        seeded: true,
        seededCurrent: 26,
        seededBest: 68,
        countedDays: runEnding('2026-11-17', 26),
        restoredDays: const {'2026-11-07'},
        consumedSaveMonths: const {'2026-11'},
        accrualMonth: '2026-11',
        lastEvaluatedDay: '2026-11-17',
      );
      final r = restoreBrokenDay(s, todayTabsDay: '2026-11-19');
      expect(r.restoredDay, '2026-11-18');
      expect(r.state.countedDays, contains('2026-11-18'));
      expect(r.state.summaryCompletedDays, contains('2026-11-18'));
      // NOT a freeze day; no freeze consumed or granted.
      expect(r.state.restoredDays, isNot(contains('2026-11-18')));
      expect(r.state.consumedSaveMonths, s.consumedSaveMonths);
      expect(r.state.purchasedFreezes, s.purchasedFreezes);
      expect(r.state.earnedFreezes, s.earnedFreezes);
      final anchor = DateTime(2026, 11, 19, 10);
      expect(streakCurrent(r.state, anchor), 27);
      expect(streakBest(r.state), 68);
    });

    test('no break → no-op; two-day gap → no-op; second restore '
        'after a repair → no-op (idempotent)', () {
      final alive = StreakState(
        seeded: true,
        countedDays: runEnding('2026-11-18', 27),
        accrualMonth: '2026-11',
      );
      expect(
        restoreBrokenDay(alive, todayTabsDay: '2026-11-19').restoredDay,
        isNull,
      );
      final twoGap = StreakState(
        seeded: true,
        countedDays: runEnding('2026-11-16', 25),
        accrualMonth: '2026-11',
      );
      expect(
        restoreBrokenDay(twoGap, todayTabsDay: '2026-11-19').restoredDay,
        isNull,
      );
      final broken = StreakState(
        seeded: true,
        countedDays: runEnding('2026-11-17', 26),
        accrualMonth: '2026-11',
      );
      final once = restoreBrokenDay(broken, todayTabsDay: '2026-11-19');
      expect(once.restoredDay, '2026-11-18');
      final twice = restoreBrokenDay(once.state, todayTabsDay: '2026-11-19');
      expect(twice.restoredDay, isNull);
      expect(twice.state, once.state);
    });
  });

  group('Feature — dev Restore Streak (store path)', () {
    late Map<String, String> disk;
    late StreakStore store;
    final pushes = <({int current, int best, String json})>[];

    Future<bool> push(int c, int b, String j,
        {int? purchasedFreezes}) async {
      pushes.add((current: c, best: b, json: j));
      return true;
    }

    setUp(() {
      disk = {};
      pushes.clear();
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
      // The broken record on disk: a genuine v2 run whose days
      // summary-completed, ending Nov 17; Nov 18 was missed
      // entirely (never counted, no freeze left to cover it).
      disk[StreakStore.storageKey] = jsonEncode({
        'ownerEmail': null,
        'state': StreakState(
          seeded: true,
          seededCurrent: 26,
          seededBest: 68,
          countedDays: runEnding('2026-11-17', 26),
          summaryCompletedDays: runEnding('2026-11-17', 26),
          restoredDays: const {'2026-11-07'},
          consumedSaveMonths: const {'2026-11'},
          spoiledMonths: const {'2026-11'},
          accrualMonth: '2026-11',
          lastEvaluatedDay: '2026-11-17',
        ).toJson(),
      });
    });

    tearDown(() => store.debugReset());

    test('restore repairs the break, pushes through the profile '
        'path, and a second tap changes nothing', () async {
      final r1 = await store.recordDevRestore(
        pullSucceeded: false,
        seedCurrent: null,
        seedBest: null,
        seedStateJson: null,
        now: DateTime(2026, 11, 19, 10),
        push: push,
      );
      // pullSucceeded false → no push fires (the push discipline
      // is recordOpen's); use a successful pull for the push pin.
      expect(r1.restoredDay, '2026-11-18');
      expect(r1.current, 27);
      expect(r1.best, 68);
      expect(r1.state.countedDays, contains('2026-11-18'));
      expect(r1.state.summaryCompletedDays, contains('2026-11-18'));
      expect(r1.state.restoredDays, isNot(contains('2026-11-18')));

      final r2 = await store.recordDevRestore(
        pullSucceeded: true,
        seedCurrent: 27,
        seedBest: 68,
        seedStateJson: jsonEncode(r1.state.toJson()),
        now: DateTime(2026, 11, 19, 11),
        push: push,
      );
      expect(r2.restoredDay, isNull);
      expect(r2.current, 27);
      expect(pushes, isEmpty,
          reason: 'a no-op restore installs and pushes nothing');
    });

    test('restore with a successful pull pushes the restored '
        'record (current 27) through the profile path', () async {
      final r = await store.recordDevRestore(
        pullSucceeded: true,
        seedCurrent: 26,
        seedBest: 68,
        seedStateJson: null,
        now: DateTime(2026, 11, 19, 10),
        push: push,
      );
      expect(r.restoredDay, '2026-11-18');
      expect(pushes, hasLength(1));
      expect(pushes.single.current, 27);
      expect(pushes.single.best, 68);
      final pushedState = StreakState.fromJson(
        jsonDecode(pushes.single.json) as Map<String, dynamic>,
      );
      expect(pushedState.countedDays, contains('2026-11-18'));
      expect(pushedState.summaryCompletedDays, contains('2026-11-18'));
    });
  });

  group('Feature — Restore Streak widget + dev gate', () {
    testWidgets('tap restores → restored feedback; no break → '
        'no-op feedback', (tester) async {
      var outcome = const StreakRestoreOutcome(
        restoredDay: '2026-11-18',
        current: 27,
        best: 68,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreakRestoreEntry(onRestore: () async => outcome),
          ),
        ),
      );
      expect(find.byKey(const Key('streakRestoreButton')), findsOneWidget);
      await tester.tap(find.byKey(const Key('streakRestoreButton')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('streakRestoreFeedback')),
        findsOneWidget,
      );
      expect(find.text(StreakRestoreCopy.restored('2026-11-18', 27)),
          findsOneWidget);

      outcome = const StreakRestoreOutcome(
        restoredDay: null,
        current: 27,
        best: 68,
      );
      await tester.tap(find.byKey(const Key('streakRestoreButton')));
      await tester.pumpAndSettle();
      expect(find.text(StreakRestoreCopy.noBrokenDay),
          findsOneWidget);
    });

    // The settings gate (same fence as the SIM): one tree per
    // case, mirroring streak_dev_access_test's choreography.
    Future<void> pumpSettings(
      WidgetTester tester,
      Map<String, dynamic> pull,
    ) async {
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          backend: _FakeBackend(
            sessionStore: FakeSessionStore(),
            pull: pull,
          ),
          settingsStore: SettingsStore.withStorage(
            read: (k) async => null,
            write: (k, v) async {},
            delete: (k) async {},
          ),
          notificationService: FakeReminderNotificationService(),
          urlLauncher: (uri) async => true,
        ),
      ));
      await tester.pumpAndSettle();
      final entry = find.byKey(const ValueKey('developer_terminal_entry'));
      if (entry.evaluate().isNotEmpty) {
        await tester.ensureVisible(entry);
        await tester.pumpAndSettle();
        await tester.tap(entry);
        await tester.pumpAndSettle();
      }
    }

    Map<String, dynamic> gatePull({bool? devAccess, bool isAdmin = false}) =>
        {
          'isUnlimited': isAdmin,
          'isAdmin': isAdmin,
          'nickname': 'Tyson',
          'tag': '1234',
          'profile': <String, dynamic>{
            'dev_access': ?devAccess,
          },
          'insights': const [],
        };

    testWidgets('settings gate: dev_access → Restore Streak renders',
        (tester) async {
      await pumpSettings(tester, gatePull(devAccess: true));
      expect(find.byKey(const Key('streakRestoreButton')), findsOneWidget);
    });

    testWidgets('settings gate: no dev_access → no Restore Streak',
        (tester) async {
      await pumpSettings(tester, gatePull());
      expect(find.byKey(const Key('streakRestoreButton')), findsNothing);
    });

    testWidgets('settings gate: ADMIN without dev_access → no '
        'Restore Streak', (tester) async {
      await pumpSettings(tester, gatePull(isAdmin: true));
      expect(find.byKey(const Key('streakRestoreButton')), findsNothing);
    });
  });

  // ── A2 copy rendering on the real streak screen ─────────────

  group('A2 — purchase copy rendering (Juno §§1a/1b/1c)', () {
    late _FakePurchaseStore store;

    StreakState screenState() => StreakState(
          seeded: true,
          seededCurrent: 17,
          seededBest: 17,
          countedDays: runEnding('2026-11-17', 17),
          accrualMonth: '2026-11',
          lastEvaluatedDay: '2026-11-17',
        );

    Future<void> pumpScreen(
      WidgetTester tester,
      StreakFreezePurchaseService service, {
      bool reduceMotion = false,
    }) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: reduceMotion
              ? (context, child) => MediaQuery(
                    data: const MediaQueryData(disableAnimations: true),
                    child: child!,
                  )
              : null,
          home: StreakScreen(
            state: screenState(),
            now: DateTime(2026, 11, 18, 12),
            purchaseService: service,
          ),
        ),
      );
      await tester.pump();
    }

    /// Fake-async-safe flush for widget tests: stream deliveries
    /// and verify futures resolve as microtasks, which only run
    /// when the tester pumps (a real Future.delayed here would
    /// deadlock the test body).
    Future<void> flush(WidgetTester tester) async {
      for (var i = 0; i < 6; i++) {
        await tester.pump(Duration.zero);
      }
    }

    setUp(() {
      store = _FakePurchaseStore();
    });

    testWidgets('verified grant: Juno §1a is the ONE confirmation '
        '(no §5b count string, no stacked restored copy), the '
        'freeze icon animates in once and one light haptic lands',
        (tester) async {
      var haptics = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') haptics++;
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final service = StreakFreezePurchaseService(
        store: store,
        verify: ({
          required String productId,
          required String purchaseToken,
          required String orderId,
        }) async =>
            1,
      );
      addTearDown(service.dispose);
      await pumpScreen(tester, service);
      await flush(tester);
      store.emit(const StreakFreezePurchaseUpdate(
        productId: StreakFreezePurchaseService.productId,
        purchaseToken: 'token-1',
        orderId: 'GPA.1234',
        status: 'purchased',
      ));
      await flush(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakPurchaseSuccess')),
        120,
      );
      // §1a exactly once; §5b formatter string nowhere.
      expect(find.byKey(const Key('streakPurchaseSuccess')), findsOneWidget);
      expect(find.text(StreakPurchaseCopy.freezeGranted), findsOneWidget);
      expect(
        find.textContaining("You've got an extra freeze. You now have"),
        findsNothing,
      );
      expect(find.byKey(const Key('streakPurchaseRestored')), findsNothing);
      expect(find.byKey(const Key('streakFreezeGrantIcon')), findsOneWidget);
      // Let the ~350 ms grant animation land: exactly one haptic.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(haptics, 1,
          reason: 'one light haptic tap when the icon lands');
      // The confirmation STAYS (no auto-vanish).
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(StreakPurchaseCopy.freezeGranted), findsOneWidget);
    });

    testWidgets('reduce-motion: the grant icon renders in place, '
        '§1a still shows, one haptic', (tester) async {
      var haptics = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'HapticFeedback.vibrate') haptics++;
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null);
      });
      final service = StreakFreezePurchaseService(
        store: store,
        verify: ({
          required String productId,
          required String purchaseToken,
          required String orderId,
        }) async =>
            1,
      );
      addTearDown(service.dispose);
      await pumpScreen(tester, service, reduceMotion: true);
      await flush(tester);
      store.emit(const StreakFreezePurchaseUpdate(
        productId: StreakFreezePurchaseService.productId,
        purchaseToken: 'token-1',
        orderId: 'GPA.1234',
        status: 'purchased',
      ));
      await flush(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakPurchaseSuccess')),
        120,
      );
      expect(find.text(StreakPurchaseCopy.freezeGranted), findsOneWidget);
      expect(find.byKey(const Key('streakFreezeGrantIcon')), findsOneWidget);
      expect(haptics, 1);
    });

    testWidgets('already-held (409): §1c renders inline on the '
        'purchase card and the buy action is gone', (tester) async {
      final service = StreakFreezePurchaseService(
        store: store,
        verifyDetailed: ({
          required String productId,
          required String purchaseToken,
          required String orderId,
        }) async =>
            (count: null, alreadyHeld: true),
        resolveHeldCount: () async => 1,
      );
      addTearDown(service.dispose);
      await pumpScreen(tester, service);
      await flush(tester);
      store.emit(const StreakFreezePurchaseUpdate(
        productId: StreakFreezePurchaseService.productId,
        purchaseToken: 'token-1',
        orderId: 'GPA.1234',
        status: 'purchased',
      ));
      await flush(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakPurchaseAlreadyHeld')),
        120,
      );
      expect(find.text(StreakPurchaseCopy.alreadyHeld), findsOneWidget);
      expect(find.byKey(const Key('streakBuyButton')), findsNothing);
      expect(find.byKey(const Key('streakPurchasePending')), findsNothing);
      expect(find.byKey(const Key('streakPurchaseFailure')), findsNothing);
    });

    testWidgets('verify-pending: §1b renders and the §5c failure '
        'string does NOT render for the same event', (tester) async {
      final service = StreakFreezePurchaseService(
        store: store,
        verify: ({
          required String productId,
          required String purchaseToken,
          required String orderId,
        }) async =>
            null,
      );
      addTearDown(service.dispose);
      await pumpScreen(tester, service);
      await flush(tester);
      store.emit(const StreakFreezePurchaseUpdate(
        productId: StreakFreezePurchaseService.productId,
        purchaseToken: 'token-1',
        orderId: 'GPA.1234',
        status: 'purchased',
      ));
      await flush(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('streakPurchasePending')),
        120,
      );
      expect(find.text(StreakPurchaseCopy.verifyPending), findsOneWidget);
      expect(find.byKey(const Key('streakPurchaseFailure')), findsNothing);
      expect(
        find.textContaining("Purchase didn't finish"),
        findsNothing,
      );
    });
  });

  // ── Bug 3: Home reads the settled state ──────────────────────

  group('Bug 3 — Home pills read the settled state, not raw '
      'pulled counters', () {
    late Map<String, String> disk;
    late Map<String, String> cacheDisk;

    setUp(() {
      disk = {};
      cacheDisk = {};
      StreakStore.instance.debugReset();
      StreakStore.instance.debugSetStore(
        read: (key) async => disk[key],
        write: (key, value) async {
          disk[key] = value;
        },
        delete: (key) async {
          disk.remove(key);
        },
      );
      HomeDataCache.instance.debugReset();
      HomeDataCache.instance.debugSetStore(
        read: (key) async => cacheDisk[key],
        write: (key, value) async {
          cacheDisk[key] = value;
        },
        delete: (key) async {
          cacheDisk.remove(key);
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(HealthConnectService.channelName),
        (call) async {
          if (call.method == 'isAvailable') return false;
          return null;
        },
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) {
          final args = call.arguments;
          if (call.method == 'read' &&
              args is Map &&
              args['key'] == 'hc_granted_permissions') {
            return Future<String?>.value(null);
          }
          return Completer<String?>().future;
        },
      );
    });

    tearDown(() {
      StreakStore.instance.debugReset();
      HomeDataCache.instance.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(HealthConnectService.channelName),
        null,
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        null,
      );
    });

    testWidgets('after a settlement that breaks the run, Home '
        'pills, the Home cache, and the streak-screen source state '
        'all read the settled 0 — never the pulled 27',
        (tester) async {
      // Relative to the REAL Tabs today so Home's own DateTime.now()
      // settlement runs the founder scenario: a 5-day run ending
      // yesterday, yesterday counted under legacy app-open
      // semantics (stamp = yesterday, no summary completion, the
      // month's grant already consumed) — just-closed
      // revalidation + settlement breaks the run at 0, while the
      // raw profile counters still say 27/68.
      final now = DateTime.now();
      final today = tabsDayStr(now);
      final yesterday = streakDayStr(
        DateTime.parse(today).subtract(const Duration(days: 1)),
      );
      Set<String> runEndingRel(String endDay, int length) {
        final end = DateTime.parse(endDay);
        return {
          for (var i = 0; i < length; i++)
            streakDayStr(end.subtract(Duration(days: i))),
        };
      }

      final run = runEndingRel(yesterday, 5);
      final months = run.map((d) => d.substring(0, 7)).toSet();
      final blob = jsonEncode(
        StreakState(
          seeded: true,
          seededCurrent: 5,
          seededBest: 68,
          countedDays: run,
          consumedSaveMonths: months,
          spoiledMonths: months,
          accrualMonth: yesterday.substring(0, 7),
          lastEvaluatedDay: yesterday,
        ).toJson(),
      );
      final repo = _Bug3Repository(stateJson: blob);

      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            weatherApi: WeatherApiClient(client: _mockWeatherClient()),
            healthRepository: repo,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump();

      // The settled state (the streak screen's source) is broken.
      final settled = StreakStore.instance.state;
      expect(settled, isNotNull);
      expect(streakCurrent(settled!, tabsDayAnchor(DateTime.now())), 0);
      // The Home cache — the pills' durable source — agrees.
      final snap = HomeDataCache.instance.snapshot;
      expect(snap.streakLoaded, isTrue);
      expect(snap.currentStreak, 0);
      expect(snap.bestStreak, 68);
      // And the rendered pills show the settled values.
      expect(find.text('0'), findsOneWidget);
      expect(find.text('27'), findsNothing);

      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
    });
  });
}

class _FakeBackend extends TabsBackend {
  final Map<String, dynamic> pull;
  _FakeBackend({super.sessionStore, required this.pull});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => pull;
}

/// Repository for the Bug 3 Home test: vitals resolve, the raw
/// streak counters say 27/68 (the founder's stale profile), and
/// the full record carries the legacy blob whose settled
/// evaluation breaks the run.
class _Bug3Repository extends HealthRepository {
  final String stateJson;
  _Bug3Repository({required this.stateJson}) : super();

  @override
  Future<TodayVitals> loadTodayVitals({required bool connected}) async =>
      const TodayVitals(
        heartRate: 75,
        activeCalories: 460,
        sleepMinutes: 430,
        logCountToday: 4,
      );

  @override
  Future<({bool succeeded, int? current, int? best})> loadStreak() async =>
      (succeeded: true, current: 27, best: 68);

  @override
  Future<
      ({
        bool succeeded,
        int? current,
        int? best,
        String? stateJson,
        int? purchasedFreezes
      })> loadStreakRecord() async => (
        succeeded: true,
        current: 27,
        best: 68,
        stateJson: stateJson,
        purchasedFreezes: 0,
      );
}

MockClient _mockWeatherClient() {
  return MockClient((request) async {
    final host = request.url.host;
    if (host == 'ipinfo.io') {
      return http.Response(
        '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
        200,
      );
    }
    if (host == 'api.open-meteo.com') {
      return http.Response(
        '{"current":{"temperature_2m":60.0,"weather_code":2,"is_day":1}}',
        200,
      );
    }
    return http.Response('not found', 404);
  });
}

class _FakePurchaseStore implements StreakFreezeStore {
  final StreamController<List<StreakFreezePurchaseUpdate>> _controller =
      StreamController<List<StreakFreezePurchaseUpdate>>.broadcast();
  int completeCalls = 0;
  int restoreCalls = 0;

  void emit(StreakFreezePurchaseUpdate update) => _controller.add([update]);

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<List<StreakFreezePurchaseUpdate>> get purchaseUpdates =>
      _controller.stream;

  @override
  Future<StreakFreezeProduct?> queryProduct(String productId) async =>
      const StreakFreezeProduct(id: 'streak_freeze_099', price: '\$0.99');

  @override
  Future<bool> buyConsumable(StreakFreezeProduct product) async => true;

  @override
  Future<void> completePurchase(StreakFreezePurchaseUpdate update) async {
    completeCalls++;
  }

  @override
  Future<void> restorePurchases() async {
    restoreCalls++;
  }
}
