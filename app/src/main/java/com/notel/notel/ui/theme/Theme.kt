package com.notel.notel.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

/** User-facing appearance choice. Persisted in NotelPreferences ("theme_mode"). */
enum class ThemeMode {
    /** Always dark (the historical behavior; also the default for existing users). */
    DARK,
    /** Always light. */
    LIGHT,
    /** Follow the OS dark/light setting. */
    SYSTEM;

    companion object {
        fun fromStored(value: String?): ThemeMode = when (value?.uppercase()) {
            "LIGHT" -> LIGHT
            "SYSTEM" -> SYSTEM
            else -> DARK
        }
        fun toStored(mode: ThemeMode): String = mode.name
    }
}

private fun darkScheme(p: NotelPalette) = darkColorScheme(
    primary          = p.primary,
    onPrimary        = p.onAccent,        // deep ink on white fills (~18:1) — AA
    secondary        = p.accent,
    onSecondary      = p.onAccent,
    background       = p.background,
    onBackground     = p.textPrimary,
    surface          = p.surface,
    onSurface        = p.textPrimary,
    surfaceVariant   = p.surfaceHigh,
    onSurfaceVariant = p.textSecondary,
    tertiary         = p.primary,
    outline          = p.border,
    error            = p.error,
    onError          = Color(0xFFFFFFFF),
)

private fun lightScheme(p: NotelPalette) = lightColorScheme(
    primary          = p.primary,
    onPrimary        = p.onAccent,        // white on black fills (~19.8:1) — AA
    secondary        = p.accent,
    onSecondary      = p.onAccent,
    background       = p.background,
    onBackground     = p.textPrimary,       // ~15:1 — AA
    surface          = p.surface,
    onSurface        = p.textPrimary,
    surfaceVariant   = p.surfaceHigh,
    onSurfaceVariant = p.textSecondary,     // ~7:1 — AA
    tertiary         = p.primary,
    outline          = p.border,
    error            = p.error,             // 5.12:1 on #F4F4F8 — AA
    onError          = Color(0xFFFFFFFF),
)

@Composable
fun NotelTheme(
    themeMode: ThemeMode = ThemeMode.DARK,
    content: @Composable () -> Unit
) {
    val darkTheme = when (themeMode) {
        ThemeMode.DARK -> true
        ThemeMode.LIGHT -> false
        ThemeMode.SYSTEM -> isSystemInDarkTheme()
    }
    val palette = if (darkTheme) DarkNotelPalette else LightNotelPalette
    val colorScheme = if (darkTheme) darkScheme(palette) else lightScheme(palette)

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = colorScheme.background.toArgb()
            window.navigationBarColor = colorScheme.background.toArgb()
            // Light status-bar icons on dark bg, dark icons on light bg.
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = !darkTheme
            WindowCompat.getInsetsController(window, view).isAppearanceLightNavigationBars = !darkTheme
        }
    }

    CompositionLocalProvider(LocalNotelPalette provides palette) {
        MaterialTheme(
            colorScheme = colorScheme,
            typography = Typography,
            content = content
        )
    }
}
