import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_sync.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'settings_r30_google_test.dart' as r30g;
import 'settings_r51_connstate_test.dart' as r51;
import 'test_helpers.dart';

/// HRV capture invisibility fix — regression tests:
///
/// Defect 0 (structural): the Kotlin HRV range read wrapped its
/// whole chunk loop in one try/catch, so one failing chunk zeroed
/// the read. It now mirrors readSleepHistory: per-chunk isolation,
/// surviving samples returned with a partialError (sleep map
/// shape), total failure still errors. Dart side pinned here:
/// the partial shape parses, HRV_SAMPLES_PARTIAL is recorded as a
/// partial (never a failure), and the samples survive.
///
/// Defect 1 + 1b: `HealthHistorySync.captureFromHealthConnect`
/// never looked at `lastReadErrorCode`, so a failed HRV read was
/// swallowed completely and the capture still stamped success.
/// The capture now snapshots the code around every read —
/// mirroring health_history_queries — and persists per-metric
/// diagnostics on the store. For the HRV leg the entry is written
/// every capture and carries the OUTCOME numbers (error/partial
/// code, raw sample count, attributed day count); other metrics'
/// failure entries clear on their next successful read.
///
/// Defect 2: `getStatus()` reported `partiallyConnected` without
/// naming WHICH data type was missing. The service now exposes
/// the missing-permission set + plain-language labels, both
/// partial-grant surfaces (Settings → Connected Apps and the Data
/// Connections screen) render the naming copy with the exact
/// remedy, and the Connected Apps card carries the HRV
/// diagnostics line (Defect 1b's screenshot surface).

/// In-memory [SecureStore] for the channel-mocked service.
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

/// Fake capture source: every window empty; the HRV read fails
/// with the real bridge code while [failHrv] is set (the service's
/// fail-closed shape: [] + lastReadErrorCode), comes back partial
/// while [partialHrv] is set ([] kept samples + partial code),
/// and otherwise succeeds with one sample.
class _CaptureFakeHc extends HealthConnectService {
  bool failHrv = true;
  bool partialHrv = false;
  bool failSleep = false;

  static final _sample = (
    t: DateTime(2026, 10, 19, 2).millisecondsSinceEpoch,
    ms: 55.0,
    tier: 100,
  );

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
      int days) async => const [];

  @override
  Future<List<({String date, int kcal})>> readCaloriesHistory(
      int days) async => const [];

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    if (failSleep) {
      lastReadErrorCode = 'SLEEP_HISTORY_READ_FAILED';
      return const [];
    }
    return const [];
  }

  @override
  Future<List<({String date, int count})>> readSpikeCounts(
      int days) async => const [];

  @override
  Future<List<({int t, double ms, int tier})>> readHrvSamples(
      int days) async {
    if (failHrv) {
      lastReadErrorCode = 'HRV_SAMPLES_READ_FAILED';
      return const [];
    }
    if (partialHrv) {
      lastPartialErrorCode = 'HRV_SAMPLES_PARTIAL';
      lastReadErrorDetails = 'SecurityException';
      return [_sample];
    }
    return [_sample];
  }
}

/// Settings Connected Apps fake: canned status + canned missing
/// labels (extends the Round 51 fake so the shared pump plumbing
/// accepts it).
class _SettingsFakeHc extends r51.FakeHCService {
  _SettingsFakeHc(this.missingLabels)
      : super(HealthConnectStatus.partiallyConnected);

  final List<String> missingLabels;

  @override
  Future<List<String>> getMissingPermissionLabels() async => missingLabels;
}

