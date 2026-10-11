import 'package:flutter/material.dart';

/// Tabs design tokens, ported verbatim from the native app's
/// `DarkNotelPalette` (the native default) in `ui/theme/Color.kt`.
abstract final class NotelColors {
  static const background = Color(0xFF080E1A); // Very deep navy — page background
  static const surface = Color(0xFF0D1428); // Deep navy — card background
  static const surfaceHigh = Color(0xFF152040); // Elevated surfaces
  static const primary = Color(0xFF7C6EFF); // Tabs purple — primary actions
  static const textPrimary = Color(0xFFF0EEFF); // Near-white
  static const textSecondary = Color(0xFF7A8FAF); // Muted blue-grey
  static const error = Color(0xFFFF6B6B);
  static const success = Color(0xFF4CAF50); // NotelSuccess (dark palette)
  static const warning = Color(0xFFFFB74D); // NotelWarning (dark palette)
  static const info = Color(0xFF42A5F5); // NotelInfo (dark palette)

  /// Legacy dark-theme glass tokens (native `LegacyDark*` in Color.kt).
  static const legacyDarkScrim = Color(0x4D000000); // Black @ 30% — dark card fill
  static const legacyDarkHairline = Color(0x1AFFFFFF); // White @ 10% — hairline border
  static const legacyDarkHairlineFaint = Color(0x0DFFFFFF); // White @ 5% — faint circle fill (dark)
  static const legacyDarkDivider = Color(0x26FFFFFF); // White @ 15% — dividers
  static const legacyDarkOnDark = Color(0xFFFFFFFF); // White — text on dark scrim

  /// Best-streak gold (native: Color(0xFFFFD700) literal in TodayScreen.kt).
  static const streakGold = Color(0xFFFFD700);

  /// Callout-chip icon backgrounds on the welcome screen
  /// (native: 0xFFA855F7 / 0xFFEC4899 literals).
  static const chipPurple = Color(0xFFA855F7);
  static const chipPink = Color(0xFFEC4899);

  /// Card hairline: primary at 15% alpha (native: NotelPrimary.copy(alpha = 0.15f)).
  static const cardBorder = Color(0x267C6EFF);

  /// Unfocused text-field border (native: NotelTextSecondary.copy(alpha = 0.4f)).
  static const fieldBorderIdle = Color(0x667A8FAF);

  /// Unchecked checkbox border (native: NotelTextSecondary.copy(alpha = 0.6f)).
  static const checkboxBorderIdle = Color(0x997A8FAF);

  /// "or" divider line (native: NotelTextSecondary.copy(alpha = 0.2f)).
  static const divider = Color(0x337A8FAF);

  /// Weekly Snapshot chart tokens (native `WeeklySnapshotCard.kt`, dark theme).
  static const chartGrid = Color(0x0FFFFFFF); // White @ 6% — chart gridlines
  static const noDataRing = Color(0x33FFFFFF); // White @ 20% — empty-day ring
  static const noDataTick = Color(0x40FFFFFF); // White @ 25% — empty-day tick
  static const heartRateRed = Color(0xFFFF5E62); // Resting-HR line color
}
