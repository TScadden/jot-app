import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart'
    show historyDateStr;
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/today_summary.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/feeling_checkin_card.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/migraine_block.dart';
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';

import 'test_helpers.dart';

/// BlackGlass v4 — render + bounding-box harness for the PRODUCTION
/// Home layout (release/vc100113 widgets, unmodified).
///
/// Used twice, with the identical seed, as the layout-freeze gate:
/// once on a clean vc100113 checkout (the overlay BASELINE) and once
/// on lab/blackglass-theme (the themed build). Per capture it writes
/// (a) the PNG at exactly 1080x2400 and (b) a JSON of bounding boxes
/// (tester.getRect, logical px @ DPR 3.0) for every element that
/// matters plus every visible Text widget by its string.
///
/// Output directory: $BLACKGLASS_OUT (falls back to
/// ~/workspace/tiktok-ui-lab when it exists, else system temp).
/// File prefix: $BLACKGLASS_PREFIX (default 'tabs_home_blackglass_v1').
///
/// Seeding (mirrors the earlier Lab package where applicable):
/// - Daily Score 78 in an in-memory HealthHistoryStore.
/// - Today's Plan rows 'SS-31 Peptide' 0.05 Daily and 'Ivabradine'
///   7.5mg Daily, served to the production TodaySummaryCard through
///   its OWN last-known cache (TodaySummaryCache.instance): the
///   production card constructs its own backend, whose pull fails
///   honestly in the harness (no session), so it falls back to the
///   seeded cache exactly as it does offline on device. NO
///   production plumbing is changed to make this happen.
/// - A 61° weather mock and a fake sync pull (for Home's own repo)
///   with no check-in entry, no counters, no Hydration category.
class _RenderServer {
  http.Client get client => MockClient(_handle);

  Map<String, dynamic> _pullBody() {
    return {
      'entries': const [],
      'categories': [
        {'id': 1, 'name': 'Symptoms'},
        {'id': 4, 'name': 'Goals & Habits'},
        {'id': 8, 'name': 'Medication'},
      ],
      'profile': {'medications': '[]', 'reminders': '[]'},
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
      return http.Response('{"success":true}', 200);
    }
    return http.Response('{}', 404);
  }
}

class _FakeHc extends HealthConnectService {
  @override
  Future<HealthConnectStatus> getStatus() async =>
      HealthConnectStatus.connected;

