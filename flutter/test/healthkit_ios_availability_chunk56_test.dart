import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'settings_r30_google_test.dart' as r30g;
import 'test_helpers.dart';

/// HealthKit chunks 5+6 — the honest iOS availability model, Juno's
/// signed copy, and the authorization request flow.
///
/// Juno's strings are hardcoded as literals in this file ON PURPOSE
/// (from `build-apple-readiness/juno/ios-availability-copy.md`,
/// 2026-11-22): the tests pin the shipped copy against Juno's file,
/// not against the app's own constants, so a drift in either
/// direction fails here.
///
/// The honesty rule under test: "Connected" derives ONLY from
/// requested AND a real read returning data — never from an
/// authorization status (which the bridge never even exposes).

class MemorySecureStore implements SecureStore {
  final Map<String, String> map = {};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async {
    map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    map.remove(key);
  }
}

const _channelName = 'com.notel.notel.playground.flutter/health_connect';

// Juno's signed strings, verbatim (see file header).
const _junoState1Body =
    'Tabs can read your heart rate, resting heart rate, heart rate '
    'variability, sleep, steps, and energy from Apple Health, so you '
    'can see your own daily values together in Tabs. Tabs reads this '
    'data only. It does not write anything to Apple Health.';
const _junoState2Body = 'Tabs is reading your health data from Apple Health.';
const _junoState2Footer =
    'Your connection is managed in Apple Health. To stop Tabs from '
    'reading your health data, open the Health app, tap your profile, '
    'tap Apps, tap Tabs, and turn off the data types you no longer '
    'want to share. You can also go to Settings, then Health, then '
    'Data Access & Devices, then Tabs.';
const _junoState3Body =
    'Tabs has asked Apple Health for your health data, and nothing '
    'has come back yet. That is normal if you do not have an Apple '
    'Watch or another app writing to Apple Health: heart rate, '
    'resting heart rate, and heart rate variability are recorded by '
    'a watch, and sleep is recorded by a watch or another sleep app. '
    'Steps and energy from your iPhone can take a little while to '
    'appear. Your logging, check-ins, and notes in Tabs work either '
    'way.';
const _junoState3Secondary =
    'If you expected data to be here, check that Tabs is allowed to '
    'read it: open the Health app, tap your profile, tap Apps, tap '
    'Tabs, and make sure the data types you want are on.';
