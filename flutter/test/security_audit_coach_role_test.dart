// Security Audit wave 2 (Bram) — CoachChatMessage role default hardening.
//
// Wave-1 A10 observation: CoachChatMessage.fromJson defaulted a missing
// 'role' field to 'coach' — the privileged role. Proposal cards render
// only on non-user messages (_ChatBubble: `if (!isUser && !isError)
// ..._proposalWidgets(parsed)`) and the typed approve/deny shortcut in
// _send resolves only when the last real message has role == 'coach'.
// A malformed or crafted stored message that lost its role therefore
// acquired coach privileges by omission. The default is now 'user'
// (non-privileged): no proposal card, no approve-shortcut match.
// Messages with an explicit 'coach' role behave exactly as before.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';

import 'test_helpers.dart';

TabsBackend backendWith(MockClient client, {String? token = 'tok'}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

/// Mock server shaped like tools_r48fix_c_test's: enough for a chat
/// send (coach reply + session/message sync) and for a note-proposal
/// approval (pull + classify + entries post) if a shortcut ever fires.
MockClient serverClient(List<http.BaseRequest> log,
    {String reply = 'OK.'}) {
  return MockClient((request) async {
    log.add(request);
    switch (request.url.path) {
      case '/api/ai/coach':
        return http.Response(jsonEncode({'result': reply}), 200);
      case '/api/ai/coach/title':
        return http.Response(jsonEncode({'title': 'Chat'}), 200);
      case '/api/sync/pull':
        return http.Response(
            jsonEncode({
              'isUnlimited': true,
              'profile': <String, dynamic>{},
              'entries': <dynamic>[],
              'categories': <dynamic>[],
            }),
            200);
      case '/api/sync/profile':
        return http.Response(jsonEncode({'saved': true, 'synced': 1}), 200);
      case '/api/sync/coach_sessions':
      case '/api/sync/coach_messages':
        final key = request.url.path.endsWith('sessions')
            ? 'sessions'
            : 'messages';
        final batch =
            (jsonDecode(request.body) as Map<String, dynamic>)[key] as List;
        return http.Response(jsonEncode({'synced': batch.length}), 200);
      case '/api/ai/classify-coach-note':
        return http.Response(
            jsonEncode({
              'result': {'categoryId': 3},
            }),
            200);
      case '/api/sync/entries':
        return http.Response(jsonEncode({'synced': 1}), 200);
    }
    return http.Response('{}', 404);
  });
}

Future<void> pumpChat(
  WidgetTester tester, {
  required TabsBackend backend,
  required List<CoachChatMessage> messages,
}) async {
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: CoachChatScreen(
        backend: backend,
        notificationService: FakeReminderNotificationService(),
        sessionId: 's1',
        sessionTitle: 'Chat',
        initialMessages: messages,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const proposalContent = 'Note? [PROPOSE_NOTE: drank water]';

/// A stored message whose JSON carries NO role field at all.
CoachChatMessage missingRoleMsg() => CoachChatMessage.fromJson(const {
      'id': 'm1',
      'sessionId': 's1',
      'content': proposalContent,
      'timestamp': 1,
    });

CoachChatMessage explicitCoachMsg() => CoachChatMessage.fromJson(const {
      'id': 'm1',
      'sessionId': 's1',
      'role': 'coach',
      'content': proposalContent,
      'timestamp': 1,
    });

void main() {
  // The sync-pull / habits caches are STATIC and session-keyed (see
  // tools_r48c_test) — reset between cases so one case's cached pull
  // cannot be served to the next.
  setUp(TabsBackend.debugResetSharedCaches);

  group('CoachChatMessage.fromJson role default (security audit)', () {
    test('missing role defaults to the non-privileged user role', () {
      final msg = missingRoleMsg();
      expect(msg.role, 'user');
      expect(msg.role, isNot('coach'));
    });

    test('explicit roles are preserved exactly', () {
      expect(explicitCoachMsg().role, 'coach');
      final user = CoachChatMessage.fromJson(const {
        'id': 'm2',
        'sessionId': 's1',
        'role': 'user',
        'content': 'hi',
        'timestamp': 2,
      });
      expect(user.role, 'user');
    });

    test('a missing-role message still parses its proposal tag — '
        'only the role gate withholds the card', () {
      // The content parse is role-independent; privilege comes from
      // the role checks in rendering and in _send, both keyed off
      // role != 'user' / role == 'coach'.
      expect(pendingProposalKind(missingRoleMsg().parsed), 'note');
      expect(pendingProposalKind(explicitCoachMsg().parsed), 'note');
    });
  });

  group('proposal-card rendering gate', () {
    testWidgets('missing-role message renders NO proposal card',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log)),
        messages: [missingRoleMsg()],
      );
      expect(find.text('Suggested Note Log'), findsNothing);
      expect(find.text('Approve'), findsNothing);
    });

    testWidgets('explicit coach message still renders its proposal card',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log)),
        messages: [explicitCoachMsg()],
      );
      expect(find.text('Suggested Note Log'), findsOneWidget);
      expect(find.text('Approve'), findsOneWidget);
    });
  });

  group('approve-shortcut gate', () {
    testWidgets(
        'typing "approve" against a missing-role message does NOT '
        'resolve the proposal — the text is sent as a chat message',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log)),
        messages: [missingRoleMsg()],
      );
      await tester.enterText(find.byType(TextField), 'approve');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      // The shortcut precondition (last real message role == 'coach')
      // was not met, so the word went to the coach endpoint as an
      // ordinary message and no note write happened.
      expect(log.any((r) => r.url.path == '/api/ai/coach'), isTrue);
      expect(
          log.any((r) => r.url.path == '/api/sync/entries'), isFalse);
      expect(find.text("Great! I've saved that note to your history."),
          findsNothing);
    });

    testWidgets(
        'typing "approve" against an explicit coach message still '
        'resolves the proposal without posting a chat message',
        (tester) async {
      final log = <http.BaseRequest>[];
      await pumpChat(
        tester,
        backend: backendWith(serverClient(log)),
        messages: [explicitCoachMsg()],
      );
      expect(find.text('Suggested Note Log'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'approve');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pumpAndSettle();
      // Shortcut fired: nothing was sent to the coach endpoint, and
      // the note approval completed exactly as before the fix.
      expect(log.any((r) => r.url.path == '/api/ai/coach'), isFalse);
      expect(find.text("Great! I've saved that note to your history."),
          findsOneWidget);
    });
  });
}
