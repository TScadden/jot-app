import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/home/migraine_block.dart';

import 'migraine_timer_test.dart' as mt;

/// Founder note-typing display bug — migraine "Meds taken" field
/// (a log-entry note field living on Home). The field's onChanged
/// persists through MigraineController.updateActive on EVERY
/// keystroke, which notifies listeners and rebuilds the block with a
/// fresh attack object each time — the exact rebuild-while-typing
/// pattern under suspicion. Asserts the DISPLAYED value after every
/// character, and that the persisted model carries the full text.

const _typed = 'sumatriptan 50mg';

void main() {
  testWidgets('Migraine meds field shows every typed character '
      'while updateActive rebuilds land', (tester) async {
    final h = mt.Harness();
    await h.controller.initialize();
    await h.controller.startAttack();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MigraineBlock(controller: h.controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    await tester.tap(field);
    await tester.pump();
    for (var i = 1; i <= _typed.length; i++) {
      final prefix = _typed.substring(0, i);
      await tester.enterText(field, prefix);
      await tester.pump();
      final tf = tester.widget<TextField>(field);
      expect(
        tf.controller!.text,
        prefix,
        reason: 'displayed meds text after $i char(s)',
      );
      // The persisted model must carry exactly what is displayed.
      expect(
        h.controller.activeAttack!.medsTaken,
        prefix,
        reason: 'persisted meds text after $i char(s)',
      );
    }
  });

  testWidgets('Migraine details form meds field shows every character',
      (tester) async {
    final h = mt.Harness();
    await h.controller.initialize();
    await h.controller.startAttack();
    final attack = h.controller.activeAttack!;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showMigraineDetailsForm(
                  context,
                  controller: h.controller,
                  attack: attack,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    await tester.tap(field);
    await tester.pump();
    for (var i = 1; i <= _typed.length; i++) {
      final prefix = _typed.substring(0, i);
      await tester.enterText(field, prefix);
      await tester.pump();
      final tf = tester.widget<TextField>(field);
      expect(tf.controller!.text, prefix,
          reason: 'details-form displayed text after $i char(s)');
    }
  });
}
