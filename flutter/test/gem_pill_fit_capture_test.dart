import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/health_history_queries.dart'
    show historyDateStr;
import 'package:tabs_lab/src/data/health_history_store.dart';
import 'package:tabs_lab/src/data/health_repository.dart';
import 'package:tabs_lab/src/data/home_data_cache.dart';
import 'package:tabs_lab/src/data/log_entry_outbox.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/home/bandit_reading_slot.dart';
import 'package:tabs_lab/src/features/home/daily_score_circle.dart';
import 'package:tabs_lab/src/features/home/event_counter_rotator.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/home/vitals_strip.dart';

import 'test_helpers.dart';

/// Gem pill fit package (Nov 23, 2026) — capture + measurement
/// harness for Vera. Full Home frames at DPR 3.0 in the LOGGED
/// band state (scored entry + one event counter), for:
/// - founder: gems 415, streak 32 (his real values)
/// - stress: gems 10000, streak 132
/// at 360 and 390 CSS px. Writes PNGs + a JSON sidecar of widget
/// rects to $GEM_FIT_OUT (default ~/workspace/build-gem-pill-fit/
/// captures/after). Run the same file on the base head with a
/// different $GEM_FIT_OUT for the before frames; the package's
/// measure script diffs them.

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

MockClient _server({required int streak, required int gems}) =>
    MockClient((request) async {
      if (request.url.path == '/api/sync/pull') {
        final now = DateTime.now();
        final target = DateTime(now.year, now.month, now.day + 7);
        return http.Response(
          jsonEncode({
            'entries': [
              {
                'id': 90,
                'categoryId': 6,
                'body': 'Feeling: 3/5 Today',
                'chips': '["Daily Ranking"]',
                'manualText': '',
                'timestamp': now.millisecondsSinceEpoch,
              },
            ],
            'categories': [
              {'id': 1, 'name': 'Symptoms'},
              {'id': 4, 'name': 'Goals & Habits'},
              {'id': 6, 'name': 'Mood & Energy'},
              {'id': 8, 'name': 'Medication'},
            ],
            'profile': {
              'currentStreak': streak,
              'bestStreak': streak,
              'gem_balance': gems,
              'medications': '[]',
              'reminders': '[]',
              'eventCounters': jsonEncode([
                {
                  'id': 'a',
                  'name': 'Alpha',
                  'targetDate': target.millisecondsSinceEpoch,
                  'isUp': false,
                  'autoUp': false,
                  'isFavorite': false,
                  'isArchived': false,
                },
              ]),
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
      return http.Response('not found', 404);
    });

Future<void> _bridge(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
  }
  await tester.pump();
  await tester.pump(const Duration(seconds: 3));
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(seconds: 31));
}

Map<String, dynamic> _rectJson(Rect r) => {
  'left': r.left,
  'top': r.top,
  'width': r.width,
  'height': r.height,
  'right': r.right,
  'bottom': r.bottom,
  'cx': r.center.dx,
};

void main() {
  testWidgets('gem pill fit captures', (tester) async {
    final outDir = Directory(
      Platform.environment['GEM_FIT_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-gem-pill-fit/'
              'captures/after',
    );
    await tester.runAsync(() => outDir.create(recursive: true));

    setUpFontsAndMocks();
    final rootKey = GlobalKey();
    final sidecar = <String, dynamic>{};

    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      final iconsFile = File(
        '${Platform.environment['HOME']}/workspace/tools/flutter/bin/cache/'
        'artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
      if (await iconsFile.exists()) {
        final icons = await iconsFile.readAsBytes();
        final iconLoader = FontLoader('MaterialIcons');
        iconLoader.addFont(
          Future.value(ByteData.view(Uint8List.fromList(icons).buffer)),
        );
        await iconLoader.load();
      }
    });

    Future<void> pumpHome({
      required Size physicalSize,
      required int streak,
      required int gems,
    }) async {
      // Fresh state per frame: dispose the previous Home first.
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      TabsBackend.debugResetSharedCaches();
      HomeDataCache.instance.debugReset();
      GemService.instance.debugReset();

      tester.view.physicalSize = physicalSize;
      tester.view.devicePixelRatio = 3.0;

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
      GemService.instance.debugSetStore(
        read: read,
        write: write,
        delete: delete,
      );

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

      final backend = TabsBackend(
        client: _server(streak: streak, gems: gems),
        sessionStore: FakeSessionStore()..token = 'tok',
      );

      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Roboto'),
            home: TickerMode(
              enabled: false,
              child: MediaQuery(
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
                  dailyScoreSnapshotCapture: ({bool force = false}) async =>
                      true,
                ),
              ),
            ),
          ),
        ),
      );
      await _bridge(tester);
      // Dismiss the streak celebration if it covers Home.
      final yay = find.byKey(const Key('celebrationYay'));
      if (yay.evaluate().isNotEmpty) {
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
      final ctx = tester.element(find.byType(HomeStreakStack));
      await tester.runAsync(
        () => precacheImage(const AssetImage(GemCopy.iconAsset), ctx),
      );
      await tester.pump();
    }

    Future<void> capture(String name, int wantW, int wantH) async {
      final boundary =
          rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
        if (image.width != wantW || image.height != wantH) {
          throw StateError(
            'capture $name size ${image.width}x${image.height}, '
            'want ${wantW}x$wantH',
          );
        }
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
      sidecar[name] = {
        'gemPill': _rectJson(
          tester.getRect(find.byKey(const Key('homeGemPill'))),
        ),
        'gemIcon': _rectJson(
          tester.getRect(find.byKey(const Key('homeGemPillIcon'))),
        ),
        'gemCount': _rectJson(
          tester.getRect(find.byKey(const Key('homeGemPillCount'))),
        ),
        'flamePill': _rectJson(
          tester.getRect(find.byKey(const Key('homeStreakPills'))),
        ),
        'stack': _rectJson(tester.getRect(find.byType(HomeStreakStack))),
        'rotator': _rectJson(tester.getRect(find.byType(EventCounterRotator))),
        'scoreFace': _rectJson(tester.getRect(find.byType(DailyScoreFace))),
        'banditTop': tester.getRect(find.byType(BanditReadingSlot)).top,
        'drawer': _rectJson(
          tester.getRect(find.byKey(const ValueKey('home_drawer_button'))),
        ),
        'gear': _rectJson(
          tester.getRect(find.byKey(const ValueKey('home_settings_gear'))),
        ),
        'vitals': _rectJson(
          tester.getRect(find.byKey(const Key('vitalsStripCompact'))),
        ),
      };
      // ignore: avoid_print
      print('CAPTURED $name ${sidecar[name]}');
    }

    addTearDown(tester.view.reset);

    await pumpHome(physicalSize: const Size(1080, 2400), streak: 32, gems: 415);
    await capture('founder_360', 1080, 2400);

    await pumpHome(physicalSize: const Size(1170, 2532), streak: 32, gems: 415);
    await capture('founder_390', 1170, 2532);

    await pumpHome(
      physicalSize: const Size(1080, 2400),
      streak: 132,
      gems: 10000,
    );
    await capture('stress_360', 1080, 2400);

    await pumpHome(
      physicalSize: const Size(1170, 2532),
      streak: 132,
      gems: 10000,
    );
    await capture('stress_390', 1170, 2532);

    await tester.runAsync(() async {
      await File('${outDir.path}/rects.json')
          .writeAsString(const JsonEncoder.withIndent('  ').convert(sidecar));
    });
    expect(tester.takeException(), isNull);
  });
}

/// The secure-storage mock + cache resets the full-Home harnesses
/// share (mirrors home_band_counters_r5_test's setUp).
void setUpFontsAndMocks() {
  TabsBackend.debugResetSharedCaches();
  HomeDataCache.instance.debugSetStore(
    read: (k) async => null,
    write: (k, v) async {},
    delete: (k) async {},
  );
  HomeDataCache.instance.debugReset();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
        (call) async => call.method == 'readAll' ? <String, String>{} : null,
      );
}
