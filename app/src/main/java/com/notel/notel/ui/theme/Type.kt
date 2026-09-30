package com.notel.notel.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontFeatureSettings
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

// ── Tabs Lab type scale ("Instrument", 2026-09-30) ───────────────────────────────
// Instrument discipline: tabular numerals everywhere (tnum) so columns of
// numbers, streaks, and list values align like a precision instrument.
// A real ramp with editorial tracking: large sizes pull in tight (negative
// letter spacing reads premium), body breathes at 1.5 line height, eyebrows
// stay small caps-free sentence case via SectionLabel in DesignTokens.kt.
//
// Mapped roles:
//   Display   → displaySmall   28sp/600/-0.5  — hero numbers, big scores
//   Headline  → headlineMedium 22sp/600       — screen titles
//   Title     → titleLarge 20sp / titleMedium 17sp / titleSmall 15sp — cards
//   Body      → bodyLarge 16sp / bodyMedium 14sp — reading copy
//   Caption   → labelMedium 12sp / labelSmall 11sp — eyebrows, metadata
//
// Avoid raw fontSize values in new UI code; pick the closest ramp step.
val Typography = Typography(
    displaySmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 28.sp,
        lineHeight = 36.sp,
        letterSpacing = (-0.5).sp
        fontFeatureSettings = FontFeatureSettings("tnum"),
    ),
    headlineMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 22.sp,
        lineHeight = 28.sp,
        letterSpacing = 0.sp
        fontFeatureSettings = FontFeatureSettings("tnum"),
    ),
    titleLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 20.sp,
        lineHeight = 26.sp,
        letterSpacing = 0.sp
        fontFeatureSettings = FontFeatureSettings("tnum"),
    ),
    titleMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 17.sp,
        lineHeight = 22.sp,
        letterSpacing = 0.sp
        fontFeatureSettings = FontFeatureSettings("tnum"),
    ),
    titleSmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 15.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.sp
        fontFeatureSettings = FontFeatureSettings("tnum"),
    ),
    bodyLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        letterSpacing = 0.25.sp
        fontFeatureSettings = FontFeatureSettings("tnum"),
    ),
    bodyMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 14.sp,
        lineHeight = 20.sp,
        letterSpacing = 0.25.sp
        fontFeatureSettings = FontFeatureSettings("tnum"),
    ),
    labelLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 13.sp,
        lineHeight = 18.sp,
        letterSpacing = 0.25.sp
        fontFeatureSettings = FontFeatureSettings("tnum"),
    ),
    labelMedium = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 12.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.4.sp
        fontFeatureSettings = FontFeatureSettings("tnum"),
    ),
    labelSmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.SemiBold,
        fontSize = 11.sp,
        lineHeight = 14.sp,
        letterSpacing = 0.6.sp
        fontFeatureSettings = FontFeatureSettings("tnum"),
    )
)
