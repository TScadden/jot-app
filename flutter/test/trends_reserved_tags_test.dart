import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/trends_screen.dart';

import 'test_helpers.dart';

/// Vera round-2 Condition 2 (feat/checkin-merged-flow): the reserved
/// internal data tags — `Flare Day` (flareTag), `Good Day`
/// (goodDayTag), `Daily Ranking` (feelingCheckInTag) — are NOT display
/// copy (Juno ruling Item 6 / §5) and must never render as chips in
/// the Trends "MOST USED SYMPTOMS" dialog. `_topChips` therefore
/// excludes them from its counts. Stored entry chips are untouched;
/// ordinary user chips on the very same entries still count.
///
/// Harness mirrors test/trends_r36_test.dart (real sync-pull shapes:
/// int8 fields as strings, chips as a JSON-array string).

TabsBackend backendWith(MockClient client, {String? token}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

Future<void> pumpTrends(WidgetTester tester, Map<String, dynamic> pull) async {
  final backend = backendWith(
    MockClient((_) async => http.Response(jsonEncode(pull), 200)),
    token: 't',
  );
  await tester.pumpWidget(MaterialApp(home: TrendsScreen(backend: backend)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// One entry in the real server shape: every int8 field a string.
Map<String, dynamic> sEntry(
  int id,
  String body,
  DateTime when, {
  int categoryId = 1,
  String chips = '[]',
}) => {
  'id': '$id',
  'body': body,
  'timestamp': '${when.millisecondsSinceEpoch}',
  'categoryId': '$categoryId',
  'chips': chips,
};

List<Map<String, dynamic>> sCategories() => [
  {'id': '1', 'name': 'Symptoms', 'colorHex': '#7C6EFF'},
  {'id': '2', 'name': 'Mood', 'colorHex': '#42A5F5'},
  {'id': '3', 'name': 'Medication', 'colorHex': '#66BB6A'},
];

void main() {
  // The sync-pull cache is STATIC and session-keyed; reset between
  // cases so one case's cached pull cannot serve the next (r36 note).
  setUp(TabsBackend.debugResetSharedCaches);

  group('Trends top chips — reserved tags excluded (Vera C2)', () {
    testWidgets(
      'reserved tags never render; user chips on the same entries count',
      (tester) async {
        final now = DateTime.now();
        DateTime at(int hour) => DateTime(now.year, now.month, now.day, hour);
        await pumpTrends(tester, {
          'entries': [
            // Flare record: reserved tag + real severity/type chips.
            sEntry(
              501,
              'flare log',
              at(8),
              chips: '["Flare Day", "Severe", "Migraine"]',
            ),
            // Good-day record: reserved tag + a real option chip.
            sEntry(502, 'good log', at(9), chips: '["Good Day", "Energy"]'),
            // Feeling check-in record: reserved tag only.
            sEntry(503, 'check-in log', at(10), chips: '["Daily Ranking"]'),
            // Case/whitespace variants of all three reserved tags on
            // one entry, plus one ordinary chip.
            sEntry(
              504,
              'variant log',
              at(11),
              chips: '[" flare day ", "GOOD DAY", "daily ranking", "Nausea"]',
            ),
            sEntry(505, 'nausea log a', at(12), chips: '["Nausea"]'),
            sEntry(506, 'nausea log b', at(13), chips: '["Nausea"]'),
          ],
          'categories': sCategories(),
          'profile': <String, dynamic>{},
        });

        await tester.tap(find.byIcon(Icons.list));
        await tester.pump();
        expect(find.text('MOST USED SYMPTOMS'), findsOneWidget);

        // No reserved tag renders, in stored or variant casing.
        expect(find.text('Flare Day'), findsNothing);
        expect(find.text('flare day'), findsNothing);
        expect(find.text('Good Day'), findsNothing);
        expect(find.text('GOOD DAY'), findsNothing);
        expect(find.text('Daily Ranking'), findsNothing);
        expect(find.text('daily ranking'), findsNothing);

        // Ordinary chips on those same entries still count, merged
        // across casings exactly as before: Nausea 1 + 1 + 1 = 3.
        expect(find.text('Nausea'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
        expect(find.text('Severe'), findsOneWidget);
        expect(find.text('Migraine'), findsOneWidget);
        expect(find.text('Energy'), findsOneWidget);
      },
    );

    testWidgets('entries with ONLY reserved tags → honest empty sheet', (
      tester,
    ) async {
      final now = DateTime.now();
      DateTime at(int hour) => DateTime(now.year, now.month, now.day, hour);
      await pumpTrends(tester, {
        'entries': [
          sEntry(
            601,
            'flare only',
            at(8),
            chips: '["Flare Day", "Daily Ranking"]',
          ),
          sEntry(602, 'good only', at(9), chips: '["Good Day"]'),
        ],
        'categories': sCategories(),
        'profile': <String, dynamic>{},
      });

      await tester.tap(find.byIcon(Icons.list));
      await tester.pump();
      expect(find.text('No symptoms logged yet.'), findsOneWidget);
      expect(find.text('Flare Day'), findsNothing);
      expect(find.text('Good Day'), findsNothing);
      expect(find.text('Daily Ranking'), findsNothing);
    });
  });
}
