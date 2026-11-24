import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/badge_engine.dart';
import 'package:tabs_lab/src/features/badges/badge_share_card.dart';

/// Badge share card — visual capture harness (modeled on
/// badges_capture_test.dart). Renders two earned-state share
/// cards at full 1080×1080:
/// - badge_share_capture_day_streak_7 (Day streak, Gold II)
/// - badge_share_capture_calories_month_5 (Monthly calories,
///   Silver I)
///
/// Output dir: $BADGE_SHARE_CAPTURE_OUT, default
/// ~/workspace/build-badge-share/captures.
void main() {
  testWidgets('capture the badge share cards', (tester) async {
    final outDir = Directory(
      Platform.environment['BADGE_SHARE_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-badge-share/captures',
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
        final ui.Image image = await boundary.toImage(pixelRatio: 1.0);
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    tester.view.physicalSize = const Size(1080, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    Widget frame(BadgeMetric metric, int rungIndex) => RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData(fontFamily: 'Roboto'),
            home: TickerMode(
              enabled: false,
              child: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: Scaffold(
                  body: BadgeShareCard(metric: metric, rungIndex: rungIndex),
                ),
              ),
            ),
          ),
        );

    await tester.pumpWidget(frame(BadgeMetrics.dayStreak, 7));
    await tester.pump();
    await capture('badge_share_capture_day_streak_7');

    await tester.pumpWidget(frame(BadgeMetrics.caloriesMonth, 5));
    await tester.pump();
    await capture('badge_share_capture_calories_month_5');
  });
}
