package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.*
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.BodyLoadState
import kotlin.math.PI
import kotlin.math.sin

@Composable
fun BodyLoadCard(
    state: BodyLoadState,
    onDaySelected: (String) -> Unit = {},
    onFactorSelected: (String?) -> Unit = {},
    onResetSelection: () -> Unit = {}
) {
    val score = state.score
    val isLoading = state.isLoading
    val todayStr = java.time.LocalDate.now().toString()

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 16.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // ── Top Row: Days of the Week ──────────────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 24.dp),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            // Generate last 7 days
            val last7Days = (0..6).map { 
                val d = java.time.LocalDate.now().minusDays(it.toLong())
                d.toString() to d.format(java.time.format.DateTimeFormatter.ofPattern("EEE"))
            }.reversed()

            last7Days.forEach { (dateStr, dayLabel) ->
                val historicalScore = state.historyScores.find { it.date == dateStr }?.score ?: 0
                val isSelected = state.selectedDate == dateStr
                
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.clickable { onDaySelected(dateStr) }
                ) {
                    Text(dayLabel, color = NotelTextSecondary, fontSize = 12.sp, modifier = Modifier.padding(bottom = 6.dp))
                    Box(
                        modifier = Modifier
                            .size(38.dp)
                            .border(
                                width = if (isSelected) 2.dp else 1.dp,
                                brush = if (isSelected) Brush.linearGradient(listOf(NotelPrimary, NotelAccent)) else SolidColor(NotelSurfaceHigh.copy(alpha = 0.5f)),
                                shape = CircleShape
                            ),
                        contentAlignment = Alignment.Center
                     ) {
                        Text(
                            text = if (historicalScore > 0) historicalScore.toString() else "-",
                            color = if (isSelected) NotelTextPrimary else NotelTextSecondary,
                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                            fontSize = 13.sp
                        )
                    }
                }
            }
        }

        Spacer(Modifier.height(16.dp))

        // ── Main Tree Section ──────────────────────────────────────────
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(320.dp),
            contentAlignment = Alignment.TopCenter
        ) {
            // ... (Canvas and Node tree remains the same logic)
            Canvas(modifier = Modifier.fillMaxSize()) {
                val centerTop = Offset(size.width / 2, 70.dp.toPx())
                val splitY = 160.dp.toPx()
                val bottomY = 240.dp.toPx()
                val itemWidth = size.width / 3
                val p1 = Offset(itemWidth * 0.5f, bottomY)
                val p2 = Offset(itemWidth * 1.5f, bottomY)
                val p3 = Offset(itemWidth * 2.5f, bottomY)
                val lineStyle = Stroke(width = 1.5.dp.toPx(), cap = StrokeCap.Round)
                val lineColor = NotelSurfaceHigh.copy(alpha = 0.6f)
                drawLine(lineColor, centerTop.copy(y = centerTop.y + 50.dp.toPx()), Offset(size.width / 2, splitY), strokeWidth = lineStyle.width)
                drawLine(lineColor, Offset(p1.x, splitY), Offset(p3.x, splitY), strokeWidth = lineStyle.width)
                drawLine(lineColor, Offset(p1.x, splitY), p1, strokeWidth = lineStyle.width)
                drawLine(lineColor, Offset(p2.x, splitY), p2, strokeWidth = lineStyle.width)
                drawLine(lineColor, Offset(p3.x, splitY), p3, strokeWidth = lineStyle.width)
            }

            // Central Big Node (The Score)
            Column(
                modifier = Modifier.align(Alignment.TopCenter),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                val infiniteTransition = rememberInfiniteTransition()
                val rotation by infiniteTransition.animateFloat(
                    initialValue = 0f,
                    targetValue = 360f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(15000, easing = LinearEasing),
                        repeatMode = RepeatMode.Restart
                    )
                )

                Box(
                    modifier = Modifier.size(100.dp),
                    contentAlignment = Alignment.Center
                ) {
                    // Smooth sweep gradient ring
                    Canvas(modifier = Modifier.fillMaxSize()) {
                        val strokeWidth = 5.dp.toPx()
                        
                        val gradientColors = listOf(
                            Color(0xFFFF5252), // Red
                            Color(0xFF42A5F5), // Blue
                            Color(0xFF7C6EFF), // Purple
                            Color(0xFFFF5252)  // Close loop
                        )
                        
                        rotate(rotation) {
                            drawArc(
                                brush = Brush.sweepGradient(gradientColors),
                                startAngle = 0f,
                                sweepAngle = 360f,
                                useCenter = false,
                                style = Stroke(width = strokeWidth, cap = StrokeCap.Round)
                            )
                        }
                    }

                    if (isLoading) {
                        CircularProgressIndicator(color = NotelPrimary, modifier = Modifier.size(24.dp))
                    } else {
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(
                                text = score.toString(),
                                fontSize = 42.sp,
                                fontWeight = FontWeight.Black,
                                color = NotelTextPrimary
                            )
                        }
                    }
                }
            }

            // Sub-Pillars Bottom Row
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .align(Alignment.BottomCenter)
                    .padding(bottom = 10.dp),
                horizontalArrangement = Arrangement.SpaceAround,
                verticalAlignment = Alignment.Top
            ) {
                // Calories Pillar
                PillarNode(
                    modifier = Modifier,
                    icon = Icons.Default.Whatshot,
                    value = "${state.activeCalories}",
                    target = "",
                    label = "CALORIES",
                    progress = state.factors.find { it.name.lowercase().contains("cal") || it.name.lowercase().contains("activity") }?.weight?.times(3.0f)?.coerceIn(0f, 1f)
                                ?: (state.activeCalories / 2500f).coerceIn(0f, 1f),
                    color = Color(0xFFFF5252) // Red
                )
                
                // Sleep Pillar
                PillarNode(
                    modifier = Modifier,
                    icon = Icons.Default.Nightlight,
                    value = formatSleep(state.sleepMinutes),
                    target = "",
                    label = "HOURS SLEPT",
                    progress = state.factors.find { it.name.lowercase().contains("sleep") || it.name.lowercase().contains("rest") }?.weight?.times(3.5f)?.coerceIn(0f, 1f)
                                ?: (state.sleepMinutes / 480f).coerceIn(0f, 1f),
                    color = Color(0xFF42A5F5) // Blue
                )
                
                // Jots Pillar
                PillarNode(
                    modifier = Modifier,
                    icon = Icons.Default.Edit,
                    value = "${state.jotCountDaily}",
                    target = "",
                    label = "JOTS",
                    progress = state.factors.find { it.name.lowercase().contains("jot") || it.name.lowercase().contains("note") }?.weight?.times(3.0f)?.coerceIn(0f, 1f) 
                                ?: (state.jotCount7Days / 20f).coerceIn(0f, 1f),
                    color = Color(0xFF7C6EFF) // Purple
                )
            }
        }
            
        Spacer(Modifier.height(24.dp))
        Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                // Current Streak
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .liquidGlass(shape = RoundedCornerShape(16.dp), color = NotelBackground, alpha = 0.6f)
                        .padding(vertical = 12.dp, horizontal = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = "🔥 ${state.currentStreak}",
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        text = "Current Streak",
                        fontSize = 11.sp,
                        color = NotelTextSecondary,
                        fontWeight = FontWeight.Medium
                    )
                }

                // Best Streak
                Column(
                    modifier = Modifier
                        .weight(1f)
                        .liquidGlass(shape = RoundedCornerShape(16.dp), color = NotelBackground, alpha = 0.6f)
                        .padding(vertical = 12.dp, horizontal = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Text(
                        text = "🏆 ${state.bestStreak}",
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                    Spacer(Modifier.height(2.dp))
                    Text(
                        text = "Best Streak",
                        fontSize = 11.sp,
                        color = NotelTextSecondary,
                        fontWeight = FontWeight.Medium
                    )
                }
            }
        

    }
}

