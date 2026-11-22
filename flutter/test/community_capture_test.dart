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
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/community_screen.dart';

import 'test_helpers.dart';

/// Community revamp (Option A) — visual capture harness (modeled
/// on gems_capture_test.dart). Frames @ DPR 3.0, 360dp wide:
/// - community_360: the Community screen with the mock's sample
///   friends (Boston / Dad / Mom / Addy) and the self row on the
///   leaderboard (You #48210, streak 27, gems 145, 320 pts).
/// - community_detail_sharing_off_360: the friend detail dialog
///   for a sharing-off friend — game cards visible, health stats
///   behind the health-qualified lock copy.
///
/// Output dir: $COMMUNITY_CAPTURE_OUT, default
/// ~/workspace/build-community/captures.
void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  testWidgets('capture the community frames', (tester) async {
    final outDir = Directory(
      Platform.environment['COMMUNITY_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-community/captures',
    );
    await tester.runAsync(() => outDir.create(recursive: true));
    final rootKey = GlobalKey();

    // Legible text + real glyphs (repo capture-harness pattern):
    // load the bundled Roboto faces and the Material icons font so
    // the flame icon renders as a flame, not a placeholder box.
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
      final boundary =
          rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 3.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    TabsBackend backend() {
      final store = FakeSessionStore()..token = 'tok';
      return TabsBackend(
        sessionStore: store,
        client: MockClient((request) async {
          switch (request.url.path) {
            case '/api/friends/list':
              return http.Response(
                jsonEncode({
                  'success': true,
                  'friends': [
                    {
                      'id': 'f-boston',
                      'nickname': 'Boston',
                      'tag': '91304',
                      'status': '',
                      'level': 285,
                      'gemBalance': 210,
                      'currentStreak': 31,
                    },
                    {
                      'id': 'f-dad',
                      'nickname': 'Dad',
                      'tag': '20517',
                      'status': '',
                      'level': 190,
                      'gemBalance': 85,
                      'currentStreak': 12,
                    },
                    {
                      'id': 'f-mom',
                      'nickname': 'Mom',
                      'tag': '73062',
                      'status': '',
                      'level': 240,
                      'gemBalance': 120,
                      'currentStreak': 18,
                    },
                    {
                      'id': 'f-addy',
                      'nickname': 'Addy',
                      'tag': '55198',
                      'status': '',
                      'level': 150,
                      'gemBalance': 40,
                      'currentStreak': 6,
                    },
                  ],
                }),
                200,
              );
            case '/api/friends/notifications':
              return http.Response(
                jsonEncode({'success': true, 'notifications': []}),
                200,
              );
            case '/api/sync/pull':
              return http.Response(
                jsonEncode({
                  'isUnlimited': true,
                  'nickname': 'You',
                  'tag': '48210',
                  'profile': {
                    'weeklyScore': 320,
                    'currentStreak': 27,
                    'gem_balance': 145,
                  },
                }),
                200,
              );
            case '/api/friends/data/f-addy':
              return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {
                    'friendId': 'f-addy',
                    'nickname': 'Addy',
                    'tag': '55198',
                    'sharingEnabled': false,
                    'gemBalance': 40,
                    'currentStreak': 6,
                  },
                }),
                200,
              );
          }
          return http.Response('{}', 404);
        }),
      );
    }

    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      RepaintBoundary(
        key: rootKey,
        child: MaterialApp(
          theme: ThemeData(fontFamily: 'Roboto'),
          home: TickerMode(
            enabled: false,
            child: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: CommunityToolScreen(backend: backend()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await precacheGemIcon();
    await capture('community_360');

    // FRAME 2 — detail dialog, sharing off.
    await tester.tap(find.text('Addy').first);
    await tester.pumpAndSettle();
    await precacheGemIcon();
    await capture('community_detail_sharing_off_360');
  });
}
