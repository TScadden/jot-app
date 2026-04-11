package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.*
import androidx.compose.ui.platform.LocalDensity
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
    var showDebtHistory by remember { mutableStateOf(false) }
    
    if (showDebtHistory) {
        SleepDebtHistoryDialog(
            history = state.sleepDebtHistory,
            onDismiss = { showDebtHistory = false }
        )
    }

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

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(400.dp),
            contentAlignment = Alignment.Center
        ) {
            val radius = 130.dp
            val radPx: Float = with(LocalDensity.current) { radius.toPx() }
            
            // Generative Connection Lines (Equilateral Triangle Vertices)
            Canvas(modifier = Modifier.fillMaxSize()) {
                val hub = Offset(size.width / 2, size.height / 2)
                val lineStyle = Stroke(width = 1.dp.toPx(), cap = StrokeCap.Round)
                val lineColor = NotelSurfaceHigh.copy(alpha = 0.3f)
                
                // Vertices relative to Hub
                val v1 = Offset(hub.x, hub.y - radPx) // Top
                val v2 = Offset(hub.x - radPx * 0.866f, hub.y + radPx * 0.5f) // Bottom Left
                val v3 = Offset(hub.x + radPx * 0.866f, hub.y + radPx * 0.5f) // Bottom Right
                
                drawLine(lineColor, hub, v1, strokeWidth = lineStyle.width)
                drawLine(lineColor, hub, v2, strokeWidth = lineStyle.width)
                drawLine(lineColor, hub, v3, strokeWidth = lineStyle.width)
            }

            // Central Score Hub
            Column(
                modifier = Modifier.align(Alignment.Center),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                // ... (Rotation logic remains)
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
                    modifier = Modifier.size(110.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Canvas(modifier = Modifier.fillMaxSize()) {
                        val strokeWidth = 5.dp.toPx()
                        val gradientColors = listOf(Color(0xFFFF5252), Color(0xFF42A5F5), Color(0xFF7C6EFF), Color(0xFFFF5252))
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
                        Text(
                            text = score.toString(),
                            fontSize = 44.sp,
                            fontWeight = FontWeight.Black,
                            color = NotelTextPrimary
                        )
                    }
                }
                Text("SUMMARY", fontSize = 10.sp, color = NotelTextSecondary, fontWeight = FontWeight.Bold)
            }

            // Triangle Vertices (Node Orbiters)
            
            // 1. Calories (Top Node)
            Box(modifier = Modifier.align(Alignment.Center).offset(y = -radius)) {
                PillarNode(
                    icon = Icons.Default.Whatshot,
                    value = "${state.activeCalories}",
                    target = "",
                    label = "CALORIES",
                    progress = (state.activeCalories / 2500f).coerceIn(0f, 1f),
                    color = Color(0xFFFF5252)
                )
            }

            // 2. Sleep (Bottom Left Node)
            Box(modifier = Modifier.align(Alignment.Center).offset(x = -radius * 0.866f, y = radius * 0.5f)) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    PillarNode(
                        icon = Icons.Default.Nightlight,
                        value = formatSleep(state.sleepMinutes),
                        target = "8h",
                        label = "SLEEP",
                        progress = (state.sleepMinutes / 480f).coerceIn(0f, 1f),
                        color = Color(0xFF42A5F5)
                    )
                    
                    // Sleep Debt
                    val debtMins = state.sleepDebtMins
                    if (!isLoading) {
                        val isSurplus = debtMins > 0
                        val isDeficit = debtMins < 0
                        val dDebt = if (isDeficit) -debtMins else debtMins
                        val h = dDebt / 60
                        val m = dDebt % 60
                        val dStr = if (h > 0) "${h}h ${m}m" else "${m}m"
                        val lbl = if (isSurplus) "surplus" else if (isDeficit) "deficit" else "balanced"
                        val bColor = if (isSurplus) Color(0xFF66BB6A) else if (isDeficit && dDebt > 600) Color(0xFFFF5252) else Color(0xFFFFB74D)

                        Surface(
                            shape = RoundedCornerShape(8.dp),
                            color = NotelSurface.copy(alpha = 0.8f),
                            modifier = Modifier
                                .offset(y = (-4).dp)
                                .clickable { showDebtHistory = true }
                                .border(1.dp, bColor.copy(alpha = 0.3f), RoundedCornerShape(8.dp))
                                .padding(horizontal = 6.dp, vertical = 2.dp)
                        ) {
                            Text("$dStr $lbl", color = bColor, fontSize = 8.sp, fontWeight = FontWeight.Bold)
                        }
                    }
                }
            }

            // 3. Jots (Bottom Right Node)
            Box(modifier = Modifier.align(Alignment.Center).offset(x = radius * 0.866f, y = radius * 0.5f)) {
                PillarNode(
                    icon = Icons.Default.Edit,
                    value = "${state.jotCountDaily}",
                    target = "",
                    label = "JOTS",
                    progress = (state.jotCount7Days / 20f).coerceIn(0f, 1f),
                    color = Color(0xFF7C6EFF)
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
@Composable
fun SleepDebtHistoryDialog(
    history: List<Triple<String, Double, Double>>,
    onDismiss: () -> Unit
) {
    androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
        Surface(
            modifier = Modifier
                .fillMaxWidth(0.9f)
                .fillMaxHeight(0.7f),
            shape = RoundedCornerShape(16.dp),
            color = NotelBackground
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(16.dp)
            ) {
                Text(
                    text = "Sleep Bank Ledger",
                    style = MaterialTheme.typography.titleLarge,
                    color = Color.White
                )
                Text(
                    text = "Target: 8h | Walk from oldest history",
                    style = MaterialTheme.typography.bodySmall,
                    color = Color.Gray,
                    modifier = Modifier.padding(bottom = 16.dp)
                )
                
                LazyColumn(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(history.reversed()) { triple ->
                        val (date, delta, balanceHours) = triple
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .liquidGlass(shape = RoundedCornerShape(8.dp), alpha = 0.1f)
                                .padding(12.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column {
                                Text(date, color = Color.Gray, fontSize = 10.sp)
                                val isSurplus = balanceHours >= 0
                                val balanceColor = if (isSurplus) Color(0xFF66BB6A) else Color(0xFFFF5252)
                                val h = Math.abs(balanceHours).toInt()
                                val m = ((Math.abs(balanceHours) - h) * 60).toInt()
                                val balanceStr = (if (isSurplus) "+" else "-") + "${h}h ${m}m"
                                
                                Text(
                                    text = if (isSurplus) "$balanceStr Surplus" else "$balanceStr Deficit",
                                    color = balanceColor,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold
                                )
                                Text(
                                    text = "Total Bank",
                                    color = Color.Gray,
                                    fontSize = 9.sp
                                )
                            }
                            
                            // Daily Delta on the right
                            Column(horizontalAlignment = Alignment.End) {
                                val isPosDelta = delta >= 0
                                val deltaColor = if (isPosDelta) Color(0xFF66BB6A).copy(alpha = 0.8f) else Color(0xFFFFB74D).copy(alpha = 0.8f)
                                val dh = Math.abs(delta).toInt()
                                val dm = ((Math.abs(delta) - dh) * 60).toInt()
                                val deltaStr = (if (isPosDelta) "+" else "-") + "${dh}h ${dm}m"
                                
                                Text(
                                    text = deltaStr,
                                    color = deltaColor,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    text = "Daily Impact",
                                    color = Color.Gray,
                                    fontSize = 9.sp
                                )
                            }
                        }
                    }
                }
                
                Button(
                    onClick = onDismiss,
                    modifier = Modifier.align(Alignment.End).padding(top = 16.dp),
                    colors = ButtonDefaults.buttonColors(containerColor = Color.White.copy(alpha = 0.1f))
                ) {
                    Text("Close", color = Color.White)
                }
            }
        }
    }
}
