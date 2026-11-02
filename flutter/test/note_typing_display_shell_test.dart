import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/quick_log_cache.dart';
import 'package:tabs_lab/src/data/quick_log_models.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/slide_page_route.dart';

/// Founder note-typing display bug, shell context: the Quick Log
/// details field as it actually sits in production — inside
/// MainShell's paired SlideTransition slots, under the NavDock
/// overlay — typed into character by character. (Isolated-screen
/// pumps in note_typing_display_test.dart pass; this checks the
/// shell wrapping for a display-level truncation.)

const _typed = 'Feeling dizzy today';

void main() {
  testWidgets('Quick Log details field, inside MainShell, shows '
      'every typed character', (tester) async {
    QuickLogCache.instance.debugReset();
    QuickLogCache.instance.applyLoad(
      categories: const [
        QuickLogCategory(
          id: 3,
          name: 'Symptoms',
          icon: 'circle',
          colorHex: '#4ECDC4',
          isDefault: true,
          sortOrder: 0,
        ),
      ],
      recentSuggestions: const [],
      todayCount: 0,
      isUnlimited: true,
      isAdmin: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          scaffoldBackgroundColor: NotelColors.background,
          pageTransitionsTheme: slidePageTransitionsTheme(),
        ),
        home: const MainShell(),
      ),
    );
    await tester.pump();
    // Switch to the Quick Log tab (the edit/pencil dock button).
    await tester.tap(find.descendant(
      of: find.byType(NavDock),
      matching: find.byIcon(Icons.edit),
    ));
    // Let the 300ms slide finish in timed pumps (Home never settles:
    // its weather icon animates forever).
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('quicklog_screen')), findsOneWidget);
    final field = find.byType(TextField);
    expect(field, findsOneWidget);
    await tester.tap(field);
    await tester.pump();
    final widthBefore = tester.getSize(field).width;
    for (var i = 1; i <= _typed.length; i++) {
      final prefix = _typed.substring(0, i);
      await tester.enterText(field, prefix);
      await tester.pump();
      final tf = tester.widget<TextField>(field);
      expect(
        tf.controller!.text,
        prefix,
        reason: 'shell: displayed text after $i char(s)',
      );
    }
    expect(tester.getSize(field).width, widthBefore,
        reason: 'shell: field width must not collapse while typing');
    expect(find.text(_typed), findsOneWidget,
        reason: 'shell: quick-note preview shows the full text');
  });
}
