import 'package:flutter/material.dart';

import 'notel_colors.dart';
import 'slide_page_route.dart';

/// Round 28 — the app's full dark theme, built from the Notel palette.
///
/// Until now `MaterialApp` carried a minimal [ThemeData] (scaffold
/// background + page transitions only) with NO [ColorScheme], so every
/// STOCK Material surface fell back to the default LIGHT Material 3
/// theme — most visibly the Heart screen's `showDatePicker`, which
/// rendered white over an otherwise all-dark app.
///
/// This theme fixes that at the root: an explicit dark [ColorScheme]
/// mapped from the existing tokens, plus sub-themes for the stock
/// surfaces the app actually uses (date/time pickers, dialogs, modal
/// bottom sheets, dropdown/popup menus, snackbars) and text selection.
/// The app's own screens paint their Notel colors per-widget and do
/// not read these values, so their look is unchanged — only widgets
/// that ask the theme for a color (stock Material surfaces) change,
/// from light-fallback to the app's dark tokens.
ThemeData notelDarkTheme() {
  const colorScheme = ColorScheme.dark(
    primary: NotelColors.primary,
    onPrimary: NotelColors.textPrimary,
    primaryContainer: NotelColors.surfaceHigh,
    onPrimaryContainer: NotelColors.textPrimary,
    secondary: NotelColors.primary,
    onSecondary: NotelColors.textPrimary,
    secondaryContainer: NotelColors.surfaceHigh,
    onSecondaryContainer: NotelColors.textPrimary,
    tertiary: NotelColors.info,
    onTertiary: NotelColors.textPrimary,
    surface: NotelColors.surface,
    onSurface: NotelColors.textPrimary,
    onSurfaceVariant: NotelColors.textSecondary,
    surfaceContainerLowest: NotelColors.background,
    surfaceContainerLow: NotelColors.surface,
    surfaceContainer: NotelColors.surface,
    surfaceContainerHigh: NotelColors.surfaceHigh,
    surfaceContainerHighest: NotelColors.surfaceHigh,
    surfaceDim: NotelColors.background,
    surfaceBright: NotelColors.surfaceHigh,
    inverseSurface: NotelColors.textPrimary,
    onInverseSurface: NotelColors.background,
    inversePrimary: NotelColors.primary,
    error: NotelColors.error,
    onError: NotelColors.textPrimary,
    errorContainer: NotelColors.errorTint,
    onErrorContainer: NotelColors.error,
    outline: NotelColors.fieldBorderIdle,
    outlineVariant: NotelColors.divider,
    scrim: Colors.black,
    shadow: Colors.black,
  );

  // Selected day/year in the stock pickers: Tabs purple fill with the
  // near-white text token on top; unselected entries use the primary
  // text token, disabled entries the secondary token.
  Color? pickerForeground(Set<WidgetState> states) {
    if (states.contains(WidgetState.selected)) {
      return NotelColors.textPrimary;
    }
    if (states.contains(WidgetState.disabled)) {
      return NotelColors.textSecondary;
    }
    return NotelColors.textPrimary;
  }

  Color? pickerBackground(Set<WidgetState> states) {
    if (states.contains(WidgetState.selected)) {
      return NotelColors.primary;
    }
    return Colors.transparent;
  }

  return ThemeData(
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: NotelColors.background,
    pageTransitionsTheme: slidePageTransitionsTheme(),
    dialogTheme: const DialogThemeData(
      backgroundColor: NotelColors.surface,
      surfaceTintColor: Colors.transparent,
      iconColor: NotelColors.textSecondary,
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: NotelColors.surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: NotelColors.surfaceHigh,
      headerForegroundColor: NotelColors.textPrimary,
      dayForegroundColor: WidgetStateProperty.resolveWith(pickerForeground),
      dayBackgroundColor: WidgetStateProperty.resolveWith(pickerBackground),
      todayForegroundColor: WidgetStateProperty.resolveWith(pickerForeground),
      todayBackgroundColor:
          WidgetStateProperty.resolveWith(pickerBackground),
      todayBorder: const BorderSide(color: NotelColors.primary),
      yearForegroundColor: WidgetStateProperty.resolveWith(pickerForeground),
      yearBackgroundColor: WidgetStateProperty.resolveWith(pickerBackground),
    ),
    timePickerTheme: const TimePickerThemeData(
      backgroundColor: NotelColors.surface,
      dialBackgroundColor: NotelColors.surfaceHigh,
      dialHandColor: NotelColors.primary,
      dialTextColor: NotelColors.textPrimary,
      hourMinuteColor: NotelColors.surfaceHigh,
      hourMinuteTextColor: NotelColors.textPrimary,
      entryModeIconColor: NotelColors.textSecondary,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: NotelColors.surface,
      modalBackgroundColor: NotelColors.surface,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: NotelColors.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(color: NotelColors.textPrimary),
      iconColor: NotelColors.textSecondary,
    ),
    menuTheme: const MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(NotelColors.surfaceHigh),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    dropdownMenuTheme: const DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(NotelColors.surfaceHigh),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: NotelColors.surfaceHigh,
      contentTextStyle: TextStyle(color: NotelColors.textPrimary),
      actionTextColor: NotelColors.primary,
      closeIconColor: NotelColors.textSecondary,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: NotelColors.primary,
      selectionColor: Color(0x597C6EFF), // Primary @ 35%
      selectionHandleColor: NotelColors.primary,
    ),
  );
}
