import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/data/badge_store.dart';
import 'package:tabs_lab/src/data/gem_service.dart';

/// BadgeService pins (BADGES package): retroactive backfill,
/// idempotent re-evaluation, the offline grant queue + retry,
/// alreadyGranted = paid, monotonic grants, and the day gate.
void main() {
  final now = DateTime(2026, 11, 20, 12);

  BadgeService makeService({
    required Future<GemRequestResult> Function(String key) grant,
    Map<String, String>? disk,
  }) {
    final store = disk ?? <String, String>{};
    final svc = BadgeService(grant: grant);
    svc.debugSetStore(
      read: (k) async => store[k],
      write: (k, v) async => store[k] = v,
      delete: (k) async => store.remove(k),
    );
    return svc;
  }

  GemRequestResult ok({bool already = false, int balance = 100}) => (
        statusCode: 200,
        body: {'gemBalance': balance, 'alreadyGranted': already},
      );

  /// [count] logs, one per day at noon — isolates total_logs
  /// (logs_in_day stays 1, morning_logger stays 0).
  BadgeInputs logsOnly(int count) => BadgeInputs(
        logTimestampsMs: [
          for (var i = 0; i < count; i++)
            DateTime(2025, 1, 1, 12)
                .add(Duration(days: i))
                .millisecondsSinceEpoch,
        ],
      );

  test('backfill: first run grants from full history and pays', () async {
    final grantedKeys = <String>[];
    final svc = makeService(grant: (key) async {
      grantedKeys.add(key);
      return ok();
    });
    // 30 logs all time → total_logs rungs 0,1,2 (5/15/30).
    final batch = await svc.evaluate(
      inputs: logsOnly(30),
      blockedMetrics: const {},
      now: now,
    );
    expect(batch, isNotNull);
    expect(batch!.isBackfill, isTrue);
    expect(batch.grants.length, 3);
    expect(batch.grants.every((g) => g.paid), isTrue);
    expect(grantedKeys, [
      'badge:total_logs:bronze_3',
      'badge:total_logs:bronze_2',
      'badge:total_logs:bronze_1',
    ]);
    expect(svc.snapshot.earnedBadgeCount, 1);
    expect(svc.snapshot.topRungOf('total_logs'), 2);
    expect(svc.topBadge?.rungIndex, 2);
  });

  test('idempotent re-evaluation: same inputs grant nothing twice',
      () async {
    var calls = 0;
    final svc = makeService(grant: (key) async {
      calls++;
      return ok();
    });
    final first = await svc.evaluate(
      inputs: logsOnly(30),
      blockedMetrics: const {},
      now: now,
    );
    expect(first?.grants.length, 3);
    expect(calls, 3);
    // Force past the day gate: still nothing new, no new calls.
    final second = await svc.evaluate(
      inputs: logsOnly(30),
      blockedMetrics: const {},
      now: now,
      force: true,
    );
    expect(second, isNull);
    expect(calls, 3);
  });

  test('day gate: same-day re-evaluation without force is a no-op',
      () async {
    final svc = makeService(grant: (key) async => ok());
    await svc.evaluate(
      inputs: logsOnly(30),
      blockedMetrics: const {},
      now: now,
    );
    expect(await svc.needsEvaluation(now), isFalse);
    expect(await svc.needsEvaluation(DateTime(2026, 11, 21, 12)), isTrue);
    // More logs the same day do not evaluate without force.
    final batch = await svc.evaluate(
      inputs: logsOnly(500),
      blockedMetrics: const {},
      now: now,
    );
    expect(batch, isNull);
    expect(svc.snapshot.topRungOf('total_logs'), 2);
  });

  test('offline grant queues, retries at next settlement, pays once',
      () async {
    var online = false;
    final calls = <String>[];
    final svc = makeService(grant: (key) async {
      calls.add(key);
      if (!online) throw Exception('offline');
      return ok();
    });
    final batch = await svc.evaluate(
      inputs: logsOnly(5), // total_logs rung 0 only
      blockedMetrics: const {},
      now: now,
    );
    expect(batch, isNotNull);
    expect(batch!.grants.single.paid, isFalse); // pending, honestly
    expect(svc.debugPending, ['badge:total_logs:bronze_3']);
    expect(svc.debugPaid, isEmpty);
    // The rung itself is granted (badges never wait on the
    // network); only the payout is pending.
    expect(svc.snapshot.topRungOf('total_logs'), 0);

    online = true;
    await svc.retryPending();
    expect(svc.debugPending, isEmpty);
    expect(svc.debugPaid, {'badge:total_logs:bronze_3'});
    // Exactly two attempts total for the key: the failed one and
    // the retry — and no third after payment.
    expect(calls.length, 2);
    await svc.retryPending();
    expect(calls.length, 2);
  });

  test('alreadyGranted counts as paid (no double-pay on reinstall)',
      () async {
    final svc = makeService(grant: (key) async => ok(already: true));
    final batch = await svc.evaluate(
      inputs: logsOnly(5),
      blockedMetrics: const {},
      now: now,
    );
    expect(batch!.grants.single.paid, isTrue);
    expect(svc.debugPaid, {'badge:total_logs:bronze_3'});
    // Vera C2: ledger-confirmed, but NOT a fresh payout — the
    // unlock dialog must not present it as one.
    expect(batch.grants.single.paidFresh, isFalse);
    expect(batch.freshPaidCount, 0);
    expect(batch.anyPending, isFalse);
  });

  test('a fresh grant is paidFresh (dialog may show +5)', () async {
    final svc = makeService(grant: (key) async => ok());
    final batch = await svc.evaluate(
      inputs: logsOnly(5),
      blockedMetrics: const {},
      now: now,
    );
    expect(batch!.grants.single.paid, isTrue);
    expect(batch.grants.single.paidFresh, isTrue);
    expect(batch.freshPaidCount, 1);
  });

  test('a non-200 grant stays queued for the next settlement', () async {
    var attempts = 0;
    final svc = makeService(grant: (key) async {
      attempts++;
      if (attempts == 1) {
        return (statusCode: 409, body: {'error': 'grant_not_ready'});
      }
      return ok();
    });
    final batch = await svc.evaluate(
      inputs: logsOnly(5),
      blockedMetrics: const {},
      now: now,
    );
    expect(batch!.grants.single.paid, isFalse);
    await svc.retryPending();
    expect(svc.debugPaid, {'badge:total_logs:bronze_3'});
  });

  test('grants are monotonic: a later smaller value drops nothing',
      () async {
    final svc = makeService(grant: (key) async => ok());
    await svc.evaluate(
      inputs: logsOnly(30),
      blockedMetrics: const {},
      now: now,
    );
    final batch = await svc.evaluate(
      inputs: logsOnly(3), // e.g. a partial pull — never a drop
      blockedMetrics: const {},
      now: DateTime(2026, 11, 21, 12),
      force: true,
    );
    expect(batch, isNull);
    expect(svc.snapshot.topRungOf('total_logs'), 2);
  });

  test('unknown sources grant nothing and keep prior values', () async {
    final svc = makeService(grant: (key) async => ok());
    await svc.evaluate(
      inputs: logsOnly(30),
      blockedMetrics: const {},
      now: now,
    );
    final batch = await svc.evaluate(
      inputs: const BadgeInputs(), // every source unknown
      blockedMetrics: const {},
      now: DateTime(2026, 11, 21, 12),
      force: true,
    );
    expect(batch, isNull);
    expect(svc.snapshot.values['total_logs'], 30);
    expect(svc.snapshot.topRungOf('total_logs'), 2);
  });

  test('state persists across service instances on the same disk',
      () async {
    final disk = <String, String>{};
    final first = makeService(grant: (key) async => ok(), disk: disk);
    await first.evaluate(
      inputs: logsOnly(30),
      blockedMetrics: const {},
      now: now,
    );
    var calls = 0;
    final second = makeService(
      grant: (key) async {
        calls++;
        return ok();
      },
      disk: disk,
    );
    final batch = await second.evaluate(
      inputs: logsOnly(30),
      blockedMetrics: const {},
      now: DateTime(2026, 11, 21, 12),
      force: true,
    );
    expect(batch, isNull); // nothing re-granted
    expect(calls, 0); // nothing re-requested
    expect(second.snapshot.topRungOf('total_logs'), 2);
  });

  test('blocked metrics ride the snapshot for the Juno §9 states',
      () async {
    final svc = makeService(grant: (key) async => ok());
    await svc.evaluate(
      inputs: const BadgeInputs(logTimestampsMs: []),
      blockedMetrics: {'steps_day', 'calories_month', 'active_week'},
      now: now,
    );
    expect(
      svc.snapshot.blockedMetrics,
      {'steps_day', 'calories_month', 'active_week'},
    );
    // A later unblocked evaluation refreshes the display state.
    await svc.evaluate(
      inputs: const BadgeInputs(logTimestampsMs: []),
      blockedMetrics: const {},
      now: DateTime(2026, 11, 21, 12),
      force: true,
    );
    expect(svc.snapshot.blockedMetrics, isEmpty);
  });
}
