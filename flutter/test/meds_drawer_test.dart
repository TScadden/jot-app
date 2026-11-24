import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';

import 'test_helpers.dart';

/// Medications → drawer (founder, Nov 23, 2026): Medications left
/// the Tools screen for the Home drawer, alongside AI Advocate,
/// Event Counters, Community and Badges. This suite pins:
/// (1) the drawer carries a Medications row (appended last, plain
/// row pattern) and tapping it lands on the UNCHANGED
/// MedicationsScreen — the same screen the Tools tile opened;
/// (2) a surveyed alternate medication surface behaves exactly as
/// before: the Daily Summary / Today Plan medication item's
/// Take control still records the dose in place (that route never
/// navigated to the Medications screen and still does not).
/// Tools-side absence (incl. stale saved orders) is pinned in
/// tools_screen_test.dart.

WeatherApiClient _testWeather() => WeatherApiClient(
      client: MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
              200);
        }
        return http.Response('not found', 404);
      }),
    );

Future<void> _loadRoboto(WidgetTester tester) async {
  // Real Roboto (repo capture pattern): the default test font's
  // glyphs are full-width blocks, which wraps drawer labels onto
  // two lines and inflates row heights — neither is true of the
  // shipped render.
  await tester.runAsync(() async {
    final loader = FontLoader('Roboto');
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await loader.load();
  });
}

Future<void> _openDrawer(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('home_drawer_button')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
  expect(find.byType(Drawer), findsOneWidget);
}

/// Drain Home's Daily Score capture chain (bounded HC reads park
/// 30s timers against the missing test platform channel; the repo
/// pattern runs the clock past every bound).
Future<void> _drainScoreChain(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(seconds: 31));
  }
}

