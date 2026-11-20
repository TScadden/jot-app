import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/data/badge_store.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/weather_api.dart';
import 'package:tabs_lab/src/features/badges/badges_screen.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';

/// Badges — visual capture harness (modeled on
/// gems_capture_test.dart). Frames @ DPR 3.0, 360dp wide:
/// - badges_screen_360: the collection screen with a mixed
///   earned/in-progress state (Diamond III top badge).
/// - badge_detail_360: the Total logs detail view + ladder.
/// - home_drawer_360: the Home drawer with Badges appended last.
///
/// Output dir: $BADGE_CAPTURE_OUT, default
/// ~/workspace/build-badges/captures.
void main() {
  testWidgets('capture the badges frames', (tester) async {
    final outDir = Directory(
      Platform.environment['BADGE_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-badges/captures',
    );
    await tester.runAsync(() => outDir.create(recursive: true));
    final rootKey = GlobalKey();

    // Real glyphs, not test-font blocks (repo capture pattern).
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      final iconsFile = File(
        '${Platform.environment['HOME']}/workspace/flutter-sdk/bin/cache/'
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

    Future<void> capture(String name) async {
      final boundary = rootKey.currentContext!.findRenderObject()!
          as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    // A rich, real-shaped badge state.
    final disk = <String, String>{};
    final svc = BadgeService(
      grant: (_) async => (
        statusCode: 200,
        body: {'gemBalance': 500, 'alreadyGranted': false},
      ),
    );
    svc.debugSetStore(
      read: (k) async => disk[k],
      write: (k, v) async => disk[k] = v,
      delete: (k) async => disk.remove(k),
    );
    BadgeSleepSession night(int startDay) => (
          startMs: DateTime(2026, 10, startDay, 21, 30)
              .millisecondsSinceEpoch,
          endMs: DateTime(2026, 10, startDay + 1, 6, 30)
              .millisecondsSinceEpoch,
          asleepMinutes: 430,
        );
    await svc.evaluate(
      inputs: BadgeInputs(
        logTimestampsMs: [
          for (var d = 0; d < 100; d++)
            for (var i = 0; i < 5; i++)
              DateTime(2026, 8, 1, 12)
                  .add(Duration(days: d, minutes: i))
                  .millisecondsSinceEpoch,
        ],
        streakState: StreakState(
          seeded: true,
          seededBest: 68,
          summaryCompletedDays: {
            for (var d = 2; d <= 8; d++) '2026-11-0$d',
          },
          restoredDays: {'2026-10-03', '2026-11-14'},
        ),
        dailyTotalCalories: {'2026-10-05': 100000},
        dailySteps: {'2026-11-10': 20000},
        exerciseSessions: [
          (
            startMs: DateTime(2026, 11, 2, 7).millisecondsSinceEpoch,
            endMs: DateTime(2026, 11, 2, 12).millisecondsSinceEpoch,
          ),
        ],
        sleepSessions: [for (var d = 1; d <= 30; d++) night(d)],
      ),
      blockedMetrics: const {},
      now: DateTime(2026, 11, 20, 12),
    );

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    Widget frame(Widget child) => RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'Roboto'),
            home: TickerMode(
              enabled: false,
              child: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: child,
              ),
            ),
          ),
        );

    // FRAME 1 — the collection screen.
    await tester.pumpWidget(frame(BadgesScreen(
      service: svc,
      onOpenHcSettings: () async {},
    )));
    await tester.pump();
    await capture('badges_screen_360');

    // FRAME 2 — the Total logs detail view.
    await tester.pumpWidget(frame(BadgeDetailScreen(
      metric: BadgeMetrics.totalLogs,
      service: svc,
      onOpenHcSettings: () async {},
    )));
    await tester.pump();
    await capture('badge_detail_360');

    // FRAME 3 — the Home drawer, Badges appended last.
    final weather = WeatherApiClient(
      client: MockClient((request) async {
        if (request.url.host == 'ipinfo.io') {
          return http.Response(
              '{"city":"Orem","loc":"40.2969,-111.6946","country":"US"}',
              200);
        }
        return http.Response('not found', 404);
      }),
    );
    await tester.pumpWidget(frame(HomeScreen(weatherApi: weather)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byKey(const ValueKey('home_drawer_button')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await capture('home_drawer_360');
    await tester.pump(const Duration(milliseconds: 700));
  });
}
