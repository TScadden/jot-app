import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';
import 'package:tabs_lab/src/features/onboarding/conditions_screen.dart';
import 'package:tabs_lab/src/features/onboarding/consent_screen.dart';
import 'package:tabs_lab/src/features/onboarding/consultation_intro_screen.dart';
import 'package:tabs_lab/src/features/onboarding/notification_onboarding_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_connections_screen.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_flow.dart';
import 'package:tabs_lab/src/features/onboarding/profile_setup_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';

import 'onboarding_r32_test.dart' as r32;
import 'test_helpers.dart';

/// Founder fix (Oct 27, 2026) — the Settings system-back fix
/// (settings_system_back_test.dart) extended to the two pre-shell
/// flows. Both flows are stage/step body swaps inside AppFlow's
/// single root route, so without interception the Navigator had
/// nothing to pop on Android back and the gesture exited the app,
/// while the in-app arrows behaved correctly:
///
/// - OnboardingFlow: system back now runs the SAME `_stepBack()`
///   action as every step's back arrow (same destination per step).
///   On consent — the first step, whose arrow is a deliberate
///   no-op — the pop is allowed through so the gesture exits
///   instead of trapping the user.
/// - Login stage (AppFlow's _FlowStage machine): LoginScreen is
///   wrapped in a PopScope that runs the SAME onBack callback as
///   its header arrow — AppFlow's stage flip back to Welcome.
///   Register mode is a mode of this same stage/screen, so it
///   inherits the behavior. The Welcome stage is untouched:
///   system back there still exits.
///
/// These tests host each flow in a route pushed over a launcher
/// page so a wrongful pop is observable (the launcher would
/// reappear), and drive a REAL system back via
/// [WidgetsBinding.handlePopRoute] — the entry point the Android
/// back gesture funnels into. Pumps are bounded (never
/// pumpAndSettle) because ProfileSetupScreen runs a 3s prompt
/// rotation loop that never settles.

/// One Android system-back press, delivered the way the OS
/// delivers it, followed by enough frames for a step/stage swap
/// or a route-pop transition to land.
Future<void> systemBack(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 800));
  await tester.pump();
}

/// Pushes an [OnboardingFlow] starting at [initialStep] over a
/// minimal launcher page.
Future<void> pumpPushedFlow(
  WidgetTester tester, {
  required OnboardingStep initialStep,
}) async {
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => OnboardingFlow(
                  initialStep: initialStep,
                  onboardingStore: r32.fakeOnboardingStore({}),
                  backend: r32.FakeOnboardingBackend(),
                  healthConnectService: r32.FakeOnboardingHC(),
                  notificationService: FakeReminderNotificationService(),
                  onComplete: () {},
                  onDeclineConsent: () {},
                ),
              ),
            ),
            child: const Text('OPEN FLOW'),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.tap(find.text('OPEN FLOW'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// Pushes the real [AppFlow] (the _FlowStage machine) over a
/// minimal launcher page and fast-forwards past the splash
/// (650 entry + 1200 hold + 650 exit), landing on Welcome with no
/// stored session.
Future<void> pumpPushedAppFlow(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 3400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final session = FakeSessionStore();
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AppFlow(
                  authApi: AuthApiClient(
                      client: MockClient(
                          (_) async => http.Response('nf', 404))),
                  sessionStore: session,
                  onboardingStore: r32.fakeOnboardingStore({}),
                  tabsBackend:
                      r32.FakeOnboardingBackend(sessionStore: session),
                  weatherApi: WeatherApiClient(
                      client: MockClient(
                          (_) async => http.Response('nf', 404))),
                  healthConnectService: r32.FakeOnboardingHC(),
                  notificationService: FakeReminderNotificationService(),
                ),
              ),
            ),
            child: const Text('OPEN APP'),
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
  await tester.tap(find.text('OPEN APP'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1850));
  await tester.pump(const Duration(milliseconds: 650));
  await tester.pump();
}

