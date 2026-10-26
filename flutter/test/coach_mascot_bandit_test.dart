import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/home/weekly_snapshot_card.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/tools/coach_mascot.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';

import 'test_helpers.dart';

/// Bandit (founder-named Oct 26, 2026) as the Health Coach's face:
/// the name lives in one constant, the greeting/label/hint use it,
/// and the mascot avatar renders in the chat header and thread.

TabsBackend _backend() {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(
    client: MockClient((_) async => http.Response(
        jsonEncode({'success': true, 'result': null}), 200)),
    sessionStore: store,
  );
}

Widget _wrap(Widget child) {
  return MaterialApp(
    home: MediaQuery(
      // Reduced motion: mascot renders static (no timers/controllers),
      // which also keeps the test clock clean.
      data: const MediaQueryData(disableAnimations: true),
      child: child,
    ),
  );
}

void main() {
  test('coach name constant is Bandit and the greeting uses it', () {
    expect(kCoachName, 'Bandit');
    expect(coachWelcomeMessage, startsWith("Hi! I'm Bandit."));
    expect(coachWelcomeMessage, isNot(contains("I'm Tabs Coach")));
  });

  testWidgets('mascot avatar renders from the Bandit asset', (tester) async {
    await tester.pumpWidget(_wrap(const CoachMascotAvatar(size: 36)));
    await tester.pump();
    final image = tester.widget<Image>(find.byType(Image));
    expect((image.image as AssetImage).assetName, kCoachAvatarAsset);
  });

  testWidgets('new chat shows Bandit in header, greeting, label and hint',
      (tester) async {
    await tester.pumpWidget(_wrap(CoachChatScreen(backend: _backend())));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Header avatar.
    expect(find.byType(CoachMascotAvatar), findsWidgets);
    // First-run greeting is Bandit's welcome message.
    expect(find.textContaining("Hi! I'm Bandit."), findsOneWidget);
    // Sender label is the mascot's name (no sparkle label remains).
    expect(find.text('Bandit'), findsOneWidget);
    expect(find.textContaining('Tabs Coach'), findsNothing);
    // Input hint uses the name.
    expect(find.text('Ask Bandit about your health…'), findsOneWidget);
  });

  testWidgets('app-wide: Weekly Snapshot empty state shows Bandit',
      (tester) async {
    await tester.pumpWidget(_wrap(const Scaffold(
      body: Column(children: [WeeklySnapshotCard()]),
    )));
    await tester.pump();
    expect(find.byType(CoachMascotFigure), findsOneWidget);
    expect(find.text('Not enough sleep data yet'), findsOneWidget);
  });

  testWidgets('app-wide: History with no entries shows Bandit',
      (tester) async {
    final store = FakeSessionStore()..token = 'tok';
    final backend = TabsBackend(
      client: MockClient((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
              jsonEncode({
                'isUnlimited': true,
                'entries': [],
                'categories': [],
                'coachSessions': [],
                'coachMessages': [],
              }),
              200);
        }
        return http.Response(jsonEncode({'success': true}), 200);
      }),
      sessionStore: store,
    );
    await tester.pumpWidget(_wrap(HistoryScreen(backend: backend)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CoachMascotFigure), findsOneWidget);
    expect(find.text('No entries yet'), findsOneWidget);
  });
}
