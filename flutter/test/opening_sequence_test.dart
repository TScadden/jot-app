import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/session_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/splash/opening_sequence_screen.dart';

import 'test_helpers.dart';

/// Opening sequence (LAB) — flag-gated front-door clip.
///
/// Covers the package spec: flag-off is a no-op, a signed-in cold
/// start never sees the sequence, the signed-out front door runs
/// poster → clip → handoff → beats 6–7 with working welcome
/// callbacks, tap-to-skip during the native beats, the end-still
/// fallback on init failure AND on init timeout, play-once per
/// process, and the reduced-motion direct render.

class FakeOpeningPlayer implements OpeningPlayer {
  FakeOpeningPlayer({
    this.failInit = false,
    this.manualInit = false,
  });

  final bool failInit;

  /// When true, initialize() waits on [initGate] (a hang, unless the
  /// test completes the gate).
  final bool manualInit;
  final Completer<void> initGate = Completer<void>();

  final List<VoidCallback> _listeners = [];
  bool _completed = false;
  bool played = false;
  bool disposed = false;
  double? volume;

  @override
  bool get isInitialized => true;

  @override
  bool get isCompleted => _completed;

  @override
  Duration get duration => Duration.zero;

  @override
  void addListener(VoidCallback listener) => _listeners.add(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _listeners.remove(listener);

  @override
  Future<void> initialize() async {
    if (failInit) throw StateError('fake init failure');
    if (manualInit) return initGate.future;
  }

  @override
  Future<void> setVolume(double v) async {
    volume = v;
  }

  @override
  Future<void> play() async {
    played = true;
  }

  @override
  Widget buildVideo(BuildContext context) =>
      const SizedBox(key: ValueKey('fake-opening-video'));

  @override
  void dispose() {
    disposed = true;
  }

  void complete() {
    _completed = true;
    for (final l in List.of(_listeners)) {
      l();
    }
  }
}

class FakeBackend extends TabsBackend {
  FakeBackend({super.sessionStore});

  @override
  void invalidateSyncPull() {}

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => null;
}

class FakeHC extends HealthConnectService {
  @override
  Future<bool> hasPersistedConnection() async => false;

  @override
  Future<HealthConnectStatus> getStatus() async =>
      HealthConnectStatus.notConnected;

  @override
  Future<Set<String>> requestPermissions() async => const {};

  @override
  Future<void> openHealthConnectSettings() async {}
}

OnboardingStore fakeOnboardingStore(Map<String, String> map) =>
    OnboardingStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

MockClient mockWeatherClient() {
  return MockClient((request) async {
    if (request.url.host == 'ipinfo.io') {
      return http.Response(
          '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
          200);
    }
    if (request.url.host == 'api.open-meteo.com') {
      return http.Response(
          '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
          200);
    }
    return http.Response('not found', 404);
  });
}

Future<void> pumpFlow(
  WidgetTester tester, {
  required SessionStore session,
  bool? openingEnabled,
  OpeningPlayerFactory? playerFactory,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: AppFlow(
      authApi: AuthApiClient(
          client: MockClient((_) async => http.Response('nf', 404))),
      sessionStore: session,
      onboardingStore: fakeOnboardingStore({}),
      tabsBackend: FakeBackend(sessionStore: session),
      weatherApi: WeatherApiClient(client: mockWeatherClient()),
      healthConnectService: FakeHC(),
      notificationService: FakeReminderNotificationService(),
      openingSequenceEnabled: openingEnabled,
      openingPlayerFactory: playerFactory,
    ),
  ));
}

/// Front door, flag on, fake player installed. Returns the fake
/// after the signed-out resolution has started playback.
Future<FakeOpeningPlayer> pumpFrontDoor(
  WidgetTester tester, {
  FakeOpeningPlayer? player,
}) async {
  final fake = player ?? FakeOpeningPlayer();
  await pumpFlow(
    tester,
    session: FakeSessionStore(),
    openingEnabled: true,
    playerFactory: () => fake,
  );
  await tester.pump();
  await tester.pump();
  return fake;
}

/// Clip end → handoff (400ms) → beat 6 (650ms) → beat 7 (550ms) →
/// the post-frame completion callback.
Future<void> driveToDone(
    WidgetTester tester, FakeOpeningPlayer fake) async {
  fake.complete();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump(const Duration(milliseconds: 600));
  await tester.pump();
}

void expectEndStateLive(WidgetTester tester) {
  expect(find.text('Your health, all in one place'), findsOneWidget);
  final getStarted = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Get started'));
  expect(getStarted.onPressed, isNotNull,
      reason: 'Get started must be live at the end state');
  final haveAccount = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'I have an account'));
  expect(haveAccount.onPressed, isNotNull,
      reason: 'I have an account must be live at the end state');
}

