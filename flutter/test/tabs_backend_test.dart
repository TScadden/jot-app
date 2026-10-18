import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';

import 'test_helpers.dart';

/// Builds a TabsBackend against a mock HTTP client with an optional token.
TabsBackend backendWith(
  MockClient client, {
  String? token,
}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

void main() {
  group('fetchStreak', () {
    test('parses current/best from a sample pullData payload', () async {
      final backend = backendWith(
        MockClient((request) async {
          expect(request.method, 'GET');
          expect(request.url.toString(),
              'https://api.jottracker.com/api/sync/pull');
          expect(request.headers['Authorization'], 'Bearer tok123');
          return http.Response(
            jsonEncode({
              'entries': [],
              'profile': {
                'currentStreak': 12,
                'bestStreak': 30,
              },
            }),
            200,
          );
        }),
        token: 'tok123',
      );

      final streak = await backend.fetchStreak();
      expect(streak.current, 12);
      expect(streak.best, 30);
    });

    test('missing profile → nulls (never invented)', () async {
      final backend = backendWith(
        MockClient(
            (_) async => http.Response(jsonEncode({'entries': []}), 200)),
        token: 'tok',
      );
      final streak = await backend.fetchStreak();
      expect(streak.current, isNull);
      expect(streak.best, isNull);
    });

    test('HTTP 401 → nulls', () async {
      final backend = backendWith(
        MockClient((_) async => http.Response('{"error":"bad token"}', 401)),
        token: 'stale',
      );
      final streak = await backend.fetchStreak();
      expect(streak.current, isNull);
      expect(streak.best, isNull);
    });

    test('no token → nulls without hitting the network', () async {
      var hit = false;
      final backend = backendWith(
        MockClient((_) async {
          hit = true;
          return http.Response('{}', 200);
        }),
      );
      final streak = await backend.fetchStreak();
      expect(streak.current, isNull);
      expect(streak.best, isNull);
      expect(hit, isFalse);
    });

    test('transport failure → nulls', () async {
      final backend = backendWith(
        MockClient((_) async => throw http.ClientException('down')),
        token: 'tok',
      );
      final streak = await backend.fetchStreak();
      expect(streak.current, isNull);
      expect(streak.best, isNull);
    });
  });

  group('fetchLogEntries', () {
    test('returns entry timestamps (epoch ms)', () async {
      final backend = backendWith(
        MockClient((_) async => http.Response(
              jsonEncode({
                'entries': [
                  {'id': 'a', 'timestamp': 1700000000000},
                  {'id': 'b', 'timestamp': 1700003600000},
                  {'id': 'c'}, // no timestamp → skipped
                ],
              }),
              200,
            )),
        token: 'tok',
      );
      expect(await backend.fetchLogEntries(), [1700000000000, 1700003600000]);
    });

    test('failure → empty list', () async {
      final backend = backendWith(
        MockClient((_) async => http.Response('boom', 500)),
        token: 'tok',
      );
      expect(await backend.fetchLogEntries(), isEmpty);
    });
  });

  group('fetchHabits', () {
    test('parses id/title/logs', () async {
      final backend = backendWith(
        MockClient((request) async {
          expect(request.url.toString(), 'https://api.jottracker.com/api/habits');
          return http.Response(
            jsonEncode({
              'habits': [
                {
                  'id': 'h1',
                  'title': 'Water',
                  'target_time': 'Anytime',
                  'logs': ['2026-10-10', '2026-10-11'],
                },
                {'id': 'h2', 'title': 'Meds', 'logs': []},
              ],
            }),
            200,
          );
        }),
        token: 'tok',
      );
      final habits = await backend.fetchHabits();
      expect(habits, hasLength(2));
      expect(habits[0].id, 'h1');
      expect(habits[0].title, 'Water');
      expect(habits[0].logs, ['2026-10-10', '2026-10-11']);
      expect(habits[1].logs, isEmpty);
    });

    test('failure → empty list', () async {
      final backend = backendWith(
        MockClient((_) async => http.Response('nope', 404)),
        token: 'tok',
      );
      expect(await backend.fetchHabits(), isEmpty);
    });
  });

  group('fetchManualBpLogs', () {
    test('parses the profile JSON string', () async {
      final backend = backendWith(
        MockClient((_) async => http.Response(
              jsonEncode({
                'profile': {
                  'manualBloodPressureLogs': jsonEncode([
                    {
                      'systolic': 120,
                      'diastolic': 80,
                      'timeEpochMs': 1700000000000,
                      'id': 'm1',
                      'source': 'MANUAL',
                    },
                  ]),
                },
              }),
              200,
            )),
        token: 'tok',
      );
      final logs = await backend.fetchManualBpLogs();
      expect(logs, hasLength(1));
      expect(logs[0].systolic, 120);
      expect(logs[0].diastolic, 80);
      expect(logs[0].timeEpochMs, 1700000000000);
    });

    test('null / blank / "[]" / malformed → empty, never throws', () async {
      for (final raw in [null, '', '   ', '[]', 'not-json', '[1,2']) {
        final backend = backendWith(
          MockClient((_) async => http.Response(
                jsonEncode({
                  'profile': {'manualBloodPressureLogs': raw},
                }),
                200,
              )),
          token: 'tok',
        );
        expect(await backend.fetchManualBpLogs(), isEmpty,
            reason: 'raw=$raw');
      }
      // Malformed rows are skipped, valid rows survive.
      final backend = backendWith(
        MockClient((_) async => http.Response(
              jsonEncode({
                'profile': {
                  'manualBloodPressureLogs': jsonEncode([
                    {'systolic': 120, 'diastolic': 80, 'timeEpochMs': 1},
                    {'systolic': 'bad'},
                  ]),
                },
              }),
              200,
            )),
        token: 'tok',
      );
      expect((await backend.fetchManualBpLogs()).length, 1);
    });

    test('missing profile → empty', () async {
      final backend = backendWith(
        MockClient((_) async => http.Response('{}', 200)),
        token: 'tok',
      );
      expect(await backend.fetchManualBpLogs(), isEmpty);
    });
  });

  group('security', () {
    test('HTTPS base URL, no http fallback', () {
      expect(TabsBackend.defaultBaseUrl, startsWith('https://'));
    });

    test('the token is never in an error or log path', () async {
      // There is no API that surfaces the token: fetchStreak only
      // returns streak ints; failures return nulls.
      final backend = backendWith(
        MockClient((_) async => http.Response('boom', 500)),
        token: 'super-secret-token',
      );
      final streak = await backend.fetchStreak();
      expect(streak.toString(), isNot(contains('super-secret-token')));
      expect(await backend.fetchLogEntries(), isEmpty);
    });
  });
}
