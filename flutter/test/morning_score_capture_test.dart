import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_data.dart'
    show buildMorningScoreMetric, sevenDayWindow;
import 'package:tabs_lab/src/data/weekly_snapshot.dart';
import 'package:tabs_lab/src/data/weekly_snapshot_cache.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Capture harness for the Morning Score graph option (Nov 4, 2026).
/// NOT a behavior test — it renders the Weekly Snapshot card at
/// 1080x2400 with seeded Morning Score weeks (through the real
/// builder) and writes PNGs for the delivery record:
///
/// - `tabs_weekly_morningscore_graph_v1_full.png` — all 7 days
///   scored (3,4,2,5,4,3,4), Morning Score selected.
/// - `tabs_weekly_morningscore_graph_v1_sparse.png` — only 2 of 7
///   days scored; the rest are gaps (no line, no zeros).
/// - `tabs_weekly_morningscore_graph_v1_options.png` — the metric
///   dropdown open, showing Morning Score as the eighth option.
///
/// Output directory: $MORNING_CAPTURE_OUT, falling back to
/// ~/workspace/tiktok-ui-lab when it exists, else the system temp.
void main() {
  testWidgets('capture Morning Score frames at 1080x2400', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final outDirPath = Platform.environment['MORNING_CAPTURE_OUT'] ??
        (() {
          final home = Platform.environment['HOME'] ?? '/home/hatch';
          final lab = Directory('$home/workspace/tiktok-ui-lab');
          return lab.existsSync() ? lab.path : Directory.systemTemp.path;
        })();
    final outDir = Directory(outDirPath);
    // createSync, NOT await create(): a real-IO await in the
    // fake-async test zone deadlocks (harness lesson, Nov 3).
    outDir.createSync(recursive: true);

    // Real fonts before any layout (the blackglass harness pattern):
    // without them the test font's wide glyphs overflow the card's
    // fixed rows and the frames would not show production metrics.
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

    Future<WeeklySnapshotMetricData> Function(SnapshotMetric) loader(
      Map<int, int> byWindowIndex,
    ) {
      return (metric) async {
        if (metric != SnapshotMetric.morningScore) {
          return emptyMetricData(metric);
        }
        final window = sevenDayWindow();
        final byDay = <String, int>{
          for (final e in byWindowIndex.entries)
            window[e.key].dateStr: e.value,
        };
        return buildMorningScoreMetric(
          [for (final w in window) w.dateStr],
          [for (final w in window) w.dayLabel],
          byDay,
        );
      };
    }

    Future<void> pumpCard(Map<int, int> seed) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
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
              child: Scaffold(
                backgroundColor: NotelColors.background,
                body: Column(
                  children: [
                    const SizedBox(height: 24),
                    WeeklySnapshotCard(
                      loadData: loader(seed),
                      cache: WeeklySnapshotCache.testInstance(),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> selectMorningScore() async {
      await tester.tap(find.byIcon(Icons.arrow_drop_down));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Morning Score').last);
      await tester.pumpAndSettle();
    }

    Future<void> capture(String name) async {
      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
        if (image.width != 1080 || image.height != 2400) {
          throw StateError(
            'capture size ${image.width}x${image.height}, want 1080x2400',
          );
        }
        final byteData =
            await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '${outDir.path}/$name',
        ).writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    // Frame 1 — a full week of morning scores.
    await pumpCard(const {0: 3, 1: 4, 2: 2, 3: 5, 4: 4, 5: 3, 6: 4});
    await selectMorningScore();
    expect(find.text('7-Day Avg: 3.6 / 5'), findsOneWidget);
    await capture('tabs_weekly_morningscore_graph_v1_full.png');

    // Frame 2 — a sparse week: two scored days, five gaps.
    await pumpCard(const {1: 2, 5: 5});
    await selectMorningScore();
    expect(find.text('7-Day Avg: 3.5 / 5'), findsOneWidget);
    await capture('tabs_weekly_morningscore_graph_v1_sparse.png');

    // Frame 3 — the options dropdown open on the full week.
    await pumpCard(const {0: 3, 1: 4, 2: 2, 3: 5, 4: 4, 5: 3, 6: 4});
    await tester.tap(find.byIcon(Icons.arrow_drop_down));
    await tester.pumpAndSettle();
    expect(find.text('Morning Score'), findsWidgets);
    await capture('tabs_weekly_morningscore_graph_v1_options.png');
  });
}