  @override
  Future<int?> readSleepMinutes(String dateStr) async => null;

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

Future<void> _bridge(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
  }
  await tester.pump();
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  testWidgets('capture production Home at 1080x2400 with bboxes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final outDirPath =
        Platform.environment['BLACKGLASS_OUT'] ??
        (() {
          final home = Platform.environment['HOME'] ?? '/home/hatch';
          final lab = Directory('$home/workspace/tiktok-ui-lab');
          return lab.existsSync() ? lab.path : Directory.systemTemp.path;
        })();
    final prefix =
        Platform.environment['BLACKGLASS_PREFIX'] ?? 'tabs_home_blackglass_v1';
    final outDir = Directory(outDirPath);
    // createSync, NOT await create(): a real-IO await in the
    // fake-async test zone deadlocks (found by bisection, Nov 3).
    outDir.createSync(recursive: true);

    // In-memory stores so nothing touches platform channels.
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => call.method == 'readAll' ? <String, String>{} : null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
            null,
          ),
    );

    // Daily Score seed: 78 today.
    final scoreStore = HealthHistoryStore.testInstance();
    scoreStore.debugSetStore(read: read, write: write, delete: delete);
    scoreStore.debugReset();
    final today = historyDateStr(DateTime.now());
    await scoreStore.mergeRefresh([
      DailyBiometrics(date: today, restingHrBpm: 60),
    ]);
    await scoreStore.replaceScore(
      today,
      dailyScore: 78,
      scoreHrv: 78,
      scoreRestingHr: 78,
    );

    // Today Summary seed: the production card's own cache fallback.
    final summaryCache = TodaySummaryCache.instance;
    summaryCache.debugSetStore(read: read, write: write, delete: delete);
    summaryCache.debugReset();
    const plan = TodayPlanData(
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
      plannedCount: 2,
      remainingCount: 2,
      overdueCount: 0,
      summaryText: '2 items remaining',
    );
    await summaryCache.save(
      email: null,
      todayStr: dateStrOf(DateTime.now()),
      plan: plan,
      trends: const [],
    );

    final server = _RenderServer();
    final session = FakeSessionStore()
      ..token = 'tok'
      ..email = 'a@x.com';
    final backend = TabsBackend(client: server.client, sessionStore: session);
    final repo = HealthRepository(hc: _FakeHc(), backend: backend);
    final mockWeather = MockClient((request) async {
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

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          fontFamily: 'Roboto',
          fontFamilyFallback: const ['Noto Color Emoji', 'Noto Sans Symbols 2'],
        ),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: RepaintBoundary(
            key: boundaryKey,
            child: Stack(
              children: [
                HomeScreen(
                  weatherApi: WeatherApiClient(client: mockWeather),
                  healthRepository: repo,
                  tabsBackend: backend,
                  healthHistoryStore: scoreStore,
                  migraineController: MigraineController.production(
                    backend: backend,
                  ),
                  dailyScoreSnapshotCapture: ({bool force = false}) async =>
                      true,
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: NavDock(selected: DockTab.home, onSelect: (_) {}),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await _bridge(tester);
    await tester.pump(const Duration(seconds: 3));

    // Collapsed-by-default is the production behavior (gate: the
    // plan rows must NOT be visible before the expand tap).
    expect(find.text('Today Summary'), findsOneWidget);
    expect(find.text('SS-31 Peptide'), findsNothing);

    List<Map<String, dynamic>> collectBoxes() {
      final out = <Map<String, dynamic>>[];
      void add(String id, Finder finder) {
        var i = 0;
        for (final e in finder.evaluate()) {
          final r = tester.getRect(find.byWidget(e.widget));
          out.add({
            'id': i == 0 ? id : '$id#$i',
            'rect': [
              double.parse(r.left.toStringAsFixed(2)),
              double.parse(r.top.toStringAsFixed(2)),
              double.parse(r.right.toStringAsFixed(2)),
              double.parse(r.bottom.toStringAsFixed(2)),
            ],
          });
          i++;
        }
      }

      add('type:DailyScoreCircle', find.byType(DailyScoreCircle));
      add('type:DailyScoreFace', find.byType(DailyScoreFace));
      add('type:FeelingCheckInCard', find.byType(FeelingCheckInCard));
      add('type:VitalsStrip', find.byType(VitalsStrip));
      add('type:HomeStreakRow', find.byType(HomeStreakRow));
      add('type:TodaySummaryCard', find.byType(TodaySummaryCard));
      add('type:MigraineBlock', find.byType(MigraineBlock));
      add('type:WeeklySnapshotCard', find.byType(WeeklySnapshotCard));
      add('type:NavDock', find.byType(NavDock));
      add(
        'key:dock_selection_pill',
        find.byKey(const ValueKey('dock_selection_pill')),
      );
      add(
        'key:dock_quicklog_ring',
        find.byKey(const ValueKey('dock_quicklog_ring')),
      );
      add('tooltip:Take Medication', find.byTooltip('Take Medication'));
      add('tooltip:Skip Medication', find.byTooltip('Skip Medication'));
      // Every visible Text widget, by its string.
      final seen = <String, int>{};
      for (final e in find.byType(Text).evaluate()) {
        final w = e.widget as Text;
        final s = w.data ?? w.textSpan?.toPlainText() ?? '';
        final n = seen[s] ?? 0;
        seen[s] = n + 1;
        final r = tester.getRect(find.byWidget(w));
        out.add({
          'id': n == 0 ? 'text:$s' : 'text:$s#$n',
          'rect': [
            double.parse(r.left.toStringAsFixed(2)),
            double.parse(r.top.toStringAsFixed(2)),
            double.parse(r.right.toStringAsFixed(2)),
            double.parse(r.bottom.toStringAsFixed(2)),
          ],
        });
      }
      out.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
      return out;
    }

    Future<void> capture(String frame, String suffix) async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final boxes = collectBoxes();
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
        if (image.width != 1080 || image.height != 2400) {
          throw StateError(
            'capture size ${image.width}x${image.height}, want 1080x2400',
          );
        }
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        final bytes = byteData!.buffer.asUint8List();
        await File('${outDir.path}/$prefix$suffix.png').writeAsBytes(bytes);
        await File('${outDir.path}/$prefix$suffix.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'frame': frame,
            'viewport_physical': [1080, 2400],
            'units': 'logical px (DPR 3.0)',
            'elements': boxes,
          }),
        );
      });
    }

    // FRAME 1 — hero frame: top of Home, Today Summary COLLAPSED
    // (the production default state).
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    expect(scrollable.position.pixels, 0);
    await capture('hero', '');

    // Expand Today Summary so the seeded plan rows render, settle,
    // then scroll the minimum so both rows sit fully clear of the
    // floating dock (same discipline as the earlier Lab package).
    await tester.tap(find.text('Today Summary'));
    await tester.pump();
    await _bridge(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('SS-31 Peptide'), findsOneWidget);
    expect(find.text('Ivabradine'), findsOneWidget);

    final dockTop = tester.getTopLeft(find.byType(NavDock)).dy;
    final doseRect = tester.getRect(find.text('7.5mg · Daily'));
    final shift = doseRect.bottom + 14 + 8 - dockTop;
    if (shift > 0) {
      scrollable.position.jumpTo(scrollable.position.pixels + shift);
    }
    await tester.pump();
    await _bridge(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(
      tester.getRect(find.text('SS-31 Peptide')).top,
      greaterThanOrEqualTo(0),
    );
    expect(
      tester.getRect(find.text('7.5mg · Daily')).bottom + 14,
      lessThan(dockTop),
    );

    // FRAME 2 — plan frame.
    await capture('plan', '_plan');
  });
}
