import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/data/badge_store.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';

/// Load-failure pins for the gems/badges grant path (FIX package,
/// Nov 20, 2026).
///
/// Production evidence: gem_ledger held 0 rows for every user while
/// the server endpoint was proven good by an authenticated smoke —
/// the shipped app never sent a grant. Both services share the
/// house ensureLoaded pattern: a secure-storage READ that throws
/// leaves `_loaded` false, and every entry point then returns
/// silently (no grant, no log, no surface). A per-key storage
/// failure (a wedged flutter_secure_storage entry) therefore
/// disabled the entire grant path forever, invisibly.
///
/// These tests fault-inject the storage layer and pin the fixed
/// behaviour:
/// - a transient read failure is absorbed and grants still fire;
/// - a persistent read failure is recorded and recovered from
///   (the wedged entry is cleared and the service starts clean —
///   server idempotency + history re-derivation are the backstop,
///   the same reasoning as the corrupt-blob path), so grants fire
///   from the same app open's later entry points onward.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 11, 20, 12);

  GemRequestResult ok({int balance = 5}) => (
        statusCode: 200,
        body: {'gemBalance': balance, 'alreadyGranted': false},
      );

  StreakState settledState() => StreakState(
        seeded: true,
        countedDays: {'2026-11-20'},
        summaryCompletedDays: {'2026-11-20'},
      );

  group('GemService storage load failure', () {
    GemService buildService({
      required List<String> grantCalls,
      required Future<String?> Function(String) read,
    }) {
      final s = GemService(
        grant: (key) async {
          grantCalls.add(key);
          return ok();
        },
        spend: (id) async => (statusCode: 200, body: null),
        pullBalance: () async => 0,
      );
      s.debugSetStore(
        read: read,
        write: (k, v) async {},
        delete: (k) async {},
      );
      return s;
    }

    test('persistent read failure: a completion still grants '
        '(recovery, not a silent no-op)', () async {
      final grantCalls = <String>[];
      final gems = buildService(
        grantCalls: grantCalls,
        read: (k) async => throw StateError('storage wedged'),
      );
      // Home-shaped sequence: the app-open sync runs first, then
      // the day's completion lands.
      await gems.onAppOpen(state: settledState(), now: now);
      final result = await gems.processCompletion(
        summaryTabsDay: '2026-11-20',
        previousStreak: 0,
        newStreak: 1,
        settledState: settledState(),
        now: now,
      );
      expect(grantCalls, contains('daily:2026-11-20'));
      expect(result.lines, contains(GemCopy.dailyEarnLine));
    });

    test('transient read failure (throws once, then reads): the '
        'same completion still grants', () async {
      final grantCalls = <String>[];
      var attempts = 0;
      final gems = buildService(
        grantCalls: grantCalls,
        read: (k) async {
          attempts++;
          if (attempts == 1) throw StateError('transient');
          return null;
        },
      );
      final result = await gems.processCompletion(
        summaryTabsDay: '2026-11-20',
        previousStreak: 0,
        newStreak: 1,
        settledState: settledState(),
        now: now,
      );
      expect(grantCalls, contains('daily:2026-11-20'));
      expect(result.lines, contains(GemCopy.dailyEarnLine));
    });
  });

  group('BadgeService storage load failure', () {
    BadgeInputs logsOnly(int count) => BadgeInputs(
          logTimestampsMs: [
            for (var i = 0; i < count; i++)
              DateTime(2025, 1, 1, 12)
                  .add(Duration(days: i))
                  .millisecondsSinceEpoch,
          ],
        );

    test('persistent read failure: the backfill evaluation still '
        'grants (recovery, not a silent no-op)', () async {
      final grantCalls = <String>[];
      final svc = BadgeService(
        grant: (key) async {
          grantCalls.add(key);
          return ok(balance: 100);
        },
      );
      svc.debugSetStore(
        read: (k) async => throw StateError('storage wedged'),
        write: (k, v) async {},
        delete: (k) async {},
      );
      // Home-shaped sequence: the day-gate probe and the pending
      // retry run before any evaluation.
      await svc.needsEvaluation(now);
      await svc.retryPending();
      // After recovery the day gate must read as "evaluation due"
      // again, and the backfill must queue + flush its grants.
      expect(await svc.needsEvaluation(now), isTrue);
      final batch = await svc.evaluate(
        inputs: logsOnly(30),
        blockedMetrics: const {},
        now: now,
      );
      expect(batch, isNotNull);
      expect(grantCalls, [
        'badge:total_logs:bronze_3',
        'badge:total_logs:bronze_2',
        'badge:total_logs:bronze_1',
      ]);
    });

    test('transient read failure (throws once, then reads): the '
        'same evaluation still grants', () async {
      final grantCalls = <String>[];
      var attempts = 0;
      final svc = BadgeService(
        grant: (key) async {
          grantCalls.add(key);
          return ok(balance: 100);
        },
      );
      svc.debugSetStore(
        read: (k) async {
          attempts++;
          if (attempts == 1) throw StateError('transient');
          return null;
        },
        write: (k, v) async {},
        delete: (k) async {},
      );
      final batch = await svc.evaluate(
        inputs: logsOnly(30),
        blockedMetrics: const {},
        now: now,
      );
      expect(batch, isNotNull);
      expect(grantCalls, hasLength(3));
    });
  });
}
