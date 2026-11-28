import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/auth/email_verification_screen.dart';
import 'package:tabs_lab/src/features/billing/billing_panel.dart';
import 'package:tabs_lab/src/features/onboarding/onboarding_flow.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';

import 'onboarding_r32_test.dart' as r32;
import 'test_helpers.dart';

/// VC 100134 Package C — AppFlow-level email verification flow:
/// entry routing (register / login / restore), verify-success
/// routing per origin, grandfathering, fail-open restore, escape,
/// and session expiry mid-gate.

const _email = 'pending@tabs.app';

class FakeFlowBackend extends TabsBackend {
  Map<String, dynamic>? pullBody;
  VerifyEmailOutcome verifyOutcome = const VerifyEmailSuccess();
  int verifyCalls = 0;
  String? lastCode;

  FakeFlowBackend({required super.sessionStore});

  @override
  void invalidateSyncPull() {}

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => pullBody;

  @override
  Future<VerifyEmailOutcome> verifyEmailCode(String code) async {
    verifyCalls++;
    lastCode = code;
    return verifyOutcome;
  }

  @override
  Future<ResendVerificationOutcome> resendVerificationCode() async =>
      const ResendVerificationSent();
}

/// A store whose verified-flag read throws (fail-open case).
class _VerifiedThrowingStore extends FakeSessionStore {
  @override
  Future<bool?> readEmailVerified() async =>
      throw StateError('fake verified read failure');
}

OnboardingStore _fakeOnboardingStore(Map<String, String> map) =>
    OnboardingStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

MockClient _weather() => MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
            200);
      }
      return http.Response(
          '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
          200);
    });

AuthApiClient _authApi({
  Map<String, dynamic>? registerBody,
  Map<String, dynamic>? loginBody,
}) =>
    AuthApiClient(
      client: MockClient((request) async {
        if (request.url.path == '/api/auth/register' &&
            registerBody != null) {
          return http.Response(jsonEncode(registerBody), 200);
        }
        if (request.url.path == '/api/auth/login' && loginBody != null) {
          return http.Response(jsonEncode(loginBody), 200);
        }
        return http.Response('nf', 404);
      }),
    );

Future<FakeFlowBackend> pumpFlow(
  WidgetTester tester, {
  required FakeSessionStore session,
  Map<String, String>? onboardingMap,
  AuthApiClient? authApi,
}) async {
  final backend = FakeFlowBackend(sessionStore: session);
  await tester.pumpWidget(MaterialApp(
    home: AppFlow(
      authApi: authApi ?? _authApi(),
      sessionStore: session,
      onboardingStore: _fakeOnboardingStore(onboardingMap ?? {}),
      tabsBackend: backend,
      weatherApi: WeatherApiClient(client: _weather()),
      healthConnectService: r32.FakeOnboardingHC(),
      notificationService: FakeReminderNotificationService(),
    ),
  ));
  // Past the splash (entry 650 + hold 1200 + exit 650).
  await tester.pump(const Duration(milliseconds: 1850));
  await tester.pump(const Duration(milliseconds: 650));
  await tester.pump();
  return backend;
}

Future<void> driveRegister(WidgetTester tester) async {
  // Plain register (NOT the pre-account value flow) is now
  // reached via Log In -> "Don't have an account? Sign Up".
  await tester.tap(find.text('Log In'));
  await tester.pumpAndSettle();
  await tester.tap(find.text("Don't have an account? Sign Up"));
  await tester.pumpAndSettle();
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), _email);
  await tester.enterText(fields.at(1), 'secret');
  await tester.tap(find.text('I confirm I am 13 or older.'));
  await tester.pump();
  await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

Future<void> driveLogin(WidgetTester tester) async {
  await tester.tap(find.text('Log In'));
  await tester.pumpAndSettle();
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), _email);
  await tester.enterText(fields.at(1), 'secret');
  await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

