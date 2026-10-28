import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/home/home_screen.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/notel_theme.dart';

/// Snackbar / nav-dock clearance — founder-reported defect: snackbars
/// rendered UNDER the floating bottom nav dock (e.g. Settings →
/// User Profile's "Profile updated from Health Connect." was
/// half-hidden behind the dock pill).
///
/// Mechanism: MainShell is a Stack — the tab bodies and the NavDock
/// are siblings, the dock drawn after/above the bodies. It is NOT
/// any tab Scaffold's bottomNavigationBar, so a (default, fixed)
/// SnackBar anchors to its own Scaffold's bottom edge and the opaque
/// dock pill paints over its lower half. The fix scopes a floating
/// SnackBar theme around the shell's body slot only, with a bottom
/// inset derived from the shared dock geometry
/// (see nav_dock.dart / main_shell.dart), parking the visible card
/// exactly 8dp above the pill.
///
/// These tests pump the REAL MainShell, show the founder's exact
/// snackbar from a context inside the shell body, and measure the
/// visible bar's Material (the one inside the SnackBar carrying the
/// theme's surfaceHigh color at elevation 6) against the NavDock
/// rect. Geometry is captured BEFORE any assertions run, and the
/// snackbar is then flushed through its 4s auto-dismiss, so a
/// failing assertion never leaves a pending timer behind.
void main() {
  const message = 'Profile updated from Health Connect.';
  const screenSize = Size(800, 600);
  const systemBottomInset = 24.0;

  Finder snackBarMaterial() => find.descendant(
    of: find.byType(SnackBar),
    matching: find.byWidgetPredicate(
      (w) =>
          w is Material &&
          w.color == NotelColors.surfaceHigh &&
          w.elevation == 6.0,
    ),
  );

  void usePhoneView(WidgetTester tester) {
    tester.view.physicalSize = screenSize;
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(bottom: systemBottomInset);
    tester.view.padding = const FakeViewPadding(bottom: systemBottomInset);
    addTearDown(tester.view.reset);
  }

  SettingsStore storeFor(bool labels) {
    final map = <String, String>{
      SettingsStore.showNavLabelsKey: labels ? 'true' : 'false',
    };
    return SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );
  }

  /// Pumps the real shell, shows the snackbar from inside its body,
  /// captures the bar + dock geometry, flushes the dismiss, and
  /// returns the captured rects.
  Future<({Rect bar, Rect dock, bool dockLabels})> captureInShell(
    WidgetTester tester, {
    required bool labels,
  }) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: notelDarkTheme(),
        home: MainShell(settingsStore: storeFor(labels)),
      ),
    );
    await tester.pump();
    // Stored preference lands + staggered-entrance delays fire.
    await tester.pump(const Duration(milliseconds: 500));

    final dockWidget = tester.widget<NavDock>(find.byType(NavDock));

    // A context inside the shell body (the Home tab's screen).
    final bodyContext = tester.element(find.byType(HomeScreen));
    ScaffoldMessenger.of(bodyContext)
        .showSnackBar(const SnackBar(content: Text(message)));
    await tester.pump();
    // Past the 250ms entry animation; NOT pumpAndSettle, which
    // would run through the 4s auto-dismiss before measuring.
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(message), findsOneWidget);
    expect(snackBarMaterial(), findsOneWidget);
    final bar = tester.getRect(snackBarMaterial());
    final dock = tester.getRect(find.byType(NavDock));

    // Flush the auto-dismiss + exit so no timer is pending at
    // teardown, whatever the caller's assertions then do.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));

    return (bar: bar, dock: dock, dockLabels: dockWidget.showLabels);
  }

  testWidgets('in shell, labels off: bar parks 8dp above the dock, '
      'full width', (tester) async {
    final g = await captureInShell(tester, labels: false);
    expect(g.dockLabels, isFalse);
    expect(g.bar.bottom, closeTo(g.dock.top - 8, 0.5));
    expect(g.bar.left, 0);
    expect(g.bar.right, screenSize.width);
  });

  testWidgets('in shell, labels on: bar parks 8dp above the taller '
      'dock, full width', (tester) async {
    final g = await captureInShell(tester, labels: true);
    expect(g.dockLabels, isTrue);
    expect(g.bar.bottom, closeTo(g.dock.top - 8, 0.5));
    expect(g.bar.left, 0);
    expect(g.bar.right, screenSize.width);
  });

  testWidgets('outside the shell: unchanged fixed geometry, bar '
      'reaches the screen bottom', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      MaterialApp(
        theme: notelDarkTheme(),
        home: const Scaffold(body: Center(child: Text('outside'))),
      ),
    );
    await tester.pump();

    final context = tester.element(find.byType(Scaffold));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text(message)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text(message), findsOneWidget);
    expect(snackBarMaterial(), findsOneWidget);
    final bar = tester.getRect(snackBarMaterial());

    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(milliseconds: 500));

    // The pre-fix geometry, exactly: a fixed bar anchored to the
    // Scaffold's own bottom edge — no phantom dock gap outside
    // the shell.
    expect(bar.bottom, screenSize.height);
    expect(bar.left, 0);
    expect(bar.right, screenSize.width);
  });
}
