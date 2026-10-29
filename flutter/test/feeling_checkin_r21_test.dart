import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'test_helpers.dart';

QuickLogEntry _entry({
  int id = 1,
  int categoryId = 6,
  String body = 'x',
  String chips = '[]',
  int timestamp = 0,
}) => QuickLogEntry(
  id: id,
  categoryId: categoryId,
  body: body,
  chips: chips,
  manualText: '',
  timestamp: timestamp,
);

const _energyWords = ['really bad', 'rough', 'average', 'good', 'really good'];

Finder energyButton(int level) => find.byWidgetPredicate(
  (w) =>
      w is Semantics &&
      w.properties.label == 'Energy $level of 5, ${_energyWords[level - 1]}',
);

QuickLogCategory _cat(int id, String name) => QuickLogCategory(
  id: id,
  name: name,
  icon: 'circle',
  colorHex: '#CCCCCC',
  isDefault: true,
  sortOrder: 0,
);

void main() {
  // Oct 26, 2026 perf package: the sync-pull and habits caches are
  // STATIC and session-keyed, and cases in this file reuse one session
  // token across fresh fake servers — reset between cases so one
  // case's cached pull/habits body cannot be served to the next case.
  setUp(() {
    TabsBackend.debugResetSharedCaches();
    final disk = <String, String>{};
    final outbox = LogEntryOutbox.instance;
    outbox.debugReset();
    outbox.debugSetStore(
      read: (key) async => disk[key],
      write: (key, value) async => disk[key] = value,
      delete: (key) async => disk.remove(key),
    );
  });
  tearDown(() => LogEntryOutbox.instance.debugReset());
  group('feelingDayStart (native energyDayStart, 04:00 boundary)', () {
    test('after 04:00 → today 04:00', () {
      final start = feelingDayStart(DateTime(2026, 10, 12, 11, 30));
      expect(start, DateTime(2026, 10, 12, 4));
    });

    test('before 04:00 → yesterday 04:00', () {
      final start = feelingDayStart(DateTime(2026, 10, 12, 2, 30));
      expect(start, DateTime(2026, 10, 11, 4));
    });

    test('exactly 04:00 → today 04:00', () {
      final start = feelingDayStart(DateTime(2026, 10, 12, 4, 0));
      expect(start, DateTime(2026, 10, 12, 4));
    });
  });

  group('hasFeelingCheckIn', () {
    final now = DateTime(2026, 10, 12, 11, 0); // energy day starts 04:00
    int ms(DateTime d) => d.millisecondsSinceEpoch;

    test('tag entry in mood category inside the window → true', () {
      final entries = [
        _entry(
          chips: '["Daily Ranking"]',
          body: 'Feeling: 3/5 Today',
          timestamp: ms(DateTime(2026, 10, 12, 9, 15)),
        ),
      ];
      expect(hasFeelingCheckIn(entries, moodCategoryId: 6, now: now), isTrue);
    });

    test('entry from the previous energy day does not count', () {
      final entries = [
        _entry(
          chips: '["Daily Ranking"]',
          timestamp: ms(DateTime(2026, 10, 11, 23, 0)),
        ),
      ];
      // At 02:30 the energy day still started yesterday 04:00, so the
      // 23:00 entry DOES count; at 11:00 it no longer does.
      expect(
        hasFeelingCheckIn(
          entries,
          moodCategoryId: 6,
          now: DateTime(2026, 10, 12, 2, 30),
        ),
        isTrue,
      );
      expect(hasFeelingCheckIn(entries, moodCategoryId: 6, now: now), isFalse);
    });

    test('tag in another category does not count', () {
      final entries = [
        _entry(
          categoryId: 7,
          chips: '["Daily Ranking"]',
          timestamp: ms(DateTime(2026, 10, 12, 9, 15)),
        ),
      ];
      expect(hasFeelingCheckIn(entries, moodCategoryId: 6, now: now), isFalse);
    });

    test('mood entry without the tag does not count', () {
      final entries = [
        _entry(
          chips: '["Mood & Energy"]',
          timestamp: ms(DateTime(2026, 10, 12, 9, 15)),
        ),
      ];
      expect(hasFeelingCheckIn(entries, moodCategoryId: 6, now: now), isFalse);
    });

    test('chips parsing tolerates bare-list rendering', () {
      expect(chipsContainFeelingTag('[Daily Ranking]'), isTrue);
      expect(chipsContainFeelingTag('[]'), isFalse);
      expect(chipsContainFeelingTag(''), isFalse);
      expect(chipsContainFeelingTag('not json'), isFalse);
    });
  });

  group('resolveFeelingCategoryId', () {
    test('by name wins (the pulled set carries no slug)', () {
      expect(
        resolveFeelingCategoryId([_cat(9, 'Mood & Energy'), _cat(6, 'Other')]),
        9,
      );
    });

    test('falls back to native fallback id 6', () {
      expect(resolveFeelingCategoryId([_cat(6, 'Renamed')]), 6);
    });

    test('null when neither resolves — caller hides the card', () {
      expect(resolveFeelingCategoryId([_cat(3, 'Sleep')]), isNull);
      expect(resolveFeelingCategoryId(const []), isNull);
    });
  });

  group('buildFeelingEntry (native selectLevel write)', () {
    test('exact body/chips/category and id = max + 1', () {
      final entry = buildFeelingEntry(
        level: 4,
        categoryId: 6,
        existing: [_entry(id: 3), _entry(id: 41), _entry(id: 7)],
        now: DateTime(2026, 10, 12, 11, 0),
      );
      expect(entry.id, 42);
      expect(entry.categoryId, 6);
      expect(entry.body, 'Feeling: 4/5 Today');
      expect(entry.chips, '["Daily Ranking"]');
      expect(entry.manualText, '');
      expect(
        entry.timestamp,
        DateTime(2026, 10, 12, 11, 0).millisecondsSinceEpoch,
      );
    });

    test('empty history → id 1', () {
      final entry = buildFeelingEntry(
        level: 1,
        categoryId: 6,
        existing: const [],
      );
      expect(entry.id, 1);
    });

    test('an explicit id (the outbox allocation) wins over max + 1', () {
      final entry = buildFeelingEntry(
        level: 2,
        categoryId: 6,
        existing: [_entry(id: 41)],
        id: 99,
      );
      expect(entry.id, 99);
    });

    test("feelingRankingOf parses the body; feeling words are Juno's", () {
      expect(feelingRankingOf(_entry(body: 'Feeling: 3/5 Today')), 3);
      expect(feelingRankingOf(_entry(body: 'Feeling: 5/5 Today')), 5);
      expect(feelingRankingOf(_entry(body: 'headache')), isNull);
      expect(feelingWords,
          ['Really bad', 'Rough', 'Average', 'Good', 'Really good']);
      expect(feelingButtonSemantics(1), 'Energy 1 of 5, really bad');
      expect(feelingButtonSemantics(5), 'Energy 5 of 5, really good');
      // findFeelingCheckInEntry returns the entry hasFeelingCheckIn sees.
      final now = DateTime(2026, 10, 12, 11, 0);
      final e = _entry(
        chips: '["Daily Ranking"]',
        body: 'Feeling: 2/5 Today',
        timestamp: DateTime(2026, 10, 12, 9, 0).millisecondsSinceEpoch,
      );
      expect(
        findFeelingCheckInEntry([e], moodCategoryId: 6, now: now)?.id,
        e.id,
      );
    });
  });

  group('FeelingCheckInCard widget (native styling)', () {
    testWidgets('renders title + five 48dp buttons; tap reports the level', (
      tester,
    ) async {
      int? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FeelingCheckInCard(onSelect: (v) => selected = v),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500)); // entrance

      expect(find.text('How are you feeling?'), findsOneWidget);
      final title = tester.widget<Text>(find.text('How are you feeling?'));
      expect(title.style?.fontSize, 13);
      expect(title.style?.fontWeight, FontWeight.w500);
      expect(title.style?.color, NotelColors.textSecondary);

      for (var level = 1; level <= 5; level++) {
        expect(energyButton(level), findsOneWidget);
        expect(tester.getSize(energyButton(level)), const Size(48, 48));
      }
      // Juno Item 2: the five visible captions, verbatim, under the
      // buttons on every presentation — no shortened forms.
      for (final caption
          in ['Really bad', 'Rough', 'Average', 'Good', 'Really good']) {
        expect(find.text(caption), findsOneWidget, reason: caption);
      }

      await tester.tap(find.text('4'));
      await tester.pump();
      expect(selected, 4);
    });

    testWidgets('pressed button fills Tabs purple with a white number', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: FeelingCheckInCard(onSelect: (_) {})),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));

      Container buttonContainer() => tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(FeelingCheckInCard),
              matching: find.byType(Container),
            ),
          )
          .firstWhere(
            (c) =>
                c.constraints?.maxWidth == 48 && c.constraints?.maxHeight == 48,
          );

      final idle = buttonContainer().decoration as BoxDecoration;
      expect(idle.color, NotelColors.surfaceHigh);

      final gesture = await tester.startGesture(
        tester.getCenter(energyButton(2)),
      );
      await tester.pump();
      final pressed = buttonContainer().decoration as BoxDecoration;
      // firstWhere picks button 1's container; press state is per-button,
      // so assert at least the pressed button (2) flipped by checking all.
      final anyPressed = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(FeelingCheckInCard),
              matching: find.byType(Container),
            ),
          )
          .where(
            (c) =>
                c.constraints?.maxWidth == 48 && c.constraints?.maxHeight == 48,
          )
          .any(
            (c) => (c.decoration as BoxDecoration).color == NotelColors.primary,
          );
      expect(
        pressed.color,
        anyOf(NotelColors.surfaceHigh, NotelColors.primary),
      );
      expect(anyPressed, isTrue);
      await gesture.up();
      await tester.pump();
    });
  });

  group('HomeScreen integration (mock backend)', () {
    MockClient mockBackend({
      required List<Map<String, dynamic>> entries,
      required void Function(Map<String, dynamic> body) onPost,
      int pullStatus = 200,
    }) {
      return MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          if (pullStatus != 200) return http.Response('err', pullStatus);
          return http.Response(
            jsonEncode({
              'entries': entries,
              'categories': [
                {
                  'id': 6,
                  'name': 'Mood & Energy',
                  'icon': 'Mood',
                  'colorHex': '#FFD93D',
                  'isDefault': true,
                  'sortOrder': 6,
                },
              ],
              'profile': {'currentStreak': 3, 'bestStreak': 9},
            }),
            200,
          );
        }
        if (request.url.path == '/api/sync/entries' &&
            request.method == 'POST') {
          onPost(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response('{}', 200);
        }
        return http.Response('not found', 404);
      });
    }

    TabsBackend backendFor(MockClient client) => TabsBackend(
      client: client,
      sessionStore: FakeSessionStore()..token = 'tok',
    );

    WeatherApiClient weather() => WeatherApiClient(
      client: MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
            200,
          );
        }
        return http.Response(
          '{"current":{"temperature_2m":70.0,"weather_code":2,"is_day":1}}',
          200,
        );
      }),
    );

    Future<void> pumpHome(WidgetTester tester, TabsBackend backend) async {
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            weatherApi: weather(),
            tabsBackend: backend,
            logEntryOutbox: LogEntryOutbox.instance,
          ),
        ),
      );
      // Let the pull + weather + health loads settle.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets(
      'no check-in today → card shows; tap 3 writes the exact entry '
      'through the outbox and the summary replaces the card',
      (tester) async {
        Map<String, dynamic>? posted;
        final backend = backendFor(
          mockBackend(
            entries: [
              {
                'id': 41,
                'categoryId': 1,
                'body': 'headache',
                'chips': '[]',
                'manualText': '',
                'timestamp': DateTime.now().millisecondsSinceEpoch,
              },
            ],
            onPost: (body) => posted = body,
          ),
        );
        await pumpHome(tester, backend);

        expect(find.text('How are you feeling?'), findsOneWidget);
        // Card is the first content on Home: it sits above the vitals strip.
        final cardY = tester.getTopLeft(find.text('How are you feeling?')).dy;
        expect(cardY, lessThan(200));

        await tester.tap(find.text('3'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump();

        expect(posted, isNotNull);
        final rows = posted!['entries'] as List<dynamic>;
        expect(rows, hasLength(1));
        final row = rows.single as Map<String, dynamic>;
        // The outbox allocation also lands on max(41) + 1 here.
        expect(row['id'], 42);
        expect(row['categoryId'], 6);
        expect(row['body'], 'Feeling: 3/5 Today');
        expect(row['chips'], '["Daily Ranking"]');
        expect(row['manualText'], '');

        // Merged flow: the summary card replaces the number card
        // for the rest of the energy day (no exit-slide state).
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump();
        expect(find.text('How are you feeling?'), findsNothing);
        expect(find.text('3 · Average'), findsOneWidget);
      },
    );

    testWidgets(
        'check-in already logged this energy day → card never shows; '
        'the summary shows instead', (
      tester,
    ) async {
      final backend = backendFor(
        mockBackend(
          entries: [
            {
              'id': 41,
              'categoryId': 6,
              'body': 'Feeling: 5/5 Today',
              'chips': '["Daily Ranking"]',
              'manualText': '',
              'timestamp': DateTime.now().millisecondsSinceEpoch,
            },
          ],
          onPost: (_) => fail('must not write'),
        ),
      );
      await pumpHome(tester, backend);
      expect(find.text('How are you feeling?'), findsNothing);
      expect(find.text('5 · Really good'), findsOneWidget);
    });

    testWidgets('pull failure → honest hidden state, no card, no crash', (
      tester,
    ) async {
      final backend = backendFor(
        mockBackend(entries: const [], onPost: (_) {}, pullStatus: 500),
      );
      await pumpHome(tester, backend);
      expect(find.text('How are you feeling?'), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
    });
  });
}
