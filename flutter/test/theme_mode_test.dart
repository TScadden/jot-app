import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/main.dart';
import 'package:tabs_lab/src/data/settings_store.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/notel_theme.dart';
import 'package:tabs_lab/src/theme/theme_mode_controller.dart';

/// Theme-mode package (Nov 27, 2026) — acceptance tests:
/// (a) the stored mode is honored on startup for all three
///     values (including a LIGHT/SYSTEM value stored before the
///     Oct 2026 disabling — Juno Nov 27 §5.1);
/// (b) writing a new mode (the picker's path) switches the app's
///     brightness live, without restart;
/// (c) SYSTEM follows the platform brightness and live-switches
///     when it changes, without changing the stored value;
/// (d) both palettes pass WCAG AA on the design audit's headline
///     text/surface pairs, and the dark palette is byte-identical
///     to the shipped values.

SettingsStore _fakeStore(Map<String, String> map) =>
    SettingsStore.withStorage(
      read: (k) async => map[k],
      write: (k, v) async => map[k] = v,
      delete: (k) async => map.remove(k),
    );

double _lum(Color c) {
  double f(double v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * f(c.r * 255) +
      0.7152 * f(c.g * 255) +
      0.0722 * f(c.b * 255);
}

double _ratio(Color a, Color b) {
  final la = _lum(a), lb = _lum(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Pumps the app root with [controller] and advances fake time
/// past the splash + any cross-fade already in flight.
Future<void> _pumpApp(
    WidgetTester tester, ThemeModeController controller) async {
  await tester.pumpWidget(TabsLabApp(themeModeController: controller));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pump(const Duration(milliseconds: 600));
  // Advance past AppFlow's splash timers (650 + 1200 + 650ms) so
  // no fake timer is left pending at test end.
  await tester.pump(const Duration(seconds: 3));
}

ThemeData _appTheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(AppFlow)));

void main() {
  // Token state is process-global; every test in this file starts
  // and ends on the shipped dark palette with no dev override.
  setUp(() {
    NotelColors.setBrightness(Brightness.dark);
    NotelColors.clearBackgroundOverride();
  });
  tearDown(() {
    NotelColors.setBrightness(Brightness.dark);
    NotelColors.clearBackgroundOverride();
  });

  group('palettes', () {
    test('dark palette is byte-identical to the shipped values', () {
      final p = NotelColors.darkPalette;
      expect(p.background.toARGB32(), 0xFF0A0A0B);
      expect(p.surface.toARGB32(), 0xFF101013);
      expect(p.surfaceHigh.toARGB32(), 0xFF0C0C0F);
      expect(p.textPrimary.toARGB32(), 0xFFF5F5F7);
      expect(p.textSecondary.toARGB32(), 0xFF9A9AA3);
      expect(NotelColors.primary.toARGB32(), 0xFF7C6EFF);
    });

    test('light palette passes WCAG AA on the headline pairs', () {
      final p = NotelColors.lightPalette;
      // The three pairs the package reports, measured with the
      // design audit §2 formula: all must clear 4.5:1.
      expect(_ratio(p.textPrimary, p.background),
          greaterThanOrEqualTo(4.5),
          reason: 'textPrimary/background');
      expect(_ratio(p.textSecondary, p.surface),
          greaterThanOrEqualTo(4.5),
          reason: 'textSecondary/surface');
      expect(_ratio(p.textPrimary, p.surface),
          greaterThanOrEqualTo(4.5),
          reason: 'textPrimary/surface');
      // The rest of the working set, same bar:
      expect(_ratio(p.textSecondary, p.background),
          greaterThanOrEqualTo(4.5),
          reason: 'textSecondary/background');
      expect(_ratio(p.textSecondary, p.surfaceHigh),
          greaterThanOrEqualTo(4.5),
          reason: 'textSecondary/surfaceHigh');
      expect(_ratio(p.textPrimary, p.surfaceHigh),
          greaterThanOrEqualTo(4.5),
          reason: 'textPrimary/surfaceHigh');
      expect(_ratio(p.primaryText, p.surface),
          greaterThanOrEqualTo(4.5),
          reason: 'primaryText/surface');
      expect(_ratio(p.primaryText, p.surfaceHigh),
          greaterThanOrEqualTo(4.5),
          reason: 'primaryText/surfaceHigh');
      expect(_ratio(p.error, p.surface), greaterThanOrEqualTo(4.5),
          reason: 'error/surface');
    });

    test('token getters follow the selected palette', () {
      NotelColors.setBrightness(Brightness.light);
      expect(NotelColors.surface, NotelColors.lightPalette.surface);
      expect(NotelColors.textPrimary,
          NotelColors.lightPalette.textPrimary);
      expect(NotelColors.background,
          NotelColors.lightPalette.background);
      expect(NotelColors.isLight, isTrue);
      NotelColors.setBrightness(Brightness.dark);
      expect(NotelColors.surface, NotelColors.darkPalette.surface);
      expect(NotelColors.background, NotelColors.defaultBackground);
    });

    test('dev background override wins in BOTH themes', () {
      const override = Color(0xFF112233);
      NotelColors.backgroundOverride = override;
      expect(NotelColors.background, override);
      NotelColors.setBrightness(Brightness.light);
      expect(NotelColors.background, override);
      // Surfaces never follow the override, in either theme.
      expect(NotelColors.surface, NotelColors.lightPalette.surface);
      NotelColors.clearBackgroundOverride();
      expect(NotelColors.background,
          NotelColors.lightPalette.background);
    });
  });

  group('notelLightTheme scheme', () {
    testWidgets('resolves light brightness and light token mapping',
        (tester) async {
      late ThemeData resolved;
      await tester.pumpWidget(MaterialApp(
        theme: notelLightTheme(),
        home: Builder(builder: (context) {
          resolved = Theme.of(context);
          return const SizedBox();
        }),
      ));
      final p = NotelColors.lightPalette;
      expect(resolved.brightness, Brightness.light);
      expect(resolved.colorScheme.brightness, Brightness.light);
      expect(resolved.colorScheme.primary, NotelColors.primary);
      expect(resolved.colorScheme.surface, p.surface);
      expect(resolved.colorScheme.onSurface, p.textPrimary);
      expect(resolved.colorScheme.onSurfaceVariant, p.textSecondary);
      expect(resolved.colorScheme.surfaceContainerHigh, p.surfaceHigh);
      expect(resolved.scaffoldBackgroundColor, p.background);
      expect(resolved.dialogTheme.backgroundColor, p.surface);
      expect(resolved.datePickerTheme.backgroundColor, p.surface);
      expect(resolved.bottomSheetTheme.backgroundColor, p.surface);
      expect(resolved.popupMenuTheme.color, p.surfaceHigh);
      expect(resolved.snackBarTheme.backgroundColor, p.surfaceHigh);
    });
  });

  group('(a) stored mode honored on startup', () {
    for (final (stored, expectedMode, expectedBrightness) in [
      ('LIGHT', ThemeMode.light, Brightness.light),
      ('DARK', ThemeMode.dark, Brightness.dark),
      ('SYSTEM', ThemeMode.system, Brightness.light),
    ]) {
      testWidgets('stored $stored renders $expectedBrightness',
          (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        addTearDown(
            tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final map = <String, String>{
          SettingsStore.themeModeKey: stored,
        };
        final controller =
            ThemeModeController(store: _fakeStore(map));
        await controller.load();
        await _pumpApp(tester, controller);

        final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
        expect(app.themeMode, expectedMode);
        expect(_appTheme(tester).brightness, expectedBrightness);
        expect(NotelColors.brightness, expectedBrightness);
        expect(
          NotelColors.textPrimary,
          expectedBrightness == Brightness.light
              ? NotelColors.lightPalette.textPrimary
              : NotelColors.darkPalette.textPrimary,
        );
        controller.dispose();
      });
    }

    testWidgets('no stored value renders Dark (fresh install)',
        (tester) async {
      final controller =
          ThemeModeController(store: _fakeStore(<String, String>{}));
      await controller.load();
      expect(controller.mode, 'DARK');
      await _pumpApp(tester, controller);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.dark);
      expect(_appTheme(tester).brightness, Brightness.dark);
      controller.dispose();
    });
  });

  group('(b) live switch on write', () {
    testWidgets('setMode LIGHT switches brightness + writes store',
        (tester) async {
      final map = <String, String>{};
      final controller = ThemeModeController(store: _fakeStore(map));
      await controller.load();
      await _pumpApp(tester, controller);
      expect(_appTheme(tester).brightness, Brightness.dark);

      await controller.setMode('LIGHT');
      // Advance through the capture window + the 450ms fade.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 3));

      expect(map[SettingsStore.themeModeKey], 'LIGHT');
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.themeMode, ThemeMode.light);
      expect(_appTheme(tester).brightness, Brightness.light);
      expect(NotelColors.brightness, Brightness.light);
      expect(NotelColors.surface, NotelColors.lightPalette.surface);
      controller.dispose();
    });
  });

  group('(c) SYSTEM follows platform brightness', () {
    testWidgets('platform flip live-switches, stored value untouched',
        (tester) async {
      tester.platformDispatcher.platformBrightnessTestValue =
          Brightness.light;
      addTearDown(
          tester.platformDispatcher.clearPlatformBrightnessTestValue);
      final map = <String, String>{
        SettingsStore.themeModeKey: 'SYSTEM',
      };
      final controller = ThemeModeController(store: _fakeStore(map));
      await controller.load();
      await _pumpApp(tester, controller);
      expect(_appTheme(tester).brightness, Brightness.light);
      final appBefore =
          tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(appBefore.themeMode, ThemeMode.system);

      // The device setting flips to dark.
      tester.platformDispatcher.platformBrightnessTestValue =
          Brightness.dark;
      controller.didChangePlatformBrightness();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(seconds: 3));

      expect(_appTheme(tester).brightness, Brightness.dark);
      expect(NotelColors.brightness, Brightness.dark);
      // The selection stays System; the stored value never moved.
      final appAfter =
          tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(appAfter.themeMode, ThemeMode.system);
      expect(controller.mode, 'SYSTEM');
      expect(map[SettingsStore.themeModeKey], 'SYSTEM');
      controller.dispose();
    });
  });
}
