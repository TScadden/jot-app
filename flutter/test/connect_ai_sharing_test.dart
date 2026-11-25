import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/connections/connect_ai_screen.dart';

import 'test_helpers.dart';

/// Friend data sharing — Connect an AI sections (Bram, MCP
/// friend-sharing package). Copy assertions use Juno's SIGNED
/// strings (build-mcp-sharing/JUNO-COPY.md §a/§b) as independent
/// literals — never via ShareCopy — so a drift in the screen's
/// copy fails here (the premium-gate pattern).

class FakeShareBackend extends TabsBackend {
  FakeShareBackend({
    this.friends = const [],
    this.outgoing = const [],
    this.incoming = const [],
    this.lastReads = const [],
    this.failShares = false,
    this.membershipResult = const (isUnlimited: true, isAdmin: false),
    this.createResult,
    this.writeResult = true,
  }) : super(
          client: MockClient((_) async => http.Response('{}', 200)),
          sessionStore: FakeSessionStore(),
        );

  List<FriendDto> friends;
  List<DataShareDto>? outgoing;
  List<DataShareDto>? incoming;
  List<ShareLastReadDto>? lastReads;
  bool failShares;
  ({bool isUnlimited, bool isAdmin})? membershipResult;
  DataShareDto? createResult;
  bool writeResult;

  final List<(String, List<String>)> created = [];
  final List<String> acceptedIds = [];
  final List<String> declinedIds = [];
  final List<String> revokedIds = [];
  final List<(String, List<String>)> categoryUpdates = [];

  @override
  Future<List<AiConnectionDto>?> fetchAiConnections() async => const [];

  @override
  Future<({bool isUnlimited, bool isAdmin})?> fetchMembershipOrNull() async =>
      membershipResult;

  @override
  Future<List<FriendDto>> fetchFriendsList() async {
    if (failShares) throw StateError('boom');
    return friends;
  }

  @override
  Future<List<DataShareDto>?> fetchOutgoingShares() async =>
      failShares ? null : outgoing;

  @override
  Future<List<DataShareDto>?> fetchIncomingShares() async =>
      failShares ? null : incoming;

  @override
  Future<List<ShareLastReadDto>?> fetchShareLastReads() async =>
      failShares ? null : lastReads;

  @override
  Future<DataShareDto?> createDataShare(
      String recipientId, List<String> categories) async {
    created.add((recipientId, categories));
    return createResult;
  }

  @override
  Future<bool> acceptDataShare(String id) async {
    acceptedIds.add(id);
    return writeResult;
  }

  @override
  Future<bool> declineDataShare(String id) async {
    declinedIds.add(id);
    return writeResult;
  }

  @override
  Future<bool> revokeDataShare(String id) async {
    revokedIds.add(id);
    return writeResult;
  }

  @override
  Future<bool> updateDataShareCategories(
      String id, List<String> categories) async {
    categoryUpdates.add((id, categories));
    return writeResult;
  }
}

FriendDto _friend(String id, String nickname) => FriendDto(
      id: id,
      nickname: nickname,
      tag: '00001',
      status: 'Online',
      level: 1,
    );

DataShareDto _share(
  String id,
  String otherId,
  String nickname, {
  required bool outgoing,
  List<String> categories = const ['medications'],
  List<String> unknownCategories = const [],
  String status = 'pending',
  DateTime? respondedAt,
}) =>
    DataShareDto(
      id: id,
      otherId: otherId,
      otherNickname: nickname,
      otherTag: '00001',
      categories: categories,
      unknownCategories: unknownCategories,
      status: status,
      createdAt: DateTime(2026, 11, 20),
      respondedAt: respondedAt,
    );

Widget _wrap(Widget child) => MaterialApp(home: child);

/// Drags the screen's ListView until [finder] is built, then
/// ensures it is visible. (scrollUntilVisible proved flaky
/// against this screen's lazily built sections.)
Future<void> _scrollTo(WidgetTester tester, Finder finder,
    {bool up = false}) async {
  for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
    await tester.drag(
        find.byType(ListView), Offset(0, up ? 300 : -300));
    await tester.pumpAndSettle();
  }
  if (finder.evaluate().isNotEmpty) {
    await tester.ensureVisible(finder.first);
    await tester.pumpAndSettle();
  }
}

