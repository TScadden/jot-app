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
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'test_helpers.dart';

/// Opening sequence (LAB) — flag-gated front-door overlay.
///
/// Landing (founder-directed, Oct 29, 2026): the sequence is an
/// opaque overlay above the REAL WelcomeScreen — clip, center
/// lockup resolve (real ic_tabs_note mark + native wordmark), rise
/// into the welcome header's own position, reveal, overlay removed.
/// There is NO invented welcome content: the end-state assertions
/// target the real screen, and the deleted storyboard strings are
/// asserted ABSENT.

class FakeOpeningPlayer implements OpeningPlayer {
  FakeOpeningPlayer({
    this.failInit = false,
    this.manualInit = false,
  });

  final bool failInit;

  /// When true, initialize() waits on [initGate] (a hang, unless
  /// the test completes the gate).
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
  bool disableAnimations = false,
}) async {
  final flow = AppFlow(
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
  );
  await tester.pumpWidget(MaterialApp(
    home: disableAnimations
        ? Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: true),
              child: flow,
            ),
          )
        : flow,
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

/// Clip end → resolve (200ms) → rise (650ms) → reveal (500ms) →
/// the post-frame completion callback removes the overlay.
Future<void> driveToDone(
    WidgetTester tester, FakeOpeningPlayer fake) async {
  fake.complete();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
  await tester.pump(const Duration(milliseconds: 700));
  await tester.pump(const Duration(milliseconds: 550));
  await tester.pump();
  await tester.pump();
}

/// The end state is the REAL WelcomeScreen, live — and none of the
/// deleted storyboard landing exists anywhere in the flow.
void expectRealWelcome(WidgetTester tester) {
  expect(find.byType(OpeningSequenceScreen), findsNothing,
      reason: 'the overlay must be removed at the end state');
  expect(find.byType(WelcomeScreen), findsOneWidget);
  expect(find.text('Notes that build'), findsOneWidget);
  expect(find.text('Register'), findsOneWidget);
  expect(find.text('Log In'), findsOneWidget);
  expect(find.text('Track symptoms and treatments'), findsOneWidget);
  expect(find.text('Reach your goals'), findsOneWidget);
  expect(find.text('Learn patterns and get insights'), findsOneWidget);
  // Negative assertions: the invented beat-7 landing is deleted.
  expect(find.text('Your health, all in one place'), findsNothing);
  expect(find.text('Get started'), findsNothing);
  expect(find.text('I have an account'), findsNothing);
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

    testWidgets('front door: poster first, muted clip plays, '
        'lockup resolves with the real mark, reveal lands on the '
        'real WelcomeScreen', (tester) async {
      final fake = FakeOpeningPlayer(manualInit: true);
      await pumpFlow(
        tester,
        session: FakeSessionStore(),
        openingEnabled: true,
        playerFactory: () => fake,
      );
      await tester.pump();
      // Phase A: the poster is the first thing on the door, and
      // playback has not begun (init is still gated). The real
      // WelcomeScreen already stands underneath the overlay.
      expect(find.byType(OpeningSequenceScreen), findsOneWidget);
      expect(find.byType(WelcomeScreen), findsOneWidget);
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
          reason: 'the player must stay hard-muted');
      expect(find.byKey(const ValueKey('fake-opening-video')),
          findsOneWidget);
      // Resolve: mid-crossfade, the overlay lockup carries the
      // REAL mark (a second ic_tabs_note image, over the real
      // header's own) and every "Tabs" text on screen — overlay
      // and real header alike — is native, NotelPrimary, w900.
      fake.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        find.byWidgetPredicate((w) =>
            w is Image &&
            w.image is AssetImage &&
            (w.image as AssetImage).assetName ==
                'assets/images/ic_tabs_note.png'),
        findsNWidgets(2),
      );
      final wordmarks = tester.widgetList<Text>(find.text('Tabs'));
      expect(wordmarks.length, 2);
      for (final w in wordmarks) {
        expect(w.style?.color, NotelColors.primary);
        expect(w.style?.fontWeight, FontWeight.w900);
      }
      // Rise + reveal finish the landing.
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pump();
      await tester.pump();
      expectRealWelcome(tester);
      // The real screen is live: Register drives AppFlow's
      // existing _goLogin path.
      await tester.tap(find.text('Register'));
      await tester.pump();
      expect(find.byType(LoginScreen), findsOneWidget);
      // Flush AppFlow's splash timer before teardown.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('front door: Log In on the revealed WelcomeScreen '
        'fires the existing login path', (tester) async {
      final fake = await pumpFrontDoor(tester);
      await driveToDone(tester, fake);
      expectRealWelcome(tester);
      await tester.tap(find.text('Log In'));
      await tester.pump();
      expect(find.byType(LoginScreen), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('tap during the native phases snaps the lockup '
        'home and completes the reveal instantly', (tester) async {
      final fake = await pumpFrontDoor(tester);
      fake.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      // Now rising. A tap finishes everything at once.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(400, 200));
      await tester.pump();
      await tester.pump();
      expectRealWelcome(tester);
      await tester.tap(find.text('Register'));
      await tester.pump();
      expect(find.byType(LoginScreen), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('player init failure: poster fallback reaches '
        'the same real WelcomeScreen', (tester) async {
      final fake =
          await pumpFrontDoor(tester, player: FakeOpeningPlayer(failInit: true));
      await tester.pump();
      await tester.pump();
      // Fallback holds the POSTER (frame 0) — never an end frame.
      expect(find.byKey(const ValueKey('opening_poster')),
          findsOneWidget);
      expect(fake.played, isFalse);
      await tester.pump(const Duration(milliseconds: 950));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pump();
      expectRealWelcome(tester);
    });

    testWidgets('player init timeout (~700ms): poster fallback '
        'reaches the same real WelcomeScreen', (tester) async {
      final fake = await pumpFrontDoor(
          tester, player: FakeOpeningPlayer(manualInit: true));
      await tester.pump(const Duration(milliseconds: 750));
      await tester.pump();
      expect(find.byKey(const ValueKey('opening_poster')),
          findsOneWidget);
      expect(fake.played, isFalse);
      await tester.pump(const Duration(milliseconds: 950));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(milliseconds: 550));
      await tester.pump();
      expectRealWelcome(tester);
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
      expectRealWelcome(tester);
      // Leave the front door (Register → login) and come back.
      await tester.tap(find.text('Register'));
      await tester.pump();
      expect(find.byType(LoginScreen), findsOneWidget);
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      expect(find.byType(OpeningSequenceScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(factoryCalls, 1,
          reason: 'the sequence must not be rebuilt on return');
      // Flush AppFlow's splash timer before teardown.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('reduced motion: no overlay at all, straight to '
        'the real WelcomeScreen, no player created', (tester) async {
      var factoryCalls = 0;
      await pumpFlow(
        tester,
        session: FakeSessionStore(),
        openingEnabled: true,
        disableAnimations: true,
        playerFactory: () {
          factoryCalls++;
          return FakeOpeningPlayer();
        },
      );
      await tester.pump();
      await tester.pump();
      expect(factoryCalls, 0);
      expect(find.byKey(const ValueKey('opening_poster')),
          findsNothing);
      expectRealWelcome(tester);
      // Flush AppFlow's splash timer before teardown.
      await tester.pump(const Duration(seconds: 2));
    });
  });
}
