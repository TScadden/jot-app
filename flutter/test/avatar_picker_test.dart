import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';
import 'package:tabs_lab/src/features/settings/settings_profile.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/features/tools/community_screen.dart';
import 'package:tabs_lab/src/widgets/user_avatar.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Profile picture picker (Nov 23, 2026) — catalog completeness,
/// the shared UserAvatar widget's image-vs-fallback contract, the
/// tolerant avatarId parses (FriendDto + SettingsProfileData), and
/// the Settings card + picker save flow against the Round 29 fake
/// backend seam.
void main() {
  group('avatar catalog', () {
    test('exactly 15 options, ids avatar_01..avatar_15 in sheet order', () {
      expect(kAvatarCatalog, hasLength(15));
      for (var i = 0; i < 15; i++) {
        final n = (i + 1).toString().padLeft(2, '0');
        expect(kAvatarCatalog[i].id, 'avatar_$n');
        expect(kAvatarCatalog[i].asset, 'assets/images/avatar_$n.png');
      }
    });

    test('display names match the approved sheet names', () {
      expect(kAvatarCatalog.map((o) => o.name).toList(), [
        'Classic Bandit',
        'Teal Bandit',
        'Gold Bandit',
        // Juno ruling (Nov 23, 2026): the art is pink/magenta,
        // not red — Rose Bandit (id avatar_04 unchanged).
        'Rose Bandit',
        'Emerald Bandit',
        'Pink Bandit',
        'Flame',
        'Gem',
        'Moon',
        'Orb',
        'Prism',
        'Waves',
        'Sunset',
        'Heart',
        'Snowflake',
      ]);
    });

    test('every catalog asset file exists in the bundle sources', () {
      for (final option in kAvatarCatalog) {
        expect(
          File(option.asset).existsSync(),
          isTrue,
          reason: '${option.asset} missing',
        );
      }
    });

    test('avatarOptionForId resolves only known ids', () {
      expect(avatarOptionForId('avatar_01')?.name, 'Classic Bandit');
      expect(avatarOptionForId('avatar_15')?.name, 'Snowflake');
      expect(avatarOptionForId(null), isNull);
      expect(avatarOptionForId(''), isNull);
      expect(avatarOptionForId('avatar_99'), isNull);
      expect(avatarOptionForId('avatar_1'), isNull);
      expect(isKnownAvatarId('avatar_07'), isTrue);
      expect(isKnownAvatarId('nope'), isFalse);
    });
  });

  group('UserAvatar', () {
    Future<void> pumpAvatar(WidgetTester tester, String? id) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UserAvatar(
              avatarId: id,
              size: 40,
              fallback: const Text('FALLBACK'),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('valid id renders the catalog image, not the fallback', (
      tester,
    ) async {
      await pumpAvatar(tester, 'avatar_07');
      final image = tester.widget<Image>(find.byType(Image));
      expect(
        (image.image as AssetImage).assetName,
        'assets/images/avatar_07.png',
      );
      expect(find.text('FALLBACK'), findsNothing);
    });

    testWidgets('null id renders the fallback untouched', (tester) async {
      await pumpAvatar(tester, null);
      expect(find.text('FALLBACK'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('unknown id renders the fallback untouched', (tester) async {
      await pumpAvatar(tester, 'avatar_99');
      expect(find.text('FALLBACK'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('empty id renders the fallback untouched', (tester) async {
      await pumpAvatar(tester, '');
      expect(find.text('FALLBACK'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('FriendDto avatarId parse', () {
    Map<String, dynamic> row(Map<String, dynamic> extra) => {
      'id': 'f1',
      'nickname': 'Boston',
      'tag': '91304',
      'status': '',
      'level': 10,
      ...extra,
    };

    test('string avatarId is carried', () {
      expect(
        FriendDto.fromJson(row({'avatarId': 'avatar_03'})).avatarId,
        'avatar_03',
      );
    });

    test('absent avatarId parses to null', () {
      expect(FriendDto.fromJson(row({})).avatarId, isNull);
    });

    test('non-string avatarId parses to null', () {
      expect(FriendDto.fromJson(row({'avatarId': 42})).avatarId, isNull);
      expect(FriendDto.fromJson(row({'avatarId': true})).avatarId, isNull);
    });

    test('empty / blank avatarId parses to null', () {
      expect(FriendDto.fromJson(row({'avatarId': ''})).avatarId, isNull);
      expect(FriendDto.fromJson(row({'avatarId': '  '})).avatarId, isNull);
    });

    test('copyWith preserves and overrides avatarId', () {
      final dto = FriendDto.fromJson(row({'avatarId': 'avatar_03'}));
      expect(dto.copyWith(gemBalance: 5).avatarId, 'avatar_03');
      expect(dto.copyWith(avatarId: 'avatar_09').avatarId, 'avatar_09');
    });
  });

  group('SettingsProfileData avatarId parse', () {
    test('reads avatarId from the pull profile map', () {
      final data = SettingsProfileData.fromPull({
        'nickname': 'Tyson',
        'tag': '1234',
        'profile': {'avatarId': 'avatar_05'},
      });
      expect(data.avatarId, 'avatar_05');
    });

    test('absent avatarId defaults to empty (no picture)', () {
      final data = SettingsProfileData.fromPull({
        'nickname': 'Tyson',
        'tag': '1234',
        'profile': <String, dynamic>{},
      });
      expect(data.avatarId, '');
      expect(const SettingsProfileData().avatarId, '');
    });

    test('non-string avatarId defaults to empty', () {
      final data = SettingsProfileData.fromPull({
        'profile': {'avatarId': 42},
      });
      expect(data.avatarId, '');
    });

    test('copyWith carries and overrides avatarId', () {
      const data = SettingsProfileData(avatarId: 'avatar_02');
      expect(data.copyWith(nickname: 'X').avatarId, 'avatar_02');
      expect(data.copyWith(avatarId: 'avatar_11').avatarId, 'avatar_11');
    });
  });

  group('Settings profile card + avatar picker', () {
    Future<void> pumpProfile(
      WidgetTester tester, {
      required r29.FakeSettingsBackend backend,
    }) async {
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(
              backend: backend,
              settingsStore: r29.fakeStore({}),
              notificationService: FakeReminderNotificationService(),
              urlLauncher: (uri) async => true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('menu_user_profile')));
      await tester.pumpAndSettle();
    }

    r29.FakeSettingsBackend backendWithAvatar(String avatarId) =>
        r29.FakeSettingsBackend()
          ..pullBody = r29.pull(profile: {'avatarId': avatarId});

    testWidgets(
      'card shows the picked avatar and the Edit profile picture button',
      (tester) async {
        await pumpProfile(tester, backend: backendWithAvatar('avatar_03'));
        final avatar = tester.widget<UserAvatar>(
          find.byKey(const ValueKey('profile_avatar')),
        );
        expect(avatar.avatarId, 'avatar_03');
        expect(avatar.size, 72);
        expect(
          find.byKey(const ValueKey('edit_profile_picture_button')),
          findsOneWidget,
        );
        // Juno copy ruling: Title Case, matching 'Edit Profile'.
        expect(find.text('Edit Profile Picture'), findsOneWidget);
        // Juno a11y ruling: one semantics label on the card avatar.
        expect(
          find.bySemanticsLabel('Profile picture: Gold Bandit'),
          findsOneWidget,
        );
      },
    );

    testWidgets('card with no pick renders the initials fallback', (
      tester,
    ) async {
      final backend = r29.FakeSettingsBackend()..pullBody = r29.pull();
      await pumpProfile(tester, backend: backend);
      final avatar = tester.widget<UserAvatar>(
        find.byKey(const ValueKey('profile_avatar')),
      );
      expect(avatar.avatarId, isNull);
      // Nickname "Tyson" → initials "TY" on the fallback circle.
      expect(find.text('TY'), findsOneWidget);
      // Juno a11y ruling: the not-set label, and the letter glyph
      // is not read separately (it is inside ExcludeSemantics, so
      // no semantics node carries it — the visual text still shows).
      expect(find.bySemanticsLabel('Profile picture: not set'), findsOneWidget);
    });

    testWidgets('picker renders all 15 cells with the current pick marked', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpProfile(tester, backend: backendWithAvatar('avatar_03'));
      await tester.tap(
        find.byKey(const ValueKey('edit_profile_picture_button')),
      );
      await tester.pumpAndSettle();
      // Juno copy ruling: picker title + the required helper line.
      expect(find.text('Choose a Profile Picture'), findsOneWidget);
      expect(
        find.text(
          'Tap a picture to save it. Your friends will see it next to your name.',
        ),
        findsOneWidget,
      );
      // Juno a11y ruling: cell label is the name only; selection
      // rides the platform selected flag, never the label text.
      // (Asserted on the semantics data directly — the repo's
      // a11y-test pattern; matchesSemantics mishandles this node.)
      final selectedData = tester
          .getSemantics(
              find.byKey(const ValueKey('avatar_option_avatar_03')))
          .getSemanticsData();
      expect(selectedData.label, 'Gold Bandit');
      expect(selectedData.flagsCollection.isButton, isTrue);
      expect(selectedData.flagsCollection.isSelected, ui.Tristate.isTrue);
      final unselectedData = tester
          .getSemantics(
              find.byKey(const ValueKey('avatar_option_avatar_04')))
          .getSemanticsData();
      expect(unselectedData.label, 'Rose Bandit');
      expect(unselectedData.flagsCollection.isButton, isTrue);
      expect(
          unselectedData.flagsCollection.isSelected, ui.Tristate.isFalse);
      // Disposed inline: the test framework's handle check runs
      // before addTearDown callbacks.
      handle.dispose();
      for (var i = 1; i <= 15; i++) {
        final n = i.toString().padLeft(2, '0');
        expect(
          find.byKey(ValueKey('avatar_option_avatar_$n')),
          findsOneWidget,
          reason: 'cell avatar_$n missing',
        );
      }
      // The current pick (avatar_03) carries the check badge; an
      // unpicked cell does not.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('avatar_option_avatar_03')),
          matching: find.byIcon(Icons.check),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('avatar_option_avatar_04')),
          matching: find.byIcon(Icons.check),
        ),
        findsNothing,
      );
    });

    testWidgets('tapping a cell saves immediately and closes the picker', (
      tester,
    ) async {
      final backend = backendWithAvatar('avatar_03');
      await pumpProfile(tester, backend: backend);
      await tester.tap(
        find.byKey(const ValueKey('edit_profile_picture_button')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('avatar_option_avatar_07')));
      await tester.pumpAndSettle();
      expect(backend.profilePushes, [
        {'avatarId': 'avatar_07'},
      ]);
      // Picker closed; the card now shows the new picture.
      expect(
        find.byKey(const ValueKey('avatar_option_avatar_07')),
        findsNothing,
      );
      final avatar = tester.widget<UserAvatar>(
        find.byKey(const ValueKey('profile_avatar')),
      );
      expect(avatar.avatarId, 'avatar_07');
    });

    testWidgets(
      'a failed save keeps the picker open and the picture unchanged',
      (tester) async {
        final backend = backendWithAvatar('avatar_03')..pushResult = false;
        await pumpProfile(tester, backend: backend);
        await tester.tap(
          find.byKey(const ValueKey('edit_profile_picture_button')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('avatar_option_avatar_07')));
        await tester.pumpAndSettle();
        expect(backend.profilePushes, [
          {'avatarId': 'avatar_07'},
        ]);
        // Picker still open (the failure snack is _pushProfile's own
        // surface), and the card still shows the old picture.
        expect(
          find.byKey(const ValueKey('avatar_option_avatar_07')),
          findsOneWidget,
        );
        final avatar = tester.widget<UserAvatar>(
          find.byKey(const ValueKey('profile_avatar')),
        );
        expect(avatar.avatarId, 'avatar_03');
      },
    );
  });

  group('friend surfaces render picked pictures', () {
    setUp(TabsBackend.debugResetSharedCaches);

    testWidgets('community friend row shows the picked icon', (tester) async {
      final store = FakeSessionStore()..token = 'tok';
      final backend = TabsBackend(
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
          }
          return http.Response('{}', 404);
        }),
      );
      await tester.pumpWidget(
        MaterialApp(home: CommunityToolScreen(backend: backend)),
      );
      await tester.pumpAndSettle();
      // Boston picked Flame: his row renders the catalog image.
      final images = tester
          .widgetList<Image>(find.byType(Image))
          .map((i) => (i.image as AssetImage).assetName)
          .toList();
      expect(images, contains('assets/images/avatar_07.png'));
      // Dad picked nothing: his initials fallback renders as before.
      expect(find.text('DA'), findsOneWidget);
    });

    testWidgets('streak friends tab shows the picked icon', (tester) async {
      var s = streakSeed(current: 5, best: 12, now: DateTime(2026, 11, 1, 12));
      s = streakEvaluate(s, DateTime(2026, 11, 3, 12));
      s = streakEvaluate(s, DateTime(2026, 11, 4, 12));
      await tester.pumpWidget(
        MaterialApp(
          home: StreakScreen(
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
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('streakTabFriends')));
      await tester.pumpAndSettle();
      final images = tester
          .widgetList<Image>(find.byType(Image))
          .map((i) => (i.image as AssetImage).assetName)
          .toList();
      expect(images, contains('assets/images/avatar_09.png'));
      // Dad picked nothing: the navy initial fallback renders.
      expect(find.text('D'), findsOneWidget);
    });
  });
}
