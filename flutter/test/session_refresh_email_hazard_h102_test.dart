import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import 'test_helpers.dart';

/// H1-02 — regression tests for the refresh email-read hazard in
/// TabsBackend._performRefresh.
///
/// After AuthApiClient.refreshSession returns RefreshSuccess the
/// server has ALREADY rotated the refresh token and invalidated
/// the old one. The pre-fix code then did
/// `final email = await _sessionStore.readEmail() ?? '';`
/// followed by saveSession, inside the outer try whose catch
/// returns a TEMPORARY failure. Two hazards:
/// (1) a throwing readEmail discarded the newly rotated pair —
///     the next refresh would present the old, already-rotated
///     token, the server reads that as reuse, and the session is
///     definitively killed;
/// (2) a null readEmail persisted user_email as '', silently
///     unbinding every email-scoped local store.
///
/// All tokens here are OBVIOUSLY FAKE test fixtures.
const _oldAccess = 'fake-access-old';
const _oldRefresh = 'fake-refresh-old';
const _newAccess = 'fake-access-new';
const _newRefresh = 'fake-refresh-new';
const _newerAccess = 'fake-access-newer';
const _newerRefresh = 'fake-refresh-newer';
const _email = 'founder@tabs.app';

/// The underlying stored email stays [_email] (the field), but
/// every READ of it throws — modelling a transient keystore
/// failure on the post-rotation read.
class _ThrowingEmailReadStore extends FakeSessionStore {
  @override
  Future<String?> readEmail() async =>
      throw StateError('fake email read failure');
}

/// The underlying stored email stays [_email] (the field), but
/// every READ of it returns null — modelling a transient
/// per-key read coming back empty.
class _NullEmailReadStore extends FakeSessionStore {
  @override
  Future<String?> readEmail() async => null;
}

