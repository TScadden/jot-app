import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart'
    show historyDateStr;
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_plan_store.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/checkin_summary_card.dart';
import 'package:tabs_lab/src/features/home/daily_score_screen.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

import 'test_helpers.dart';

/// Home redesign (Lab, Nov 9, 2026) — the NEW behavior pins:
/// drawer + "AI Advocate" deep-link, vitals-pill centering and
/// compact size, streak-stack order, the Today Summary sheet
/// hosting the check-in, the header-trailing tap isolation
/// (seventh ruling), the progress fraction (ruling R1), and the
/// verdict chip on today's history row.
///
/// Fixtures follow feeling_checkin_r21_test.dart (mock backend
/// pull + outbox capture) and lab_blackglass_render_test.dart
/// (in-memory stores, cache-seeded plan).

class _FakeHc extends HealthConnectService {
  @override
  Future<HealthConnectStatus> getStatus() async =>
      HealthConnectStatus.connected;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async {
    final now = DateTime.now();
    final noon = DateTime(now.year, now.month, now.day, 12);
    return [HrSample(timeMs: noon.millisecondsSinceEpoch, bpm: 74)];
  }

  @override
  Future<int?> readActiveCalories(String dateStr) async => 159;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => 510;

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

MockClient _mockWeather() => MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}', 200);
      }
      return http.Response(
          '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
          200);
    });

/// Stateful fake backend: the pull serves [entries] plus the
/// streak profile (18 current / 68 best); POSTs are captured and
/// reflected into later pulls, like production.
MockClient _mockBackend({
  required List<Map<String, dynamic>> entries,
  required void Function(Map<String, dynamic>) onPost,
}) {
  final serverEntries = List<Map<String, dynamic>>.of(entries);
  return MockClient((request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(
        jsonEncode({
          'entries': serverEntries,
          'categories': [
            {'id': 1, 'name': 'Symptoms', 'icon': 'Pulse', 'colorHex': '#FF6B6B', 'isDefault': true, 'sortOrder': 1},
            {'id': 4, 'name': 'Goals & Habits', 'icon': 'Target', 'colorHex': '#4ECDC4', 'isDefault': true, 'sortOrder': 4},
            {'id': 6, 'name': 'Mood & Energy', 'icon': 'Mood', 'colorHex': '#FFD93D', 'isDefault': true, 'sortOrder': 6},
            {'id': 8, 'name': 'Medication', 'icon': 'Pill', 'colorHex': '#95E1D3', 'isDefault': true, 'sortOrder': 8},
          ],
          'profile': {
            'currentStreak': 18,
            'bestStreak': 68,
            'medications': '[]',
            'reminders': '[]',
          },
          'isUnlimited': true,
          'isAdmin': false,
        }),
        200,
      );
    }
    if (request.url.path == '/api/habits') {
      return http.Response('{"habits":[]}', 200);
    }
    if (request.url.path == '/api/sync/entries' &&
        request.method == 'POST') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      onPost(body);
      for (final e in (body['entries'] as List)) {
        serverEntries.add((e as Map).cast<String, dynamic>());
      }
      return http.Response('{}', 200);
    }
    return http.Response('not found', 404);
  });
}

/// In-memory key/value store for the summary card's injected
/// plan store / cache in the standalone-card tests.
class _CardMemStore {
  final Map<String, String> map = {};
  Future<String?> read(String k) async => map[k];
  Future<void> write(String k, String v) async => map[k] = v;
  Future<void> delete(String k) async => map.remove(k);
}

Map<String, dynamic> _entry({
  required int id,
  required int categoryId,
  required String body,
  String chips = '[]',
}) =>
    {
      'id': id,
      'categoryId': categoryId,
      'body': body,
      'chips': chips,
      'manualText': '',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

Future<void> _bridge(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
  }
  await tester.pump();
  // Elapse the staggered entrances (last timer 320ms) and the
  // vitals count-up so values are final when read.
  await tester.pump(const Duration(seconds: 3));
  await _drainScoreChain(tester);
}