/// Settings pump with an injectable history store (the Round 51
/// pump does not take one; the diagnostics line needs it).
Future<void> pumpSettingsWithHistory(
  WidgetTester tester, {
  required HealthHistoryStore historyStore,
  required r51.FakeHCService hc,
}) async {
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final backend = r30g.LinkBackend()..pullBody = r29.pull();
  final map = <String, String>{};
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SettingsScreen(
        backend: backend,
        settingsStore: SettingsStore.withStorage(
          read: (k) async => map[k],
          write: (k, v) async => map[k] = v,
          delete: (k) async => map.remove(k),
        ),
        notificationService: FakeReminderNotificationService(),
        googleSignInService: r30g.FakeGoogle(),
        healthConnectService: hc,
        historyStore: historyStore,
        urlLauncher: (uri) async => true,
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

HealthHistoryStore diagStore(Map<String, String> disk) {
  final store = HealthHistoryStore.testInstance();
  store.debugSetStore(
    read: (k) async => disk[k],
    write: (k, v) async => disk[k] = v,
    delete: (k) async => disk.remove(k),
  );
  return store;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  group('Defect 0 — HRV bridge partial contract (Dart side)', () {
    test('partial map: samples survive, HRV_SAMPLES_PARTIAL recorded, '
        'failure code stays null', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async => {
          'items': [
            {'t': 1000, 'ms': 55.0, 'tier': 100},
            {'t': 2000, 'ms': 65.0, 'tier': 100},
          ],
          'partialError': 'SecurityException',
        },
      );
      final out = await service.readHrvSamples(90);
      expect(out, hasLength(2));
      expect(out.first.ms, 55.0);
      expect(service.lastPartialErrorCode, 'HRV_SAMPLES_PARTIAL');
      expect(service.lastReadErrorCode, isNull);
      expect(service.lastReadErrorDetails, contains('SecurityException'));
    });

    test('bare list (all chunks OK) leaves no error recorded', () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async => [
          {'t': 1000, 'ms': 55.0, 'tier': 100},
        ],
      );
      final out = await service.readHrvSamples(31);
      expect(out, hasLength(1));
      expect(service.lastReadErrorCode, isNull);
      expect(service.lastPartialErrorCode, isNull);
    });

    test('total failure still errors closed: [] + HRV_SAMPLES_READ_FAILED',
        () async {
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async => throw PlatformException(
          code: 'HRV_SAMPLES_READ_FAILED',
          message: 'Could not read heart rate variability samples.',
          details: 'SecurityException',
        ),
      );
      final out = await service.readHrvSamples(90);
      expect(out, isEmpty);
      expect(service.lastReadErrorCode, 'HRV_SAMPLES_READ_FAILED');
      expect(service.lastReadErrorDetails, contains('SecurityException'));
    });
  });

  group('Defect 1 + 1b — capture records per-metric outcomes', () {
    late Map<String, String> disk;
    late HealthHistoryStore store;

    setUp(() {
      disk = {};
      store = diagStore(disk);
    });

    test(
        'failing HRV read records the code + outcome counts in the '
        'persisted diagnostics; a later successful capture replaces '
        'the entry with a clean outcome', () async {
      final hc = _CaptureFakeHc();
      final now = DateTime(2026, 10, 19, 12);
      final sync =
          HealthHistorySync.withDeps(hc: hc, store: store, now: () => now);

      // The capture still completes (never throws, merge/throttle
      // behavior unchanged) — but the failure is now on record.
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      final diag = store.lastCaptureDiagnostics;
      expect(diag.keys, ['hrv']);
      expect(diag['hrv']!.errorCode, 'HRV_SAMPLES_READ_FAILED');
      expect(diag['hrv']!.partialCode, isNull);
      expect(diag['hrv']!.sampleCount, 0);
      expect(diag['hrv']!.dayCount, 0);
      expect(diag['hrv']!.atMs, now.millisecondsSinceEpoch);
      // Other metrics succeeded: no failure entries for them.
      expect(diag.containsKey('restingHr'), isFalse);
      expect(diag.containsKey('sleep'), isFalse);

      // Persisted: the blob itself carries the trace, and a fresh
      // store over the same disk (a restart) still shows it.
      final blob = jsonDecode(disk[HealthHistoryStore.storageKey]!) as Map;
      expect(blob['lastCaptureDiagnostics'], {
        'hrv': {
          'code': 'HRV_SAMPLES_READ_FAILED',
          'samples': 0,
          'days': 0,
          'atMs': now.millisecondsSinceEpoch,
        },
      });
      final cold = diagStore(disk);
      await cold.warmFromDisk();
      expect(cold.lastCaptureDiagnostics['hrv']!.errorCode,
          'HRV_SAMPLES_READ_FAILED');
      expect(cold.lastCaptureDiagnostics['hrv']!.sampleCount, 0);

      // A later successful HRV capture clears the FAILURE (the
      // entry now records the clean outcome counts) — and the HRV
      // value itself lands as before.
      hc.failHrv = false;
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      final after = store.lastCaptureDiagnostics['hrv']!;
      expect(after.errorCode, isNull);
      expect(after.partialCode, isNull);
      expect(after.sampleCount, 1);
      expect(after.dayCount, 1);
      expect((await store.readAll())['2026-10-19']!.hrvRmssdMs, 55.0);
    });

    test(
        'partial HRV read: samples land, entry carries the partial '
        'code + counts and NO error code', () async {
      final hc = _CaptureFakeHc()
        ..failHrv = false
        ..partialHrv = true;
      final sync = HealthHistorySync.withDeps(
          hc: hc, store: store, now: () => DateTime(2026, 10, 19, 12));
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      final diag = store.lastCaptureDiagnostics['hrv']!;
      expect(diag.errorCode, isNull);
      expect(diag.partialCode, 'HRV_SAMPLES_PARTIAL');
      expect(diag.sampleCount, 1);
      expect(diag.dayCount, 1);
      expect((await store.readAll())['2026-10-19']!.hrvRmssdMs, 55.0);
    });

    test('each failing metric is recorded under its own name', () async {
      final hc = _CaptureFakeHc()..failSleep = true;
      final sync = HealthHistorySync.withDeps(
          hc: hc, store: store, now: () => DateTime(2026, 10, 19, 12));
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(store.lastCaptureDiagnostics.keys,
          containsAll(['hrv', 'sleep']));
      expect(store.lastCaptureDiagnostics['sleep']!.errorCode,
          'SLEEP_HISTORY_READ_FAILED');
      expect(store.lastCaptureDiagnostics['hrv']!.errorCode,
          'HRV_SAMPLES_READ_FAILED');
    });

    test('a fully successful capture records a clean HRV outcome only',
        () async {
      final hc = _CaptureFakeHc()..failHrv = false;
      final sync = HealthHistorySync.withDeps(
          hc: hc, store: store, now: () => DateTime(2026, 10, 19, 12));
      expect(await sync.captureFromHealthConnect(force: true), isTrue);
      expect(store.lastCaptureDiagnostics.keys, ['hrv']);
      final diag = store.lastCaptureDiagnostics['hrv']!;
      expect(diag.errorCode, isNull);
      expect(diag.sampleCount, 1);
      expect(diag.dayCount, 1);
    });
  });

  group('Defect 2a — service exposes the missing set, named', () {
    test(
        'partial grant missing only HRV: missing set + label name '
        'Heart rate variability', () async {
      final granted = HealthConnectService.requiredPermissions
          .difference({
        'android.permission.health.READ_HEART_RATE_VARIABILITY',
      }).toList();
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return granted;
          throw UnimplementedError(call.method);
        },
      );
      expect(await service.getStatus(),
          HealthConnectStatus.partiallyConnected);
      expect(await service.getMissingPermissions(), {
        'android.permission.health.READ_HEART_RATE_VARIABILITY',
      });
      expect(await service.getMissingPermissionLabels(),
          ['Heart rate variability']);
    });

    test('static helpers: every required permission has a plain label',
        () {
      // No required permission may fall back to its raw name.
      for (final p in HealthConnectService.requiredPermissions) {
        expect(HealthConnectService.permissionLabel(p),
            isNot(startsWith('android.permission')),
            reason: '$p must have a plain-language label');
      }
      expect(
          HealthConnectService.permissionLabel(
              'android.permission.health.READ_HEART_RATE_VARIABILITY'),
          'Heart rate variability');
      expect(
          HealthConnectService.missingPermissions(
              HealthConnectService.requiredPermissions),
          isEmpty);
      expect(
          HealthConnectService.missingPermissionLabels(
              HealthConnectService.requiredPermissions),
          isEmpty);
    });

    test('the naming copy is the exact shared wording', () {
      expect(
        HealthConnectService.missingPermissionsMessage(
            ['Heart rate variability']),
        'Some health data is not shared: Heart rate variability. '
        'To fix it, open Health Connect, tap App permissions, '
        'tap Tabs, and turn on Heart rate variability.',
      );
    });
  });

  group('Defect 2b — partial surfaces render the naming copy', () {
    const expectedCopy =
        'Some health data is not shared: Heart rate variability. '
        'To fix it, open Health Connect, tap App permissions, '
        'tap Tabs, and turn on Heart rate variability.';

    testWidgets('Settings → Connected Apps names the missing type',
        (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = _SettingsFakeHc(const ['Heart rate variability']);
      await r51.pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await r51.openConnectedApps(tester);
      expect(find.text('Partially connected'), findsOneWidget);
      expect(find.text(expectedCopy), findsOneWidget);
      // The generic line is replaced, not stacked on top.
      expect(
          find.text(
              'Some health permissions are still missing. Grant the remaining permissions to sync everything.'),
          findsNothing);
    });

    testWidgets(
        'Settings → Connected Apps keeps the generic line when the '
        'missing set could not be read', (tester) async {
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      final hc = _SettingsFakeHc(const []);
      await r51.pumpSettings(tester, backend: backend, map: {}, hc: hc);
      await r51.openConnectedApps(tester);
      expect(find.text('Partially connected'), findsOneWidget);
      expect(
          find.text(
              'Some health permissions are still missing. Grant the remaining permissions to sync everything.'),
          findsOneWidget);
    });

    testWidgets('Data Connections screen names the missing type',
        (tester) async {
      final granted = HealthConnectService.requiredPermissions
          .difference({
        'android.permission.health.READ_HEART_RATE_VARIABILITY',
      }).toList();
      final service = serviceWith(
        store: MemorySecureStore(),
        handler: (call) async {
          if (call.method == 'isAvailable') return true;
          if (call.method == 'getGrantedPermissions') return granted;
          throw UnimplementedError(call.method);
        },
      );
      await tester.pumpWidget(
        MaterialApp(home: ConnectionsScreen(healthConnectService: service)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Partially connected'), findsOneWidget);
      expect(find.text(expectedCopy), findsOneWidget);
    });
  });

  group('Defect 1b — Connected Apps diagnostics line', () {
    testWidgets('failed HRV outcome renders code + counts',
        (tester) async {
      final disk = <String, String>{};
      final store = diagStore(disk);
      await store.recordCaptureDiagnostics(
        failures: const {'hrv': 'HRV_SAMPLES_READ_FAILED'},
        succeeded: const {},
        atMs: DateTime(2026, 10, 19, 12).millisecondsSinceEpoch,
        hrvSampleCount: 0,
        hrvDayCount: 0,
      );
      await pumpSettingsWithHistory(tester,
          historyStore: store, hc: _SettingsFakeHc(const []));
      await r51.openConnectedApps(tester);
      expect(
          find.text('Last HRV sync check: the read failed '
              '[HRV_SAMPLES_READ_FAILED]. 0 samples read, 0 days.'),
          findsOneWidget);
    });

    testWidgets('partial HRV outcome renders partial code + counts',
        (tester) async {
      final disk = <String, String>{};
      final store = diagStore(disk);
      await store.recordCaptureDiagnostics(
        failures: const {},
        succeeded: const {'hrv'},
        atMs: DateTime(2026, 10, 19, 12).millisecondsSinceEpoch,
        hrvPartialCode: 'HRV_SAMPLES_PARTIAL',
        hrvSampleCount: 132,
        hrvDayCount: 29,
      );
      await pumpSettingsWithHistory(tester,
          historyStore: store, hc: _SettingsFakeHc(const []));
      await r51.openConnectedApps(tester);
      expect(
          find.text('Last HRV sync check: some data could not be read '
              '[HRV_SAMPLES_PARTIAL]. 132 samples read, 29 days.'),
          findsOneWidget);
    });

    testWidgets('clean HRV outcome renders counts, no code',
        (tester) async {
      final disk = <String, String>{};
      final store = diagStore(disk);
      await store.recordCaptureDiagnostics(
        failures: const {},
        succeeded: const {'hrv'},
        atMs: DateTime(2026, 10, 19, 12).millisecondsSinceEpoch,
        hrvSampleCount: 132,
        hrvDayCount: 29,
      );
      await pumpSettingsWithHistory(tester,
          historyStore: store, hc: _SettingsFakeHc(const []));
      await r51.openConnectedApps(tester);
      expect(find.text('Last HRV sync check: 132 samples read, 29 days.'),
          findsOneWidget);
    });

    testWidgets('no capture diagnostics → no diagnostics line',
        (tester) async {
      final disk = <String, String>{};
      final store = diagStore(disk);
      await pumpSettingsWithHistory(tester,
          historyStore: store, hc: _SettingsFakeHc(const []));
      await r51.openConnectedApps(tester);
      expect(find.textContaining('Last HRV sync check'), findsNothing);
    });
  });
}
