import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';

import 'test_helpers.dart';

/// Clipped first sender label (founder report, VC 100103): in the
/// Capabilities thread the greeting's 'Bandit · Tabs Coach' label
/// rendered sliced in half at the top of the list, flush under the
/// disclaimer banner, after the first exchange.
///
/// Cause: `_scrollToBottom` animated to `maxScrollExtent`
/// unconditionally. When the thread only BARELY overflows the
/// viewport (greeting + one short question + one long answer), that
/// can leave the first message's label row straddling the viewport's
/// top edge — half visible, half clipped.
///
/// Fix contract: the label row spans content offsets 8 (the list's
/// top padding) to 8 + its height (24: 20px avatar + 4 bottom pad).
/// Only when maxScrollExtent falls inside that one-row-tall window
/// does the view stay top-anchored instead of slicing the row. At
/// or below 8 the row is fully visible at the bottom-scroll
/// position; past the window it has fully scrolled away (bubble
/// body straddling the edge is normal chat behavior), and every
/// other flow — notably proposal approvals, which append a
/// confirmation message a screenful down at extents like 153 —
/// still lands at the latest message. (An earlier whole-item
/// threshold broke exactly those approval flows: tools_r48c /
/// tools_r54 confirmation messages landed outside the list's build
/// window and never rendered. The window must stay label-sized.)
///
/// Scenario metrics at the 390x760 test surface (measured on the
/// pre-fix code): a 120-char reply gives maxScrollExtent 16 —
/// inside the (8, 32) window — with the first label's rect at top
/// 177.5 against a ListView top of 184: the label straddles the
/// edge. A 150-char reply gives maxScrollExtent 38, just past the
/// window. A 600-char reply gives maxScrollExtent 632 (genuinely
/// long thread).

TabsBackend _backendFor(String reply) {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient((request) async {
      switch (request.url.path) {
        case '/api/ai/coach':
          return http.Response(jsonEncode({'result': reply}), 200);
        case '/api/sync/coach_sessions':
        case '/api/sync/coach_messages':
          final key =
              request.url.path.endsWith('sessions') ? 'sessions' : 'messages';
          final batch =
              (jsonDecode(request.body) as Map<String, dynamic>)[key] as List;
          return http.Response(jsonEncode({'synced': batch.length}), 200);
      }
      return http.Response('{}', 200);
    }),
    sessionStore: store,
  );
}

Future<void> _sendOneExchange(WidgetTester tester, String reply) async {
  tester.view.physicalSize = const Size(390, 760);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(MaterialApp(
    home: MediaQuery(
      // Reduced motion: the mascot renders static, keeping the test
      // clock clean (same wrap as coach_mascot_bandit_test).
      data: const MediaQueryData(disableAnimations: true),
      child: CoachChatScreen(
        backend: _backendFor(reply),
        notificationService: FakeReminderNotificationService(),
        accountEmail: 'user@example.com',
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'What can you do?');
  await tester.tap(find.byIcon(Icons.send));
  await tester.pumpAndSettle();
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  testWidgets(
      'small overflow: first sender label stays fully visible after reply',
      (tester) async {
    await _sendOneExchange(tester, List.filled(120, 'x').join());

    final listRect = tester.getRect(find.byType(ListView));
    final labels = find.text('Bandit · Tabs Coach');
    expect(labels, findsNWidgets(2),
        reason: 'greeting + reply labels both render');
    final firstLabel = tester.getRect(labels.first);
    expect(firstLabel.top, greaterThanOrEqualTo(listRect.top),
        reason:
            'first label must not straddle the viewport top edge: '
            'label=$firstLabel listTop=${listRect.top}');
    expect(firstLabel.bottom, lessThanOrEqualTo(listRect.bottom),
        reason: 'first label must be fully inside the viewport');

    final pos =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(pos.maxScrollExtent, greaterThan(0),
        reason: 'scenario must actually overflow (barely)');
    expect(pos.pixels, 0,
        reason: 'small-overflow threads stay top-anchored');
  });

  testWidgets(
      'just past the label window: send still scrolls to the bottom',
      (tester) async {
    await _sendOneExchange(tester, List.filled(150, 'x').join());

    final pos =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(pos.maxScrollExtent, greaterThan(32),
        reason: 'scenario must sit just past the (8, 32) label window; '
            'got ${pos.maxScrollExtent}');
    expect(pos.pixels, pos.maxScrollExtent,
        reason: 'outside the label window the view still lands at '
            'the latest message');
  });

  testWidgets('long thread: send still scrolls to the latest message',
      (tester) async {
    await _sendOneExchange(tester, List.filled(600, 'x').join());

    final pos =
        tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    expect(pos.maxScrollExtent, greaterThan(200),
        reason: 'scenario must be a genuinely long thread');
    expect(pos.pixels, pos.maxScrollExtent,
        reason: 'long threads still land at the bottom');
    // The reply (last message) reaches the bottom of the viewport:
    // its text ends at the viewport's bottom edge (less the list's
    // bottom padding). The reply's own sender label has scrolled
    // fully past — normal chat behavior for a long message.
    final listRect = tester.getRect(find.byType(ListView));
    final replyText = tester.getRect(find.textContaining('xxxx'));
    expect(replyText.bottom, lessThanOrEqualTo(listRect.bottom));
    expect(replyText.bottom, greaterThan(listRect.bottom - 40));
  });
}