/// Drives the Daily Score history-capture chain to completion:
/// its bounded HC reads park 30s timeout timers, and the
/// single-flight is shared across tests in this file, so a chain
/// left mid-flight in one test leaves pending timers in the
/// next. Alternating real-async drains with pumps (the
/// settingsgear harness pattern) runs it out, then the fake
/// clock elapses past any final bounded-read timer.
Future<void> _drainScoreChain(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(seconds: 31));
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required Size physicalSize,
  required List<Map<String, dynamic>> entries,
  void Function(Map<String, dynamic>)? onPost,
}) async {
  tester.view.physicalSize = physicalSize;
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  final disk = <String, String>{};
  Future<String?> read(String k) async => disk[k];
  Future<void> write(String k, String v) async => disk[k] = v;
  Future<void> delete(String k) async => disk.remove(k);
  LogEntryOutbox.instance.debugSetStore(
      read: read, write: write, delete: delete);
  LogEntryOutbox.instance.debugReset();

  final scoreStore = HealthHistoryStore.testInstance();
  scoreStore.debugSetStore(read: read, write: write, delete: delete);
  scoreStore.debugReset();
  final today = historyDateStr(DateTime.now());
  await scoreStore.mergeRefresh([DailyBiometrics(date: today, restingHrBpm: 60)]);
  await scoreStore.replaceScore(today,
      dailyScore: 73, scoreHrv: 73, scoreRestingHr: 73);

  final backend = TabsBackend(
    client: _mockBackend(entries: entries, onPost: onPost ?? (_) {}),
    sessionStore: FakeSessionStore()..token = 'tok',
  );

  // Real font metrics: the default test font is ~1.5x wider than
  // Roboto and overflows fixed rows at 360dp that fit on device
  // (the capture harnesses load Roboto for the same reason).
  await tester.runAsync(() async {
    final loader = FontLoader('Roboto');
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
    loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
    await loader.load();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto'),
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: HomeScreen(
          weatherApi: WeatherApiClient(client: _mockWeather()),
          tabsBackend: backend,
          logEntryOutbox: LogEntryOutbox.instance,
          healthConnectService: _FakeHc(),
          // Home builds its repository from the HC service alone
          // (default production backend) unless one is injected —
          // the streak/log-count loads ride the repository's
          // backend, so inject it over the mock.
          healthRepository: HealthRepository(hc: _FakeHc(), backend: backend),
          healthHistoryStore: scoreStore,
          dailyScoreSnapshotCapture: ({bool force = false}) async => true,
        ),
      ),
    ),
  );
  await _bridge(tester);
}

