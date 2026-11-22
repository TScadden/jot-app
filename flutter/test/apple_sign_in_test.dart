import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/apple_sign_in_service.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';

import 'test_helpers.dart';

/// Sign in with Apple — fake [AppleSignInService]: returns a canned
/// credential or throws a canned [AppleSignInOutcome], and counts
/// calls so tests can prove sign-in was (or was not) launched. Never
/// touches the real plugin.
class FakeAppleSignInService extends AppleSignInService {
  AppleCredential credential = const AppleCredential(
    idToken: 'fake-identity-token',
    givenName: 'Jane',
    familyName: 'Appleseed',
  );
  AppleSignInOutcome? outcomeToThrow;
  int calls = 0;

  @override
  Future<AppleCredential> signInForCredential() async {
    calls++;
    final outcome = outcomeToThrow;
    if (outcome != null) throw outcome;
    return credential;
  }
}

/// Fake [AuthApiClient]: records `appleLogin` calls and returns a
/// canned result. The inherited real HTTP client is never used
/// because the entry point is overridden.
class FakeAppleAuthApiClient extends AuthApiClient {
  LoginResult appleResult = const LoginFailure(
    LoginFailureKind.server,
    'unconfigured fake',
  );
  int appleCalls = 0;
  String? lastIdToken;
  bool? lastIsRegisterMode;
  bool? lastAgeConfirmed;
  String? lastGivenName;
  String? lastFamilyName;

  @override
  Future<LoginResult> appleLogin({
    required String idToken,
    required bool isRegisterMode,
    required bool ageConfirmed,
    String? givenName,
    String? familyName,
  }) async {
    appleCalls++;
    lastIdToken = idToken;
    lastIsRegisterMode = isRegisterMode;
    lastAgeConfirmed = ageConfirmed;
    lastGivenName = givenName;
    lastFamilyName = familyName;
    return appleResult;
  }
}

/// testWidgets wrapper that runs the body with the platform
/// overridden to iOS (the Apple button builds only there —
/// login_screen.dart's gate reads defaultTargetPlatform). The
/// override is reset in a finally INSIDE the test body: the test
/// binding verifies foundation debug vars are unset before
/// tearDown callbacks run, so a tearDown reset is too late.
void appleTestWidgets(
    String name, Future<void> Function(WidgetTester tester) body) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

