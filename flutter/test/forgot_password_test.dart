import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/features/auth/login_screen.dart';

/// Audit GAP-2 — fake auth API for the password-reset wiring tests.
/// Records every forgot-password call; login/register stay
/// unconfigured failures (never exercised by these tests). The
/// inherited real HTTP client is never used.
class _FakeAuthApi extends AuthApiClient {
  ForgotPasswordResult forgotResult = const ForgotPasswordSuccess();
  Completer<ForgotPasswordResult>? forgotGate;
  final List<String> forgotEmails = [];

  int get forgotCalls => forgotEmails.length;

  @override
  Future<ForgotPasswordResult> forgotPassword({
    required String email,
  }) async {
    forgotEmails.add(email);
    final gate = forgotGate;
    if (gate != null) return gate.future;
    return forgotResult;
  }

  @override
  Future<LoginResult> login({
    required String email,
    required String password,
  }) async =>
      const LoginFailure(LoginFailureKind.server, 'unconfigured fake');

  @override
  Future<LoginResult> register({
    required String email,
    required String password,
    required bool ageConfirmed,
  }) async =>
      const LoginFailure(LoginFailureKind.server, 'unconfigured fake');
}

/// Pumps the login screen in login mode, switches to the
/// forgot-password form, and (when [email] is given) types it on
/// the LOGIN form first — the reset form must carry it over,
/// because the email controller is shared across modes.
Future<void> _openResetForm(
  WidgetTester tester,
  _FakeAuthApi api, {
  String? email,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: LoginScreen(initialRegisterMode: false, authApi: api),
  ));
  await tester.pump();
  if (email != null) {
    await tester.enterText(find.byType(TextField).first, email);
  }
  await tester.tap(find.text('Forgot Password?'));
  await tester.pump();
  expect(find.text('Reset Password'), findsOneWidget);
  expect(find.text('Send Reset Link'), findsOneWidget);
}

void main() {
  testWidgets(
      '(1) tapping Send Reset Link invokes forgot-password with the '
      'email typed on the login form (prefill carries over)',
      (tester) async {
    final api = _FakeAuthApi();
    await _openResetForm(tester, api, email: 'person@tabs.app');

    await tester.tap(find.widgetWithText(ElevatedButton, 'Send Reset Link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.forgotCalls, 1);
    expect(api.forgotEmails.single, 'person@tabs.app');
  });

  testWidgets('(2) success state renders after a 200, worded so it '
      'never claims the account exists, with a path back to login',
      (tester) async {
    final api = _FakeAuthApi()
      ..forgotResult = const ForgotPasswordSuccess();
    await _openResetForm(tester, api, email: 'person@tabs.app');

    await tester.tap(find.widgetWithText(ElevatedButton, 'Send Reset Link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final success = find.byKey(const ValueKey('forgot_password_success'));
    expect(success, findsOneWidget);
    expect(
      tester.widget<Text>(success).data,
      contains('If there\'s an account for that email'),
    );
    expect(find.textContaining('not found'), findsNothing);
    expect(find.byKey(const ValueKey('login_error')), findsNothing);
    // Clear path back to login.
    expect(find.text('Back to Log In'), findsOneWidget);
    await tester.tap(find.text('Back to Log In'));
    await tester.pump();
    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.text('Log In'), findsOneWidget);
    // The stale confirmation does not follow the user back.
    expect(success, findsNothing);
  });

  testWidgets('(3) error state renders on failure and tapping Send '
      'again retries the request', (tester) async {
    final api = _FakeAuthApi()
      ..forgotResult = const ForgotPasswordFailure(
        LoginFailureKind.network,
        "Couldn't reach the server. Check your connection and try again.",
      );
    await _openResetForm(tester, api, email: 'person@tabs.app');

    await tester.tap(find.widgetWithText(ElevatedButton, 'Send Reset Link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.forgotCalls, 1);
    final error = find.byKey(const ValueKey('login_error'));
    expect(error, findsOneWidget);
    expect(
      tester.widget<Text>(error).data,
      contains("Couldn't reach the server"),
    );
    expect(find.byKey(const ValueKey('forgot_password_success')),
        findsNothing);

    // Retry path: the button is live again and a second tap calls
    // the endpoint again — this time it succeeds.
    api.forgotResult = const ForgotPasswordSuccess();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Send Reset Link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(api.forgotCalls, 2);
    expect(find.byKey(const ValueKey('forgot_password_success')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('login_error')), findsNothing);
  });

  testWidgets('(4) in-flight state disables the button and prevents '
      'a second submit', (tester) async {
    final api = _FakeAuthApi()
      ..forgotGate = Completer<ForgotPasswordResult>();
    await _openResetForm(tester, api, email: 'person@tabs.app');

    await tester.tap(find.widgetWithText(ElevatedButton, 'Send Reset Link'));
    await tester.pump();

    expect(api.forgotCalls, 1);
    // Spinner up, button disabled while the request is in flight.
    // (While loading, the button's child is the spinner, not the
    // label, so it is found by type: the main action button is the
    // first ElevatedButton in the card.)
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    final mainButton = find.byType(ElevatedButton).first;
    final button = tester.widget<ElevatedButton>(mainButton);
    expect(button.onPressed, isNull);

    // A second tap while in flight must not submit again.
    await tester.tap(mainButton);
    await tester.pump();
    expect(api.forgotCalls, 1);

    // Completing the request lands on the success state and
    // re-enables the button.
    api.forgotGate!.complete(const ForgotPasswordSuccess());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const ValueKey('forgot_password_success')),
        findsOneWidget);
    final settled = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Send Reset Link'),
    );
    expect(settled.onPressed, isNotNull);
  });

  testWidgets('blank email shows a prompt and sends no request',
      (tester) async {
    final api = _FakeAuthApi();
    await _openResetForm(tester, api);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Send Reset Link'));
    await tester.pump();

    expect(api.forgotCalls, 0);
    final error = find.byKey(const ValueKey('login_error'));
    expect(error, findsOneWidget);
    expect(tester.widget<Text>(error).data, 'Please enter your email first.');
  });
}
