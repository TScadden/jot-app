package com.notel.notel.ui.theme

import android.app.Activity
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

private val DarkColorScheme = darkColorScheme(
    primary        = NotelPrimary,
    onPrimary      = NotelTextPrimary,
    secondary      = NotelAccent,
    onSecondary    = NotelBackground,
    background     = NotelBackground,
    onBackground   = NotelTextPrimary,
    surface        = NotelSurface,
    onSurface      = NotelTextPrimary,
    surfaceVariant = NotelSurfaceHigh,
    onSurfaceVariant = NotelTextSecondary,
    tertiary       = NotelAccent
)

@Composable
fun NotelTheme(
    darkTheme: Boolean = true, // Always dark
    content: @Composable () -> Unit
) {
    val colorScheme = DarkColorScheme

    val view = LocalView.current
    if (!view.isInEditMode) {
        SideEffect {
            val window = (view.context as Activity).window
            window.statusBarColor = colorScheme.background.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = false
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}