void main() {

  Future<void> tapApple(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pump();
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump();
  }

  appleTestWidgets('iOS render shows the Apple button; Android render '
      'does not', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        initialRegisterMode: false,
        authApi: FakeAppleAuthApiClient(),
        sessionStore: FakeSessionStore(),
        appleSignInService: FakeAppleSignInService(),
      ),
    ));
    expect(
        find.byKey(const ValueKey('sign_in_with_apple_button')),
        findsOneWidget);
    expect(find.text('Sign in with Apple'), findsOneWidget);

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        initialRegisterMode: false,
        authApi: FakeAppleAuthApiClient(),
        sessionStore: FakeSessionStore(),
        appleSignInService: FakeAppleSignInService(),
      ),
    ));
    await tester.pump();
    expect(find.byKey(const ValueKey('sign_in_with_apple_button')),
        findsNothing);
    expect(find.text('Sign in with Apple'), findsNothing);
    // The Google button is unaffected by the Apple gate.
    expect(find.text('Log in with Google'), findsOneWidget);
  });

  appleTestWidgets(
      'login-mode Apple tap: success saves the session and fires '
      'onLoginSuccess with the Apple email', (tester) async {
    final service = FakeAppleSignInService();
    final api = FakeAppleAuthApiClient()
      ..appleResult = const LoginSuccess(
        token: 'tok-apple',
        refreshToken: 'ref-apple',
        userId: 'u-apple',
        email: 'jane@privaterelay.appleid.com',
      );
    final store = FakeSessionStore();
    String? successEmail;
    String? registerEmail;

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        initialRegisterMode: false,
        authApi: api,
        sessionStore: store,
        appleSignInService: service,
        onLoginSuccess: (s) => successEmail = s.email,
        onRegisterSuccess: (s) => registerEmail = s.email,
      ),
    ));

    await tapApple(tester, 'Sign in with Apple');

    expect(service.calls, 1);
    expect(api.appleCalls, 1);
    expect(api.lastIdToken, 'fake-identity-token');
    expect(api.lastIsRegisterMode, isFalse);
    expect(api.lastAgeConfirmed, isFalse);
    // Identical downstream path to password/Google login.
    expect(store.token, 'tok-apple');
    expect(store.refreshToken, 'ref-apple');
    expect(store.email, 'jane@privaterelay.appleid.com');
    expect(successEmail, 'jane@privaterelay.appleid.com');
    expect(store.emailVerified, isTrue);
    // Apple uses onLoginSuccess in BOTH modes — never the register
    // callback.
    expect(registerEmail, isNull);
  });

  appleTestWidgets(
      'register-mode Apple tap (age confirmed): name parts are '
      'forwarded and success STILL fires onLoginSuccess, not '
      'onRegisterSuccess', (tester) async {
    final service = FakeAppleSignInService();
    final api = FakeAppleAuthApiClient()
      ..appleResult = const LoginSuccess(
        token: 'tok-apple',
        refreshToken: 'ref-apple',
        userId: 'u-apple',
        email: 'jane@privaterelay.appleid.com',
      );
    final store = FakeSessionStore();
    String? successEmail;
    String? registerEmail;

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        // Register mode is the default.
        authApi: api,
        sessionStore: store,
        appleSignInService: service,
        onLoginSuccess: (s) => successEmail = s.email,
        onRegisterSuccess: (s) => registerEmail = s.email,
      ),
    ));
    expect(find.text('Sign up with Apple'), findsOneWidget);

    await tester.tap(find.text('I confirm I am 13 or older.'));
    await tester.pump();
    await tapApple(tester, 'Sign up with Apple');

    expect(service.calls, 1);
    expect(api.appleCalls, 1);
    expect(api.lastIsRegisterMode, isTrue);
    expect(api.lastAgeConfirmed, isTrue);
    expect(api.lastGivenName, 'Jane');
    expect(api.lastFamilyName, 'Appleseed');
    expect(store.token, 'tok-apple');
    expect(successEmail, 'jane@privaterelay.appleid.com');
    expect(registerEmail, isNull);
  });

  appleTestWidgets(
      'register mode without age confirmation: exact age-gate '
      'error and the service is never called', (tester) async {
    final service = FakeAppleSignInService();
    final api = FakeAppleAuthApiClient();

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        authApi: api,
        sessionStore: FakeSessionStore(),
        appleSignInService: service,
      ),
    ));
    expect(find.text('Create Your Account'), findsOneWidget);

    await tapApple(tester, 'Sign up with Apple');

    expect(
      find.text(
          'Tabs is for people 13 and older. You cannot create an account yet.'),
      findsOneWidget,
    );
    expect(service.calls, 0);
    expect(api.appleCalls, 0);
  });

  appleTestWidgets(
      'Apple cancel: no error text, no API call, still on the '
      'login screen', (tester) async {
    final service = FakeAppleSignInService()
      ..outcomeToThrow = const AppleSignInOutcome.cancelled();
    final api = FakeAppleAuthApiClient();

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        initialRegisterMode: false,
        authApi: api,
        sessionStore: FakeSessionStore(),
        appleSignInService: service,
      ),
    ));

    await tapApple(tester, 'Sign in with Apple');

    expect(service.calls, 1);
    expect(api.appleCalls, 0);
    expect(find.byKey(const ValueKey('login_error')), findsNothing);
    expect(find.text('Welcome Back'), findsOneWidget);
  });

  appleTestWidgets(
      'server rejection: the server message is displayed verbatim',
      (tester) async {
    final service = FakeAppleSignInService();
    final api = FakeAppleAuthApiClient()
      ..appleResult = const LoginFailure(
        LoginFailureKind.server,
        'No account was found with that Apple account. Please sign up first.',
      );

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        initialRegisterMode: false,
        authApi: api,
        sessionStore: FakeSessionStore(),
        appleSignInService: service,
      ),
    ));

    await tapApple(tester, 'Sign in with Apple');

    expect(api.appleCalls, 1);
    expect(
      find.text(
          'No account was found with that Apple account. Please sign up first.'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('login_error')), findsOneWidget);
  });

  appleTestWidgets('failed outcome: the generic Apple message is shown',
      (tester) async {
    final service = FakeAppleSignInService()
      ..outcomeToThrow = const AppleSignInOutcome.failed();
    final api = FakeAppleAuthApiClient();

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        initialRegisterMode: false,
        authApi: api,
        sessionStore: FakeSessionStore(),
        appleSignInService: service,
      ),
    ));

    await tapApple(tester, 'Sign in with Apple');

    expect(api.appleCalls, 0);
    expect(find.text('Apple sign-in failed. Please try again.'),
        findsOneWidget);
  });
}
