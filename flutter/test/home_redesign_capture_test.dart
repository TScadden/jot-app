import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

import 'test_helpers.dart';

/// Home redesign — visual capture harness (modeled on
/// morning_score_capture_test.dart / lab_blackglass_render_test).
///
/// Frames (all @ DPR 3.0, animations disabled):
/// - home_360 / home_390: the redesigned Home (score 73, streaks
///   68 best / 18 current, vitals 74 / 159 / 10 logs / 8h30m, plan
///   marker mid-track from a cache-seeded plan: planned 4, two
///   open meds, one taken + one SKIPPED dose resolved — the
///   subtitle's remainingCount 3 keeps its pre-existing semantics
///   while the bar reads (4−2)/4 = 0.5).
/// - drawer_open_360: the one-row "AI Advocate" drawer.
/// - sheet_unchecked_360 / sheet_checked_360: the Today Summary
///   sheet hosting the check-in (checked fixture logs
///   'Feeling: 3/5 Today' → '3 · Average').
///
/// Output dir: $HOME_REDESIGN_CAPTURE_OUT, default
/// ~/workspace/jotapp-home-redesign/captures.
///
/// Note: the Bandit slot renders its still path here —
/// video_player cannot initialize inside the widget-test
/// harness (the slot's FLUTTER_TEST gate), so the frames show
/// the approved mascot figure where the reading loop plays on
/// device.

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

