import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';

/// HC read hardening (founder defect #3) — regression tests:
/// - the Heart screen bounds its HR read: a wedged channel surfaces
///   a visible READ_TIMEOUT, never a permanent spinner (the bound
///   lives at the caller per the codebase's guard pattern — a
///   service-owned timer on every call fails this suite's widget
///   teardown wherever a fake/unmocked future legitimately pends);
/// - native exception class + message travel through the channel
///   error details into [HealthConnectService.lastReadErrorDetails];
/// - chunked reads return partial data + the partial error;
/// - a failed load never stamps HeartDataCache.lastSyncAt
///   ("Synced just now" over dead reads) and never wipes a cached
///   series;
/// - the grant-state probe: grants OK + probe SecurityException =
///   STALE_GRANT with plain recovery wording, and the connection is
///   NOT persisted;
/// - the Heart screen's persisted-connection fallback is
///   provisional: a failing read surfaces its error even over
///   cached data.

class MemorySecureStore implements SecureStore {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
  @override
  Future<void> delete(String key) async => _map.remove(key);
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

String todayStr() {
  final d = DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

int todayMs(int hour) {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day, hour).millisecondsSinceEpoch;
}

/// Fake service whose HR read NEVER returns — the defect #3 wedge.
class WedgedFakeHc extends HealthConnectService {
  @override
  Future<bool> isConnected() async => true;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) =>
      Completer<List<HrSample>>().future;
}

/// Fake service for the Heart screen provisional-fallback test: the
/// live check throws, persisted state says connected, and the read
/// fails with a recorded bridge error.
class ProvisionalFakeHc extends HealthConnectService {
  @override
  Future<bool> isConnected() async =>
      throw const HealthConnectException('GRANTED_CHECK_FAILED', 'boom');

  @override
  Future<bool> hasPersistedConnection() async => true;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    lastReadErrorCode = 'HR_SAMPLES_READ_FAILED';
    lastReadErrorDetails = 'IllegalStateException: service wedged';
    return const [];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  group('exception details pass through (instrument, don\'t swallow)', () {
    test('HR read: code stays stable, details carry the exception', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async => throw PlatformException(
          code: 'HR_SAMPLES_READ_FAILED',
          message: 'Could not read heart rate samples.',
          details: 'SecurityException: READ_HEART_RATE not granted',
        ),
      );
      final out = await service.readHeartRateSamples('2026-10-18');
      expect(out, isEmpty);
      expect(service.lastReadErrorCode, 'HR_SAMPLES_READ_FAILED');
      expect(service.lastReadErrorDetails,
          contains('SecurityException'));
    });

