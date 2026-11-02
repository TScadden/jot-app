import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/quicklog/history_screen.dart';
import 'package:tabs_lab/src/features/quicklog/quick_log_screen.dart';
import 'package:tabs_lab/src/features/tools/health_coach_screen.dart';
import 'package:tabs_lab/src/features/tools/notes_screen.dart';

import 'settings_r29_test.dart' as r29;
import 'test_helpers.dart';

/// Founder note-typing display bug — DEVICE-CONDITIONS pass
/// (coordinator acceptance check, Nov 2, 2026).
///
/// The first pass typed with `tester.enterText` (whole-string
/// replacement, desktop-size surface, no keyboard). This pass
/// re-checks the five highest-likelihood surfaces under the
/// conditions that pass could not see:
///
/// - A phone viewport (Pixel-class 1080x2424 physical, DPR 2.625)
///   with the software keyboard OPEN: `viewInsets.bottom = 800`
///   physical (~305 logical), so Scaffolds resize exactly as on
///   device; for Quick Log the inset is ANIMATED in (0→800 in
///   steps) while the first characters are typed.
/// - Gboard-style incremental IME updates through
///   `TestTextInput.updateEditingValue` — the real
///   platform→framework channel — carrying COMPOSING ranges: the
///   current word stays composing while it is typed, a space
///   commits it (composing clears), and one mid-word AUTOCORRECT
///   rewrite replaces the composing word in place.
/// - Assertions are render-level, not just controller-level: the
///   RenderEditable's painted text must equal the full string
///   after EVERY update, and the field must sit above the keyboard
///   region at full phone width. The end-of-text caret must lie
///   inside the visible viewport at every word commit and after a
///   final settle — the points where a user actually looks at the
///   field. (Mid-word, the framework's own caret reveal — a
///   post-frame-scheduled 100 ms animation, editable_text.dart
///   _scheduleShowCaretOnScreen — is still chasing the caret;
///   fake-async pumps starve that animation between keystrokes in
///   a way real 60-120 Hz frames do not, so mid-word caret
///   position is not asserted. What IS asserted mid-word is the
///   full painted text, which is what "the display holds what I
///   typed" means.)

const _typed = 'Feeling dizzy today';

// Pixel-class geometry used by every test in this file.
const _physW = 1080.0;
const _physH = 2424.0;
const _dpr = 2.625;
const _kbPhys = 800.0;
double get _kbTopLogical => (_physH - _kbPhys) / _dpr;

void _phoneViewport(WidgetTester tester, {double kbBottom = _kbPhys}) {
  tester.view.physicalSize = const Size(_physW, _physH);
  tester.view.devicePixelRatio = _dpr;
  tester.view.viewInsets = FakeViewPadding(bottom: kbBottom);
  addTearDown(tester.view.reset);
}

/// A Gboard-like typer: drives one field through
/// TestTextInput.updateEditingValue with composing ranges, and
/// asserts the DISPLAY (controller, rendered painter text, caret
/// visibility, on-screen geometry) after every single update.
class _Gboard {
  _Gboard(this.tester, this.field, {required this.label});

  final WidgetTester tester;
  final Finder field;
  final String label;
  String _text = '';
  int _wordStart = 0;

  Finder get _editable =>
      find.descendant(of: field, matching: find.byType(EditableText));

  Future<void> begin() async {
    await tester.showKeyboard(field);
    await tester.pump();
    _text = tester.widget<TextField>(field).controller!.text;
    _wordStart = _text.length;
    _assertShown('focus');
  }

  Future<void> _pumpSend(
    TextEditingValue value,
    String step, {
    bool caret = false,
  }) async {
    tester.testTextInput.updateEditingValue(value);
    await tester.pump(const Duration(milliseconds: 150));
    _assertShown(step, caret: caret);
  }

