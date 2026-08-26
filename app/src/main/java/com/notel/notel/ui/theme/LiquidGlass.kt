package com.notel.notel.ui.theme

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Surface
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * Solid dark-navy tile modifier — replaces the old liquid glass effect.
 * Applies:
 *  - Solid [color] background
 *  - Subtle 1dp [NotelPrimary]-tinted border
 *  - Clip to [shape]
 */
fun Modifier.liquidGlass(
    shape: Shape = RoundedCornerShape(16.dp),
    color: Color = NotelSurface,
    showBorder: Boolean = true,
    alpha: Float = 1f,
    borderWidth: Dp = 1.dp
): Modifier = this.then(
    Modifier
        .clip(shape)
        .background(color.copy(alpha = alpha.coerceIn(0f, 1f)))
        .then(
            if (showBorder) Modifier.border(
                width = borderWidth,
                color = NotelPrimary.copy(alpha = 0.18f),
                shape = shape
            ) else Modifier
        )
)

/**
 * A solid-filled action button using the tile theme's primary cyan color.
 */
@Composable
fun GlassyButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    containerColor: Color = NotelPrimary,
    shape: Shape = RoundedCornerShape(14.dp),
    contentPadding: PaddingValues = PaddingValues(horizontal = 24.dp, vertical = 12.dp),
    content: @Composable RowScope.() -> Unit
) {
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()

    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.96f else 1f,
        animationSpec = spring(stiffness = Spring.StiffnessLow),
        label = "scale"
    )

    val resolvedColor = if (enabled) containerColor else Color(0xFF1E2A3A)
    val borderColor  = if (enabled) containerColor.copy(alpha = 0.6f) else Color(0xFF253040)

    Surface(
        onClick = onClick,
        enabled = enabled,
        interactionSource = interactionSource,
        modifier = modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .clip(shape)
            .border(width = 1.dp, color = borderColor, shape = shape),
        color = resolvedColor,
        shape = shape
    ) {
        Row(
            modifier = Modifier.padding(contentPadding),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
            content = content
        )
    }
}

/**
 * Tile-style card — solid deep-navy background with a subtle cyan border.
 * Drop-in replacement for the old GlassyCard.
 */
@Composable
fun GlassyCard(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(16.dp),
    color: Color = NotelSurface,
    content: @Composable ColumnScope.() -> Unit
) {
    Box(
        modifier = modifier
            .clip(shape)
            .background(color)
            .border(width = 1.dp, color = NotelPrimary.copy(alpha = 0.18f), shape = shape)
            .padding(16.dp),
        contentAlignment = Alignment.TopStart
    ) {
        Column(content = content)
    }
}

/**
 * Animated spinner — kept as-is for loading states.
 */
@Composable
fun GlassySpinner(
    modifier: Modifier = Modifier,
    color: Color = NotelPrimary,
    size: Dp = 48.dp
) {
    val infiniteTransition = rememberInfiniteTransition(label = "spinner")

    val rotation by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = tween(1000, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "rotation"
    )

    val pulseScale by infiniteTransition.animateFloat(
        initialValue = 0.8f,
        targetValue = 1.2f,
        animationSpec = infiniteRepeatable(
            animation = tween(800, easing = FastOutSlowInEasing),
            repeatMode = RepeatMode.Reverse
        ),
        label = "pulse"
    )

    Box(
        modifier = modifier
            .size(size)
            .clip(RoundedCornerShape(50))
            .background(NotelSurface)
            .border(1.dp, color.copy(alpha = 0.25f), RoundedCornerShape(50)),
        contentAlignment = Alignment.Center
    ) {
        androidx.compose.foundation.Canvas(
            modifier = Modifier
                .size(size * 0.72f)
                .graphicsLayer { rotationZ = rotation }
        ) {
            drawArc(
                brush = Brush.sweepGradient(
                    listOf(color.copy(alpha = 0.05f), color.copy(alpha = 0.9f), color.copy(alpha = 0.05f))
                ),
                startAngle = 0f,
                sweepAngle = 300f,
                useCenter = false,
                style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round)
            )
        }

        Box(
            modifier = Modifier
                .size(size * 0.22f)
                .graphicsLayer {
                    scaleX = pulseScale
                    scaleY = pulseScale
                }
                .background(color.copy(alpha = 0.85f), RoundedCornerShape(50))
        )
    }
}
