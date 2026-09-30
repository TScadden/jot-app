package com.notel.notel.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

// ── Tabs Lab type scale (professional bar) ─────────────────────────────────────
// One display style, one body, one caption — mapped in DesignTokens.kt:
//
//   Display → typography.titleLarge (22sp, bold at call sites)
//   Body    → typography.bodyLarge  (16sp)
//   Caption → typography.labelMedium (12sp)
//
// Eyebrow section headers use SectionLabel (sentence case, never ALL CAPS).
// Avoid raw fontSize values in new UI code.
val Typography = Typography(
    bodyLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 16.sp,
        lineHeight = 24.sp,
        letterSpacing = 0.5.sp
    )
    /* Other default text styles to override
    titleLarge = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Normal,
        fontSize = 22.sp,
        lineHeight = 28.sp,
        letterSpacing = 0.sp
    ),
    labelSmall = TextStyle(
        fontFamily = FontFamily.Default,
        fontWeight = FontWeight.Medium,
        fontSize = 11.sp,
        lineHeight = 16.sp,
        letterSpacing = 0.5.sp
    )
    */
)