import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart'
    show historyDateStr;
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/daily_score_hero_card.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_tray.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';

import 'test_helpers.dart';

/// Lab (TikTok-UI exploration) suite:
/// (a) the morphing tray opens from the dock's center log button,
///     morphs to the note editor, and saving writes through the
///     REAL quick-log note path (outbox staging → POST
///     /api/sync/entries against a fake server);
/// (b) the dock renders as a floating pill with all five slots;
/// (c) Home's Daily Score renders as the hero card (and the old
///     header pairing is gone).
/// The instant-tap suite (today_plan_instant_tap_test.dart) is
/// untouched by this package and must pass unmodified.

class _TrayServer {
  final List<Map<String, dynamic>> postedEntries = [];

  http.Client get client => MockClient(_handle);

  Map<String, dynamic> _pullBody() => {
        'entries': const [],
        'categories': [
          {'id': 1, 'name': 'Symptoms'},
          {'id': 7, 'name': 'General'},
          {'id': 8, 'name': 'Medication'},
        ],
        'profile': {'medications': '[]', 'reminders': '[]'},
        'isUnlimited': true,
        'isAdmin': false,
      };

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(jsonEncode(_pullBody()), 200);
    }
    if (request.url.path == '/api/sync/entries') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      for (final e in (body['entries'] as List)) {
        postedEntries.add((e as Map).cast<String, dynamic>());
      }
      return http.Response('{"success":true}', 200);
    }
    if (request.url.path == '/api/habits') {
      return http.Response('{"habits":[]}', 200);
    }
    return http.Response('{}', 404);
  }
}

class _FakeHc extends HealthConnectService {
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

/// Lets real-async completions land in the fake-async test zone.
Future<void> _bridge(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
  }
  await tester.pump();
}

