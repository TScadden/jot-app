import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  // The Customize integration tests (grouped below) mount a real
  // MainShell, whose Settings tab builds the REAL TabsBackend. Its
  // pull reads the session token from flutter_secure_storage —
  // unimplemented in tests, the resulting MissingPluginException
  // surfaced inside whichever test happened to be active (leg (d)
  // flaked on it). The group mocks the channel to the signed-out
  // answers (read → null), the path the backend handles
  // gracefully, so loads complete deterministically. The mock is
  // scoped to the group on purpose: file-wide, it also lets the
  // Home pull in the older shell test proceed far enough to leave
  // a pending timer at teardown. The fake SettingsStore storage in
  // these tests never touches this channel.
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

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
    // Flip the stored value DIRECTLY in storage (bypassing the
    // setter, so no change notification fires) and switch tabs:
    // MainShell's dock-tap re-read still picks it up. This is the
    // belt-and-braces path; the setter path is covered live by the
    // Customize integration tests below (customize-wiring fix).
    map[SettingsStore.showNavLabelsKey] = 'true';
    await tester.tap(find.descendant(
        of: find.byType(NavDock), matching: find.byIcon(Icons.favorite)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final updated = tester.widget<NavDock>(find.byType(NavDock));
    expect(updated.showLabels, isTrue);
  });

  // ── Customize-wiring fix (Oct 2026) — the four read-back legs ──
  //
  // The defect: flipping "Show Navigation Bar Labels" in Settings →
  // Customize wrote the store, but MainShell only re-read it at
  // init / on a dock tap, so the visible dock did not change until
  // a tab switch. The fix: SettingsStore notifies on
  // setShowNavLabels, MainShell listens on the SAME instance it
  // hands to Settings, and re-reads. These tests prove the full
  // wiring read-back at integration level — real Customize toggle
  // in a real shell tree:
  //   (a) OFF takes effect live on the same screen, no tab switch
  //   (b) OFF persists across a simulated cold restart
  //   (c) ON returns live, same screen, no tab switch
  //   (d) ON persists across a simulated cold restart

  SettingsStore storeOver(Map<String, String> map) =>
      SettingsStore.withStorage(
        read: (k) async => map[k],
        write: (k, v) async => map[k] = v,
        delete: (k) async => map.remove(k),
      );

  Finder dockLabel(String label) => find.descendant(
      of: find.byType(NavDock), matching: find.text(label));

  Future<void> pumpShell(WidgetTester tester, SettingsStore store) async {
    await tester.pumpWidget(MaterialApp(home: MainShell(settingsStore: store)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  /// From a freshly pumped shell on Home: switch to the Settings
  /// tab and open Customize. Returns with the toggle on screen AND
  /// showing [toggleValue]: the wait matters — Settings seeds the
  /// toggle from its async _load(), and a tap that lands before
  /// the load would toggle the initial default instead of the
  /// stored value (leg (d) caught exactly that race: the switch
  /// still showed the initial true, so the tap wrote false again).
  Future<void> openCustomize(WidgetTester tester,
      {required bool toggleValue}) async {
    await tester.tap(find.descendant(
        of: find.byType(NavDock), matching: find.byIcon(Icons.settings)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.ensureVisible(find.text('Customize'));
    await tester.tap(find.text('Customize'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const ValueKey('nav_labels_toggle')), findsOneWidget);
    final switchFinder = find.descendant(
        of: find.byKey(const ValueKey('nav_labels_toggle')),
        matching: find.byType(Switch));
    // The seed comes from Settings' _load(), which awaits a REAL
    // async pull (the shell builds Settings with the real backend)
    // — fake-clock pumps alone do not reliably let real async work
    // complete on a contended box (this wait flaked twice under
    // load with pump-only budgets of 30 and 100). The loop
    // therefore alternates: real time via runAsync (the pull can
    // actually finish), then fake pumps (the setState lands).
    for (var i = 0; i < 60; i++) {
      if (tester.widget<Switch>(switchFinder).value == toggleValue) break;
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(tester.widget<Switch>(switchFinder).value, toggleValue,
        reason: 'Settings load never seeded the toggle');
  }

  /// Unmount the tree for a simulated cold restart. Real async is
  /// drained first: Home's migraine controller finishes its
  /// initialize() before dispose, instead of notifying after it
  /// (an after-teardown exception the framework attributes to the
  /// running test).
  Future<void> unmount(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
  }

  Future<void> tapNavLabelsToggle(WidgetTester tester) async {
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('nav_labels_toggle')),
        matching: find.byType(Switch)));
    // The write lands, the store notifies, the shell re-reads and
    // rebuilds — all async hops, all flushed by timed pumps. NO tab
    // tap happens anywhere in these legs.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
  }

  void expectDockLabels(WidgetTester tester, {required bool shown}) {
    expect(tester.widget<NavDock>(find.byType(NavDock)).showLabels, shown);
    for (final label in ['Home', 'Tools', 'Heart', 'Settings']) {
      expect(dockLabel(label), shown ? findsOneWidget : findsNothing,
          reason: 'dock label "$label"');
    }
  }

  group('Customize integration (secure-storage channel mocked)', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, (call) async {
        return switch (call.method) {
          'read' => null,
          'readAll' => <String, String>{},
          _ => null,
        };
      });
    });
    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
    });

  testWidgets(
      'legs (a)+(c): Customize toggle flips the dock LIVE in both '
      'directions, same screen, no tab switch', (tester) async {
    final map = <String, String>{};
    await pumpShell(tester, storeOver(map));
    expectDockLabels(tester, shown: true); // native default

    await openCustomize(tester, toggleValue: true);

    // Leg (a): OFF — the dock in THIS tree loses its labels while
    // the Customize page is still on screen.
    await tapNavLabelsToggle(tester);
    expect(map[SettingsStore.showNavLabelsKey], 'false');
    expectDockLabels(tester, shown: false);
    // Still sitting in Settings on the Customize page: no tab
    // switch was involved in the refresh.
    expect(find.text('Appearance'), findsOneWidget);
    expect(tester.widget<NavDock>(find.byType(NavDock)).selected,
        DockTab.settings);

    // Leg (c): ON — labels return live, same screen.
    await tapNavLabelsToggle(tester);
    expect(map[SettingsStore.showNavLabelsKey], 'true');
    expectDockLabels(tester, shown: true);
    expect(find.text('Appearance'), findsOneWidget);
  });

  testWidgets('leg (b): OFF persists across a cold restart',
      (tester) async {
    final map = <String, String>{};
    await pumpShell(tester, storeOver(map));
    await openCustomize(tester, toggleValue: true);
    await tapNavLabelsToggle(tester);
    expect(map[SettingsStore.showNavLabelsKey], 'false');
    expectDockLabels(tester, shown: false);

    // Simulated cold restart: unmount the whole tree, then a FRESH
    // shell with a FRESH store instance over the same storage.
    await unmount(tester);
    await pumpShell(tester, storeOver(map));
    expectDockLabels(tester, shown: false);
  });

  testWidgets('leg (d): ON persists across a cold restart',
      (tester) async {
    final map = <String, String>{
      SettingsStore.showNavLabelsKey: 'false',
    };
    await pumpShell(tester, storeOver(map));
    expectDockLabels(tester, shown: false); // stored value seeded

    await openCustomize(tester, toggleValue: false);
    await tapNavLabelsToggle(tester);
    expect(map[SettingsStore.showNavLabelsKey], 'true');
    expectDockLabels(tester, shown: true);

    await unmount(tester);
    await pumpShell(tester, storeOver(map));
    expectDockLabels(tester, shown: true);
  });
  }); // Customize integration group
}