Future<void> submitCode(WidgetTester tester) async {
  // Six-box UI: pasting the full code into the first box fills
  // all six boxes in order — and since VC 100136 that completion
  // AUTO-SUBMITS (no Verify tap; by the time the verify resolves
  // the stage has already changed and the button is gone).
  await tester.enterText(
      find.byKey(const ValueKey('verify_digit_0')), '001234');
  await tester.pump();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

/// Leave the verify stage via its escape so the screen (and its
/// countdown timer) is disposed before teardown.
Future<void> escapeToWelcome(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('verify_escape')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

Map<String, dynamic> _authBody({bool? verified}) {
  final body = <String, dynamic>{
    'token': 'tok',
    'refreshToken': 'ref',
    'email': _email,
  };
  if (verified != null) body['emailVerified'] = verified;
  return body;
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);
  setUp(() => TabsBackend.onSessionExpired = null);
  tearDown(() => TabsBackend.onSessionExpired = null);

  testWidgets('register with emailVerified:false → verify stage; '
      'neither onboarding nor home is reachable', (tester) async {
    final session = FakeSessionStore();
    await pumpFlow(
      tester,
      session: session,
      authApi: _authApi(registerBody: _authBody(verified: false)),
    );
    await driveRegister(tester);
    expect(find.byType(EmailVerificationScreen), findsOneWidget);
    expect(find.byType(OnboardingFlow), findsNothing);
    expect(find.byType(MainShell), findsNothing);
    expect(session.emailVerified, isFalse);
    await escapeToWelcome(tester);
    expect(find.byType(WelcomeScreen), findsOneWidget);
  });

  testWidgets('register → verify success → onboarding at consent, '
      'persisted flag now true, code sent as "001234"',
      (tester) async {
    final session = FakeSessionStore();
    final map = <String, String>{};
    final backend = await pumpFlow(
      tester,
      session: session,
      onboardingMap: map,
      authApi: _authApi(registerBody: _authBody(verified: false)),
    );
    await driveRegister(tester);
    expect(find.byType(EmailVerificationScreen), findsOneWidget);
    await submitCode(tester);
    expect(backend.verifyCalls, 1);
    expect(backend.lastCode, '001234');
    expect(find.byType(EmailVerificationScreen), findsNothing);
    expect(find.byType(OnboardingFlow), findsOneWidget);
    expect(find.text('Privacy & Data Consent'), findsOneWidget);
    expect(session.emailVerified, isTrue);
    // The all-false flags stamped at register time are intact.
    expect(map['has_consented'], 'false');
    expect(map['onboarding_complete'], 'false');
  });

  testWidgets('B1 regression: register unverified → verify success '
      '→ walk to Membership shows the purchase/trial panel, NOT '
      'VerifyEmailGate', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final session = FakeSessionStore();
    final map = <String, String>{};
    await pumpFlow(
      tester,
      session: session,
      onboardingMap: map,
      authApi: _authApi(registerBody: _authBody(verified: false)),
    );
    await driveRegister(tester);
    expect(find.byType(EmailVerificationScreen), findsOneWidget);
    await submitCode(tester);
    expect(find.byType(OnboardingFlow), findsOneWidget);
    expect(session.emailVerified, isTrue);

    // Consent.
    await tester.tap(find.widgetWithText(FilledButton, 'I consent'));
    await tester.pumpAndSettle();
    // Profile (unskippable; Next is gated at 10 words).
    expect(find.text("Let's get you set up!"), findsOneWidget);
    await tester.enterText(
      find.byType(TextField),
      'one two three four five six seven eight nine ten eleven',
    );
    await tester.pump();
    await tester.ensureVisible(find.text('Next Step'));
    await tester.tap(find.text('Next Step'));
    await tester.pumpAndSettle();
    // Conditions (selection optional; step is skippable).
    expect(find.text('Add conditions'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    // Connections: skip goes through the warning dialog first.
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(find.text('Skip Health Connect?'), findsOneWidget);
    await tester.tap(find.text('Skip anyway'));
    await tester.pumpAndSettle();
    // Gems.
    expect(find.text('STREAKS, FREEZES & GEMS'), findsOneWidget);
    await tester.tap(find.text('Got it'));
    await tester.pumpAndSettle();

    // Membership: the user who verified when prompted must reach
    // the purchase/trial panel in THIS session. Before the fix,
    // _onVerificationSuccess persisted the verified flag but never
    // updated the in-memory session field the gate reads, so
    // VerifyEmailGate reappeared here and tapping through it
    // looped (verify → resume at Membership → gate again).
    expect(find.text('Unlock Tabs Premium'), findsOneWidget);
    expect(find.byType(VerifyEmailGate), findsNothing);
    expect(
        find.byKey(const ValueKey('verify_email_gate')), findsNothing);
    expect(find.text('Monthly Plan'), findsOneWidget);
    expect(find.text(r'$5.99 / month'), findsOneWidget);
    expect(find.text('Start 7-Day Free Trial'), findsOneWidget);
  });

  testWidgets('login with emailVerified:false → verify stage → '
      'verify success → resolving → home', (tester) async {
    final session = FakeSessionStore();
    final backend = await pumpFlow(
      tester,
      session: session,
      authApi: _authApi(loginBody: _authBody(verified: false)),
    );
    backend.pullBody = {
      'entries': [],
      'profile': <String, dynamic>{},
    };
    await driveLogin(tester);
    expect(find.byType(EmailVerificationScreen), findsOneWidget);
    await submitCode(tester);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byType(MainShell), findsOneWidget);
    expect(session.emailVerified, isTrue);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('verified login (explicit true) routes home exactly '
      'as today — no verify stage', (tester) async {
    final session = FakeSessionStore();
    final backend = await pumpFlow(
      tester,
      session: session,
      authApi: _authApi(loginBody: _authBody(verified: true)),
    );
    backend.pullBody = {
      'entries': [],
      'profile': <String, dynamic>{},
    };
    await driveLogin(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EmailVerificationScreen), findsNothing);
    expect(find.byType(MainShell), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('GRANDFATHERING: login payload with the flag ABSENT '
      'routes home exactly as today', (tester) async {
    final session = FakeSessionStore();
    final backend = await pumpFlow(
      tester,
      session: session,
      authApi: _authApi(loginBody: _authBody()),
    );
    backend.pullBody = {
      'entries': [],
      'profile': <String, dynamic>{},
    };
    await driveLogin(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(EmailVerificationScreen), findsNothing);
    expect(find.byType(MainShell), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('register payload with the flag ABSENT routes into '
      'onboarding exactly as today', (tester) async {
    final session = FakeSessionStore();
    await pumpFlow(
      tester,
      session: session,
      authApi: _authApi(registerBody: _authBody()),
    );
    await driveRegister(tester);
    expect(find.byType(EmailVerificationScreen), findsNothing);
    expect(find.text('Privacy & Data Consent'), findsOneWidget);
  });

  testWidgets('restore mid-verification: seeded unverified session '
      'lands on the verify stage; verify success resumes '
      'onboarding at consent (flags were stamped at register)',
      (tester) async {
    final session = FakeSessionStore()
      ..token = 'tok'
      ..refreshToken = 'ref'
      ..email = _email
      ..emailVerified = false;
    final map = <String, String>{
      'has_consented': 'false',
      'intro_consultation_seen': 'false',
      'onboarding_complete': 'false',
      'onboarding_owner_email': _email,
    };
    await pumpFlow(tester, session: session, onboardingMap: map);
    expect(find.byType(EmailVerificationScreen), findsOneWidget);
    expect(find.byType(MainShell), findsNothing);
    expect(find.byType(WelcomeScreen), findsNothing);
    await submitCode(tester);
    expect(find.byType(OnboardingFlow), findsOneWidget);
    expect(find.text('Privacy & Data Consent'), findsOneWidget);
    expect(session.emailVerified, isTrue);
  });

  testWidgets('restore mid-verification with completed onboarding: '
      'verify success lands home', (tester) async {
    final session = FakeSessionStore()
      ..token = 'tok'
      ..refreshToken = 'ref'
      ..email = _email
      ..emailVerified = false;
    final map = <String, String>{
      'has_consented': 'true',
      'intro_consultation_seen': 'true',
      'onboarding_complete': 'true',
      'onboarding_owner_email': _email,
    };
    await pumpFlow(tester, session: session, onboardingMap: map);
    expect(find.byType(EmailVerificationScreen), findsOneWidget);
    await submitCode(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MainShell), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('restore, legacy session (no verified key at all) '
      'lands home — the grandfathering invariant', (tester) async {
    final session = FakeSessionStore()
      ..token = 'tok'
      ..refreshToken = 'ref'
      ..email = _email;
    await pumpFlow(tester, session: session);
    expect(session.emailVerified, isNull);
    expect(find.byType(EmailVerificationScreen), findsNothing);
    expect(find.byType(MainShell), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('restore fail-open: a throwing verified-flag read '
      'lands home, never the code screen', (tester) async {
    final session = _VerifiedThrowingStore()
      ..token = 'tok'
      ..refreshToken = 'ref'
      ..email = _email
      ..emailVerified = false;
    await pumpFlow(tester, session: session);
    expect(find.byType(EmailVerificationScreen), findsNothing);
    expect(find.byType(MainShell), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('escape end-to-end: from a restore-seeded verify '
      'stage, escape lands welcome with the store fully cleared',
      (tester) async {
    final session = FakeSessionStore()
      ..token = 'tok'
      ..refreshToken = 'ref'
      ..email = _email
      ..emailVerified = false;
    await pumpFlow(tester, session: session);
    expect(find.byType(EmailVerificationScreen), findsOneWidget);
    await escapeToWelcome(tester);
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(session.token, isNull);
    expect(session.refreshToken, isNull);
    expect(session.email, isNull);
    expect(session.emailVerified, isNull);
  });

  testWidgets('session expiry mid-gate routes back to welcome',
      (tester) async {
    final session = FakeSessionStore()
      ..token = 'tok'
      ..refreshToken = 'ref'
      ..email = _email
      ..emailVerified = false;
    await pumpFlow(tester, session: session);
    expect(find.byType(EmailVerificationScreen), findsOneWidget);
    // The backend wrapper clears the store on a definitive refresh
    // failure BEFORE firing this callback (pinned in the backend
    // suites); here we pin the AppFlow half from the verify stage.
    await session.clear();
    TabsBackend.onSessionExpired?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(EmailVerificationScreen), findsNothing);
    expect(find.byType(WelcomeScreen), findsOneWidget);
  });
}
