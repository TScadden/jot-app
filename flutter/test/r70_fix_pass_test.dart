import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';
import 'package:tabs_lab/src/features/settings/account_actions.dart';

import 'test_helpers.dart';

/// In-memory fake for the history store's storage functions.
class _FakeStore {
  final Map<String, String> values = {};
  Future<String?> read(String key) async => values[key];
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  Future<void> delete(String key) async {
    values.remove(key);
  }
}

MockClient _mockWeather() => MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
      }
      return http.Response(
          '{"current":{"temperature_2m":55.0,"weather_code":2,"is_day":1}}',
          200);
    });

void main() {
  // R70 fix pass A5 (Vera F1 / Juno C1 regression shape): the
  // history store's account guard existed and was unit-tested but
  // had NO production caller, so this test drives the REAL wiring
  // paths — AppFlow login success, AppFlow session expiry, and
  // AccountActions' default cache wipe — never a direct
  // clearIfOwnerMismatch / clear call on the store under test.
  testWidgets(
      'wiring: a mismatched account\'s stored history is dropped on '
      'login, on session expiry, and on the account-clear wipe',
      (tester) async {
    final fake = _FakeStore();
    final store = HealthHistoryStore.instance;
    store.debugSetStore(read: fake.read, write: fake.write, delete: fake.delete);
    store.debugReset();
    addTearDown(() {
      TabsBackend.onSessionExpired = null;
      store.debugReset();
    });

    Future<void> seedOwnedBy(String email) async {
      await store.mergeRefresh(const [
        DailyBiometrics(
            date: '2026-10-01', restingHrBpm: 60, sleepMinutes: 400),
      ]);
      await store.persistScore('2026-10-01', dailyScore: 72, scoreSleep: 80);
      store.bindToAccount(email);
      await store.persist();
      expect(await store.dayCount(), 1);
      expect(
          (await store.readAll())['2026-10-01']!.dailyScore, 72);
    }

    // Account A's all-time history (+ a Daily Score) sits on device,
    // then memory is reset so the login path must meet the DISK blob.
    await seedOwnedBy('a@x.com');
    store.debugReset();

    final session = FakeSessionStore();
    await tester.pumpWidget(MaterialApp(
      home: AppFlow(
        authApi: AuthApiClient(
            client: MockClient((_) async => http.Response(
                  jsonEncode({
                    'token': 'tok-b',
                    'refreshToken': 'ref-b',
                    'userId': 'u-b',
                    'email': 'b@x.com',
                  }),
                  200,
                ))),
        sessionStore: session,
        weatherApi: WeatherApiClient(client: _mockWeather()),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 1850));
    await tester.pump(const Duration(milliseconds: 650));
    await tester.pump();

    // Welcome -> login in login mode, as account B.
    await tester.tap(find.text('Log In'));
    await tester.pump();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'b@x.com');
    await tester.enterText(fields.at(1), 'correct-horse');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log In'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Login success wiring dropped A's history before/with the
    // shell landing: nothing renders or remains for B.
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(fake.values.containsKey(HealthHistoryStore.storageKey), isFalse);
    expect(await store.readAll(), isEmpty);
    expect(store.ownerEmail, 'b@x.com');

    // Session-expiry wiring: B's history is on device, the backend
    // fires expiry, and the store is wiped by AppFlow's handler.
    await seedOwnedBy('b@x.com');
    TabsBackend.onSessionExpired?.call();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(WelcomeScreen), findsOneWidget);
    expect(fake.values.containsKey(HealthHistoryStore.storageKey), isFalse);
    expect(await store.readAll(), isEmpty);

    // Account-clear wiring (logout / account deletion): the
    // default cache wipe leaves no history on device either.
    // runAsync: the wipe also touches sibling caches backed by the
    // real secure-storage platform channel, whose futures cannot
    // complete inside the fake-async test zone when awaited
    // directly.
    await seedOwnedBy('b@x.com');
    await tester.runAsync(() => AccountActions.clearDefaultCaches());
    expect(fake.values.containsKey(HealthHistoryStore.storageKey), isFalse);
    expect(await store.readAll(), isEmpty);
  });
}
