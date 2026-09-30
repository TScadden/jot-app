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

// ── Pure color math (unit-testable; no Compose runtime needed) ───────────────

/**
 * WCAG 2.1 contrast ratio (1–21) between two opaque ARGB colors.
 * Used to pin the light-mode alert ramp to its AA targets in unit tests.
 */
fun contrastRatio(argb1: Int, argb2: Int): Double {
    fun luminance(argb: Int): Double {
        fun channel(c: Int): Double {
            val s = c / 255.0
            return if (s <= 0.03928) s / 12.92 else Math.pow((s + 0.055) / 1.055, 2.4)
        }
        val r = channel((argb shr 16) and 0xFF)
        val g = channel((argb shr 8) and 0xFF)
        val b = channel(argb and 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
    val l1 = luminance(argb1)
    val l2 = luminance(argb2)
    val (lighter, darker) = if (l1 >= l2) l1 to l2 else l2 to l1
    return (lighter + 0.05) / (darker + 0.05)
}

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

// ── Error-tint ramp (Mira light-mode polish spec, 2026-09-27) ────────────────
// Soft red surface treatment for alert cards (spike summaries, error banners).
// Light values are the spec ramp (all WCAG AA-verified); dark values are the
// legacy maroon fills so dark mode renders byte-identically.
// The raw ARGB constants exist so unit tests can verify the WCAG contrast
// ratios without a Compose runtime.
internal const val ErrorTintSurfaceLightArgb = 0xFFF9E2E0L
internal const val ErrorTintSurfaceDarkArgb = 0xFF2A121AL
internal const val ErrorTintBorderLightArgb = 0xFFEFC7C2L
internal const val ErrorTintStrongLightArgb = 0xFFF6D9D7L
internal const val ErrorTintStrongDarkArgb = 0xFF4A1820L
internal const val ErrorTintOnLightArgb = 0xFF9B1C1CL

/** Alert card surface — light #F9E2E0 / dark legacy maroon #2A121A. */
val NotelErrorTint: Color
    @Composable get() = if (isLightTheme) Color(ErrorTintSurfaceLightArgb) else Color(ErrorTintSurfaceDarkArgb)

/** Alert card 1dp border — light #EFC7C2 / dark the standard card hairline. */
val NotelErrorTintBorder: Color
    @Composable get() = if (isLightTheme) Color(ErrorTintBorderLightArgb) else NotelPrimary.copy(alpha = 0.18f)

/** Icon-circle / rank-badge fill on the alert surface — light #F6D9D7 / dark #4A1820. */
val NotelErrorTintStrong: Color
    @Composable get() = if (isLightTheme) Color(ErrorTintStrongLightArgb) else Color(ErrorTintStrongDarkArgb)

/** Glyph / badge text on the alert surface — light #9B1C1C / dark NotelError. */
val NotelErrorTintOn: Color
    @Composable get() = if (isLightTheme) Color(ErrorTintOnLightArgb) else NotelError

/** Solid "High load"-style badge fill — light error red / dark legacy maroon. */
val NotelErrorBadgeFill: Color
    @Composable get() = if (isLightTheme) NotelError else Color(ErrorTintStrongDarkArgb)

/** Text on the solid error badge — light white / dark NotelError. */
val NotelErrorBadgeText: Color
    @Composable get() = if (isLightTheme) NotelOnAccent else NotelError

// ── Legacy dark values (Step 2 light-mode polish, 2026-09-27) ────────────────
// Pre-polish hardcoded dark fills, preserved exactly so dark mode renders
// byte-identically. UI code references these tokens — never raw literals —
// per the audit rule ("no raw color literals in UI code, everything through
// theme tokens"). All are dark-theme-only except NotelOnAccent.

/** Solid white — text/icons on accent fills (either theme). */
val NotelOnAccent: Color = Color.White

/** White text/icons on dark surfaces (dark theme only). */
val LegacyDarkOnDark: Color = Color.White

// Heart-screen pills (Fitbit)
val LegacyDarkAsleepPill: Color = Color(0xFF1A1B36)
val LegacyDarkAsleepPillBorder: Color = Color(0xFF2C2E5D)
val LegacyDarkAsleepInk: Color = Color(0xFFA49BFF)
val LegacyDarkLastPill: Color = Color(0xFF12233D)
val LegacyDarkLastPillBorder: Color = Color(0xFF1E3A66)
val LegacyDarkReviewButton: Color = Color(0xFF19223D)
val LegacyDarkConnectCircle: Color = Color(0xFF1E284A)

// Dialogs / sheets
val LegacyDarkDialog: Color = Color(0xFF161622)
val LegacyDarkSheet: Color = Color(0xFF1E293B)

// Food error banner (legacy reds)
val LegacyDarkFoodErrorSurface: Color = Color(0xFF2C1E1E)
val LegacyDarkFoodErrorBorder: Color = Color(0xFFD32F2F).copy(alpha = 0.3f)
val LegacyDarkFoodErrorInk: Color = Color(0xFFFFCDD2)

// Selected filter-chip text (dark ink on the saturated chip fill;
// used by both the ALL chip and the category chips)
val LegacyDarkChipInk: Color = Color(0xFF0A0A0E)

// Disabled glass button
val LegacyDarkDisabledButton: Color = Color(0xFF1E2A3A)
val LegacyDarkDisabledButtonBorder: Color = Color(0xFF253040)

// Dark translucent overlays / hairlines (alpha tints of black/white)
val LegacyDarkScrim: Color = Color.Black.copy(alpha = 0.3f)
val LegacyDarkHairline: Color = Color.White.copy(alpha = 0.1f)
val LegacyDarkHairlineFaint: Color = Color.White.copy(alpha = 0.05f)
val LegacyDarkDivider: Color = Color.White.copy(alpha = 0.15f)
val LegacyDarkTopDivider: Color = Color.White.copy(alpha = 0.08f)
val LegacyDarkNoDataRing: Color = Color.White.copy(alpha = 0.2f)
val LegacyDarkNoDataTick: Color = Color.White.copy(alpha = 0.25f)
val LegacyDarkGrid: Color = Color.White.copy(alpha = 0.06f)
