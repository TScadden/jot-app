import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'test_helpers.dart';

/// Pumps [AppFlow] with a mock backend and fast-forwards past the splash
/// (entry 650ms + hold 1200ms + exit 650ms).
Future<void> _pumpAppFlow(
  WidgetTester tester, {
  required http.Client mockHttp,
  required FakeSessionStore store,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: AppFlow(
      authApi: AuthApiClient(client: mockHttp),
      sessionStore: store,
    ),
  ));
  await tester.pump(const Duration(milliseconds: 1850));
  await tester.pump(const Duration(milliseconds: 650));
  await tester.pump();
}

/// Taps the main action button after filling the login form.
Future<void> _attemptLogin(
  WidgetTester tester, {
  required String email,
  required String password,
}) async {
  final fields = find.byType(TextField);
  await tester.enterText(fields.at(0), email);
  await tester.enterText(fields.at(1), password);
  await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
  // Let the mock HTTP round-trip complete.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  testWidgets('home screen renders the native background color',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    // Native today route: Scaffold containerColor = NotelBackground.
    expect(scaffold.backgroundColor, NotelColors.background);
    expect(NotelColors.background.toARGB32(), 0xFF080E1A);
    // Background only: no content whatsoever.
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('successful login navigates home showing the email',
      (tester) async {
    final store = FakeSessionStore();
    await _pumpAppFlow(
      tester,
      mockHttp: MockClient((_) async => http.Response(
            jsonEncode({
              'token': 'tok123',
              'refreshToken': 'ref456',
              'userId': 'u1',
              'email': 'founder@tabs.app',
            }),
            200,
          )),
      store: store,
    );

    // Welcome -> login in login mode.
    await tester.tap(find.text('Log In'));
    await tester.pump();
    expect(find.text('Welcome Back'), findsOneWidget);

    await _attemptLogin(
        tester, email: 'founder@tabs.app', password: 'correct-horse');

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Logged in as founder@tabs.app'), findsOneWidget);
    // Session persisted to the (fake) secure store; password never stored.
    expect(store.token, 'tok123');
    expect(store.email, 'founder@tabs.app');
  });

  testWidgets('wrong password shows the error and stays on login',
      (tester) async {
    final store = FakeSessionStore();
    await _pumpAppFlow(
      tester,
      mockHttp: MockClient(
          (_) async => http.Response('{"error":"Invalid credentials"}', 401)),
      store: store,
    );

    await tester.tap(find.text('Log In'));
    await tester.pump();
    await _attemptLogin(
        tester, email: 'founder@tabs.app', password: 'wrong-password');

    expect(find.text('Wrong password or email.'), findsOneWidget);
    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(store.token, isNull);
  });

  testWidgets('nonexistent account shows its error and stays on login',
      (tester) async {
    final store = FakeSessionStore();
    await _pumpAppFlow(
      tester,
      mockHttp: MockClient((_) async => http.Response(
            jsonEncode({
              'error':
                  'No account found with that email. Please sign up to create one.'
            }),
            404,
          )),
      store: store,
    );

    await tester.tap(find.text('Log In'));
    await tester.pump();
    await _attemptLogin(tester, email: 'ghost@tabs.app', password: 'whatever');

    expect(find.text("That account doesn't exist."), findsOneWidget);
    expect(find.text('Welcome Back'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(store.token, isNull);
  });

  testWidgets('blank fields show the native fill-in-all-fields error',
      (tester) async {
    final store = FakeSessionStore();
    await _pumpAppFlow(
      tester,
      mockHttp: MockClient((_) async => http.Response('{}', 200)),
      store: store,
    );

    await tester.tap(find.text('Log In'));
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pump();

    expect(find.text('Please fill in all fields'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });

  testWidgets('"Sign Up" stays a no-op (no navigation)', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AppFlow()));
    await tester.pump(const Duration(milliseconds: 1850));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();

    await tester.tap(find.text('Register'));
    await tester.pump();
    expect(find.text('Create Your Account'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Sign Up'));
    await tester.pump();
    // Still on the login screen; nothing navigated.
    expect(find.text('Create Your Account'), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
  });
}
