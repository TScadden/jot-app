import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';
import 'package:tabs_lab/src/features/tools/key_metrics_screen.dart';
import 'package:tabs_lab/src/features/tools/tips_tricks_screen.dart';
import 'package:tabs_lab/src/features/tools/trends_screen.dart';

import 'test_helpers.dart';

/// Round 18 (Team C) — widget + unit tests for the four tool screens:
/// Tips & Tricks, Health Coach, Key Metrics, Trends.
///
/// Covers: parsing, empty states, auth-failure → honest empty, locked
/// state when not unlimited, AI failure → visible error (never a
/// fabricated reply), and never a crash on malformed payloads.

TabsBackend backendWith(MockClient client, {String? token}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

/// In-memory SecureStore for the fake Health Connect service.
class _MemStore implements SecureStore {
  final _map = <String, String>{};

  @override
  Future<String?> read(String key) async => _map[key];

  @override
  Future<void> write(String key, String value) async {
    _map[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _map.remove(key);
  }
}

/// Fake Health Connect that answers instantly: unmocked MethodChannels
/// hang forever in widget tests, so KeyMetrics tests inject this instead.
class _FakeHc extends HealthConnectService {
  _FakeHc()
      : super(
            channel: const MethodChannel('test-health-connect'),
            store: _MemStore());

  @override
  Future<bool> isConnected() async => false;
}

// ── Tips & Tricks parsing ───────────────────────────────────────────────────

void main() {
  group('tips parsing', () {
    test('cleanTipsJson strips ```json fences', () {
      expect(cleanTipsJson('```json\n["a"]\n```'), '["a"]');
      expect(cleanTipsJson('```\n["a"]\n```'), '["a"]');
      expect(cleanTipsJson('  ["a"]  '), '["a"]');
    });

    test('parseTopics parses a JSON array of strings', () {
      expect(parseTopics('["Q1?", "Q2?"]'), ['Q1?', 'Q2?']);
    });

    test('parseTopics tolerates fenced + dirty input', () {
      expect(parseTopics('```json\n["Q1?", 7, ""]\n```'), ['Q1?', '7']);
    });

    test('parseTopics returns empty on malformed input (never throws)', () {
      expect(parseTopics('not json'), isEmpty);
      expect(parseTopics('{"a":1}'), isEmpty);
      expect(parseTopics(''), isEmpty);
    });

    test('parseTips mirrors parseTopics', () {
      expect(parseTips('["Tip 1"]'), ['Tip 1']);
      expect(parseTips('oops'), isEmpty);
    });
  });

  group('TipsTricksScreen', () {
    testWidgets('locked state when not unlimited', (tester) async {
      final backend = backendWith(
        MockClient((_) async =>
            http.Response(jsonEncode({'isUnlimited': false}), 200)),
        token: 't',
      );
      await pumpScreen(tester, TipsTricksScreen(backend: backend));
      expect(find.text('Tips & Insights is locked'), findsOneWidget);
      expect(find.textContaining('requires a Tabs membership'), findsOneWidget);
      // No onboarding CTA when locked.
      expect(find.text('Generate Custom Tips'), findsNothing);
    });

    testWidgets('auth failure → locked state (honest, no crash)', (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response('{"error":"bad"}', 401)),
      );
      await pumpScreen(tester, TipsTricksScreen(backend: backend));
      expect(find.text('Tips & Insights is locked'), findsOneWidget);
    });

    testWidgets('unlimited + no topics → onboarding empty state', (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response(
            jsonEncode({'isUnlimited': true, 'entries': []}), 200)),
        token: 't',
      );
      await pumpScreen(tester, TipsTricksScreen(backend: backend));
      expect(find.text('Personalized Insights'), findsOneWidget);
      expect(find.text('Generate Custom Tips'), findsOneWidget);
    });

    testWidgets('generate → topics list renders from api/ai/advice',
        (tester) async {
      final backend = backendWith(
        MockClient((request) async {
          if (request.url.path == '/api/ai/advice') {
            expect(request.method, 'POST');
            return http.Response(
                jsonEncode({
                  'result': '["How can I sleep better?", "Med tips?"]'
                }),
                200);
          }
          return http.Response(
              jsonEncode({'isUnlimited': true, 'entries': []}), 200);
        }),
        token: 't',
      );
      await pumpScreen(tester, TipsTricksScreen(backend: backend));
      await tester.tap(find.text('Generate Custom Tips'));
      await tester.pumpAndSettle();
      expect(find.text('How can I sleep better?'), findsOneWidget);
      expect(find.text('Med tips?'), findsOneWidget);
    });

    testWidgets('AI failure → visible error, no topics', (tester) async {
      final backend = backendWith(
        MockClient((request) async {
          if (request.url.path == '/api/ai/advice') {
            return http.Response('boom', 500);
          }
          return http.Response(
              jsonEncode({'isUnlimited': true, 'entries': []}), 200);
        }),
        token: 't',
      );
      await pumpScreen(tester, TipsTricksScreen(backend: backend));
      await tester.tap(find.text('Generate Custom Tips'));
      await tester.pumpAndSettle();
      expect(find.text('Could not load your data'), findsOneWidget);
      expect(find.text('Personalized Insights'), findsNothing);
    });

    testWidgets('malformed AI result → error, never fabricated topics',
        (tester) async {
      final backend = backendWith(
        MockClient((request) async {
          if (request.url.path == '/api/ai/advice') {
            return http.Response(jsonEncode({'result': 'hello world'}), 200);
          }
          return http.Response(
              jsonEncode({'isUnlimited': true, 'entries': []}), 200);
        }),
        token: 't',
      );
      await pumpScreen(tester, TipsTricksScreen(backend: backend));
      await tester.tap(find.text('Generate Custom Tips'));
      await tester.pumpAndSettle();
      expect(find.textContaining('did not return any topics'), findsOneWidget);
    });
  });

  // ── Health Coach ──────────────────────────────────────────────────────────

  group('coach parsing', () {
    test('parseCoachSessions sorts newest first, skips bad rows', () {
      final sessions = parseCoachSessions([
        {'id': 'a', 'title': 'Old', 'updatedAt': 100},
        {'id': 'b', 'title': 'New', 'updatedAt': 200},
        {'nope': true},
        'garbage',
      ]);
      expect(sessions.map((s) => s.title), ['New', 'Old']);
    });

    test('groupCoachMessages groups + sorts oldest first', () {
      final grouped = groupCoachMessages([
        {'id': 'm2', 'sessionId': 's1', 'role': 'coach', 'content': 'hi', 'timestamp': 20},
        {'id': 'm1', 'sessionId': 's1', 'role': 'user', 'content': 'yo', 'timestamp': 10},
        {'id': 'm3', 'sessionId': 's2', 'role': 'user', 'content': 'x', 'timestamp': 5},
      ]);
      expect(grouped['s1']!.map((m) => m.content), ['yo', 'hi']);
      expect(grouped['s2']!.single.content, 'x');
    });

    test('formatCoachDate renders like the native history list', () {
      final dt = DateTime(2026, 10, 11, 18, 5);
      expect(formatCoachDate(dt.millisecondsSinceEpoch), 'Oct 11, 6:05 PM');
    });
  });

  group('HealthCoachScreen', () {
    testWidgets('locked state when not unlimited', (tester) async {
      final backend = backendWith(
        MockClient((_) async =>
            http.Response(jsonEncode({'isUnlimited': false}), 200)),
        token: 't',
      );
      await pumpScreen(tester, HealthCoachScreen(backend: backend));
      expect(find.text('Health Coach is locked'), findsOneWidget);
      expect(find.textContaining('requires a Tabs membership'), findsOneWidget);
    });

    testWidgets('session list renders from the sync pull', (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response(
            jsonEncode({
              'isUnlimited': true,
              'coachSessions': [
                {'id': 's1', 'title': 'Sleep chat', 'updatedAt': 1000},
              ],
              'coachMessages': [],
            }),
            200)),
        token: 't',
      );
      await pumpScreen(tester, HealthCoachScreen(backend: backend));
      expect(find.text('Sleep chat'), findsOneWidget);
    });

    testWidgets('empty sessions → honest empty state', (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response(
            jsonEncode(
                {'isUnlimited': true, 'coachSessions': [], 'coachMessages': []}),
            200)),
        token: 't',
      );
      await pumpScreen(tester, HealthCoachScreen(backend: backend));
      expect(find.text('No chats yet.'), findsOneWidget);
    });
  });

  group('CoachChatScreen', () {
    MockClient coachClient(String reply) {
      return MockClient((request) async {
        if (request.url.path == '/api/ai/coach') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['messages'], isA<List>());
          return http.Response(jsonEncode({'result': reply}), 200);
        }
        return http.Response('{}', 200);
      });
    }

    testWidgets('send → real reply renders verbatim', (tester) async {
      final backend = backendWith(coachClient('Drink more water.'), token: 't');
      await pumpScreen(tester, CoachChatScreen(backend: backend));
      await tester.enterText(find.byType(TextField), 'I feel tired');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(find.text('I feel tired'), findsOneWidget);
      expect(find.text('Drink more water.'), findsOneWidget);
    });

    testWidgets('prior session messages render', (tester) async {
      final backend = backendWith(coachClient('x'), token: 't');
      await pumpScreen(
        tester,
        CoachChatScreen(
          backend: backend,
          initialMessages: const [
            CoachChatMessage(
                id: 'm1',
                sessionId: 's1',
                role: 'user',
                content: 'Hello coach',
                timestamp: 1),
            CoachChatMessage(
                id: 'm2',
                sessionId: 's1',
                role: 'coach',
                content: 'Hi there',
                timestamp: 2),
          ],
        ),
      );
      expect(find.text('Hello coach'), findsOneWidget);
      expect(find.text('Hi there'), findsOneWidget);
    });

    testWidgets('AI failure → visible error, never a fabricated reply',
        (tester) async {
      final backend = backendWith(
        MockClient((request) async {
          if (request.url.path == '/api/ai/coach') {
            return http.Response('boom', 500);
          }
          return http.Response('{}', 200);
        }),
        token: 't',
      );
      await pumpScreen(tester, CoachChatScreen(backend: backend));
      await tester.enterText(find.byType(TextField), 'Hello?');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(find.text('Hello?'), findsOneWidget);
      expect(find.textContaining('could not reply'), findsOneWidget);
    });
  });

  // ── Key Metrics ───────────────────────────────────────────────────────────

  group('metrics helpers', () {
    test('nonZeroInt drops zeros and junk (biometric zero rule)', () {
      expect(nonZeroInt(72), 72);
      expect(nonZeroInt(0), isNull);
      expect(nonZeroInt('0'), isNull);
      expect(nonZeroInt(null), isNull);
      expect(nonZeroInt('abc'), isNull);
      expect(nonZeroInt('68'), 68);
    });
  });

  group('KeyMetricsScreen', () {
    testWidgets('profile values render in metric cards', (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response(
            jsonEncode({
              'profile': {'todayAvgHr': 78, 'weightKg': 70.0},
            }),
            200)),
        token: 't',
      );
      // Health Connect is unavailable in tests → hcConnected=false,
      // resting HR + calories show honest empty states.
      await pumpScreen(tester, KeyMetricsScreen(backend: backend, healthConnect: _FakeHc()));
      expect(find.text('78'), findsOneWidget);
      expect(find.text('BPM'), findsWidgets);
      expect(find.text('154'), findsOneWidget); // 70kg → lbs
      // The tile grid is lazy. With HC disconnected the night
      // metrics (Breathing Rate, Blood Oxygen, HRV) show their
      // calculated-at-night note, so Resting HR — in the last row,
      // outside the initial build range — is the tile carrying
      // "No Data Recorded". Scroll it into view.
      await tester.drag(find.byType(GridView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(find.text('No Data Recorded'), findsWidgets);
    });

    testWidgets('zero avg HR → No Data Recorded (never charted)',
        (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response(
            jsonEncode({
              'profile': {'todayAvgHr': 0},
            }),
            200)),
        token: 't',
      );
      await pumpScreen(tester, KeyMetricsScreen(backend: backend, healthConnect: _FakeHc()));
      expect(find.text('0'), findsNothing);
      expect(find.text('No Data Recorded'), findsWidgets);
    });

    testWidgets('auth failure → honest error, no crash', (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response('{"error":"bad"}', 401)),
      );
      await pumpScreen(tester, KeyMetricsScreen(backend: backend, healthConnect: _FakeHc()));
      expect(find.textContaining('Could not load your metrics'),
          findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
    });
  });

  // ── Trends ────────────────────────────────────────────────────────────────

  group('trends parsing', () {
    test('splitChips splits on commas and semicolons', () {
      expect(splitChips('headache, nausea; fatigue '),
          ['headache', 'nausea', 'fatigue']);
      expect(splitChips(''), isEmpty);
    });

    test('splitChips decodes JSON-array chip strings', () {
      // The chips field is a JSON array string (native encodes a list).
      expect(splitChips('["Heart Palpitations"]'), ['Heart Palpitations']);
      expect(splitChips('["Daily Ranking","Nausea"]'),
          ['Daily Ranking', 'Nausea']);
      // Empty array = no chips, never a literal "[]" symptom.
      expect(splitChips('[]'), isEmpty);
      expect(splitChips('[ ]'), isEmpty);
      // Malformed array syntax is machine text — yields nothing.
      expect(splitChips('["broken"'), isEmpty);
    });

    test('parseTrendsEntries accepts string id/timestamp (int8 JSON)', () {
      // node-pg serializes Postgres bigint columns as JSON strings.
      // Cross-checked against the live DB: local_id 639 =
      // 1791747393624 ms = Oct 11, 2026 1:36 PM MDT (hour 13);
      // local_id 635 = 1791738774130 = 11:12 AM MDT (hour 11).
      final out = parseTrendsEntries([
        {
          'id': '639',
          'body': 'x',
          'timestamp': '1791747393624',
          'categoryId': 8,
          'chips': '[]',
        },
        {
          'id': '635',
          'body': 'y',
          'timestamp': '1791738774130',
          'categoryId': '6',
          'chips': '["Daily Ranking"]',
        },
      ]);
      expect(out[0].id, 639);
      expect(out[0].timestamp, 1791747393624);
      expect(out[1].timestamp, 1791738774130);
      expect(out[1].categoryId, 6);
      final dt = DateTime.fromMillisecondsSinceEpoch(out[0].timestamp);
      expect(dt.year, 2026);
      expect(dt.month, 10);
      expect(dt.day, isNot(0)); // a real day, not epoch 0
    });

    test('formatEntryDate renders like native rows', () {
      final dt = DateTime(2026, 10, 11, 18, 5);
      expect(
          formatEntryDate(dt.millisecondsSinceEpoch), '6:05 PM, Oct 11');
    });
  });

  group('TrendsScreen', () {
    Map<String, dynamic> trendsPull() {
      final now = DateTime.now();
      final todayNoon =
          DateTime(now.year, now.month, now.day, 12).millisecondsSinceEpoch;
      return {
        'entries': [
          {
            'id': 1,
            'body': 'Morning check-in',
            'timestamp': todayNoon,
            'categoryId': 1,
            'chips': 'headache, nausea'
          },
          {
            'id': 2,
            'body': 'Evening log',
            'timestamp': todayNoon + 3600000,
            'categoryId': 2,
            'chips': 'headache'
          },
        ],
        'categories': [
          {'id': 1, 'name': 'Symptoms', 'colorHex': '#7C6EFF'},
          {'id': 2, 'name': 'Mood', 'colorHex': '#42A5F5'},
        ],
        'insights': [
          {
            'id': 'i1',
            'text': 'You log most in the morning.',
            'type': 'pattern',
            'dateRangeText': 'Last 30 days',
            'isDismissed': false,
            'timestamp': 10
          },
        ],
      };
    }

    // The screen builds lazily (CustomScrollView) — below-fold content
    // only exists once scrolled into view.
    Future<void> reveal(WidgetTester tester, String text) async {
      await tester.scrollUntilVisible(find.text(text), 300,
          scrollable: find
              .descendant(
                  of: find.byType(CustomScrollView),
                  matching: find.byType(Scrollable))
              .first);
      expect(find.text(text), findsOneWidget);
    }

    Future<void> scrollToBottom(WidgetTester tester) async {
      for (var i = 0; i < 5; i++) {
        await tester.drag(
            find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pumpAndSettle();
      }
    }

    testWidgets('entries → volume card, chart, categories',
        (tester) async {
      final backend = backendWith(
        MockClient((_) async =>
            http.Response(jsonEncode(trendsPull()), 200)),
        token: 't',
      );
      await pumpScreen(tester, TrendsScreen(backend: backend));
      expect(find.text('2 Total Entries'), findsOneWidget);
      expect(find.text('Symptoms'), findsOneWidget);
      expect(find.text('Mood'), findsOneWidget);
      // Round 20b: the Patterns section is gone — its insight text
      // must not render anywhere, even after scrolling to the bottom.
      // Round 20c: the Heart rate over time section is gone too.
      await reveal(tester, 'Category Focus');
      await scrollToBottom(tester);
      expect(find.text('You log most in the morning.'), findsNothing);
      expect(find.text('PATTERNS'), findsNothing);
      expect(find.text('HEART RATE OVER TIME'), findsNothing);
      expect(find.text('No heart rate history yet'), findsNothing);
    });

    testWidgets('empty entries → honest empty states, no crash',
        (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response(
            jsonEncode(
                {'entries': [], 'insights': [], 'profile': {}}),
            200)),
        token: 't',
      );
      await pumpScreen(tester, TrendsScreen(backend: backend));
      expect(find.text('No logs yet'), findsOneWidget);
      // Round 20c: no Heart rate section at the bottom anymore.
      await scrollToBottom(tester);
      expect(find.text('HEART RATE OVER TIME'), findsNothing);
      expect(find.text('No heart rate history yet'), findsNothing);
      expect(find.text('No patterns yet'), findsNothing);
    });

    testWidgets('auth failure → honest error, no crash', (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response('{"error":"bad"}', 401)),
      );
      await pumpScreen(tester, TrendsScreen(backend: backend));
      expect(find.textContaining('Could not load your data'), findsOneWidget);
    });

    testWidgets('malformed payload → honest empty, never a crash',
        (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response(
            jsonEncode({
              'entries': 'not-a-list',
              'insights': {'weird': true},
              'profile': {'something': '[[broken'},
            }),
            200)),
        token: 't',
      );
      await pumpScreen(tester, TrendsScreen(backend: backend));
      expect(find.text('No logs yet'), findsOneWidget);
      await scrollToBottom(tester);
      expect(find.text('HEART RATE OVER TIME'), findsNothing);
      expect(find.text('No heart rate history yet'), findsNothing);
    });
  });
}
