import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';

/// Report Reliability Phase 2, PR-1 (probe core) — new fixtures:
///
/// 1. The Phase 1 Vera residual, closed: two CONCURRENT loadRange
///    calls sharing ONE service instance whose reads complete
///    interleaved (sleep's outcome is determined first and lands
///    last; HRV's lands first). At base (2f9a709d) attribution
///    rode on the service-global slot fields with a reset/claim
///    drain per union, so one union's drain/reset necessarily
///    stole or wiped the other's signal — this file cannot pass
///    there (the outcome API it exercises does not exist at base;
///    a legacy-API variant of the same concurrent shape was run
///    against the base separately and failed on assertions — see
///    the PR body for both runs). At head each read's outcome
///    object carries its own signals, so attribution holds by
///    construction for any interleaving.
///
/// 2. probeAvailability() via the channel-mock harness
///    (health_connect_test.dart style): the snapshot is data —
///    never a throw, never a persist.

class MemorySecureStore implements SecureStore {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }
}

const _channelName = HealthConnectService.channelName;

HealthConnectService serviceWith({
  required MemorySecureStore store,
  Future<dynamic> Function(MethodCall call)? handler,
}) {
  final channel = MethodChannel(_channelName);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, handler);
  return HealthConnectService(channel: channel, store: store);
}

