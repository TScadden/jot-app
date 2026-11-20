import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/data/badge_store.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

/// BadgeService pins (BADGES package): retroactive backfill,
/// idempotent re-evaluation, the offline grant queue + retry,
/// alreadyGranted = paid, monotonic grants, and the day gate.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  group('loader: Juno B-ruling fixtures (exercise is badges-scoped)',
      () {
    const exercisePermission = 'android.permission.health.READ_EXERCISE';
    const channel = MethodChannel('badges_fixture_hc');

    TabsBackend deadBackend() => TabsBackend(
          client: MockClient((_) async => http.Response('x', 500)),
        );

    Future<({BadgeInputs inputs, Set<String> blockedMetrics})> loadWith(
      Set<String> liveGranted, {
      List<Object?> exerciseRows = const [],
    }) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        switch (call.method) {
          case 'isAvailable':
            return true;
          case 'getGrantedPermissions':
            return liveGranted.toList();
          case 'probeReadAccess':
            return true;
          case 'readStepsHistory':
            return [
              {'date': '2026-11-16', 'count': 9000},
            ];
          case 'readTotalCaloriesHistory':
            return [
              {'date': '2026-11-16', 'kcal': 2500},
            ];
          case 'readSleepHistory':
            return <Object?>[];
          case 'readExerciseSessions':
            return exerciseRows;
          default:
            return null;
        }
      });
      addTearDown(() =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null));
      return loadBadgeInputs(
        backend: deadBackend(),
        hc: HealthConnectService(channel: channel),
        streakState: null,
      );
    }

    test('condition 2: READ_EXERCISE is not in the required set', () {
      expect(
        HealthConnectService.requiredPermissions,
        isNot(contains(exercisePermission)),
      );
      // Juno said the Exercise label "may stay", but the pinned
      // label test (hrv_grant_visibility_test) requires the label
      // map's keys to equal the required set exactly, and her
      // condition 5 requires that test to pass UNMODIFIED — so
      // the label goes too. It was dead weight under B anyway:
      // Exercise can never be a missing required permission.
      expect(
        HealthConnectService.permissionLabels,
        isNot(contains(exercisePermission)),
      );
    });

    test('(i) main set granted + Exercise granted via settings: '
        'Active week computes', () async {
      final start = DateTime(2026, 11, 16, 7);
      final result = await loadWith(
        {...HealthConnectService.requiredPermissions, exercisePermission},
        exerciseRows: [
          {
            'startMs': start.millisecondsSinceEpoch,
            'endMs': start
                .add(const Duration(minutes: 90))
                .millisecondsSinceEpoch,
          },
        ],
      );
      expect(result.blockedMetrics, isEmpty);
      expect(result.inputs.exerciseSessions, hasLength(1));
      expect(computeBadgeValues(result.inputs)['active_week'], 90);
    });

    test('(ii) main set granted, Exercise absent: Active week is '
        'blocked, nothing else is', () async {
      final result = await loadWith(
        {...HealthConnectService.requiredPermissions},
      );
      expect(result.blockedMetrics, {BadgeMetrics.activeWeek.id});
      expect(result.inputs.exerciseSessions, isNull);
      expect(result.inputs.dailySteps, isNotNull);
      expect(result.inputs.dailyTotalCalories, isNotNull);
    });
  });
}
