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
import 'package:tabs_lab/src/features/home/vitals_strip.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Gems — visual capture harness (modeled on
/// home_redesign_capture_test.dart). Frames @ DPR 3.0, 360dp wide:
/// - streak_gem_section_360: the Streak Freeze card's gem-buy
///   section (balance line, disabled buy button, §2d line, and the
///   Juno §4 explainer) at a 35-gem balance.
/// - home_gem_pill_360: the Home streak stack with the gem pill
///   under the two streak pills at a 1000-gem balance (widening).
///
/// Output dir: $GEM_CAPTURE_OUT, default
/// ~/workspace/build-gems/captures.
void main() {
  testWidgets('capture the gems frames', (tester) async {
    final outDir = Directory(
      Platform.environment['GEM_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-gems/captures',
    );
    // Real IO must run inside runAsync: awaiting a real Future in
    // the fake-async test body deadlocks the harness (this hung
    // the first two capture attempts at minute zero).
    await tester.runAsync(() => outDir.create(recursive: true));
    final rootKey = GlobalKey();

    // Legible text + a decoded gem icon (repo capture-harness
    // pattern): load the bundled Roboto faces and the Material
    // icons font, so the frames show real glyphs, not test-font
    // blocks; the icon is precached per frame before capture.
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

    Future<void> precacheGemIcon() async {
      await tester.runAsync(() async {
        await precacheImage(
          const AssetImage(GemCopy.iconAsset),
          rootKey.currentContext!,
        );
      });
      await tester.pump();
    }

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

    GemService fakeGems(int balance) {
      final disk = <String, String>{};
      final s = GemService(
        grant: (_) async => (statusCode: null, body: null),
        spend: (_) async => (statusCode: null, body: null),
        pullBalance: () async => balance,
      );
      s.debugSetStore(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        delete: (k) async => disk.remove(k),
      );
      return s;
    }

    // FRAME 1 — streak screen gem section.
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    final state = streakSeedForAdoption(
      current: 5,
      best: 12,
      now: DateTime(2026, 11, 19, 12),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          // Animations frozen (the repo capture-harness pattern):
          // the flame's repeating ticker otherwise keeps the
          // boundary perpetually dirty and toImage never lands.
          home: TickerMode(
            enabled: false,
            child: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: StreakScreen(
                state: state,
                now: DateTime(2026, 11, 19, 12),
                gemService: fakeGems(35),
                streakPush: (current, best, json,
                        {int? purchasedFreezes}) async =>
                    true,
                purchaseService: StreakFreezePurchaseService(
                  store: _FakePurchaseStore(),
                  verify: (
                      {required productId,
                      required purchaseToken,
                      required orderId}) async =>
                      null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // Let the server balance land in the service, then scroll
    // the section into the built region (the ListView builds it
    // lazily) and anchor the frame on the section top so the
    // whole gem section + explainer is in frame.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.scrollUntilVisible(
      find.byKey(const Key('gemExplainerLine4')),
      120,
    );
    await tester.pump();
    await tester.scrollUntilVisible(
      find.byKey(const Key('gemBalanceLine')),
      120,
    );
    await tester.pump();
    expect(find.byKey(const Key('gemBalanceLine')), findsOneWidget);
    expect(find.byKey(const Key('gemBuySection')), findsOneWidget);
    expect(find.byKey(const Key('gemExplainerLine4')), findsOneWidget);
    await capture('streak_gem_section_360');

    // FRAME 2 — Home streak stack with the gem pill (1000).
    await tester.pumpWidget(
      RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: Scaffold(
            backgroundColor: NotelColors.background,
            body: Padding(
              padding: EdgeInsets.fromLTRB(0, 12, 0, 0),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 200,
                  child: HomeStreakStack(
                    currentStreak: 18,
                    bestStreak: 68,
                    animateCountUps: false,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    gemBalance: 1000,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const Key('homeGemPill')), findsOneWidget);
    await precacheGemIcon();
    await capture('home_gem_pill_360');
  });
}

class _FakePurchaseStore implements StreakFreezeStore {
  @override
  Future<bool> isAvailable() async => false;
  @override
  Stream<List<StreakFreezePurchaseUpdate>> get purchaseUpdates =>
      const Stream.empty();
  @override
  Future<StreakFreezeProduct?> queryProduct(String productId) async => null;
  @override
  Future<bool> buyConsumable(StreakFreezeProduct product) async => false;
  @override
  Future<void> completePurchase(StreakFreezePurchaseUpdate update) async {}
  @override
  Future<void> restorePurchases() async {}
}