/// The concurrent-unions service: ONE instance whose outcome
/// reads interleave — sleep's SecurityException outcome is
/// determined up front but lands LAST (30 ms), HRV's generic
/// failure lands FIRST (10 ms), calories is healthy and instant.
/// Only the outcome variants are overridden: the inherited legacy
/// methods delegate to them (Phase 2 §1), exactly as the real
/// service's legacy methods delegate to its cores.
class _ConcurrentHc extends HealthConnectService {
  @override
  Future<HcReadOutcome<List<({String date, int mins, int deep})>>>
      readSleepHistoryWithOutcome(int days) async {
    final outcome = HcReadOutcome<List<({String date, int mins, int deep})>>(
      value: const [],
      errorCode: 'SLEEP_HISTORY_READ_FAILED',
      errorDetails: 'SecurityException',
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    return outcome;
  }

  @override
  Future<HcReadOutcome<List<({int t, double ms, int tier})>>>
      readHrvSamplesWithOutcome(int days) async {
    final outcome = HcReadOutcome<List<({int t, double ms, int tier})>>(
      value: const [],
      errorCode: 'HRV_SAMPLES_READ_FAILED',
      errorDetails: 'IOException',
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return outcome;
  }

  @override
  Future<HcReadOutcome<List<({String date, int kcal})>>>
      readCaloriesHistoryWithOutcome(int days) async =>
          HcReadOutcome(
            value: const [(date: '2026-10-20', kcal: 2100)],
          );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  group('concurrent unions on ONE shared service instance (Vera residual)',
      () {
    late HealthHistoryStore store;

    setUp(() {
      final disk = <String, String>{};
      store = HealthHistoryStore.testInstance();
      store.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      store.debugReset();
    });

    test(
        'interleaved failures attribute ONLY to their own union; '
        'healthy rows survive in both', () async {
      final hc = _ConcurrentHc();
      final queriesA = HealthHistoryQueries(hc: hc, store: store);
      final queriesB = HealthHistoryQueries(hc: hc, store: store);

      // Both unions in flight at once on the shared instance:
      // A runs sleep (lands at 30 ms) + calories; B runs HRV
      // (lands at 10 ms, while A's sleep read is still in
      // flight) + calories.
      final futureA = queriesA.loadRange(
        startDate: '2026-10-19',
        endDate: '2026-10-21',
        metrics: {HistoryMetric.sleep, HistoryMetric.calories},
      );
      final futureB = queriesB.loadRange(
        startDate: '2026-10-19',
        endDate: '2026-10-21',
        metrics: {HistoryMetric.hrv, HistoryMetric.calories},
      );
      final unionA = await futureA;
      final unionB = await futureB;

      // Union A: ONLY its own sleep SecurityException failure.
      expect(unionA.failedMetrics, {HistoryMetric.sleep});
      expect(unionA.failureDetails.keys, {HistoryMetric.sleep});
      expect(unionA.failureDetails[HistoryMetric.sleep],
          contains('SecurityException'));
      expect(unionA.failedWithSecurityException(HistoryMetric.sleep), isTrue);
      expect(unionA.partialMetrics, isEmpty);
      // Its healthy calories rows survive.
      expect(unionA.calories['2026-10-20'], 2100);

      // Union B: ONLY its own HRV generic failure — no trace of
      // A's SecurityException may leak into B.
      expect(unionB.failedMetrics, {HistoryMetric.hrv});
      expect(unionB.failureDetails.keys, {HistoryMetric.hrv});
      expect(unionB.failureDetails[HistoryMetric.hrv],
          contains('IOException'));
      expect(unionB.failedWithSecurityException(HistoryMetric.hrv), isFalse);
      expect(unionB.partialMetrics, isEmpty);
      expect(unionB.calories['2026-10-20'], 2100);
    });
  });

  group('probeAvailability()', () {
    final allGranted = HealthConnectService.requiredPermissions.toList();

    test('full grant + probe ok → connected, no stale, nothing persisted',
        () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return allGranted;
          if (call.method == 'probeReadAccess') return true;
          throw UnimplementedError(call.method);
        },
      );
      final snap = await service.probeAvailability();
      expect(snap.status, HealthConnectStatus.connected);
      expect(snap.serviceAvailable, isTrue);
      expect(snap.grantKnown, isTrue);
      expect(snap.fullGrant, isTrue);
      expect(snap.missingPermissions, isEmpty);
      expect(snap.staleWedged, isFalse);
      expect(snap.stepsProbe, HcReadProbeOutcome.ok);
      expect(snap.bridgeErrorCode, isNull);
      // The probe must NOT persist anything: the persisted flag is
      // a first-paint hint, never written by probing.
      expect(await service.hasPersistedConnection(), isFalse);
    });

    test('full grant + SecurityException probe → staleWedged as data, '
        'no throw', () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return allGranted;
          if (call.method == 'probeReadAccess') {
            throw PlatformException(
              code: 'PROBE_READ_FAILED',
              message: 'Probe read failed.',
              details: 'SecurityException',
            );
          }
          throw UnimplementedError(call.method);
        },
      );
      final snap = await service.probeAvailability();
      expect(snap.staleWedged, isTrue);
      expect(snap.stepsProbe, HcReadProbeOutcome.securityFailure);
      expect(snap.fullGrant, isTrue);
      expect(snap.status, HealthConnectStatus.connected);
      // …while getStatus() keeps its EXACT legacy contract over
      // the probe: stale throws STALE_GRANT and persists nothing.
      await expectLater(
        service.getStatus(),
        throwsA(isA<HealthConnectException>().having(
            (e) => e.code, 'code', HealthConnectService.staleGrantCode)),
      );
      expect(await service.hasPersistedConnection(), isFalse);
    });

    test('partial grant → missing set correct, probe not run', () async {
      final store = MemorySecureStore();
      const sleepPerm = 'android.permission.health.READ_SLEEP';
      const stepsPerm = 'android.permission.health.READ_STEPS';
      final granted =
          allGranted.where((p) => p != sleepPerm && p != stepsPerm).toList();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return granted;
          throw UnimplementedError(call.method);
        },
      );
      final snap = await service.probeAvailability();
      expect(snap.status, HealthConnectStatus.partiallyConnected);
      expect(snap.fullGrant, isFalse);
      expect(snap.missingPermissions, {sleepPerm, stepsPerm});
      expect(snap.stepsProbe, isNull);
      expect(snap.staleWedged, isFalse);
    });

    test('isAvailable false → unavailable', () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return false;
          throw UnimplementedError(call.method);
        },
      );
      final snap = await service.probeAvailability();
      expect(snap.status, HealthConnectStatus.unavailable);
      expect(snap.serviceAvailable, isFalse);
      expect(snap.staleWedged, isFalse);
    });

    test('bridge throw → status null + bridgeErrorCode set, no throw',
        () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async =>
            throw PlatformException(code: 'BRIDGE_DOWN', message: 'down'),
      );
      final snap = await service.probeAvailability();
      expect(snap.status, isNull);
      expect(snap.grantKnown, isFalse);
      expect(snap.grantedPermissions, isNull);
      expect(snap.bridgeErrorCode, 'BRIDGE_DOWN');
      expect(snap.staleWedged, isFalse);
    });

    test('persisted flag rides as a hint and never overrides a known '
        'state', () async {
      final store = MemorySecureStore();
      await store.write(
          'hc_granted_permissions',
          HealthConnectService.requiredPermissions.join(','));
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          // Live truth: NOTHING is granted any more.
          if (call.method == 'getGrantedPermissions') return <String>[];
          throw UnimplementedError(call.method);
        },
      );
      final snap = await service.probeAvailability();
      expect(snap.persistedConnected, isTrue);
      // The known live state (notConnected) governs — the
      // persisted hint does not override it.
      expect(snap.status, HealthConnectStatus.notConnected);
    });
  });

  group('outcome-carrying reads (channel core)', () {
    test('partial sleep read: outcome carries the partial, value keeps '
        'its rows, legacy slot still written as a diagnostic', () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'readSleepHistory') {
            return {
              'items': [
                {
                  'date': '2026-10-17',
                  'startMs': DateTime(2026, 10, 17, 1, 0)
                      .millisecondsSinceEpoch,
                  'endMs':
                      DateTime(2026, 10, 17, 8, 0).millisecondsSinceEpoch,
                  'awake': <List<int>>[],
                  'deep': <List<int>>[],
                },
              ],
              'partialError': 'IOException',
            };
          }
          throw UnimplementedError(call.method);
        },
      );
      final outcome = await service.readSleepHistoryWithOutcome(30);
      expect(outcome.failed, isFalse);
      expect(outcome.partial, isTrue);
      expect(outcome.partialCode, 'SLEEP_HISTORY_PARTIAL');
      expect(outcome.value, hasLength(1));
      expect(outcome.value.single.mins, 420);
      // The legacy diagnostic side channel is still written by
      // the core implementation (capture's PR-3 migration reads
      // it until then) — but the outcome above needed no slot.
      expect(service.lastPartialErrorCode, 'SLEEP_HISTORY_PARTIAL');
      expect(service.lastReadErrorCode, isNull);
    });

    test('failed resting HR read: outcome carries code + SecurityException '
        'detail; the legacy method returns the identical fail-closed value',
        () async {
      final store = MemorySecureStore();
      final service = serviceWith(
        store: store,
        handler: (call) async => throw PlatformException(
          code: 'RHR_HISTORY_READ_FAILED',
          message: 'Could not read resting heart rate history.',
          details: 'SecurityException',
        ),
      );
      final outcome = await service.readRestingHrHistoryWithOutcome(30);
      expect(outcome.failed, isTrue);
      expect(outcome.errorCode, 'RHR_HISTORY_READ_FAILED');
      expect(outcome.failedWithSecurityException, isTrue);
      expect(outcome.value, isEmpty);
      expect(await service.readRestingHrHistory(30), isEmpty);
      expect(service.lastReadErrorCode, 'RHR_HISTORY_READ_FAILED');
    });
  });
}
