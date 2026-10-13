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

  /// Heart screen tokens (round 25; native `Color.kt` dark values +
  /// `FitbitScreen.kt` graph literals).
  static const errorTint = Color(0xFF2A121A); // NotelErrorTint (dark)
  static const errorTintStrong = Color(0xFF4A1820); // NotelErrorTintStrong / NotelErrorBadgeFill (dark)
  static const legacyDarkAsleepPill = Color(0xFF1A1B36);
  static const legacyDarkAsleepPillBorder = Color(0xFF2C2E5D);
  static const legacyDarkAsleepInk = Color(0xFFA49BFF);
  static const legacyDarkLastPill = Color(0xFF12233D);
  static const legacyDarkLastPillBorder = Color(0xFF1E3A66);
  static const legacyDarkReviewButton = Color(0xFF19223D);
  static const legacyDarkConnectCircle = Color(0xFF1E284A);
  static const restingBand = Color(0xFF1B2847); // graph band fill (drawn @ 60% alpha)
  static const restingSwatch = Color(0xFF2A385E); // legend band swatch
  static const heartChartGridY = Color(0xFF222F4C); // dashed horizontal grid
  static const heartChartGridX = Color(0xFF1D2A47); // dashed vertical grid
}