const _junoState4Detail =
    'Apple Health is not available on this device, so Tabs cannot '
    'read health data from it here. Your logging, check-ins, and '
    'notes in Tabs still work.';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel(_channelName), null);
  });

  HealthConnectService iosService({
    required MemorySecureStore store,
    Future<dynamic> Function(MethodCall call)? handler,
  }) {
    final channel = const MethodChannel(_channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    return HealthConnectService(
        channel: channel, store: store, isIOSOverride: true);
  }

  /// A bridge handler for the availability probe: availability plus
  /// the four evidence reads, all empty unless [steps] says data.
  Future<dynamic> Function(MethodCall) probeHandler({int? steps}) {
    return (call) async {
      switch (call.method) {
        case 'isAvailable':
          return true;
        case 'readSteps':
          return steps;
        case 'readHeartRateSamples':
          return const [];
        case 'readRestingHeartRate':
          return null;
        case 'readHrvSdnnSamples':
          return const [];
      }
      return null;
    };
  }

  group('probeIosAvailability — the four honest states', () {
    test('HealthKit unavailable → unavailable', () async {
      final service = iosService(
        store: MemorySecureStore(),
        handler: (call) async {
          if (call.method == 'isAvailable') return false;
          return null;
        },
      );
      final snap = await service.probeIosAvailability();
      expect(snap.state, IosHealthAvailabilityState.unavailable);
      expect(snap.serviceAvailable, isFalse);
    });

    test('an availability bridge failure also maps to unavailable '
        '(never a fabricated connected)', () async {
      final service = iosService(
        store: MemorySecureStore(),
        handler: (call) async {
          throw PlatformException(code: 'BOOM', message: 'nope');
        },
      );
      final snap = await service.probeIosAvailability();
      expect(snap.state, IosHealthAvailabilityState.unavailable);
    });

    test('available + never requested → notYetRequested, even when '
        'data exists (requested is a separate fact)', () async {
      final service = iosService(
        store: MemorySecureStore(),
        handler: probeHandler(steps: 4321),
      );
      final snap = await service.probeIosAvailability();
      expect(snap.state, IosHealthAvailabilityState.notYetRequested);
      expect(snap.requested, isFalse);
    });

    test('requested + no data yet → noDataYet', () async {
      final store = MemorySecureStore();
      await store.write('hk_authorization_requested', '1');
      final service = iosService(store: store, handler: probeHandler());
      final snap = await service.probeIosAvailability();
      expect(snap.state, IosHealthAvailabilityState.noDataYet);
      expect(snap.requested, isTrue);
      expect(snap.hasData, isFalse);
    });

    test('requested + a real read returns data → connected', () async {
      final store = MemorySecureStore();
      await store.write('hk_authorization_requested', '1');
      final service =
          iosService(store: store, handler: probeHandler(steps: 4321));
      final snap = await service.probeIosAvailability();
      expect(snap.state, IosHealthAvailabilityState.connected);
      expect(snap.hasData, isTrue);
    });

    test('connected can be earned by SDNN evidence alone (a shared '
        'type must not be condemned by an unshared one)', () async {
      final store = MemorySecureStore();
      await store.write('hk_authorization_requested', '1');
      final service = iosService(
        store: store,
        handler: (call) async {
          switch (call.method) {
            case 'isAvailable':
              return true;
            case 'readSteps':
              return null;
            case 'readHeartRateSamples':
              return const [];
            case 'readRestingHeartRate':
              return null;
            case 'readHrvSdnnSamples':
              return [
                {'t': 1000, 'ms': 48.0},
              ];
          }
          return null;
        },
      );
      final snap = await service.probeIosAvailability();
      expect(snap.state, IosHealthAvailabilityState.connected);
    });
  });

  group('requestPermissions on iOS — the authorization flow', () {
    test('success persists the request and returns the honest empty '
        'set (no grant list exists to return)', () async {
      final store = MemorySecureStore();
      final service = iosService(
        store: store,
        handler: (call) async {
          if (call.method == 'requestPermissions') return true;
          return null;
        },
      );
      expect(await service.iosAuthorizationRequested(), isFalse);
      final result = await service.requestPermissions();
      expect(result, isEmpty);
      expect(await service.iosAuthorizationRequested(), isTrue);
    });

    test('a bridge failure propagates its code and persists nothing',
        () async {
      final store = MemorySecureStore();
      final service = iosService(
        store: store,
        handler: (call) async {
          if (call.method == 'requestPermissions') {
            throw PlatformException(
                code: 'AUTHORIZATION_FAILED',
                message: 'Authorization request failed.');
          }
          return null;
        },
      );
      await expectLater(
        service.requestPermissions(),
        throwsA(isA<HealthConnectException>()
            .having((e) => e.code, 'code', 'AUTHORIZATION_FAILED')),
      );
      expect(await service.iosAuthorizationRequested(), isFalse);
    });

    test('missing plugin → NO_CHANNEL, never a silent hang', () async {
      final service = HealthConnectService(
        channel: const MethodChannel('$_channelName-missing'),
        store: MemorySecureStore(),
        isIOSOverride: true,
      );
      await expectLater(
        service.requestPermissions(),
        throwsA(isA<HealthConnectException>()
            .having((e) => e.code, 'code', 'NO_CHANNEL')),
      );
    });

    test('getGrantedPermissions on iOS stays honest: no channel '
        'answer, no fabricated list', () async {
      final service = HealthConnectService(
        channel: const MethodChannel('$_channelName-missing'),
        store: MemorySecureStore(),
        isIOSOverride: true,
      );
      await expectLater(
        service.getGrantedPermissions(),
        throwsA(isA<HealthConnectException>()
            .having((e) => e.code, 'code', 'NO_CHANNEL')),
      );
    });

    test('disconnect clears the iOS requested record', () async {
      final store = MemorySecureStore();
      final service = iosService(
        store: store,
        handler: (call) async {
          if (call.method == 'requestPermissions') return true;
          return null;
        },
      );
      await service.requestPermissions();
      expect(await service.iosAuthorizationRequested(), isTrue);
      await service.disconnect();
      expect(await service.iosAuthorizationRequested(), isFalse);
    });
  });

  group('Swift + plist pins (chunks 5+6)', () {
    final swift = File(
            'plugins/healthkit_bridge/ios/healthkit_bridge/Sources/'
            'healthkit_bridge/HealthkitBridgePlugin.swift')
        .readAsStringSync();

    test('requestPermissions is implemented read-only in context', () {
      expect(swift, contains('case "requestPermissions"'));
      expect(swift, contains('requestAuthorization'));
      // The share set is EMPTY — no write types, ever.
      expect(swift, contains('toShare: Set<HKSampleType>()'));
      expect(swift, contains('read: Self.healthReadTypes'));
    });

    test('cancelRequest stays unimplemented (HealthKit has no '
        'cancellation API — no honest analogue)', () {
      expect(swift, isNot(contains('case "cancelRequest"')));
    });

    test('the probe is a sample query, not a statistics query '
        '(Vera chunk-2 note)', () {
      final probeStart = swift.indexOf('private func probeReadAccess');
      final probeEnd = swift.indexOf('private func requestPermissions');
      expect(probeStart, greaterThanOrEqualTo(0));
      expect(probeEnd, greaterThan(probeStart));
      final probeBody = swift.substring(probeStart, probeEnd);
      expect(probeBody, contains('querySamples'));
      expect(probeBody, isNot(contains('queryStatisticsSum')));
      expect(probeBody, contains('limit: 1'));
    });

    test('Info.plist: Juno\'s read-only share description present, '
        'update description absent', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();
      expect(plist, contains('NSHealthShareUsageDescription'));
      expect(plist, isNot(contains('NSHealthUpdateUsageDescription')));
    });
  });

  group('Connections screen on iOS — Juno copy, four states', () {
    Future<void> pumpConnections(
        WidgetTester tester, HealthConnectService service) async {
      // A tall surface: the State 3 sheet's full Juno body +
      // secondary line + button must fit without scrolling, or
      // the button tap lands outside the sheet's viewport.
      tester.view.physicalSize = const Size(1080, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(home: ConnectionsScreen(healthConnectService: service)),
      );
      await tester.pumpAndSettle();
    }

    void expectBlocklistAbsent() {
      expect(find.text('Partially connected'), findsNothing);
      expect(find.text('Connection problem'), findsNothing);
      expect(find.text('Grant New Permissions'), findsNothing);
      expect(find.text('No permissions were granted.'), findsNothing);
      expect(find.textContaining('Health Connect'), findsNothing);
      expect(find.textContaining('App permissions'), findsNothing);
    }

    testWidgets('State 1: Available row; sheet carries Juno\'s body '
        'and Connect button; a completed request lands on No data yet',
        (tester) async {
      final store = MemorySecureStore();
      final base = probeHandler();
      final service = iosService(
        store: store,
        handler: (call) async {
          if (call.method == 'requestPermissions') return true;
          return base(call);
        },
      );
      await pumpConnections(tester, service);
      expect(find.text('Apple Health'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
      expectBlocklistAbsent();

      await tester.tap(find.text('Available'));
      await tester.pumpAndSettle();
      expect(find.text('Not connected'), findsOneWidget);
      expect(find.text(_junoState1Body), findsOneWidget);
      expect(find.text('Connect Apple Health'), findsOneWidget);
      expectBlocklistAbsent();

      await tester.tap(find.text('Connect Apple Health'));
      await tester.pumpAndSettle();
      // The request completed and nothing has come back: State 3,
      // never an error, never "No permissions were granted."
      expect(find.text('No data yet'), findsOneWidget);
      expect(find.text('No permissions were granted.'), findsNothing);
      expectBlocklistAbsent();
    });

    testWidgets('State 2: Connected row + sheet with Juno\'s body, '
        'manage button and footer', (tester) async {
      final store = MemorySecureStore();
      await store.write('hk_authorization_requested', '1');
      final service =
          iosService(store: store, handler: probeHandler(steps: 4321));
      await pumpConnections(tester, service);
      expect(find.text('Connected'), findsOneWidget);
      expectBlocklistAbsent();

      await tester.tap(find.text('Connected'));
      await tester.pumpAndSettle();
      expect(find.text(_junoState2Body), findsOneWidget);
      expect(find.text('Manage in Health app'), findsOneWidget);
      expect(find.text(_junoState2Footer), findsOneWidget);
      expectBlocklistAbsent();
    });

    testWidgets('State 3: No data yet row + sheet with Juno\'s body, '
        'secondary line and Check again', (tester) async {
      final store = MemorySecureStore();
      await store.write('hk_authorization_requested', '1');
      final service = iosService(store: store, handler: probeHandler());
      await pumpConnections(tester, service);
      expect(find.text('No data yet'), findsOneWidget);
      expectBlocklistAbsent();

      await tester.tap(find.text('No data yet'));
      await tester.pumpAndSettle();
      expect(find.text(_junoState3Body), findsOneWidget);
      expect(find.text(_junoState3Secondary), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      expectBlocklistAbsent();

      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();
      expect(find.text('No data yet'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
    });

    testWidgets('State 4: disabled row + Juno\'s detail; no sheet',
        (tester) async {
      final service = iosService(
        store: MemorySecureStore(),
        handler: (call) async {
          if (call.method == 'isAvailable') return false;
          return null;
        },
      );
      await pumpConnections(tester, service);
      expect(find.text('Apple Health'), findsOneWidget);
      expect(find.text('Not available on this device'), findsOneWidget);
      expect(find.text(_junoState4Detail), findsOneWidget);
      expectBlocklistAbsent();

      await tester.tap(find.text('Apple Health'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
    });
  });

  group('Settings Connected Apps on iOS — Juno §2 row', () {
    testWidgets('Apple Health row with the state status line; no '
        'Android card, no background row, no grant upsell',
        (tester) async {
      final hc = _FakeIosHc(const IosHealthAvailability(
        state: IosHealthAvailabilityState.noDataYet,
        requested: true,
        hasData: false,
      ));
      final backend = r30g.LinkBackend()..pullBody = r29.pull();
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SettingsScreen(
            backend: backend,
            settingsStore: SettingsStore.withStorage(
              read: (k) async => null,
              write: (k, v) async {},
              delete: (k) async {},
            ),
            notificationService: FakeReminderNotificationService(),
            googleSignInService: r30g.FakeGoogle(),
            healthConnectService: hc,
            urlLauncher: (uri) async => true,
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu_connected_apps')));
      await tester.pumpAndSettle();

      expect(find.text('Apple Health'), findsOneWidget);
      expect(find.text('No data yet'), findsOneWidget);
      expect(hc.iosProbeCalls, greaterThan(0));
      // The Android derivations were never consulted on iOS.
      expect(hc.androidProbeCalled, isFalse);
      expect(hc.backgroundReadCalled, isFalse);
      // Juno §2/§3 blocklist for this surface.
      expect(find.text('Google Health Connect'), findsNothing);
      expect(find.text('Partially connected'), findsNothing);
      expect(find.text('Grant New Permissions'), findsNothing);
      expect(find.text('Daily Score in the Background'), findsNothing);
      expect(find.textContaining('Background access'), findsNothing);
    });
  });
}

/// Settings fake for the iOS path: a canned iOS snapshot, with the
/// Android derivations instrumented so the test can prove they are
/// never consulted on iOS.
class _FakeIosHc extends HealthConnectService {
  _FakeIosHc(this.snapshot)
      : super(store: MemorySecureStore(), isIOSOverride: true);

  final IosHealthAvailability snapshot;
  int iosProbeCalls = 0;
  bool androidProbeCalled = false;
  bool backgroundReadCalled = false;

  @override
  Future<IosHealthAvailability> probeIosAvailability() async {
    iosProbeCalls++;
    return snapshot;
  }

  @override
  Future<HcAvailability> probeAvailability() async {
    androidProbeCalled = true;
    return const HcAvailability(
      serviceAvailable: false,
      grantedPermissions: null,
      bridgeErrorCode: 'SHOULD_NOT_BE_CALLED_ON_IOS',
      stepsProbe: null,
      persistedConnected: false,
    );
  }

  @override
  Future<bool> hasBackgroundAccess() async {
    backgroundReadCalled = true;
    return false;
  }
}
