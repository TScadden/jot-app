import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/tools/food_screen.dart';
import 'package:tabs_lab/src/features/tools/habits_screen.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';
import 'package:tabs_lab/src/features/tools/lists_screen.dart';
import 'package:tabs_lab/src/features/tools/notes_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Sweep round 2 for the founder note-typing display bug (Nov 2,
/// 2026): per-character typing into every remaining free-note surface
/// not covered by note_typing_display_test.dart, asserting the
/// DISPLAYED editing value after every keystroke.

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
    final editable = tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    expect(
      editable.controller.text,
      prefix,
      reason: 'rendered EditableText after $i char(s) of "$text"',
    );
  }
}

TabsBackend _backend(MockClientHandler handler, {String? token = 'tok'}) {
  final store = FakeSessionStore()..token = token;
  return TabsBackend(client: MockClient(handler), sessionStore: store);
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  group('note typing display sweep', () {
    testWidgets('Notes EDIT dialog body shows every typed character',
        (tester) async {
      final backend = _backend((_) async => http.Response(
            jsonEncode({
              'profile': {
                'userLists': jsonEncode([
                  {
                    'name': '__user_notes__',
                    'items': [
                      'Evening note_||_Heart rate spike_||_1720000000000',
                    ],
                  },
                ]),
              },
            }),
            200,
          ));
      await _pump(tester, NotesScreen(backend: backend));
      await tester.tap(find.text('Evening note'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Note'), findsOneWidget);
      final fields = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      expect(fields, findsNWidgets(2));
      // Body is the second field; clear the seed first, then type.
      await tester.enterText(fields.at(1), '');
      await _typePerChar(tester, fields.at(1), _typed);
    });

    testWidgets('Lists add-item field shows every typed character',
        (tester) async {
      final backend = _backend((_) async => http.Response(
            jsonEncode({
              'profile': {
                'userLists': jsonEncode([
                  {
                    'name': 'Groceries',
                    'items': ['Eggs'],
                  },
                ]),
              },
            }),
            200,
          ));
      await _pump(tester, ListsScreen(backend: backend));
      expect(find.text('Groceries'), findsOneWidget);
      final field = find.widgetWithText(TextField, 'Add an item...');
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
    });

    testWidgets('Habits add field shows every typed character',
        (tester) async {
      final backend = _backend((_) async => http.Response(
            jsonEncode({'habits': []}),
            200,
          ));
      await _pump(tester, HabitsScreen(backend: backend));
      final field =
          find.widgetWithText(TextField, 'Add new routine habit...');
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
    });

    testWidgets('Food input shows every typed character', (tester) async {
      final backend = _backend((_) async => http.Response('{}', 200));
      await _pump(tester, FoodToolScreen(backend: backend));
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
    });

    testWidgets('Coach chat input shows every typed character',
        (tester) async {
      final backend = _backend((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'isUnlimited': true,
              'coachSessions': [
                {
                  'id': 's1',
                  'title': 'Chat',
                  'createdAt': 1,
                  'updatedAt': 1760000000000,
                },
              ],
              'coachMessages': [],
            }),
            200,
          );
        }
        return http.Response(jsonEncode({'synced': 1}), 200);
      });
      await _pump(
        tester,
        CoachChatScreen(
          backend: backend,
          sessionId: 's1',
          sessionTitle: 'Chat',
        ),
      );
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
    });

    testWidgets('Settings Add Text Note dialog shows every character',
        (tester) async {
      final backend = r29.FakeSettingsBackend()
        ..pullBody = r29.pull(profile: {});
      await r29.pumpSettings(
        tester,
        r29.host(
          r29.screen(
            backend: backend,
            store: r29.fakeStore(<String, String>{}),
          ),
        ),
      );
      await tester.tap(find.text('AI & Clinical Advocate'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('add_text_note_button')));
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('note_body_field'));
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
    });
  });
}
