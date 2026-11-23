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
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/tools/community_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Profile picture picker (Nov 23, 2026) — visual capture harness
/// (modeled on badges_capture_test.dart / community_capture_test).
/// Frames at 390 AND 360 CSS px wide (DPR 2.0):
/// - settings_profile_{390,360}: the Settings profile card with a
///   picked avatar (Gold Bandit) + the Edit Profile Picture button.
/// - avatar_picker_{390,360}: the open picker grid (Gold Bandit
///   marked current).
/// - community_friend_{390,360}: a Community friend row showing a
///   picked icon (Boston = Flame) next to a fallback row (Dad).
/// - streak_friend_{390,360}: the Streak Friends tab with a picked
///   icon (Boston = Moon) next to a fallback row (Dad).
///
/// Output dir: $AVATAR_CAPTURE_OUT, default
/// ~/workspace/build-avatar-picker/captures.
void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  testWidgets('capture the avatar picker frames', (tester) async {
    final outDir = Directory(
      Platform.environment['AVATAR_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-avatar-picker/captures',
    );
    await tester.runAsync(() => outDir.create(recursive: true));
    final rootKey = GlobalKey();

    // Real glyphs, not test-font blocks (repo capture pattern).
    await tester.runAsync(() async {
      final loader = FontLoader('Roboto');
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      loader.addFont(rootBundle.load('assets/fonts/Roboto-Bold.ttf'));
      await loader.load();
      // The Streak screen's font (streak_duo_capture_test pattern):
      // without it every Streak glyph renders as a placeholder box.
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
      final boundary =
          rootKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
        final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('${outDir.path}/$name.png')
            .writeAsBytes(byteData!.buffer.asUint8List());
      });
    }

    Future<void> precacheAvatars() async {
      await tester.runAsync(() async {
        // ALL 15 picker assets: an unprecached cell paints empty
        // in the capture even though the widget tree is correct
        // (asset decode is real async work pumpAndSettle does not
        // wait for).
        for (var i = 1; i <= 15; i++) {
          final n = i.toString().padLeft(2, '0');
          await precacheImage(
            AssetImage('assets/images/avatar_$n.png'),
            rootKey.currentContext!,
          );
        }
        await precacheImage(
            AssetImage(GemCopy.iconAsset), rootKey.currentContext!);
      });
      await tester.pump();
    }

    /// The Settings menu rows build only after the screen's async
    /// load lands; pumpAndSettle alone raced it once (menu key
    /// absent at tap time). Pump in bounded steps until the key
    /// exists, then make sure it is on screen before tapping.
    Future<void> tapMenuProfile() async {
      final finder = find.byKey(const ValueKey('menu_user_profile'));
      for (var i = 0; i < 50 && finder.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(finder, findsOneWidget);
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
      // The Settings pages share one scrollable: ensureVisible
      // scrolled the MENU list, and that offset carries onto the
      // profile page, hiding its first card. Reset to the top so
      // the profile card (avatar + button) is in frame.
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
    }

    void setSize(double width, double height) {
      tester.view.physicalSize = Size(width * 2, height * 2);
      tester.view.devicePixelRatio = 2.0;
    }

    addTearDown(tester.view.reset);

    // ── Settings card + picker ──────────────────────────────────
    final backend = r29.FakeSettingsBackend()
      ..pullBody = r29.pull(profile: {'avatarId': 'avatar_03'});

    for (final width in [390.0, 360.0]) {
      final tag = width.toInt();
      setSize(width, 844);
      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'Roboto'),
            home: Scaffold(
              body: SettingsScreen(
                // Unique key per frame size: without it the second
                // pump reuses the first screen's State (same widget
                // type/position) and reopens on the profile page
                // instead of the menu.
                key: ValueKey('settings_$tag'),
                backend: backend,
                settingsStore: r29.fakeStore({}),
                notificationService: FakeReminderNotificationService(),
                urlLauncher: (uri) async => true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tapMenuProfile();
      await precacheAvatars();
      await capture('settings_profile_$tag');

      await tester
          .tap(find.byKey(const ValueKey('edit_profile_picture_button')));
      await tester.pumpAndSettle();
      await precacheAvatars();
      await capture('avatar_picker_$tag');
      // Close the picker before the next frame size.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    }

    // ── Community friend row ────────────────────────────────────
    TabsBackend communityBackend() {
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
                      'avatarId': 'avatar_07',
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
                  ],
                }),
                200,
              );
            case '/api/friends/notifications':
              return http.Response(
                  jsonEncode({'success': true, 'notifications': []}), 200);
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
          }
          return http.Response('{}', 404);
        }),
      );
    }

    for (final width in [390.0, 360.0]) {
      final tag = width.toInt();
      setSize(width, 844);
      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'Roboto'),
            home: TickerMode(
              enabled: false,
              child: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: CommunityToolScreen(
                  key: ValueKey('community_$tag'),
                  backend: communityBackend(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await precacheAvatars();
      await capture('community_friend_$tag');
    }

    // ── Streak friends tab ──────────────────────────────────────
    var s = streakSeed(current: 5, best: 12, now: DateTime(2026, 11, 1, 12));
    s = streakEvaluate(s, DateTime(2026, 11, 3, 12));
    s = streakEvaluate(s, DateTime(2026, 11, 4, 12));

    for (final width in [390.0, 360.0]) {
      final tag = width.toInt();
      setSize(width, 844);
      await tester.pumpWidget(
        RepaintBoundary(
          key: rootKey,
          child: MaterialApp(
            theme: ThemeData(fontFamily: 'Roboto'),
            home: TickerMode(
              enabled: false,
              child: MediaQuery(
                data: const MediaQueryData(disableAnimations: true),
                child: StreakScreen(
                  key: ValueKey('streak_$tag'),
                  state: s,
                  now: DateTime(2026, 11, 4, 12),
                  initialFriends: const [
                    FriendDto(
                      id: 'f-boston',
                      nickname: 'Boston',
                      tag: '91304',
                      status: '',
                      level: 285,
                      gemBalance: 210,
                      currentStreak: 31,
                      avatarId: 'avatar_09',
                    ),
                    FriendDto(
                      id: 'f-dad',
                      nickname: 'Dad',
                      tag: '20517',
                      status: '',
                      level: 190,
                      gemBalance: 85,
                      currentStreak: 12,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('streakTabFriends')));
      await tester.pumpAndSettle();
      await precacheAvatars();
      await capture('streak_friend_$tag');
    }
  });
}