  /// Lets the framework's caret-reveal animation finish (the user
  /// paused): 400 ms across 8 frames — an animation only advances
  /// one step per pumped frame in fake async, however long each
  /// pump's duration is.
  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    _assertShown('settled after pause', caret: true);
  }

  /// Types [s] character by character, Gboard-style: the current
  /// word is carried in the composing range; a space commits the
  /// word (a second update with the composing range cleared).
  Future<void> type(String s) async {
    for (var k = 0; k < s.length; k++) {
      final c = s[k];
      _text += c;
      if (c == ' ') {
        await _pumpSend(
          TextEditingValue(
            text: _text,
            selection: TextSelection.collapsed(offset: _text.length),
          ),
          'commit word at ${_text.length}',
          caret: true,
        );
        _wordStart = _text.length;
      } else {
        await _pumpSend(
          TextEditingValue(
            text: _text,
            selection: TextSelection.collapsed(offset: _text.length),
            composing: TextRange(start: _wordStart, end: _text.length),
          ),
          'compose "${_text.substring(_wordStart)}"',
        );
      }
    }
  }

  /// Re-sends the current value unchanged (Gboard does this when
  /// its composing underline refreshes) — must be a display no-op.
  Future<void> resend() async {
    await _pumpSend(
      TextEditingValue(
        text: _text,
        selection: TextSelection.collapsed(offset: _text.length),
        composing: TextRange(start: _wordStart, end: _text.length),
      ),
      'composing resend',
    );
  }

  /// Gboard autocorrect: the composing word [wrong] is replaced by
  /// [right] in a single update, text before the word untouched.
  Future<void> autocorrect(String wrong, String right) async {
    expect(_text.substring(_wordStart), wrong,
        reason: '$label: autocorrect precondition');
    _text = _text.substring(0, _wordStart) + right;
    await _pumpSend(
      TextEditingValue(
        text: _text,
        selection: TextSelection.collapsed(offset: _text.length),
        composing: TextRange(start: _wordStart, end: _text.length),
      ),
      'autocorrect $wrong→$right',
    );
  }

  /// Select-all + delete, as a user clearing a seeded editor.
  Future<void> clearAll() async {
    _text = '';
    _wordStart = 0;
    await _pumpSend(
      const TextEditingValue(
        text: '',
        selection: TextSelection.collapsed(offset: 0),
      ),
      'clear all',
    );
  }

  void _assertShown(String step, {bool caret = false}) {
    final where = '$label [$step]';
    final tf = tester.widget<TextField>(field);
    expect(tf.controller!.text, _text, reason: '$where: controller');
    final editable = tester.widget<EditableText>(_editable);
    expect(editable.controller.text, _text,
        reason: '$where: EditableText controller');
    // Render level: what the painter actually holds.
    final ro = tester.state<EditableTextState>(_editable).renderEditable;
    expect(ro.text!.toPlainText(), _text,
        reason: '$where: RenderEditable painted text');
    // At word commits and after a pause, the caret (end of text)
    // must be inside the visible viewport — if the scroll offset
    // were stuck at 0 in a single-line field, the user would see
    // the FIRST letters and not the caret (the founder's symptom
    // shape). getLocalRectForCaret already returns viewport-local
    // coordinates (the render object folds its scroll offset into
    // the rect), so the rect is compared to the size directly.
    if (caret) {
      final caretRect =
          ro.getLocalRectForCaret(TextPosition(offset: _text.length));
      if (tf.maxLines == 1) {
        expect(caretRect.left, greaterThanOrEqualTo(-1.0),
            reason:
                '$where: caret left of viewport (x=${caretRect.left})');
        expect(caretRect.left, lessThanOrEqualTo(ro.size.width + 1.0),
            reason: '$where: caret right of viewport '
                '(x=${caretRect.left}, w=${ro.size.width}) — end of '
                'text not visible');
      } else {
        expect(caretRect.top, greaterThanOrEqualTo(-1.0),
            reason:
                '$where: caret above viewport (y=${caretRect.top})');
        expect(caretRect.top, lessThanOrEqualTo(ro.size.height + 1.0),
            reason: '$where: caret below viewport '
                '(y=${caretRect.top}, h=${ro.size.height}) — end of '
                'text not visible');
      }
    }
    // Geometry on the phone surface: full-width field, and no part
    // of it hidden under the keyboard region.
    final rect = tester.getRect(field);
    expect(rect.width, greaterThan(150),
        reason: '$where: field width collapsed (${rect.width})');
    expect(rect.bottom, lessThanOrEqualTo(_kbTopLogical + 2),
        reason: '$where: field bottom ${rect.bottom} is under the '
            'keyboard (top at $_kbTopLogical)');
  }
}

