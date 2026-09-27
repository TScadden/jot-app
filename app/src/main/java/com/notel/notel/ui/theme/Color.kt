package com.notel.notel.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color

/**
 * Theme-aware color palette (light-mode toggle, 2026-09-27).
 *
 * Every structural color resolves through [LocalNotelPalette], so the whole
 * app follows the user's Light / Dark / System choice with zero call-site
 * changes: the public vals below keep their exact names and are backed by
 * @Composable getters. They MUST only be read from @Composable UI code —
 * never from ViewModels, workers, widgets, or remember{} calculation
 * lambdas (capture LocalNotelPalette.current as a plain value instead).
 *
 * Light tokens (Mira spec): soft off-white surfaces (#F4F4F8 family — never
 * pure-white large surfaces), hairline borders, depth from elevation tints.
 * Accent verdict: #7C6EFF fails AA on light (3.48:1 as text, 3.80:1 as fill
 * with white labels), so the light primary is the adjusted variant #5445CC
 * (6.21:1 as text, 6.77:1 white-on-fill). Status colors get light variants
 * that pass AA as text; dark variants are the previous values (unchanged).
 */
data class NotelPalette(
    val background: Color,
    val surface: Color,
    val surfaceHigh: Color,
    val primary: Color,
    val accent: Color,
    val textPrimary: Color,
    val textSecondary: Color,
    val border: Color,
    val error: Color,
    val success: Color,
    val warning: Color,
    val info: Color,
)

internal val DarkNotelPalette = NotelPalette(
    background    = Color(0xFF080E1A),   // Very deep navy — page background
    surface       = Color(0xFF0D1428),   // Deep navy — tile card background
    surfaceHigh   = Color(0xFF152040),   // Slightly lighter navy — elevated surfaces
    primary       = Color(0xFF7C6EFF),   // Purple accent — primary actions, headers
    accent        = Color(0xFF7C6EFF),   // Purple — secondary accent
    textPrimary   = Color(0xFFF0EEFF),   // Near-white — primary text
    textSecondary = Color(0xFF7A8FAF),   // Muted blue-grey — secondary text
    border        = Color(0x407C6EFF),   // Primary at 25% — hairlines (was Theme.kt outline)
    error         = Color(0xFFFF6B6B),   // 6.95:1 on dark bg
    success       = Color(0xFF4CAF50),   // 6.94:1 on dark bg
    warning       = Color(0xFFFFB74D),   // 11.15:1 on dark bg
    info          = Color(0xFF42A5F5),   // 7.29:1 on dark bg
)

internal val LightNotelPalette = NotelPalette(
    background    = Color(0xFFF4F4F8),   // Soft off-white — page background
    surface       = Color(0xFFFAFAFC),   // Soft near-white cards (never pure white)
    surfaceHigh   = Color(0xFFE9E9F0),   // Nested / elevated panels
    primary       = Color(0xFF5445CC),   // Adjusted violet — AA on light (see header note)
    accent        = Color(0xFF5445CC),   // Same — one accent, no negotiation
    textPrimary   = Color(0xFF14141C),   // Near-black — ~15:1 on bg
    textSecondary = Color(0xFF5A5A6E),   // Muted slate — ~7:1 on bg
    border        = Color(0xFFDFDFE8),   // Hairline on light
    error         = Color(0xFFC62828),   // 5.12:1 on light bg
    success       = Color(0xFF2E7D32),   // 4.67:1 on light bg
    warning       = Color(0xFFB45309),   // 4.58:1 on light bg
    info          = Color(0xFF1565C0),   // 5.24:1 on light bg
)

val LocalNotelPalette = staticCompositionLocalOf { DarkNotelPalette }

/** True when the currently-provided palette is the light one. */
val isLightTheme: Boolean
    @Composable get() = LocalNotelPalette.current === LightNotelPalette

// ── Public theme colors — @Composable getters over the active palette ────────
val NotelBackground: Color
    @Composable get() = LocalNotelPalette.current.background
val NotelSurface: Color
    @Composable get() = LocalNotelPalette.current.surface
val NotelSurfaceHigh: Color
    @Composable get() = LocalNotelPalette.current.surfaceHigh
val NotelPrimary: Color
    @Composable get() = LocalNotelPalette.current.primary
val NotelAccent: Color
    @Composable get() = LocalNotelPalette.current.accent
val NotelTextPrimary: Color
    @Composable get() = LocalNotelPalette.current.textPrimary
val NotelTextSecondary: Color
    @Composable get() = LocalNotelPalette.current.textSecondary
val NotelBorder: Color
    @Composable get() = LocalNotelPalette.current.border
val NotelError: Color
    @Composable get() = LocalNotelPalette.current.error
val NotelSuccess: Color
    @Composable get() = LocalNotelPalette.current.success
val NotelWarning: Color
    @Composable get() = LocalNotelPalette.current.warning
val NotelInfo: Color
    @Composable get() = LocalNotelPalette.current.info

// ── Legacy glass colors ──────────────────────────────────────────────────────
// GlassBorder was a translucent-white hairline for dark cards; it now follows
// the palette so card borders stay visible in light mode. The other glass
// values are translucent overlays kept as-is for minor decorative uses.
val GlassWhite: Color = Color(0x33FFFFFF)
val GlassWhiteHigh: Color = Color(0x66FFFFFF)
val GlassPrimary: Color = Color(0x4D7C6EFF)
val GlassBorder: Color
    @Composable get() = if (isLightTheme) Color(0x2414141E) else Color(0x26FFFFFF)
val GlassHighlight: Color = Color(0x1AFFFFFF)
