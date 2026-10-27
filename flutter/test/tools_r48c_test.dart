import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/community_screen.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';
import 'package:tabs_lab/src/features/tools/project_focus_screen.dart';
import 'package:tabs_lab/src/features/tools/research_screen.dart';
import 'package:tabs_lab/src/features/tools/tips_tricks_screen.dart';

import 'test_helpers.dart';

/// Round 48 (Group C) — tests for the parity fixes in Health Coach,
/// Community, Project Focus, Research, and Tips & Tricks:
/// payloads, flows, and failure paths for every new write.

TabsBackend backendWith(MockClient client, {String? token = 'tok'}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

String dateStr(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

void main() {
  // Oct 26, 2026 perf package: the sync-pull and habits caches are
  // STATIC and session-keyed, and cases in this file reuse one session
  // token across fresh fake servers — reset between cases so one
  // case's cached pull/habits body cannot be served to the next case.
  setUp(TabsBackend.debugResetSharedCaches);
  // ── Backend payloads ──────────────────────────────────────────────────────

  group('backend friend endpoints', () {
    test('sendFriendRequest posts friendIdString to /api/friends/request',
        () async {
      http.Request? seen;
      final backend = backendWith(MockClient((request) async {
        seen = request;
        return http.Response(
            jsonEncode({'success': true, 'message': null, 'error': null}),
            200);
      }));
      final body = await backend.sendFriendRequest('26385');
      expect(body?['success'], isTrue);
      expect(seen!.url.path, '/api/friends/request');
      expect(jsonDecode(seen!.body), {'friendIdString': '26385'});
    });

    test('respondFriendRequest posts accept/reject actions', () async {
      final bodies = <Map<String, dynamic>>[];
      final backend = backendWith(MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response(jsonEncode({'success': true}), 200);
      }));
      await backend.respondFriendRequest(42, true);
      await backend.respondFriendRequest(43, false);
      expect(bodies, [
        {'requestId': 42, 'action': 'accept'},
        {'requestId': 43, 'action': 'reject'},
      ]);
    });

    test('markFriendNotificationsRead posts to the read endpoint',
        () async {
      String? path;
      final backend = backendWith(MockClient((request) async {
        path = request.url.path;
        return http.Response(jsonEncode({'success': true}), 200);
      }));
      expect(await backend.markFriendNotificationsRead(), isTrue);
      expect(path, '/api/friends/notifications/read');
    });

    test('fetchFriendDetail hits /api/friends/data/{id}', () async {
      String? path;
      final backend = backendWith(MockClient((request) async {
        path = request.url.path;
        return http.Response(
            jsonEncode({
              'success': true,
              'data': {
                'friendId': 'f1',
                'nickname': 'Sam',
                'tag': '12345',
                'sharingEnabled': true,
                'todaySleepMins': '420', // string number tolerated
                'todayScore': 12,
              },
            }),
            200);
      }));
      final body = await backend.fetchFriendDetail('f1');
      expect(path, '/api/friends/data/f1');
      final detail = FriendDetail.fromJson(body?['data']);
      expect(detail?.todaySleepMins, 420);
      expect(detail?.todayScore, 12);
      expect(detail?.sharingEnabled, isTrue);
    });
  });

  group('backend coach endpoints', () {
    test('syncCoachSessions/Messages wrap payloads in native keys',
        () async {
      final seen = <String, Map<String, dynamic>>{};
      final backend = backendWith(MockClient((request) async {
        seen[request.url.path] =
            jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'synced': 1}), 200);
      }));
      expect(
          await backend.syncCoachSessions([
            {'id': 's1', 'title': 'Chat', 'createdAt': 1, 'updatedAt': 2},
          ]),
          isTrue);
      expect(
          await backend.syncCoachMessages([
            {
              'id': 'm1',
              'sessionId': 's1',
              'role': 'user',
              'content': 'hi',
              'timestamp': 3,
            },
          ]),
          isTrue);
      expect(seen['/api/sync/coach_sessions']!.keys, ['sessions']);
      expect(seen['/api/sync/coach_messages']!.keys, ['messages']);
    });

    test('deleteCoachSession DELETEs the session path', () async {
      String? path;
      String? method;
      final backend = backendWith(MockClient((request) async {
        path = request.url.path;
        method = request.method;
        return http.Response(jsonEncode({'success': true}), 200);
      }));
      expect(await backend.deleteCoachSession('s 1'), isTrue);
      expect(method, 'DELETE');
      expect(path, '/api/sync/coach_sessions/s%201');
    });

    test('fetchCoachTitle parses title, null on failure', () async {
      final ok = backendWith(MockClient((request) async {
        expect(request.url.path, '/api/ai/coach/title');
        expect(jsonDecode(request.body), {'firstMessage': 'help me sleep'});
        return http.Response(jsonEncode({'title': 'Sleep Help'}), 200);
      }));
      expect(await ok.fetchCoachTitle('help me sleep'), 'Sleep Help');

      final bad = backendWith(
          MockClient((_) async => http.Response('nope', 500)));
      expect(await bad.fetchCoachTitle('x'), isNull);
    });

    test('classifyCoachNote parses categoryId, null on failure', () async {
      final ok = backendWith(MockClient((request) async {
        expect(request.url.path, '/api/ai/classify-coach-note');
        return http.Response(
            jsonEncode({
              'result': {'categoryId': '3'}, // string tolerated
            }),
            200);
      }));
      expect(await ok.classifyCoachNote('note', {'3': 'Sleep'}), 3);

      final bad = backendWith(
          MockClient((_) async => http.Response('nope', 500)));
      expect(await bad.classifyCoachNote('note', const {}), isNull);
    });

    test('syncDocuments wraps payloads in the documents key', () async {
      Map<String, dynamic>? seen;
      final backend = backendWith(MockClient((request) async {
        seen = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(jsonEncode({'synced': 1}), 200);
      }));
      expect(
          await backend.syncDocuments([
            {'id': 'd1', 'name': 'a.txt'},
          ]),
          isTrue);
      expect(seen!.keys, ['documents']);
    });
  });

  group('friend DTO tolerant parsing', () {
    test('FriendDto parses string level', () {
      final f = FriendDto.fromJson({
        'id': 'f1',
        'nickname': 'Sam',
        'tag': '12345',
        'status': '',
        'level': '77',
      });
      expect(f.level, 77);
    });

    test('FriendNotificationDto parses friendRequestId (num or string)',
        () {
      final n = FriendNotificationDto.fromJson({
        'id': '9',
        'type': 'friend_request',
        'message': 'hi',
        'isRead': false,
        'createdAt': '',
        'friendRequestId': '42',
      });
      expect(n.id, 9);
      expect(n.friendRequestId, 42);
      expect(n.copyWith(isRead: true).isRead, isTrue);
      expect(n.copyWith(isRead: true).friendRequestId, 42);
    });
  });

  // ── Community helpers + widgets ───────────────────────────────────────────

  group('community helpers', () {
    test('isValidFriendTag mirrors native validation', () {
      expect(isValidFriendTag('26385'), isTrue);
      expect(isValidFriendTag('#26385'), isTrue);
      expect(isValidFriendTag(' 26385 '), isTrue);
      expect(isValidFriendTag('2638'), isFalse);
      expect(isValidFriendTag('263855'), isFalse);
      expect(isValidFriendTag('abcde'), isFalse);
      expect(isValidFriendTag(''), isFalse);
    });

    test('leaderboard includes self, sorted by level desc', () {
      final friends = [
        const FriendDto(
            id: 'f1', nickname: 'Sam', tag: '11111', status: '', level: 50),
        const FriendDto(
            id: 'f2', nickname: 'Kim', tag: '22222', status: '', level: 90),
      ];
      final self =
          selfLeaderboardEntry(nickname: '', tag: '', weeklyScore: 70);
      expect(self.nickname, 'You');
      expect(self.tag, '00000');
      final board = buildLeaderboardWithSelf(friends, self);
      expect(board.map((f) => f.id), ['f2', 'me', 'f1']);
    });

    test('friend detail stat formatting mirrors native', () {
      expect(formatFriendSleep(125), '2h5m');
      expect(formatFriendSleep(45), '45m');
      expect(formatFriendSleep(null), '·');
      expect(formatFriendSleepDebt(0), 'None');
      expect(formatFriendSleepDebt(-90), '-1h30m');
      expect(formatFriendSleepDebt(null), '·');
      expect(formatFriendSpikes(1), '1 spike');
      expect(formatFriendSpikes(3), '3 spikes');
      expect(formatFriendSpikes(null), '·');
    });
  });

  group('CommunityToolScreen flows', () {
    MockClient communityClient(List<http.BaseRequest> log) {
      return MockClient((request) async {
        log.add(request);
        switch (request.url.path) {
          case '/api/friends/list':
            return http.Response(
                jsonEncode({
                  'success': true,
                  'friends': [
                    {
                      'id': 'f1',
                      'nickname': 'Sam',
                      'tag': '12345',
                      'status': '',
                      'level': 50,
                    },
                  ],
                }),
                200);
          case '/api/friends/notifications':
            return http.Response(
                jsonEncode({
                  'success': true,
                  'notifications': [
                    {
                      'id': 1,
                      'type': 'friend_request',
                      'message': 'Sam sent you a friend request',
                      'isRead': false,
                      'createdAt': '',
                      'senderNickname': 'Sam',
                      'senderTag': '12345',
                      'friendRequestId': 42,
                    },
                  ],
                }),
                200);
          case '/api/sync/pull':
            return http.Response(
                jsonEncode({
                  'isUnlimited': true,
                  'nickname': 'Me',
                  'tag': '99999',
                  'profile': {'weeklyScore': 70},
                }),
                200);
          case '/api/friends/notifications/read':
            return http.Response(jsonEncode({'success': true}), 200);
          case '/api/friends/respond':
            return http.Response(jsonEncode({'success': true}), 200);
          case '/api/friends/request':
            return http.Response(jsonEncode({'success': true}), 200);
          case '/api/friends/data/f1':
            return http.Response(
                jsonEncode({
                  'success': true,
                  'data': {
                    'friendId': 'f1',
                    'nickname': 'Sam',
                    'tag': '12345',
                    'sharingEnabled': true,
                    'todaySleepMins': 420,
                    'todayAvgHr': 88,
                    'todayScore': 12,
                    'todaySpikes': 1,
                    'todaySleepDebt': 0,
                  },
                }),
                200);
        }
        return http.Response('{}', 404);
      });
    }

    testWidgets('leaderboard shows self; notifications accept works',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpScreen(
          tester,
          CommunityToolScreen(
              backend: backendWith(communityClient(log))));
      expect(find.text('Sam'), findsWidgets);
      expect(find.text('Me'), findsOneWidget); // self leaderboard row

      await tester.tap(find.byIcon(Icons.notifications));
      await tester.pumpAndSettle();
      // Opening the panel marks notifications read (native).
      expect(
          log.any((r) => r.url.path == '/api/friends/notifications/read'),
          isTrue);
      expect(find.text('Accept'), findsOneWidget);
      expect(find.text('Decline'), findsOneWidget);

      await tester.tap(find.text('Accept'));
      await tester.pumpAndSettle();
      final respond = log
          .where((r) => r.url.path == '/api/friends/respond')
          .toList();
      expect(respond, hasLength(1));
      expect(jsonDecode((respond.single as http.Request).body),
          {'requestId': 42, 'action': 'accept'});
    });

    testWidgets('add friend validates then sends', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpScreen(
          tester,
          CommunityToolScreen(
              backend: backendWith(communityClient(log))));
      await tester.tap(find.text('Add Friend'));
      await tester.pumpAndSettle();
      expect(
          find.text("Enter your friend's 5-digit Tag (e.g. 26385)"),
          findsOneWidget);

      await tester.enterText(find.byType(TextField), '123');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Invalid format. Enter a 5-digit Tag (e.g. 26385)'),
          findsOneWidget);
      expect(log.any((r) => r.url.path == '/api/friends/request'),
          isFalse);

      await tester.enterText(find.byType(TextField), '54321');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text('Request sent successfully!'), findsOneWidget);
      final send = log
          .where((r) => r.url.path == '/api/friends/request')
          .toList();
      expect(send, hasLength(1));
      expect(jsonDecode((send.single as http.Request).body),
          {'friendIdString': '54321'});
    });

    testWidgets('friend detail dialog shows shared stats', (tester) async {
      final log = <http.BaseRequest>[];
      await pumpScreen(
          tester,
          CommunityToolScreen(
              backend: backendWith(communityClient(log))));
      await tester.tap(find.text('Sam').first);
      await tester.pumpAndSettle();
      expect(find.text('TODAY'), findsOneWidget);
      expect(find.text('7h0m'), findsOneWidget); // sleep 420m
      expect(find.text('88 bpm'), findsOneWidget);
      expect(find.text('1 spike'), findsOneWidget);
      expect(find.text('12 pts'), findsOneWidget);
      expect(find.text('None'), findsOneWidget); // sleep debt 0
    });

    testWidgets('friend request failure surfaces the server error',
        (tester) async {
      final backend = backendWith(MockClient((request) async {
        switch (request.url.path) {
          case '/api/friends/list':
            return http.Response(
                jsonEncode({'success': true, 'friends': []}), 200);
          case '/api/friends/notifications':
            return http.Response(
                jsonEncode({'success': true, 'notifications': []}), 200);
          case '/api/sync/pull':
            return http.Response(jsonEncode({'profile': {}}), 200);
          case '/api/friends/request':
            return http.Response(
                jsonEncode(
                    {'success': false, 'error': 'User not found'}),
                200);
        }
        return http.Response('{}', 404);
      }));
      await pumpScreen(tester, CommunityToolScreen(backend: backend));
      await tester.tap(find.text('Add Friend'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '54321');
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(find.text('User not found'), findsOneWidget);
      expect(find.text('Request sent successfully!'), findsNothing);
    });
  });

  // ── Health Coach ──────────────────────────────────────────────────────────

  group('coach proposal parsing', () {
    test('note tag parses and strips from display text', () {
      final p = parseCoachMessageContent(
          'Here you go. [PROPOSE_NOTE: drank water] Done.');
      expect(p.cleanContent, 'Here you go.  Done.');
      expect(p.noteText, 'drank water');
      expect(p.noteStatus, CoachProposalStatus.pending);
    });

    test('approved/denied statuses parse', () {
      final p = parseCoachMessageContent('[APPROVED_LIST:Trip|Hat]');
      expect(p.listStatus, CoachProposalStatus.approved);
      expect(p.listName, 'Trip');
      expect(p.listItems, ['Hat']);
      final d = parseCoachMessageContent('[DENIED_REMINDER: Meds|08:00]');
      expect(d.reminderStatus, CoachProposalStatus.denied);
      expect(d.reminderTitle, 'Meds');
      expect(d.reminderTime, '08:00');
    });

    test('calendar + delete tags do not collide', () {
      final p = parseCoachMessageContent(
          '[PROPOSE_DELETE_CALENDAR_EVENT:Dentist|2026-10-20]');
      expect(p.calendarDeleteTitle, 'Dentist');
      expect(p.calendarDeleteDate, '2026-10-20');
      expect(p.calendarTitle, isNull);
      final c = parseCoachMessageContent(
          '[PROPOSE_CALENDAR_EVENT:PT|2026-10-20|02:30 PM|Bring notes]');
      expect(c.calendarTitle, 'PT');
      expect(c.calendarTime, '02:30 PM');
      expect(c.calendarDesc, 'Bring notes');
    });

    test('multiple medication tags collect all meds', () {
      final p = parseCoachMessageContent(
          '[PROPOSE_MEDICATION:Pyridostigmine|Jun 2026||true;Metoprolol|Jan 2025|May 2026|false]');
      expect(p.medicationStatus, CoachProposalStatus.pending);
      expect(p.medications, hasLength(2));
      expect(p.medications.first.name, 'Pyridostigmine');
      expect(p.medications.first.isPresent, isTrue);
      expect(p.medications.first.endDate, 'Present');
      expect(p.medications.last.isPresent, isFalse);
      expect(p.medications.last.endDate, 'May 2026');
    });

    test('plain text parses to no proposals', () {
      final p = parseCoachMessageContent('Just a reply.');
      expect(p.cleanContent, 'Just a reply.');
      expect(pendingProposalKind(p), isNull);
    });

    test('rewriteProposalTag flips the verb, case-insensitively', () {
      expect(
          rewriteProposalTag('x [propose_note: hi]', 'NOTE', 'APPROVED'),
          'x [APPROVED_NOTE: hi]');
      expect(
          rewriteProposalTag(
              '[PROPOSE_MEDICATION:a] [PROPOSE_MEDICATION:b]',
              'MEDICATION',
              'DENIED'),
          '[DENIED_MEDICATION:a] [DENIED_MEDICATION:b]');
    });

    test('pendingProposalKind follows native check order', () {
      final both = parseCoachMessageContent(
          '[PROPOSE_REMINDER: R|08:00] [PROPOSE_NOTE: n]');
      expect(pendingProposalKind(both), 'note');
    });
  });

  group('coach text helpers', () {
    test('cleanCoachDisplayText strips HTML, entities, emphasis', () {
      expect(cleanCoachDisplayText('<p>Hello <b>there</b></p>'),
          'Hello there');
      expect(cleanCoachDisplayText('Fish &amp; Chips &lt;3'),
          'Fish & Chips <3');
      expect(cleanCoachDisplayText('**Bold** and *italic*'),
          'Bold and italic');
      expect(cleanCoachDisplayText('line<br>break'), 'line\nbreak');
    });

    test('text shortcuts mirror native phrase sets', () {
      expect(coachTextShortcut('note', 'Approve'), 'approve');
      expect(coachTextShortcut('note', 'please save it'), 'approve');
      expect(coachTextShortcut('note', "don't save"), 'deny');
      expect(coachTextShortcut('list', 'create it'), 'approve');
      expect(coachTextShortcut('list', "don't create"), 'deny');
      expect(coachTextShortcut('reminder', 'set it'), 'approve');
      expect(coachTextShortcut('reminder', 'ok'), 'approve');
      expect(coachTextShortcut('reminder', 'approve'),
          isNull); // native reminder set has no "approve"
      expect(coachTextShortcut('medication', 'add it'), 'approve');
      expect(coachTextShortcut('medication', "don't add"), 'deny');
      expect(coachTextShortcut('note', 'maybe later'), isNull);
    });

    test('enriched context carries native proposal instructions', () {
      final ctx = coachEnrichedUserContext('BASE',
          now: DateTime(2026, 10, 13, 15, 4));
      expect(ctx, startsWith('BASE\n\n'));
      expect(ctx, contains('SYSTEM RULES FOR PROPOSING ACTIONS:'));
      expect(ctx,
          contains('[PROPOSE_LIST:ListName|Item1|Item2|Item3|...]'));
      expect(ctx, contains('[PROPOSE_REMINDER:Reminder Title|HH:MM]'));
      expect(ctx, contains('[PROPOSE_MEDICATION:'));
      // Juno F1 fix: no calendar connection in this build, so the context
      // carries native's not-connected instruction instead of eliciting
      // calendar proposals it could never fulfil.
      expect(ctx, contains('Do NOT output a [PROPOSE_CALENDAR_EVENT:'));
      expect(ctx, isNot(contains('[PROPOSE_CALENDAR_EVENT:Event Title')));
      expect(ctx, contains('2026-10-13'));
      expect(ctx, contains('Tuesday, October 13, 2026 15:04'));
      final bare = coachEnrichedUserContext(null,
          now: DateTime(2026, 1, 5, 9, 7));
      expect(bare, startsWith('SYSTEM RULES FOR PROPOSING ACTIONS:'));
      expect(bare, contains('Monday, January 05, 2026 09:07'));
    });

    test('parseCoachSessions tolerates string timestamps', () {
      final sessions = parseCoachSessions([
        {'id': 'a', 'title': 'Old', 'updatedAt': '1000'},
        {'id': 'b', 'title': 'New', 'updatedAt': 2000},
        {'title': 'no id'},
      ]);
      expect(sessions.map((s) => s.id), ['b', 'a']);
    });

    test('newUuid produces v4-shaped ids', () {
      final id = newUuid();
      expect(
          RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
              .hasMatch(id),
          isTrue);
      expect(newUuid(), isNot(id));
    });
  });

  group('coach chat flows', () {
    MockClient chatClient(List<http.BaseRequest> log,
        {String reply = 'Here is your list. [PROPOSE_LIST:Groceries|Milk|Eggs]'}) {
      return MockClient((request) async {
        log.add(request);
        switch (request.url.path) {
          case '/api/ai/coach':
            return http.Response(jsonEncode({'result': reply}), 200);
          case '/api/ai/coach/title':
            return http.Response(jsonEncode({'title': 'Groceries'}), 200);
          case '/api/sync/coach_sessions':
          case '/api/sync/coach_messages':
            // Round 57: echo the real batch count, like the restored
            // server handler — a constant 1 hid partial saves.
            final key = request.url.path.endsWith('sessions')
                ? 'sessions'
                : 'messages';
            final batch =
                (jsonDecode(request.body) as Map<String, dynamic>)[key]
                    as List;
            return http.Response(
                jsonEncode({'synced': batch.length}), 200);
          case '/api/sync/pull':
            return http.Response(
                jsonEncode({
                  'isUnlimited': true,
                  'profile': {'userLists': '[]'},
                  'entries': [],
                }),
                200);
          case '/api/sync/profile':
            return http.Response(jsonEncode({'saved': true}), 200);
        }
        return http.Response('{}', 404);
      });
    }

    testWidgets(
        'new chat persists session+messages, proposal card approves to a real list',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpScreen(
        tester,
        CoachChatScreen(backend: backendWith(chatClient(log))),
      );
      // Native greeting for a new session.
      expect(find.textContaining("Hi, I'm Bandit, your Tabs Coach."),
          findsOneWidget);

      await tester.enterText(find.byType(TextField), 'make a list');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();

      // The tag never renders raw; the card shows instead.
      expect(find.textContaining('[PROPOSE_LIST'), findsNothing);
      expect(find.text('Create List?'), findsOneWidget);
      expect(find.text('Create list "Groceries" with items:'),
          findsOneWidget);
      // Session + messages were pushed.
      expect(
          log.any((r) => r.url.path == '/api/sync/coach_sessions'),
          isTrue);
      expect(
          log.any((r) => r.url.path == '/api/sync/coach_messages'),
          isTrue);
      // The AI title replaced "New Chat".
      expect(find.text('Groceries'), findsWidgets);

      await tester.tap(find.text('Approve'));
      await tester.pumpAndSettle();
      // The list write went to the profile's userLists blob.
      final profilePushes = log
          .where((r) => r.url.path == '/api/sync/profile')
          .toList();
      expect(profilePushes, hasLength(1));
      final pushBody = jsonDecode(
          (profilePushes.single as http.Request).body) as Map<String, dynamic>;
      final lists = jsonDecode(pushBody['userLists'] as String) as List;
      expect(lists, [
        {
          'name': 'Groceries',
          'items': ['Milk', 'Eggs'],
        },
      ]);
      expect(find.text('✓ List Created'), findsOneWidget);
      expect(
          find.text('Awesome! I\'ve created the list "Groceries" with 2 items.'),
          findsOneWidget);
    });

    testWidgets('typed shortcut denies a pending proposal',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpScreen(
        tester,
        CoachChatScreen(
          backend: backendWith(chatClient(log)),
          sessionId: 's1',
          sessionTitle: 'Chat',
          initialMessages: const [
            CoachChatMessage(
              id: 'm1',
              sessionId: 's1',
              role: 'coach',
              content: 'Note? [PROPOSE_NOTE: drank water]',
              timestamp: 1,
            ),
          ],
        ),
      );
      expect(find.text('Suggested Note Log'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'deny');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(find.text('✗ Note Dismissed'), findsOneWidget);
      expect(find.text("Okay, I won't save that note."), findsOneWidget);
      // The word "deny" was NOT sent to the coach endpoint.
      expect(log.any((r) => r.url.path == '/api/ai/coach'), isFalse);
    });

    testWidgets('AI failure shows the honest error bubble', (tester) async {
      final backend = backendWith(MockClient((request) async {
        if (request.url.path == '/api/ai/coach') {
          return http.Response('boom', 500);
        }
        return http.Response(jsonEncode({'synced': 1}), 200);
      }));
      await pumpScreen(
        tester,
        CoachChatScreen(
          backend: backend,
          sessionId: 's1',
          sessionTitle: 'Chat',
        ),
      );
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'The coach could not reply right now. Check your connection and try again.'),
          findsOneWidget);
    });

    testWidgets('history delete removes the session via DELETE',
        (tester) async {
      final log = <http.BaseRequest>[];
      final backend = backendWith(MockClient((request) async {
        log.add(request);
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
              jsonEncode({
                'isUnlimited': true,
                'coachSessions': [
                  {
                    'id': 's1',
                    'title': 'My Chat',
                    'createdAt': 1,
                    'updatedAt': 1760000000000,
                  },
                ],
                'coachMessages': [],
              }),
              200);
        }
        if (request.url.path == '/api/sync/coach_sessions/s1') {
          return http.Response(jsonEncode({'success': true}), 200);
        }
        return http.Response('{}', 404);
      }));
      await pumpScreen(tester, HealthCoachScreen(backend: backend));
      expect(find.text('My Chat'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.text('Delete "My Chat"? This cannot be undone.'),
          findsOneWidget);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(
          log.any((r) =>
              r.method == 'DELETE' &&
              r.url.path == '/api/sync/coach_sessions/s1'),
          isTrue);
      expect(find.text('My Chat'), findsNothing);
      expect(find.text('No chats yet.'), findsOneWidget);
    });

    testWidgets('history delete failure keeps the row + shows error',
        (tester) async {
      final backend = backendWith(MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
              jsonEncode({
                'isUnlimited': true,
                'coachSessions': [
                  {
                    'id': 's1',
                    'title': 'My Chat',
                    'createdAt': 1,
                    'updatedAt': 1760000000000,
                  },
                ],
                'coachMessages': [],
              }),
              200);
        }
        return http.Response('nope', 500);
      }));
      await pumpScreen(tester, HealthCoachScreen(backend: backend));
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('My Chat'), findsOneWidget);
      expect(
          find.text(
              'Could not delete that chat. Check your connection and try again.'),
          findsOneWidget);
    });
  });

  // ── Project Focus ─────────────────────────────────────────────────────────

  group('project focus helpers', () {
    test('parseFocusSuggestions skips malformed rows', () {
      expect(
          parseFocusSuggestions([
            {'title': 'A', 'desc': 'a'},
            {'desc': 'no title'},
            'junk',
            {'title': 'B'},
          ]).map((s) => s.title),
          ['A', 'B']);
      expect(parseFocusSuggestions('nope'), isEmpty);
      expect(parseFocusSuggestions(null), isEmpty);
    });

    test('FocusTest tolerates string numbers and round-trips', () {
      final t = FocusTest.fromJson({
        'id': 't1',
        'title': 'Sleep',
        'durationDays': '7',
        'startTimestamp': '1760000000000',
        'logs': {'2026-10-12': true},
      });
      expect(t, isNotNull);
      expect(t!.durationDays, 7);
      final json = t.toJson();
      expect(json['durationDays'], 7);
      expect(json['logs'], {'2026-10-12': true});
      final copy = t.copyWith(logs: {'2026-10-13': false});
      expect(copy.logs, {'2026-10-13': false});
      expect(copy.title, 'Sleep');
    });
  });

  group('ProjectFocusScreen flows', () {
    MockClient focusClient(
      List<http.BaseRequest> log, {
      required Map<String, dynamic> profile,
    }) {
      return MockClient((request) async {
        log.add(request);
        switch (request.url.path) {
          case '/api/sync/pull':
            return http.Response(
                jsonEncode({
                  'isUnlimited': true,
                  'profile': profile,
                  'entries': [],
                  'categories': [],
                }),
                200);
          case '/api/ai/focus-suggestions':
            return http.Response(
                jsonEncode({
                  'result': [
                    {'title': 'Magnesium wind-down', 'desc': 'Take magnesium before bed'},
                    {'title': 'Morning light', 'desc': 'Sunlight within an hour of waking'},
                  ],
                }),
                200);
          case '/api/sync/profile':
            return http.Response(jsonEncode({'saved': true}), 200);
        }
        return http.Response('{}', 404);
      });
    }

    Map<String, dynamic> lastFocusBlob(List<http.BaseRequest> log) {
      final pushes = log
          .where((r) => r.url.path == '/api/sync/profile')
          .toList();
      expect(pushes, isNotEmpty);
      final body = jsonDecode((pushes.last as http.Request).body)
          as Map<String, dynamic>;
      return jsonDecode(body['focusState'] as String)
          as Map<String, dynamic>;
    }

    testWidgets('creation flow: struggle → suggestions → metric → setup → lock-in',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpScreen(
        tester,
        ProjectFocusScreen(
            backend: backendWith(
                focusClient(log, profile: {'focusState': '{}'}))),
      );
      // The Round 18 stub copy is gone; the real input flow renders.
      expect(find.textContaining('coming soon'), findsNothing);
      expect(find.text('What are you trying to work towards?'),
          findsOneWidget);

      await tester.enterText(find.byType(TextField), 'my sleep is bad');
      // One frame so the input rebuilds with Send enabled (its
      // onPressed is gated on the just-typed text) before the tap.
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      // The struggle hit the native suggestions endpoint.
      final suggReq = log
          .where((r) => r.url.path == '/api/ai/focus-suggestions')
          .toList();
      expect(suggReq, hasLength(1));
      expect(jsonDecode((suggReq.single as http.Request).body),
          {'struggle': 'my sleep is bad'});
      expect(find.text('Select a Test'), findsOneWidget);

      await tester.tap(find.text('Magnesium wind-down'));
      await tester.pumpAndSettle();
      expect(find.text('Target Metric'), findsOneWidget);

      await tester.tap(find.text('Sleep Duration 🛌'));
      await tester.pumpAndSettle();
      expect(find.text('Test Duration'), findsOneWidget);
      expect(find.text('7 Days'), findsOneWidget);

      await tester.tap(find.text('Lock it In'));
      // Short pumps only: the splash auto-advances on a 2s timer,
      // which must not fire before the splash assertions.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Test Locked In!'), findsOneWidget);

      final blob = lastFocusBlob(log);
      final tests = blob['activeTests'] as List;
      expect(tests, hasLength(1));
      final test = tests.single as Map<String, dynamic>;
      expect(test['title'], 'Magnesium wind-down');
      expect(test['durationDays'], 7);
      expect(test['measureMetric'], 'sleepMins');
      expect(test['id'], startsWith('test_'));
      expect(blob['selectedTestId'], test['id']);

      // Flush the splash timer so none is pending at test end; the
      // flow lands on the new test's details (lock-in day state).
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(find.text('New test locked in!'), findsOneWidget);
    });

    testWidgets('suggestions failure shows a visible error, stays on input',
        (tester) async {
      final backend = backendWith(MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
              jsonEncode({
                'profile': {'focusState': '{}'},
                'entries': [],
                'categories': [],
              }),
              200);
        }
        return http.Response('boom', 500);
      }));
      await pumpScreen(tester, ProjectFocusScreen(backend: backend));
      await tester.enterText(find.byType(TextField), 'stress');
      // One frame so the input rebuilds with Send enabled (its
      // onPressed is gated on the just-typed text) before the tap.
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Could not load suggestions. Check your connection and try again.'),
          findsOneWidget);
      expect(find.text('Select a Test'), findsNothing);
    });

    testWidgets('check-in Yes logs today; Undo removes it',
        (tester) async {
      final log = <http.BaseRequest>[];
      final start =
          DateTime.now().subtract(const Duration(days: 2));
      final testJson = {
        'id': 'test_1',
        'title': 'Magnesium for sleep',
        'desc': 'Take magnesium',
        'durationDays': 7,
        'startTimestamp': start.millisecondsSinceEpoch,
        'lockDayStr': null,
        'logs': <String, bool>{},
        'measureMetric': 'sleepMins',
      };
      final profile = {
        'focusState': jsonEncode({
          'activeTests': [testJson],
          'activeTest': testJson,
          'selectedTestId': 'test_1',
          'currentSubView': 'details',
        }),
      };
      await pumpScreen(
        tester,
        ProjectFocusScreen(
            backend: backendWith(focusClient(log, profile: profile))),
      );
      expect(find.text('Yes, I did it'), findsOneWidget);
      expect(find.text('Not today'), findsOneWidget);

      await tester.tap(find.text('Yes, I did it'));
      await tester.pumpAndSettle();
      final today = dateStr(DateTime.now());
      var blob = lastFocusBlob(log);
      expect(
          ((blob['activeTests'] as List).single
              as Map<String, dynamic>)['logs'],
          {today: true});
      expect(find.text('Response logged for today!'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      blob = lastFocusBlob(log);
      expect(
          ((blob['activeTests'] as List).single
              as Map<String, dynamic>)['logs'],
          <String, bool>{});
      expect(find.text('Yes, I did it'), findsOneWidget);
    });

    testWidgets('check-in push failure keeps the old state + error',
        (tester) async {
      final start =
          DateTime.now().subtract(const Duration(days: 2));
      final testJson = {
        'id': 'test_1',
        'title': 'Magnesium for sleep',
        'durationDays': 7,
        'startTimestamp': start.millisecondsSinceEpoch,
        'logs': <String, bool>{},
      };
      final backend = backendWith(MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
              jsonEncode({
                'profile': {
                  'focusState': jsonEncode({
                    'activeTests': [testJson],
                    'selectedTestId': 'test_1',
                  }),
                },
                'entries': [],
                'categories': [],
              }),
              200);
        }
        return http.Response('boom', 500);
      }));
      await pumpScreen(tester, ProjectFocusScreen(backend: backend));
      await tester.tap(find.text('Yes, I did it'));
      await tester.pumpAndSettle();
      // No phantom check-in: the buttons are still offered and the
      // failure is visible.
      expect(find.text('Yes, I did it'), findsOneWidget);
      expect(find.text('Response logged for today!'), findsNothing);
      expect(
          find.text(
              'Could not save your check-in. Check your connection and try again.'),
          findsOneWidget);
    });

    testWidgets('cancel experiment removes the test after confirm',
        (tester) async {
      final log = <http.BaseRequest>[];
      final start =
          DateTime.now().subtract(const Duration(days: 2));
      final testJson = {
        'id': 'test_1',
        'title': 'Magnesium for sleep',
        'durationDays': 7,
        'startTimestamp': start.millisecondsSinceEpoch,
        'logs': <String, bool>{},
      };
      final profile = {
        'focusState': jsonEncode({
          'activeTests': [testJson],
          'selectedTestId': 'test_1',
        }),
      };
      await pumpScreen(
        tester,
        ProjectFocusScreen(
            backend: backendWith(focusClient(log, profile: profile))),
      );
      await tester.scrollUntilVisible(find.text('Cancel Experiment'), 200);
      // scrollUntilVisible stops with the button's center just past
      // the surface edge (CI: tap at y=600.6 on a 600px surface would
      // not hit test); ensureVisible brings it fully on screen.
      await tester.ensureVisible(find.text('Cancel Experiment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel Experiment'));
      await tester.pumpAndSettle();
      expect(
          find.text(
              'Are you sure you want to cancel this experiment? This will delete all logged progress for it.'),
          findsOneWidget);
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      final blob = lastFocusBlob(log);
      expect(blob['activeTests'], isEmpty);
      expect(find.text('What are you trying to work towards?'),
          findsOneWidget);
    });
  });

  // ── Tips & Tricks cache ───────────────────────────────────────────────────

  group('tips cache', () {
    test('cached topics/answers decode tolerantly', () {
      expect(decodeCachedTopics('["A?", "B?"]'), ['A?', 'B?']);
      expect(decodeCachedTopics('not json'), isEmpty);
      expect(decodeCachedTopics('{"x":1}'), isEmpty);
      expect(
          decodeCachedAnswers('{"A?": ["t1", "t2"], "B?": "junk"}'),
          {
            'A?': ['t1', 't2'],
          });
      expect(decodeCachedAnswers('[]'), isEmpty);
    });

    test('TipsCacheStore round-trips through injected IO', () async {
      final mem = <String, String>{};
      final store = TipsCacheStore()
        ..debugSetIO(
          read: (key) async => mem[key],
          write: (key, value) async => mem[key] = value,
          delete: (key) async => mem.remove(key),
        );
      await store.saveTopics(['Q1?']);
      await store.saveAnswers({
        'Q1?': ['tip'],
      });
      expect(await store.loadTopics(), ['Q1?']);
      expect(await store.loadAnswers(), {
        'Q1?': ['tip'],
      });
      await store.clearAnswers();
      expect(await store.loadAnswers(), isEmpty);
      expect(await store.loadTopics(), ['Q1?']);
    });

    testWidgets('cached topics render on open without generating',
        (tester) async {
      final mem = <String, String>{
        TipsCacheStore.topicsKey: '["How can I sleep better?"]',
        TipsCacheStore.answersKey:
            '{"How can I sleep better?": ["Keep a consistent wake time"]}',
      };
      final store = TipsCacheStore()
        ..debugSetIO(
          read: (key) async => mem[key],
          write: (key, value) async => mem[key] = value,
          delete: (key) async => mem.remove(key),
        );
      final backend = backendWith(MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
              jsonEncode({'isUnlimited': true, 'profile': {}}), 200);
        }
        return http.Response('{}', 404);
      }));
      await pumpScreen(
        tester,
        TipsTricksScreen(backend: backend, cacheStore: store),
      );
      expect(find.text('How can I sleep better?'), findsOneWidget);
      expect(find.text('Generate Custom Tips'), findsNothing);

      // Cached answer opens without an AI call.
      await tester.tap(find.text('How can I sleep better?'));
      await tester.pumpAndSettle();
      expect(find.text('Keep a consistent wake time'), findsOneWidget);
    });
  });

  // ── Research ──────────────────────────────────────────────────────────────

  group('research', () {
    testWidgets('no-conditions card offers the Profile → Conditions button',
        (tester) async {
      final backend = backendWith(MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
              jsonEncode({'profile': {'conditions': '[]'}}), 200);
        }
        return http.Response('{}', 404);
      }));
      await pumpScreen(
        tester,
        ResearchToolScreen(
          backend: backend,
          bundle: _FakeBundle({
            'AssetManifest.json': '{}',
          }),
        ),
      );
      expect(find.text('No conditions saved yet'), findsOneWidget);
      expect(find.text('Go to Profile → Conditions'), findsOneWidget);
    });

    testWidgets('entries for the selected condition render + expand',
        (tester) async {
      final entry = jsonEncode({
        'id': 'pots_fluids_salt',
        'title': 'Extra fluids and salt for blood volume',
        'summary': 'Summary text',
        'takeaways': ['pair salt with fluids'],
        'detail': 'Long detail text',
        'sourceName': 'Mayo Clinic',
        'sourceUrl': 'https://example.com/source',
        'conditionTags': ['POTS (Postural Orthostatic Tachycardia Syndrome)'],
      });
      final backend = backendWith(MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
              jsonEncode({
                'profile': {
                  'conditions':
                      '["POTS (Postural Orthostatic Tachycardia Syndrome)"]',
                },
              }),
              200);
        }
        return http.Response('{}', 404);
      }));
      await pumpScreen(
        tester,
        ResearchToolScreen(
          backend: backend,
          bundle: _FakeBundle({
            'AssetManifest.json': jsonEncode({
              'assets/research/pots_fluids_salt.json': <String>[],
            }),
            'assets/research/pots_fluids_salt.json': entry,
          }),
        ),
      );
      expect(find.text('Extra fluids and salt for blood volume'),
          findsOneWidget);
      expect(find.text('pair salt with fluids'), findsOneWidget);
      expect(find.text('Long detail text'), findsNothing);
      await tester.tap(find.text('Extra fluids and salt for blood volume'));
      await tester.pumpAndSettle();
      expect(find.text('Long detail text'), findsOneWidget);
    });
  });
}

/// In-memory AssetBundle for research tests (same pattern as the
/// Round 18b tests).
class _FakeBundle extends AssetBundle {
  _FakeBundle(this.strings);

  final Map<String, String> strings;

  @override
  Future<ByteData> load(String key) => throw UnsupportedError('not needed');

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    final s = strings[key];
    if (s == null) throw FlutterError('asset not found: $key');
    return s;
  }
}