TabsBackend _backend(MockClientHandler handler) {
  final store = FakeSessionStore()..token = 'test-token';
  return TabsBackend(client: MockClient(handler), sessionStore: store);
}

void main() {
  setUp(TabsBackend.debugResetSharedCaches);

  group('note typing display — device conditions', () {
    testWidgets(
        'Quick Log details: keyboard animates in while Gboard '
        'composing + autocorrect types the note', (tester) async {
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
      // Larger system text, as an accessibility-set phone would run.
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(
          () => tester.platformDispatcher.clearTextScaleFactorTestValue());
      _phoneViewport(tester, kbBottom: 0);
      await tester.pumpWidget(
        MaterialApp(home: QuickLogScreen(backend: backend)),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      final g = _Gboard(tester, field, label: 'quicklog');
      await g.begin();
      // Keyboard opening animation: the inset grows 0→800 physical
      // in 5 steps while the first five characters land.
      const steps = [160.0, 320.0, 480.0, 640.0, 800.0];
      const firstChars = ['F', 'e', 'e', 'l', 'i'];
      for (var i = 0; i < steps.length; i++) {
        tester.view.viewInsets = FakeViewPadding(bottom: steps[i]);
        await tester.pump(const Duration(milliseconds: 50));
        await g.type(firstChars[i]);
      }
      await g.type('ng dizzu');
      await g.resend();
      await g.autocorrect('dizzu', 'dizzy');
      await g.type(' today');
      await g.settle();
      expect(find.text(_typed), findsOneWidget,
          reason: 'quick-note preview shows the full typed text');
    });

    testWidgets('Notes compose body: keyboard open, Gboard composing',
        (tester) async {
      final backend = _backend((_) async => http.Response(
            jsonEncode({
              'profile': {'userLists': '[]'},
            }),
            200,
          ));
      _phoneViewport(tester);
      await tester.pumpWidget(
        MaterialApp(home: NotesScreen(backend: backend)),
      );
      await tester.pumpAndSettle();
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(2));
      final g = _Gboard(tester, fields.at(1), label: 'notes-compose');
      await g.begin();
      await g.type('Feeling dizzu');
      await g.autocorrect('dizzu', 'dizzy');
      await g.resend();
      await g.type(' today');
      await g.settle();
    });

    testWidgets(
        'Personal Context: keyboard open, Gboard composing, '
        'debounced save still carries the full text', (tester) async {
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
      // r29's harness uses a tall desktop surface; re-frame as the
      // phone with the keyboard open before touching the field.
      _phoneViewport(tester);
      await tester.pump();
      final field = find.byKey(const ValueKey('personal_context_field'));
      expect(field, findsOneWidget);
      final g = _Gboard(tester, field, label: 'personal-context');
      await g.begin();
      await g.type('Feeling dizzu');
      await g.autocorrect('dizzu', 'dizzy');
      await g.type(' today');
      await g.settle();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(backend.profilePushes, [
        equals({'userContext': _typed}),
      ]);
    });

    testWidgets(
        'History Edit Entry Text: keyboard open, clear the seed, '
        'Gboard composing types the replacement', (tester) async {
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
      _phoneViewport(tester);
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
      final g = _Gboard(tester, field, label: 'history-edit');
      await g.begin();
      await g.clearAll();
      await g.type('Feeling dizzu');
      await g.autocorrect('dizzu', 'dizzy');
      await g.type(' today');
      await g.settle();
    });

    testWidgets(
        'Coach chat input: keyboard open (bar must ride above it), '
        'Gboard composing', (tester) async {
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
      _phoneViewport(tester);
      await tester.pumpWidget(
        MaterialApp(
          home: CoachChatScreen(
            backend: backend,
            sessionId: 's1',
            sessionTitle: 'Chat',
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      final g = _Gboard(tester, field, label: 'coach');
      await g.begin();
      await g.type('Feeling dizzu');
      await g.resend();
      await g.autocorrect('dizzu', 'dizzy');
      await g.type(' today');
      await g.settle();
    });
  });
}
