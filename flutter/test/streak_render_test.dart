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
import 'package:tabs_lab/src/data/health_history_queries.dart'
    show historyDateStr;
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/migraine_controller.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';

import 'test_helpers.dart';

/// Lab (streak screen package, Nov 4, 2026) — render harness for
/// the delivery captures at exactly 1080x2400:
///
/// - `tabs_home_streakscreen_v1.png` — production Home, pull seeded
///   with currentStreak 6 / bestStreak 12; the streak pills show
///   the engine's values and are the tap target.
/// - `tabs_streak_screen_v1.png` — the Streak detail screen for the
///   same state (restore still available).
/// - `tabs_streak_screen_saved_v1.png` — the Streak screen scrolled
///   to History for a state whose save restored a day two days ago:
///   the day is marked in Tabs purple, the legend shows, and the
///   Restore card reads "No restores left this month".
///
/// Output directory: $STREAK_OUT (falls back to
/// ~/workspace/tiktok-ui-lab when it exists, else system temp).
/// Like the other Lab harnesses, in CI this simply exercises the
/// widgets; the PNGs matter on local runs.
class _RenderServer {
  http.Client get client => MockClient(_handle);

  /// Profile pushes the app made, decoded — the read-back evidence
  /// that the settled streak record returns to the server.
  final List<Map<String, dynamic>> profilePushes = [];

  Map<String, dynamic> _pullBody() {
    return {
      'entries': const [],
      'categories': [
        {'id': 1, 'name': 'Symptoms'},
        {'id': 4, 'name': 'Goals & Habits'},
        {'id': 8, 'name': 'Medication'},
      ],
      'profile': {
        'medications': '[]',
        'reminders': '[]',
        // The founder's actual frozen counters (verified on the
        // live profile Nov 5, 2026) and NO streakState blob —
        // the exact pre-fix server record.
        'currentStreak': 14,
        'bestStreak': 68,
      },
      'isUnlimited': true,
      'isAdmin': false,
    };
  }

  Future<http.Response> _handle(http.Request request) async {
    if (request.url.path == '/api/sync/pull') {
      return http.Response(jsonEncode(_pullBody()), 200);
    }
    if (request.url.path == '/api/sync/profile') {
      profilePushes.add(
        jsonDecode(request.body) as Map<String, dynamic>,
      );
      return http.Response('{"saved":true}', 200);
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

/// Captures MUST run inside tester.runAsync (the blackglass
/// harness pattern): calling toImage directly in the fake-async
/// zone lets the body finish but wedges test completion — the
/// test reports "did not complete" at teardown. Bisected Nov 5,
/// 2026 (probe D: body done in 919 ms, completion hung).
Future<void> _capture(
  WidgetTester tester,
  GlobalKey boundaryKey,
  Directory outDir,
  String name,
) async {
  final boundary =
      boundaryKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 3.0);
    if (image.width != 1080 || image.height != 2400) {
      throw StateError(
        'capture size ${image.width}x${image.height}, want 1080x2400',
      );
    }
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('${outDir.path}/$name').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  testWidgets('capture Home + streak screens at 1080x2400', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final outDirPath =
        Platform.environment['STREAK_OUT'] ??
        (() {
          final home = Platform.environment['HOME'] ?? '/home/hatch';
          final lab = Directory('$home/workspace/vc100115-ship/captures');
          return lab.existsSync() ? lab.path : Directory.systemTemp.path;
        })();
    final outDir = Directory(outDirPath);
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
    StreakStore.instance.debugSetStore(
      read: read,
      write: write,
      delete: delete,
    );
    StreakStore.instance.debugReset();
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

    // Daily Score seed: 78 today (same as the blackglass harness).
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
          '${Platform.environment['HOME']}/workspace/flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
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

    ThemeData theme() => ThemeData(
          fontFamily: 'Roboto',
          fontFamilyFallback: const ['Noto Color Emoji', 'Noto Sans Symbols 2'],
        );

    final homeBoundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: RepaintBoundary(
            key: homeBoundary,
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
    // The streak pills carry the engine's seeded values.
    expect(find.byKey(const Key('homeStreakPills')), findsOneWidget);
    await _capture(tester, homeBoundary, outDir, 'tabs_home_streak_vc100115_2026-11-05.png');

    // Rect evidence for the gate: the streak band + pill target
    // box on Home (logical px @ DPR 3.0, same convention as the
    // other Lab harnesses). Home redesign: the corner band's
    // HomeStreakStack replaces the old HomeStreakRow in the body;
    // the JSON field keeps its historical name for the gate.
    final rowRect = tester.getRect(find.byType(HomeStreakStack));
    final pillsRect = tester.getRect(find.byKey(const Key('homeStreakPills')));
    // Read-back proof: the settle pushed the adopted record back
    // to the (mock) profile — counters 14/68 plus a streakState
    // blob holding a 14-day counted run ending today. This is the
    // exact payload shape the live server now stores.
    expect(server.profilePushes, isNotEmpty);
    final streakPush = server.profilePushes.lastWhere(
      (p) => p.containsKey('streakState'),
    );
    expect(streakPush['currentStreak'], 14);
    expect(streakPush['bestStreak'], 68);
    final pushedState = StreakState.fromJson(
      jsonDecode(streakPush['streakState'] as String)
          as Map<String, dynamic>,
    );
    expect(pushedState.countedDays, hasLength(14));
    expect(pushedState.lastEvaluatedDay, streakDayStr(DateTime.now()));

    File('${outDir.path}/tabs_streak_captures_vc100115_2026-11-05.json')
        .writeAsStringSync(
      jsonEncode({
        'profilePush': streakPush,
        'homeStreakRow': {
          'left': rowRect.left,
          'top': rowRect.top,
          'width': rowRect.width,
          'height': rowRect.height,
        },
        'homeStreakPills': {
          'left': pillsRect.left,
          'top': pillsRect.top,
          'width': pillsRect.width,
          'height': pillsRect.height,
        },
      }),
    );

    final now = DateTime.now();
    final freshState = streakSeed(current: 14, best: 68, now: now);
    final screenBoundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: RepaintBoundary(
            key: screenBoundary,
            child: StreakScreen(state: freshState, now: now),
          ),
        ),
      ),
    );
    await tester.pump();
    await _bridge(tester);
    expect(find.text('1 restore left this month'), findsOneWidget);
    await _capture(tester, screenBoundary, outDir, 'tabs_streak_screen_vc100115_2026-11-05.png');

    var savedState = streakSeed(
      current: 5,
      best: 12,
      now: now.subtract(const Duration(days: 3)),
    );
    savedState = streakEvaluate(
      savedState,
      now.subtract(const Duration(days: 1)),
    );
    savedState = streakEvaluate(savedState, now);
    expect(savedState.restoredDays, isNotEmpty);
    final savedBoundary = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: theme(),
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: RepaintBoundary(
            key: savedBoundary,
            child: StreakScreen(state: savedState, now: now),
          ),
        ),
      ),
    );
    await tester.pump();
    await _bridge(tester);
    await tester.scrollUntilVisible(
      find.text('A day with a purple ring was restored.'),
      160,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    expect(
      find.byKey(
        Key('streakRestoredDay-${streakDayStr(now.subtract(const Duration(days: 2)))}'),
      ),
      findsOneWidget,
    );
    await _capture(tester, savedBoundary, outDir, 'tabs_streak_screen_restored_vc100115_2026-11-05.png');
  });
}