void main() {
  group('opening sequence (LAB)', () {
    test('compile-time flag defaults to false', () {
      expect(tabsOpeningSequenceEnabled, isFalse);
    });

    testWidgets('flag off: signed-out cold start is the unchanged '
        'splash + welcome path', (tester) async {
      await pumpFlow(tester, session: FakeSessionStore());
      await tester.pump(const Duration(milliseconds: 1850));
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
      expect(find.byType(OpeningSequenceScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.text('Register'), findsOneWidget);
    });

    testWidgets('signed-in cold start with flag on: sequence never '
        'appears and routing is not delayed', (tester) async {
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'founder@tabs.app';
      var factoryCalls = 0;
      await pumpFlow(
        tester,
        session: session,
        openingEnabled: true,
        playerFactory: () {
          factoryCalls++;
          return FakeOpeningPlayer();
        },
      );
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(OpeningSequenceScreen), findsNothing);
      expect(find.byType(MainShell), findsOneWidget);
      expect(factoryCalls, 0,
          reason: 'no player is ever created for a signed-in start');
      // Flush one-shot start-up timers before teardown.
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('front door: poster first, muted clip plays, end '
        'state reachable, Get started fires onRegister',
        (tester) async {
      final fake = FakeOpeningPlayer(manualInit: true);
      await pumpFlow(
        tester,
        session: FakeSessionStore(),
        openingEnabled: true,
        playerFactory: () => fake,
      );
      await tester.pump();
      // Phase A: the poster is the first thing on the door, and
      // playback has not begun (init is still gated).
      expect(find.byType(OpeningSequenceScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('opening_poster')),
          findsOneWidget);
      expect(fake.played, isFalse);
      // Signed-out resolution + init completes → clip fades in,
      // muted, and plays.
      fake.initGate.complete();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(fake.played, isTrue);
      expect(fake.volume, 0,
          reason: 'the generated audio track must stay muted');
      expect(find.byKey(const ValueKey('fake-opening-video')),
          findsOneWidget);
      await driveToDone(tester, fake);
      expectEndStateLive(tester);
      // The finished sequence stays as the welcome surface.
      expect(find.byType(OpeningSequenceScreen), findsOneWidget);
      await tester.tap(find.text('Get started'));
      await tester.pump();
      expect(find.byType(LoginScreen), findsOneWidget);
    });

    testWidgets('front door: I have an account fires onLogin',
        (tester) async {
      final fake = await pumpFrontDoor(tester);
      await driveToDone(tester, fake);
      expectEndStateLive(tester);
      await tester.tap(find.text('I have an account'));
      await tester.pump();
      expect(find.byType(LoginScreen), findsOneWidget);
      // Flush AppFlow's splash timer before teardown.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('tap during the native beats jumps to the end '
        'state instantly', (tester) async {
      final fake = await pumpFrontDoor(tester);
      fake.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      // Now in beat 6 (rise). A tap finishes everything at once.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(400, 200));
      await tester.pump();
      expectEndStateLive(tester);
      // Flush AppFlow's splash timer before teardown.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('player init failure: end-still fallback reaches '
        'the same end state', (tester) async {
      final fake =
          await pumpFrontDoor(tester, player: FakeOpeningPlayer(failInit: true));
      await tester.pump();
      await tester.pump();
      // Fallback: the end still stands in for the clip.
      expect(find.byKey(const ValueKey('opening_end_still')),
          findsOneWidget);
      expect(fake.played, isFalse);
      await tester.pump(const Duration(milliseconds: 950));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expectEndStateLive(tester);
    });

    testWidgets('player init timeout (~700ms): end-still fallback '
        'reaches the same end state', (tester) async {
      final fake = await pumpFrontDoor(
          tester, player: FakeOpeningPlayer(manualInit: true));
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pump();
      expect(find.byKey(const ValueKey('opening_end_still')),
          findsOneWidget);
      expect(fake.played, isFalse);
      await tester.pump(const Duration(milliseconds: 950));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expectEndStateLive(tester);
    });

    testWidgets('plays once: returning to welcome in-process does '
        'not replay it', (tester) async {
      var factoryCalls = 0;
      final fake = FakeOpeningPlayer();
      await pumpFlow(
        tester,
        session: FakeSessionStore(),
        openingEnabled: true,
        playerFactory: () {
          factoryCalls++;
          return fake;
        },
      );
      await tester.pump();
      await tester.pump();
      await driveToDone(tester, fake);
      expectEndStateLive(tester);
      // Let AppFlow's legacy splash timer + exit fully elapse so
      // its overlay can never sit over the login screen below
      // (stepped pumps: the exit ticker advances per frame).
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      // Leave the front door (Get started → login) and come back.
      await tester.tap(find.text('Get started'));
      await tester.pump();
      expect(find.byType(LoginScreen), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      expect(find.byType(OpeningSequenceScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.text('Get started'), findsNothing);
      expect(factoryCalls, 1,
          reason: 'the sequence must not be rebuilt on return');
    });

    testWidgets('reduced motion: straight to the end state, no '
        'player is created', (tester) async {
      var factoryCalls = 0;
      var registerCalls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(disableAnimations: true),
            child: OpeningSequenceScreen(
              onRegister: () => registerCalls++,
              onLogin: () {},
              playerFactory: () {
                factoryCalls++;
                return FakeOpeningPlayer();
              },
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(factoryCalls, 0);
      expect(find.byKey(const ValueKey('opening_poster')),
          findsNothing);
      expectEndStateLive(tester);
      await tester.tap(find.text('Get started'));
      expect(registerCalls, 1);
    });
  });
}
