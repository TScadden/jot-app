import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';
import 'package:tabs_lab/src/features/tools/notes_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Founder bug (Nov 2, 2026, VC 100112): "when we start typing in the
/// note area it only shows our first letter or so. Everything gets
/// logged fine but the visual is not right."
///
/// These tests type character-by-character into every prime free-note
/// surface and assert what the field DISPLAYS after each keystroke
/// (the TextField's controller / editing value AND the field's
/// rendered width), not merely what a save would persist.

const _typed = 'Feeling dizzy today';

/// Types [text] one character at a time into the field matched by
/// [field], asserting after EVERY keystroke that the field's
/// displayed editing value equals everything typed so far.
Future<void> _typePerChar(
  WidgetTester tester,
  Finder field,
  String text,
) async {
  await tester.tap(field);
  await tester.pump();
  final widthBefore = tester.getSize(field).width;
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
  final widthAfter = tester.getSize(field).width;
  expect(
    widthAfter,
    greaterThan(widthBefore * 0.75),
    reason: 'field width must not collapse while typing '
        '(was $widthBefore, now $widthAfter)',
  );
}

TabsBackend _backend(MockClientHandler handler) {
  final store = FakeSessionStore()..token = 'test-token';
  return TabsBackend(client: MockClient(handler), sessionStore: store);
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  group('note typing display', () {
    testWidgets('Quick Log details field shows every typed character',
        (tester) async {
      const cat = QuickLogCategory(
        id: 3,
        name: 'Symptoms',
        icon: 'circle',
        colorHex: '#4ECDC4',
        isDefault: true,
        sortOrder: 0,
      );
      final backend = _backend((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': <dynamic>[],
              'categories': [cat.toSyncJson()],
              'profile': <String, dynamic>{},
              'isUnlimited': true,
              'isAdmin': false,
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      await tester.pumpWidget(
        MaterialApp(home: QuickLogScreen(backend: backend)),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
      // The "Your quick note" preview must show the full text too.
      expect(find.text(_typed), findsOneWidget);
    });

    testWidgets('Notes compose body shows every typed character',
        (tester) async {
      final backend = _backend((_) async => http.Response(
            jsonEncode({
              'profile': {'userLists': '[]'},
            }),
            200,
          ));
      await tester.pumpWidget(
        MaterialApp(home: NotesScreen(backend: backend)),
      );
      await tester.pumpAndSettle();
      // Compose card: title field first, body field second.
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      await _typePerChar(tester, fields.at(1), _typed);
    });

    testWidgets('History Edit Entry Text shows every typed character',
        (tester) async {
      final entry = <String, dynamic>{
        'id': 42,
        'categoryId': 3,
        'body': 'Brain fog all morning',
        'chips': '["Symptoms"]',
        'manualText': '',
        'timestamp': DateTime(2026, 10, 12, 9, 30).millisecondsSinceEpoch,
      };
      final backend = _backend((request) async {
        if (request.url.path == '/api/sync/pull') {
          return http.Response(
            jsonEncode({
              'entries': [entry],
              'categories': [
                {
                  'id': 3,
                  'name': 'Symptoms',
                  'icon': 'circle',
                  'colorHex': '#4ECDC4',
                  'isDefault': true,
                  'sortOrder': 1,
                },
              ],
              'profile': <String, dynamic>{},
              'isUnlimited': true,
              'isAdmin': false,
            }),
            200,
          );
        }
        return http.Response('{}', 200);
      });
      await tester.pumpWidget(
        MaterialApp(home: HistoryScreen(backend: backend)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Brain fog all morning'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit Entry Text'), findsOneWidget);
      final field = find.byKey(const ValueKey('entry_text_editor'));
      await _typePerChar(tester, field, _typed);
    });

    testWidgets('Settings Personal Context shows every typed character',
        (tester) async {
      final backend = r29.FakeSettingsBackend()
        ..pullBody = r29.pull(profile: {'userContext': ''});
      await r29.pumpSettings(
        tester,
        r29.host(
          r29.screen(
            backend: backend,
            store: r29.fakeStore(<String, String>{
              'settings_user_context_hidden': 'false',
            }),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('personal_context_field'));
      expect(field, findsOneWidget);
      await _typePerChar(tester, field, _typed);
      // Save path unchanged: after the 3 s debounce exactly one push
      // carries the FULL typed text.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(backend.profilePushes, [
        equals({'userContext': _typed}),
      ]);
    });
  });
}
