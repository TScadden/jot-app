import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/auth_api.dart';
import 'package:tabs_lab/src/data/onboarding_store.dart';
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

/// Round 33 — in-memory [OnboardingStore] for AppFlow widget tests
/// (same withStorage pattern as onboarding_r32_test.dart).
///
/// Why this exists: Round 32 layered the onboarding gate INSIDE
/// _restoreSession, and AppFlow's default OnboardingStore is backed
/// by flutter_secure_storage — a platform channel whose futures
/// never complete under FakeAsync. The pre-Round-33 fixtures here
/// injected only the session store, so the gate's first await
/// stalled the restore forever and every restored session sat on
/// Welcome (verified by diagnostic: hasAnyState() never completed,
/// MainShell 0 / Welcome 1 / OnboardingFlow 0). The production gate
/// logic was NOT misrouting: with a real store injected, a keyless
/// legacy session lands home per the Round 32 backfill design.
/// An EMPTY map is exactly a pre-Round-32 stored session: a valid
/// session with no onboarding keys at all.
OnboardingStore _fakeOnboardingStore(Map<String, String> map) =>
    OnboardingStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

/// Round 31 fix pass — a seeded store whose EMAIL read throws
/// (Vera NIT 2): the token read still succeeds, so restore must
/// route home with a null email instead of aborting to welcome.
class _EmailThrowingStore extends FakeSessionStore {
  @override
  Future<String?> readEmail() async =>
      throw StateError('fake email read failure');
}

