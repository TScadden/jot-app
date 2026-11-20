import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/data/tabs_backend.dart';
import 'package:tabs_lab/src/features/settings/app_background_section.dart';
import 'package:tabs_lab/src/features/settings/settings_screen.dart';
import 'package:tabs_lab/src/theme/app_background.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/notel_theme.dart';

import 'test_helpers.dart';

/// Dev-only app background changer (founder direction Nov 19,
/// 2026, scope #4). Acceptance:
/// (a) setting a color changes the resolved background token;
/// (b) reset restores the shipped default;
/// (c) persistence round-trip through local prefs (set → reload
///     → same color; unset → default);
/// (d) the dev section renders with dev_access on and does NOT
///     render with it off;
/// (e) invalid hex does not change the active color.
///
/// NOTE on the default value: the package brief named #080E1A as
/// "the current default", but the token on this branch resolved
/// to #0A0A0B (BlackGlass v4, pinned by lab_blackglass_theme_test
/// and home_screen_test). The default under test here is the
/// ACTUAL token default, NotelColors.defaultBackground
/// (0xFF0A0A0B); #080E1A ships as a preset (Deep navy).

SettingsStore _fakeStore(Map<String, String> map) =>
    SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

class _FakeBackend extends TabsBackend {
  final Map<String, dynamic> pull;
  _FakeBackend({super.sessionStore, required this.pull});

  @override
  Future<Map<String, dynamic>?> fetchSyncPull() async => pull;
}

Map<String, dynamic> _pull({bool? devAccess}) {
  return {
    'isUnlimited': false,
    'isAdmin': false,
    'nickname': 'Tyson',
    'tag': '1234',
    'profile': <String, dynamic>{
      'dev_access': ?devAccess,
    },
    'insights': const [],
  };
}

