import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/theme/animations.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'package:tabs_lab/src/data/weather_api.dart';

import 'test_helpers.dart';

/// Mock weather backend: serves ipinfo + Open-Meteo canned payloads with
/// the given temperature, or an unavailable state when [temp] is null.
MockClient _mockWeatherClient([int? temp]) {
  return MockClient((request) async {
    final host = request.url.host;
    if (host == 'ipinfo.io') {
      return http.Response(
          '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
    }
    if (host == 'api.open-meteo.com') {
      if (temp == null) return http.Response('boom', 500);
      return http.Response(
          '{"current":{"temperature_2m":$temp.0,"weather_code":2,"is_day":1}}',
          200);
    }
    return http.Response('not found', 404);
  });
}

/// Round 38 — the signed-in email must appear NOWHERE in the current
/// widget tree: neither the exact "Logged in as …" label, nor the
/// raw email string inside any rendered Text widget.
void expectNoEmailRendered(WidgetTester tester, String email) {
  expect(find.text('Logged in as $email'), findsNothing);
  expect(find.textContaining('Logged in as'), findsNothing);
  expect(find.textContaining(email), findsNothing);
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    expect(text.data ?? '', isNot(contains(email)));
    expect(text.data ?? '', isNot(contains('Logged in as')));
  }
}

/// Pumps [AppFlow] with a mock backend and fast-forwards past the splash
/// (entry 650ms + hold 1200ms + exit 650ms).
Future<void> _pumpAppFlow(
  WidgetTester tester, {
  required http.Client mockHttp,
  required FakeSessionStore store,
  int? weatherTemp,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: AppFlow(
      authApi: AuthApiClient(client: mockHttp),
      sessionStore: store,
      weatherApi: WeatherApiClient(client: _mockWeatherClient(weatherTemp)),
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
  testWidgets('home screen renders the native background color and header',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
          weatherApi: WeatherApiClient(client: _mockWeatherClient())),
    ));
    await tester.pump();
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    // Native today route: Scaffold containerColor = NotelBackground.
    expect(scaffold.backgroundColor, NotelColors.background);
    expect(NotelColors.background.toARGB32(), 0xFF080E1A);
    // Today header (native topBar): title, weather icon, watch icon.
    expect(find.text('Today'), findsOneWidget);
    // Round 14: the header icon is the living AnimatedWeatherIcon (a
    // static cloud when no condition has loaded yet).
    expect(find.byType(AnimatedWeatherIcon), findsOneWidget);
    expect(find.byIcon(Icons.watch), findsOneWidget);
    // Weather unavailable (mock 500s): icon only — never a zero.
    expect(find.text('0°'), findsNothing);
    // Let the staggered-entrance delay timers fire (no pending timers
    // at teardown).
    await tester.pump(const Duration(milliseconds: 300));
  });

  // Round 38 — direct Home render WITH a signed-in email supplied:
  // the email (and any "Logged in as …" label) is absent anywhere on
  // the screen, including after scrolling to the very bottom where
  // the label used to sit. The email param itself stays as internal
  // plumbing (cache account-binding / Settings forwarding).
  testWidgets(
      'home with a signed-in email renders the email NOWHERE, '
      'even scrolled to the bottom', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
          email: 'founder@tabs.app',
          weatherApi: WeatherApiClient(client: _mockWeatherClient())),
    ));
    await tester.pump();
    expect(find.text('Today'), findsOneWidget);
    expectNoEmailRendered(tester, 'founder@tabs.app');
    // Scroll to the bottom (the label's old slot was the last item
    // above the nav-dock clearance) and re-assert.
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -2000));
    await tester.pump();
    expectNoEmailRendered(tester, 'founder@tabs.app');
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('header shows the live temp once loaded', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: HomeScreen(
          weatherApi: WeatherApiClient(client: _mockWeatherClient(61))),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('61°'), findsOneWidget);
    expect(find.byType(AnimatedWeatherIcon), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('successful login navigates home WITHOUT showing the email',
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
    // Round 38 — Home renders, but the account email is visible
    // NOWHERE on it (the "Logged in as …" label is gone). The email
    // remains internal: session storage below still holds it.
    expectNoEmailRendered(tester, 'founder@tabs.app');
    // Session persisted to the (fake) secure store; password never stored.
    expect(store.token, 'tok123');
    expect(store.email, 'founder@tabs.app');
    // Let the staggered-entrance delay timers fire (no pending timers
    // at teardown).
    await tester.pump(const Duration(milliseconds: 300));
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
