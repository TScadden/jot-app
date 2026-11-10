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
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
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
  Future<HcAvailability> probeAvailability() async => const HcAvailability(
        serviceAvailable: true,
        grantedPermissions: HealthConnectService.requiredPermissions,
        bridgeErrorCode: null,
        stepsProbe: HcReadProbeOutcome.ok,
        persistedConnected: true,
      );

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
    // Settings-gear round: a SECOND boundary around the whole
    // MaterialApp. The inner boundary wraps the Home+dock Stack
    // (a page) and therefore cannot see a pushed ROUTE (the
    // settings tray in V6/V7; the full-screen SettingsScreen
    // since the settings-fullscreen round), which lives in the
    // Navigator overlay above the page; the root boundary
    // captures it. Hero/plan captures keep using the inner
    // boundary exactly as the frozen baseline did.
    final rootBoundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: rootBoundaryKey,
        child: MaterialApp(
        // The root-boundary frames (settings / settings-sub) would
        // otherwise carry the debug banner ribbon at the top
        // right; the production app disables it, and the inner
        // hero/plan captures never contained it (it lives outside
        // the inner boundary), so this changes nothing there.
        debugShowCheckedModeBanner: false,
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
      // Rect from the ELEMENT's render object, not getRect(byWidget):
      // a shared const widget instance mounted twice (the plan
      // rows' identical const 'Overdue' chip, which appears from
      // 18:00 local when 'Daily' items go overdue) makes byWidget
      // ambiguous and crashes the capture. Element rects are the
      // identical boxes getRect returns when unambiguous, so the
      // frozen-baseline comparison is unaffected. (Navbar round
      // harness fix: the crash reproduced byte-identically on the
      // unmodified base branch at 18:xx UTC — pre-existing
      // time-of-day fragility, not a product change.)
      Rect rectOf(Element e) {
        final ro = e.renderObject! as RenderBox;
        return ro.localToGlobal(Offset.zero) & ro.size;
      }

      void add(String id, Finder finder) {
        var i = 0;
        for (final e in finder.evaluate()) {
          final r = rectOf(e);
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
      add('type:HomeStreakStack', find.byType(HomeStreakStack));
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
      // Settings-gear round — placement proof for the header
      // gear + watch pair: the gear by its stable Key, the watch
      // button as the IconButton ancestor of its 'Connections'
      // tooltip (the Tooltip's own box is the button's centered
      // 40dp visual box; the ancestor's is the 48dp target box —
      // the placement numbers are read off the BUTTON boxes).
      add(
        'key:home_settings_gear',
        find.byKey(const ValueKey('home_settings_gear')),
      );
      add('tooltip:Connections', find.byTooltip('Connections'));
      add(
        'button:watch_connections',
        find.ancestor(
          of: find.byTooltip('Connections'),
          matching: find.byType(IconButton),
        ),
      );
      // The pushed full-screen SettingsScreen + its Customize
      // sub-page toggle (settings-fullscreen round: present only
      // in the settings / settings-sub frames; absent — no
      // entries — in the hero/plan frames, exactly as the dock
      // ring was). The tray keys this replaces no longer exist
      // anywhere in the app.
      add('type:SettingsScreen', find.byType(SettingsScreen));
      add(
        'key:nav_labels_toggle',
        find.byKey(const ValueKey('nav_labels_toggle')),
      );
      // Every visible Text widget, by its string.
      final seen = <String, int>{};
      for (final e in find.byType(Text).evaluate()) {
        final w = e.widget as Text;
        final s = w.data ?? w.textSpan?.toPlainText() ?? '';
        final n = seen[s] ?? 0;
        seen[s] = n + 1;
        final r = rectOf(e);
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

    // Open the Today Summary SHEET so the seeded plan rows render
    // (redesign: the card no longer expands in place — the plan
    // lives in the modal sheet, which overlays the dock, so the
    // old scroll-clear-of-dock discipline no longer applies; the
    // rows simply need to sit inside the viewport).
    await tester.tap(find.text('Today Summary'));
    await tester.pump();
    await _bridge(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('SS-31 Peptide'), findsOneWidget);
    expect(find.text('Ivabradine'), findsOneWidget);
    expect(
      tester.getRect(find.text('SS-31 Peptide')).top,
      greaterThanOrEqualTo(0),
    );
    expect(
      tester.getRect(find.text('7.5mg · Daily')).bottom,
      lessThan(800),
    );

    // FRAME 2 — plan frame (the open sheet).
    await capture('plan', '_plan');

    // Dismiss the sheet before the settings frames: the gear sits
    // behind the modal scrim, so a tap there would only close
    // the sheet instead of pushing Settings.
    await tester.tapAt(const Offset(180, 20));
    await tester.pump();
    await _bridge(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('SS-31 Peptide'), findsNothing);

    // ── Settings frames (root boundary — the pushed Settings
    // route is a Navigator-overlay route and lives OUTSIDE the
    // inner boundary). Settings-fullscreen round: the gear pushes
    // the full-screen SettingsScreen (the tray frames this block
    // used to capture are gone with the tray). The page-level
    // MediaQuery disables animations for Home's own widgets, so
    // the gear's SlidePageRoute is built with reducedMotion and
    // the pushed screen is settled when captured.
    // Explicit-filename root capture for the settings frames:
    // their deliverable names are fixed by the package
    // (tabs_settings_fullscreen_v1.png /
    // tabs_settings_fullscreen_subpage_v1.png), not derived from
    // the Home prefix. The JSON sidecar carries the same stem.
    Future<void> captureRootAs(String frame, String fileStem) async {
      final boundary =
          rootBoundaryKey.currentContext!.findRenderObject()!
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
        await File('${outDir.path}/$fileStem.png').writeAsBytes(bytes);
        await File('${outDir.path}/$fileStem.json').writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'frame': frame,
            'viewport_physical': [1080, 2400],
            'units': 'logical px (DPR 3.0)',
            'elements': boxes,
          }),
        );
      });
    }

    final gearFinder = find.byKey(const ValueKey('home_settings_gear'));
    final settingsFinder = find.byType(SettingsScreen);

    // FRAME 3 — full-screen Settings (settled): tap the header
    // gear, let the push finish and the Settings load land. The
    // pushed screen fills the whole surface (no tray exists).
    await tester.tap(gearFinder);
    await tester.pump();
    await _bridge(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(settingsFinder, findsOneWidget);
    expect(tester.getRect(settingsFinder),
        const Rect.fromLTWH(0, 0, 360, 800));
    await captureRootAs('settings', 'tabs_settings_fullscreen_v1');

    // FRAME 4 — Settings SUB-PAGE (Customize): tap 'Customize'
    // inside the pushed screen; the page swaps in place under
    // the screen's own AppBar (back arrow + 'Customize' title).
    final customizeFinder = find.text('Customize');
    await tester.ensureVisible(customizeFinder);
    await tester.pump();
    await tester.tap(customizeFinder);
    await tester.pump();
    await _bridge(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(settingsFinder, findsOneWidget);
    expect(find.byKey(const ValueKey('nav_labels_toggle')),
        findsOneWidget);
    await captureRootAs(
        'settings_sub', 'tabs_settings_fullscreen_subpage_v1');
  });
}
