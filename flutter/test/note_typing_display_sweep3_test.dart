import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/onboarding/profile_setup_screen.dart';
import 'package:tabs_lab/src/features/tools/medications_screen.dart';
import 'package:tabs_lab/src/features/tools/project_focus_screen.dart';
import 'package:tabs_lab/src/features/tools/reminders_screen.dart';

import 'test_helpers.dart';

/// Sweep round 3 for the founder note-typing display bug (Nov 2,
/// 2026): the remaining free-text surfaces — Project Focus struggle
/// field, Reminders editor title, Medications editor name, and the
/// onboarding profile-context field — typed into character by
/// character, asserting the DISPLAYED value after every keystroke.

const _typed = 'Feeling dizzy today';

Future<void> _typePerChar(
  WidgetTester tester,
  Finder field,
  String text,
) async {
  await tester.tap(field);
  await tester.pump();
  for (var i = 1; i <= text.length; i++) {
    final prefix = text.substring(0, i);
    await tester.enterText(field, prefix);
    await tester.pump();
    final tf = tester.widget<TextField>(field);
    expect(
      tf.controller!.text,
      prefix,
      reason: 'displayed text after $i char(s) of "$text"',
    );
  }
}

TabsBackend _backend(MockClientHandler handler) {
  final store = FakeSessionStore()..token = 'tok';
  return TabsBackend(client: MockClient(handler), sessionStore: store);
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  group('note typing display sweep 3', () {
    testWidgets('Project Focus struggle field shows every character',
        (tester) async {
      final backend = _backend((_) async => http.Response(
            jsonEncode({'profile': <String, dynamic>{}}),
            200,
          ));
      await _pump(tester, ProjectFocusScreen(backend: backend));
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
    });

    testWidgets('Reminders editor title shows every character',
        (tester) async {
      final backend = _backend((_) async => http.Response(
            jsonEncode({
              'profile': {'reminders': '[]'},
            }),
            200,
          ));
      await _pump(
        tester,
        RemindersScreen(
          backend: backend,
          notificationService: FakeReminderNotificationService(),
        ),
      );
      await tester.tap(find.text('New Reminder'));
      await tester.pumpAndSettle();
      // Create-permission gate: rationale dialog first.
      await tester.tap(find.text('Allow'));
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
    });

    testWidgets('Medications editor name shows every character',
        (tester) async {
      final backend = _backend((_) async => http.Response(
            jsonEncode({
              'profile': {'medications': '[]'},
            }),
            200,
          ));
      await _pump(tester, MedicationsScreen(backend: backend));
      await tester.tap(find.byKey(const ValueKey('add_medication')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('med_edit_name'));
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
    });

    testWidgets('Onboarding profile context shows every character',
        (tester) async {
      final backend = _backend((_) async => http.Response(
            jsonEncode({'profile': <String, dynamic>{}}),
            200,
          ));
      await _pump(
        tester,
        ProfileSetupScreen(
          onBack: () {},
          onNavigateNext: () {},
          backend: backend,
        ),
      );
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
      // Flush the screen's 3 s prompt-rotation loop before the test
      // ends: unmount (dispose stops the loop) and advance past the
      // in-flight delay so no fake timer is left pending.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    });
  });
}
