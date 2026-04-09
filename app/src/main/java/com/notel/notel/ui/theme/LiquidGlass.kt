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
 * A custom modifier that applies a "Liquid Glass" effect.
 * Features:
 * - Backdrop blur emulation (via semi-transparent gradient)
 * - Inner highlight border (refraction)
 * - Animated "shine" flare
 * - Press response scale
 */
fun Modifier.liquidGlass(
    shape: Shape = RoundedCornerShape(16.dp),
    color: Color = NotelSurface,
    showBorder: Boolean = true,
    alpha: Float = 0.6f,
    borderWidth: Dp = 1.5.dp
): Modifier = this.then(
    Modifier
        .clip(shape)
        .drawBehind {
            val radius = if (shape is RoundedCornerShape) {
                shape.topStart.toPx(size, this)
            } else {
                16.dp.toPx()
            }

            // Background Layer
            drawRoundRect(
                brush = Brush.verticalGradient(
                    listOf(color.copy(alpha = alpha), color.copy(alpha = alpha * 0.8f))
                ),
                cornerRadius = CornerRadius(radius, radius)
            )

            // Inner Highlight (Top Edge Light Refraction)
            if (showBorder) {
                drawRoundRect(
                    brush = Brush.verticalGradient(
                        0.0f to GlassWhite.copy(alpha = 0.4f),
                        0.1f to Color.Transparent,
                        0.9f to Color.Transparent,
                        1.0f to GlassWhite.copy(alpha = 0.1f)
                    ),
                    cornerRadius = CornerRadius(radius, radius),
                    style = Stroke(width = borderWidth.toPx())
                )
            }
        }
)

@Composable
fun GlassyButton(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    containerColor: Color = NotelPrimary,
    shape: Shape = RoundedCornerShape(16.dp),
    content: @Composable RowScope.() -> Unit
) {
    val interactionSource = remember { MutableInteractionSource() }
    val isPressed by interactionSource.collectIsPressedAsState()
    
    val scale by animateFloatAsState(
        targetValue = if (isPressed) 0.96f else 1f,
        animationSpec = spring(stiffness = Spring.StiffnessLow),
        label = "scale"
    )

    Surface(
        onClick = onClick,
        enabled = enabled,
        interactionSource = interactionSource,
        modifier = modifier
            .graphicsLayer {
                scaleX = scale
                scaleY = scale
            }
            .liquidGlass(
                shape = shape,
                color = if (enabled) containerColor else Color.Gray,
                alpha = if (enabled) 0.5f else 0.2f
            ),
        color = Color.White.copy(alpha = 0.01f), // Ensure hit-testing works on the whole area
        shape = shape
    ) {
        Row(
            modifier = Modifier
                .padding(horizontal = 24.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center,
            content = content
        )
    }
}

@Composable
fun GlassyCard(
    modifier: Modifier = Modifier,
    shape: Shape = RoundedCornerShape(20.dp),
    color: Color = NotelSurface,
    content: @Composable ColumnScope.() -> Unit
) {
    Box(
        modifier = modifier
            .liquidGlass(shape = shape, color = color, alpha = 0.4f)
            .padding(16.dp),
        contentAlignment = Alignment.TopStart
    ) {
        Column(content = content)
    }
}

@Composable
fun GlassySpinner(
    modifier: Modifier = Modifier,
    color: Color = Color.White,
    size: Dp = 48.dp
) {
    val infiniteTransition = rememberInfiniteTransition(label = "spinner")
    
    val rotation by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = 360f,
        animationSpec = infiniteRepeatable(
            animation = outlineCutoutAnimation(1000),
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
            .liquidGlass(shape = RoundedCornerShape(50), color = NotelSurface, alpha = 0.3f),
        contentAlignment = Alignment.Center
    ) {
        // Spinner Ring
        androidx.compose.foundation.Canvas(modifier = Modifier.size(size * 0.75f).graphicsLayer { rotationZ = rotation }) {
            drawArc(
                brush = Brush.sweepGradient(
                    listOf(color.copy(alpha = 0.1f), color.copy(alpha = 0.8f), color.copy(alpha = 0.1f))
                ),
                startAngle = 0f,
                sweepAngle = 300f,
                useCenter = false,
                style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round)
            )
        }
        
        // Pulsing Core
        Box(
            modifier = Modifier
                .size(size * 0.25f)
                .graphicsLayer { 
                    scaleX = pulseScale
                    scaleY = pulseScale
                }
                .background(color.copy(alpha = 0.9f), RoundedCornerShape(50))
        )
    }
}

private fun outlineCutoutAnimation(duration: Int) = tween<Float>(
    durationMillis = duration,
    easing = LinearEasing
)