/// Same transient read failure, empty-string flavour.
class _EmptyEmailReadStore extends FakeSessionStore {
  @override
  Future<String?> readEmail() async => '';
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);
  setUp(() {
    TabsBackend.onSessionExpired = null;
  });
  tearDown(() {
    TabsBackend.onSessionExpired = null;
  });

  group('H1-02 refresh email-read hazard', () {
    test(
        '(a) readEmail throws after RefreshSuccess: rotated tokens '
        'persisted, session survives, next refresh uses the NEW '
        'refresh token', () async {
      final store = _ThrowingEmailReadStore()
        ..token = _oldAccess
        ..refreshToken = _oldRefresh
        ..email = _email;
      var expiredCalls = 0;
      TabsBackend.onSessionExpired = () => expiredCalls++;
      var newAccessExpired = false;
      final presentedRefreshTokens = <String?>[];
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            presentedRefreshTokens.add(body['refreshToken'] as String?);
            if (body['refreshToken'] == _oldRefresh) {
              return http.Response(
                jsonEncode(
                    {'token': _newAccess, 'refreshToken': _newRefresh}),
                200,
              );
            }
            if (body['refreshToken'] == _newRefresh) {
              return http.Response(
                jsonEncode({
                  'token': _newerAccess,
                  'refreshToken': _newerRefresh,
                }),
                200,
              );
            }
            // Presenting an already-rotated token again is reuse:
            // the real server answers definitively.
            return http.Response('{"error":"Refresh token revoked"}', 401);
          }
          if (request.url.path == '/api/sync/pull') {
            final auth = request.headers['Authorization'];
            if (auth == 'Bearer $_oldAccess') {
              return http.Response('{"error":"expired"}', 401);
            }
            if (auth == 'Bearer $_newAccess' && !newAccessExpired) {
              return http.Response(
                jsonEncode({
                  'entries': [],
                  'profile': {'currentStreak': 12, 'bestStreak': 30},
                }),
                200,
              );
            }
            if (auth == 'Bearer $_newAccess' && newAccessExpired) {
              return http.Response('{"error":"expired"}', 401);
            }
            if (auth == 'Bearer $_newerAccess') {
              return http.Response(
                jsonEncode({
                  'entries': [],
                  'profile': {'currentStreak': 15, 'bestStreak': 30},
                }),
                200,
              );
            }
          }
          return http.Response('not found', 404);
        }),
        sessionStore: store,
      );

      // Wave 1: old access 401s, refresh rotates, email read throws.
      final streak = await backend.fetchStreak();

      expect(streak.current, 12, reason: 'retry after refresh must succeed');
      expect(streak.best, 30);
      expect(store.token, _newAccess,
          reason: 'rotated access token must be persisted despite '
              'the throwing email read');
      expect(store.refreshToken, _newRefresh,
          reason: 'rotated refresh token must be persisted despite '
              'the throwing email read');
      expect(store.email, _email,
          reason: 'stored email must be left untouched');
      expect(expiredCalls, 0);

      // Wave 2: the new access token expires too. The next refresh
      // must present the NEW refresh token — presenting the old
      // one would be reuse and kill the session on the server.
      TabsBackend.debugResetSharedCaches();
      newAccessExpired = true;
      final streak2 = await backend.fetchStreak();

      expect(streak2.current, 15);
      expect(presentedRefreshTokens, [_oldRefresh, _newRefresh],
          reason: 'second refresh must present the rotated token '
              'persisted by the first refresh');
      expect(store.token, _newerAccess);
      expect(store.refreshToken, _newerRefresh);
      expect(store.email, _email);
      expect(expiredCalls, 0);
    });

    test(
        '(b) readEmail returns null after RefreshSuccess: rotated '
        'tokens persisted and stored user_email unchanged (not '
        "empty string)", () async {
      final store = _NullEmailReadStore()
        ..token = _oldAccess
        ..refreshToken = _oldRefresh
        ..email = _email;
      var expiredCalls = 0;
      TabsBackend.onSessionExpired = () => expiredCalls++;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            return http.Response(
              jsonEncode({'token': _newAccess, 'refreshToken': _newRefresh}),
              200,
            );
          }
          if (request.url.path == '/api/sync/pull') {
            if (request.headers['Authorization'] == 'Bearer $_oldAccess') {
              return http.Response('{"error":"expired"}', 401);
            }
            if (request.headers['Authorization'] == 'Bearer $_newAccess') {
              return http.Response(
                jsonEncode({
                  'entries': [],
                  'profile': {'currentStreak': 9, 'bestStreak': 11},
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

      expect(streak.current, 9);
      expect(store.token, _newAccess);
      expect(store.refreshToken, _newRefresh);
      expect(store.email, _email,
          reason: "user_email must never be overwritten with '' "
              'when a real email was previously stored');
      expect(expiredCalls, 0);
    });

    test(
        '(b2) readEmail returns empty string after RefreshSuccess: '
        'stored user_email unchanged', () async {
      final store = _EmptyEmailReadStore()
        ..token = _oldAccess
        ..refreshToken = _oldRefresh
        ..email = _email;
      var expiredCalls = 0;
      TabsBackend.onSessionExpired = () => expiredCalls++;
      final backend = TabsBackend(
        client: MockClient((request) async {
          if (request.url.path == '/api/auth/refresh-token') {
            return http.Response(
              jsonEncode({'token': _newAccess, 'refreshToken': _newRefresh}),
              200,
            );
          }
          if (request.url.path == '/api/sync/pull') {
            if (request.headers['Authorization'] == 'Bearer $_oldAccess') {
              return http.Response('{"error":"expired"}', 401);
            }
            if (request.headers['Authorization'] == 'Bearer $_newAccess') {
              return http.Response(
                jsonEncode({
                  'entries': [],
                  'profile': {'currentStreak': 4, 'bestStreak': 6},
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

      expect(streak.current, 4);
      expect(store.token, _newAccess);
      expect(store.refreshToken, _newRefresh);
      expect(store.email, _email);
      expect(expiredCalls, 0);
    });
  });
}
