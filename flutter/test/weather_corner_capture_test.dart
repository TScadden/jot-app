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
import 'package:tabs_lab/src/features/badges/badges_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/theme/animations.dart';

import 'test_helpers.dart';

/// Weather Corner — visual capture harness (modeled on
/// home_redesign_capture_test.dart). Renders the full Home screen
/// with weather loaded and captures the frame at DPR 3.0:
/// - {PREFIX}390: 390dp wide, temp 61 (2-digit)
/// - {PREFIX}360: 360dp wide, temp 61 (2-digit)
/// - {PREFIX}360_temp3digit: 360dp wide, temp 100 (3-digit —
///   the title-collision case)
///
/// PREFIX comes from $WEATHER_CORNER_PREFIX (default 'after_') so
/// the same harness produces the before set on unmodified code and
/// the after set on the fixed code. Output dir:
/// $WEATHER_CORNER_CAPTURE_OUT, default
/// ~/workspace/build-weather-corner/captures.
///
/// Each capture also writes a `<name>.json` sidecar with the
/// widget rects (card, title, temp text, weather icon, weather
/// button) in dp, for the programmatic pixel-measurement step.

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

MockClient _mockWeather(int temp) => MockClient((request) async {
  if (request.url.host == 'ipinfo.io') {
    return http.Response(
      '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
      200,
    );
  }
  return http.Response(
    '{"current":{"temperature_2m":$temp.0,"weather_code":2,"is_day":1}}',
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

Future<void> _dismissCelebrationIfShown(WidgetTester tester) async {
  final yay = find.byKey(const Key('celebrationYay'));
  if (yay.evaluate().isEmpty) return;
  await tester.tap(yay);
  await tester.pump();
  final yayAgain = find.byKey(const Key('celebrationYay'));
  if (yayAgain.evaluate().isNotEmpty) {
    await tester.tap(yayAgain);
    await tester.pump();
  }
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  final outDir = Directory(
    Platform.environment['WEATHER_CORNER_CAPTURE_OUT'] ??
        '${Platform.environment['HOME']}'
            '/workspace/build-weather-corner/captures',
  );
  final prefix = Platform.environment['WEATHER_CORNER_PREFIX'] ?? 'after_';

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

  Future<void> runCapture(
    WidgetTester tester, {
    required double widthDp,
    required int temp,
    required String name,
  }) async {
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
    tester.view.physicalSize = Size(widthDp * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

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
              weatherApi: WeatherApiClient(client: _mockWeather(temp)),
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
    await _dismissCelebrationIfShown(tester);
    if (find.byType(BadgeUnlockDialog).evaluate().isNotEmpty) {
      await tester.tap(
        find.descendant(
          of: find.byType(BadgeUnlockDialog),
          matching: find.text('Done'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    }

    // Weather must be loaded (temp text visible) before capture.
    expect(
      find.text('$temp°'),
      findsOneWidget,
      reason: 'weather temp text should be rendered',
    );
    expect(find.byType(AnimatedWeatherIcon), findsOneWidget);

    Map<String, double> rectOf(Rect r) => {
      'left': r.left,
      'top': r.top,
      'right': r.right,
      'bottom': r.bottom,
      'width': r.width,
      'height': r.height,
    };
    final cardRect = tester.getRect(find.byType(TodaySummaryCard));
    final titleRect = tester.getRect(find.text('Today Summary').first);
    final tempRect = tester.getRect(find.text('$temp°'));
    final iconRect = tester.getRect(find.byType(AnimatedWeatherIcon));
    final buttonRect = tester.getRect(find.byTooltip('Weather'));
    final sidecar = {
      'widthDp': widthDp,
      'temp': temp,
      'card': rectOf(cardRect),
      'title': rectOf(titleRect),
      'tempText': rectOf(tempRect),
      'weatherIcon': rectOf(iconRect),
      'weatherButton': rectOf(buttonRect),
    };
    // ignore: avoid_print
    print('WEATHER_CORNER_RECTS $name ${jsonEncode(sidecar)}');

    final boundary =
        rootBoundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${outDir.path}/$name.png')
          .writeAsBytes(byteData!.buffer.asUint8List());
      await File('${outDir.path}/$name.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(sidecar));
    });

    // Drain bounded-read timers so none outlive the tree.
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 31));
  }

  testWidgets('capture weather corner at 390 (temp 61)', (tester) async {
    await runCapture(tester, widthDp: 390, temp: 61, name: '${prefix}390');
  });

  testWidgets('capture weather corner at 360 (temp 61)', (tester) async {
    await runCapture(tester, widthDp: 360, temp: 61, name: '${prefix}360');
  });

  testWidgets('capture weather corner at 360 (temp 100, 3-digit)', (
    tester,
  ) async {
    await runCapture(
      tester,
      widthDp: 360,
      temp: 100,
      name: '${prefix}360_temp3digit',
    );
  });
}
