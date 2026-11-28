import 'package:flutter/material.dart';

/// One complete Tabs palette (theme-mode package, Nov 27, 2026).
///
/// Two const instances exist — [NotelColors.darkPalette] (the
/// shipped BlackGlass v4 values, byte-identical to the pre-package
/// tokens) and [NotelColors.lightPalette] (the founder-approved
/// light starting point from the settings mock — bg #F4F4F8, cards
/// white, text #14141C, accent unchanged — with secondary/semantic
/// values darkened until every text/surface pair passes WCAG AA;
/// measured ratios are recorded in PATTERN.md and pinned by
/// test/theme_mode_test.dart).
class NotelPalette {
  const NotelPalette({
    required this.background,
    required this.surface,
    required this.surfaceHigh,
    required this.primaryText,
    required this.textPrimary,
    required this.textSecondary,
    required this.error,
    required this.success,
    required this.warning,
    required this.info,
    required this.streakGold,
    required this.heartRateRed,
    required this.cardBorder,
    required this.fieldBorderIdle,
    required this.checkboxBorderIdle,
    required this.divider,
    required this.legacyDarkScrim,
    required this.legacyDarkHairline,
    required this.legacyDarkHairlineFaint,
    required this.legacyDarkDivider,
    required this.legacyDarkOnDark,
    required this.chartGrid,
    required this.noDataRing,
    required this.noDataTick,
    required this.errorTint,
    required this.errorTintStrong,
    required this.legacyDarkAsleepPill,
    required this.legacyDarkAsleepPillBorder,
    required this.legacyDarkAsleepInk,
    required this.legacyDarkLastPill,
    required this.legacyDarkLastPillBorder,
    required this.legacyDarkReviewButton,
    required this.legacyDarkConnectCircle,
    required this.restingBand,
    required this.restingSwatch,
    required this.heartChartGridY,
    required this.heartChartGridX,
  });

  final Color background;
  final Color surface;
  final Color surfaceHigh;
  final Color primaryText;
  final Color textPrimary;
  final Color textSecondary;
  final Color error;
  final Color success;
  final Color warning;
  final Color info;
  final Color streakGold;
  final Color heartRateRed;
  final Color cardBorder;
  final Color fieldBorderIdle;
  final Color checkboxBorderIdle;
  final Color divider;
  final Color legacyDarkScrim;
  final Color legacyDarkHairline;
  final Color legacyDarkHairlineFaint;
  final Color legacyDarkDivider;
  final Color legacyDarkOnDark;
  final Color chartGrid;
  final Color noDataRing;
  final Color noDataTick;
  final Color errorTint;
  final Color errorTintStrong;
  final Color legacyDarkAsleepPill;
  final Color legacyDarkAsleepPillBorder;
  final Color legacyDarkAsleepInk;
  final Color legacyDarkLastPill;
  final Color legacyDarkLastPillBorder;
  final Color legacyDarkReviewButton;
  final Color legacyDarkConnectCircle;
  final Color restingBand;
  final Color restingSwatch;
  final Color heartChartGridY;
  final Color heartChartGridX;
}

/// Tabs design tokens, ported verbatim from the native app's
/// `DarkNotelPalette` (the native default) in `ui/theme/Color.kt`.
///
/// Theme-mode package (Nov 27, 2026): the static API is unchanged —
/// every call site still reads `NotelColors.<token>` — but the
/// theme-varying tokens are now getters backed by the
/// brightness-selected palette ([darkPalette] / [lightPalette]).
/// The active brightness is driven by `ThemeModeController`
/// (theme_mode_controller.dart) from the stored theme mode; it
/// defaults to dark, so any surface that never opts in renders
/// exactly the shipped dark values. Tokens that are identical in
/// both themes (the brand [primary] above all) stay `static const`.
abstract final class NotelColors {
  // BlackGlass v4 (Lab, Nov 3, 2026; ported to the release line
  // in VC 100116): the near-black theme values live at the token
  // level so every surface that reads these tokens takes the
  // theme with zero geometry/string/behavior change. Contrast:
  // textPrimary on background 18.18:1, textSecondary on surface
  // 6.70:1 (AA, v3-verified values re-checked for this palette).
  /// The shipped default page background (BlackGlass v4 near-black).
  /// This is the value every device resolves in dark mode when no
  /// dev override is set, and the value Reset returns to.
  static const defaultBackground = Color(0xFF0A0A0B);