@Composable
fun PillarNode(
    modifier: Modifier = Modifier,
    icon: ImageVector,
    value: String,
    target: String,
    label: String,
    progress: Float,
    color: Color
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = modifier.width(80.dp)) {
        Box(
            modifier = Modifier
                .size(54.dp)
                .background(NotelSurface, CircleShape)
                .border(2.dp, NotelSurfaceHigh.copy(alpha = 0.3f), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            // Circular Progress
            Canvas(modifier = Modifier.fillMaxSize().padding(2.dp)) {
                drawArc(
                    color = color,
                    startAngle = -90f,
                    sweepAngle = 360f * progress,
                    useCenter = false,
                    style = Stroke(width = 3.dp.toPx(), cap = StrokeCap.Round)
                )
            }
            Icon(icon, null, tint = color, modifier = Modifier.size(20.dp))
        }
        Spacer(Modifier.height(8.dp))
        Row(verticalAlignment = Alignment.Bottom) {
            Text(value, color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            if (target.isNotEmpty()) {
                Text("/$target", color = NotelTextSecondary, fontSize = 10.sp, modifier = Modifier.padding(bottom = 1.dp))
            }
        }
        Text(label, color = NotelTextSecondary, fontSize = 8.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
    }
}

private fun formatSleep(mins: Int): String {
    val h = mins / 60
    val m = mins % 60
    return if (h > 0) "${h}h${m}m" else "${m}m"
}

private fun getFactorColor(name: String): Color {
    val lowName = name.lowercase()
    return when {
        lowName.contains("hrv") || lowName.contains("ready") -> Color(0xFF4DB6AC) // Teal/Mint for HRV
        lowName.contains("cal") || lowName.contains("activity") || lowName.contains("exercise") -> Color(0xFFFF5252) // Red
        lowName.contains("sleep") || lowName.contains("rest") -> Color(0xFF42A5F5) // Blue
        lowName.contains("jot") || lowName.contains("note") -> Color(0xFF7C6EFF) // Purple
        lowName.contains("cardio") || lowName.contains("pots") || lowName.contains("hr") || lowName.contains("spike") -> Color(0xFF7C6EFF) // Purple
        lowName.contains("mcas") || lowName.contains("histamine") || lowName.contains("allergy") -> Color(0xFFFFB74D) // Orange
        else -> NotelPrimary
    }
}
