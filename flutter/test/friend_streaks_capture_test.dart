import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/friend_streak_invite_screen.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';

/// Friend Streaks — visual capture harness (modeled on
/// streak_duo_capture_test.dart). Renders the three mock v3 states
/// at 390 CSS px wide for eyeball comparison against
/// ~/workspace/friend-streak-mock/friend_streak_mock_v3_part{1,2,3}:
/// - friend_streaks_empty_390: FRIENDS tab, empty state (part 1)
/// - friend_streaks_picker_390: invite picker (part 2)
/// - friend_streaks_populated_390: incoming + active pair (part 3)
///
/// Output dir: $FRIEND_STREAKS_CAPTURE_OUT, default
/// ~/workspace/build-friend-streaks/captures.
void main() {
  testWidgets('capture the three friend streak states', (tester) async {
    final outDir = Directory(
      Platform.environment['FRIEND_STREAKS_CAPTURE_OUT'] ??
          '${Platform.environment['HOME']}/workspace/build-friend-streaks/captures',
    );
    await tester.runAsync(() => outDir.create(recursive: true));
    final rootKey = GlobalKey();

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

    Future<void> capture(String name) async {
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

    void frame(int heightCss) {
      tester.view.physicalSize = Size(390 * 2, heightCss * 2);
      tester.view.devicePixelRatio = 2.0;
    }

    final state = streakSeed(
      current: 5,
      best: 12,
      now: DateTime(2026, 11, 23, 12),
    );
    final now = DateTime(2026, 11, 23, 12);

    // Part 1 — empty state.
    frame(700);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: rootKey,
          child: StreakScreen(
            state: state,
            now: now,
            nickname: 'Tyson',
            initialFriendStreaks: FriendStreaksDto.empty,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('streakTabFriends')));
    await tester.pump();
    await capture('friend_streaks_empty_390_20261123.png');

    // Part 3 — populated: incoming jeffscadden + active Boston (5,
    // both finished), mirroring the mock's sample rows.
    frame(700);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: rootKey,
          child: StreakScreen(
            state: state,
            now: now,
            nickname: 'Tyson',
            initialFriendStreaks: const FriendStreaksDto(
              incoming: [
                FriendStreakIncomingDto(
                  pairId: 'pair-in-1',
                  partner: FriendStreakPartnerDto(
                    userId: 'u-jeff',
                    nickname: 'jeffscadden',
                    tag: '71298',
                  ),
                ),
              ],
              pairs: [
                FriendStreakPairDto(
                  pairId: 'pair-boston',
                  partner: FriendStreakPartnerDto(
                    userId: 'u-boston',
                    nickname: 'Boston Scadden',
                    tag: '67676',
                  ),
                  status: 'active',
                  count: 5,
                  best: 5,
                  viewerFinishedToday: true,
                  partnerFinishedToday: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('streakTabFriends')));
    await tester.pump();
    await capture('friend_streaks_populated_390_20261123.png');

    // Part 2 — picker: Boston invitable, jeffscadden pending.
    frame(560);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: RepaintBoundary(
          key: rootKey,
          child: FriendStreakInviteScreen(
            now: now,
            initialFriends: const [
              FriendDto(
                id: 'f-boston',
                nickname: 'Boston Scadden',
                tag: '67676',
                status: '',
                level: 0,
              ),
              FriendDto(
                id: 'f-jeff',
                nickname: 'jeffscadden',
                tag: '71298',
                status: '',
                level: 0,
              ),
            ],
            initialOutgoingPending: const {'f-jeff'},
          ),
        ),
      ),
    );
    await tester.pump();
    await capture('friend_streaks_picker_390_20261123.png');

    addTearDown(tester.view.reset);
  });
}
