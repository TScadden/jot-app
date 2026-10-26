import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/trends_screen.dart';
import 'package:tabs_lab/src/theme/skeleton.dart';

import 'test_helpers.dart';

/// Round 36 — founder-directed Trends verification round.
///
/// Fixtures are shaped like the REAL sync-pull payload:
/// - node-pg serializes Postgres int8 (bigint) as JSON STRINGS, so
///   entry/category `id`, `timestamp`, and `categoryId` arrive as
///   numeric strings, not numbers.
/// - `chips` arrives as a JSON-array STRING (DB default literally
///   `'[]'`).
/// - `insights` carries ~1544 rows including machine-series blobs
///   (`biometrics_<date>_v6` JSON) and HTML report text — none of it
///   may ever reach the Trends screen (Patterns removed in Round 20b).

TabsBackend backendWith(MockClient client, {String? token}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> pumpTrends(WidgetTester tester, Map<String, dynamic> pull) async {
  final backend = backendWith(
    MockClient((_) async => http.Response(jsonEncode(pull), 200)),
    token: 't',
  );
  await pumpScreen(tester, TrendsScreen(backend: backend));
}

Finder mainScrollable() => find
    .descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    )
    .first;

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
  // Oct 26, 2026 perf package: the sync-pull and habits caches are
  // STATIC and session-keyed, and cases in this file reuse one session
  // token across fresh fake servers — reset between cases so one
  // case's cached pull/habits body cannot be served to the next case.
  setUp(TabsBackend.debugResetSharedCaches);
  group('R36 parsing (real server shapes)', () {
    test('parseTrendsCategories parses string int8 ids, keeps names', () {
      final cats = parseTrendsCategories(sCategories());
      expect(cats.map((c) => c.id), [1, 2, 3]);
      expect(cats.map((c) => c.name), ['Symptoms', 'Mood', 'Medication']);
    });

    test('parseEpochMs accepts ISO-8601 strings', () {
      final dt = DateTime(2026, 10, 11, 13, 36);
      expect(parseEpochMs(dt.toIso8601String()), dt.millisecondsSinceEpoch);
      expect(parseEpochMs('1791747393624'), 1791747393624);
      expect(parseEpochMs(1791747393624), 1791747393624);
      expect(parseEpochMs('junk'), 0);
      expect(parseEpochMs(null), 0);
    });
  });

  group('R36 Category Focus with string-shaped payload', () {
    Map<String, dynamic> pull() {
      final now = DateTime.now();
      final today9 = DateTime(now.year, now.month, now.day, 9);
      final yday10 = DateTime(now.year, now.month, now.day - 1, 10);
      return {
        'entries': [
          sEntry(11, 'today symptom log', today9, categoryId: 1),
          sEntry(12, 'yday mood log', yday10, categoryId: 2),
          sEntry(13, 'yday med log', yday10, categoryId: 3),
        ],
        'categories': sCategories(),
        'profile': <String, dynamic>{},
      };
    }

    testWidgets('category rows show real names, scoped to the view', (
      tester,
    ) async {
      await pumpTrends(tester, pull());
      await tester.scrollUntilVisible(
        find.text('Category Focus'),
        200,
        scrollable: mainScrollable(),
      );
      // Today (day mode): only today's Symptoms entry is in scope.
      expect(find.text('Symptoms'), findsOneWidget);
      expect(find.text('Category 1'), findsNothing);
      expect(find.text('Mood'), findsNothing); // yesterday — out of scope

      // All-time mode: every category appears under its real name.
      await tester.scrollUntilVisible(
        find.text('3 Total Entries'),
        200,
        scrollable: mainScrollable(),
      );
      await tester.tap(find.text('3 Total Entries'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Medication'),
        200,
        scrollable: mainScrollable(),
      );
      expect(find.text('Symptoms'), findsOneWidget);
      expect(find.text('Mood'), findsOneWidget);
      expect(find.text('Medication'), findsOneWidget);
      expect(find.text('Category 1'), findsNothing);
      expect(find.text('Category 2'), findsNothing);
      expect(find.text('Category 3'), findsNothing);
    });
  });

  group('R36 log volume with string-shaped payload', () {
    Map<String, dynamic> pull() {
      final now = DateTime.now();
      final today9 = DateTime(now.year, now.month, now.day, 9);
      final today15 = DateTime(now.year, now.month, now.day, 15);
      return {
        'entries': [
          sEntry(639, 'morning dose', today9),
          sEntry(640, 'morning note', today9.add(const Duration(minutes: 30))),
          sEntry(641, 'afternoon log', today15),
        ],
        'categories': sCategories(),
        'profile': <String, dynamic>{},
      };
    }

    testWidgets('string timestamps bucket into the correct hours', (
      tester,
    ) async {
      await pumpTrends(tester, pull());
      expect(find.text('3 Total Entries'), findsOneWidget);
      expect(find.text('2'), findsOneWidget); // 9am bucket
      expect(find.text('1'), findsOneWidget); // 3pm bucket
    });

    testWidgets('hour tap lists entries with real dates, newest first', (
      tester,
    ) async {
      await pumpTrends(tester, pull());
      await tester.tap(find.text('9am'));
      await tester.pump();
      // Scroll to the LOWER card (oldest) so both are on screen.
      await tester.scrollUntilVisible(
        find.text('morning dose'),
        200,
        scrollable: mainScrollable(),
      );
      expect(find.text('morning note'), findsOneWidget);
      // Real rendered dates — never the epoch-zero "Dec 31, 1969".
      expect(find.textContaining('AM,'), findsWidgets);
      expect(find.textContaining('1969'), findsNothing);
      expect(find.textContaining('Dec 31'), findsNothing);
      // Newest first (native selectHour sorts by timestamp desc):
      // the 9:30 entry renders above the 9:00 entry.
      final noteDy = tester.getTopLeft(find.text('morning note')).dy;
      final doseDy = tester.getTopLeft(find.text('morning dose')).dy;
      expect(noteDy, lessThan(doseDy));
    });

    testWidgets('entry tap navigates with the parsed int id', (tester) async {
      int? navigated;
      final backend = backendWith(
        MockClient((_) async => http.Response(jsonEncode(pull()), 200)),
        token: 't',
      );
      await pumpScreen(
        tester,
        TrendsScreen(
          backend: backend,
          onNavigateToEntry: (id) => navigated = id,
        ),
      );
      await tester.tap(find.text('9am'));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('morning dose'),
        200,
        scrollable: mainScrollable(),
      );
      await tester.tap(find.text('morning dose'));
      await tester.pump();
      expect(navigated, 639);
    });

    testWidgets('day selector cannot page past today', (tester) async {
      await pumpTrends(tester, pull());
      expect(find.text('Today'), findsOneWidget);
      final next = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.chevron_right),
      );
      expect(next.onPressed, isNull); // disabled at today
      await tester.tap(find.byTooltip('Previous Day'));
      await tester.pump();
      expect(find.text('Yesterday'), findsOneWidget);
      await tester.tap(find.byTooltip('Next Day'));
      await tester.pump();
      expect(find.text('Today'), findsOneWidget);
    });
  });

  group('R36 symptoms sheet', () {
    testWidgets('counts merge across casings, no [] artifacts', (tester) async {
      final now = DateTime.now();
      final base = DateTime(now.year, now.month, now.day, 8);
      final entries = <Map<String, dynamic>>[
        for (var i = 0; i < 3; i++)
          sEntry(
            100 + i,
            'n$i',
            base.add(Duration(minutes: i)),
            chips: '["Nausea"]',
          ),
        for (var i = 0; i < 2; i++)
          sEntry(
            110 + i,
            'n${3 + i}',
            base.add(Duration(minutes: 10 + i)),
            chips: '["nausea"]',
          ),
        sEntry(
          120,
          'n5',
          base.add(const Duration(minutes: 20)),
          chips: '["NAUSEA", ""]',
        ),
        sEntry(121, 'plain', base.add(const Duration(minutes: 30))),
      ];
      await pumpTrends(tester, {
        'entries': entries,
        'categories': sCategories(),
        'profile': <String, dynamic>{},
      });

      await tester.tap(find.byIcon(Icons.list));
      await tester.pump();
      expect(find.text('MOST USED SYMPTOMS'), findsOneWidget);
      // 3 + 2 + 1 merged into a single 'Nausea' chip with count 6.
      expect(find.text('Nausea'), findsOneWidget);
      expect(find.text('6'), findsOneWidget);
      expect(find.text('[]'), findsNothing);
      expect(find.text('nausea'), findsNothing); // merged, not separate
    });

    testWidgets('selecting a symptom clears the hour filter (native parity)', (
      tester,
    ) async {
      final now = DateTime.now();
      final today9 = DateTime(now.year, now.month, now.day, 9);
      await pumpTrends(tester, {
        'entries': [
          sEntry(201, 'headache at nine', today9, chips: '["Headache"]'),
        ],
        'categories': sCategories(),
        'profile': <String, dynamic>{},
      });
      await tester.tap(find.text('9am'));
      await tester.pump();
      expect(find.text('LOGS AT 9 AM'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.list));
      await tester.pump();
      await tester.tap(find.text('Headache'));
      await tester.pump();
      // Native selectSymptom clears selectedHour.
      expect(find.text('LOGS AT 9 AM'), findsNothing);
      expect(find.text('LOG ACTIVITY BY HOUR'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text("LOGS FOR 'HEADACHE'"),
        200,
        scrollable: mainScrollable(),
      );
      expect(find.text("LOGS FOR 'HEADACHE'"), findsOneWidget);
    });

    testWidgets('no symptoms → honest empty sheet', (tester) async {
      final now = DateTime.now();
      final today9 = DateTime(now.year, now.month, now.day, 9);
      await pumpTrends(tester, {
        'entries': [sEntry(301, 'plain log', today9)],
        'categories': sCategories(),
        'profile': <String, dynamic>{},
      });
      await tester.tap(find.byIcon(Icons.list));
      await tester.pump();
      expect(find.text('No symptoms logged yet.'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);
    });
  });

  group('R36 loading + performance + insights hygiene', () {
    testWidgets('initial load shows a skeleton, never a blocking spinner', (
      tester,
    ) async {
      final completer = Completer<http.Response>();
      final backend = backendWith(
        MockClient((_) => completer.future),
        token: 't',
      );
      await tester.pumpWidget(
        MaterialApp(home: TrendsScreen(backend: backend)),
      );
      await tester.pump();
      expect(find.byType(SkeletonBox), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      completer.complete(
        http.Response(
          jsonEncode({'entries': [], 'categories': [], 'profile': {}}),
          200,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('No logs yet'), findsOneWidget);
    });

    testWidgets('full dataset: lazy list, no insight leakage, no crash', (
      tester,
    ) async {
      final now = DateTime.now();
      final today9 = DateTime(now.year, now.month, now.day, 9);
      final entries = <Map<String, dynamic>>[
        for (var i = 0; i < 580; i++)
          sEntry(
            2000 + i,
            'entry $i',
            today9.subtract(Duration(days: i % 30, minutes: i % 50)),
            categoryId: 1 + (i % 3),
            chips: i % 7 == 0 ? '["Fatigue"]' : '[]',
          ),
      ];
      final insights = <Map<String, dynamic>>[
        for (var i = 0; i < 1544; i++)
          if (i % 3 == 0)
            {
              'id': 'm$i',
              'type': 'Biometrics',
              'text': '{"biometrics_2026-10-11_v6": {"avgHr": 72}}',
              'timestamp': '${1700000000000 + i}',
            }
          else if (i % 3 == 1)
            {
              'id': 'b$i',
              'type': 'BodyLoad',
              'text': 'bodyload_blob_$i {"load": 0.42}',
              'timestamp': '${1700000000000 + i}',
            }
          else
            {
              'id': 'p$i',
              'type': 'pattern',
              'text': '<p>You <b>log</b> most in the morning.</p>',
              'timestamp': '${1700000000000 + i}',
            },
      ];
      await pumpTrends(tester, {
        'entries': entries,
        'categories': sCategories(),
        'insights': insights,
        'profile': <String, dynamic>{},
      });
      expect(find.text('580 Total Entries'), findsOneWidget);
      expect(find.byType(CustomScrollView), findsOneWidget);
      // Scroll the whole screen: no insight content of any kind.
      for (var i = 0; i < 6; i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pump();
      }
      expect(find.textContaining('biometrics_2026'), findsNothing);
      expect(find.textContaining('bodyload_blob'), findsNothing);
      expect(find.textContaining('<p>'), findsNothing);
      expect(find.textContaining('log</b>'), findsNothing);
      expect(find.text('You log most in the morning.'), findsNothing);
      expect(find.text('PATTERNS'), findsNothing);
      expect(find.text('HEART RATE OVER TIME'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('entries exist but none today → honest zero chart', (
      tester,
    ) async {
      final now = DateTime.now();
      final yday9 = DateTime(now.year, now.month, now.day - 1, 9);
      await pumpTrends(tester, {
        'entries': [sEntry(401, 'only yesterday', yday9)],
        'categories': sCategories(),
        'profile': <String, dynamic>{},
      });
      expect(find.text('1 Total Entries'), findsOneWidget);
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('No logs yet'), findsNothing); // there ARE logs
      expect(find.text('LOGS AT 9 AM'), findsNothing);
      await tester.tap(find.text('9am'));
      await tester.pump();
      // Hour selected but empty: no entries section appears.
      expect(find.text('Entries for this hour'), findsNothing);
      expect(find.text('only yesterday'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
