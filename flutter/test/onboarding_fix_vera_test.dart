import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart' show HrSample;
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_connections_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_flow.dart';

import 'onboarding_r32_test.dart' as r32;
import 'test_helpers.dart';

/// Vera fix round (onboarding reorder) — regression tests for:
///  F1: the pre-account connections step must run ZERO health
///      data read / probe calls (grant-status read-back only).
///  F2: pre-account entry must check the in-progress flag's
///      provenance — flag-absent payload is wiped, never resumed
///      or minted over, at BOTH doors (Get started + cold start).
///  Guard: pre-account gems Continue with no handoff callback
///      never advances to membership.

const _contextText =
    'I have POTS and chronic migraines and heat makes everything '
    'worse daily';
const _foreign =
    'a foreign template goal that is not the new users own words '
    'at all';

OnboardingStore _store(Map<String, String> map) =>
    OnboardingStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

class _MemStore implements SecureStore {
  final Map<String, String> _map = {};
  @override
  Future<String?> read(String key) async => _map[key];
  @override
  Future<void> write(String key, String value) async => _map[key] = value;
  @override
  Future<void> delete(String key) async => _map.remove(key);
}

/// RECORDING Health Connect fake (Vera F1 regression surface).
///
/// It records every service method call at the probe / read /
/// grant-status entry points, and — critically — it does NOT
/// override the status entry points away: [getStatus],
/// [getGrantStatusOnly], [probeIosAvailability] and
/// [probeIosAvailabilityGrantOnly] are the REAL implementations,
/// so if the production status path calls a probe or a data read,
/// the recording below catches it. Only the leaf primitives are
/// faked: grant-status primitives answer from fields, and every
/// probe / data-read leaf records its call before answering with
/// data (so a normal post-account probe WOULD earn "connected" —
/// the pre-account path must simply never call them).
class RecordingHC extends HealthConnectService {
  RecordingHC({required bool isIOS, Set<String>? granted, bool iosRequested = false})
      : granted = granted ?? <String>{},
        grantedOnRequest = granted ?? <String>{},
        iosRequested = iosRequested,
        super(store: _MemStore(), isIOSOverride: isIOS);

  Set<String> granted;
  Set<String> grantedOnRequest;
  bool iosRequested;
  final List<String> calls = [];

  static const readProbeNames = {
    'probeReadAccess',
    'readSteps',
    'readHeartRateSamples',
    'readRestingHeartRate',
    'readHrvSdnnSamples',
    'readSleepMinutes',
  };

  List<String> get readProbeCalls =>
      calls.where(readProbeNames.contains).toList();

  @override
  Future<bool> isAvailable() async {
    calls.add('isAvailable');
    return true;
  }

  @override
  Future<Set<String>> getGrantedPermissions() async {
    calls.add('getGrantedPermissions');
    return granted;
  }

  @override
  Future<bool> hasPersistedConnection() async {
    calls.add('hasPersistedConnection');
    return granted.containsAll(HealthConnectService.requiredPermissions);
  }

  @override
  Future<bool> iosAuthorizationRequested() async {
    calls.add('iosAuthorizationRequested');
    return iosRequested;
  }

  @override
  Future<HcReadProbeOutcome> probeReadAccess() async {
    calls.add('probeReadAccess');
    return HcReadProbeOutcome.ok;
  }

  @override
  Future<int?> readSteps(String dateStr) async {
    calls.add('readSteps');
    return 5000;
  }

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    calls.add('readHeartRateSamples');
    return const [HrSample(timeMs: 0, bpm: 70)];
  }

  @override
  Future<int?> readRestingHeartRate(String dateStr) async {
    calls.add('readRestingHeartRate');
    return 60;
  }

  @override
  Future<List<HrvSdnnSample>> readHrvSdnnSamples(int days) async {
    calls.add('readHrvSdnnSamples');
    return const [HrvSdnnSample(t: 0, ms: 50)];
  }

  @override
  Future<int?> readSleepMinutes(String dateStr) async {
    calls.add('readSleepMinutes');
    return 400;
  }

  @override
  Future<Set<String>> requestPermissions() async {
    calls.add('requestPermissions');
    iosRequested = true;
    granted = grantedOnRequest;
    return grantedOnRequest;
  }

  @override
  Future<Set<String>> requestPermissionsGrantOnly() async {
    calls.add('requestPermissionsGrantOnly');
    iosRequested = true;
    granted = grantedOnRequest;
    return grantedOnRequest;
  }

  @override
  Future<void> openHealthConnectSettings() async {
    calls.add('openHealthConnectSettings');
  }
}