MockClient _mockBackend({required bool checked}) {
  final now = DateTime.now().millisecondsSinceEpoch;
  Map<String, dynamic> entry(
          int id, int categoryId, String body, String chips) =>
      {
        'id': id,
        'categoryId': categoryId,
        'body': body,
        'chips': chips,
        'manualText': '',
        'timestamp': now,
      };
  final entries = <Map<String, dynamic>>[
    for (var i = 0; i < (checked ? 9 : 10); i++)
      entry(100 + i, 1, 'entry $i', '[]'),
    if (checked)
      entry(200, 6, 'Feeling: 3/5 Today', '["Daily Ranking"]'),
  ];
  return MockClient((request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(
        jsonEncode({
          'entries': entries,
          'categories': [
            {'id': 1, 'name': 'Symptoms'},
            {'id': 4, 'name': 'Goals & Habits'},
            {'id': 6, 'name': 'Mood & Energy'},
            {'id': 8, 'name': 'Medication'},
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
    if (request.url.path == '/api/sync/entries') {
      return http.Response('{}', 200);
    }
    return http.Response('not found', 404);
  });
}

Future<void> _bridge(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
  }
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
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

  testWidgets('capture the redesigned Home frames', (tester) async {
    final outDir = Directory(
      Platform.environment['HOME_REDESIGN_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/jotapp-home-redesign/captures',
    );
    // createSync, NOT await create(): a real-IO await in the
    // fake-async test zone deadlocks (blackglass harness lesson).
    outDir.createSync(recursive: true);

    // Shared in-memory stores.
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
    await scoreStore
        .mergeRefresh([DailyBiometrics(date: today, restingHrBpm: 60)]);
    await scoreStore.replaceScore(today,
        dailyScore: 73, scoreHrv: 73, scoreRestingHr: 73);

    // Plan seed through the card's own cache fallback (the card's
    // default backend has no session in the harness, so its pull
    // fails honestly and the seed stands — the production
    // offline path, as in the blackglass harness).
    final summaryCache = TodaySummaryCache.instance;
    summaryCache.debugSetStore(read: read, write: write, delete: delete);
    summaryCache.debugReset();
    await summaryCache.save(
      email: null,
      todayStr: dateStrOf(DateTime.now()),
      plan: const TodayPlanData(
        items: [
          TodayPlanItem(
            kind: PlanItemKind.medication,
            id: 'med_med-uuid-ss31_Daily',
            title: 'SS-31 Peptide',
            timeDisplay: 'Daily',
            isCompleted: false,
            dose: '0.05',
            medKey: 'med-uuid-ss31',
            slot: 'Daily',
          ),
          TodayPlanItem(
            kind: PlanItemKind.medication,
            id: 'med_med-uuid-iva_Daily',
            title: 'Ivabradine',
            timeDisplay: 'Daily',
            isCompleted: false,
            dose: '7.5mg',
            medKey: 'med-uuid-iva',
            slot: 'Daily',
          ),
        ],
        plannedCount: 4,
        remainingCount: 3,
        overdueCount: 0,
        summaryText: '3 items remaining',
      ),
      trends: const [],
    );

    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      try {
        final icons = await File(
          '${Platform.environment['HOME']}/workspace/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ).readAsBytes();
        final iconLoader = FontLoader('MaterialIcons');
        iconLoader.addFont(
          Future.value(ByteData.view(Uint8List.fromList(icons).buffer)),
        );
        await iconLoader.load();
      } catch (_) {}
      for (final (family, path) in [
        (
          'Noto Color Emoji',
          '/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf',
        ),
        (
          'Noto Sans Symbols 2',
          '/usr/share/fonts/truetype/noto/NotoSansSymbols2-Regular.ttf',
        ),
      ]) {
        try {
          final bytes = await File(path).readAsBytes();
          final emojiLoader = FontLoader(family);
          emojiLoader.addFont(
            Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)),
          );
          await emojiLoader.load();
        } catch (_) {}
      }
    });

    final rootBoundaryKey = GlobalKey();

    Future<void> pumpHome({required bool checked}) async {
      TabsBackend.debugResetSharedCaches();
      LogEntryOutbox.instance.debugReset();
      // Dispose the previous Home outright: a same-position
      // pumpWidget would UPDATE the live HomeScreen state, whose
      // loads (bound to the old fixture's backend at initState)
      // would never rerun.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final backend = TabsBackend(
        client: _mockBackend(checked: checked),
        sessionStore: FakeSessionStore()..token = 'tok',
      );
      await tester.pumpWidget(
        RepaintBoundary(
          key: rootBoundaryKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              fontFamily: 'Roboto',
              fontFamilyFallback: const [
                'Noto Color Emoji',
                'Noto Sans Symbols 2',
              ],
            ),
            home: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: HomeScreen(
                weatherApi: WeatherApiClient(client: _mockWeather()),
                tabsBackend: backend,
                logEntryOutbox: LogEntryOutbox.instance,
                healthConnectService: _FakeHc(),
                healthRepository:
                    HealthRepository(hc: _FakeHc(), backend: backend),
                healthHistoryStore: scoreStore,
                dailyScoreSnapshotCapture: ({bool force = false}) async =>
                    true,
              ),
            ),
          ),
        ),
      );
      await _bridge(tester);
    }

    Future<void> capture(String name, int wantW, int wantH) async {
      final boundary = rootBoundaryKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
        if (image.width != wantW || image.height != wantH) {
          throw StateError(
              'capture $name size ${image.width}x${image.height}, want ${wantW}x$wantH');
        }
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    Future<void> openSheet() async {
      await tester.tap(find.text('Today Summary'));
      await tester.pump();
      await _bridge(tester);
    }

    // FRAME 1 — home_360 (unchecked fixture).
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await pumpHome(checked: false);
    await capture('home_360', 1080, 2400);

    // FRAME 2 — home_390.
    tester.view.physicalSize = const Size(1170, 2532);
    await tester.pump();
    await _bridge(tester);
    await capture('home_390', 1170, 2532);
    tester.view.physicalSize = const Size(1080, 2400);
    await tester.pump();

    // FRAME 3 — drawer_open_360.
    await tester.tap(find.byKey(const ValueKey('home_drawer_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.text('AI Advocate'), findsOneWidget);
    await capture('drawer_open_360', 1080, 2400);
    await tester.tapAt(const Offset(340, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // FRAME 4 — sheet_unchecked_360.
    await openSheet();
    expect(find.text('How are you feeling?'), findsOneWidget);
    await capture('sheet_unchecked_360', 1080, 2400);
    await tester.tapAt(const Offset(180, 20));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    // FRAME 5 — sheet_checked_360 (checked fixture).
    await pumpHome(checked: true);
    await openSheet();
    expect(find.text('3 · Average'), findsOneWidget);
    await capture('sheet_checked_360', 1080, 2400);

    // Drain the score chain so no bounded-read timer is left
    // pending at teardown.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 31));
  });
}