void _noopSelect(DockTab _) {}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);
  setUp(() {
    final disk = <String, String>{};
    Future<String?> read(String k) async => disk[k];
    Future<void> write(String k, String v) async => disk[k] = v;
    Future<void> delete(String k) async => disk.remove(k);
    LogEntryOutbox.instance.debugSetStore(
        read: read, write: write, delete: delete);
    LogEntryOutbox.instance.debugReset();
    QuickLogCache.instance.debugSetStore(
        read: read, write: write, delete: delete);
    QuickLogCache.instance.debugReset();
    HomeDataCache.instance.debugSetStore(
        read: read, write: write, delete: delete);
    HomeDataCache.instance.debugReset();
  });

  testWidgets(
      '(a) tray opens from the log button, morphs to the note '
      'editor, and saving writes through the real quick-log path',
      (tester) async {
    final server = _TrayServer();
    final session = FakeSessionStore()
      ..token = 'tok'
      ..email = 'a@x.com';
    final backend =
        TabsBackend(client: server.client, sessionStore: session);
    await tester.pumpWidget(MaterialApp(
      home: MainShell(
        tabsBackend: backend,
        logEntryOutbox: LogEntryOutbox.instance,
        // Externally owned so the shell's Home never disposes it
        // mid-test (its initialize completes against the fake
        // backend instead of a stalled real one).
        migraineController: MigraineController.production(backend: backend),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    // Tap the dock's center log button.
    await tester.tap(find.descendant(
      of: find.byType(NavDock),
      matching: find.byIcon(Icons.edit),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await _bridge(tester);

    // Root state: tray chrome + the note entry + real categories.
    expect(find.byType(QuickLogTray), findsOneWidget);
    expect(find.text('Quick Log'), findsOneWidget);
    expect(find.text('Your quick note'), findsOneWidget);
    expect(find.text('Symptoms'), findsOneWidget);
    expect(find.text('General'), findsOneWidget);
    // The category load landed during the bridge and the tray is
    // morphing taller (AnimatedSize); let the morph settle so the
    // rows are inside the tray's hit area before tapping.
    await tester.pump(const Duration(milliseconds: 400));

    // Morph to the editor state.
    await tester.tap(find.text('Your quick note'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(TextField), findsOneWidget);
    expect(
      find.text('Add optional details about these symptoms…'),
      findsOneWidget,
    );
    // The root rows are gone (content crossfaded, not stacked).
    expect(find.text('Symptoms'), findsNothing);

    // Save a note: it must land on the fake server through the
    // existing POST /api/sync/entries path, filed under the
    // account's General category (id 7), with the screen's exact
    // chipless payload shape.
    await tester.enterText(find.byType(TextField), 'Felt dizzy at noon');
    await tester.pump();
    await tester.tap(find.widgetWithText(ElevatedButton, 'Log'));
    await _bridge(tester);
    await tester.pump(const Duration(milliseconds: 400));

    expect(server.postedEntries, hasLength(1));
    expect(server.postedEntries.single['body'], 'Felt dizzy at noon');
    expect(server.postedEntries.single['manualText'], 'Felt dizzy at noon');
    expect(server.postedEntries.single['chips'], '');
    expect(server.postedEntries.single['categoryId'], 7);
    // Tray dismissed after the save.
    expect(find.byType(QuickLogTray), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('(b) dock renders as a floating pill with all five slots',
      (tester) async {
    // Pumped directly (the r19c pattern): a full MainShell pump
    // would also mount Home, whose background score capture arms
    // long bounded-read timers that outlive a geometry test.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: NavDock(selected: DockTab.home, onSelect: _noopSelect),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(NavDock), findsOneWidget);
    for (final icon in [
      Icons.home,
      Icons.assignment,
      Icons.edit,
      Icons.favorite,
      Icons.settings,
    ]) {
      expect(
        find.descendant(
            of: find.byType(NavDock), matching: find.byIcon(icon)),
        findsOneWidget,
        reason: 'dock slot icon $icon missing',
      );
    }
    // Floating pill geometry: 64dp pill + 12dp bottom gap, and the
    // pill surface is a 32dp-radius rounded rect.
    final dockSize = tester.getSize(find.byType(NavDock));
    expect(dockSize.height, 64 + 12);
    final pillMaterial = tester.widget<Material>(
      find
          .descendant(
              of: find.byType(NavDock), matching: find.byType(Material))
          .first,
    );
    final shape = pillMaterial.shape! as RoundedRectangleBorder;
    expect(shape.borderRadius, BorderRadius.circular(32));
    // The sliding selected capsule + raised center circle exist.
    expect(find.byKey(const ValueKey('dock_selection_pill')),
        findsOneWidget);
    final ring = tester.widget<Container>(
        find.byKey(const ValueKey('dock_quicklog_ring')));
    expect((ring.decoration! as BoxDecoration).shape, BoxShape.circle);
  });

  testWidgets('(c) Home renders the Daily Score as the hero card',
      (tester) async {
    final disk = <String, String>{};
    final store = HealthHistoryStore.testInstance();
    store.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    store.debugReset();
    final today = historyDateStr(DateTime.now());
    // replaceScore only rewrites an EXISTING row: seed today's row
    // first, then stamp the persisted score onto it.
    await store.mergeRefresh(
        [DailyBiometrics(date: today, restingHrBpm: 60)]);
    await store.replaceScore(today,
        dailyScore: 78, scoreHrv: 78, scoreRestingHr: 78);
    final mockWeather = MockClient((request) async {
      if (request.url.host == 'ipinfo.io') {
        return http.Response(
            '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
            200);
      }
      return http.Response(
          '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
          200);
    });
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: HomeScreen(
          weatherApi: WeatherApiClient(client: mockWeather),
          healthConnectService: _FakeHc(),
          healthHistoryStore: store,
          migraineController: MigraineController.production(),
          dailyScoreSnapshotCapture: ({bool force = false}) async => true,
        ),
      ),
    ));
    await tester.pump();
    await _bridge(tester);

    expect(find.byType(DailyScoreHeroCard), findsOneWidget);
    expect(find.text('78'), findsOneWidget);
    expect(find.text('Good'), findsOneWidget);
    expect(find.text('Daily Score'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
  });
}
