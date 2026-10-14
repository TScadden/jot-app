import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/coach_memory_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';

import 'test_helpers.dart';

/// Round 57 — regression tests for the founder-hit coach save defect:
/// chatting worked, but every save ended in "Could not save this chat
/// to your account…".
///
/// Root cause (server, jot-server PR #4): the May 29 server rewrite
/// dropped `POST /api/sync/coach_sessions`, `POST
/// /api/sync/coach_messages`, the DELETE route, the pull's coach
/// fields, and the coach tables — saves hit the Express 404 handler.
///
/// The fake below implements the RESTORED handlers' semantics,
/// copied from the server code (src/routes/sync.js in jot-server),
/// not the shapes the client wishes for:
/// - request bodies are validated (string ids, string title/content,
///   role `user|coach` only, numeric epoch-ms timestamps) → 400,
/// - messages for an unknown session fail closed → 403,
/// - success is `{synced: n}` counting every row the server holds
///   from the batch, including rows stored by an idempotent retry,
/// - the pull returns sessions/messages with BIGINT timestamps as
///   JSON strings, exactly as node-pg serializes int8.
///
/// Client side of the round: `syncCoachSessions`/`syncCoachMessages`
/// now verify the `synced` count covers the whole batch instead of
/// trusting HTTP 200 alone (the ORIGINAL server handler silently
/// skipped messages whose session check failed while returning 200 —
/// the phantom-save mode pinned by the silent-skip test below, which
/// fails on the pre-fix client).

const String saveFailureBanner = 'Could not save this chat to your '
    'account. Check your connection — it may not appear on your '
    'other devices.';

TabsBackend backendWith(MockClient client, {String? token = 'tok'}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: client, sessionStore: store);
}

CoachMemoryStore memoryStore(Map<String, String> mem) {
  return CoachMemoryStore.withStorage(
    read: (k) async => mem[k],
    write: (k, v) async => mem[k] = v,
    delete: (k) async => mem.remove(k),
  );
}

/// A stateful fake of the restored coach sync handlers.
class FakeCoachServer {
  final Map<String, Map<String, dynamic>> sessions = {};
  final Map<String, Map<String, dynamic>> messages = {};
  final List<http.Request> log = [];

  /// Simulates the deployed pre-fix server: the coach sync routes do
  /// not exist, so every save lands on the 404 handler (whose body is
  /// `{error: 'Route not found: …'}`, copied from src/index.js).
  bool dropCoachRoutes = false;

  /// Simulates the ORIGINAL handler's silent skip: messages whose
  /// session check fails are dropped, yet the response is still
  /// 200 `{synced: 0}`.
  bool skipMessagesSilently = false;

  /// Simulates a genuine server failure on the sessions route.
  bool failSessions = false;

  MockClient get client => MockClient(_handle);

  List<String> get paths => [for (final r in log) r.url.path];