MockClient _weather() => MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
            200);
      }
      return http.Response(
          '{"current":{"temperature_2m":61.0,"weather_code":2,'
          '"is_day":1}}',
          200);
    });

Future<void> _pumpApp(
  WidgetTester tester, {
  required FakeSessionStore session,
  required Map<String, String> map,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: AppFlow(
      authApi: AuthApiClient(
          client: MockClient((_) async => http.Response('nf', 404))),
      sessionStore: session,
      onboardingStore: _store(map),
      tabsBackend: r32.FakeOnboardingBackend(sessionStore: session),
      weatherApi: WeatherApiClient(client: _weather()),
      healthConnectService: r32.FakeOnboardingHC(),
      notificationService: FakeReminderNotificationService(),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 1850));
  await tester.pump(const Duration(milliseconds: 650));
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

void _seedForeign(Map<String, String> map, String marker) {
  map[OnboardingStore.userContextKey] = _foreign;
  map[OnboardingStore.userConditionsKey] = '["Asthma"]';
  map[OnboardingStore.hasConsentedKey] = 'true';
  map[OnboardingStore.stepMarkerKey] = marker;
  // NO preAccountInProgressKey, NO owner stamp: foreign state.
  map.remove(OnboardingStore.preAccountInProgressKey);
  map.remove(OnboardingStore.ownerEmailKey);
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);
  setUp(() => TabsBackend.onSessionExpired = null);
  tearDown(() => TabsBackend.onSessionExpired = null);

  group('F1 — pre-account connections: grant-status only', () {
    Future<void> pumpConnections(
      WidgetTester tester,
      RecordingHC hc, {
      required bool preAccount,
    }) async {
      tester.view.physicalSize = const Size(1080, 2800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: OnboardingConnectionsScreen(
          onBack: () {},
          onNavigateNext: () {},
          healthConnectService: hc,
          preAccount: preAccount,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
    }

    testWidgets(
        'Android landing pre-account WITH full grants: ZERO '
        'read/probe calls, grant-status calls only, connected '
        'from grants alone', (tester) async {
      final hc = RecordingHC(
        isIOS: false,
        granted: HealthConnectService.requiredPermissions.toSet(),
      );
      await pumpConnections(tester, hc, preAccount: true);
      expect(hc.readProbeCalls, isEmpty,
          reason: 'pre-account landing ran a health read/probe: '
              '${hc.calls}');
      expect(hc.calls, contains('getGrantedPermissions'));
      expect(hc.calls, contains('hasPersistedConnection'));
      expect(find.text('Looks like you are already connected!'),
          findsOneWidget);
    });

    testWidgets(
        'Android landing post-account still uses the normal '
        'status path (probe runs)', (tester) async {
      final hc = RecordingHC(
        isIOS: false,
        granted: HealthConnectService.requiredPermissions.toSet(),
      );
      await pumpConnections(tester, hc, preAccount: false);
      expect(hc.calls, contains('probeReadAccess'),
          reason: 'post-account getStatus must keep its probe');
      expect(find.text('Looks like you are already connected!'),
          findsOneWidget);
    });

    testWidgets(
        'iOS landing pre-account WITH authorization requested: '
        'ZERO evidence reads, never claims connected',
        (tester) async {
      final hc = RecordingHC(isIOS: true, iosRequested: true);
      await pumpConnections(tester, hc, preAccount: true);
      expect(hc.readProbeCalls, isEmpty,
          reason: 'pre-account iOS landing ran an evidence read: '
              '${hc.calls}');
      expect(hc.calls, contains('iosAuthorizationRequested'));
      expect(find.text('Looks like you are already connected!'),
          findsNothing);
      expect(find.text('Skip for now'), findsOneWidget);
    });

    testWidgets(
        'iOS landing post-account still uses the normal probe '
        '(evidence reads run, connected earned)', (tester) async {
      final hc = RecordingHC(isIOS: true, iosRequested: true);
      await pumpConnections(tester, hc, preAccount: false);
      expect(hc.readProbeCalls, isNotEmpty,
          reason: 'post-account probeIosAvailability must keep '
              'its data-evidence reads');
      expect(find.text('Looks like you are already connected!'),
          findsOneWidget);
    });

    testWidgets(
        'Android connect tap pre-account: grant-only request, '
        'no probe read after the grant', (tester) async {
      final hc = RecordingHC(isIOS: false, granted: <String>{})
        ..grantedOnRequest =
            HealthConnectService.requiredPermissions.toSet();
      await pumpConnections(tester, hc, preAccount: true);
      hc.calls.clear();
      await tester.tap(
          find.widgetWithText(FilledButton, 'Connect Health Data'));
      await tester.pumpAndSettle();
      // MF-3 disclosure first (allowed pre-account), then Continue.
      expect(find.text('Connect Health Connect?'), findsOneWidget);
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(hc.calls, contains('requestPermissionsGrantOnly'));
      expect(hc.calls, isNot(contains('requestPermissions')));
      expect(hc.readProbeCalls, isEmpty,
          reason: 'post-grant re-check probed pre-account: '
              '${hc.calls}');
      expect(find.text('Looks like you are already connected!'),
          findsOneWidget);
    });

    testWidgets(
        'Android connect tap post-account: normal request path '
        'unchanged', (tester) async {
      final hc = RecordingHC(isIOS: false, granted: <String>{})
        ..grantedOnRequest =
            HealthConnectService.requiredPermissions.toSet();
      await pumpConnections(tester, hc, preAccount: false);
      hc.calls.clear();
      await tester.tap(
          find.widgetWithText(FilledButton, 'Connect Health Data'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(hc.calls, contains('requestPermissions'));
      expect(hc.calls, isNot(contains('requestPermissionsGrantOnly')));
    });

    testWidgets(
        'iOS connect tap pre-account: grant-only request + '
        'grant-only re-check, ZERO evidence reads', (tester) async {
      final hc = RecordingHC(isIOS: true, iosRequested: false);
      await pumpConnections(tester, hc, preAccount: true);
      hc.calls.clear();
      await tester.tap(
          find.widgetWithText(FilledButton, 'Connect Apple Health'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump();
      expect(hc.calls, contains('requestPermissionsGrantOnly'));
      expect(hc.calls, isNot(contains('requestPermissions')));
      expect(hc.readProbeCalls, isEmpty,
          reason: 'post-grant iOS re-check read data pre-account: '
              '${hc.calls}');
    });
  });

  group('F2 — flag provenance at both doors', () {
    testWidgets(
        '(a) Get started: foreign unstamped payload, marker='
        'conditions, no flag → wiped, starts at Consent',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final map = <String, String>{};
      await _pumpApp(tester, session: FakeSessionStore(), map: map);
      expect(find.text('Get started'), findsOneWidget);
      // Payload present at Get-started time (seeded after the
      // cold-start restore already ran, isolating THIS door).
      _seedForeign(map, '2');
      await tester.tap(find.text('Get started'));
      await _settle(tester);
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      expect(find.text('Add conditions'), findsNothing);
      expect(map[OnboardingStore.userContextKey], isNull);
      expect(map[OnboardingStore.userConditionsKey], isNull);
      expect(map[OnboardingStore.hasConsentedKey], isNot('true'));
      expect(await _store(map).getHasConsented(), isFalse);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        '(b) Get started: foreign unstamped payload, marker=gems, '
        'no flag → wiped, Consent start (never the handoff)',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final map = <String, String>{};
      await _pumpApp(tester, session: FakeSessionStore(), map: map);
      _seedForeign(map, '4'); // gems
      await tester.tap(find.text('Get started'));
      await _settle(tester);
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      expect(find.text('STREAKS, FREEZES & GEMS'), findsNothing);
      expect(map[OnboardingStore.userContextKey], isNull);
      expect(map[OnboardingStore.userConditionsKey], isNull);
      expect(map[OnboardingStore.hasConsentedKey], isNot('true'));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        '(c) cold start: foreign unstamped payload, no token → '
        'not resumed, state wiped, app at Welcome', (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final map = <String, String>{};
      _seedForeign(map, '2');
      await _pumpApp(tester, session: FakeSessionStore(), map: map);
      expect(find.text('Get started'), findsOneWidget);
      expect(find.text('Add conditions'), findsNothing);
      expect(find.text('Privacy & Data Consent'), findsNothing);
      expect(map[OnboardingStore.userContextKey], isNull);
      expect(map[OnboardingStore.userConditionsKey], isNull);
      expect(map[OnboardingStore.stepMarkerKey], isNull);
      expect(map[OnboardingStore.hasConsentedKey], isNull);
      // A fresh Get started now starts Consent with empty state.
      await tester.tap(find.text('Get started'));
      await _settle(tester);
      expect(find.text('Privacy & Data Consent'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'positive pin (Get started door): flag PRESENT + same '
        'payload → resume still works at the marked step',
        (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final map = <String, String>{};
      await _pumpApp(tester, session: FakeSessionStore(), map: map);
      map[OnboardingStore.preAccountInProgressKey] = 'true';
      map[OnboardingStore.preAccountLastActivityKey] =
          DateTime.now().toIso8601String();
      map[OnboardingStore.userContextKey] = _contextText;
      map[OnboardingStore.userConditionsKey] = '["Asthma"]';
      map[OnboardingStore.hasConsentedKey] = 'true';
      map[OnboardingStore.stepMarkerKey] = '2'; // conditions
      await tester.tap(find.text('Get started'));
      await _settle(tester);
      expect(find.text('Add conditions'), findsOneWidget);
      expect(map[OnboardingStore.userContextKey], _contextText);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'positive pin (cold-start door): flag PRESENT + same '
        'payload → cold start still resumes', (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final map = <String, String>{
        OnboardingStore.preAccountInProgressKey: 'true',
        OnboardingStore.preAccountLastActivityKey:
            DateTime.now().toIso8601String(),
        OnboardingStore.userContextKey: _contextText,
        OnboardingStore.userConditionsKey: '["Asthma"]',
        OnboardingStore.hasConsentedKey: 'true',
        OnboardingStore.stepMarkerKey: '2',
      };
      await _pumpApp(tester, session: FakeSessionStore(), map: map);
      expect(find.text('Add conditions'), findsOneWidget);
      expect(map[OnboardingStore.userContextKey], _contextText);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('gems guard', () {
    testWidgets(
        'pre-account gems Continue with a NULL handoff callback '
        'stays on gems, never membership', (tester) async {
      tester.view.physicalSize = const Size(1440, 3200);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      final map = <String, String>{};
      await tester.pumpWidget(MaterialApp(
        home: OnboardingFlow(
          initialStep: OnboardingStep.gems,
          onboardingStore: _store(map),
          backend: r32.FakeOnboardingBackend(
              sessionStore: FakeSessionStore()),
          healthConnectService: r32.FakeOnboardingHC(),
          preAccount: true,
          // Deliberately NO onPreAccountComplete.
          onComplete: () {},
          onDeclineConsent: () {},
        ),
      ));
      await tester.pump();
      expect(find.text('STREAKS, FREEZES & GEMS'), findsOneWidget);
      await tester.tap(find.text('Got it'));
      await _settle(tester);
      expect(find.text('STREAKS, FREEZES & GEMS'), findsOneWidget);
      expect(find.text('Unlock Tabs Premium'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });
}
