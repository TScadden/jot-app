import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/blood_pressure_tool_screen.dart';
import 'package:tabs_lab/src/features/tools/community_screen.dart';
import 'package:tabs_lab/src/features/tools/food_screen.dart';
import 'package:tabs_lab/src/features/tools/research_screen.dart';

import 'test_helpers.dart';

/// Builds a TabsBackend against a mock HTTP client with a token.
TabsBackend backendWith(MockClient client, {String? token}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

/// HealthConnectService whose channel answers "not connected" — avoids the
/// connected path's secure-storage write so widget tests stay channel-free.
HealthConnectService disconnectedHc() {
  const channel = MethodChannel(HealthConnectService.channelName);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
    switch (call.method) {
      case 'isAvailable':
        return false;
      case 'getGrantedPermissions':
        return <String>[];
      case 'readBloodPressure':
        return <Map<String, Object>>[];
    }
    return null;
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding.instance
      .defaultBinaryMessenger
      .setMockMethodCallHandler(channel, null));
  return HealthConnectService(channel: channel);
}

BpRecord bp(int sys, int dia, int t) =>
    BpRecord(systolic: sys, diastolic: dia, timeEpochMs: t);

void main() {
  group('mergeBpRecords', () {
    test('merges manual + HC, newest first', () {
      final merged = mergeBpRecords(
        manual: [bp(118, 76, 1000)],
        healthConnect: [bp(122, 80, 2000)],
      );
      expect(merged.length, 2);
      expect(merged.first.record.timeEpochMs, 2000);
      expect(merged.first.source, BpSource.healthConnect);
      expect(merged.last.source, BpSource.manual);
    });

    test('dedupes by timestamp; HC wins the collision', () {
      final merged = mergeBpRecords(
        manual: [bp(110, 70, 1000)],
        healthConnect: [bp(120, 80, 1000)],
      );
      expect(merged.length, 1);
      expect(merged.single.source, BpSource.healthConnect);
      expect(merged.single.record.systolic, 120);
    });

    test('founder rule: 0/0 is a failed read and is dropped', () {
      final merged = mergeBpRecords(
        manual: [bp(0, 0, 1000), bp(118, 76, 2000)],
        healthConnect: [bp(0, 80, 3000), bp(120, 0, 4000)],
      );
      expect(merged.map((r) => r.record.timeEpochMs), [2000]);
    });

    test('empty in → empty out', () {
      expect(mergeBpRecords(manual: const [], healthConnect: const []),
          isEmpty);
    });
  });

  group('splitFoodItems', () {
    test('splits on commas and newlines, lowercases, trims, dedupes', () {
      expect(
        splitFoodItems('Spinach, coffee\nAvocado, spinach\n\n'),
        ['spinach', 'coffee', 'avocado'],
      );
    });

    test('blank input → empty', () {
      expect(splitFoodItems('  \n, '), isEmpty);
    });
  });

  group('buildFoodPrompt', () {
    test('contains the foods and the five topics', () {
      final prompt = buildFoodPrompt(['spinach', 'coffee']);
      expect(prompt, contains('spinach, coffee'));
      for (final topic in foodCoreTopics) {
        expect(prompt, contains('"$topic"'));
      }
      expect(prompt, contains('MUST be exactly one of "High", "Medium", or "Low"'));
    });
  });

  group('parseFoodAiResponse', () {
    const responseBody = '''
```json
{
  "spinach": {
    "Histamine": { "level": "High", "reasoning": "Rich in histamine." },
    "Sugar": { "level": "Low", "reasoning": "Low glycemic load." },
    "FODMAP": { "level": "Low", "reasoning": "Low FODMAP serving." },
    "Inflammation": { "level": "Low", "reasoning": "Antioxidants." },
    "Oxalate": { "level": "High", "reasoning": "Very high oxalate." }
  }
}
```''';

    test('parses fenced JSON into five topics per food', () {
      final results = parseFoodAiResponse(responseBody);
      expect(results.length, 1);
      final food = results.single;
      expect(food.foodName, 'spinach');
      expect(food.levels.length, 5);
      expect(food.levels[0].topicName, 'Histamine');
      expect(food.levels[0].level, 'High');
      expect(food.levels[0].reasoning, 'Rich in histamine.');
    });

    test('missing topics fall back to Low / No details available.', () {
      final results = parseFoodAiResponse('{"coffee": {}}');
      expect(results.single.levels.length, 5);
      for (final lvl in results.single.levels) {
        expect(lvl.level, 'Low');
        expect(lvl.reasoning, 'No details available.');
      }
    });

    test('garbage → FormatException so the caller shows the visible error',
        () {
      expect(() => parseFoodAiResponse('not json at all'),
          throwsA(isA<FormatException>()));
    });
  });

  group('buildFoodAiRequestBody', () {
    test('matches the native AiRequest shape', () {
      final body = buildFoodAiRequestBody(['spinach']);
      final entries = body['entries'] as List;
      final entry = entries.single as Map;
      expect(entry['id'], 99999);
      expect(entry['categoryId'], 7);
      expect(entry['body'], 'Food Sensitivity Scan');
      expect(entry['chips'], '');
      expect(entry['manualText'], 'Food Sensitivity Scan');
      expect(entry['timestamp'], isA<int>());
      expect(body['categories'], isEmpty);
      expect(body['userContext'], contains('spinach'));
    });
  });

  // Round 18b: the research library is bundled assets, not sync-pull
  // `documents`. See tools_r18b_test.dart for ResearchEntry parsing,
  // entriesForCondition filtering, and loadResearchEntries tests.

  group('buildLeaderboard', () {
    test('sorts friends by level, highest first', () {
      final friends = [
        const FriendDto(
            id: 'a', nickname: 'a', tag: '1', status: '', level: 10),
        const FriendDto(
            id: 'b', nickname: 'b', tag: '2', status: '', level: 50),
        const FriendDto(
            id: 'c', nickname: 'c', tag: '3', status: '', level: 25),
      ];
      final board = buildLeaderboard(friends);
      expect(board.map((f) => f.nickname), ['b', 'c', 'a']);
    });
  });

  group('auth failure → honest empty (never invented, never crash)', () {
    test('fetchManualBpLogs 401 → empty', () async {
      final backend = backendWith(
        MockClient((_) async => http.Response('{"error":"bad"}', 401)),
token: 't',
      );
      expect(await backend.fetchManualBpLogs(), isEmpty);
    });

    test('friends + notifications 401 → empty lists', () async {
      final backend = backendWith(
        MockClient((_) async => http.Response('{"error":"bad"}', 401)),
token: 't',
      );
      expect(await backend.fetchFriendsList(), isEmpty);
      expect(await backend.fetchFriendNotifications(), isEmpty);
    });

    test('postAi with no token → null (no AI call fires)', () async {
      final backend = backendWith(MockClient((_) async {
        fail('no request should be made without a token');
      }));
      expect(await backend.postAi('/api/ai/advice', {}), isNull);
    });

    test('postAi 500 → null (caller shows the visible error)', () async {
      final backend = backendWith(
        MockClient((_) async => http.Response('boom', 500)),
token: 't',
      );
      expect(await backend.postAi('/api/ai/advice', {'a': 1}), isNull);
    });
  });

  group('BloodPressureToolScreen widget', () {
    testWidgets('empty state is honest: -- / -- and no crash', (tester) async {
      final backend = backendWith(
        MockClient(
            (_) async => http.Response('{"profile": {}}', 200)),
token: 't',
      );
      await tester.pumpWidget(MaterialApp(
        home: BloodPressureToolScreen(
            backend: backend, healthConnect: disconnectedHc()),
      ));
      await tester.pumpAndSettle();
      expect(find.text('-- / --'), findsOneWidget);
      expect(find.text('No readings logged yet'), findsOneWidget);
      expect(
          find.text('Health Connect is not connected. Showing manual readings only.'),
          findsOneWidget);
    });

    testWidgets('manual records render with latest spotlighted', (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response(
            jsonEncode({
              'profile': {
                'manualBloodPressureLogs': jsonEncode([
                  {'systolic': 118, 'diastolic': 76, 'timeEpochMs': 1700000000000},
                  {'systolic': 122, 'diastolic': 80, 'timeEpochMs': 1700100000000},
                ])
              }
            }),
            200)),
token: 't',
      );
      await tester.pumpWidget(MaterialApp(
        home: BloodPressureToolScreen(
            backend: backend, healthConnect: disconnectedHc()),
      ));
      await tester.pumpAndSettle();
      // Latest (newest) is spotlighted at the top.
      expect(find.text('122 / 80'), findsOneWidget);
      // Both rows appear in the history list.
      expect(find.text('118 / 76 mmHg'), findsOneWidget);
      expect(find.text('122 / 80 mmHg'), findsOneWidget);
    });
  });

  group('FoodToolScreen widget', () {
    testWidgets('AI failure → visible error, no fake results', (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response('boom', 500)),
token: 't',
      );
      // R68 repair: inject the in-memory history store (the R48B
      // pattern). The default secure-storage store's channel futures
      // never complete under FakeAsync, which wedged the check and
      // left timers pending at teardown.
      await tester.pumpWidget(MaterialApp(
          home: FoodToolScreen(
              backend: backend, historyStore: _MemFoodStore())));
      await tester.enterText(
          find.byType(TextField), 'spinach, coffee');
      await tester.pump(); // rebuild so the Check button enables
      await tester.tap(find.text('Check Sensitivity'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Could not load your data'), findsOneWidget);
      // No fabricated result cards.
      expect(find.text('Spinach'), findsNothing);
      expect(find.text('Coffee'), findsNothing);
    });

    testWidgets('AI success renders parsed results', (tester) async {
      final result = {
        'spinach': {
          'Histamine': {'level': 'High', 'reasoning': 'Rich in histamine.'},
          'Sugar': {'level': 'Low', 'reasoning': 'Low sugar.'},
          'FODMAP': {'level': 'Low', 'reasoning': 'Low FODMAP.'},
          'Inflammation': {'level': 'Low', 'reasoning': 'Anti-inflammatory.'},
          'Oxalate': {'level': 'High', 'reasoning': 'High oxalate.'},
        },
      };
      final backend = backendWith(
        MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/ai/advice');
          return http.Response(jsonEncode({'result': jsonEncode(result)}), 200);
        }),
token: 't',
      );
      await tester.pumpWidget(MaterialApp(
          home: FoodToolScreen(
              backend: backend, historyStore: _MemFoodStore())));
      await tester.enterText(find.byType(TextField), 'spinach');
      await tester.pump(); // rebuild so the Check button enables
      await tester.tap(find.text('Check Sensitivity'));
      await tester.pumpAndSettle();
      expect(find.text('Spinach'), findsOneWidget);
      expect(find.text('High'), findsNWidgets(2)); // Histamine + Oxalate
      // Recent searches get a chip for this session (below the fold in the
      // test viewport, so offstage must be included).
      expect(find.text('Recently Checked', skipOffstage: false),
          findsOneWidget);
    });
  });

  group('CommunityToolScreen widget', () {
    MockClient communityClient() => MockClient((request) async {
          if (request.url.path == '/api/friends/list') {
            return http.Response(
                jsonEncode({
                  'friends': [
                    {
                      'id': 'f1',
                      'nickname': 'Nudy',
                      'tag': '12345',
                      'status': 'Online',
                      'level': 42
                    },
                    {
                      'id': 'f2',
                      'nickname': 'Javin',
                      'tag': '23456',
                      'status': 'Offline',
                      'level': 60
                    },
                  ]
                }),
                200);
          }
          if (request.url.path == '/api/friends/notifications') {
            return http.Response(
                jsonEncode({
                  'notifications': [
                    {
                      'id': 7,
                      'type': 'friend_request',
                      'message': 'Nudy sent you a friend request',
                      'isRead': false,
                      'createdAt': 'Oct 10',
                      'senderNickname': 'Nudy',
                      'senderTag': '12345'
                    },
                  ]
                }),
                200);
          }
          return http.Response('{}', 404);
        });

    testWidgets('renders friends, leaderboard order, and unread badge',
        (tester) async {
      final backend = backendWith(communityClient(), token: 't');
      await tester.pumpWidget(
          MaterialApp(home: CommunityToolScreen(backend: backend)));
      await tester.pumpAndSettle();
      expect(find.text('Nudy'), findsWidgets);
      expect(find.text('#12345'), findsWidgets);
      expect(find.text('42 pts'), findsWidgets);
      // Round 18b: no presence badge is ever rendered (native never had
      // one; the server has no last-active data). "Online"/"Offline"
      // must not appear anywhere.
      expect(find.text('Online'), findsNothing);
      expect(find.text('Offline'), findsNothing);
      // Leaderboard ranks highest level first.
      expect(find.text('#1'), findsOneWidget);
      // Notification opens in the sheet with the unread message.
      await tester.tap(find.bySemanticsLabel('Notifications'));
      await tester.pumpAndSettle();
      expect(
          find.text('Nudy sent you a friend request'), findsOneWidget);
    });

    testWidgets('empty friends/notifications stay honest', (tester) async {
      final backend = backendWith(
        MockClient((_) async => http.Response('{}', 200)),
token: 't',
      );
      await tester.pumpWidget(
          MaterialApp(home: CommunityToolScreen(backend: backend)));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'No friends added yet. Add friends using their Nickname#ID!'),
          findsOneWidget);
      // R68 repair (R48C supersession): the leaderboard now always
      // includes the user's own row (native parity), so the empty
      // state is the self row alone — the old "No scores yet" copy no
      // longer exists. Honest empty = friends copy above + self row.
      expect(find.text('You'), findsOneWidget);
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('0 pts'), findsOneWidget);
    });
  });

  // Round 18b: the library is bundled assets; entries filter by the
  // user's conditions. A fake AssetBundle drives the screen in tests.
  group('ResearchToolScreen widget', () {
    _TestBundle bundleWith(List<Map<String, dynamic>> entries) {
      final files = <String, String>{};
      final manifest = <String, Object?>{};
      for (var i = 0; i < entries.length; i++) {
        final path = 'assets/research/e$i.json';
        manifest[path] = {};
        files[path] = jsonEncode(entries[i]);
      }
      files['AssetManifest.json'] = jsonEncode(manifest);
      return _TestBundle(files);
    }

    Map<String, dynamic> researchEntryJson({
      required String id,
      required String title,
      required List<String> takeaways,
      required List<String> conditionTags,
      String detail = 'Full detail text here.',
      String sourceUrl = 'https://example.com/source',
    }) =>
        {
          'id': id,
          'title': title,
          'summary': 'Summary of $title.',
          'takeaways': takeaways,
          'detail': detail,
          'sourceName': 'Example Source',
          'sourceUrl': sourceUrl,
          'conditionTags': conditionTags,
        };

    TabsBackend backendWithConditions(List<String> conditions) =>
        backendWith(
          MockClient((_) async => http.Response(
              jsonEncode({
                'profile': {'conditions': jsonEncode(conditions)},
              }),
              200)),
          token: 'tok',
        );

    testWidgets('entries render filtered by condition and expand',
        (tester) async {
      final bundle = bundleWith([
        researchEntryJson(
          id: 'pots-1',
          title: 'POTS overview',
          takeaways: ['Drink more fluids', 'Increase salt intake'],
          conditionTags: ['POTS'],
        ),
        researchEntryJson(
          id: 'mcas-1',
          title: 'MCAS basics',
          takeaways: ['Avoid triggers'],
          conditionTags: ['MCAS'],
        ),
      ]);
      await tester.pumpWidget(MaterialApp(
          home: ResearchToolScreen(
              backend: backendWithConditions(['POTS']), bundle: bundle)));
      await tester.pumpAndSettle();
      // Disclaimer always visible.
      expect(find.textContaining('For educational purposes only'),
          findsOneWidget);
      // Only the POTS entry shows for the POTS condition.
      expect(find.text('POTS overview'), findsOneWidget);
      expect(find.text('MCAS basics'), findsNothing);
      // Takeaway bullets render.
      expect(find.textContaining('Drink more fluids'), findsOneWidget);
      // Tap to expand → detail shows.
      await tester.tap(find.text('POTS overview'));
      await tester.pumpAndSettle();
      expect(find.text('Full detail text here.'), findsOneWidget);
    });

    testWidgets('no entries for condition → honest empty', (tester) async {
      final bundle = bundleWith([
        researchEntryJson(
          id: 'mcas-1',
          title: 'MCAS basics',
          takeaways: ['Avoid triggers'],
          conditionTags: ['MCAS'],
        ),
      ]);
      await tester.pumpWidget(MaterialApp(
          home: ResearchToolScreen(
              backend: backendWithConditions(['POTS']), bundle: bundle)));
      await tester.pumpAndSettle();
      expect(find.text('Nothing here yet'), findsOneWidget);
      expect(find.text('MCAS basics'), findsNothing);
    });

    testWidgets('no conditions → prompt to add them', (tester) async {
      final bundle = bundleWith([]);
      await tester.pumpWidget(MaterialApp(
          home: ResearchToolScreen(
              backend: backendWithConditions([]), bundle: bundle)));
      await tester.pumpAndSettle();
      expect(find.text('No conditions saved yet'), findsOneWidget);
    });
  });
}

/// In-memory [FoodHistoryStore] — the R48B pattern: IO completes
/// instantly, so no secure-storage channel future can wedge a test.
class _MemFoodStore implements FoodHistoryStore {
  String? value;

  @override
  Future<String?> loadEncyclopediaJson() async => value;

  @override
  Future<void> saveEncyclopediaJson(String json) async {
    value = json;
  }
}

/// In-memory AssetBundle for Research widget tests.
class _TestBundle extends AssetBundle {
  _TestBundle(this.strings);

  final Map<String, String> strings;

  @override
  Future<ByteData> load(String key) =>
      throw UnsupportedError('not needed');

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    final s = strings[key];
    if (s == null) throw FlutterError('asset not found: $key');
    return s;
  }
}