  Future<http.Response> _handle(http.Request request) async {
    log.add(request);
    final path = request.url.path;

    if (dropCoachRoutes && path.startsWith('/api/sync/coach_')) {
      return http.Response(
          jsonEncode(
              {'error': 'Route not found: ${request.method} $path'}),
          404);
    }

    switch (path) {
      case '/api/sync/pull':
        final sessionRows = sessions.values.toList()
          ..sort((a, b) =>
              (b['updatedAt'] as int).compareTo(a['updatedAt'] as int));
        final messageRows = messages.values.toList()
          ..sort((a, b) =>
              (a['timestamp'] as int).compareTo(b['timestamp'] as int));
        return http.Response(
            jsonEncode({
              'isUnlimited': true,
              'isAdmin': true,
              'profile': <String, dynamic>{},
              'entries': [],
              'categories': [],
              // node-pg serializes BIGINT as JSON strings.
              'coachSessions': [
                for (final s in sessionRows)
                  {
                    'id': s['id'],
                    'title': s['title'],
                    'createdAt': '${s['createdAt']}',
                    'updatedAt': '${s['updatedAt']}',
                  },
              ],
              'coachMessages': [
                for (final m in messageRows)
                  {
                    'id': m['id'],
                    'sessionId': m['sessionId'],
                    'role': m['role'],
                    'content': m['content'],
                    'timestamp': '${m['timestamp']}',
                  },
              ],
            }),
            200);
      case '/api/sync/coach_sessions':
        if (failSessions) {
          return http.Response(
              jsonEncode({'error': 'Failed to sync coach sessions'}),
              500);
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final batch = body['sessions'];
        if (batch is! List) {
          return http.Response(
              jsonEncode({'error': 'sessions must be an array'}), 400);
        }
        for (final s in batch) {
          if (s is! Map<String, dynamic> ||
              s['id'] is! String ||
              (s['id'] as String).isEmpty ||
              s['title'] is! String ||
              s['createdAt'] is! num ||
              s['updatedAt'] is! num) {
            return http.Response(
                jsonEncode({'error': 'malformed session'}), 400);
          }
        }
        var synced = 0;
        for (final s in batch) {
          final row = Map<String, dynamic>.from(s as Map);
          sessions[row['id'] as String] = row;
          synced++;
        }
        return http.Response(jsonEncode({'synced': synced}), 200);
      case '/api/sync/coach_messages':
        if (skipMessagesSilently) {
          return http.Response(jsonEncode({'synced': 0}), 200);
        }
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final batch = body['messages'];
        if (batch is! List) {
          return http.Response(
              jsonEncode({'error': 'messages must be an array'}), 400);
        }
        for (final m in batch) {
          if (m is! Map<String, dynamic> ||
              m['id'] is! String ||
              m['sessionId'] is! String ||
              (m['role'] != 'user' && m['role'] != 'coach') ||
              m['content'] is! String ||
              m['timestamp'] is! num) {
            return http.Response(
                jsonEncode({'error': 'malformed message'}), 400);
          }
          if (!sessions.containsKey(m['sessionId'])) {
            return http.Response(
                jsonEncode({
                  'error': 'Message session not found for this account.'
                }),
                403);
          }
        }
        var synced = 0;
        for (final m in batch) {
          final row = Map<String, dynamic>.from(m as Map);
          // Idempotent: a row already stored for the same session
          // counts as synced, exactly like the restored handler.
          messages[row['id'] as String] = row;
          synced++;
        }
        return http.Response(jsonEncode({'synced': synced}), 200);
      case '/api/ai/coach':
        return http.Response(
            jsonEncode({'result': 'Drink water and rest.'}), 200);
      case '/api/ai/coach/title':
        return http.Response(jsonEncode({'title': 'Hydration Chat'}), 200);
    }
    if (request.method == 'DELETE' &&
        path.startsWith('/api/sync/coach_sessions/')) {
      final id = Uri.decodeComponent(path.split('/').last);
      final removed = sessions.remove(id);
      if (removed != null) {
        messages.removeWhere((_, m) => m['sessionId'] == id);
      }
      return http.Response(jsonEncode({'deleted': true}), 200);
    }
    return http.Response('{}', 404);
  }
}

Future<void> pumpChat(
  WidgetTester tester, {
  required TabsBackend backend,
  required Map<String, String> mem,
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
        coachMemoryStore: memoryStore(mem),
        accountEmail: 'user@example.com',
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> sendOneMessage(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField), 'I feel tired');
  await tester.tap(find.byIcon(Icons.send));
  await tester.pumpAndSettle();
}

void main() {
  group('backend synced-count verification', () {
    test('true only when synced covers the whole batch', () async {
      TabsBackend withBody(int status, Object body) =>
          backendWith(MockClient((_) async =>
              http.Response(jsonEncode(body), status)));

      final sessions = [
        {'id': 's1', 'title': 'Chat', 'createdAt': 1, 'updatedAt': 2},
      ];
      expect(await withBody(200, {'synced': 1}).syncCoachSessions(sessions),
          isTrue);
      // A string count is tolerated (int8-style serialization).
      expect(
          await withBody(200, {'synced': '1'})
              .syncCoachSessions(sessions),
          isTrue);
      // Partial, missing, and error outcomes all fail closed.
      expect(await withBody(200, {'synced': 0}).syncCoachSessions(sessions),
          isFalse);
      expect(
          await withBody(200, {'saved': true}).syncCoachSessions(sessions),
          isFalse);
      expect(
          await withBody(404, {'error': 'Route not found: POST x'})
              .syncCoachSessions(sessions),
          isFalse);
      expect(await withBody(500, {'error': 'boom'}).syncCoachSessions(sessions),
          isFalse);
    });

    test('messages: an idempotent retry verifies against the fake',
        () async {
      final server = FakeCoachServer();
      final backend = backendWith(server.client);
      expect(
          await backend.syncCoachSessions([
            {'id': 's1', 'title': 'Chat', 'createdAt': 1, 'updatedAt': 2},
          ]),
          isTrue);
      final batch = [
        {
          'id': 'm1',
          'sessionId': 's1',
          'role': 'user',
          'content': 'hi',
          'timestamp': 3,
        },
        {
          'id': 'm2',
          'sessionId': 's1',
          'role': 'coach',
          'content': 'hello',
          'timestamp': 4,
        },
      ];
      expect(await backend.syncCoachMessages(batch), isTrue);
      // Retry after a lost response: still true, no duplicates.
      expect(await backend.syncCoachMessages(batch), isTrue);
      expect(server.messages, hasLength(2));
    });
  });

  group('chat save sequence against the restored handlers', () {
    testWidgets('first send saves session + messages, no banner',
        (tester) async {
      final server = FakeCoachServer();
      final backend = backendWith(server.client);
      await pumpChat(tester, backend: backend, mem: {});
      await sendOneMessage(tester);

      // The reply rendered and NO save-failure banner fired.
      expect(find.text('Drink water and rest.'), findsOneWidget);
      expect(find.text(saveFailureBanner), findsNothing);

      // The save sequence, in order (the title call is backgrounded
      // by design, so it is checked separately below): session
      // upsert → history+user messages → coach call → session bump
      // → coach message.
      final sequence = [
        for (final p in server.paths)
          if (p != '/api/ai/coach/title') p,
      ];
      expect(sequence, [
        '/api/sync/coach_sessions',
        '/api/sync/coach_messages',
        '/api/ai/coach',
        '/api/sync/coach_sessions',
        '/api/sync/coach_messages',
      ]);
      expect(server.paths, contains('/api/ai/coach/title'));

      // Exact payload shapes (native DTO contract).
      final firstSession = server.log
          .firstWhere((r) => r.url.path == '/api/sync/coach_sessions');
      final sessionBody =
          jsonDecode(firstSession.body) as Map<String, dynamic>;
      expect(sessionBody.keys, ['sessions']);
      final session =
          (sessionBody['sessions'] as List).single as Map<String, dynamic>;
      expect(session.keys.toSet(),
          {'id', 'title', 'createdAt', 'updatedAt'});
      expect(session['id'], isA<String>());
      expect(session['title'], 'New Chat');
      expect(session['createdAt'], isA<int>());
      expect(session['updatedAt'], session['createdAt']);

      final firstMessages = server.log
          .firstWhere((r) => r.url.path == '/api/sync/coach_messages');
      final messagesBody =
          jsonDecode(firstMessages.body) as Map<String, dynamic>;
      expect(messagesBody.keys, ['messages']);
      final sent = messagesBody['messages'] as List;
      expect(sent, hasLength(2)); // welcome + the new user message
      for (final m in sent) {
        final msg = m as Map<String, dynamic>;
        expect(msg.keys.toSet(),
            {'id', 'sessionId', 'role', 'content', 'timestamp'});
        expect(msg['sessionId'], session['id']);
        expect(msg['timestamp'], isA<int>());
      }
      expect([for (final m in sent) (m as Map)['role']],
          ['coach', 'user']);
      expect((sent[1] as Map)['content'], 'I feel tired');
      expect((sent[0] as Map)['content'], coachWelcomeMessage);

      // The server now holds the whole chat, title included.
      expect(server.sessions, hasLength(1));
      expect(server.sessions.values.single['title'], 'Hydration Chat');
      expect(server.messages, hasLength(3));
      expect(
          server.messages.values.map((m) => m['role']),
          containsAllInOrder(['coach', 'user', 'coach']));
    });

    testWidgets('the saved chat appears on another device (fresh pull)',
        (tester) async {
      final server = FakeCoachServer();
      final mem = <String, String>{};
      await pumpChat(
          tester, backend: backendWith(server.client), mem: mem);
      await sendOneMessage(tester);
      expect(find.text(saveFailureBanner), findsNothing);

      // A brand-new backend instance (cold pull cache) over the same
      // server = the second device's view.
      tester.view.physicalSize = const Size(1200, 2000);
      tester.view.devicePixelRatio = 1.0;
      await tester.pumpWidget(
        MaterialApp(
          home: HealthCoachScreen(
            backend: backendWith(server.client),
            coachMemoryStore: memoryStore(mem),
            accountEmail: 'user@example.com',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Hydration Chat'), findsOneWidget);

      await tester.tap(find.text('Hydration Chat'));
      await tester.pumpAndSettle();
      expect(find.text('I feel tired'), findsOneWidget);
      expect(find.text('Drink water and rest.'), findsOneWidget);
      expect(find.text(saveFailureBanner), findsNothing);
    });

    testWidgets(
        'silent-skip 200 (synced 0) still banners — no phantom save',
        (tester) async {
      final server = FakeCoachServer()..skipMessagesSilently = true;
      await pumpChat(
          tester, backend: backendWith(server.client), mem: {});
      await sendOneMessage(tester);
      expect(find.text(saveFailureBanner), findsOneWidget);
      // The coach still replied; only the SAVE is reported failed.
      expect(find.text('Drink water and rest.'), findsOneWidget);
    });

    testWidgets('pre-fix server (404 route shape) banners honestly',
        (tester) async {
      final server = FakeCoachServer()..dropCoachRoutes = true;
      await pumpChat(
          tester, backend: backendWith(server.client), mem: {});
      await sendOneMessage(tester);
      expect(find.text(saveFailureBanner), findsOneWidget);
    });

    testWidgets('genuine 500 on the sessions route banners',
        (tester) async {
      final server = FakeCoachServer()..failSessions = true;
      await pumpChat(
          tester, backend: backendWith(server.client), mem: {});
      await sendOneMessage(tester);
      expect(find.text(saveFailureBanner), findsOneWidget);
    });
  });
}
