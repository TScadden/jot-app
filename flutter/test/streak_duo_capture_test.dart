import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/gem_service.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/streak_purchase.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';

/// Streak screen Duo rebuild — visual capture harness (modeled on
/// gems_capture_test.dart). Seeds the mock v3 state: streak 30
/// (counted Oct 23 – Nov 21), best 68, gems 215, 1 purchased freeze
/// held, November's monthly grant used, Nov 10 freeze-covered,
/// Nov 12 grace-completed, today Sun Nov 22 pending.
///
/// Renders the full screen in one tall frame per width (390 and
/// 360 CSS px) and writes PNGs to $STREAK_DUO_CAPTURE_OUT (default
/// ~/workspace/build-streak-screen-duo/captures). Slicing into
/// mock-comparable parts happens outside the harness.
void main() {
  testWidgets('capture the rebuilt streak screen', (tester) async {
    final outDir = Directory(
      Platform.environment['STREAK_DUO_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-streak-screen-duo/captures',
    );
    await tester.runAsync(() => outDir.create(recursive: true));
    final rootKey = GlobalKey();

    // Real glyphs: bundled Nunito (the screen's font) + Roboto +
    // the Material icons font, per the repo capture pattern.
    await tester.runAsync(() async {
      final nunito = FontLoader('Nunito');
      nunito.addFont(rootBundle.load('assets/fonts/Nunito-Variable.ttf'));
      await nunito.load();
      final roboto = FontLoader('Roboto');
      roboto.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      roboto.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await roboto.load();
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

    GemService fakeGems() {
      final disk = <String, String>{};
      final s = GemService(
        grant: (_) async => (statusCode: null, body: null),
        spend: (id) async => (statusCode: null, body: null),
        pullBalance: () async => 215,
      );
      s.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      return s;
    }

    final counted = <String>{};
    var day = DateTime(2026, 10, 23);
    final last = DateTime(2026, 11, 21);
    while (!day.isAfter(last)) {
      counted.add(streakDayStr(day));
      day = day.add(const Duration(days: 1));
    }
    final state = StreakState(
      seeded: true,
      seededCurrent: 30,
      seededBest: 68,
      countedDays: counted,
      restoredDays: const {'2026-11-10'},
      graceCompletedDays: const {'2026-11-12'},
      accrualMonth: '2026-11',
      lastEvaluatedDay: '2026-11-21',
      consumedSaveMonths: const {'2026-11'},
      purchasedFreezes: 1,
    );

    Future<void> capture(int widthCss, String name) async {
      tester.view.physicalSize = Size(widthCss * 2, 2900 * 2);
      tester.view.devicePixelRatio = 2.0;
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          home: RepaintBoundary(
            key: rootKey,
            child: StreakScreen(
              state: state,
              now: DateTime(2026, 11, 22, 12),
              gemService: fakeGems(),
              purchaseService: StreakFreezePurchaseService(
                store: _FakeStore(
                  product: const StreakFreezeProduct(
                    id: StreakFreezePurchaseService.productId,
                    price: '\$0.99',
                  ),
                ),
                verify: ({
                  required productId,
                  required purchaseToken,
                  required orderId,
                }) async => null,
              ),
              streakPush: (c, b, j, {int? purchasedFreezes}) async => true,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.runAsync(() async {
        await precacheImage(
          const AssetImage(GemCopy.iconAsset),
          rootKey.currentContext!,
        );
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final boundary =
          rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      late ui.Image image;
      await tester.runAsync(() async {
        image = await boundary.toImage(pixelRatio: 2.0);
      });
      final bytes = await tester.runAsync<Uint8List>(
        () async =>
            (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer
                .asUint8List(),
      );
      await tester.runAsync(
        () => File('${outDir.path}/$name').writeAsBytes(bytes!),
      );
    }

    await capture(390, 'streak_duo_real_390_full_20261122.png');
    await capture(360, 'streak_duo_real_360_full_20261122.png');
    addTearDown(tester.view.reset);
  });
}

class _FakeStore implements StreakFreezeStore {
  final StreakFreezeProduct? product;
  final StreamController<List<StreakFreezePurchaseUpdate>> _controller =
      StreamController<List<StreakFreezePurchaseUpdate>>.broadcast();

  _FakeStore({required this.product});

  @override
  Future<bool> isAvailable() async => true;

  @override
  Stream<List<StreakFreezePurchaseUpdate>> get purchaseUpdates =>
      _controller.stream;

  @override
  Future<StreakFreezeProduct?> queryProduct(String productId) async => product;

  @override
  Future<bool> buyConsumable(StreakFreezeProduct product) async => true;

  @override
  Future<void> completePurchase(StreakFreezePurchaseUpdate update) async {}

  @override
  Future<void> restorePurchases() async {}
}
