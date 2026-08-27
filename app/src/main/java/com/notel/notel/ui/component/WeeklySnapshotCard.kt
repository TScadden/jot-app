package com.notel.notel.ui.component

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.data.repository.DailySnapshotPoint
import com.notel.notel.data.repository.WeeklySnapshotMetricData
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.WeeklySnapshotState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun WeeklySnapshotCard(
    state: WeeklySnapshotState,
    availableMetrics: List<String>,
    onSelectMetric: (String) -> Unit,
    onRefresh: () -> Unit,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 6.dp),
        color = NotelSurface,
        shape = RoundedCornerShape(18.dp),
        border = BorderStroke(1.dp, GlassBorder)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            // Header Row: Title & Dropdown / Refresh
            var dropdownExpanded by remember { mutableStateOf(false) }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        imageVector = Icons.Default.BarChart,
                        contentDescription = null,
                        tint = NotelPrimary,
                        modifier = Modifier.size(20.dp)
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(
                        text = "Weekly Snapshot",
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary,
                        fontSize = 16.sp
                    )
                }

                Row(verticalAlignment = Alignment.CenterVertically) {
                    IconButton(
                        onClick = onRefresh,
                        modifier = Modifier.size(28.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Refresh,
                            contentDescription = "Refresh Weekly Snapshot",
                            tint = NotelTextSecondary,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
            }

            Spacer(Modifier.height(10.dp))

            // Metric Selector Dropdown Box
            val currentMetric = when (state) {
                is WeeklySnapshotState.Ready -> state.metricData.metricName
                else -> "Sleep Hours"
            }

            Box(modifier = Modifier.fillMaxWidth()) {
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(40.dp)
                        .clickable { dropdownExpanded = true },
                    color = NotelSurfaceHigh,
                    shape = RoundedCornerShape(10.dp),
                    border = BorderStroke(1.dp, GlassBorder)
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxSize()
                            .padding(horizontal = 12.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = currentMetric,
                            fontWeight = FontWeight.SemiBold,
                            color = NotelPrimary,
                            fontSize = 14.sp
                        )
                        Icon(
                            imageVector = Icons.Default.ArrowDropDown,
                            contentDescription = "Select Metric",
                            tint = NotelPrimary
                        )
                    }
                }

                DropdownMenu(
                    expanded = dropdownExpanded,
                    onDismissRequest = { dropdownExpanded = false },
                    modifier = Modifier.background(NotelSurfaceHigh)
                ) {
                    availableMetrics.forEach { metric ->
                        DropdownMenuItem(
                            text = {
                                Text(
                                    text = metric,
                                    color = if (metric == currentMetric) NotelPrimary else NotelTextPrimary,
                                    fontWeight = if (metric == currentMetric) FontWeight.Bold else FontWeight.Normal
                                )
                            },
                            onClick = {
                                dropdownExpanded = false
                                onSelectMetric(metric)
                            }
                        )
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // State Content Rendering
            when (state) {
                is WeeklySnapshotState.Loading -> {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(160.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        CircularProgressIndicator(
                            color = NotelPrimary,
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp
                        )
                    }
                }
                is WeeklySnapshotState.Error -> {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(120.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = state.message,
                            color = MaterialTheme.colorScheme.error,
                            fontSize = 12.sp,
                            textAlign = TextAlign.Center
                        )
                    }
                }
                is WeeklySnapshotState.Ready -> {
                    val metricData = state.metricData
                    Text(
                        text = metricData.averageOrTotalText,
                        color = NotelTextSecondary,
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Medium
                    )

                    Spacer(Modifier.height(12.dp))

                    if (!metricData.isAvailable) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(140.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Text(
                                text = "Metric not available or permission missing",
                                color = NotelTextSecondary,
                                fontSize = 13.sp
                            )
                        }
                    } else {
                        // Native Canvas Chart
                        WeeklySnapshotChartCanvas(
                            metricData = metricData,
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(160.dp)
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun WeeklySnapshotChartCanvas(
    metricData: WeeklySnapshotMetricData,
    modifier: Modifier = Modifier
) {
    val points = metricData.points
    val isBarChart = metricData.metricName in listOf("Logs", "Symptoms", "Medication Adherence", "Habit Completion")
    val isBpChart = metricData.metricName == "Blood Pressure"

    val lineColor = when (metricData.metricName) {
        "Sleep Hours" -> Color(0xFF42A5F5)
        "Resting Heart Rate" -> Color(0xFFFF5E62)
        "Calories" -> Color(0xFFFFA726)
        "Logs" -> Color(0xFF66BB6A)
        "Symptoms" -> Color(0xFFAB47BC)
        "Medication Adherence" -> Color(0xFF26A69A)
        "Habit Completion" -> Color(0xFFFFB74D)
        "Blood Pressure" -> Color(0xFFEF5350)
        else -> NotelPrimary
    }

    Box(modifier = modifier) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val width = size.width
            val height = size.height
            val bottomPadding = 24.dp.toPx()
            val chartH = height - bottomPadding
            val stepX = width / (points.size.coerceAtLeast(1))

            // Grid Lines (3 horizontal lines)
            for (i in 0..2) {
                val y = chartH * (i / 2f)
                drawLine(
                    color = Color.White.copy(alpha = 0.06f),
                    start = Offset(0f, y),
                    end = Offset(width, y),
                    strokeWidth = 1.dp.toPx()
                )
            }

            if (isBarChart) {
                // Render Rounded Bar Chart
                val maxVal = points.mapNotNull { it.value }.maxOrNull()?.coerceAtLeast(1f) ?: 100f
                val barWidth = (stepX * 0.45f).coerceAtMost(28.dp.toPx())

                points.forEachIndexed { index, pt ->
                    val cx = (index + 0.5f) * stepX
                    val valF = pt.value
                    if (valF != null && valF > 0f) {
                        val barH = (valF / maxVal) * (chartH * 0.85f)
                        val topY = chartH - barH
                        drawRoundRect(
                            color = lineColor.copy(alpha = 0.85f),
                            topLeft = Offset(cx - barWidth / 2f, topY),
                            size = Size(barWidth, barH),
                            cornerRadius = androidx.compose.ui.geometry.CornerRadius(4.dp.toPx())
                        )
                    } else if (valF == 0f) {
                        // Tiny dot for zero
                        drawCircle(
                            color = lineColor.copy(alpha = 0.3f),
                            radius = 2.dp.toPx(),
                            center = Offset(cx, chartH - 2.dp.toPx())
                        )
                    }
                }
            } else if (isBpChart) {
                // Dual Line Chart for Blood Pressure
                val sysVals = points.mapNotNull { it.value }
                val diaVals = points.mapNotNull { it.secondaryValue }
                if (sysVals.isNotEmpty() || diaVals.isNotEmpty()) {
                    val maxVal = (sysVals.maxOrNull() ?: 140f).coerceAtLeast(140f) + 10f
                    val minVal = (diaVals.minOrNull() ?: 60f).coerceAtMost(60f) - 10f
                    val valRange = (maxVal - minVal).coerceAtLeast(1f)

                    val sysPath = Path()
                    val diaPath = Path()
                    var sysStarted = false
                    var diaStarted = false

                    points.forEachIndexed { index, pt ->
                        val cx = (index + 0.5f) * stepX
                        pt.value?.let { sys ->
                            val cy = chartH - ((sys - minVal) / valRange) * chartH
                            if (!sysStarted) { sysPath.moveTo(cx, cy); sysStarted = true } else sysPath.lineTo(cx, cy)
                            drawCircle(lineColor, radius = 3.dp.toPx(), center = Offset(cx, cy))
                        }
                        pt.secondaryValue?.let { dia ->
                            val cy = chartH - ((dia - minVal) / valRange) * chartH
                            if (!diaStarted) { diaPath.moveTo(cx, cy); diaStarted = true } else diaPath.lineTo(cx, cy)
                            drawCircle(Color(0xFF42A5F5), radius = 3.dp.toPx(), center = Offset(cx, cy))
                        }
                    }

                    if (sysStarted) drawPath(sysPath, lineColor, style = Stroke(width = 2.dp.toPx()))
                    if (diaStarted) drawPath(diaPath, Color(0xFF42A5F5), style = Stroke(width = 2.dp.toPx()))
                }
            } else {
                // Continuous Line Chart (Sleep, Heart Rate, Calories)
                val validVals = points.mapNotNull { it.value }
                if (validVals.size >= 2) {
                    val minV = validVals.minOrNull() ?: 0f
                    val maxV = validVals.maxOrNull() ?: 1f
                    val range = (maxV - minV).let { if (it == 0f) 1f else it }

                    val linePath = Path()
                    val fillPath = Path()

                    val chartPoints = mutableListOf<Offset>()
                    points.forEachIndexed { index, pt ->
                        val cx = (index + 0.5f) * stepX
                        pt.value?.let { v ->
                            val cy = chartH - 12.dp.toPx() - (((v - minV) / range) * (chartH - 24.dp.toPx()))
                            chartPoints.add(Offset(cx, cy))
                        }
                    }

                    if (chartPoints.isNotEmpty()) {
                        linePath.moveTo(chartPoints[0].x, chartPoints[0].y)
                        fillPath.moveTo(chartPoints[0].x, chartH)
                        fillPath.lineTo(chartPoints[0].x, chartPoints[0].y)

                        for (i in 1 until chartPoints.size) {
                            linePath.lineTo(chartPoints[i].x, chartPoints[i].y)
                            fillPath.lineTo(chartPoints[i].x, chartPoints[i].y)
                        }

                        fillPath.lineTo(chartPoints.last().x, chartH)
                        fillPath.close()

                        // Draw Gradient Fill
                        drawPath(
                            path = fillPath,
                            brush = Brush.verticalGradient(
                                colors = listOf(lineColor.copy(alpha = 0.35f), Color.Transparent),
                                startY = 0f,
                                endY = chartH
                            )
                        )

                        // Draw Line
                        drawPath(
                            path = linePath,
                            color = lineColor,
                            style = Stroke(width = 2.5.dp.toPx())
                        )

                        // Draw Point Circles
                        chartPoints.forEach { pt ->
                            drawCircle(Color.White, radius = 3.5.dp.toPx(), center = pt)
                            drawCircle(lineColor, radius = 2.dp.toPx(), center = pt)
                        }
                    }
                }
            }
        }

        // X-Axis Labels Row below Canvas
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
                .height(20.dp),
            horizontalArrangement = Arrangement.SpaceAround,
            verticalAlignment = Alignment.CenterVertically
        ) {
            points.forEach { pt ->
                Text(
                    text = pt.dayLabel,
                    color = NotelTextSecondary,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    textAlign = TextAlign.Center
                )
            }
        }
    }
}
