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
import 'package:tabs_lab/src/features/home/today_summary_card.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/shell/tablet_content_shell.dart';
import 'package:tabs_lab/src/features/tools/tools_screen.dart';
import 'package:tabs_lab/src/theme/notel_theme.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Tablet width adaptation — Phase 1 before/after capture harness.
///
/// Run on the BASE head with TABLET_CAPTURE_VARIANT=before for the
/// "before" frames (old grid code, no shell) and on the prototype
/// branch with TABLET_CAPTURE_VARIANT=after for the "after" frames
/// (the variant flag adds the TabletContentShell wrapper; the grid
/// counts come from whichever lib code is checked out).
///
/// Frames: Home, Tools, Badges, Settings, Log (Quick Log), Summary
/// (Today Summary card) at 820x1180 and 1180x820, plus Home + Tools
/// at 390x844 (phone regression frame). DPR 1.0 throughout.
/// Output dir: $TABLET_CAPTURE_OUT.
void main() {
  testWidgets('capture tablet adaptation frames', (tester) async {
    final variant =
        Platform.environment['TABLET_CAPTURE_VARIANT'] ?? 'after';
    final outDir = Directory(
      Platform.environment['TABLET_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-tablet-adaptation/renders',
    );
    await tester.runAsync(() => outDir.create(recursive: true));
    final rootKey = GlobalKey();

    // Real glyphs, not test-font blocks (repo capture pattern).
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      final nunito = FontLoader('Nunito');
      nunito.addFont(rootBundle.load('assets/fonts/Nunito-Variable.ttf'));
      await nunito.load();
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
        final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    Widget frame(Widget child) => RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: notelDarkTheme(),
            home: TickerMode(
              enabled: false,
              child: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: variant == 'after'
                    ? TabletContentShell(child: child)
                    : child,
              ),
            ),
          ),
        );

    Future<void> shoot(String surface, Size size, Widget child) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(frame(child));
      // Bounded pumps only: several surfaces arm real async work;
      // pumpAndSettle can hang on it. Layout is final after these.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      final tag = '${size.width.toInt()}x${size.height.toInt()}';
      await capture('${surface}_${tag}_$variant');
      tester.takeException();
    }

    // ── Fixtures ────────────────────────────────────────────────
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

    final toolStore = ToolOrderStore();
    final toolMap = <String, String>{};
    toolStore.debugSetIO(
      read: (k) async => toolMap[k],
      write: (k, v) async => toolMap[k] = v,
    );

    final badgeDisk = <String, String>{};
    final badgeSvc = BadgeService(
      grant: (_) async => (
        statusCode: 200,
        body: {'gemBalance': 500, 'alreadyGranted': false},
      ),
    );
    badgeSvc.debugSetStore(
      read: (k) async => badgeDisk[k],
      write: (k, v) async => badgeDisk[k] = v,
      delete: (k) async => badgeDisk.remove(k),
    );
    BadgeSleepSession night(int startDay) => (
          startMs: DateTime(2026, 10, startDay, 21, 30)
              .millisecondsSinceEpoch,
          endMs: DateTime(2026, 10, startDay + 1, 6, 30)
              .millisecondsSinceEpoch,
          asleepMinutes: 430,
        );
    await badgeSvc.evaluate(
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

    final settingsBackend = r29.FakeSettingsBackend()
      ..pullBody = r29.pull(profile: {'avatarId': 'avatar_03'});

    const tabletSizes = [Size(820, 1180), Size(1180, 820)];
    var frameNo = 0;
    for (final size in tabletSizes) {
      frameNo++;
      await shoot('home', size, HomeScreen(weatherApi: weather));
      await shoot(
          'tools', size, ToolsScreen(orderStore: toolStore));
      await shoot(
          'badges',
          size,
          BadgesScreen(service: badgeSvc, onOpenHcSettings: () async {}));
      await shoot(
          'settings',
          size,
          SettingsScreen(
            key: ValueKey('settings_tablet_$frameNo'),
            backend: settingsBackend,
            settingsStore: r29.fakeStore({}),
            notificationService: FakeReminderNotificationService(),
            urlLauncher: (uri) async => true,
          ));
      await shoot('log', size, const QuickLogScreen());
      await shoot(
          'summary',
          size,
          const Scaffold(
            body: SingleChildScrollView(child: TodaySummaryCard()),
          ));
    }

    // Phone regression frames (after must read identical to before).
    await shoot(
        'home', const Size(390, 844), HomeScreen(weatherApi: weather));
    await shoot(
        'tools', const Size(390, 844), ToolsScreen(orderStore: toolStore));
  });
}
