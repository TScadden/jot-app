import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/google_sign_in_service.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';

import 'test_helpers.dart';

/// Round 24 — fake [GoogleSignInService]: returns a canned ID token
/// or throws a canned [GoogleSignInOutcome], and counts calls so
/// tests can prove sign-in was (or was not) launched. Never touches
/// the real plugin.
class FakeGoogleSignInService extends GoogleSignInService {
  String idToken = 'fake-id-token';
  GoogleSignInOutcome? outcomeToThrow;
  int calls = 0;

  @override
  Future<String> signInForIdToken() async {
    calls++;
    final outcome = outcomeToThrow;
    if (outcome != null) throw outcome;
    return idToken;
  }
}

/// Round 24 — fake [AuthApiClient]: records `googleLogin` calls and
/// returns a canned result. The inherited real HTTP client is never
/// used because both entry points are overridden.
class FakeAuthApiClient extends AuthApiClient {
  LoginResult googleResult = const LoginFailure(
    LoginFailureKind.server,
    'unconfigured fake',
  );
  int googleCalls = 0;
  String? lastIdToken;
  bool? lastIsRegisterMode;
  bool? lastAgeConfirmed;

  @override
  Future<LoginResult> googleLogin({
    required String idToken,
    required bool isRegisterMode,
    required bool ageConfirmed,
  }) async {
    googleCalls++;
    lastIdToken = idToken;
    lastIsRegisterMode = isRegisterMode;
    lastAgeConfirmed = ageConfirmed;
    return googleResult;
  }
}

void main() {
  Future<void> tapGoogle(WidgetTester tester, String label) async {
    await tester.ensureVisible(find.text(label));
    await tester.pump();
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump();
  }

  testWidgets(
      'login-mode Google tap: success saves the session and fires '
      'onLoginSuccess with the Google email', (tester) async {
    final service = FakeGoogleSignInService();
    final api = FakeAuthApiClient()
      ..googleResult = const LoginSuccess(
        token: 'tok-google',
        refreshToken: 'ref-google',
        userId: 'u-google',
        email: 'google@example.com',
      );
    final store = FakeSessionStore();
    String? successEmail;

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        initialRegisterMode: false,
        authApi: api,
        sessionStore: store,
        googleSignInService: service,
        onLoginSuccess: (email) => successEmail = email,
      ),
    ));

    await tapGoogle(tester, 'Log in with Google');

    expect(service.calls, 1);
    expect(api.googleCalls, 1);
    expect(api.lastIdToken, 'fake-id-token');
    expect(api.lastIsRegisterMode, isFalse);
    expect(api.lastAgeConfirmed, isFalse);
    // Identical downstream path to password login (Juno N5).
    expect(store.token, 'tok-google');
    expect(store.refreshToken, 'ref-google');
    expect(store.email, 'google@example.com');
    expect(successEmail, 'google@example.com');
  });

  testWidgets(
      'Google cancel: no error text, no API call, still on the '
      'login screen', (tester) async {
    final service = FakeGoogleSignInService()
      ..outcomeToThrow = const GoogleSignInOutcome.cancelled();
    final api = FakeAuthApiClient();

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        initialRegisterMode: false,
        authApi: api,
        sessionStore: FakeSessionStore(),
        googleSignInService: service,
      ),
    ));

    await tapGoogle(tester, 'Log in with Google');

    expect(service.calls, 1);
    expect(api.googleCalls, 0);
    expect(find.byKey(const ValueKey('login_error')), findsNothing);
    expect(find.text('Welcome Back'), findsOneWidget);
  });

  testWidgets(
      'register mode without age confirmation: exact age-gate '
      'error and the service is never called', (tester) async {
    final service = FakeGoogleSignInService();
    final api = FakeAuthApiClient();

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        // Register mode is the default.
        authApi: api,
        sessionStore: FakeSessionStore(),
        googleSignInService: service,
      ),
    ));
    expect(find.text('Create Your Account'), findsOneWidget);

    await tapGoogle(tester, 'Continue with Google');

    expect(
      find.text(
          'Tabs is for people 13 and older. You cannot create an account yet.'),
      findsOneWidget,
    );
    expect(service.calls, 0);
    expect(api.googleCalls, 0);
  });

  testWidgets(
      'server rejection: the server message is displayed verbatim',
      (tester) async {
    final service = FakeGoogleSignInService();
    final api = FakeAuthApiClient()
      ..googleResult = const LoginFailure(
        LoginFailureKind.server,
        'No account was found with that Google account. Please sign up first.',
      );

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        initialRegisterMode: false,
        authApi: api,
        sessionStore: FakeSessionStore(),
        googleSignInService: service,
      ),
    ));

    await tapGoogle(tester, 'Log in with Google');

    expect(api.googleCalls, 1);
    expect(
      find.text(
          'No account was found with that Google account. Please sign up first.'),
      findsOneWidget,
    );
  });

  testWidgets(
      'unavailable outcome: exact Lab-build message is displayed',
      (tester) async {
    final service = FakeGoogleSignInService()
      ..outcomeToThrow = const GoogleSignInOutcome.unavailable();
    final api = FakeAuthApiClient();

    await tester.pumpWidget(MaterialApp(
      home: LoginScreen(
        initialRegisterMode: false,
        authApi: api,
        sessionStore: FakeSessionStore(),
        googleSignInService: service,
      ),
    ));

    await tapGoogle(tester, 'Log in with Google');

    expect(api.googleCalls, 0);
    expect(
      find.text("Google sign-in isn't available in this Lab build yet."),
      findsOneWidget,
    );
  });
}
