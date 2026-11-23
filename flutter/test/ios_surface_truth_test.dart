import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/features/connections/connections_screen.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/features/home/health_connect_banner.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_connections_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_header.dart';

/// iOS surface truth — Vera's PR #140 merge conditions + Juno's two
/// signed copy addenda (Heart/Home banner, onboarding health step),
/// implemented verbatim.
///
/// Juno's strings are hardcoded as literals in this file ON PURPOSE
/// (from `build-apple-readiness/juno/ios-heart-home-copy-addendum.md`
/// and `ios-onboarding-copy-addendum.md`, both signed 2026-11-22):
/// the tests pin the shipped copy against Juno's files, not against
/// the app's own constants, so a drift in either direction fails
/// here — the chunk 5/6 test house style.

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
const _junoHeartState1Body =
    'Connect Apple Health to read your heart rate and sleep data.';
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

/// An iOS service fake whose probe state the test controls. The
/// Android derivations are instrumented so tests can prove the iOS
/// surfaces never consult them.
class FakeIosHc extends HealthConnectService {
  FakeIosHc({required this.state, this.failRequest = false})
      : super(store: MemorySecureStore(), isIOSOverride: true);

  IosHealthAvailabilityState state;
  bool failRequest;
  int iosProbeCalls = 0;
  int requestCalls = 0;
  int androidProbeCalls = 0;
  int persistedCalls = 0;

  @override
  Future<IosHealthAvailability> probeIosAvailability() async {
    iosProbeCalls++;
    return IosHealthAvailability(
      state: state,
      requested: state == IosHealthAvailabilityState.connected ||
          state == IosHealthAvailabilityState.noDataYet,
      hasData: state == IosHealthAvailabilityState.connected,
    );
  }

  @override
  Future<Set<String>> requestPermissions() async {
    requestCalls++;
    if (failRequest) {
      throw const HealthConnectException(
          'AUTHORIZATION_FAILED', 'Apple Health authorization did not complete.');
    }
    // A completed request that shares nothing lands on State 3.
    if (state == IosHealthAvailabilityState.notYetRequested) {
      state = IosHealthAvailabilityState.noDataYet;
    }
    return const <String>{};
  }

  @override
  Future<HcAvailability> probeAvailability() async {
    androidProbeCalls++;
    return const HcAvailability(
      serviceAvailable: false,
      grantedPermissions: null,
      bridgeErrorCode: 'SHOULD_NOT_BE_CALLED_ON_IOS',
      stepsProbe: null,
      persistedConnected: false,
    );
  }

  @override
  Future<bool> hasPersistedConnection() async {
    persistedCalls++;
    return false;
  }

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async =>
      const [];
}

/// An Android service fake for the Gate 10 twin: full grant, so the
/// Heart screen paints its connected (State 2) body through the
/// Android probe path.
class FakeAndroidHc extends HealthConnectService {
  FakeAndroidHc()
      : super(store: MemorySecureStore(), isIOSOverride: false);

  @override
  Future<HcAvailability> probeAvailability() async => HcAvailability(
        serviceAvailable: true,
        grantedPermissions: HealthConnectService.requiredPermissions,
        bridgeErrorCode: null,
        stepsProbe: null,
        persistedConnected: true,
      );

  @override
  Future<bool> hasPersistedConnection() async => true;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async =>
      const [];
}

/// The Health Connect brand-mark image, by asset name — Gate 10's
/// pinned asset.
Finder hcLogoFinder() => find.byWidgetPredicate((w) =>
    w is Image &&
    w.image is AssetImage &&
    (w.image as AssetImage).assetName ==
        'assets/images/ic_health_connect.png');

