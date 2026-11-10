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
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';

import 'test_helpers.dart';

/// Header alignment package (Nov 10, 2026) — measurement + capture
/// harness. Same fixtures as home_redesign_capture_test.dart
/// (score 73, streaks 68 best / 18 current, vitals 74 / 159 / 10 /
/// 8h30m). Prints exact dp rects for the header elements and writes
/// PNG frames (DPR 3.0) to $HEADER_ALIGN_OUT:
/// - measure_360 / measure_390: progress 0.5 (marker mid-bar)
/// - measure_full_360: progress 1.0 (marker at the flag)

class _FakeHc extends HealthConnectService {
  @override
  Future<HcAvailability> probeAvailability() async => const HcAvailability(
    serviceAvailable: true,
    grantedPermissions: HealthConnectService.requiredPermissions,
    bridgeErrorCode: null,
    stepsProbe: HcReadProbeOutcome.ok,
    persistedConnected: true,
  );

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
    int days,
  ) async {
    return const [];
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(int days) async =>
      const [];
}

MockClient _mockWeather() => MockClient((request) async {
  if (request.url.host == 'ipinfo.io') {
    return http.Response(
      '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
      200,
    );
  }
  return http.Response(
    '{"current":{"temperature_2m":61.0,"weather_code":2,"is_day":1}}',
    200,
  );
});

MockClient _mockBackend() {
  final now = DateTime.now().millisecondsSinceEpoch;
  Map<String, dynamic> entry(
    int id,
    int categoryId,
    String body,
    String chips,
  ) => {
    'id': id,
    'categoryId': categoryId,
    'body': body,
    'chips': chips,
    'manualText': '',
    'timestamp': now,
  };
  final entries = <Map<String, dynamic>>[
    for (var i = 0; i < 10; i++) entry(100 + i, 1, 'entry $i', '[]'),
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
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
  }
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
}

String _r(Rect r) =>
    'L${r.left.toStringAsFixed(2)} T${r.top.toStringAsFixed(2)} '
    'W${r.width.toStringAsFixed(2)} H${r.height.toStringAsFixed(2)} '
    'cx${r.center.dx.toStringAsFixed(2)}';

