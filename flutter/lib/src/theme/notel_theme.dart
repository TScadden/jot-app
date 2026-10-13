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

  // Round 49 (audit S3) — an explicit textTheme built from the app's
  // measured type scale, so M3 defaults stop leaking un-tokenized
  // sizes into stock surfaces and inherited slots (the Settings AppBar
  // title, toggle-row titles, and field hints all inherited silently).
  // Slots with a measured app role carry that role's size/weight/color
  // (titleLarge = the 22sp root/AppBar title, titleMedium = the 16sp
  // card title, titleSmall = the 14sp in-card section header, bodySmall
  // / labelMedium / labelSmall = the textSecondary caption roles);
  // display/headline slots keep their M3 sizes — no new scale — with
  // the textPrimary token applied.
  const textTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: 57,
      color: NotelColors.textPrimary,
    ),
    displayMedium: TextStyle(
      fontSize: 45,
      color: NotelColors.textPrimary,
    ),
    displaySmall: TextStyle(
      fontSize: 36,
      color: NotelColors.textPrimary,
    ),
    headlineLarge: TextStyle(
      fontSize: 32,
      color: NotelColors.textPrimary,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      color: NotelColors.textPrimary,
    ),
    headlineSmall: TextStyle(
      fontSize: 24,
      color: NotelColors.textPrimary,
    ),
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.bold,
      color: NotelColors.textPrimary,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      color: NotelColors.textPrimary,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.bold,
      color: NotelColors.textPrimary,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      color: NotelColors.textPrimary,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      color: NotelColors.textPrimary,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      color: NotelColors.textSecondary,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: NotelColors.textPrimary,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: NotelColors.textSecondary,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      color: NotelColors.textSecondary,
    ),
  );

  // Round 49 (audit S2) — stock Material buttons default to a 40dp
  // height app-wide because no button theme set a minimumSize. The
  // theme-level floor is 48dp (the M3 64dp minimum width is kept);
  // call sites that need a taller button still set their own size.
  const buttonMinimumSize = WidgetStatePropertyAll(Size(64, 48));

  return ThemeData(
    brightness: Brightness.dark,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: NotelColors.background,
    pageTransitionsTheme: slidePageTransitionsTheme(),
    textTheme: textTheme,
    elevatedButtonTheme: const ElevatedButtonThemeData(
      style: ButtonStyle(minimumSize: buttonMinimumSize),
    ),
    filledButtonTheme: const FilledButtonThemeData(
      style: ButtonStyle(minimumSize: buttonMinimumSize),
    ),
    outlinedButtonTheme: const OutlinedButtonThemeData(
      style: ButtonStyle(minimumSize: buttonMinimumSize),
    ),
    textButtonTheme: const TextButtonThemeData(
      style: ButtonStyle(minimumSize: buttonMinimumSize),
    ),
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
