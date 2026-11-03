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
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';

import 'test_helpers.dart';

/// Lab (TikTok-UI exploration) — the Home screen capture.
///
/// Pumps the REAL Home (plus the real floating dock overlaid, as
/// the shell lays it out) with the same seeded fake data the
/// today-summary suites use — Tyson's plan rows 'SS-31 Peptide'
/// 0.05 Daily and 'Ivabradine' 7.5mg Daily from a fake sync pull,
/// a persisted Daily Score of 78 in an in-memory history store,
/// and a 61° weather mock — at phone resolution (physical
/// 1080x2400, logical 360x800 @ DPR 3.0), expands Today Summary
/// so the plan rows render, and captures the RepaintBoundary to
/// a PNG at exactly 1080x2400.
///
/// Substitution note (also in BUILD.md): the plan rows render
/// because Home now passes its own backend to the Today Summary
/// card (see home_screen.dart); the harness injects that backend
/// through HomeScreen's existing healthRepository/tabsBackend
/// parameters. Everything on screen is the built production
/// widgets — no mock widgets are substituted.

class _RenderServer {
  http.Client get client => MockClient(_handle);

  Map<String, dynamic> _pullBody() {
    final meds = jsonEncode([
      {
        'id': 'med-uuid-ss31',
        'name': 'SS-31 Peptide',
        'dose': '0.05',
        'frequency': 'Daily',
        'startDate': '2026-01-01',
        'endDate': 'Present',
        'isPresent': true,
        'isDeleted': false,
        'updatedAt': '1760000000000',
      },
      {
        'id': 'med-uuid-iva',
        'name': 'Ivabradine',
        'dose': '7.5mg',
        'frequency': 'Daily',
        'startDate': '2026-01-01',
        'endDate': 'Present',
        'isPresent': true,
        'isDeleted': false,
        'updatedAt': '1760000000000',
      },
    ]);
    return {
      'entries': const [],
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
      int days) async {
    return const [];
  }

  @override
  Future<List<({String date, int bpm})>> readRestingHrHistory(
          int days) async =>
      const [];
}

Future<void> _bridge(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)));
  }
  await tester.pump();
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  testWidgets('capture the built Home UI at 1080x2400', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    // In-memory stores so nothing touches platform channels.
    final disk = <String, String>{};
    Future<String?> read(String k) async => disk[k];
    Future<void> write(String k, String v) async => disk[k] = v;
    Future<void> delete(String k) async => disk.remove(k);
    LogEntryOutbox.instance.debugSetStore(
        read: read, write: write, delete: delete);
    LogEntryOutbox.instance.debugReset();
    // Secure-storage-backed stores inside Home (plan store,
    // summary cache, session store) read through the platform
    // channel; mock it to the empty-storage answers so every load
    // completes deterministically in the harness.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async => call.method == 'readAll' ? <String, String>{} : null,
    );
    addTearDown(() => TestDefaultBinaryMessengerBinding
        .instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel(
                'plugins.it_nomads.com/flutter_secure_storage'),
            null));

    final scoreStore = HealthHistoryStore.testInstance();
    scoreStore.debugSetStore(read: read, write: write, delete: delete);
    scoreStore.debugReset();
    final today = historyDateStr(DateTime.now());
    await scoreStore.mergeRefresh(
        [DailyBiometrics(date: today, restingHrBpm: 60)]);
    await scoreStore.replaceScore(today,
        dailyScore: 78, scoreHrv: 78, scoreRestingHr: 78);

    final server = _RenderServer();
    final session = FakeSessionStore()
      ..token = 'tok'
      ..email = 'a@x.com';
    final backend =
        TabsBackend(client: server.client, sessionStore: session);
    final repo = HealthRepository(hc: _FakeHc(), backend: backend);
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

    // The default test font draws every glyph as a block; load the
    // app's bundled Roboto (pubspec assets) so the capture is
    // legible, exactly as golden harnesses do.
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(
          rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      // The Material icon font ships with the Flutter SDK; loading
      // it makes the capture show real icons instead of boxes.
      try {
        final icons = await File(
                '${Platform.environment['HOME']}/workspace/tools/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf')
            .readAsBytes();
        final iconLoader = FontLoader('MaterialIcons');
        iconLoader.addFont(Future.value(
            ByteData.view(Uint8List.fromList(icons).buffer)));
        await iconLoader.load();
      } catch (_) {
        // Icons fall back to boxes; text stays legible either way.
      }
    });

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
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
                  migraineController:
                      MigraineController.production(backend: backend),
                  dailyScoreSnapshotCapture: ({bool force = false}) async =>
                      true,
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: NavDock(
                    selected: DockTab.home,
                    onSelect: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await _bridge(tester);

    // Expand Today Summary so the seeded plan rows render.
    expect(find.text('SS-31 Peptide'), findsNothing);
    await tester.tap(find.text('Today Summary'));
    await tester.pump();
    await _bridge(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('SS-31 Peptide'), findsOneWidget);
    expect(find.text('Ivabradine'), findsOneWidget);
    expect(find.text('78'), findsOneWidget);
    // Scroll so the hero's lower half and the expanded Today's
    // Plan rows share the captured frame.
    await tester.drag(
        find.byType(SingleChildScrollView), const Offset(0, -120));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final boundary = boundaryKey.currentContext!.findRenderObject()!
        as RenderRepaintBoundary;
    // Capture + file writes are REAL async work: they must run in
    // runAsync, or their futures never complete in the fake zone.
    final bytes = await tester.runAsync(() async {
      final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
      if (image.width != 1080 || image.height != 2400) {
        throw StateError(
            'capture size ${image.width}x${image.height}, want 1080x2400');
      }
      final byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      final png = byteData!.buffer.asUint8List();
      final home = Platform.environment['HOME'] ?? '/home/hatch';
      await File('$home/workspace/tiktok-ui-lab/tabs_home_tiktokui_v1.png')
          .writeAsBytes(png);
      await File('$home/workspace/your_files/tabs_home_tiktokui_v1.png')
          .writeAsBytes(png);
      return png;
    });
    // PNG signature + IHDR dimensions at fixed offsets.
    expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    final w =
        (bytes[16] << 24) | (bytes[17] << 16) | (bytes[18] << 8) | bytes[19];
    final h =
        (bytes[20] << 24) | (bytes[21] << 16) | (bytes[22] << 8) | bytes[23];
    expect(w, 1080);
    expect(h, 2400);
  });
}
