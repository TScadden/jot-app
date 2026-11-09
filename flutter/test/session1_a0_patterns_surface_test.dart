import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/correlation_copy.dart';
import 'package:tabs_lab/src/data/correlation_engine.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/patterns_screen.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';
import 'package:tabs_lab/src/features/tools/trends_screen.dart';

/// Session #1 A0 — Patterns discoverability + receipt line.
///
/// Routing: the Home entry (grouped under Weekly Snapshot) and
/// the Tools Patterns tile both open PatternsScreen; the Trends
/// tile no longer carries the Patterns label and still opens
/// TrendsScreen. Receipt: a fixture card renders Juno's
/// provenance line with exactly the counts the fixture carries —
/// and never an excluded-days clause (the engine exposes no such
/// count; see the GAP note in correlation_copy.dart).

MockClient _mockWeatherClient() {
  return MockClient((request) async {
    final host = request.url.host;
    if (host == 'ipinfo.io') {
      return http.Response(
        '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
        200,
      );
    }
    if (host == 'api.open-meteo.com') {
      return http.Response(
        '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
        200,
      );
    }
    return http.Response('not found', 404);
  });
}

ToolOrderStore _memoryStore() {
  final store = ToolOrderStore();
  final map = <String, String>{};
  store.debugSetIO(
    read: (key) async => map[key],
    write: (key, value) async => map[key] = value,
  );
  return store;
}

InsightRecord _rec({
  required String familyId,
  required String splitId,
  required InsightState state,
  List<InsightGroup> groups = const [],
  String? headerLabel,
  String? subjectName,
  String throughDate = '2026-10-20',
}) => InsightRecord(
  familyId: familyId,
  splitId: splitId,
  windowKey: 'last90d',
  state: state,
  groups: groups,
  headerLabel: headerLabel,
  subjectName: subjectName,
  computedAtMs: 0,
  throughDate: throughDate,
  inputFingerprint: 'fixture',
);

InsightRecord _f1aNumbers() => _rec(
  familyId: 'F1',
  splitId: 'F1a',
  state: InsightState.numbers,
  groups: const [
    InsightGroup(
      label: 'nights under 6 hours of sleep',
      n: 7,
      mean: 71.4,
      median: 70,
    ),
    InsightGroup(
      label: 'nights with 6 or more hours of sleep',
      n: 9,
      mean: 80.2,
      median: 81,
    ),
  ],
);

Future<void> _pumpPatterns(
  WidgetTester tester,
  List<InsightRecord> records,
) async {
  await tester.pumpWidget(
    MaterialApp(home: PatternsScreen(records: records, isUnlimited: true)),
  );
  await tester.pump();
}

/// The default 800x600 test surface leaves the lower Tools tiles
/// (and the Home entry, below the fold) with tap points outside
/// the viewport; a tall surface keeps every tap on-screen.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// scrollUntilVisible stops once a deep GridView tile enters the
/// grid's cache extent, which can leave its tap point off-screen.
/// This drags the grid until [text]'s center is actually inside
/// the viewport, then taps it (any point on a tile card taps it).
Future<void> _dragUntilTapText(
  WidgetTester tester, {
  required String text,
}) async {
  final grid = find.byType(GridView);
  for (var i = 0; i < 16; i++) {
    final finder = find.text(text);
    if (finder.evaluate().isNotEmpty) {
      final center = tester.getCenter(finder);
      final height =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      if (center.dy > 60 && center.dy < height - 60) {
        await tester.tap(finder);
        return;
      }
    }
    await tester.drag(grid, const Offset(0, -400));
    await tester.pump();
  }
  fail('tile text "$text" never came on-screen');
}