/// Opens the summary sheet with fixed pumps (the loaded weather
/// icon animates indefinitely, so pumpAndSettle never settles).
Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.text('Today Summary'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

void main() {
  setUp(() {
    TabsBackend.debugResetSharedCaches();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
  });

  group('drawer + AI Advocate deep-link', () {
    testWidgets(
        'hamburger opens a drawer whose ONLY row is "AI Advocate"; '
        'tapping it pushes Settings at the AI page, and back exits '
        'to Home', (tester) async {
      await _pumpHome(
        tester,
        physicalSize: const Size(1080, 2400),
        entries: [_entry(id: 41, categoryId: 1, body: 'headache')],
      );

      await tester.tap(find.byKey(const ValueKey('home_drawer_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.byType(Drawer), findsOneWidget);
      expect(find.text('AI Advocate'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
      // One row only: a single tappable inside the drawer.
      expect(
        find.descendant(
            of: find.byType(Drawer), matching: find.byType(InkWell)),
        findsOneWidget,
      );

      await tester
          .tap(find.byKey(const ValueKey('home_drawer_ai_advocate')));
      await _bridge(tester);

      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(
        find.descendant(
            of: find.byType(AppBar),
            matching: find.text('AI & Clinical Advocate')),
        findsOneWidget,
      );

      // Back from the deep-linked AI page exits to Home (the
      // openAiKnowledge special case), not to the Settings menu.
      await tester.binding.handlePopRoute();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.byType(SettingsScreen), findsNothing);
      expect(find.byType(HomeScreen), findsOneWidget);
      await _drainScoreChain(tester);
    });
  });

  group('header corner buttons (Vera F1/F3, Juno C3)', () {
    Finder circleIn(Finder ancestor) => find.descendant(
          of: ancestor,
          matching: find.byWidgetPredicate((widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).shape ==
                  BoxShape.circle),
        );

    void expectBorderedCircle(WidgetTester tester, Finder circle) {
      expect(circle, findsOneWidget);
      final rect = tester.getRect(circle);
      expect(rect.width, 40);
      expect(rect.height, 40);
      final decoration =
          tester.widget<Container>(circle).decoration as BoxDecoration;
      expect(decoration.color, NotelColors.surface);
      final border = decoration.border as Border;
      expect(border.top.color, NotelColors.legacyDarkHairline);
      expect(border.top.width, 1);
    }

    testWidgets(
        'gear renders inside a 40dp bordered circle; drawer-button '
        'hit rect is 48x48 with its 40dp circle centered; the drawer '
        'button carries the Menu tooltip and semantics label',
        (tester) async {
      await _pumpHome(
        tester,
        physicalSize: const Size(1080, 2400),
        entries: [_entry(id: 41, categoryId: 1, body: 'headache')],
      );

      final drawerBtn = find.byKey(const ValueKey('home_drawer_button'));
      final gear = find.byKey(const ValueKey('home_settings_gear'));

      // F3: the keyed InkWell covers the full 48x48 slot (slot
      // edges unmoved), CircleBorder retained, and the 40dp
      // bordered circle is centered inside it.
      final drawerRect = tester.getRect(drawerBtn);
      expect(drawerRect.width, 48);
      expect(drawerRect.height, 48);
      expect(tester.widget<InkWell>(drawerBtn).customBorder,
          isA<CircleBorder>());
      final drawerCircle = circleIn(drawerBtn);
      expectBorderedCircle(tester, drawerCircle);
      expect(tester.getRect(drawerCircle).center, drawerRect.center);

      // Juno C3: accessible name 'Menu' — tooltip AND semantics.
      expect(find.byTooltip('Menu'), findsOneWidget);
      expect(find.bySemanticsLabel('Menu'), findsWidgets);
      final semanticsWidget = tester.widgetList<Semantics>(find
          .ancestor(of: drawerBtn, matching: find.byType(Semantics)));
      expect(
        semanticsWidget.any((s) => s.properties.label == 'Menu'),
        isTrue,
      );

      // F1: the gear glyph (24dp, textPrimary) renders inside a
      // 40dp bordered circle with the same construction as the
      // hamburger, centered in the gear's 48dp slot.
      final gearRect = tester.getRect(gear);
      expect(gearRect.width, 48);
      expect(gearRect.height, 48);
      final gearCircle = circleIn(gear);
      expectBorderedCircle(tester, gearCircle);
      expect(tester.getRect(gearCircle).center, gearRect.center);
      final glyph = tester.widget<Icon>(find.descendant(
          of: gear, matching: find.byIcon(Icons.settings)));
      expect(glyph.size, 24);
      expect(glyph.color, NotelColors.textPrimary);
      expect(find.byTooltip('Settings'), findsOneWidget);
      await _drainScoreChain(tester);
    });
  });

  group('vitals pill', () {
    for (final (label, size) in [
      ('360', const Size(1080, 2400)),
      ('390', const Size(1170, 2532)),
    ]) {
      testWidgets(
          'pill is centered between the corner buttons at ${label}dp '
          'and renders the compact size', (tester) async {
        await _pumpHome(
          tester,
          physicalSize: size,
          entries: [
            for (var i = 0; i < 10; i++)
              _entry(id: 100 + i, categoryId: 1, body: 'entry $i'),
          ],
        );

        final pill = tester
            .getRect(find.byKey(const ValueKey('vitalsStripCompact')));
        final drawerBtn =
            tester.getRect(find.byKey(const ValueKey('home_drawer_button')));
        final gear =
            tester.getRect(find.byKey(const ValueKey('home_settings_gear')));
        debugPrint(
            'VITALS PILL AFTER @$label: ${pill.width} x ${pill.height}');
        // Centered by construction: the pill's center x is the
        // midpoint between the two buttons' inner edges (±1dp).
        // Both buttons are 48dp hit slots (Vera F3: the drawer's
        // keyed InkWell now covers its full 48dp slot, with the
        // 40dp visual circle centered inside it), so each slot's
        // inner edge is its keyed rect's edge.
        final drawerSlotRight = drawerBtn.right;
        final midpoint = (drawerSlotRight + gear.left) / 2;
        expect(pill.center.dx, closeTo(midpoint, 1.0));
        // Compact contract: content-width (BEFORE was 328dp wide
        // at 360dp) and shorter than the old ≈40–41dp strip.
        expect(pill.width, lessThan(328));
        expect(pill.height, lessThan(40));
        // The four values render (74 HR · 159 cal · 10 logs ·
        // 8h30m sleep).
        expect(find.text('74'), findsWidgets);
        expect(find.text('159'), findsOneWidget);
        expect(find.text('10'), findsWidgets);
      });
    }
  });

  group('corner band', () {
    testWidgets('streak stack: BEST (🏆 68) sits above CURRENT (🔥 18)',
        (tester) async {
      await _pumpHome(
        tester,
        physicalSize: const Size(1080, 2400),
        entries: [_entry(id: 41, categoryId: 1, body: 'headache')],
      );

      final stack = find.byType(HomeStreakStack);
      expect(stack, findsOneWidget);
      final trophy = tester.getRect(find.descendant(
          of: stack, matching: find.text('🏆')));
      final flame = tester.getRect(find.descendant(
          of: stack, matching: find.text('🔥')));
      expect(trophy.top, lessThan(flame.top));
      // Values ride their own pills: 68 beside the trophy,
      // 18 beside the flame (same row band, ± a few dp).
      final best = tester.getRect(
          find.descendant(of: stack, matching: find.text('68')));
      final current = tester.getRect(
          find.descendant(of: stack, matching: find.text('18')));
      expect(best.center.dy, closeTo(trophy.center.dy, 6));
      expect(current.center.dy, closeTo(flame.center.dy, 6));
      expect(best.top, lessThan(current.top));
    });
  });

  group('summary sheet hosts the check-in', () {
    testWidgets(
        'un-checked: the sheet hosts FeelingCheckInCard; tapping 3 '
        'commits through Home and the section swaps to the summary',
        (tester) async {
      Map<String, dynamic>? posted;
      await _pumpHome(
        tester,
        physicalSize: const Size(1080, 2400),
        entries: [_entry(id: 41, categoryId: 1, body: 'headache')],
        onPost: (body) => posted = body,
      );

      // Not in the Home body anymore.
      expect(find.byType(FeelingCheckInCard), findsNothing);
      await _openSheet(tester);
      expect(find.byType(FeelingCheckInCard), findsOneWidget);

      await tester.tap(find.descendant(
        of: find.byType(FeelingCheckInCard),
        matching: find.text('3'),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(posted, isNotNull);
      final rows = posted!['entries'] as List<dynamic>;
      expect(rows, hasLength(1));
      final row = rows.single as Map<String, dynamic>;
      expect(row['categoryId'], 6);
      expect(row['body'], 'Feeling: 3/5 Today');
      expect(row['chips'], '["Daily Ranking"]');

      // The sheet's section swapped to the checked summary.
      expect(find.byType(FeelingCheckInCard), findsNothing);
      expect(find.byType(CheckInSummaryCard), findsOneWidget);
      expect(find.text('3 · Average'), findsOneWidget);
      // The commit re-ran Home's health load, which starts a
      // fresh history-capture flight — drain it before teardown.
      await _drainScoreChain(tester);
    });
  });

  group('summary card header trailing (seventh ruling)', () {
    testWidgets(
        'the trailing widget (weather on Home) takes its OWN tap '
        'and does NOT open the summary sheet', (tester) async {
      var trailingTaps = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TodaySummaryCard(
              backend: TabsBackend(
                client: MockClient(
                    (request) async => http.Response('boom', 500)),
                sessionStore: FakeSessionStore()..token = 'tok',
              ),
              healthConnectService: _FakeHc(),
              headerTrailing: IconButton(
                key: const ValueKey('fake_weather_trailing'),
                onPressed: () => trailingTaps++,
                icon: const Icon(Icons.cloud),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.byKey(const ValueKey('fake_weather_trailing')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(trailingTaps, 1);
      expect(find.text("Today's Plan"), findsNothing);

      // Control: the title region still opens the sheet.
      await tester.tap(find.text('Today Summary'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump();
      expect(find.text("Today's Plan"), findsOneWidget);
    });
  });

  group('progress bar (ruling R1)', () {
    Future<void> pumpSeededCard(
      WidgetTester tester, {
      required TodayPlanData plan,
    }) async {
      final planMem = _CardMemStore();
      final cacheMem = _CardMemStore();
      final planStore = TodayPlanStore.testInstance();
      planStore.debugSetStore(
          read: planMem.read, write: planMem.write, delete: planMem.delete);
      final cache = TodaySummaryCache.testInstance();
      cache.debugSetStore(
          read: cacheMem.read,
          write: cacheMem.write,
          delete: cacheMem.delete);
      await cache.save(
        email: 'a@x.com',
        todayStr: dateStrOf(DateTime.now()),
        plan: plan,
        trends: const [],
      );
      final session = FakeSessionStore()
        ..token = 'tok'
        ..email = 'a@x.com';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: TodaySummaryCard(
                // The pull fails honestly, so the card stands on
                // its cache seed — the production offline path.
                backend: TabsBackend(
                  client: MockClient(
                      (request) async => http.Response('boom', 500)),
                  sessionStore: session,
                ),
                healthConnectService: _FakeHc(),
                planStore: planStore,
                summaryCache: cache,
                sessionStore: session,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
    }

    testWidgets(
        'skipped dose counts as resolved: planned 4 with 2 open '
        'items puts the marker at the track midpoint', (tester) async {
      // remainingCount is 3 by the subtitle's pre-existing
      // semantics (the skipped dose still counts as remaining
      // there); the BAR's resolved = planned − open items = 2
      // (one taken + one skipped), so progress is exactly 0.5.
      await pumpSeededCard(
        tester,
        plan: const TodayPlanData(
          items: [
            TodayPlanItem(
              kind: PlanItemKind.medication,
              id: 'med_a_Daily',
              title: 'Med A',
              timeDisplay: 'Daily',
              isCompleted: false,
              dose: '1',
              medKey: 'med-a',
              slot: 'Daily',
            ),
            TodayPlanItem(
              kind: PlanItemKind.medication,
              id: 'med_b_Daily',
              title: 'Med B',
              timeDisplay: 'Daily',
              isCompleted: false,
              dose: '1',
              medKey: 'med-b',
              slot: 'Daily',
            ),
          ],
          plannedCount: 4,
          remainingCount: 3,
          overdueCount: 0,
          summaryText: '3 items remaining',
        ),
      );

      expect(
          find.byKey(const ValueKey('todaySummaryProgressBar')),
          findsOneWidget);
      final track = tester
          .getRect(find.byKey(const ValueKey('todaySummaryProgressTrack')));
      final marker = tester
          .getRect(find.byKey(const ValueKey('todaySummaryProgressMarker')));
      expect(marker.center.dx, closeTo(track.center.dx, 1.5));
      expect(find.byKey(const ValueKey('todaySummaryProgressFinish')),
          findsOneWidget);
      expect(find.byIcon(Icons.sports_score), findsOneWidget);
    });

    testWidgets('plannedCount == 0 renders NO bar (never a fake 0)',
        (tester) async {
      await pumpSeededCard(
        tester,
        plan: const TodayPlanData(
          items: [],
          plannedCount: 0,
          remainingCount: 0,
          overdueCount: 0,
          summaryText: 'No plans recorded today',
        ),
      );
      expect(find.byKey(const ValueKey('todaySummaryProgressBar')),
          findsNothing);
      expect(find.byKey(const ValueKey('todaySummaryProgressTrack')),
          findsNothing);
    });
  });

  group('daily score history verdict chip', () {
    testWidgets(
        "today's row carries the verdict chip; other rows do not",
        (tester) async {
      final disk = <String, String>{};
      final store = HealthHistoryStore.testInstance();
      store.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      store.debugReset();
      final now = DateTime.now();
      final today = historyDateStr(now);
      final yesterday =
          historyDateStr(now.subtract(const Duration(days: 1)));
      await store.mergeRefresh([
        DailyBiometrics(date: today, restingHrBpm: 60),
        DailyBiometrics(date: yesterday, restingHrBpm: 60),
      ]);
      await store.replaceScore(today,
          dailyScore: 73, scoreHrv: 73, scoreRestingHr: 73);
      await store.replaceScore(yesterday,
          dailyScore: 100, scoreHrv: 100, scoreRestingHr: 100);

      await tester.pumpWidget(
        MaterialApp(
          home: DailyScoreScreen(
            store: store,
            snapshotCapture: ({bool force = false}) async => true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      final chip =
          find.byKey(const ValueKey('daily_score_today_verdict_chip'));
      expect(chip, findsOneWidget);
      expect(
        find.descendant(of: chip, matching: find.text('Good')),
        findsOneWidget,
      );
    });
  });
}