  /// The light palette's page background (founder-approved mock).
  static const defaultBackgroundLight = Color(0xFFF4F4F8);

  static const darkPalette = NotelPalette(
    background: defaultBackground,
    surface: Color(0xFF101013),
    surfaceHigh: Color(0xFF0C0C0F),
    primaryText: Color(0xFF9D94FF),
    textPrimary: Color(0xFFF5F5F7),
    textSecondary: Color(0xFF9A9AA3),
    error: Color(0xFFFF6B6B),
    success: Color(0xFF4CAF50),
    warning: Color(0xFFFFB74D),
    info: Color(0xFF42A5F5),
    streakGold: Color(0xFFFFD700),
    heartRateRed: Color(0xFFFF5E62),
    cardBorder: Color(0x267C6EFF),
    fieldBorderIdle: Color(0x669A9AA3),
    checkboxBorderIdle: Color(0x999A9AA3),
    divider: Color(0x339A9AA3),
    legacyDarkScrim: Color(0x4D000000),
    legacyDarkHairline: Color(0x1AFFFFFF),
    legacyDarkHairlineFaint: Color(0x0DFFFFFF),
    legacyDarkDivider: Color(0x26FFFFFF),
    legacyDarkOnDark: Color(0xFFFFFFFF),
    chartGrid: Color(0x0FFFFFFF),
    noDataRing: Color(0x33FFFFFF),
    noDataTick: Color(0x40FFFFFF),
    errorTint: Color(0xFF2A121A),
    errorTintStrong: Color(0xFF4A1820),
    legacyDarkAsleepPill: Color(0xFF1A1B36),
    legacyDarkAsleepPillBorder: Color(0xFF2C2E5D),
    legacyDarkAsleepInk: Color(0xFFA49BFF),
    legacyDarkLastPill: Color(0xFF12233D),
    legacyDarkLastPillBorder: Color(0xFF1E3A66),
    legacyDarkReviewButton: Color(0xFF19223D),
    legacyDarkConnectCircle: Color(0xFF1E284A),
    restingBand: Color(0xFF1B2847),
    restingSwatch: Color(0xFF2A385E),
    heartChartGridY: Color(0xFF222F4C),
    heartChartGridX: Color(0xFF1D2A47),
  );