/// The source row's heart-icon fallback glyph (size 20; the summary
/// card's favorite icon is size 48, so size distinguishes them).
Finder hcFallbackFinder() => find.byWidgetPredicate(
    (w) => w is Icon && w.icon == Icons.favorite && w.size == 20);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Heart screen on iOS — Juno Heart/Home addendum §2', () {
    setUp(() {
      // The heart_r25 harness pattern: the cache's disk warm in
      // HeartScreen._init pends forever on the real secure-storage
      // channel in tests, so the probe would never run.
      HeartDataCache.instance.debugReset();
      final store = <String, String>{};
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
    });

    Future<void> pumpHeart(WidgetTester tester, FakeIosHc hc) async {
      tester.view.physicalSize = const Size(1080, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: HeartScreen(
          email: 'a@b.c',
          healthConnectService: hc,
          cache: HeartDataCache.instance,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('State 1: signed not-connected body; the tap goes '
        'straight to the request (no disclosure dialog) and a '
        'completed empty-set request lands on State 3 — the '
        'blocklisted error NEVER renders', (tester) async {
      final hc = FakeIosHc(state: IosHealthAvailabilityState.notYetRequested);
      await pumpHeart(tester, hc);
      expect(find.text('Connect Vital Signs'), findsOneWidget);
      expect(find.text(_junoHeartState1Body), findsOneWidget);
      expect(find.text('Connect Apple Health'), findsOneWidget);
      expect(find.text('Link Health Connect'), findsNothing);
      expect(find.textContaining('Health Connect'), findsNothing);
      // The gate never consulted the Android derivations on iOS.
      expect(hc.androidProbeCalls, 0);
      expect(hc.persistedCalls, 0);

      await tester.tap(find.text('Connect Apple Health'));
      await tester.pumpAndSettle();
      expect(hc.requestCalls, 1);
      // No MF-3 disclosure dialog was shown on the way.
      expect(find.byType(AlertDialog), findsNothing);
      // Completed request, nothing returned: State 3, no error.
      expect(find.text('No data yet'), findsOneWidget);
      expect(find.text('No permissions were granted.'), findsNothing);
      expect(find.textContaining('Health Connect'), findsNothing);
    });

    testWidgets('State 1: a FAILED request surfaces only the '
        'approved iOS service string', (tester) async {
      final hc = FakeIosHc(
          state: IosHealthAvailabilityState.notYetRequested,
          failRequest: true);
      await pumpHeart(tester, hc);
      await tester.tap(find.text('Connect Apple Health'));
      await tester.pumpAndSettle();
      expect(
          find.text('Apple Health authorization did not complete.'),
          findsOneWidget);
      expect(find.text('No permissions were granted.'), findsNothing);
    });

    testWidgets('State 3: the dedicated signed presentation, never '
        'labeled not-connected; Check again re-probes', (tester) async {
      final hc = FakeIosHc(state: IosHealthAvailabilityState.noDataYet);
      await pumpHeart(tester, hc);
      expect(find.text('No data yet'), findsOneWidget);
      expect(find.text(_junoState3Body), findsOneWidget);
      expect(find.text(_junoState3Secondary), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      expect(find.text('Connect Vital Signs'), findsNothing);
      expect(find.text('Connect Apple Health'), findsNothing);
      expect(find.textContaining('not connected'), findsNothing);
      expect(find.text('No permissions were granted.'), findsNothing);

      final probesBefore = hc.iosProbeCalls;
      await tester.tap(find.text('Check again'));
      await tester.pumpAndSettle();
      expect(hc.iosProbeCalls, greaterThan(probesBefore));
      expect(find.text('No data yet'), findsOneWidget);
      expect(find.text('No permissions were granted.'), findsNothing);
    });

    testWidgets('State 4: signed unavailable copy, NO button, never '
        'the State 1 headline', (tester) async {
      final hc = FakeIosHc(state: IosHealthAvailabilityState.unavailable);
      await pumpHeart(tester, hc);
      expect(find.text('Not available on this device'), findsOneWidget);
      expect(find.text(_junoState4Detail), findsOneWidget);
      expect(find.text('Connect Vital Signs'), findsNothing);
      expect(find.text('Connect Apple Health'), findsNothing);
      expect(find.text('Check again'), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
      expect(find.textContaining('Health Connect'), findsNothing);
    });

    testWidgets('State 2: the connected body renders and its '
        'source row is titled Apple Health', (tester) async {
      final hc = FakeIosHc(state: IosHealthAvailabilityState.connected);
      await pumpHeart(tester, hc);
      expect(find.text('Awake average'), findsOneWidget);
      expect(find.text('Apple Health'), findsOneWidget);
      expect(find.text('Health Connect'), findsNothing);
      expect(find.text('Connect Vital Signs'), findsNothing);
    });
  });

  group('Gate 10: connected source-row logo forks by platform', () {
    setUp(() {
      HeartDataCache.instance.debugReset();
      final store = <String, String>{};
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
    });

    Future<void> pumpHeartWith(
        WidgetTester tester, HealthConnectService hc) async {
      tester.view.physicalSize = const Size(1080, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: HeartScreen(
          email: 'a@b.c',
          healthConnectService: hc,
          cache: HeartDataCache.instance,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('iOS State 2: title is Apple Health and the '
        'ic_health_connect.png asset does NOT render — the '
        'heart-icon fallback renders instead', (tester) async {
      final hc = FakeIosHc(state: IosHealthAvailabilityState.connected);
      await pumpHeartWith(tester, hc);
      expect(find.text('Apple Health'), findsOneWidget);
      expect(find.text('Health Connect'), findsNothing);
      expect(hcLogoFinder(), findsNothing);
      expect(hcFallbackFinder(), findsOneWidget);
    });

    testWidgets('Android State 2 twin: title is Health Connect '
        'and the ic_health_connect.png asset still renders',
        (tester) async {
      await pumpHeartWith(tester, FakeAndroidHc());
      expect(find.text('Health Connect'), findsOneWidget);
      expect(find.text('Apple Health'), findsNothing);
      expect(hcLogoFinder(), findsOneWidget);
    });
  });

  group('Home banner on iOS — Juno Heart/Home addendum §3', () {
    const empty = TodayVitals(
      heartRate: null,
      activeCalories: null,
      sleepMinutes: null,
    );
    const withData = TodayVitals(
      heartRate: 72,
      activeCalories: null,
      sleepMinutes: null,
    );

    test('State 1 + empty vitals is the ONLY iOS banner', () {
      expect(
        shouldShowIosHealthBanner(
            state: IosHealthAvailabilityState.notYetRequested,
            vitals: empty),
        isTrue,
      );
      expect(iosHealthBannerTitle(IosHealthAvailabilityState.notYetRequested),
          "Apple Health isn't connected");
      expect(iosHealthBannerBody(IosHealthAvailabilityState.notYetRequested),
          'Tap to connect');
      for (final state in IosHealthAvailabilityState.values) {
        if (state == IosHealthAvailabilityState.notYetRequested) continue;
        expect(
          shouldShowIosHealthBanner(state: state, vitals: empty),
          isFalse,
          reason: 'no banner in $state (§3.2/§3.3)',
        );
        expect(iosHealthBannerTitle(state), isNull);
        expect(iosHealthBannerBody(state), isNull);
      }
      // Probe not landed → no banner; State 1 with data → no banner.
      expect(shouldShowIosHealthBanner(state: null, vitals: empty), isFalse);
      expect(
        shouldShowIosHealthBanner(
            state: IosHealthAvailabilityState.notYetRequested,
            vitals: withData),
        isFalse,
      );
    });

    testWidgets('the iOS banner widget renders the signed State 1 '
        'copy and never the Android fallback', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: HealthConnectBanner(
            status: HealthConnectStatus.notConnected,
            iosState: IosHealthAvailabilityState.notYetRequested,
            onTap: () {},
          ),
        ),
      ));
      expect(find.text("Apple Health isn't connected"), findsOneWidget);
      expect(find.text('Tap to connect'), findsOneWidget);
      expect(find.text('Tap to reconnect'), findsNothing);
      expect(find.textContaining('Health Connect'), findsNothing);
    });
  });

  group('Onboarding health step on iOS — Juno onboarding addendum', () {
    Future<int> pumpOnboarding(WidgetTester tester, FakeIosHc hc) async {
      var nextCalls = 0;
      tester.view.physicalSize = const Size(1080, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: OnboardingConnectionsScreen(
          onBack: () {},
          onNavigateNext: () => nextCalls++,
          healthConnectService: hc,
        ),
      ));
      await tester.pumpAndSettle();
      return nextCalls;
    }

    testWidgets('the 6 iOS placements render verbatim; shared '
        'strings stay shared', (tester) async {
      final hc = FakeIosHc(state: IosHealthAvailabilityState.notYetRequested);
      await pumpOnboarding(tester, hc);
      // #1 title + #2 button: the same signed literal, two sites.
      expect(find.text('Connect Apple Health'), findsNWidgets(2));
      expect(find.text('Connect Health Data'), findsNothing);
      // #3 body first line; the Daily Score line stays shared.
      expect(
          find.text('Read your heart rate and sleep data from Apple Health.'),
          findsOneWidget);
      expect(find.text('Sync your heart rate and sleep data.'), findsNothing);
      expect(find.text('This is what powers your Daily Score.'),
          findsOneWidget);
      expect(find.text('Skip for now'), findsOneWidget);
      expect(find.textContaining('Health Connect'), findsNothing);

      // #4/#5/#6: the skip dialog forks.
      await tester.tap(find.text('Skip for now'));
      await tester.pumpAndSettle();
      expect(find.text('Skip Apple Health?'), findsOneWidget);
      expect(find.text('Skip Health Connect?'), findsNothing);
      expect(find.text("Without it, Tabs can't read your:"), findsOneWidget);
      expect(find.text("Without it, Tabs can't sync in your:"), findsNothing);
      for (final item in const ['Heart rate', 'Sleep', 'HRV']) {
        expect(find.text(item), findsOneWidget);
      }
      expect(
        find.text('So there is no Daily Score, and your trends and AI '
            'insights only use what you log by hand. You can connect '
            'anytime in Tabs: Settings, then Connected Apps, then '
            'Apple Health.'),
        findsOneWidget,
      );
      expect(find.text('Connect instead'), findsOneWidget);
      expect(find.text('Skip anyway'), findsOneWidget);
    });

    testWidgets('State 4: signed unavailable string + Next, NO '
        'connect button and NO skip dialog', (tester) async {
      final hc = FakeIosHc(state: IosHealthAvailabilityState.unavailable);
      var nextCalls = 0;
      tester.view.physicalSize = const Size(1080, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: OnboardingConnectionsScreen(
          onBack: () {},
          onNavigateNext: () => nextCalls++,
          healthConnectService: hc,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text(_junoState4Detail), findsOneWidget);
      // The only 'Connect Apple Health' left is the screen title —
      // no connect BUTTON exists in this state.
      expect(
        find.widgetWithText(OnboardingPrimaryButton, 'Connect Apple Health'),
        findsNothing,
      );
      expect(find.text('Skip for now'), findsNothing);
      expect(
          find.widgetWithText(OnboardingPrimaryButton, 'Next'),
          findsOneWidget);

      await tester.tap(find.widgetWithText(OnboardingPrimaryButton, 'Next'));
      await tester.pumpAndSettle();
      expect(nextCalls, 1);
      // Advancing showed no skip dialog on the way.
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('Skip Apple Health?'), findsNothing);
    });

    testWidgets('State 3 gets NO onboarding copy changes: the '
        'not-connected layout with the §1 iOS strings stands',
        (tester) async {
      final hc = FakeIosHc(state: IosHealthAvailabilityState.noDataYet);
      await pumpOnboarding(tester, hc);
      expect(find.text('Connect Apple Health'), findsNWidgets(2));
      expect(find.text('No data yet'), findsNothing);
      expect(find.text('Skip for now'), findsOneWidget);
    });
  });

  group('Connections on iOS — the Android row never renders '
      '(Harbor sweep)', () {
    testWidgets('iOS renders the Apple Health row only; the Android '
        '"Health Connect" row is absent', (tester) async {
      final hc = FakeIosHc(state: IosHealthAvailabilityState.notYetRequested);
      tester.view.physicalSize = const Size(1080, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: ConnectionsScreen(healthConnectService: hc),
      ));
      await tester.pumpAndSettle();
      expect(find.text('Apple Health'), findsOneWidget);
      expect(find.text('Android Health (Google Fit, Samsung)'),
          findsNothing);
      expect(find.textContaining('Health Connect'), findsNothing);
    });
  });

  group('Swift pin + probe evidence + timeout discipline', () {
    final swift = File(
            'plugins/healthkit_bridge/ios/healthkit_bridge/Sources/'
            'healthkit_bridge/HealthkitBridgePlugin.swift')
        .readAsStringSync();

    test('Vera condition 2: the requestAuthorization CALL SITE is '
        'pinned to exactly 1 in the Swift plugin', () {
      // The one other match in the file is the doc comment naming
      // the API; the pin counts the actual call on the store.
      expect('store.requestAuthorization('.allMatches(swift).length, 1);
      expect(swift, contains('toShare: Set<HKSampleType>()'));
    });

    testWidgets('iOS REQUEST_TIMEOUT: a request that never returns '
        'throws REQUEST_TIMEOUT, attempts cancelRequest, and '
        'persists nothing (mirrors the Android timeout discipline)',
        (tester) async {
      final store = MemorySecureStore();
      var cancelCalls = 0;
      const channel = MethodChannel(_channelName);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'requestPermissions') {
          return Completer<dynamic>().future; // never returns
        }
        if (call.method == 'cancelRequest') {
          cancelCalls++;
          return null;
        }
        return null;
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });
      final service = HealthConnectService(
          channel: channel, store: store, isIOSOverride: true);
      Object? error;
      unawaited(service.requestPermissions().then((_) {}, onError: (Object e) {
        error = e;
      }));
      await tester.pump(HealthConnectService.requestTimeout +
          const Duration(seconds: 1));
      expect(error, isA<HealthConnectException>());
      expect((error! as HealthConnectException).code, 'REQUEST_TIMEOUT');
      expect((error! as HealthConnectException).message,
          'The permission request timed out. Please try again.');
      expect(cancelCalls, 1);
      expect(await service.iosAuthorizationRequested(), isFalse);
    });

    group('sleep-as-evidence (Vera condition 3)', () {
      tearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
                const MethodChannel(_channelName), null);
      });

      HealthConnectService iosChannelService(MemorySecureStore store,
          Future<dynamic> Function(MethodCall call) handler) {
        const channel = MethodChannel(_channelName);
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, handler);
        return HealthConnectService(
            channel: channel, store: store, isIOSOverride: true);
      }

      test('requested + sleep-only evidence → connected', () async {
        final store = MemorySecureStore();
        await store.write('hk_authorization_requested', '1');
        final service = iosChannelService(store, (call) async {
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
              return const [];
            case 'readSleepMinutes':
              return 402;
          }
          return null;
        });
        final snap = await service.probeIosAvailability();
        expect(snap.state, IosHealthAvailabilityState.connected);
        expect(snap.hasData, isTrue);
      });

      test('requested + zero sleep is NOT evidence → noDataYet',
          () async {
        final store = MemorySecureStore();
        await store.write('hk_authorization_requested', '1');
        final service = iosChannelService(store, (call) async {
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
              return const [];
            case 'readSleepMinutes':
              return 0;
          }
          return null;
        });
        final snap = await service.probeIosAvailability();
        expect(snap.state, IosHealthAvailabilityState.noDataYet);
      });
    });
  });
}
