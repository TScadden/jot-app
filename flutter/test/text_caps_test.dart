import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/text_caps.dart';
import 'package:tabs_lab/src/theme/notel_theme.dart';

/// GAP-9 (Nov 27, 2026) — Juno's ruling, client side:
/// - the cap numbers are exactly §1's;
/// - the counter format is exactly `{current} / {cap}`;
/// - prose counters are always visible; label counters appear
///   only within 20 chars of the cap;
/// - at the cap the exact string "You've hit the character
///   limit for this field." shows;
/// - typed/pasted text is never silently cut WITHOUT the cut
///   being visible: an over-cap paste stops at the cap AND the
///   full counter + at-cap line are on screen.
void main() {
  test('cap numbers match Juno §1 exactly', () {
    expect(TextCaps.personalContext, 10000);
    expect(TextCaps.knowledgeBase, 262144);
    expect(TextCaps.professionalUpdates, 20000);
    expect(TextCaps.redditSummaries, 65536);
    expect(TextCaps.logEntryBody, 10000);
    expect(TextCaps.logEntryManualText, 10000);
    expect(TextCaps.noteBody, 10000);
    expect(TextCaps.noteTitle, 200);
    expect(TextCaps.categoryName, 100);
    expect(TextCaps.itemName, 100);
    expect(TextCaps.nickname, 50);
    expect(TextCaps.atCapMessage,
        "You've hit the character limit for this field.");
  });

  /// A field wired exactly the way the production screens wire
  /// capped fields: maxLength + LengthLimiting formatter,
  /// built-in counter suppressed, CapCounter below.
  Widget field({
    required TextEditingController controller,
    required int cap,
    bool labelStyle = false,
  }) {
    return MaterialApp(
      theme: notelDarkTheme(),
      home: Scaffold(
        body: Column(
          children: [
            TextField(
              controller: controller,
              maxLength: cap,
              inputFormatters: [LengthLimitingTextInputFormatter(cap)],
              decoration: const InputDecoration(counterText: ''),
            ),
            CapCounter(
              controller: controller,
              cap: cap,
              labelStyle: labelStyle,
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('prose counter is always visible, Juno format',
      (tester) async {
    final c = TextEditingController();
    await tester.pumpWidget(field(controller: c, cap: 10000));
    expect(find.text('0 / 10000'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();
    expect(find.text('5 / 10000'), findsOneWidget);
    expect(find.text(TextCaps.atCapMessage), findsNothing);
  });

  testWidgets('label counter appears only within 20 of the cap',
      (tester) async {
    final c = TextEditingController();
    await tester.pumpWidget(
        field(controller: c, cap: TextCaps.nickname, labelStyle: true));
    // 29 chars: outside the window (50 - 20 = 30 threshold).
    await tester.enterText(find.byType(TextField), 'a' * 29);
    await tester.pump();
    expect(find.text('29 / 50'), findsNothing);
    // 30 chars: first length inside the window.
    await tester.enterText(find.byType(TextField), 'a' * 30);
    await tester.pump();
    expect(find.text('30 / 50'), findsOneWidget);
  });

  testWidgets('over-cap paste stops at the cap, visibly',
      (tester) async {
    final c = TextEditingController();
    await tester.pumpWidget(
        field(controller: c, cap: TextCaps.nickname, labelStyle: true));
    await tester.enterText(find.byType(TextField), 'a' * 80);
    await tester.pump();
    // Cut AT the cap by the formatter — and the cut is seen:
    // full counter + the exact at-cap string.
    expect(c.text.length, TextCaps.nickname);
    expect(find.text('50 / 50'), findsOneWidget);
    expect(find.text(TextCaps.atCapMessage), findsOneWidget);
    // Deleting back below the cap removes the message.
    await tester.enterText(find.byType(TextField), 'a' * 49);
    await tester.pump();
    expect(find.text(TextCaps.atCapMessage), findsNothing);
    expect(find.text('49 / 50'), findsOneWidget);
  });

  testWidgets('at-cap message shows for prose fields too',
      (tester) async {
    final c = TextEditingController(text: 'x' * 10000);
    await tester.pumpWidget(field(controller: c, cap: 10000));
    await tester.pump();
    expect(find.text('10000 / 10000'), findsOneWidget);
    expect(find.text(TextCaps.atCapMessage), findsOneWidget);
  });
}