void main() {
  group('A0 routing', () {
    testWidgets('Home entry is grouped under Weekly Snapshot and '
        'opens PatternsScreen', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: HomeScreen(
            weatherApi: WeatherApiClient(client: _mockWeatherClient()),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text(patternsEntryLabel), findsOneWidget);
      expect(find.text(patternsEntrySubtitle), findsOneWidget);
      expect(find.text('How your days compare'), findsOneWidget);
      // Grouped: the entry renders below the Weekly Snapshot card.
      final snapshotY = tester.getCenter(find.text('Weekly Snapshot')).dy;
      final entryY = tester.getCenter(find.text('Patterns')).dy;
      expect(entryY, greaterThan(snapshotY));

      await tester.ensureVisible(find.text('Patterns'));
      await tester.pump();
      await tester.tap(find.text('Patterns'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PatternsScreen), findsOneWidget);
      // The pushed PatternsScreen resolves membership on its own
      // (unknown gate): advance past its 20s resolve bound so no
      // timer is left pending at teardown.
      await tester.pump(const Duration(seconds: 21));
    });

    testWidgets('Tools Patterns tile opens PatternsScreen', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        MaterialApp(home: ToolsScreen(orderStore: _memoryStore())),
      );
      await tester.pumpAndSettle();
      await _dragUntilTapText(tester, text: 'Patterns');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PatternsScreen), findsOneWidget);
      // Drain the pushed screen's 20s membership-resolve bound,
      // as in the Home routing test above.
      await tester.pump(const Duration(seconds: 21));
    });

    testWidgets('Tools Trends tile carries no Patterns label and '
        'still opens TrendsScreen', (tester) async {
      _useTallSurface(tester);
      // Unit level: no tile in the default list promises Patterns
      // except the Patterns tile itself.
      for (final tile in defaultToolTiles) {
        if (tile.id == 'patterns') continue;
        expect(
          tile.description,
          isNot(contains('Patterns')),
          reason: 'tile ${tile.id} still promises Patterns',
        );
        expect(
          tile.title,
          isNot('Patterns'),
          reason: 'tile ${tile.id} still titled Patterns',
        );
      }
      final trends = defaultToolTiles.singleWhere((t) => t.id == 'trends');
      expect(trends.description, 'Log activity over time');

      await tester.pumpWidget(
        MaterialApp(home: ToolsScreen(orderStore: _memoryStore())),
      );
      await tester.pumpAndSettle();
      expect(find.text('Patterns over time'), findsNothing);
      await _dragUntilTapText(tester, text: 'Trends');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(TrendsScreen), findsOneWidget);
      expect(find.byType(PatternsScreen), findsNothing);
    });
  });

  group('A0 receipt line', () {
    test('formatter omits every clause it is not given, and has '
        'no excluded-days clause', () {
      expect(
        correlationReceiptLine(),
        'Nothing left your phone for this pattern.',
      );
      expect(
        correlationReceiptLine(completeDays: 5),
        'Based on 5 complete days · '
        'Nothing left your phone for this pattern.',
      );
      expect(
        correlationReceiptLine(
          completeDays: 16,
          dateRange: '2026-07-23 to 2026-10-20',
          sourceLabel: 'Sources: sleep and Daily Score from your records',
        ),
        'Based on 16 complete days, 2026-07-23 to 2026-10-20 · '
        'Sources: sleep and Daily Score from your records · '
        'Nothing left your phone for this pattern.',
      );
      expect(
        correlationReceiptLine(completeDays: 5).contains('excluded'),
        isFalse,
      );
    });

    testWidgets('numbers fixture card renders the receipt with '
        'the fixture counts (7 + 9 = 16)', (tester) async {
      await _pumpPatterns(tester, [_f1aNumbers()]);
      expect(
        find.text(
          'Based on 16 complete days, 2026-07-23 to 2026-10-20 · '
          'Sources: sleep and Daily Score from your records · '
          'Nothing left your phone for this pattern.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('progress fixture card renders the receipt with '
        'its so-far counts (2 + 3 = 5)', (tester) async {
      await _pumpPatterns(tester, [
        _rec(
          familyId: 'F4',
          splitId: 'F4',
          state: InsightState.progress,
          groups: const [
            InsightGroup(label: 'days with a Daily Ranking of 1 or 2', n: 2),
            InsightGroup(label: 'days with a Daily Ranking of 4 or 5', n: 3),
          ],
        ),
      ]);
      expect(
        find.text(
          'Based on 5 complete days, 2026-07-23 to 2026-10-20 · '
          'Sources: Daily Ranking check-ins and Daily Score from '
          'your records · '
          'Nothing left your phone for this pattern.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('F5 fixture card omits the date range (event '
        'anchor is not stored on the record)', (tester) async {
      await _pumpPatterns(tester, [
        _rec(
          familyId: 'F5',
          splitId: 'event-1',
          state: InsightState.numbers,
          headerLabel: 'Started Med',
          subjectName: 'Med',
          groups: const [
            InsightGroup(
              label: 'scored days before the change',
              n: 6,
              mean: 70,
            ),
            InsightGroup(label: 'scored days after the change', n: 8, mean: 75),
          ],
        ),
      ]);
      expect(
        find.text(
          'Based on 14 complete days · '
          'Sources: medication changes and Daily Score from your '
          'records · '
          'Nothing left your phone for this pattern.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('unavailable fixture card omits the Based-on '
        'clause (no days were counted)', (tester) async {
      await _pumpPatterns(tester, [
        _rec(
          familyId: 'F2',
          splitId: 'fluid-score',
          state: InsightState.unavailable,
          groups: const [
            InsightGroup(
              label: 'days your logged intake reached your target',
              n: 0,
            ),
            InsightGroup(
              label: 'days your logged intake was below your target',
              n: 0,
            ),
          ],
        ),
      ]);
      expect(
        find.text(
          'Sources: logged fluid intake and Daily Score from your '
          'records · '
          'Nothing left your phone for this pattern.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('complete days'), findsNothing);
      expect(find.textContaining('excluded'), findsNothing);
    });
  });
}
