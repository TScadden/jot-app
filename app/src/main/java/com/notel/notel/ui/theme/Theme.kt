package com.notel.notel.ui.theme

import android.app.Activity
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.SideEffect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalView
import androidx.core.view.WindowCompat

private val DarkColorScheme = darkColorScheme(
    primary          = NotelPrimary,                    // Cyan
    onPrimary        = Color(0xFFFFFFFF),              // White on purple
    secondary        = NotelAccent,                     // Purple
    onSecondary      = NotelTextPrimary,
    background       = NotelBackground,                 // Deep navy page background
    onBackground     = NotelTextPrimary,
    surface          = NotelSurface,                    // Tile card background
    onSurface        = NotelTextPrimary,
    surfaceVariant   = NotelSurfaceHigh,                // Elevated tile surface
    onSurfaceVariant = NotelTextSecondary,
    tertiary         = NotelPrimary,
    outline          = NotelPrimary.copy(alpha = 0.25f)
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
            window.navigationBarColor = colorScheme.background.toArgb()
            WindowCompat.getInsetsController(window, view).isAppearanceLightStatusBars = false
        }
    }

    MaterialTheme(
        colorScheme = colorScheme,
        typography = Typography,
        content = content
    )
}