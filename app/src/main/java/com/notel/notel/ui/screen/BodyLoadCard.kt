package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.GlassyCard
import com.notel.notel.ui.theme.*
import kotlin.math.PI
import kotlin.math.sin

/**
 * Displays the "Body Load Index" as an animated cup fill.
 *
 * @param score     0–100 load score. 0 = empty/great, 100 = overflowing/critical.
 * @param factors   List of (label, weight) pairs — top contributors to the load.
 * @param isLoading Show a shimmer/placeholder if the AI is still calculating.
 */
@Composable
fun BodyLoadCard(
    score: Int = 65,
    factors: List<Pair<String, Int>> = emptyList(),
    isLoading: Boolean = false,
    onAnalyzeClick: () -> Unit = {}
) {
    // Animate the fill level
    val animatedFill by animateFloatAsState(
        targetValue = score / 100f,
        animationSpec = spring(
            dampingRatio = Spring.DampingRatioMediumBouncy,
            stiffness = Spring.StiffnessLow
        ),
        label = "fill"
    )

    // Sloshing wave
    val infiniteTransition = rememberInfiniteTransition(label = "wave")
    val wavePhase by infiniteTransition.animateFloat(
        initialValue = 0f,
        targetValue = (2f * PI.toFloat()),
        animationSpec = infiniteRepeatable(
            animation = tween(3200, easing = LinearEasing),
            repeatMode = RepeatMode.Restart
        ),
        label = "wavePhase"
    )

    // Color shifts blue → amber → red as score rises
    val fillColor = when {
        score < 35 -> Color(0xFF4FC3F7)
        score < 65 -> Color(0xFFFFB74D)
        else       -> Color(0xFFEF5350)
    }

    val statusText = when {
        score < 35 -> "Low Load · Feeling good 🟢"
        score < 65 -> "Moderate Load · Monitor trends 🟡"
        else       -> "High Load · Body under stress 🔴"
    }

    GlassyCard(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp),
        color = NotelSurface
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 20.dp, horizontal = 16.dp)
        ) {
            // Header
            Text(
                "Body Load Index",
                color = NotelTextPrimary,
                fontWeight = FontWeight.ExtraBold,
                fontSize = 17.sp,
                letterSpacing = 0.3.sp
            )
            Text(
                "Subjective · Based on your logs",
                color = NotelTextSecondary,
                fontSize = 11.sp
            )

            Spacer(Modifier.height(20.dp))

            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.Center,
                modifier = Modifier.fillMaxWidth()
            ) {
                // ── Cup silhouette ──────────────────────────────────
                Canvas(modifier = Modifier.size(130.dp, 160.dp)) {
                    val w = size.width
                    val h = size.height

                    // ── Cup outline path (open top trapezoid cup) ──
                    val cupPath = Path().apply {
                        // Top left edge
                        moveTo(w * 0.15f, h * 0.05f)
                        // Down to bottom left (rounded base)
                        lineTo(w * 0.25f, h * 0.90f)
                        quadraticTo(
                            w * 0.27f, h * 0.98f,
                            w * 0.35f, h * 0.98f
                        )
                        // Bottom across
                        lineTo(w * 0.65f, h * 0.98f)
                        quadraticTo(
                            w * 0.73f, h * 0.98f,
                            w * 0.75f, h * 0.90f
                        )
                        // Up to top right edge
                        lineTo(w * 0.85f, h * 0.05f)
                        // Top edge is an ellipse arc for perspective
                        quadraticTo(
                            w * 0.50f, h * 0.00f,
                            w * 0.15f, h * 0.05f
                        )
                        close()
                    }

                    // For the "depth" effect, let's also define the inner ellipse at the top
                    val topRimPath = Path().apply {
                        addOval(
                            androidx.compose.ui.geometry.Rect(
                                left = w * 0.15f,
                                top = -h * 0.02f, // Lifted slightly
                                right = w * 0.85f,
                                bottom = h * 0.10f
                            )
                        )
                    }

                    // ── Animated water fill ──
                    clipPath(cupPath) {
                        val fillY = h * (1f - animatedFill * 0.93f) // Keep it within the cup height

                        // Background wave (depth/shadow layer)
                        val bgWave = Path().apply {
                            moveTo(0f, h)
                            lineTo(0f, fillY + sin(wavePhase + 1.0f) * 5f + 5f)
                            var x = 0f
                            while (x <= w) {
                                lineTo(x, fillY + sin(x / 30f + wavePhase + 1.0f) * 5f + 5f)
                                x += 3f
                            }
                            lineTo(w, h)
                            close()
                        }

                        // Foreground wave (top surface)
                        val fgWave = Path().apply {
                            moveTo(0f, h)
                            lineTo(0f, fillY + sin(wavePhase) * 5f)
                            var x = 0f
                            while (x <= w) {
                                lineTo(x, fillY + sin(x / 28f + wavePhase) * 5f)
                                x += 3f
                            }
                            lineTo(w, h)
                            close()
                        }

                        drawPath(bgWave, color = fillColor.copy(alpha = 0.28f))
                        drawPath(fgWave, color = fillColor.copy(alpha = 0.72f))
                    }

                    // ── Outline drawn on top ──
                    val outlineAlpha = if (score > 0) 0.80f else 0.30f
                    val outlineStyle = Stroke(
                        width = 3.dp.toPx(),
                        cap = StrokeCap.Round,
                        join = StrokeJoin.Round
                    )
                    drawPath(cupPath, color = fillColor.copy(alpha = outlineAlpha), style = outlineStyle)
                    // Draw the top rim too
                    drawPath(topRimPath, color = fillColor.copy(alpha = outlineAlpha * 0.4f), style = outlineStyle)
                }

                Spacer(Modifier.width(20.dp))

                // ── Score + label ────────────────────────────────────────
                Column(
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                    modifier = Modifier.weight(1f)
                ) {
                    // Big score number
                    Text(
                        "$score",
                        color = fillColor,
                        fontSize = 52.sp,
                        fontWeight = FontWeight.Black,
                        lineHeight = 52.sp
                    )
                    Text(
                        "out of 100",
                        color = NotelTextSecondary,
                        fontSize = 12.sp
                    )

                    Spacer(Modifier.height(6.dp))

                    Text(
                        statusText,
                        color = NotelTextSecondary,
                        fontSize = 12.sp,
                        lineHeight = 17.sp,
                        fontWeight = FontWeight.Medium
                    )

                    Spacer(Modifier.height(10.dp))

                    if (isLoading) {
                        Text("Analyzing…", color = NotelTextSecondary, fontSize = 11.sp)
                    } else if (factors.isNotEmpty()) {
                        Text(
                            "Top contributors:",
                            color = NotelTextSecondary,
                            fontSize = 10.sp,
                            fontWeight = FontWeight.SemiBold
                        )
                        Spacer(Modifier.height(2.dp))
                        factors.take(4).forEach { (label, _) ->
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("▲", color = fillColor, fontSize = 9.sp)
                                Spacer(Modifier.width(4.dp))
                                Text(label, color = NotelTextSecondary, fontSize = 11.sp)
                            }
                        }
                    } else {
                        TextButton(
                            onClick = onAnalyzeClick,
                            contentPadding = PaddingValues(0.dp)
                        ) {
                            Text(
                                "Analyze my logs →",
                                color = NotelPrimary,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                        }
                    }
                }
            }
        }
    }
}
