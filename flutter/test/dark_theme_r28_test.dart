import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tabs_lab/src/data/health_connect_service.dart';
import 'package:tabs_lab/src/data/health_data.dart';
import 'package:tabs_lab/src/data/heart_data_cache.dart';
import 'package:tabs_lab/src/features/heart/heart_screen.dart';
import 'package:tabs_lab/src/theme/notel_colors.dart';
import 'package:tabs_lab/src/theme/notel_theme.dart';

/// Round 28 — dark-theme tests.
///
/// The bug: `MaterialApp` had a minimal ThemeData with no ColorScheme,
/// so stock Material surfaces (the Heart screen's `showDatePicker`)
/// fell back to the default LIGHT Material 3 theme over an all-dark
/// app. `notelDarkTheme()` is the root-cause fix: an explicit dark
/// ColorScheme mapped from the Notel tokens plus sub-themes for the
/// stock surfaces the app uses. These tests pin the scheme mapping and
/// prove the Heart date picker itself now renders on the dark surface.

class FakeHeartHc extends HealthConnectService {
  @override
  Future<bool> isConnected() async => true;

  @override
  Future<bool> hasPersistedConnection() async => true;

  @override
  Future<List<HrSample>> readHeartRateSamples(String dateStr) async =>
      const [];
}

void main() {
  group('notelDarkTheme scheme', () {
    testWidgets('resolves dark brightness and Notel token mapping',
        (tester) async {
      late ThemeData resolved;
      await tester.pumpWidget(MaterialApp(
        theme: notelDarkTheme(),
        home: Builder(builder: (context) {
          resolved = Theme.of(context);
          return const SizedBox();
        }),
      ));

      expect(resolved.brightness, Brightness.dark);
      expect(resolved.colorScheme.brightness, Brightness.dark);
      expect(resolved.colorScheme.primary, NotelColors.primary);
      expect(resolved.colorScheme.onPrimary, NotelColors.textPrimary);
      expect(resolved.colorScheme.surface, NotelColors.surface);
      expect(resolved.colorScheme.onSurface, NotelColors.textPrimary);
      expect(resolved.colorScheme.onSurfaceVariant,
          NotelColors.textSecondary);
      expect(resolved.colorScheme.surfaceContainerHigh,
          NotelColors.surfaceHigh);
      expect(resolved.colorScheme.surfaceContainerLowest,
          NotelColors.background);
      expect(resolved.colorScheme.error, NotelColors.error);
      expect(resolved.scaffoldBackgroundColor, NotelColors.background);
    });

    testWidgets('stock-surface sub-themes are dark Notel surfaces',
        (tester) async {
      late ThemeData resolved;
      await tester.pumpWidget(MaterialApp(
        theme: notelDarkTheme(),
        home: Builder(builder: (context) {
          resolved = Theme.of(context);
          return const SizedBox();
        }),
      ));

      expect(resolved.datePickerTheme.backgroundColor, NotelColors.surface);
      expect(resolved.datePickerTheme.headerBackgroundColor,
          NotelColors.surfaceHigh);
      expect(resolved.timePickerTheme.backgroundColor, NotelColors.surface);
      expect(resolved.dialogTheme.backgroundColor, NotelColors.surface);
      expect(resolved.bottomSheetTheme.backgroundColor, NotelColors.surface);
      expect(resolved.popupMenuTheme.color, NotelColors.surfaceHigh);
      expect(resolved.snackBarTheme.backgroundColor,
          NotelColors.surfaceHigh);
      expect(resolved.textSelectionTheme.cursorColor, NotelColors.primary);
    });
  });

  group('Heart date picker (Round 28 regression)', () {
    setUp(() {
      HeartDataCache.instance.debugReset();
      final store = <String, String>{};
      HeartDataCache.instance.debugSetStore(
        read: (k) async => store[k],
        write: (k, v) async => store[k] = v,
        delete: (k) async => store.remove(k),
      );
    });

    testWidgets('date picker dialog renders on the dark Notel surface',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: notelDarkTheme(),
        home: HeartScreen(
          email: 'a@b.c',
          healthConnectService: FakeHeartHc(),
          cache: HeartDataCache.instance,
        ),
      ));
      await tester.pumpAndSettle();

      // The date pill in the app bar opens the stock showDatePicker.
      await tester.tap(find.text('Today'));
      await tester.pumpAndSettle();

      expect(find.byType(DatePickerDialog), findsOneWidget);

      // The picker dialog's resolved background is the dark token,
      // not the light Material fallback.
      final dialog = tester.widget<Dialog>(find.descendant(
        of: find.byType(DatePickerDialog),
        matching: find.byType(Dialog),
      ));
      expect(dialog.backgroundColor, NotelColors.surface);

      // And the theme the picker subtree resolves is dark.
      final pickerElement = tester.element(find.byType(DatePickerDialog));
      expect(Theme.of(pickerElement).brightness, Brightness.dark);
      expect(Theme.of(pickerElement).colorScheme.surface,
          NotelColors.surface);
    });
  });
}