    test('sleep stages: PlatformException is recorded, not swallowed',
        () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async => throw PlatformException(
          code: 'SLEEP_STAGES_READ_FAILED',
          message: 'Could not read sleep stages.',
          details: 'IllegalStateException: service not bound',
        ),
      );
      final out = await service.readSleepStages('2026-10-18');
      expect(out, isNull);
      expect(service.lastReadErrorCode, 'SLEEP_STAGES_READ_FAILED');
      expect(service.lastReadErrorDetails,
          contains('IllegalStateException'));
    });
  });

  group('chunk partial failure', () {
    test('HR: partial map returns samples + HR_SAMPLES_PARTIAL', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async => {
          'samples': [
            {'t': todayMs(8), 'bpm': 72},
          ],
          'partialError': 'IllegalStateException: chunk 2 failed',
        },
      );
      final out = await service.readHeartRateSamples(todayStr());
      expect(out, hasLength(1));
      expect(out.single.bpm, 72);
      expect(service.lastReadErrorCode, 'HR_SAMPLES_PARTIAL');
      expect(service.lastReadErrorDetails, contains('IllegalStateException'));
    });

    test('sleep history: partial map returns days + SLEEP_HISTORY_PARTIAL',
        () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async => {
          'items': [
            {'date': '2026-10-17', 'mins': 420, 'deep': 60},
          ],
          'partialError': 'IOException: chunk failed',
        },
      );
      final out = await service.readSleepHistory(30);
      expect(out, hasLength(1));
      expect(out.single.mins, 420);
      expect(service.lastReadErrorCode, 'SLEEP_HISTORY_PARTIAL');
    });

    test('HR: bare list (all chunks OK) leaves no error recorded', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async => [
          {'t': todayMs(8), 'bpm': 72},
        ],
      );
      final out = await service.readHeartRateSamples(todayStr());
      expect(out, hasLength(1));
      expect(service.lastReadErrorCode, isNull);
    });
  });

  group('grant-state probe', () {
    test('probe: SecurityException details → securityFailure', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async => throw PlatformException(
          code: 'PROBE_READ_FAILED',
          message: 'Probe read failed.',
          details: 'SecurityException: permission revoked',
        ),
      );
      expect(await service.probeReadAccess(),
          HcReadProbeOutcome.securityFailure);
    });

    test('probe: other failure → failed (never a stale verdict)', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async => throw PlatformException(
          code: 'PROBE_READ_FAILED',
          message: 'Probe read failed.',
          details: 'IOException: disk error',
        ),
      );
      expect(await service.probeReadAccess(), HcReadProbeOutcome.failed);
    });

    test('requestPermissions: full grant + probe SecurityException → '
        'STALE_GRANT, connection NOT persisted', () async {
      final store = MemorySecureStore();
      final granted = HealthConnectService.requiredPermissions.toList();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'requestPermissions') return granted;
          if (call.method == 'probeReadAccess') {
            throw PlatformException(
              code: 'PROBE_READ_FAILED',
              message: 'Probe read failed.',
              details: 'SecurityException: stale grant',
            );
          }
          return null;
        },
      );
      await expectLater(
        service.requestPermissions(),
        throwsA(isA<HealthConnectException>()
            .having((e) => e.code, 'code', HealthConnectService.staleGrantCode)
            .having((e) => e.message, 'message',
                contains('remove Tabs from the allowed apps'))),
      );
      // A blocked grant must never be stored as a healthy connection.
      expect(await store.read('hc_granted_permissions'), isNull);
      expect(await service.hasPersistedConnection(), isFalse);
    });

    test('requestPermissions: full grant + probe OK → granted + persisted',
        () async {
      final store = MemorySecureStore();
      final granted = HealthConnectService.requiredPermissions.toList();
      final service = serviceWith(
        store: store,
        handler: (call) async {
          if (call.method == 'requestPermissions') return granted;
          if (call.method == 'probeReadAccess') return true;
          return null;
        },
      );
      final result = await service.requestPermissions();
      expect(result, containsAll(HealthConnectService.requiredPermissions));
      expect(await service.hasPersistedConnection(), isTrue);
    });
  });

  group('HeartDataCache sync honesty', () {
    setUp(() {
      HeartDataCache.instance.debugReset();
      final store = <String, String>{};
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
    });

    test('failed apply on a fresh cache does NOT stamp lastSyncAt', () {
      HeartDataCache.instance.apply('2026-10-18', const [],
          ownerEmail: 'a@b.c', succeeded: false);
      expect(HeartDataCache.instance.lastSyncAt, isNull);
    });

    test('failed apply keeps the prior series and the prior sync time',
        () {
      final t0 = DateTime(2026, 10, 18, 9);
      HeartDataCache.instance.apply(
          '2026-10-18', [HrSample(timeMs: todayMs(8), bpm: 80)],
          now: t0, ownerEmail: 'a@b.c');
      expect(HeartDataCache.instance.lastSyncAt, t0);
      final data = HeartDataCache.instance.apply('2026-10-18', const [],
          now: DateTime(2026, 10, 18, 10),
          ownerEmail: 'a@b.c',
          succeeded: false);
      expect(HeartDataCache.instance.lastSyncAt, t0);
      expect(data.samples, hasLength(1));
      expect(
          HeartDataCache.instance.snapshot('2026-10-18')?.samples,
          hasLength(1));
    });

    test('successful apply stamps lastSyncAt (unchanged behavior)', () {
      final t0 = DateTime(2026, 10, 18, 9);
      HeartDataCache.instance.apply(
          '2026-10-18', [HrSample(timeMs: todayMs(8), bpm: 80)],
          now: t0, ownerEmail: 'a@b.c');
      expect(HeartDataCache.instance.lastSyncAt, t0);
    });
  });

  group('Heart screen hardening', () {
    testWidgets(
        'wedged HR read → READ_TIMEOUT surfaces, spinner does not '
        'wedge forever, no sync stamped', (tester) async {
      HeartDataCache.instance.debugReset();
      final store = <String, String>{};
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
      await tester.pumpWidget(MaterialApp(
        home: HeartScreen(
          email: 'a@b.c',
          healthConnectService: WedgedFakeHc(),
          cache: HeartDataCache.instance,
        ),
      ));
      await tester.pump();
      // The read never returns; elapse past the 30s bound.
      await tester.pump(const Duration(seconds: 31));
      await tester.pumpAndSettle();
      expect(find.textContaining('[READ_TIMEOUT]'), findsOneWidget);
      expect(find.text('Updating sync data...'), findsNothing);
      expect(HeartDataCache.instance.lastSyncAt, isNull);
    });

    setUp(() {
      HeartDataCache.instance.debugReset();
      final store = <String, String>{};
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
    });

    testWidgets(
        'live check throws → persisted fallback paints, but the failing '
        'read error surfaces over cached data and no sync is stamped',
        (tester) async {
      // Pre-seed the cache with a successful earlier load for today.
      final seededAt = DateTime.now().subtract(const Duration(hours: 2));
      HeartDataCache.instance.apply(
        todayStr(),
        [HrSample(timeMs: todayMs(8), bpm: 80)],
        now: seededAt,
        ownerEmail: 'a@b.c',
      );
      await tester.pumpWidget(MaterialApp(
        home: HeartScreen(
          email: 'a@b.c',
          healthConnectService: ProvisionalFakeHc(),
          cache: HeartDataCache.instance,
        ),
      ));
      await tester.pumpAndSettle();
      // The error is visible even though cached data is on screen.
      expect(
        find.textContaining('[HR_SAMPLES_READ_FAILED]'),
        findsOneWidget,
      );
      expect(
        find.textContaining('IllegalStateException'),
        findsOneWidget,
      );
      // And the failed load did not re-stamp the sync time.
      expect(HeartDataCache.instance.lastSyncAt, seededAt);
    });
  });
}