void main() {
  group('Share my data — gating', () {
    testWidgets('free verdict: sharing sections absent', (tester) async {
      final backend = FakeShareBackend(
        friends: [_friend('f1', 'Dad')],
        membershipResult: const (isUnlimited: false, isAdmin: false),
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      expect(find.text('Connecting an AI needs Premium'), findsOneWidget);
      expect(find.text('Share my data'), findsNothing);
      expect(find.text('Shared with you'), findsNothing);
      expect(find.text('Pick a friend'), findsNothing);
    });

    testWidgets(
        'entitlement failure: honest error, no sharing sections, '
        'no upsell claim', (tester) async {
      final backend = FakeShareBackend(
        friends: [_friend('f1', 'Dad')],
        membershipResult: null,
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      expect(find.text(ConnectAiCopy.loadError), findsOneWidget);
      expect(find.text('Share my data'), findsNothing);
      expect(find.text('Shared with you'), findsNothing);
      expect(find.text('Upgrade to Premium'), findsNothing);
    });

    testWidgets(
        'shares fetch failure: honest load error, never an '
        'empty-state claim', (tester) async {
      final backend = FakeShareBackend(failShares: true);
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text('Share my data'));
      expect(
        find.text("Couldn't load your sharing right now. Try again later."),
        findsWidgets,
      );
      expect(
        find.text("You're not sharing anything with anyone right now."),
        findsNothing,
      );
      expect(find.text('No friends to share with yet. Add a friend in '
          'Community first, then come back here.'), findsNothing);
    });
  });

  group('Share my data — picker + create', () {
    testWidgets('picker lists accepted friends exactly as fetched',
        (tester) async {
      final backend = FakeShareBackend(
        friends: [_friend('f1', 'Dad'), _friend('f2', 'Maya')],
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text('Pick a friend'));
      expect(find.text('Pick a friend'), findsOneWidget);
      expect(
        find.text("You can only share with friends you've already "
            'accepted in Community.'),
        findsOneWidget,
      );
      expect(find.text('Dad'), findsOneWidget);
      expect(find.text('Maya'), findsOneWidget);
      // The hardcoded server status literal is never a label.
      expect(find.text('Online'), findsNothing);
      // No shares yet: Juno's whole-section empty state.
      expect(
        find.text("You're not sharing anything with anyone right now."),
        findsOneWidget,
      );
    });

    testWidgets('picker empty state when there are no friends',
        (tester) async {
      final backend = FakeShareBackend();
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text('Pick a friend'));
      expect(
        find.text('No friends to share with yet. Add a friend in '
            'Community first, then come back here.'),
        findsOneWidget,
      );
    });

    testWidgets(
        'category step: Juno names + descriptions, all off, '
        'honesty block above send', (tester) async {
      final backend = FakeShareBackend(friends: [_friend('f1', 'Dad')]);
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.byKey(const ValueKey('pick_friend_f1')));
      await tester.tap(find.byKey(const ValueKey('pick_friend_f1')));
      await tester.pumpAndSettle();

      expect(find.text('Choose what to share'), findsOneWidget);
      expect(
        find.text("Everything starts off. Turn on only what you're "
            'okay sharing.'),
        findsOneWidget,
      );
      // Every category tile, scrolled into view in turn: Juno's
      // name renders and every switch starts off (§a2).
      const names = {
        'medications': 'Medications',
        'sleep': 'Sleep',
        'daily_scores': 'Daily Scores',
        'heart_rate_spikes': 'Heart rate spikes',
        'streak': 'Streak',
        'badges_and_gems': 'Badges and gems',
        'log_entries': 'Log entries',
        'summaries': 'Summaries',
        'reports': 'Reports',
      };
      for (final entry in names.entries) {
        final key = ValueKey('pick_cat_${entry.key}');
        await _scrollTo(tester, find.byKey(key));
        expect(find.text(entry.value), findsWidgets,
            reason: entry.value);
        expect(
          tester.widget<SwitchListTile>(find.byKey(key)).value,
          isFalse,
          reason: '${entry.value} must start off',
        );
      }
      await _scrollTo(tester,
          find.byKey(const ValueKey('pick_cat_daily_scores')),
          up: true);
      expect(
        find.text('Your full Daily Scores, including the sleep, HRV, '
            'and resting heart rate numbers behind each score.'),
        findsOneWidget,
      );
      await _scrollTo(
          tester, find.byKey(const ValueKey('pick_cat_sleep')),
          up: true);
      expect(
        find.text('Only your sleep numbers: how long you slept, your '
            'Sleep Need, and your sleep score. Nothing else from your '
            'Daily Scores.'),
        findsOneWidget,
      );
      // Juno ruling §5 (Summaries) + §1.1 (Reports), verbatim.
      await _scrollTo(
          tester, find.byKey(const ValueKey('pick_cat_summaries')));
      expect(
        find.text('Your Daily Summary: which days you finished it, '
            'and for one day at a time, what was planned and what '
            'got finished, your 1 to 5 check-in, and your Morning '
            'Score. Also basic facts about your generated reports '
            '— when one was made and how many entries it covered. '
            'The report itself is not part of this one.'),
        findsOneWidget,
      );
      await _scrollTo(
          tester, find.byKey(const ValueKey('pick_cat_reports')));
      expect(
        find.text('Your clinical report PDFs. With this on, their '
            'AI can make a report PDF from your Tabs data — the '
            'same kind of report you can make in the app. It starts '
            'off, and stays off unless you turn it on.'),
        findsOneWidget,
      );
      // §a4 honesty block, verbatim, above the send button.
      await _scrollTo(
          tester, find.byKey(const ValueKey('send_share_request')));
      expect(
        find.text("Heads up: what you share doesn't go straight to "
            "your friend. It goes through your friend's AI app, on "
            "that company's systems, under that company's privacy "
            "policy — not Tabs'."),
        findsOneWidget,
      );
      expect(
        find.text('If you stop sharing later, or turn a category '
            "off, that stops future reads right away. It can't take "
            'back anything their AI already read.'),
        findsOneWidget,
      );
      expect(find.text('Send share request'), findsOneWidget);
    });

    testWidgets('send with nothing picked shows Juno\'s line, no call',
        (tester) async {
      final backend = FakeShareBackend(friends: [_friend('f1', 'Dad')]);
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.byKey(const ValueKey('pick_friend_f1')));
      await tester.tap(find.byKey(const ValueKey('pick_friend_f1')));
      await tester.pumpAndSettle();
      await _scrollTo(
          tester, find.byKey(const ValueKey('send_share_request')));
      await tester.tap(find.byKey(const ValueKey('send_share_request')));
      await tester.pumpAndSettle();

      expect(find.text('Pick at least one thing to share first.'),
          findsOneWidget);
      expect(backend.created, isEmpty);
    });

    testWidgets('create → pending state renders with Juno copy',
        (tester) async {
      final backend = FakeShareBackend(
        friends: [_friend('f1', 'Dad')],
        createResult: _share('s1', 'f1', '', outgoing: true),
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.byKey(const ValueKey('pick_friend_f1')));
      await tester.tap(find.byKey(const ValueKey('pick_friend_f1')));
      await tester.pumpAndSettle();
      await _scrollTo(
          tester, find.byKey(const ValueKey('pick_cat_sleep')));
      await tester.tap(find.byKey(const ValueKey('pick_cat_sleep')));
      await tester.pumpAndSettle();
      await _scrollTo(
          tester, find.byKey(const ValueKey('pick_cat_medications')),
          up: true);
      await tester.tap(find.byKey(const ValueKey('pick_cat_medications')));
      await tester.pumpAndSettle();

      // After the create lands, the re-fetch shows the pending row.
      backend.outgoing = [
        _share('s1', 'f1', 'Dad',
            outgoing: true, categories: ['medications', 'sleep']),
      ];
      await _scrollTo(
          tester, find.byKey(const ValueKey('send_share_request')));
      await tester.tap(find.byKey(const ValueKey('send_share_request')));
      await tester.pumpAndSettle();

      // Categories go out in Juno's §a2 order regardless of tap order.
      expect(backend.created.length, 1);
      expect(backend.created.single.$1, 'f1');
      expect(backend.created.single.$2, ['medications', 'sleep']);
      // The pending card renders above the picker — scroll back up.
      await _scrollTo(tester, find.text('Waiting for Dad to accept'),
          up: true);
      expect(find.text('Waiting for Dad to accept'), findsOneWidget);
      expect(
        find.text("Dad hasn't accepted yet, so their AI can't read "
            'anything. Nothing is shared until they say yes.'),
        findsOneWidget,
      );
      expect(find.text('Cancel request'), findsOneWidget);
    });

    testWidgets('cancel request revokes the pending share',
        (tester) async {
      final backend = FakeShareBackend(
        friends: [_friend('f1', 'Dad')],
        outgoing: [_share('s1', 'f1', 'Dad', outgoing: true)],
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.byKey(const ValueKey('cancel_share_s1')));
      await tester.tap(find.byKey(const ValueKey('cancel_share_s1')));
      await tester.pumpAndSettle();

      expect(backend.revokedIds, ['s1']);
      expect(find.text('Waiting for Dad to accept'), findsNothing);
    });
  });

  group('Share my data — manage + last-read', () {
    FakeShareBackend manageBackend() => FakeShareBackend(
          friends: [_friend('f1', 'Dad')],
          outgoing: [
            _share('s1', 'f1', 'Dad',
                outgoing: true,
                categories: ['medications', 'sleep'],
                status: 'accepted',
                respondedAt: DateTime(2026, 11, 20)),
          ],
        );

    testWidgets('never-read line when the friend\'s AI has not read',
        (tester) async {
      final backend = manageBackend();
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text("Dad's AI hasn't viewed your "
          'data yet'));
      expect(
        find.text("Dad's AI hasn't viewed your data yet"),
        findsOneWidget,
      );
    });

    testWidgets('last-read line from endpoint data (today)',
        (tester) async {
      final backend = manageBackend();
      backend.lastReads = [
        ShareLastReadDto(
          recipientId: 'f1',
          nickname: 'Dad',
          tag: '00001',
          category: 'medications',
          readAt: DateTime.now(),
        ),
      ];
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(tester,
          find.text("Dad's AI last viewed your Medications today"));
      expect(
        find.text("Dad's AI last viewed your Medications today"),
        findsOneWidget,
      );
      expect(find.text("Dad's AI hasn't viewed your data yet"),
          findsNothing);
    });

    testWidgets(
        'last-read: a report generation renders Juno §8\'s '
        'generated line, not the viewed line', (tester) async {
      final backend = manageBackend();
      backend.lastReads = [
        ShareLastReadDto(
          recipientId: 'f1',
          nickname: 'Dad',
          tag: '00001',
          category: 'reports',
          tool: 'generate_report',
          readAt: DateTime.now(),
        ),
      ];
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(tester, find.text("Dad's AI last generated a "
          'report from your data today'));
      expect(
        find.text("Dad's AI last generated a report from your data "
            'today'),
        findsOneWidget,
      );
      expect(find.textContaining('last viewed your Reports'),
          findsNothing);
    });

    testWidgets(
        'last-read: a newer read still wins over an older generation',
        (tester) async {
      final backend = manageBackend();
      final now = DateTime.now();
      backend.lastReads = [
        ShareLastReadDto(
          recipientId: 'f1',
          nickname: 'Dad',
          tag: '00001',
          category: 'reports',
          tool: 'generate_report',
          readAt: now.subtract(const Duration(days: 1)),
        ),
        ShareLastReadDto(
          recipientId: 'f1',
          nickname: 'Dad',
          tag: '00001',
          category: 'sleep',
          tool: 'get_shared_data',
          readAt: now,
        ),
      ];
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.text("Dad's AI last viewed your Sleep today"));
      expect(find.text("Dad's AI last viewed your Sleep today"),
          findsOneWidget);
    });

    testWidgets('last-read line picks the most recent category',
        (tester) async {
      final backend = manageBackend();
      final now = DateTime.now();
      backend.lastReads = [
        ShareLastReadDto(
          recipientId: 'f1',
          nickname: 'Dad',
          tag: '00001',
          category: 'medications',
          readAt: now.subtract(const Duration(days: 1)),
        ),
        ShareLastReadDto(
          recipientId: 'f1',
          nickname: 'Dad',
          tag: '00001',
          category: 'sleep',
          readAt: now,
        ),
      ];
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.text("Dad's AI last viewed your Sleep today"));
      expect(find.text("Dad's AI last viewed your Sleep today"),
          findsOneWidget);
    });

    testWidgets(
        'manage: category toggle PUTs immediately; revoke confirms '
        'with Juno copy', (tester) async {
      final backend = manageBackend();
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.byKey(const ValueKey('manage_share_s1')));
      await tester.tap(find.byKey(const ValueKey('manage_share_s1')));
      await tester.pumpAndSettle();

      expect(find.text('What Dad can see'), findsOneWidget);
      expect(find.text('Categories'), findsOneWidget);
      expect(
        find.text('Changes take effect right away. Turning a '
            "category off stops future reads of it — it can't take "
            'back what their AI already read.'),
        findsOneWidget,
      );
      expect(
        find.text('Turning a category on shares it right away. Dad '
            "doesn't need to accept again."),
        findsOneWidget,
      );

      await _scrollTo(
          tester, find.byKey(const ValueKey('manage_cat_s1_streak')));
      await tester.tap(find.byKey(const ValueKey('manage_cat_s1_streak')));
      await tester.pumpAndSettle();
      expect(backend.categoryUpdates.length, 1);
      expect(backend.categoryUpdates.single.$1, 's1');
      expect(backend.categoryUpdates.single.$2,
          ['medications', 'sleep', 'streak']);

      await _scrollTo(
          tester, find.byKey(const ValueKey('stop_sharing_s1')));
      await tester.tap(find.byKey(const ValueKey('stop_sharing_s1')));
      await tester.pumpAndSettle();
      expect(find.text('Stop sharing with Dad?'), findsOneWidget);
      expect(
        find.text('Their AI will stop being able to read your data '
            'right away. Anything it already read stays with that '
            'company, under its own privacy policy — stopping '
            "can't take that back."),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('confirm_stop_sharing')));
      await tester.pumpAndSettle();
      expect(backend.revokedIds, ['s1']);
    });

    testWidgets(
        'manage toggle on a share with an unknown category keeps '
        'that key in the save payload', (tester) async {
      final backend = FakeShareBackend(
        friends: [_friend('f1', 'Dad')],
        outgoing: [
          _share('s1', 'f1', 'Dad',
              outgoing: true,
              categories: ['medications'],
              unknownCategories: ['future_scope'],
              status: 'accepted',
              respondedAt: DateTime(2026, 11, 20)),
        ],
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.byKey(const ValueKey('manage_share_s1')));
      await tester.tap(find.byKey(const ValueKey('manage_share_s1')));
      await tester.pumpAndSettle();

      // The unknown key renders no toggle of its own.
      expect(find.byKey(const ValueKey('manage_cat_s1_future_scope')),
          findsNothing);

      await _scrollTo(
          tester, find.byKey(const ValueKey('manage_cat_s1_sleep')));
      await tester.tap(find.byKey(const ValueKey('manage_cat_s1_sleep')));
      await tester.pumpAndSettle();

      // Load → toggle-another-category → save: the unknown grant
      // is written back untouched, not wiped by the save.
      expect(backend.categoryUpdates.length, 1);
      expect(backend.categoryUpdates.single.$2,
          ['medications', 'sleep', 'future_scope']);
    });

    testWidgets('manage view shows the Reports toggle',
        (tester) async {
      final backend = manageBackend();
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.byKey(const ValueKey('manage_share_s1')));
      await tester.tap(find.byKey(const ValueKey('manage_share_s1')));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.byKey(const ValueKey('manage_cat_s1_reports')));
      final tile = tester.widget<SwitchListTile>(
          find.byKey(const ValueKey('manage_cat_s1_reports')));
      expect(tile.value, isFalse);
      await tester.tap(find.byKey(const ValueKey('manage_cat_s1_reports')));
      await tester.pumpAndSettle();
      expect(backend.categoryUpdates.single.$2,
          ['medications', 'sleep', 'reports']);
    });
  });

  group('Shared with you', () {
    testWidgets(
        'incoming offer: exact category list + honesty lines; '
        'accept calls and the active row renders', (tester) async {
      final backend = FakeShareBackend(
        incoming: [
          _share('s9', 'u2', 'Dad',
              outgoing: false, categories: ['sleep', 'medications']),
        ],
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.text('Dad wants to share their Tabs data with you'));
      expect(
        find.text('Dad wants to share their Tabs data with you'),
        findsOneWidget,
      );
      // {categories} slot: complete exact names, §a2 order, even
      // though the payload arrived in the other order.
      expect(
        find.text('Dad is offering to share: Medications, Sleep. If '
            "you accept, your AI can read those parts of Dad's Tabs "
            'data and answer your questions about them. It can only '
            "read — it can't change anything in their account."),
        findsOneWidget,
      );
      expect(
        find.text("What your AI reads doesn't stay just between you "
            "and Dad. It goes through your AI app, on that company's "
            "systems, under that company's privacy policy — not "
            "Tabs'."),
        findsOneWidget,
      );
      expect(
        find.text('If Dad stops sharing later, or turns a category '
            "off, that stops future reads. It can't take back "
            'anything your AI already read.'),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('accept_share_s9')));
      await tester.pumpAndSettle();
      expect(backend.acceptedIds, ['s9']);
      const months = [
        '', 'January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November',
        'December'
      ];
      final now = DateTime.now();
      expect(
        find.text('Sharing Medications, Sleep with you since '
            '${months[now.month]} ${now.day}, ${now.year}'),
        findsOneWidget,
      );
    });

    testWidgets('decline calls and shows Juno\'s declined line',
        (tester) async {
      final backend = FakeShareBackend(
        incoming: [_share('s9', 'u2', 'Dad', outgoing: false)],
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(
          tester, find.byKey(const ValueKey('decline_share_s9')));
      await tester.tap(find.byKey(const ValueKey('decline_share_s9')));
      await tester.pumpAndSettle();

      expect(backend.declinedIds, ['s9']);
      expect(
        find.text("You said no to Dad's share, so your AI can't "
            'read any of their data.'),
        findsOneWidget,
      );
    });

    testWidgets('active share row: who, exact categories, since when',
        (tester) async {
      final backend = FakeShareBackend(
        incoming: [
          _share('s9', 'u2', 'Dad',
              outgoing: false,
              categories: ['medications', 'sleep'],
              status: 'accepted',
              respondedAt: DateTime(2026, 11, 20)),
        ],
      );
      await tester.pumpWidget(_wrap(ConnectAiScreen(backend: backend)));
      await tester.pumpAndSettle();

      await _scrollTo(tester,
          find.text('Sharing Medications, Sleep with you since '
              'November 20, 2026'));
      expect(find.text('Dad'), findsWidgets);
      expect(
        find.text('Sharing Medications, Sleep with you since '
            'November 20, 2026'),
        findsOneWidget,
      );
      // HARD CONSTRAINT (Juno flag 8): no recipient-side
      // remove/end-share action anywhere.
      expect(find.text('Stop sharing'), findsNothing);
      expect(find.textContaining('Remove'), findsNothing);
      expect(find.textContaining('End share'), findsNothing);
    });
  });

  group('DataShareDto.fromJson', () {
    test('parses the outgoing list shape and orders categories', () {
      final dto = DataShareDto.fromJson({
        'id': 'abc',
        'recipient': {'id': 'u1', 'nickname': 'Dad', 'tag': '12345'},
        'categories': ['sleep', 'medications'],
        'status': 'accepted',
        'created_at': '2026-11-20T10:00:00.000Z',
        'responded_at': '2026-11-20T12:00:00.000Z',
      }, outgoing: true);
      expect(dto, isNotNull);
      expect(dto!.otherNickname, 'Dad');
      expect(dto.categories, ['medications', 'sleep']);
      expect(dto.isAccepted, isTrue);
      expect(dto.respondedAt, isNotNull);
    });

    test('parses the flat create shape', () {
      final dto = DataShareDto.fromJson({
        'id': 'abc',
        'recipientId': 'u1',
        'categories': ['streak'],
        'status': 'pending',
      }, outgoing: true);
      expect(dto, isNotNull);
      expect(dto!.otherId, 'u1');
      expect(dto.isPending, isTrue);
    });

    test('unknown category keys are PRESERVED, missing id is null',
        () {
      // Hazard fix (MCP Reports package): the pre-fix parse dropped
      // unknown keys, so a later save could wipe a server-side
      // grant this build predates. They now ride on the model.
      final dto = DataShareDto.fromJson({
        'id': 'abc',
        'sharer': {'id': 'u2', 'nickname': 'Maya', 'tag': '9'},
        'categories': ['sleep', 'bogus_key'],
        'status': 'pending',
      }, outgoing: false);
      expect(dto!.categories, ['sleep']);
      expect(dto.unknownCategories, ['bogus_key']);
      expect(dto.allCategories, ['sleep', 'bogus_key']);
      expect(
        DataShareDto.fromJson({'status': 'pending'}, outgoing: true),
        isNull,
      );
    });

    test('reports is a known category (not unknown)', () {
      expect(dataShareCategoryKeys, contains('reports'));
      final dto = DataShareDto.fromJson({
        'id': 'abc',
        'recipient': {'id': 'u1', 'nickname': 'Dad', 'tag': '1'},
        'categories': ['reports', 'summaries'],
        'status': 'accepted',
      }, outgoing: true);
      expect(dto!.categories, ['summaries', 'reports']);
      expect(dto.unknownCategories, isEmpty);
      expect(ShareCopy.categoryName('reports'), 'Reports');
    });

    test(
        'unknown key survives load → toggle another category → save',
        () {
      // Load: the server share carries a category this build
      // predates ('future_scope') alongside a known one.
      final dto = DataShareDto.fromJson({
        'id': 'abc',
        'recipient': {'id': 'u1', 'nickname': 'Dad', 'tag': '1'},
        'categories': ['future_scope', 'medications'],
        'status': 'accepted',
      }, outgoing: true)!;
      expect(dto.categories, ['medications']);
      expect(dto.unknownCategories, ['future_scope']);

      // Toggle another category ON (the manage-view save path):
      // the payload keeps the unknown key untouched, after the
      // known keys in canonical order.
      final payloadOn = dto.categoriesForSave({'medications', 'sleep'});
      expect(payloadOn, ['medications', 'sleep', 'future_scope']);

      // Toggle a known category OFF: unknown key still survives.
      final payloadOff = dto.categoriesForSave({'sleep'});
      expect(payloadOff, ['sleep', 'future_scope']);

      // copyWith (the screen's post-save model update, which
      // passes only the known selection) preserves the unknown
      // keys by default.
      final updated = dto.copyWith(categories: ['sleep']);
      expect(updated.categories, ['sleep']);
      expect(updated.unknownCategories, ['future_scope']);
      expect(updated.allCategories, ['sleep', 'future_scope']);
      expect(updated.categoriesForSave(updated.categories), payloadOff);
    });

    test('orderedDataShareCategories: known canonical, unknown last',
        () {
      expect(
        orderedDataShareCategories(
            ['zzz_future', 'sleep', 'medications', 'sleep', 'aaa_future']),
        ['medications', 'sleep', 'zzz_future', 'aaa_future'],
      );
    });
  });

  group('TabsBackend data-shares contract', () {
    TabsBackend backendFor(
        http.Response Function(http.Request) handler) {
      final store = FakeSessionStore()..token = 'test-token';
      return TabsBackend(
        client: MockClient((req) async => handler(req)),
        sessionStore: store,
      );
    }

    test('create posts recipientId + categories, accepts 201',
        () async {
      http.Request? seen;
      final backend = backendFor((req) {
        seen = req;
        return http.Response(
          jsonEncode({
            'share': {
              'id': 'abc',
              'recipientId': 'u1',
              'categories': ['medications'],
              'status': 'pending',
            },
          }),
          201,
        );
      });
      final dto = await backend.createDataShare('u1', ['medications']);
      expect(dto, isNotNull);
      expect(dto!.isPending, isTrue);
      expect(seen!.url.path, '/api/data-shares');
      final body = jsonDecode(seen!.body) as Map<String, dynamic>;
      expect(body['recipientId'], 'u1');
      expect(body['categories'], ['medications']);
    });

    test('outgoing/incoming/last-read parse their envelopes',
        () async {
      final backend = backendFor((req) {
        switch (req.url.path) {
          case '/api/data-shares/outgoing':
            return http.Response(
              jsonEncode({
                'shares': [
                  {
                    'id': 's1',
                    'recipient': {
                      'id': 'u1',
                      'nickname': 'Dad',
                      'tag': '1'
                    },
                    'categories': ['sleep'],
                    'status': 'accepted',
                    'responded_at': '2026-11-20T12:00:00.000Z',
                  },
                ],
              }),
              200,
            );
          case '/api/data-shares/incoming':
            return http.Response(jsonEncode({'shares': []}), 200);
          case '/api/data-shares/last-read':
            return http.Response(
              jsonEncode({
                'lastReads': [
                  {
                    'recipient_id': 'u1',
                    'nickname': 'Dad',
                    'tag': '1',
                    'category': 'sleep',
                    'tool': 'get_shared_data',
                    'read_at': '2026-11-23T10:00:00.000Z',
                  },
                ],
              }),
              200,
            );
        }
        return http.Response('{}', 404);
      });
      final outgoing = await backend.fetchOutgoingShares();
      expect(outgoing!.single.otherNickname, 'Dad');
      expect(await backend.fetchIncomingShares(), isEmpty);
      final reads = await backend.fetchShareLastReads();
      expect(reads!.single.category, 'sleep');
      expect(reads.single.readAt, isNotNull);
      // The endpoint's `tool` field is carried on the DTO (Juno
      // ruling §8 keys the generation line off it).
      expect(reads.single.tool, 'get_shared_data');
      expect(reads.single.isReportGeneration, isFalse);
    });

    test('ShareLastReadDto parses a generate_report row', () {
      final dto = ShareLastReadDto.fromJson({
        'recipient_id': 'u1',
        'nickname': 'Dad',
        'tag': '1',
        'category': 'reports',
        'tool': 'generate_report',
        'read_at': '2026-11-24T10:00:00.000Z',
      });
      expect(dto, isNotNull);
      expect(dto!.isReportGeneration, isTrue);
      expect(dto.category, 'reports');
    });

    test('lists return null on non-200 (honest failure)', () async {
      final backend = backendFor((_) => http.Response('nope', 500));
      expect(await backend.fetchOutgoingShares(), isNull);
      expect(await backend.fetchIncomingShares(), isNull);
      expect(await backend.fetchShareLastReads(), isNull);
    });

    test('transitions and category PUT hit their paths', () async {
      final seen = <String>[];
      final backend = backendFor((req) {
        seen.add('${req.method} ${req.url.path}');
        return http.Response('{"share":{}}', 200);
      });
      expect(await backend.acceptDataShare('s1'), isTrue);
      expect(await backend.declineDataShare('s1'), isTrue);
      expect(await backend.revokeDataShare('s1'), isTrue);
      expect(await backend.updateDataShareCategories('s1', ['sleep']),
          isTrue);
      expect(seen, [
        'POST /api/data-shares/s1/accept',
        'POST /api/data-shares/s1/decline',
        'POST /api/data-shares/s1/revoke',
        'PUT /api/data-shares/s1/categories',
      ]);
    });
  });
}