void main() {
  // The resolved token is process-global; every test in this
  // file starts and ends at the shipped default so order cannot
  // leak an override between tests.
  setUp(() {
    NotelColors.backgroundOverride = NotelColors.defaultBackground;
  });
  tearDown(() {
    NotelColors.backgroundOverride = NotelColors.defaultBackground;
  });

  group('AppBackgroundController — token resolution', () {
    test('setting a color changes the resolved background token '
        'and the theme scaffold color', () async {
      final controller =
          AppBackgroundController(store: _fakeStore({}));
      const target = Color(0xFF112233);
      await controller.setColor(target);
      expect(NotelColors.background, target);
      expect(controller.color, target);
      // The theme built from the token (the TabsLabApp path
      // passes the controller color explicitly) resolves the
      // same value as its scaffold background.
      expect(notelDarkTheme().scaffoldBackgroundColor, target);
      expect(
          notelDarkTheme(background: target).scaffoldBackgroundColor,
          target);
      // Surfaces do NOT follow the override.
      expect(notelDarkTheme(background: target).colorScheme.surface,
          NotelColors.surface);
    });

    test('reset restores the shipped default', () async {
      final map = <String, String>{};
      final controller = AppBackgroundController(store: _fakeStore(map));
      await controller.setColor(const Color(0xFF112233));
      expect(NotelColors.background, isNot(NotelColors.defaultBackground));
      await controller.reset();
      expect(NotelColors.background, NotelColors.defaultBackground);
      expect(NotelColors.background.toARGB32(), 0xFF0A0A0B);
      // Reset deletes the key (unset state), it does not write
      // the default into prefs.
      expect(map.containsKey(SettingsStore.appBackgroundColorKey),
          isFalse);
    });

    test('presets include the default, pure black, and #080E1A',
        () {
      final hexes = AppBackgroundPresets.all
          .map((p) => AppBackgroundController.formatHex(p.color))
          .toList();
      expect(AppBackgroundPresets.all.length, 8);
      expect(hexes.first, '#0A0A0B');
      expect(hexes, contains('#000000'));
      expect(hexes, contains('#080E1A'));
    });
  });

  group('AppBackgroundController — persistence (local prefs only)',
      () {
    test('round-trip: set → reload from prefs → same color',
        () async {
      final map = <String, String>{};
      final writer = AppBackgroundController(store: _fakeStore(map));
      const target = Color(0xFF1A2B3C);
      await writer.setColor(target);
      expect(map[SettingsStore.appBackgroundColorKey], '#1A2B3C');

      // A fresh controller over the same prefs (the cold-start
      // bootstrap shape) resolves the persisted color.
      NotelColors.backgroundOverride = NotelColors.defaultBackground;
      final reader = AppBackgroundController(store: _fakeStore(map));
      await reader.load();
      expect(NotelColors.background, target);
      expect(reader.color, target);
    });

    test('unset → default on load', () async {
      final reader =
          AppBackgroundController(store: _fakeStore({}));
      await reader.load();
      expect(NotelColors.background, NotelColors.defaultBackground);
    });

    test('a corrupt stored value resolves to the default',
        () async {
      final reader = AppBackgroundController(
          store: _fakeStore(
              {SettingsStore.appBackgroundColorKey: 'not-a-color'}));
      await reader.load();
      expect(NotelColors.background, NotelColors.defaultBackground);
    });
  });

  group('hex parsing', () {
    test('valid 6-digit forms parse (bare, #-prefixed, any case)',
        () {
      expect(AppBackgroundController.parseHex('112233'),
          const Color(0xFF112233));
      expect(AppBackgroundController.parseHex('#112233'),
          const Color(0xFF112233));
      expect(AppBackgroundController.parseHex('#aAbBcC'),
          const Color(0xFFAABBCC));
      expect(AppBackgroundController.parseHex('  #080E1A '),
          const Color(0xFF080E1A));
    });

    test('invalid forms return null', () {
      for (final bad in [
        '',
        '#',
        '12345',
        '1234567',
        '#12345678',
        'GGGGGG',
        '#12 456',
        '-12345',
        'blue',
      ]) {
        expect(AppBackgroundController.parseHex(bad), isNull,
            reason: 'input: "$bad"');
      }
    });

    test('invalid hex does not change the active color', () async {
      final map = <String, String>{};
      final controller = AppBackgroundController(store: _fakeStore(map));
      const target = Color(0xFF0C1830);
      await controller.setColor(target);
      for (final bad in ['ZZZZZZ', '12345', '#1234567', '']) {
        expect(await controller.applyHex(bad), isFalse,
            reason: 'input: "$bad"');
        expect(NotelColors.background, target);
        expect(controller.color, target);
      }
      // Nothing extra was persisted by the rejected attempts.
      expect(map[SettingsStore.appBackgroundColorKey], '#0C1830');
    });

    test('valid custom hex applies and reports custom state',
        () async {
      final controller =
          AppBackgroundController(store: _fakeStore({}));
      expect(await controller.applyHex('#1A2B3C'), isTrue);
      expect(NotelColors.background, const Color(0xFF1A2B3C));
      expect(controller.isCustom, isTrue);
      await controller.setColor(const Color(0xFF080E1A));
      expect(controller.isCustom, isFalse);
    });
  });

  group('AppBackgroundSection widget', () {
    Widget harness({
      required Color active,
      ValueChanged<Color>? onPreset,
      Future<bool> Function(String)? onHex,
      VoidCallback? onReset,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: AppBackgroundSection(
            activeColor: active,
            onPresetSelected: onPreset ?? (_) {},
            onApplyHex: onHex ?? (_) async => true,
            onReset: onReset ?? () {},
          ),
        ),
      );
    }

    testWidgets('renders Juno copy byte-for-byte, the preset grid, '
        'and the reset action', (tester) async {
      await tester.pumpWidget(
          harness(active: NotelColors.defaultBackground));
      expect(find.text('App background'), findsOneWidget);
      expect(
        find.text('Sets the app background color on this device '
            'only. Applies immediately; reset restores the default.'),
        findsOneWidget,
      );
      expect(find.text('Reset to default'), findsOneWidget);
      final field = tester.widget<TextField>(
          find.byKey(const Key('appBgHexField')));
      expect(field.decoration?.hintText, '#RRGGBB');
      // All 8 preset swatches render.
      for (final preset in AppBackgroundPresets.all) {
        expect(
          find.byKey(Key(
              'appBgSwatch_${AppBackgroundController.formatHex(preset.color).substring(1)}')),
          findsOneWidget,
          reason: 'preset ${preset.name}',
        );
      }
    });

    testWidgets('the active preset carries the check indication; '
        'a custom color shows the custom indication', (tester) async {
      await tester.pumpWidget(harness(active: const Color(0xFF080E1A)));
      expect(find.byKey(const Key('appBgActiveCheck')), findsOneWidget);
      expect(find.text('Active: #080E1A'), findsOneWidget);
      expect(find.byKey(const Key('appBgCustomSwatch')), findsNothing);

      await tester.pumpWidget(harness(active: const Color(0xFF1A2B3C)));
      expect(find.byKey(const Key('appBgCustomSwatch')), findsOneWidget);
      expect(find.text('Active: custom #1A2B3C'), findsOneWidget);
    });

    testWidgets('tapping a swatch reports its color; tapping Reset '
        'reports the reset', (tester) async {
      Color? picked;
      var resets = 0;
      await tester.pumpWidget(harness(
        active: NotelColors.defaultBackground,
        onPreset: (c) => picked = c,
        onReset: () => resets++,
      ));
      await tester.tap(
          find.byKey(const Key('appBgSwatch_000000')));
      expect(picked, const Color(0xFF000000));
      await tester.tap(find.byKey(const Key('appBgResetButton')));
      expect(resets, 1);
    });

    testWidgets('invalid hex is rejected inline and the apply '
        'callback reports failure', (tester) async {
      String? submitted;
      await tester.pumpWidget(harness(
        active: NotelColors.defaultBackground,
        onHex: (hex) async {
          submitted = hex;
          return AppBackgroundController.parseHex(hex) != null;
        },
      ));
      // '12345' is typable (the field's formatter already blocks
      // non-hex characters) but is not a valid 6-digit hex.
      await tester.enterText(
          find.byKey(const Key('appBgHexField')), '12345');
      await tester.tap(find.byKey(const Key('appBgApplyButton')));
      await tester.pumpAndSettle();
      expect(submitted, '12345');
      expect(find.byKey(const Key('appBgHexError')), findsOneWidget);
    });
  });

  group('Settings dev gate — the section renders only with '
      'dev_access', () {
    Future<void> pumpSettings(
      WidgetTester tester,
      Map<String, dynamic> pull,
    ) async {
      tester.view.physicalSize = const Size(1080, 3400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: SettingsScreen(
          backend: _FakeBackend(
            sessionStore: FakeSessionStore(),
            pull: pull,
          ),
          settingsStore: _fakeStore(<String, String>{}),
          notificationService: FakeReminderNotificationService(),
          urlLauncher: (uri) async => true,
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('dev_access true → the App background section '
        'renders on the Developer Terminal page', (tester) async {
      await pumpSettings(tester, _pull(devAccess: true));
      final entry = find.byKey(const ValueKey('developer_terminal_entry'));
      expect(entry, findsOneWidget);
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('App background'), findsOneWidget);
      expect(
        find.text('Sets the app background color on this device '
            'only. Applies immediately; reset restores the default.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('appBgResetButton')), findsOneWidget);
    });

    testWidgets('dev_access false → no dev entry, no App '
        'background section', (tester) async {
      await pumpSettings(tester, _pull(devAccess: false));
      expect(
          find.byKey(const ValueKey('developer_terminal_entry')),
          findsNothing);
      expect(find.text('App background'), findsNothing);
    });

    testWidgets('dev_access absent → no App background section',
        (tester) async {
      await pumpSettings(tester, _pull());
      expect(
          find.byKey(const ValueKey('developer_terminal_entry')),
          findsNothing);
      expect(find.text('App background'), findsNothing);
    });
  });
}
