import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/friend_notification_surfacer.dart';
import 'package:tabs_lab/src/data/streak_engine.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/friend_streak_invite_screen.dart';
import 'package:tabs_lab/src/features/home/streak_screen.dart';

/// Friend Streaks (DESIGN §7/§8 app half, Nov 23, 2026) — widget
/// tests for the FRIENDS tab, the invite picker, and the local
/// notification surfacer. All user-facing strings asserted here are
/// Juno's SIGNED copy (JUNO-COPY.md) verbatim.
void main() {
  DateTime at(int y, int m, int d) => DateTime(y, m, d, 12);

  StreakState seed() => streakSeed(current: 5, best: 12, now: at(2026, 11, 23));

  FriendStreakPartnerDto partner(
    String id,
    String nickname,
    String tag,
  ) =>
      FriendStreakPartnerDto(userId: id, nickname: nickname, tag: tag);

  FriendStreakPairDto pair(
    String pairId,
    String nickname, {
    int count = 0,
    bool viewer = false,
    bool partnerDone = false,
  }) =>
      FriendStreakPairDto(
        pairId: pairId,
        partner: partner('u-$pairId', nickname, '10001'),
        status: 'active',
        count: count,
        best: count,
        viewerFinishedToday: viewer,
        partnerFinishedToday: partnerDone,
      );

  Future<void> pumpFriendsTab(
    WidgetTester tester, {
    FriendStreaksDto? initialFriendStreaks,
    Future<FriendStreaksDto?> Function()? friendStreaksLoader,
    List<FriendDto>? initialFriends,
    Future<Map<String, dynamic>?> Function(String pairId, bool accept)?
        onRespond,
    Future<Map<String, dynamic>?> Function(String pairId)? onRemove,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: StreakScreen(
          state: seed(),
          now: at(2026, 11, 23),
          nickname: 'Tyson',
          initialFriendStreaks: initialFriendStreaks,
          friendStreaksLoader: friendStreaksLoader,
          initialFriends: initialFriends,
          onRespondFriendStreak: onRespond,
          onRemoveFriendStreak: onRemove,
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('streakTabFriends')));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('empty state matches mock part 1 structure + Juno footer',
      (tester) async {
    await pumpFriendsTab(
      tester,
      initialFriendStreaks: FriendStreaksDto.empty,
    );

    // Banner: own avatar + dashed plus circle + flame on the navy band.
    expect(find.byKey(const Key('friendStreaksEmptyBanner')), findsOneWidget);
    expect(find.byKey(const Key('friendStreaksBannerPlus')), findsOneWidget);
    expect(find.byKey(const Key('friendStreaksBannerFlame')), findsOneWidget);

    // Heading + muted EDIT (nothing to edit yet).
    expect(find.text('Friend Streaks'), findsOneWidget);
    expect(find.text('EDIT'), findsOneWidget);

    // Card with TWO Invite a friend rows.
    expect(find.byKey(const Key('friendStreaksEmptyCard')), findsOneWidget);
    expect(find.byKey(const Key('friendStreaksInviteRow-0')), findsOneWidget);
    expect(find.byKey(const Key('friendStreaksInviteRow-1')), findsOneWidget);
    expect(find.text('Invite a friend'), findsNWidgets(2));

    // fs_empty_footer — Juno's AMENDED footer, verbatim.
    expect(
      find.text(
        'A friend streak goes up by one every day you both finish '
        'your day. If a day is missed, the streak ends. A day '
        'covered by a freeze pauses it instead.',
      ),
      findsOneWidget,
    );
    // The superseded mock line must not survive anywhere.
    expect(find.textContaining('loses your streak'), findsNothing);
  });

  testWidgets('load failure renders fs_error_load', (tester) async {
    await pumpFriendsTab(
      tester,
      friendStreaksLoader: () async => null,
    );
    expect(
      find.text(
        "Couldn't load your friend streaks right now. Try again later.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('incoming invite: ACCEPT and DECLINE call respond with pairId',
      (tester) async {
    final calls = <(String, bool)>[];
    await pumpFriendsTab(
      tester,
      initialFriendStreaks: FriendStreaksDto(
        incoming: [
          FriendStreakIncomingDto(
            pairId: 'pair-in-1',
            partner: partner('u-jeff', 'jeffscadden', '71298'),
          ),
        ],
      ),
      onRespond: (pairId, accept) async {
        calls.add((pairId, accept));
        return {'success': true};
      },
    );

    expect(find.text('Invited you to a friend streak'), findsOneWidget);
    expect(find.text('ACCEPT'), findsOneWidget);
    expect(find.text('DECLINE'), findsOneWidget);

    await tester.tap(find.byKey(const Key('friendStreakAccept-pair-in-1')));
    await tester.pump();
    expect(calls, [('pair-in-1', true)]);
    // The accepted row leaves the incoming list locally.
    expect(find.byKey(const Key('friendStreakAccept-pair-in-1')), findsNothing);
  });

  testWidgets('incoming invite: DECLINE calls respond with accept=false',
      (tester) async {
    final calls = <(String, bool)>[];
    await pumpFriendsTab(
      tester,
      initialFriendStreaks: FriendStreaksDto(
        incoming: [
          FriendStreakIncomingDto(
            pairId: 'pair-in-2',
            partner: partner('u-jeff', 'jeffscadden', '71298'),
          ),
        ],
      ),
      onRespond: (pairId, accept) async {
        calls.add((pairId, accept));
        return {'success': true};
      },
    );
    await tester.tap(find.byKey(const Key('friendStreakDecline-pair-in-2')));
    await tester.pump();
    expect(calls, [('pair-in-2', false)]);
  });

  testWidgets('active rows: count + each status line selected by flags',
      (tester) async {
    await pumpFriendsTab(
      tester,
      initialFriendStreaks: FriendStreaksDto(
        pairs: [
          pair('p-both', 'Boston Scadden', count: 5, viewer: true, partnerDone: true),
          pair('p-viewer', 'Mom', count: 3, viewer: true),
          pair('p-partner', 'Dad', count: 7, partnerDone: true),
          pair('p-neither', 'Addy', count: 1),
        ],
      ),
    );

    // Counts render with the flame (keyed per pair).
    expect(
      (tester.widget<Text>(find.byKey(const Key('friendStreakPairCount-p-both')))).data,
      '5',
    );
    expect(
      (tester.widget<Text>(find.byKey(const Key('friendStreakPairCount-p-partner')))).data,
      '7',
    );

    // Juno (c) note 1: exactly one status line per row, by flags.
    expect(
      (tester.widget<Text>(find.byKey(const Key('friendStreakPairStatus-p-both')))).data,
      'You both finished today',
    );
    expect(
      (tester.widget<Text>(find.byKey(const Key('friendStreakPairStatus-p-viewer')))).data,
      'You finished today',
    );
    // fs_status_partner_done keeps its second sentence.
    expect(
      (tester.widget<Text>(find.byKey(const Key('friendStreakPairStatus-p-partner')))).data,
      'They finished today. No rush on yours.',
    );
    expect(
      (tester.widget<Text>(find.byKey(const Key('friendStreakPairStatus-p-neither')))).data,
      'Today is still open for you both',
    );

    // Populated state: exactly ONE invite row at the bottom.
    expect(find.text('Invite a friend'), findsOneWidget);
  });

  testWidgets(
      'EDIT: End streak shows Juno confirm dialog only for active pairs; '
      'Cancel invite fires without one', (tester) async {
    final removed = <String>[];
    await pumpFriendsTab(
      tester,
      initialFriends: const [
        FriendDto(
          id: 'u-jeff',
          nickname: 'jeffscadden',
          tag: '71298',
          status: '',
          level: 0,
        ),
      ],
      initialFriendStreaks: FriendStreaksDto(
        pairs: [pair('p-active', 'Boston Scadden', count: 5)],
        outgoingPending: const ['u-jeff'],
        outgoingPendingPairIds: const {'u-jeff': 'pair-out-1'},
      ),
      onRemove: (pairId) async {
        removed.add(pairId);
        return {'success': true};
      },
    );

    // Enter EDIT mode: EDIT becomes DONE.
    await tester.tap(find.byKey(const Key('friendStreaksEditToggle')));
    await tester.pump();
    expect(find.text('DONE'), findsOneWidget);
    expect(find.text('End streak'), findsOneWidget);
    expect(find.text('Cancel invite'), findsOneWidget);

    // Cancel invite: NO confirmation dialog, remove fires at once
    // with the outgoing pairId (server returns [{pairId, friendId}]).
    await tester.tap(find.byKey(const Key('friendStreakCancel-u-jeff')));
    await tester.pump();
    expect(removed, ['pair-out-1']);
    expect(find.text('End this friend streak?'), findsNothing);

    // End streak: the fs_end_confirm_* dialog appears first.
    await tester.tap(find.byKey(const Key('friendStreakEnd-p-active')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('End this friend streak?'), findsOneWidget);
    expect(
      find.text(
        'Your streak with Boston Scadden will end. You can start a '
        'new one anytime.',
      ),
      findsOneWidget,
    );
    expect(find.text('KEEP IT'), findsOneWidget);
    expect(find.text('END STREAK'), findsOneWidget);
    expect(removed, ['pair-out-1']); // nothing fired yet

    await tester.tap(find.byKey(const Key('friendStreakEndDialogConfirm')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(removed, ['pair-out-1', 'p-active']);
  });

  testWidgets('picker: pending + active states, INVITE tap, Juno footers',
      (tester) async {
    final invited = <String>[];
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: FriendStreakInviteScreen(
          now: at(2026, 11, 23),
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
            FriendDto(
              id: 'f-mom',
              nickname: 'Mom',
              tag: '73062',
              status: '',
              level: 0,
            ),
          ],
          initialOutgoingPending: const {'f-jeff'},
          activePartnerIds: const {'f-mom'},
          onInviteFriend: (friendId, date) async {
            invited.add(friendId);
            return {'success': true, 'pairId': 'pair-new'};
          },
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Invite a friend'), findsOneWidget);
    expect(find.text('Pick from your friends'), findsOneWidget);
    expect(find.text('#67676'), findsOneWidget);

    // Right-side states (Juno (c) note 2): exactly one per row.
    expect(find.byKey(const Key('friendStreakInviteButton-f-boston')),
        findsOneWidget);
    expect(find.text('Request pending'), findsOneWidget);
    expect(find.text('Streak active'), findsOneWidget);

    // Juno footers: the AMENDED delivery line + consent line.
    expect(
      find.text(
        'They will see it in the app, and as a phone notification '
        'the next time they open Tabs.',
      ),
      findsOneWidget,
    );
    expect(find.text('Nothing starts until they accept.'), findsOneWidget);
    expect(
      find.textContaining('They get it as a phone notification'),
      findsNothing,
    );

    // INVITE tap calls the client and flips the row to pending.
    await tester.tap(find.byKey(const Key('friendStreakInviteButton-f-boston')));
    await tester.pump();
    await tester.pump();
    expect(invited, ['f-boston']);
    expect(find.text('Request pending'), findsNWidgets(2));
  });

  group('FriendStreaksDto.fromJson outgoingPending shapes', () {
    // Coordinator ruling (Nov 23, 2026, applied server-side by
    // Mason 8decbe1): GET /api/friends/streaks returns
    // outgoingPending as [{pairId, friendId}] objects so EDIT-mode
    // cancel has a pairId for POST /remove. The DTO must consume
    // that shape AND tolerate the legacy [friendId...] strings.
    test('object shape fills outgoingPending + pairId map', () {
      final dto = FriendStreaksDto.fromJson({
        'incoming': [],
        'outgoingPending': [
          {'pairId': 'pair-out-1', 'friendId': 'u-jeff'},
          {'pairId': 'pair-out-2', 'friendId': 'u-mom'},
        ],
        'pairs': [],
      });
      expect(dto.outgoingPending, ['u-jeff', 'u-mom']);
      expect(dto.outgoingPendingPairIds, {
        'u-jeff': 'pair-out-1',
        'u-mom': 'pair-out-2',
      });
    });

    test('legacy string shape still parses, with no pairIds', () {
      final dto = FriendStreaksDto.fromJson({
        'incoming': [],
        'outgoingPending': ['u-jeff'],
        'pairs': [],
      });
      expect(dto.outgoingPending, ['u-jeff']);
      expect(dto.outgoingPendingPairIds, isEmpty);
    });
  });

  group('local notification surfacing dedupe (DESIGN §6)', () {
    FriendNotificationDto row(
      int id,
      String type, {
      bool isRead = false,
      String message = 'Boston Scadden invited you to a friend streak.',
      String? sender = 'Boston Scadden',
    }) =>
        FriendNotificationDto(
          id: id,
          type: type,
          message: message,
          isRead: isRead,
          createdAt: '2026-11-23T19:00:00Z',
          senderNickname: sender,
        );

    ({FriendNotificationSurfacer surfacer, _FakeNotifier notifier, Map<String, String> disk})
        harness() {
      final disk = <String, String>{};
      final notifier = _FakeNotifier();
      final surfacer = FriendNotificationSurfacer(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        notifier: notifier,
      );
      return (surfacer: surfacer, notifier: notifier, disk: disk);
    }

    test('new unread friend-class row posts once; second fetch posts nothing',
        () async {
      final h = harness();
      final rows = [row(41, 'friend_streak_invite')];
      expect(await h.surfacer.surfaceNew(rows), 1);
      expect(h.notifier.calls, hasLength(1));
      expect(h.notifier.calls.single.title, 'New friend streak invite');
      expect(
        h.notifier.calls.single.body,
        'Boston Scadden invited you to a friend streak.',
      );
      // Second fetch with the same unread row: deduped.
      expect(await h.surfacer.surfaceNew(rows), 0);
      expect(h.notifier.calls, hasLength(1));

      // A fresh surfacer over the same persisted store (restart)
      // still dedupes.
      final notifier2 = _FakeNotifier();
      final surfacer2 = FriendNotificationSurfacer(
        read: (k) async => h.disk[k],
        write: (k, v) async => h.disk[k] = v,
        notifier: notifier2,
      );
      expect(await surfacer2.surfaceNew(rows), 0);
      expect(notifier2.calls, isEmpty);
    });

    test('read rows and non-friend types never post', () async {
      final h = harness();
      expect(
        await h.surfacer.surfaceNew([
          row(42, 'friend_streak_invite', isRead: true),
          row(43, 'weekly_summary'),
          row(44, 'friend_accepted', message: 'Mom accepted your friend request.'),
        ]),
        1, // only the unread friend_accepted row
      );
      expect(h.notifier.calls.single.title, 'Friend request accepted');
    });

    test('ended/removed titles + Juno template fallback when message empty',
        () async {
      final h = harness();
      expect(
        await h.surfacer.surfaceNew([
          row(50, 'friend_streak_ended', message: '', sender: 'Dad'),
          row(51, 'friend_streak_removed', message: '', sender: 'Mom'),
          row(52, 'friend_streak_accepted', message: '', sender: 'Addy'),
        ]),
        3,
      );
      expect(h.notifier.calls[0].title, 'Friend streak ended');
      expect(
        h.notifier.calls[0].body,
        'Your friend streak with Dad ended. You can start a new one anytime.',
      );
      expect(
        h.notifier.calls[1].body,
        'Mom ended your friend streak. You can start a new one anytime.',
      );
      expect(h.notifier.calls[2].title, 'Friend streak invite accepted');
      expect(
        h.notifier.calls[2].body,
        'Addy accepted your friend streak invite.',
      );
    });

    test('a failing notifier leaves the id unmarked for a later retry',
        () async {
      final disk = <String, String>{};
      final notifier = _FakeNotifier()..fail = true;
      final surfacer = FriendNotificationSurfacer(
        read: (k) async => disk[k],
        write: (k, v) async => disk[k] = v,
        notifier: notifier,
      );
      final rows = [row(60, 'friend_streak_invite')];
      expect(await surfacer.surfaceNew(rows), 0);
      notifier.fail = false;
      expect(await surfacer.surfaceNew(rows), 1);
    });
  });
}

class _FakeNotifier implements FriendLocalNotifier {
  final List<({int id, String title, String body})> calls = [];
  bool fail = false;

  @override
  Future<bool> show({
    required int serverNotificationId,
    required String title,
    required String body,
  }) async {
    if (fail) return false;
    calls.add((id: serverNotificationId, title: title, body: body));
    return true;
  }
}
