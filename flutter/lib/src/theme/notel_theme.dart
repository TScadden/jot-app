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
/// [background] is the resolved base background the theme is
/// built around (scaffold background + the scheme's background
/// slots). It defaults to the resolved [NotelColors.background]
/// token; the dev-only background changer passes the active
/// override explicitly so a change rebuilds the theme — and with
/// it every theme-driven surface — without a restart. Surface
/// tokens are never affected.
ThemeData notelDarkTheme({Color? background}) => _notelTheme(
      brightness: Brightness.dark,
      palette: NotelColors.darkPalette,
      background: background,
    );

/// Theme-mode package (Nov 27, 2026) — the light counterpart to
/// [notelDarkTheme], mirroring its component themes slot for slot
/// from [NotelColors.lightPalette]. Stock Material surfaces render
/// on the light tokens instead of the platform fallback, exactly
/// as the dark theme does for dark mode.
ThemeData notelLightTheme({Color? background}) => _notelTheme(
      brightness: Brightness.light,
      palette: NotelColors.lightPalette,
      background: background,
    );

ThemeData _notelTheme({
  required Brightness brightness,
  required NotelPalette palette,
  Color? background,
}) {
  // The resolved base background for THIS theme: an explicit
  // [background] wins; otherwise a dev override in effect wins
  // over both palettes; otherwise this theme's own palette value —
  // so the dark and light themes built side by side in one
  // MaterialApp are each internally correct even though the token
  // getters resolve against the ACTIVE palette only.
  final resolvedBackground = background ??
      (NotelColors.hasBackgroundOverride
          ? NotelColors.background
          : palette.background);
  final isDark = brightness == Brightness.dark;
  final colorScheme = (isDark ? ColorScheme.dark : ColorScheme.light)(
    primary: NotelColors.primary,
    onPrimary: palette.textPrimary,
    primaryContainer: palette.surfaceHigh,
    onPrimaryContainer: palette.textPrimary,
    secondary: NotelColors.primary,
    onSecondary: palette.textPrimary,
    secondaryContainer: palette.surfaceHigh,
    onSecondaryContainer: palette.textPrimary,
    tertiary: palette.info,
    onTertiary: palette.textPrimary,
    surface: palette.surface,
    onSurface: palette.textPrimary,
    onSurfaceVariant: palette.textSecondary,
    surfaceContainerLowest: resolvedBackground,
    surfaceContainerLow: palette.surface,
    surfaceContainer: palette.surface,
    surfaceContainerHigh: palette.surfaceHigh,
    surfaceContainerHighest: palette.surfaceHigh,
    surfaceDim: resolvedBackground,
    surfaceBright: palette.surfaceHigh,
    inverseSurface: palette.textPrimary,
    onInverseSurface: resolvedBackground,
    inversePrimary: NotelColors.primary,
    error: palette.error,
    onError: palette.textPrimary,
    errorContainer: palette.errorTint,
    onErrorContainer: palette.error,
    outline: palette.fieldBorderIdle,
    outlineVariant: palette.divider,
    scrim: Colors.black,
    shadow: Colors.black,
  );

  // Selected day/year in the stock pickers: Tabs purple fill with
  // the primary text token on top; unselected entries use the
  // primary text token, disabled entries the secondary token.
  Color? pickerForeground(Set<WidgetState> states) {
    if (states.contains(WidgetState.selected)) {
      return palette.textPrimary;
    }
    if (states.contains(WidgetState.disabled)) {
      return palette.textSecondary;
    }
    return palette.textPrimary;
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
  final textTheme = TextTheme(
    displayLarge: TextStyle(
      fontSize: 57,
      color: palette.textPrimary,
    ),
    displayMedium: TextStyle(
      fontSize: 45,
      color: palette.textPrimary,
    ),
    displaySmall: TextStyle(
      fontSize: 36,
      color: palette.textPrimary,
    ),
    headlineLarge: TextStyle(
      fontSize: 32,
      color: palette.textPrimary,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      color: palette.textPrimary,
    ),
    headlineSmall: TextStyle(
      fontSize: 24,
      color: palette.textPrimary,
    ),
    titleLarge: TextStyle(
      fontSize: 22,
      fontWeight: FontWeight.bold,
      color: palette.textPrimary,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.bold,
      color: palette.textPrimary,
    ),
    titleSmall: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.bold,
      color: palette.textPrimary,
    ),
    bodyLarge: TextStyle(
      fontSize: 16,
      color: palette.textPrimary,
    ),
    bodyMedium: TextStyle(
      fontSize: 14,
      color: palette.textPrimary,
    ),
    bodySmall: TextStyle(
      fontSize: 12,
      color: palette.textSecondary,
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: palette.textPrimary,
    ),
    labelMedium: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w600,
      color: palette.textSecondary,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w500,
      color: palette.textSecondary,
    ),
  );

  // Round 49 (audit S2) — stock Material buttons default to a 40dp
  // height app-wide because no button theme set a minimumSize. The
  // theme-level floor is 48dp (the M3 64dp minimum width is kept);
  // call sites that need a taller button still set their own size.
  const buttonMinimumSize = WidgetStatePropertyAll(Size(64, 48));

  return ThemeData(
    brightness: brightness,
    colorScheme: colorScheme,
    scaffoldBackgroundColor: resolvedBackground,
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
    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      iconColor: palette.textSecondary,
    ),
    datePickerTheme: DatePickerThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      headerBackgroundColor: palette.surfaceHigh,
      headerForegroundColor: palette.textPrimary,
      dayForegroundColor: WidgetStateProperty.resolveWith(pickerForeground),
      dayBackgroundColor: WidgetStateProperty.resolveWith(pickerBackground),
      todayForegroundColor: WidgetStateProperty.resolveWith(pickerForeground),
      todayBackgroundColor:
          WidgetStateProperty.resolveWith(pickerBackground),
      todayBorder: const BorderSide(color: NotelColors.primary),
      yearForegroundColor: WidgetStateProperty.resolveWith(pickerForeground),
      yearBackgroundColor: WidgetStateProperty.resolveWith(pickerBackground),
    ),
    timePickerTheme: TimePickerThemeData(
      backgroundColor: palette.surface,
      dialBackgroundColor: palette.surfaceHigh,
      dialHandColor: NotelColors.primary,
      dialTextColor: palette.textPrimary,
      hourMinuteColor: palette.surfaceHigh,
      hourMinuteTextColor: palette.textPrimary,
      entryModeIconColor: palette.textSecondary,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.surface,
      modalBackgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: palette.surfaceHigh,
      surfaceTintColor: Colors.transparent,
      textStyle: TextStyle(color: palette.textPrimary),
      iconColor: palette.textSecondary,
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(palette.surfaceHigh),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(palette.surfaceHigh),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.surfaceHigh,
      contentTextStyle: TextStyle(color: palette.textPrimary),
      actionTextColor: NotelColors.primary,
      closeIconColor: palette.textSecondary,
    ),
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: NotelColors.primary,
      selectionColor: Color(0x597C6EFF), // Primary @ 35%
      selectionHandleColor: NotelColors.primary,
    ),
  );
}
