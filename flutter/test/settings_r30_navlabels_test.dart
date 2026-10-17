import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';

/// Round 30 Step 4 — the Nav Bar Labels preference is wired: NavDock
/// renders native's labeled geometry (MainActivity.kt:657 dock
/// height 66, NavIcon :1005-1043 label style) when the preference is
/// on, and MainShell feeds it from SettingsStore.
void main() {
  Widget dock(bool labels, {DockTab selected = DockTab.home}) =>
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: NavDock(
              selected: selected,
              onSelect: (_) {},
              showLabels: labels,
            ),
          ),
        ),
      );

  testWidgets('labels off: no label texts, 56dp dock', (tester) async {
    await tester.pumpWidget(dock(false));
    await tester.pump();
    for (final label in ['Home', 'Tools', 'Heart', 'Settings']) {
      expect(find.text(label), findsNothing);
    }
    // The dock container is the Material under the NavDock.
    final size = tester.getSize(find.byType(NavDock));
    expect(size.height, 56 + 12); // dock + bottom padding (no inset)
  });

  testWidgets('labels on: four labels, 66dp dock, native styling',
      (tester) async {
    await tester.pumpWidget(dock(true, selected: DockTab.heart));
    await tester.pump();
    for (final label in ['Home', 'Tools', 'Heart', 'Settings']) {
      expect(find.text(label), findsOneWidget);
    }
    final size = tester.getSize(find.byType(NavDock));
    expect(size.height, 66 + 12);
    // Selected label: primary + bold. Unselected: secondary + medium.
    final heart = tester.widget<Text>(find.text('Heart'));
    expect(heart.style!.color, NotelColors.primary);
    expect(heart.style!.fontWeight, FontWeight.bold);
    expect(heart.style!.fontSize, 10);
    final home = tester.widget<Text>(find.text('Home'));
    expect(home.style!.color, NotelColors.textSecondary);
    expect(home.style!.fontWeight, FontWeight.w500);
    // The center quick-log button never carries a label (native).
    expect(find.text('Quick log'), findsNothing);
    expect(find.text('Log'), findsNothing);
  });

  testWidgets('MainShell feeds the stored preference to the dock',
      (tester) async {
    final map = <String, String>{SettingsStore.showNavLabelsKey: 'false'};
    final store = SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );
    await tester.pumpWidget(
        MaterialApp(home: MainShell(settingsStore: store)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    // Stored false wins over the native-default first frame.
    final dockWidget = tester.widget<NavDock>(find.byType(NavDock));
    expect(dockWidget.showLabels, isFalse);
    // Flip the stored value and switch tabs: MainShell re-reads.
    map[SettingsStore.showNavLabelsKey] = 'true';
    await tester.tap(find.descendant(
        of: find.byType(NavDock), matching: find.byIcon(Icons.favorite)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final updated = tester.widget<NavDock>(find.byType(NavDock));
    expect(updated.showLabels, isTrue);
  });
}
