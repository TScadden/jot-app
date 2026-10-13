import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/onboarding/welcome_screen.dart';

import 'test_helpers.dart';

/// Round 31 — session restore + refresh-token regression tests.
///
/// All tokens here are OBVIOUSLY FAKE test fixtures — no real
/// credentials anywhere near this file (Vera rule).
const _oldAccess = 'fake-access-old';
const _oldRefresh = 'fake-refresh-old';
const _newAccess = 'fake-access-new';
const _newRefresh = 'fake-refresh-new';
const _email = 'founder@tabs.app';

FakeSessionStore _seededStore() => FakeSessionStore()
  ..token = _oldAccess
  ..refreshToken = _oldRefresh
  ..email = _email;

void main() {
  setUp(() {
    TabsBackend.onSessionExpired = null;
  });
  tearDown(() {
    TabsBackend.onSessionExpired = null;
  });

  group('AuthApiClient.refreshSession', () {
    test('posts the native payload and parses rotated tokens', () async {
      late http.Request captured;
      final client = AuthApiClient(
        client: MockClient((request) async {
          captured = request;
          return http.Response(
            jsonEncode({'token': _newAccess, 'refreshToken': _newRefresh}),
            200,
          );
        }),
      );

      final result = await client.refreshSession(_oldRefresh);

      expect(captured.url.toString(),
          'https://api.jottracker.com/api/auth/refresh-token');
      expect(captured.method, 'POST');
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      expect(body, {'refreshToken': _oldRefresh});
      expect(result, isA<RefreshSuccess>());
      final success = result as RefreshSuccess;
      expect(success.token, _newAccess);
      expect(success.refreshToken, _newRefresh);
    });

    test('401 and 403 are definitive failures', () async {
      for (final status in [401, 403]) {
        final client = AuthApiClient(
          client: MockClient(
              (_) async => http.Response('{"error":"nope"}', status)),
        );
        final result = await client.refreshSession(_oldRefresh);
        expect(result, isA<RefreshDefinitiveFailure>(), reason: '$status');
      }
    });

    test('error strings expired/revoked/invalid/disabled are definitive',
        () async {
      for (final error in [
        'Refresh token expired',
        'Token REVOKED',
        'invalid refresh token',
        'Account disabled',
      ]) {
        final client = AuthApiClient(
          client: MockClient((_) async =>
              http.Response(jsonEncode({'error': error}), 200)),
        );
        final result = await client.refreshSession(_oldRefresh);
        expect(result, isA<RefreshDefinitiveFailure>(), reason: error);
      }
    });

    test('5xx is a temporary failure', () async {
      final client = AuthApiClient(
        client: MockClient((_) async => http.Response('boom', 500)),
      );
      final result = await client.refreshSession(_oldRefresh);
      expect(result, isA<RefreshTemporaryFailure>());
    });

    test('transport failure is a temporary failure', () async {
      final client = AuthApiClient(
        client: MockClient((_) async => throw const SocketException('off')),
      );
      final result = await client.refreshSession(_oldRefresh);
      expect(result, isA<RefreshTemporaryFailure>());
    });

    test('200 with a blank rotated token is temporary, never success',
        () async {
      final client = AuthApiClient(
        client: MockClient((_) async => http.Response(
            jsonEncode({'token': _newAccess, 'refreshToken': ''}), 200)),
      );
      final result = await client.refreshSession(_oldRefresh);
      expect(result, isA<RefreshTemporaryFailure>());
    });

    test('unparseable 200 body is a temporary failure', () async {
      final client = AuthApiClient(
        client: MockClient((_) async => http.Response('not json', 200)),
      );
      final result = await client.refreshSession(_oldRefresh);
      expect(result, isA<RefreshTemporaryFailure>());
    });
  });

  group('TabsBackend 401 → refresh → retry-once', () {
    test(
        'expired access + valid refresh: refreshes once, retries with '
        'the new token, stores the rotated pair, email unchanged',
        () async {
      final store = _seededStore();
      var refreshCalls = 0;
      var pullCalls = 0;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            refreshCalls++;
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            expect(body['refreshToken'], _oldRefresh);
            return http.Response(
              jsonEncode({'token': _newAccess, 'refreshToken': _newRefresh}),
              200,
            );
          }
          if (request.url.path == '/api/sync/pull') {
            pullCalls++;
            if (request.headers['Authorization'] == 'Bearer $_oldAccess') {
              return http.Response('{"error":"expired"}', 401);
            }
            if (request.headers['Authorization'] == 'Bearer $_newAccess') {
              return http.Response(
                jsonEncode({
                  'entries': [],
                  'profile': {'currentStreak': 12, 'bestStreak': 30},
                }),
                200,
              );
            }
          }
          return http.Response('not found', 404);
        }),
        sessionStore: store,
      );

      final streak = await backend.fetchStreak();

      expect(streak.current, 12);
      expect(streak.best, 30);
      expect(refreshCalls, 1);
      expect(pullCalls, 2); // original + exactly one retry
      expect(store.token, _newAccess);
      expect(store.refreshToken, _newRefresh);
      expect(store.email, _email);
    });

    test('concurrent 401s share a single refresh (single-flight)',
        () async {
      final store = _seededStore();
      var refreshCalls = 0;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            refreshCalls++;
            // Small delay so both 401s land while refresh is in flight.
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return http.Response(
              jsonEncode({'token': _newAccess, 'refreshToken': _newRefresh}),
              200,
            );
          }
          final authed =
              request.headers['Authorization'] == 'Bearer $_newAccess';
          if (!authed) return http.Response('{"error":"expired"}', 401);
          if (request.url.path == '/api/sync/pull') {
            return http.Response(
              jsonEncode({
                'entries': [],
                'profile': {'currentStreak': 7, 'bestStreak': 9},
              }),
              200,
            );
          }
          if (request.url.path == '/api/friends/list') {
            return http.Response(
              jsonEncode({
                'friends': [
                  {
                    'id': '1',
                    'nickname': 'Fake Friend',
                    'tag': '#0001',
                    'status': 'active',
                    'level': 3,
                  },
                ],
              }),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
        sessionStore: store,
      );

      final results = await Future.wait([
        backend.fetchStreak(),
        backend.fetchFriendsList(),
      ]);

      expect((results[0] as ({int? current, int? best})).current, 7);
      expect((results[1] as List).length, 1);
      expect(refreshCalls, 1);
      expect(store.token, _newAccess);
    });

    test(
        'definitive refresh rejection (401): session cleared, '
        'onSessionExpired fired once, caller gets its normal failure',
        () async {
      final store = _seededStore();
      var expiredCalls = 0;
      TabsBackend.onSessionExpired = () => expiredCalls++;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            return http.Response('{"error":"Refresh token expired"}', 401);
          }
          return http.Response('{"error":"expired"}', 401);
        }),
        sessionStore: store,
      );

      final streak = await backend.fetchStreak();

      expect(streak.current, isNull);
      expect(streak.best, isNull);
      expect(store.token, isNull);
      expect(store.refreshToken, isNull);
      expect(store.email, isNull);
      expect(expiredCalls, 1);
    });

    test(
        'temporary refresh failure (5xx) on a 401: session preserved, '
        'no session-expired callback, caller gets its normal failure',
        () async {
      final store = _seededStore();
      var expiredCalls = 0;
      TabsBackend.onSessionExpired = () => expiredCalls++;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            return http.Response('server boom', 500);
          }
          return http.Response('{"error":"expired"}', 401);
        }),
        sessionStore: store,
      );

      final streak = await backend.fetchStreak();

      expect(streak.current, isNull);
      expect(store.token, _oldAccess);
      expect(store.refreshToken, _oldRefresh);
      expect(store.email, _email);
      expect(expiredCalls, 0);
    });

    test('a second 401 after a successful refresh is NOT retried again',
        () async {
      final store = _seededStore();
      var refreshCalls = 0;
      var pullCalls = 0;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            refreshCalls++;
            return http.Response(
              jsonEncode({'token': _newAccess, 'refreshToken': _newRefresh}),
              200,
            );
          }
          pullCalls++;
          return http.Response('{"error":"still no"}', 401);
        }),
        sessionStore: store,
      );

      final streak = await backend.fetchStreak();

      expect(streak.current, isNull);
      expect(pullCalls, 2); // original + one retry, never a third
      expect(refreshCalls, 1);
      // The refresh itself succeeded, so the rotated pair stays stored.
      expect(store.token, _newAccess);
    });

    test('logout never goes through the refresh path', () async {
      final store = _seededStore();
      var refreshHit = false;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            refreshHit = true;
            return http.Response(
              jsonEncode({'token': _newAccess, 'refreshToken': _newRefresh}),
              200,
            );
          }
          if (request.url.path == '/api/auth/logout') {
            return http.Response('{"error":"nope"}', 401);
          }
          return http.Response('not found', 404);
        }),
        sessionStore: store,
      );

      final ok = await backend.logoutAccount();

      expect(ok, isFalse);
      expect(refreshHit, isFalse);
      expect(store.token, _oldAccess);
    });
  });

  group('AppFlow cold-start restore', () {
    MockClient weather() => MockClient((request) async {
          if (request.url.host == 'ipinfo.io') {
            return http.Response(
                '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
                200);
          }
          return http.Response(
              '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
              200);
        });

    Future<void> pumpFlow(WidgetTester tester, FakeSessionStore store,
        {http.Client? authHttp}) async {
      await tester.pumpWidget(MaterialApp(
        home: AppFlow(
          authApi: AuthApiClient(
              client: authHttp ??
                  MockClient((_) async => http.Response('{}', 200))),
          sessionStore: store,
          weatherApi: WeatherApiClient(client: weather()),
        ),
      ));
      // Past the splash (entry 650 + hold 1200 + exit 650).
      await tester.pump(const Duration(milliseconds: 1850));
      await tester.pump(const Duration(milliseconds: 650));
      await tester.pump();
    }

    testWidgets('cold start with a stored session lands in Main, '
        'no login required', (tester) async {
      final store = _seededStore();
      await pumpFlow(tester, store);

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.text('Logged in as $_email'), findsOneWidget);
      expect(find.byType(WelcomeScreen), findsNothing);
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets(
        'offline cold start lands in Main with the stored session '
        'and the session is still stored afterwards', (tester) async {
      final store = _seededStore();
      await pumpFlow(
        tester,
        store,
        // Every auth call fails at the transport layer — restore
        // must not depend on the network at all (native parity).
        authHttp: MockClient((_) async => throw const SocketException('off')),
      );

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(WelcomeScreen), findsNothing);
      expect(store.token, _oldAccess);
      expect(store.refreshToken, _oldRefresh);
      expect(store.email, _email);
      await tester.pump(const Duration(milliseconds: 300));
    });

    testWidgets('fresh install (no stored session) still lands on '
        'welcome', (tester) async {
      final store = FakeSessionStore();
      await pumpFlow(tester, store);

      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets(
        'session-expired callback routes a restored session back to '
        'welcome', (tester) async {
      final store = _seededStore();
      await pumpFlow(tester, store);
      expect(find.byType(HomeScreen), findsOneWidget);

      // The backend wrapper clears the store on definitive failure
      // BEFORE invoking this callback (pinned by the backend tests
      // above); here we pin the AppFlow half: routing + in-memory
      // email dropped.
      await store.clear();
      TabsBackend.onSessionExpired?.call();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(WelcomeScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
      expect(find.text('Logged in as $_email'), findsNothing);
    });
  });
}
