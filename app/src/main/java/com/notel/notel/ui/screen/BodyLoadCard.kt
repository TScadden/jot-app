package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.CutCornerShape
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
                    modifier = Modifier.width(38.dp).clickable { onDaySelected(dateStr) }
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

        Surface(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
            shape = RoundedCornerShape(12.dp),
            color = Color.Black.copy(alpha = 0.3f),
            border = BorderStroke(1.dp, Color.White.copy(alpha = 0.1f))
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(12.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Left: Main Score (Replaces Fitbit Logo)
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .background(NotelSurfaceHigh.copy(alpha = 0.1f), RoundedCornerShape(8.dp))
                        .border(2.dp, Brush.sweepGradient(listOf(Color(0xFFFF5252), Color(0xFF42A5F5), Color(0xFF7C6EFF), Color(0xFFFF5252))), RoundedCornerShape(8.dp)),
                    contentAlignment = Alignment.Center
                ) {
                    if (isLoading) {
                        CircularProgressIndicator(color = NotelPrimary, strokeWidth = 1.dp, modifier = Modifier.size(20.dp))
                    } else {
                        Text(
                            text = score.toString(),
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Black,
                            color = NotelTextPrimary
                        )
                    }
                }

                // Center Metrics
                Row(
                    modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // Calories
                    MetricItem(
                        icon = Icons.Default.Whatshot,
                        value = "${state.activeCalories}",
                        color = Color(0xFFFF5252)
                    )

                    // Jots (represented similarly to steps icon in the UI image)
                    MetricItem(
                        icon = Icons.Default.Edit,
                        value = "${state.jotCountDaily}",
                        color = Color(0xFF66BB6A)
                    )

                    // Sleep
                    MetricItem(
                        icon = Icons.Default.Nightlight,
                        value = formatSleep(state.sleepMinutes),
                        color = Color(0xFF42A5F5)
                    )
                }

                // Right: Sleep Debt (Replaces Clock)
                val debtMins = state.sleepDebtMins
                if (!isLoading) {
                    val isDeficit = debtMins < 0
                    val h = Math.abs(debtMins) / 60
                    val m = Math.abs(debtMins) % 60
                    val dStr = if (isDeficit) "-${h}h ${m}m" else "+${h}h ${m}m"
                    val bColor = if (!isDeficit) Color(0xFF66BB6A) else if (Math.abs(debtMins) > 600) Color(0xFFFF5252) else Color(0xFFFFB74D)

                    Row(
                        modifier = Modifier.clickable { showDebtHistory = true },
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Icon(
                            Icons.Default.AccessTime,
                            null,
                            tint = Color.Gray,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = dStr,
                            color = bColor,
                            fontSize = 13.sp,
                            fontWeight = FontWeight.Bold
                        )
                    }
                }
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
fun MetricItem(
    icon: ImageVector,
    value: String,
    color: Color
) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = color, modifier = Modifier.size(16.dp))
        Spacer(Modifier.width(4.dp))
        Text(value, color = Color.White, fontSize = 15.sp, fontWeight = FontWeight.Bold)
    }
}

@Composable
fun SmallPillarNode(
    icon: ImageVector,
    value: String,
    label: String,
    progress: Float,
    color: Color
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.width(38.dp)) {
        Box(
            modifier = Modifier
                .size(38.dp)
                .background(NotelSurface, CircleShape)
                .border(1.5.dp, NotelSurfaceHigh.copy(alpha = 0.2f), CircleShape),
            contentAlignment = Alignment.Center
        ) {
            Canvas(modifier = Modifier.fillMaxSize().padding(2.dp)) {
                drawArc(
                    color = color,
                    startAngle = -90f,
                    sweepAngle = 360f * progress,
                    useCenter = false,
                    style = Stroke(width = 2.dp.toPx(), cap = StrokeCap.Round)
                )
            }
            Icon(icon, null, tint = color, modifier = Modifier.size(16.dp))
        }
        Spacer(Modifier.height(4.dp))
        Text(value, color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 12.sp)
        Text(label, color = NotelTextSecondary, fontSize = 7.sp, fontWeight = FontWeight.Bold)
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
