import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 9 — nav dock tests: all five tabs tappable, home shows the real
/// home screen, the other four show blank placeholders, and the active
/// highlight follows the selection.
void main() {
  Widget shell() => const MaterialApp(home: MainShell());

  Finder dockIcon(IconData icon) => find.descendant(
        of: find.byType(NavDock),
        matching: find.byIcon(icon),
      );

  Color iconColor(WidgetTester tester, IconData icon) {
    final widget = tester.widget<Icon>(dockIcon(icon).first);
    return widget.color!;
  }

  testWidgets('all five dock tabs are present and tappable', (tester) async {
    await tester.pumpWidget(shell());
    for (final icon in [
      Icons.home,
      Icons.assignment,
      Icons.edit,
      Icons.favorite,
      Icons.settings,
    ]) {
      expect(dockIcon(icon), findsOneWidget,
          reason: 'dock icon $icon missing');
    }
  });

  testWidgets('home tab shows the home screen; others show blank screens',
      (tester) async {
    await tester.pumpWidget(shell());

    // Home tab: the real home screen (Today header).
    expect(find.text('Today'), findsOneWidget);

    // Tools -> blank: no Today title, navy background only.
    await tester.tap(dockIcon(Icons.assignment));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsNothing);

    // Heart -> blank.
    await tester.tap(dockIcon(Icons.favorite));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsNothing);

    // Settings -> blank.
    await tester.tap(dockIcon(Icons.settings));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsNothing);

    // Quick log (center pencil) -> blank.
    await tester.tap(dockIcon(Icons.edit));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsNothing);

    // Home -> back to the real home screen.
    await tester.tap(dockIcon(Icons.home));
    await tester.pumpAndSettle();
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('active highlight follows the selected tab', (tester) async {
    await tester.pumpWidget(shell());

    // Home starts selected (purple); the rest are muted.
    expect(iconColor(tester, Icons.home), NotelColors.primary);
    expect(iconColor(tester, Icons.favorite), NotelColors.textSecondary);

    // Select Heart: highlight moves, home goes muted.
    await tester.tap(dockIcon(Icons.favorite));
    await tester.pumpAndSettle();
    expect(iconColor(tester, Icons.favorite), NotelColors.primary);
    expect(iconColor(tester, Icons.home), NotelColors.textSecondary);

    // Tapping the active tab again keeps it selected (no-op, no crash).
    await tester.tap(dockIcon(Icons.favorite));
    await tester.pumpAndSettle();
    expect(iconColor(tester, Icons.favorite), NotelColors.primary);
  });

  testWidgets('dock stays visible on blank tabs', (tester) async {
    await tester.pumpWidget(shell());
    await tester.tap(dockIcon(Icons.settings));
    await tester.pumpAndSettle();
    // The dock (with all five icons) is still on screen.
    expect(find.byType(NavDock), findsOneWidget);
    expect(dockIcon(Icons.home), findsOneWidget);
  });
}
