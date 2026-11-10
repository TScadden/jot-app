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
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';

import 'test_helpers.dart';

/// Capture harness for the Weekly Snapshot metric-dropdown overflow
/// fix (Nov 6, 2026). NOT a behavior test — the behavior proof lives
/// in weekly_snapshot_test.dart. This renders the real Home screen
/// at device size (1080x1920, DPR 3.0 — a 360x640 logical phone,
/// chosen because on this shorter device the Weekly Snapshot
/// selector sits low enough that only ~243dp remains below it),
/// opens the metric dropdown,
/// and writes a PNG showing the panel capped to the space below the
/// selector (scrollable inside) instead of running off the bottom.
///
/// Fonts are loaded with FontLoader (Roboto from assets, Material
/// Icons from the local Flutter SDK cache) exactly like the
/// settingsfullscreen / blackglass harnesses, so icons render as
/// real glyphs, never hollow placeholder boxes.
///
/// Output: $SNAPSHOT_DROPDOWN_OUT or ~/workspace/tiktok-ui-lab,
/// file tabs_home_weekly_snapshot_dropdown_capped_2026-11-06_v1.png
/// plus a JSON sidecar with the panel rect.
class _RenderServer {
  http.Client get client => MockClient(_handle);

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(
        jsonEncode({
          'entries': const [],
          'categories': [
            {'id': 1, 'name': 'Symptoms'},
            {'id': 4, 'name': 'Goals & Habits'},
            {'id': 8, 'name': 'Medication'},
          ],
          'profile': {'medications': '[]', 'reminders': '[]'},
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
  ) async => const [];

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

  testWidgets('capture Home with capped snapshot dropdown open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 1920);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final outDirPath =
        Platform.environment['SNAPSHOT_DROPDOWN_OUT'] ??
        (() {
          final home = Platform.environment['HOME'] ?? '/home/hatch';
          final lab = Directory('$home/workspace/tiktok-ui-lab');
          return lab.existsSync() ? lab.path : Directory.systemTemp.path;
        })();
    const fileStem = 'tabs_home_weekly_snapshot_dropdown_capped_2026-11-06_v1';
    final outDir = Directory(outDirPath);
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

    // FontLoader first (capture-glyph lesson): real Roboto +
    // MaterialIcons glyphs, never hollow boxes.
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
            data: MediaQueryData.fromView(tester.view)
                .copyWith(disableAnimations: true),
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

    // The Weekly Snapshot card is in view at this device height
    // with its selector low on screen: ~243dp remains below it,
    // far less than the uncapped panel's 386dp — the founder's
    // defect position, where the panel ran off the bottom.
    final card = find.byType(WeeklySnapshotCard);
    expect(card, findsOneWidget);
    await tester.ensureVisible(card);
    await tester.pump();
    await _bridge(tester);

    final selector = find.descendant(
      of: card,
      matching: find.byIcon(Icons.arrow_drop_down),
    );
    expect(selector, findsOneWidget);

    // Open the dropdown and let the overlay settle.
    await tester.tap(selector);
    await tester.pump();
    await _bridge(tester);
    await tester.pump(const Duration(seconds: 1));

    final panel = find.byKey(const ValueKey('weekly_snapshot_metric_panel'));
    expect(panel, findsOneWidget);
    final panelRect = tester.getRect(panel);
    // The cap proof, recorded in the sidecar for Vera: the panel
    // bottom is inside the 800dp viewport and its height is well
    // under the uncapped 8-row height (8 x 48 + border = 386).
    expect(panelRect.bottom, lessThanOrEqualTo(640));
    expect(panelRect.height, lessThan(386));

    final boundary =
        rootBoundaryKey.currentContext!.findRenderObject()!
            as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      if (image.width != 1080 || image.height != 1920) {
        throw StateError(
          'capture size ${image.width}x${image.height}, want 1080x1920',
        );
      }
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('${outDir.path}/$fileStem.png')
          .writeAsBytes(byteData!.buffer.asUint8List());
      await File('${outDir.path}/$fileStem.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert({
          'frame': 'weekly_snapshot_dropdown_open_capped',
          'viewport_physical': [1080, 1920],
          'units': 'logical px (DPR 3.0)',
          'panel_rect': [
            panelRect.left,
            panelRect.top,
            panelRect.right,
            panelRect.bottom,
          ],
          'viewport_logical_height': 640,
          'uncapped_panel_height': 386,
        }),
      );
    });
  });
}
