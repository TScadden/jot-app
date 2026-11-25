import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/features/shell/main_shell.dart';
import 'package:tabs_lab/src/features/shell/nav_dock.dart';
import 'package:tabs_lab/src/features/shell/nav_dock_solid.dart';

/// Nav Bar Style package — the style preference that supersedes
/// the PR #170 liquid-glass bool, its migration rule (Solid in
/// every fallback case, regardless of the legacy bool), the
/// MainShell live flip between the two docks, and the Settings
/// Customize choice control (Juno's final copy).
void main() {
  SettingsStore storeOver(Map<String, String> map) =>
      SettingsStore.withStorage(
        read: (k) async => map[k],
        write: (k, v) async => map[k] = v,
        delete: (k) async => map.remove(k),
      );

  group('NavBarStyle preference', () {
    test('round-trip + notify through SettingsStore', () async {
      final map = <String, String>{};
      final store = storeOver(map);
      var notified = 0;
      store.addListener(() => notified++);

      await store.setNavBarStyle(NavBarStyle.liquidGlass);
      expect(map[SettingsStore.navBarStyleKey], 'liquid_glass');
      expect(notified, 1);
      // A FRESH store over the same storage reads it back (the
      // cold-restart leg).
      expect(await storeOver(map).getNavBarStyle(),
          NavBarStyle.liquidGlass);

      await store.setNavBarStyle(NavBarStyle.solid);
      expect(map[SettingsStore.navBarStyleKey], 'solid');
      expect(notified, 2);
      expect(await storeOver(map).getNavBarStyle(), NavBarStyle.solid);
    });

    test('fresh store -> solid', () async {
      expect(await storeOver({}).getNavBarStyle(), NavBarStyle.solid);
    });

    test('legacy bool true + no style key -> solid', () async {
      final map = <String, String>{SettingsStore.liquidGlassKey: 'true'};
      expect(await storeOver(map).getNavBarStyle(), NavBarStyle.solid);
    });

    test('legacy bool false + no style key -> solid', () async {
      final map = <String, String>{SettingsStore.liquidGlassKey: 'false'};
      expect(await storeOver(map).getNavBarStyle(), NavBarStyle.solid);
    });

    test('garbage style value -> solid', () async {
      final map = <String, String>{
        SettingsStore.navBarStyleKey: 'banana',
      };
      expect(await storeOver(map).getNavBarStyle(), NavBarStyle.solid);
    });

    test('unreadable store -> solid, never throws', () async {
      final store = SettingsStore.withStorage(
        read: (k) async => throw StateError('boom'),
        write: (k, v) async {},
        delete: (k) async {},
      );
      expect(await store.getNavBarStyle(), NavBarStyle.solid);
    });

    test('valid stored liquid_glass wins over legacy bool false',
        () async {
      final map = <String, String>{
        SettingsStore.navBarStyleKey: 'liquid_glass',
        SettingsStore.liquidGlassKey: 'false',
      };
      expect(await storeOver(map).getNavBarStyle(),
          NavBarStyle.liquidGlass);
    });

    test('clear() wipes the style key (and the legacy key)', () async {
      final map = <String, String>{};
      final store = storeOver(map);
      await store.setNavBarStyle(NavBarStyle.liquidGlass);
      await store.setLiquidGlass(true);
      await store.clear();
      expect(map.containsKey(SettingsStore.navBarStyleKey), isFalse);
      expect(map.containsKey(SettingsStore.liquidGlassKey), isFalse);
      expect(await storeOver(map).getNavBarStyle(), NavBarStyle.solid);
    });
  });

  group('MainShell style wiring', () {
    Future<void> pumpShell(WidgetTester tester, SettingsStore store) async {
      await tester.pumpWidget(
          MaterialApp(home: MainShell(settingsStore: store)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('renders NavDockSolid by default', (tester) async {
      await pumpShell(tester, storeOver({}));
      expect(find.byType(NavDockSolid), findsOneWidget);
      expect(find.byType(NavDock), findsNothing);
    });

    testWidgets('renders the glass NavDock when style is liquidGlass',
        (tester) async {
      final map = <String, String>{
        SettingsStore.navBarStyleKey: 'liquid_glass',
      };
      await pumpShell(tester, storeOver(map));
      expect(find.byType(NavDock), findsOneWidget);
      expect(find.byType(NavDockSolid), findsNothing);
      // Always true on the glass path (nav_dock.dart untouched).
      expect(tester.widget<NavDock>(find.byType(NavDock)).liquidGlass,
          isTrue);
    });

    testWidgets('flips live in both directions through the store',
        (tester) async {
      final map = <String, String>{};
      final store = storeOver(map);
      await pumpShell(tester, store);
      expect(find.byType(NavDockSolid), findsOneWidget);

      await store.setNavBarStyle(NavBarStyle.liquidGlass);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(NavDock), findsOneWidget);
      expect(find.byType(NavDockSolid), findsNothing);

      await store.setNavBarStyle(NavBarStyle.solid);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byType(NavDockSolid), findsOneWidget);
      expect(find.byType(NavDock), findsNothing);
    });
  });

  group('Settings Customize style choice', () {
    const secureStorageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

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

    Future<void> openCustomize(
        WidgetTester tester, SettingsStore store) async {
      await tester.pumpWidget(MaterialApp(
        home: MainShell(settingsStore: store),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byKey(const ValueKey('home_settings_gear')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.ensureVisible(find.text('Customize'));
      await tester.pump();
      await tester.tap(find.text('Customize'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      // Settings' async _load() seeds the choice from the store;
      // wait (real time + fake pumps, the navlabels-test pattern)
      // until both option buttons are on screen.
      for (var i = 0; i < 60; i++) {
        if (find.byKey(const ValueKey('nav_style_solid')).evaluate().isNotEmpty &&
            find
                .byKey(const ValueKey('nav_style_liquid_glass'))
                .evaluate()
                .isNotEmpty) {
          break;
        }
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byKey(const ValueKey('nav_style_solid')), findsOneWidget);
      expect(find.byKey(const ValueKey('nav_style_liquid_glass')),
          findsOneWidget);
    }

    ElevatedButton button(WidgetTester tester, String key) =>
        tester.widget<ElevatedButton>(find.byKey(ValueKey(key)));

    testWidgets('renders both options with Juno copy, solid selected '
        'by default, and writes on tap', (tester) async {
      final map = <String, String>{};
      final store = storeOver(map);
      await openCustomize(tester, store);

      // Juno's final strings, verbatim.
      expect(find.text('Navigation Bar Style'), findsOneWidget);
      expect(
          find.text('Bottom navigation bar only. Solid is the default.'),
          findsOneWidget);
      expect(find.text('Solid'), findsWidgets);
      expect(find.text('Liquid Glass'), findsOneWidget);
      // The old toggle is gone.
      expect(find.byKey(const ValueKey('liquid_glass_toggle')),
          findsNothing);

      // Default: Solid carries the selected (primary) styling.
      expect(button(tester, 'nav_style_solid').style?.backgroundColor
          ?.resolve({}), isNotNull);
      final solidBg = button(tester, 'nav_style_solid')
          .style
          ?.backgroundColor
          ?.resolve(<WidgetState>{});
      final glassBg = button(tester, 'nav_style_liquid_glass')
          .style
          ?.backgroundColor
          ?.resolve(<WidgetState>{});
      expect(solidBg, isNot(equals(glassBg)));

      // Tap Liquid Glass: the store write lands.
      await tester.tap(find.byKey(const ValueKey('nav_style_liquid_glass')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(map[SettingsStore.navBarStyleKey], 'liquid_glass');

      // Tap Solid: writes back.
      await tester.tap(find.byKey(const ValueKey('nav_style_solid')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(map[SettingsStore.navBarStyleKey], 'solid');
    });

    testWidgets('reflects a stored liquidGlass value on open',
        (tester) async {
      final map = <String, String>{
        SettingsStore.navBarStyleKey: 'liquid_glass',
      };
      final store = storeOver(map);
      await openCustomize(tester, store);
      final solidBg = button(tester, 'nav_style_solid')
          .style
          ?.backgroundColor
          ?.resolve(<WidgetState>{});
      final glassBg = button(tester, 'nav_style_liquid_glass')
          .style
          ?.backgroundColor
          ?.resolve(<WidgetState>{});
      expect(glassBg, isNot(equals(solidBg)));
      // And the shell underneath mounted the glass dock.
      expect(
          find.byType(NavDock, skipOffstage: false), findsOneWidget);
    });
  });
}