void main() {
  testWidgets(
      'drawer: Medications row is present, last, and tapping it '
      'lands on the unchanged Medications screen', (tester) async {
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await _loadRoboto(tester);

    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: HomeScreen(weatherApi: _testWeather()),
    ));
    await tester.pump();
    await _openDrawer(tester);

    // The full drawer order: the four existing rows keep their
    // relative order; Medications is appended last.
    const rowKeys = [
      ValueKey('home_drawer_ai_advocate'),
      ValueKey('home_drawer_event_counters'),
      ValueKey('home_drawer_community'),
      ValueKey('home_drawer_badges'),
      ValueKey('home_drawer_medications'),
    ];
    var lastDy = double.negativeInfinity;
    for (final key in rowKeys) {
      final row = find.byKey(key);
      expect(row, findsOneWidget, reason: '$key row missing');
      final dy = tester.getTopLeft(row).dy;
      expect(dy, greaterThan(lastDy), reason: '$key out of order');
      lastDy = dy;
    }

    final medsRow = find.byKey(const ValueKey('home_drawer_medications'));
    expect(
      find.descendant(of: medsRow, matching: find.text('Medications')),
      findsOneWidget,
    );
    final icon = tester.widget<Icon>(
      find.descendant(of: medsRow, matching: find.byType(Icon)).first,
    );
    expect(icon.icon, Icons.medication);
    expect(icon.size, 22);

    // Tap → the unchanged MedicationsScreen (same AppBar title the
    // Tools route landed on). Its default backend fails honestly
    // in the test environment, landing on the empty state.
    await tester.tap(medsRow);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.byType(MedicationsScreen), findsOneWidget);
    expect(
      find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Medications & Side Effects')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    // Back exits to Home.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.byType(MedicationsScreen), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
    await _drainScoreChain(tester);
  });

  group('surveyed alternate route — Today Plan medication item', () {
    setUp(TabsBackend.debugResetSharedCaches);
    setUp(() {
      final mem = <String, String>{};
      HealthHistoryStore.instance.debugSetStore(
        read: (k) async => mem[k],
        write: (k, v) async => mem[k] = v,
        delete: (k) async => mem.remove(k),
      );
      HealthHistoryStore.instance.debugReset();
    });

    testWidgets(
        'Take on a Daily Summary medication item still records '
        'the dose in place (no navigation, exactly as before)',
        (tester) async {
      final server = _PlanServer();
      final planMem = _MemoryStore();
      final cacheMem = _MemoryStore();
      final planStore = TodayPlanStore.testInstance()
        ..debugSetStore(
            read: planMem.read, write: planMem.write, delete: planMem.delete);
      final cache = TodaySummaryCache.testInstance()
        ..debugSetStore(
            read: cacheMem.read,
            write: cacheMem.write,
            delete: cacheMem.delete);
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'a@x.com';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: TodaySummaryCard(
                backend: TabsBackend(
                    client: server.client, sessionStore: session),
                healthConnectService: _FakePlanHc(),
                planStore: planStore,
                summaryCache: cache,
                sessionStore: session,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today Summary'));
      await tester.pumpAndSettle();

      // The medication item renders in the plan with its Take
      // control — the surveyed surface, unchanged.
      expect(find.text('Ivabradine'), findsOneWidget);
      final take = find.byTooltip('Take Medication');
      expect(take, findsOneWidget);

      await tester.tap(take);
      await tester.pump();
      // Let the background write chain (write → reconciling
      // reload) drain to completion.
      for (var i = 0; i < 4; i++) {
        await tester.pump();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)));
      }
      await tester.pumpAndSettle();

      // Exactly one dose entry was posted, and the row is resolved.
      expect(server.postedEntries, hasLength(1));
      expect(find.text('Ivabradine'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}

class _MemoryStore {
  final Map<String, String> map = {};
  Future<String?> read(String k) async => map[k];
  Future<void> write(String k, String v) async => map[k] = v;
  Future<void> delete(String k) async => map.remove(k);
}

class _FakePlanHc extends HealthConnectService {
  @override
  Future<int?> readSleepMinutes(String dateStr) async => null;

  @override
  Future<List<({String date, int mins, int deep})>> readSleepHistory(
      int days) async {
    return const [];
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];
}

/// Stateful fake server with one Daily medication (mirrors the
/// fixtures in today_plan_instant_tap_test.dart): the pull reflects
/// posted entries, so a recorded dose resolves the plan item.
class _PlanServer {
  final List<Map<String, dynamic>> serverEntries = [];
  final List<Map<String, dynamic>> postedEntries = [];

  http.Client get client => MockClient(_handle);

  Map<String, dynamic> _pullBody() {
    final meds = jsonEncode([
      {
        'id': 'med-uuid-1',
        'name': 'Ivabradine',
        'dose': '7.5 mg',
        'frequency': 'Daily',
        'startDate': '2026-01-01',
        'endDate': 'Present',
        'isPresent': true,
        'isDeleted': false,
        'updatedAt': '1760000000000',
      },
    ]);
    return {
      'entries': serverEntries
          .map((e) => {
                'id': '${e['id']}',
                'categoryId': '${e['categoryId']}',
                'body': e['body'],
                'chips': e['chips'],
                'manualText': e['manualText'],
                'timestamp': '${e['timestamp']}',
                'updatedAt': '${e['timestamp']}',
              })
          .toList(),
      'categories': [
        {'id': 1, 'name': 'Symptoms'},
        {'id': 4, 'name': 'Goals & Habits'},
        {'id': 8, 'name': 'Medication'},
      ],
      'profile': {'medications': meds, 'reminders': '[]'},
      'isUnlimited': true,
      'isAdmin': false,
    };
  }

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(jsonEncode(_pullBody()), 200);
    }
    if (request.url.path == '/api/habits') {
      return http.Response('{"habits":[]}', 200);
    }
    if (request.url.path == '/api/sync/entries') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      for (final e in (body['entries'] as List)) {
        final row = (e as Map).cast<String, dynamic>();
        postedEntries.add(row);
        serverEntries.removeWhere((s) => s['id'] == row['id']);
        serverEntries.add(row);
      }
      return http.Response('{"success":true}', 200);
    }
    return http.Response('{}', 404);
  }
}