void _report(WidgetTester tester, String tag) {
  final drawer = tester.getRect(
    find.byKey(const ValueKey('home_drawer_button')),
  );
  final gear = tester.getRect(find.byKey(const ValueKey('home_settings_gear')));
  final pill = tester.getRect(find.byKey(const Key('vitalsStripCompact')));
  final stack = tester.getRect(find.byType(HomeStreakStack));
  final face = tester.getRect(find.byType(DailyScoreFace));
  final finish = tester.getRect(
    find.byKey(const ValueKey('todaySummaryProgressFinish')),
  );
  final marker = tester.getRect(
    find.byKey(const ValueKey('todaySummaryProgressMarker')),
  );
  // Individual streak pills: the height-34 Containers inside the stack.
  final pillRects = <Rect>[];
  final containers = find.descendant(
    of: find.byType(HomeStreakStack),
    matching: find.byType(Container),
  );
  for (var i = 0; i < containers.evaluate().length; i++) {
    final r = tester.getRect(containers.at(i));
    if ((r.height - 34).abs() < 0.6 && r.width > 20) pillRects.add(r);
  }
  final w = tester.view.physicalSize.width / tester.view.devicePixelRatio;
  // ignore: avoid_print
  print('=== MEASURE $tag (screen ${w}dp, px = dp x3) ===');
  // ignore: avoid_print
  print('drawerBtn ${_r(drawer)}');
  // ignore: avoid_print
  print('gear      ${_r(gear)}');
  // ignore: avoid_print
  print('vitals    ${_r(pill)}');
  // ignore: avoid_print
  print('stackBox  ${_r(stack)}');
  for (var i = 0; i < pillRects.length; i++) {
    // ignore: avoid_print
    print('streakPill$i ${_r(pillRects[i])}');
  }
  // ignore: avoid_print
  print('scoreFace ${_r(face)}');
  // ignore: avoid_print
  print('flagBadge ${_r(finish)}');
  // ignore: avoid_print
  print('marker    ${_r(marker)}');
  final leftAxisOff = pillRects.isEmpty
      ? double.nan
      : pillRects.map((r) => r.center.dx).reduce((a, b) => a + b) /
                pillRects.length -
            drawer.center.dx;
  // ignore: avoid_print
  print(
    'AXIS left: stackPillMeanCx - drawerCx = '
    '${leftAxisOff.toStringAsFixed(2)}dp (${(leftAxisOff * 3).toStringAsFixed(1)}px)',
  );
  final rightOff = face.center.dx - gear.center.dx;
  // ignore: avoid_print
  print(
    'AXIS right: scoreCx - gearCx = '
    '${rightOff.toStringAsFixed(2)}dp (${(rightOff * 3).toStringAsFixed(1)}px)',
  );
  final gapSlotL = pill.left - 48;
  final gapSlotR = (w - 48) - pill.right;
  final gapCircL = pill.left - (drawer.center.dx + 20);
  final gapCircR = (gear.center.dx - 20) - pill.right;
  // ignore: avoid_print
  print(
    'PILL ${pill.width.toStringAsFixed(2)} x ${pill.height.toStringAsFixed(2)}dp; '
    'gapToSlotEdge L${gapSlotL.toStringAsFixed(2)}dp/${(gapSlotL * 3).toStringAsFixed(1)}px '
    'R${gapSlotR.toStringAsFixed(2)}dp/${(gapSlotR * 3).toStringAsFixed(1)}px; '
    'gapToCircleEdge L${gapCircL.toStringAsFixed(2)}dp R${gapCircR.toStringAsFixed(2)}dp',
  );
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

  testWidgets('header alignment measurements + captures', (tester) async {
    final outDir = Directory(
      Platform.environment['HEADER_ALIGN_OUT'] ??
          '${Platform.environment['HOME']}/workspace/header-align-captures',
    );
    outDir.createSync(recursive: true);

    final disk = <String, String>{};
    Future<String?> read(String k) async => disk[k];
    Future<void> write(String k, String v) async => disk[k] = v;
    Future<void> delete(String k) async => disk.remove(k);
    LogEntryOutbox.instance.debugSetStore(
      read: read,
      write: write,
      delete: delete,
    );
    LogEntryOutbox.instance.debugReset();

    final scoreStore = HealthHistoryStore.testInstance();
    scoreStore.debugSetStore(read: read, write: write, delete: delete);
    scoreStore.debugReset();
    final today = historyDateStr(DateTime.now());
    await scoreStore.mergeRefresh([
      DailyBiometrics(date: today, restingHrBpm: 60),
    ]);
    await scoreStore.replaceScore(
      today,
      dailyScore: 73,
      scoreHrv: 73,
      scoreRestingHr: 73,
    );

    final summaryCache = TodaySummaryCache.instance;
    summaryCache.debugSetStore(read: read, write: write, delete: delete);
    summaryCache.debugReset();

    Future<void> seedPlan({required bool full}) async {
      summaryCache.debugReset();
      await summaryCache.save(
        email: null,
        todayStr: dateStrOf(DateTime.now()),
        plan: full
            ? const TodayPlanData(
                items: [],
                plannedCount: 4,
                remainingCount: 0,
                overdueCount: 0,
                summaryText: 'All done',
              )
            : const TodayPlanData(
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
    }

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

    Future<void> pumpHome() async {
      TabsBackend.debugResetSharedCaches();
      LogEntryOutbox.instance.debugReset();
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      final backend = TabsBackend(
        client: _mockBackend(),
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
                healthRepository: HealthRepository(
                  hc: _FakeHc(),
                  backend: backend,
                ),
                healthHistoryStore: scoreStore,
                dailyScoreSnapshotCapture: ({bool force = false}) async => true,
              ),
            ),
          ),
        ),
      );
      await _bridge(tester);
    }

    Future<void> capture(String name, int wantW, int wantH) async {
      final boundary =
          rootBoundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
        if (image.width != wantW || image.height != wantH) {
          throw StateError(
            'capture $name size ${image.width}x${image.height}, want ${wantW}x$wantH',
          );
        }
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    await seedPlan(full: false);
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await pumpHome();
    _report(tester, '360 progress=0.5');
    await capture('measure_360', 1080, 2400);

    tester.view.physicalSize = const Size(1170, 2532);
    await tester.pump();
    await _bridge(tester);
    _report(tester, '390 progress=0.5');
    await capture('measure_390', 1170, 2532);

    // Full progress: marker at the flag.
    tester.view.physicalSize = const Size(1080, 2400);
    await seedPlan(full: true);
    await pumpHome();
    _report(tester, '360 progress=1.0');
    await capture('measure_full_360', 1080, 2400);

    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 31));
  });
}