void main() {
  // Oct 26, 2026 perf package: the sync-pull/habits caches are STATIC
  // and session-keyed, and every case here reuses the same tokens —
  // reset between cases so one case's cached pull body cannot be
  // served to the next case's fresh fake server.
  setUp(TabsBackend.debugResetSharedCaches);
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

    // Round 31 fix pass (Vera BLOCKER 1) — the keyword check is
    // status-gated to HTTP 200, native order. A 500 whose body
    // happens to contain a keyword is a server blip, NOT a dead
    // session.
    test(
        '500 with a keyword error body is TEMPORARY (status-gated '
        'taxonomy)', () async {
      final client = AuthApiClient(
        client: MockClient((_) async =>
            http.Response('{"error":"invalid token"}', 500)),
      );
      final result = await client.refreshSession(_oldRefresh);
      expect(result, isA<RefreshTemporaryFailure>());
    });

    test(
        '400 with a keyword error body is TEMPORARY, never '
        'definitive', () async {
      final client = AuthApiClient(
        client: MockClient((_) async => http.Response(
            '{"error":"refresh token revoked"}', 400)),
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

    // Round 31 fix pass (Vera SHOULD-FIX 3) — the mirror of the
    // blank-refresh case above: a blank ACCESS token in a 200 is
    // equally a server bug, never a success and never definitive.
    test(
        '200 with a blank ACCESS token (non-blank refresh) is '
        'temporary, never success', () async {
      final client = AuthApiClient(
        client: MockClient((_) async => http.Response(
            jsonEncode({'token': '', 'refreshToken': _newRefresh}),
            200)),
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

    // Round 31 fix pass (Vera BLOCKER 1), backend level — a 500
    // refresh response whose body carries a keyword must behave
    // exactly like any other temporary failure: session preserved,
    // no session-expired callback.
    test(
        'refresh 500 with a keyword error body ("invalid token"): '
        'session preserved, no session-expired callback', () async {
      final store = _seededStore();
      var expiredCalls = 0;
      TabsBackend.onSessionExpired = () => expiredCalls++;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            return http.Response('{"error":"invalid token"}', 500);
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

    // Round 31 fix pass (Vera BLOCKER 2) — the single-flight slot
    // is app-wide: two DISTINCT TabsBackend instances over one
    // store must share a single refresh. Per-instance slots let
    // each instance POST the old refresh token; rotation
    // reuse-detection could then read the second presentation as
    // revoked and clear the pair the first instance just saved.
    test(
        'two TabsBackend instances share ONE app-wide refresh: '
        'concurrent 401s → exactly one refresh POST, both calls '
        'succeed, session never cleared', () async {
      final store = _seededStore();
      var refreshCalls = 0;
      var expiredCalls = 0;
      TabsBackend.onSessionExpired = () => expiredCalls++;
      final sharedClient = MockClient((request) async {
        if (request.url.path == '/api/auth/refresh-token') {
          refreshCalls++;
          // Small delay so both instances' 401s land while the
          // refresh is in flight.
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
      });
      final backendA =
          TabsBackend(client: sharedClient, sessionStore: store);
      final backendB =
          TabsBackend(client: sharedClient, sessionStore: store);

      final results = await Future.wait([
        backendA.fetchStreak(),
        backendB.fetchFriendsList(),
      ]);

      expect((results[0] as ({int? current, int? best})).current, 7);
      expect((results[1] as List).length, 1);
      expect(refreshCalls, 1);
      expect(expiredCalls, 0);
      expect(store.token, _newAccess);
      expect(store.refreshToken, _newRefresh);
      expect(store.email, _email);
    });

    // Round 31 fix pass (Vera SHOULD-FIX 3) — a 401 with no stored
    // refresh token at all is definitive WITHOUT ever calling the
    // refresh endpoint: session cleared, callback fired.
    test(
        '401 with NO stored refresh token: definitive — session '
        'cleared, callback fired, refresh endpoint never called',
        () async {
      final store = FakeSessionStore()
        ..token = _oldAccess
        ..email = _email; // refreshToken deliberately null
      var expiredCalls = 0;
      var refreshHit = false;
      TabsBackend.onSessionExpired = () => expiredCalls++;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            refreshHit = true;
            return http.Response(
              jsonEncode({'token': _newAccess, 'refreshToken': _newRefresh}),
              200,
            );
          }
          return http.Response('{"error":"expired"}', 401);
        }),
        sessionStore: store,
      );

      final streak = await backend.fetchStreak();

      expect(streak.current, isNull);
      expect(refreshHit, isFalse);
      expect(store.token, isNull);
      expect(store.refreshToken, isNull);
      expect(store.email, isNull);
      expect(expiredCalls, 1);
    });

    // Round 31 fix pass (Vera SHOULD-FIX 2) — linkGoogle routes
    // through _sendAuthed: an expired access token refreshes and
    // the link retries once instead of failing silently.
    test(
        'linkGoogle routes through the refresh wrapper: expired '
        'token refreshes and retries once, returning the body',
        () async {
      final store = _seededStore();
      var refreshCalls = 0;
      var linkCalls = 0;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            refreshCalls++;
            return http.Response(
              jsonEncode({'token': _newAccess, 'refreshToken': _newRefresh}),
              200,
            );
          }
          if (request.url.path == '/api/auth/link-google') {
            linkCalls++;
            if (request.headers['Authorization'] ==
                'Bearer $_oldAccess') {
              return http.Response('{"error":"expired"}', 401);
            }
            return http.Response(
              jsonEncode({'success': true, 'message': 'linked'}),
              200,
            );
          }
          return http.Response('not found', 404);
        }),
        sessionStore: store,
      );

      final body = await backend.linkGoogle('fake-google-id-token');

      expect(body, isNotNull);
      expect(body!['success'], isTrue);
      expect(refreshCalls, 1);
      expect(linkCalls, 2); // original 401 + exactly one retry
      expect(store.token, _newAccess);
      expect(store.refreshToken, _newRefresh);
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
        {http.Client? authHttp, Map<String, String>? onboardingMap}) async {
      await tester.pumpWidget(MaterialApp(
        home: AppFlow(
          authApi: AuthApiClient(
              client: authHttp ??
                  MockClient((_) async => http.Response('{}', 200))),
          sessionStore: store,
          // Round 33 — inject the onboarding store (see
          // _fakeOnboardingStore). Default: an empty map, i.e. a
          // pre-Round-32 legacy session with no onboarding keys.
          onboardingStore:
              _fakeOnboardingStore(onboardingMap ?? <String, String>{}),
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
      // Explicitly a pre-Round-32 legacy session: the onboarding
      // map starts EMPTY (no onboarding keys at all).
      final onboardingMap = <String, String>{};
      await pumpFlow(tester, store, onboardingMap: onboardingMap);

      expect(find.byType(HomeScreen), findsOneWidget);
      // Round 38 — restore still lands on Home, but the account
      // email is rendered NOWHERE on it (the "Logged in as …" label
      // Home used to show as proof-of-login is removed).
      expect(find.text('Logged in as $_email'), findsNothing);
      expect(find.textContaining(_email), findsNothing);
      expect(find.byType(WelcomeScreen), findsNothing);
      // Round 32/33 matrix — a keyless legacy session is backfilled
      // onboarding-complete, never dropped into onboarding.
      await tester.pump(const Duration(milliseconds: 100));
      expect(onboardingMap['onboarding_complete'], 'true');
      expect(onboardingMap['has_consented'], 'true');
      expect(onboardingMap['intro_consultation_seen'], 'true');
      await tester.pump(const Duration(milliseconds: 300));
    });

    // Round 33 matrix — cold start with a valid stored session AND
    // completed onboarding state goes straight to Main (no resume).
    testWidgets('cold start with completed onboarding state lands '
        'in Main', (tester) async {
      final store = _seededStore();
      final onboardingMap = <String, String>{
        'has_consented': 'true',
        'intro_consultation_seen': 'true',
        'onboarding_complete': 'true',
      };
      await pumpFlow(tester, store, onboardingMap: onboardingMap);

      expect(find.byType(HomeScreen), findsOneWidget);
      // Round 38 — same as above: on Home, email rendered nowhere.
      expect(find.text('Logged in as $_email'), findsNothing);
      expect(find.textContaining(_email), findsNothing);
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

    // Round 31 fix pass (Vera NIT 2) — the email read is isolated:
    // a throwing email read must not abort a restore backed by a
    // valid token. Route home with a null email.
    testWidgets(
        'cold start with a valid token but a THROWING email read '
        'still lands in Main, session untouched', (tester) async {
      final store = _EmailThrowingStore()
        ..token = _oldAccess
        ..refreshToken = _oldRefresh
        ..email = _email;
      await pumpFlow(tester, store);

      expect(find.byType(HomeScreen), findsOneWidget);
      expect(find.byType(WelcomeScreen), findsNothing);
      expect(store.token, _oldAccess);
      expect(store.refreshToken, _oldRefresh);
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
