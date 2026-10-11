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

  /// Card hairline: primary at 15% alpha (native: NotelPrimary.copy(alpha = 0.15f)).
  static const cardBorder = Color(0x267C6EFF);

  /// Unfocused text-field border (native: NotelTextSecondary.copy(alpha = 0.4f)).
  static const fieldBorderIdle = Color(0x667A8FAF);

  /// Unchecked checkbox border (native: NotelTextSecondary.copy(alpha = 0.6f)).
  static const checkboxBorderIdle = Color(0x997A8FAF);

  /// "or" divider line (native: NotelTextSecondary.copy(alpha = 0.2f)).
  static const divider = Color(0x337A8FAF);
}