  /// Light palette. Measured WCAG ratios (design audit §2 method):
  /// textPrimary/background 16.70:1, textPrimary/surface 18.32:1,
  /// textSecondary/surface 7.62:1, textSecondary/background 6.94:1,
  /// textSecondary/surfaceHigh 6.25:1, primaryText/surface 6.84:1.
  static const lightPalette = NotelPalette(
    background: defaultBackgroundLight,
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFE8E8F0),
    primaryText: Color(0xFF5340D6),
    textPrimary: Color(0xFF14141C),
    textSecondary: Color(0xFF525266),
    error: Color(0xFFC62828),
    success: Color(0xFF2E7D32),
    warning: Color(0xFF8D5A00),
    info: Color(0xFF1565C0),
    streakGold: Color(0xFF7A5C00),
    heartRateRed: Color(0xFFD32F2F),
    cardBorder: Color(0x267C6EFF),
    fieldBorderIdle: Color(0x66525266),
    checkboxBorderIdle: Color(0x99525266),
    divider: Color(0x33525266),
    legacyDarkScrim: Color(0xA6FFFFFF),
    legacyDarkHairline: Color(0x1A000000),
    legacyDarkHairlineFaint: Color(0x0D000000),
    legacyDarkDivider: Color(0x26000000),
    legacyDarkOnDark: Color(0xFF14141C),
    chartGrid: Color(0x0F000000),
    noDataRing: Color(0x33000000),
    noDataTick: Color(0x40000000),
    errorTint: Color(0xFFFDECEA),
    errorTintStrong: Color(0xFFF9D7D7),
    legacyDarkAsleepPill: Color(0xFFE3E4F5),
    legacyDarkAsleepPillBorder: Color(0xFFC5C8EC),
    legacyDarkAsleepInk: Color(0xFF4A3FBF),
    legacyDarkLastPill: Color(0xFFDCE9F7),
    legacyDarkLastPillBorder: Color(0xFFB9D2EE),
    legacyDarkReviewButton: Color(0xFFE3EAF6),
    legacyDarkConnectCircle: Color(0xFFDDE4F2),
    restingBand: Color(0xFFD7E0F2),
    restingSwatch: Color(0xFFB9C8E4),
    heartChartGridY: Color(0xFFC9D2E4),
    heartChartGridX: Color(0xFFD3DAE9),
  );

  static Brightness _brightness = Brightness.dark;

  /// The brightness the token getters currently resolve against.
  static Brightness get brightness => _brightness;

  static bool get isLight => _brightness == Brightness.light;

  /// Selects the active palette. Driven ONLY by
  /// `ThemeModeController` / the app root's cross-fade coordinator
  /// (and by tests resetting state); screens never call this.
  static void setBrightness(Brightness value) => _brightness = value;

  static NotelPalette get palette =>
      isLight ? lightPalette : darkPalette;

  static Color? _backgroundOverride;

  /// True when a dev background override is explicitly in effect
  /// (the override wins over BOTH palettes' backgrounds).
  static bool get hasBackgroundOverride => _backgroundOverride != null;

  /// The resolved page background: the dev override when one is
  /// explicitly set, otherwise the active palette's background.
  /// The override lives ONLY in local prefs (see
  /// `AppBackgroundController` in app_background.dart) — it is
  /// never synced and never part of the profile payload, so
  /// non-dev users always resolve the palette value. Every
  /// scaffold/app-bar that paints the page background reads this
  /// getter, and the app theme's `scaffoldBackgroundColor`
  /// resolves from the same value, so one override re-skins the
  /// base background app-wide. Card / surface tokens ([surface],
  /// [surfaceHigh]) never follow it.
  static Color get background => _backgroundOverride ?? palette.background;

  /// Sets an explicit resolved-[background] override. App-facing
  /// writes go through `AppBackgroundController` (which persists
  /// + notifies); this setter is the token-level seam it drives.
  static set backgroundOverride(Color value) =>
      _backgroundOverride = value;

  /// Clears any explicit override: [background] returns to the
  /// active palette's value (dark default in dark mode, the light
  /// background in light mode).
  static void clearBackgroundOverride() => _backgroundOverride = null;

  // Settings-fidelity round (audit P2/P3): surface #1A1A1E ->
  // #101013 (card-over-background step +16.3 -> +6.5, the DNA's
  // +5-10 band); surfaceHigh #121215 -> #0C0C0F (nested one step
  // DARKER than the new card, -4 levels; P3 direction was
  // indeterminate in the audit, resolved to UI_FORMAT_SPEC).
  static Color get surface => palette.surface;
  static Color get surfaceHigh => palette.surfaceHigh;
  static const primary = Color(0xFF7C6EFF); // Tabs purple — primary actions

  /// Lighter tint of the brand hue for small purple text on L2 /
  /// tinted surfaces only (dark palette); the light palette uses a
  /// DARKER tint of the same hue, since the direction that keeps
  /// small purple text at AA flips with the surface. Never a fill.
  /// Brand [primary] is unchanged and remains the fill / icon /
  /// large-accent color (Round 53, Mira treatment spec §0).
  static Color get primaryText => palette.primaryText;

  /// Settings logout pill fill (Round 53, Mira treatment spec SE9;
  /// tokenize-only — replaces the raw literal in settings_screen.dart
  /// when that file is next touched).
  static const logoutRed = Color(0xFF801515);
  static Color get textPrimary => palette.textPrimary;
  static Color get textSecondary => palette.textSecondary;

  /// Ink on a [primary] fill — the `_chipInk` precedent from the
  /// History / Quick Log category chips (native `LegacyDarkChipInk`),
  /// measured 5.21:1 on primary where white measures 3.80:1
  /// (Round 49 audit S1). For chips, pills, and small labels on a
  /// primary fill; large bold primary button labels keep white per
  /// the founder exception.
  static const onPrimary = Color(0xFF0A0A0E);

  /// UV "Extreme" data color in the weather info sheets (data-series
  /// color, not a text/surface role).
  static const uvExtreme = Color(0xFFCE93D8);
  static Color get error => palette.error;
  static Color get success => palette.success;
  static Color get warning => palette.warning;
  static Color get info => palette.info;

  /// Legacy dark-theme glass tokens (native `LegacyDark*` in
  /// Color.kt). The names are historical; each carries a light
  /// counterpart in the palette (light scrim / dark hairlines /
  /// dark on-scrim ink) so the surfaces that read them — the
  /// vitals strip above all — render correctly in both themes.
  static Color get legacyDarkScrim => palette.legacyDarkScrim;
  static Color get legacyDarkHairline => palette.legacyDarkHairline;
  static Color get legacyDarkHairlineFaint =>
      palette.legacyDarkHairlineFaint;
  static Color get legacyDarkDivider => palette.legacyDarkDivider;
  static Color get legacyDarkOnDark => palette.legacyDarkOnDark;

  /// Best-streak gold (native: Color(0xFFFFD700) literal in
  /// TodayScreen.kt; the light palette darkens it to an AA gold —
  /// it is a value TEXT token, not a fill).
  static Color get streakGold => palette.streakGold;

  /// Callout-chip icon backgrounds on the welcome screen
  /// (native: 0xFFA855F7 / 0xFFEC4899 literals). Fills in both
  /// themes; unchanged.
  static const chipPurple = Color(0xFFA855F7);
  static const chipPink = Color(0xFFEC4899);

  /// Card hairline: primary at 15% alpha (native:
  /// NotelPrimary.copy(alpha = 0.15f)).
  static Color get cardBorder => palette.cardBorder;

  /// Unfocused text-field border (native:
  /// NotelTextSecondary.copy(alpha = 0.4f)).
  static Color get fieldBorderIdle => palette.fieldBorderIdle;

  /// Unchecked checkbox border (native:
  /// NotelTextSecondary.copy(alpha = 0.6f)).
  static Color get checkboxBorderIdle => palette.checkboxBorderIdle;

  /// "or" divider line (native: NotelTextSecondary.copy(alpha = 0.2f)).
  static Color get divider => palette.divider;

  /// Weekly Snapshot chart tokens (native `WeeklySnapshotCard.kt`).
  static Color get chartGrid => palette.chartGrid;
  static Color get noDataRing => palette.noDataRing;
  static Color get noDataTick => palette.noDataTick;
  static Color get heartRateRed => palette.heartRateRed;

  /// Heart screen tokens (round 25; native `Color.kt` values +
  /// `FitbitScreen.kt` graph literals).
  static Color get errorTint => palette.errorTint;
  static Color get errorTintStrong => palette.errorTintStrong;
  static Color get legacyDarkAsleepPill => palette.legacyDarkAsleepPill;
  static Color get legacyDarkAsleepPillBorder =>
      palette.legacyDarkAsleepPillBorder;
  static Color get legacyDarkAsleepInk => palette.legacyDarkAsleepInk;
  static Color get legacyDarkLastPill => palette.legacyDarkLastPill;
  static Color get legacyDarkLastPillBorder =>
      palette.legacyDarkLastPillBorder;
  static Color get legacyDarkReviewButton =>
      palette.legacyDarkReviewButton;
  static Color get legacyDarkConnectCircle =>
      palette.legacyDarkConnectCircle;
  static Color get restingBand => palette.restingBand;
  static Color get restingSwatch => palette.restingSwatch;
  static Color get heartChartGridY => palette.heartChartGridY;
  static Color get heartChartGridX => palette.heartChartGridX;
}