void expectFlowAlive(WidgetTester tester) {
  expect(find.byType(OnboardingFlow), findsOneWidget,
      reason: 'the onboarding route must still be on top');
  expect(find.text('OPEN FLOW'), findsNothing,
      reason: 'the route under the flow must not be exposed');
}

void expectAppFlowAlive(WidgetTester tester) {
  expect(find.byType(AppFlow), findsOneWidget,
      reason: 'the AppFlow route must still be on top');
  expect(find.text('OPEN APP'), findsNothing,
      reason: 'the route under AppFlow must not be exposed');
}

void main() {
  group('Onboarding system back (Oct 27, 2026 founder fix)', () {
    testWidgets(
        'profile setup: system back steps back to consultation intro, '
        'exactly like the arrow', (tester) async {
      await pumpPushedFlow(tester, initialStep: OnboardingStep.profileSetup);
      expect(find.byType(ProfileSetupScreen), findsOneWidget);

      await systemBack(tester);

      expectFlowAlive(tester);
      expect(find.byType(ConsultationIntroScreen), findsOneWidget);
      expect(find.text("Let's get you set up!"), findsOneWidget);
      // ProfileSetupScreen's 3s prompt-rotation loop is suspended in
      // a Future.delayed when the step is disposed by the step back;
      // run fake time past it so it observes disposal and exits
      // instead of tripping the pending-timer invariant at test end.
      await tester.pump(const Duration(seconds: 4));
    });

    testWidgets(
        'connections: system back walks notifications, then conditions',
        (tester) async {
      await pumpPushedFlow(tester, initialStep: OnboardingStep.connections);
      expect(find.byType(OnboardingConnectionsScreen), findsOneWidget);
      expect(find.text('Connect Health Data'), findsWidgets);

      await systemBack(tester);
      expectFlowAlive(tester);
      expect(find.byType(NotificationOnboardingScreen), findsOneWidget);

      await systemBack(tester);
      expectFlowAlive(tester);
      expect(find.byType(OnboardingConditionsScreen), findsOneWidget);
      expect(find.text('Add conditions'), findsOneWidget);
    });

    testWidgets(
        'consent (first step): system back pops the flow — the exit '
        'path, not a trap', (tester) async {
      await pumpPushedFlow(tester, initialStep: OnboardingStep.consent);
      expect(find.byType(OnboardingConsentScreen), findsOneWidget);
      expect(find.text('Privacy & Data Consent'), findsOneWidget);

      await systemBack(tester);

      expect(find.byType(OnboardingFlow), findsNothing,
          reason: 'the flow route should have been popped');
      expect(find.text('OPEN FLOW'), findsOneWidget);
    });
  });

  group('Pre-shell login stage system back (Oct 27, 2026 founder fix)',
      () {
    testWidgets('login stage: system back returns to the Welcome stage',
        (tester) async {
      await pumpPushedAppFlow(tester);
      expect(find.byType(WelcomeScreen), findsOneWidget);

      await tester.tap(find.text('Log In'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expectAppFlowAlive(tester);
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Welcome Back'), findsOneWidget);

      await systemBack(tester);

      expectAppFlowAlive(tester);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets(
        'register mode is the same login stage: system back returns '
        'to Welcome', (tester) async {
      await pumpPushedAppFlow(tester);
      await tester.tap(find.text('Register'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('Create Your Account'), findsOneWidget);

      await systemBack(tester);

      expectAppFlowAlive(tester);
      expect(find.byType(LoginScreen), findsNothing);
      expect(find.byType(WelcomeScreen), findsOneWidget);
    });

    testWidgets('welcome stage: system back keeps the default exit',
        (tester) async {
      await pumpPushedAppFlow(tester);
      expectAppFlowAlive(tester);
      expect(find.byType(WelcomeScreen), findsOneWidget);

      await systemBack(tester);

      expect(find.byType(AppFlow), findsNothing,
          reason: 'the AppFlow route should have been popped');
      expect(find.text('OPEN APP'), findsOneWidget);
    });
  });
}
