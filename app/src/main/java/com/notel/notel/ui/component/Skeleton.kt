package com.notel.notel.ui.component

import android.content.Context
import android.provider.Settings
import android.view.accessibility.AccessibilityManager
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.notel.notel.ui.theme.NotelBorder
import com.notel.notel.ui.theme.NotelSurface
import com.notel.notel.ui.theme.NotelSurfaceHigh
import com.notel.notel.ui.theme.isLightTheme

/**
 * Skeleton loader family (Mira spec, 2026-09-29).
 *
 * Contentless shimmer placeholders that mirror the layout of content that is
 * still loading. All fills resolve through theme tokens ([NotelSurfaceHigh],
 * [NotelSurface], [NotelBorder]); no hardcoded colors.
 */

/** True when the user asked the OS to reduce/remove animations. */
@Composable
private fun rememberIsReducedMotion(): Boolean {
    val context = LocalView.current.context
    return remember(context) {
        val accessibilityManager =
            context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? AccessibilityManager
        val animationsDisabled = Settings.Global.getFloat(
            context.contentResolver,
            Settings.Global.ANIMATOR_DURATION_SCALE,
            1f
        ) == 0f
        (accessibilityManager?.isEnabled == true) && animationsDisabled
    }
}

/**
 * The skeleton fill: [NotelSurfaceHigh] with a slow horizontal shimmer sweep
 * ([base, highlight, base]) translating across the measured width — 1400ms,
 * linear, restart. Static [NotelSurfaceHigh] when reduced motion is on.
 */
@Composable
private fun rememberSkeletonBrush(widthPx: Float): Brush {
    val base = NotelSurfaceHigh
    if (rememberIsReducedMotion() || widthPx <= 0f) return SolidColor(base)
    val highlight = if (isLightTheme) Color.Black.copy(alpha = 0.06f)
    else Color.White.copy(alpha = 0.08f)
    val transition = rememberInfiniteTransition(label = "skeletonShimmer")
    val sweep by transition.animateFloat(
        initialValue = -1f,
        targetValue = 2f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 1400, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "skeletonSweep"
    )
    return remember(base, highlight, sweep, widthPx) {
        val startX = sweep * widthPx
        Brush.horizontalGradient(
            colors = listOf(base, highlight, base),
            startX = startX - widthPx,
            endX = startX
        )
    }
}

/** Single private base every skeleton builds on. */
@Composable
private fun SkeletonShape(
    modifier: Modifier = Modifier,
    shape: Shape
) {
    BoxWithConstraints(modifier = modifier) {
        val density = LocalDensity.current
        val widthPx = remember(density, maxWidth) { with(density) { maxWidth.toPx() } }
        val brush = rememberSkeletonBrush(widthPx)
        Spacer(
            modifier = Modifier
                .fillMaxSize()
                .clip(shape)
                .background(brush)
        )
    }
}

/** Text-line placeholder. */
@Composable
fun SkeletonLine(
    width: Dp,
    height: Dp = 14.dp,
    cornerRadius: Dp = 4.dp,
    modifier: Modifier = Modifier
) {
    SkeletonShape(
        modifier = modifier.width(width).height(height),
        shape = RoundedCornerShape(cornerRadius)
    )
}

/** Text-line placeholder sized as a fraction of the available width. */
@Composable
fun SkeletonLine(
    fraction: Float,
    height: Dp = 14.dp,
    cornerRadius: Dp = 4.dp,
    modifier: Modifier = Modifier
) {
    SkeletonShape(
        modifier = modifier.fillMaxWidth(fraction).height(height),
        shape = RoundedCornerShape(cornerRadius)
    )
}

/** Generic area placeholder (chart, graph, document page, image). */
@Composable
fun SkeletonBlock(
    height: Dp,
    cornerRadius: Dp = 12.dp,
    modifier: Modifier = Modifier
) {
    SkeletonShape(
        modifier = modifier.fillMaxWidth().height(height),
        shape = RoundedCornerShape(cornerRadius)
    )
}

/**
 * Card-shaped placeholder with optional inner content lines. Mirrors the app's
 * card language: real [NotelSurface] at full opacity, 1dp [NotelBorder].
 */
@Composable
fun SkeletonCard(
    height: Dp,
    cornerRadius: Dp = 16.dp,
    contentPadding: Dp = 14.dp,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit = {}
) {
    Surface(
        modifier = modifier.fillMaxWidth().height(height),
        shape = RoundedCornerShape(cornerRadius),
        color = NotelSurface,
        border = BorderStroke(1.dp, NotelBorder)
    ) {
        Column(
            modifier = Modifier.padding(contentPadding),
            content = content
        )
    }
}

/**
 * List-row placeholder: leading badge square, text lines, optional trailing
 * block — on a real card surface with the app's 1dp [NotelBorder].
 */
@Composable
fun SkeletonListRow(
    leadingSize: Dp = 24.dp,
    leadingRadius: Dp = 6.dp,
    lines: Int = 2,
    lineSpacing: Dp = 6.dp,
    trailingWidth: Dp? = null,
    cornerRadius: Dp = 16.dp,
    contentPadding: Dp = 14.dp,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(cornerRadius),
        color = NotelSurface,
        border = BorderStroke(1.dp, NotelBorder)
    ) {
        Row(
            modifier = Modifier.padding(contentPadding),
            verticalAlignment = Alignment.CenterVertically
        ) {
            SkeletonLine(width = leadingSize, height = leadingSize, cornerRadius = leadingRadius)
            Spacer(Modifier.width(12.dp))
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(lineSpacing)
            ) {
                repeat(lines) { index ->
                    SkeletonLine(
                        fraction = if (index == 0) 0.9f else 0.65f,
                        height = 14.dp
                    )
                }
            }
            if (trailingWidth != null) {
                Spacer(Modifier.width(12.dp))
                SkeletonLine(width = trailingWidth, height = 14.dp)
            }
        }
    }
}

/**
 * Full-screen scaffold mirror. Does not guess the screen — each screen composes
 * its own skeleton content from the primitives above.
 */
@Composable
fun SkeletonScreen(
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit
) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(horizontal = 16.dp)
            .semantics { stateDescription = "Loading" },
        verticalArrangement = Arrangement.spacedBy(12.dp),
        content = content
    )
}
