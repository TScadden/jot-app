package com.notel.notel.ui.component

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.notel.notel.data.repository.DailySnapshotPoint
import com.notel.notel.data.repository.WeeklySnapshotMetricData
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.WeeklySnapshotState

// TODO: Restore metric-specific "View details" navigation after destination UX is finalized.

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
            var dropdownExpanded by remember { mutableStateOf(false) }
            var selectedPointIndex by remember { mutableStateOf<Int?>(null) }

            val currentMetric = when (state) {
                is WeeklySnapshotState.ReadyWithData -> state.metricData.metricName
                is WeeklySnapshotState.ReadyEmpty -> state.metricName
                is WeeklySnapshotState.Error -> state.retainedData?.metricName ?: "Sleep Hours"
                else -> "Sleep Hours"
            }

            val isRefreshing = when (state) {
                is WeeklySnapshotState.ReadyWithData -> state.isRefreshing
                is WeeklySnapshotState.ReadyEmpty -> state.isRefreshing
                is WeeklySnapshotState.Loading -> true
                else -> false
            }

            val infiniteTransition = rememberInfiniteTransition(label = "refreshRotation")
            val rotationAngle by infiniteTransition.animateFloat(
                initialValue = 0f,
                targetValue = 360f,
                animationSpec = infiniteRepeatable(
                    animation = tween(1000, easing = LinearEasing),
                    repeatMode = RepeatMode.Restart
                ),
                label = "refreshAngle"
            )

            // Header Row: Title & Refresh
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

                IconButton(
                    onClick = { if (!isRefreshing) onRefresh() },
                    enabled = !isRefreshing,
                    modifier = Modifier.size(28.dp)
                ) {
                    Icon(
                        imageVector = Icons.Default.Refresh,
                        contentDescription = if (isRefreshing) "Refreshing weekly snapshot" else "Refresh weekly snapshot",
                        tint = if (isRefreshing) NotelPrimary else NotelTextSecondary,
                        modifier = Modifier
                            .size(16.dp)
                            .graphicsLayer {
                                if (isRefreshing) {
                                    rotationZ = rotationAngle
                                } else {
                                    rotationZ = 0f
                                }
                            }
                    )
                }
            }

            Spacer(Modifier.height(8.dp))

            // Metric Selector Box
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
                                selectedPointIndex = null
                                onSelectMetric(metric)
                            }
                        )
                    }
                }
            }

            Spacer(Modifier.height(12.dp))

            // Content States
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
                is WeeklySnapshotState.ReadyEmpty -> {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(140.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Text(
                            text = state.emptyMessage,
                            color = NotelTextSecondary,
                            fontSize = 13.sp,
                            textAlign = TextAlign.Center
                        )
                    }
                }
                is WeeklySnapshotState.Error -> {
                    if (state.retainedData != null) {
                        SnapshotDataContent(
                            metricData = state.retainedData,
                            selectedIndex = selectedPointIndex,
                            onSelectIndex = { selectedPointIndex = it }
                        )
                    } else {
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
                }
                is WeeklySnapshotState.ReadyWithData -> {
                    SnapshotDataContent(
                        metricData = state.metricData,
                        selectedIndex = selectedPointIndex,
                        onSelectIndex = { selectedPointIndex = it }
                    )
                }
            }
        }
    }
}

@Composable
private fun SnapshotDataContent(
    metricData: WeeklySnapshotMetricData,
    selectedIndex: Int?,
    onSelectIndex: (Int?) -> Unit
) {
    Column {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                text = metricData.averageOrTotalText,
                color = NotelTextSecondary,
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium
            )

            // Blood Pressure Legend
            if (metricData.metricName == "Blood Pressure" && metricData.isAvailable) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(8.dp).background(Color(0xFFEF5350), CircleShape))
                    Spacer(Modifier.width(4.dp))
                    Text("Sys", fontSize = 10.sp, color = NotelTextSecondary)
                    Spacer(Modifier.width(8.dp))
                    Box(Modifier.size(8.dp).background(Color(0xFF42A5F5), CircleShape))
                    Spacer(Modifier.width(4.dp))
                    Text("Dia", fontSize = 10.sp, color = NotelTextSecondary)
                }
            }
        }

        Spacer(Modifier.height(8.dp))

        // Tooltip Banner for Selected Data Point
        if (selectedIndex != null && selectedIndex in metricData.points.indices) {
            val pt = metricData.points[selectedIndex]
            Surface(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(bottom = 8.dp),
                color = NotelSurfaceHigh,
                shape = RoundedCornerShape(8.dp),
                border = BorderStroke(1.dp, GlassBorder)
            ) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 10.dp, vertical = 6.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    val formattedVal = if (pt.secondaryValue != null) {
                        "${pt.value?.toInt() ?: "--"}/${pt.secondaryValue.toInt()} ${metricData.unit}"
                    } else if (pt.value != null) {
                        if (metricData.unit == "h") {
                            val h = pt.value.toInt()
                            val m = ((pt.value - h) * 60).toInt()
                            "${h}h ${m}m"
                        } else if (metricData.unit == "%") {
                            "${pt.value.toInt()}%"
                        } else {
                            "${pt.value.toInt()} ${metricData.unit}".trim()
                        }
                    } else "No data"

                    Text(
                        text = "${pt.dateStr} (${pt.dayLabel}): $formattedVal",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelPrimary
                    )

                    IconButton(
                        onClick = {
                            // TODO: Implement "View details" navigation for selected snapshot item
                            onSelectIndex(null)
                        },
                        modifier = Modifier.size(24.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Close,
                            contentDescription = "Dismiss Tooltip",
                            tint = NotelTextSecondary,
                            modifier = Modifier.size(14.dp)
                        )
                    }
                }
            }
        }

        if (!metricData.isAvailable || metricData.emptyMessage != null && metricData.points.all { it.value == null }) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .height(140.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = metricData.emptyMessage ?: "No data available past 7 days",
                    color = NotelTextSecondary,
                    fontSize = 13.sp,
                    textAlign = TextAlign.Center
                )
            }
        } else {
            WeeklySnapshotInteractiveCanvas(
                metricData = metricData,
                selectedIndex = selectedIndex,
                onSelectIndex = onSelectIndex,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(160.dp)
            )
        }
    }
}

@Composable
private fun WeeklySnapshotInteractiveCanvas(
    metricData: WeeklySnapshotMetricData,
    selectedIndex: Int?,
    onSelectIndex: (Int?) -> Unit,
    modifier: Modifier = Modifier
) {
    val points = metricData.points
    val isBarChart = metricData.metricName in listOf("HR Spikes", "Calories", "Logs", "Habit Completion")
    val isBpChart = metricData.metricName == "Blood Pressure"

    val lineColor = when (metricData.metricName) {
        "Sleep Hours" -> Color(0xFF42A5F5)
        "Resting Heart Rate" -> Color(0xFFFF5E62)
        "HR Spikes" -> Color(0xFFE53935)
        "Calories" -> Color(0xFFFFA726)
        "Logs" -> Color(0xFF66BB6A)
        "Habit Completion" -> Color(0xFFFFB74D)
        "Blood Pressure" -> Color(0xFFEF5350)
        else -> NotelPrimary
    }

    Box(
        modifier = modifier
            .pointerInput(points) {
                detectTapGestures { offset ->
                    val stepX = size.width / points.size.coerceAtLeast(1)
                    val clickedIdx = (offset.x / stepX).toInt().coerceIn(points.indices)
                    onSelectIndex(clickedIdx)
                }
            }
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val width = size.width
            val height = size.height
            val bottomPadding = 24.dp.toPx()
            val chartH = height - bottomPadding
            val stepX = width / (points.size.coerceAtLeast(1))

            // Horizontal Grid Lines
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
                val maxVal = points.mapNotNull { it.value }.maxOrNull()?.coerceAtLeast(1f) ?: 100f
                val barWidth = (stepX * 0.45f).coerceAtMost(28.dp.toPx())

                points.forEachIndexed { index, pt ->
                    val cx = (index + 0.5f) * stepX
                    val valF = pt.value
                    if (valF != null && valF > 0f) {
                        val barH = (valF / maxVal) * (chartH * 0.85f)
                        val topY = chartH - barH
                        drawRoundRect(
                            color = if (selectedIndex == index) lineColor else lineColor.copy(alpha = 0.75f),
                            topLeft = Offset(cx - barWidth / 2f, topY),
                            size = Size(barWidth, barH),
                            cornerRadius = CornerRadius(4.dp.toPx())
                        )
                    } else if (valF == 0f) {
                        drawCircle(
                            color = lineColor.copy(alpha = 0.4f),
                            radius = 3.dp.toPx(),
                            center = Offset(cx, chartH - 3.dp.toPx())
                        )
                    }
                }
            } else if (isBpChart) {
                val sysVals = points.mapNotNull { it.value }
                val diaVals = points.mapNotNull { it.secondaryValue }
                if (sysVals.isNotEmpty() || diaVals.isNotEmpty()) {
                    val maxVal = (sysVals.maxOrNull() ?: 140f).coerceAtLeast(140f) + 10f
                    val minVal = (diaVals.minOrNull() ?: 60f).coerceAtMost(60f) - 10f
                    val valRange = (maxVal - minVal).coerceAtLeast(1f)

                    // Draw segment paths without interpolating across missing null days
                    var currentSysPath: Path? = null
                    var currentDiaPath: Path? = null

                    points.forEachIndexed { index, pt ->
                        val cx = (index + 0.5f) * stepX

                        if (pt.value != null) {
                            val sysY = chartH - ((pt.value - minVal) / valRange) * chartH
                            if (currentSysPath == null) {
                                currentSysPath = Path().apply { moveTo(cx, sysY) }
                            } else {
                                currentSysPath?.lineTo(cx, sysY)
                            }
                            drawCircle(lineColor, radius = if (selectedIndex == index) 5.dp.toPx() else 3.dp.toPx(), center = Offset(cx, sysY))
                        } else {
                            currentSysPath?.let { drawPath(it, lineColor, style = Stroke(width = 2.dp.toPx())) }
                            currentSysPath = null
                        }

                        if (pt.secondaryValue != null) {
                            val diaY = chartH - ((pt.secondaryValue - minVal) / valRange) * chartH
                            if (currentDiaPath == null) {
                                currentDiaPath = Path().apply { moveTo(cx, diaY) }
                            } else {
                                currentDiaPath?.lineTo(cx, diaY)
                            }
                            drawCircle(Color(0xFF42A5F5), radius = if (selectedIndex == index) 5.dp.toPx() else 3.dp.toPx(), center = Offset(cx, diaY))
                        } else {
                            currentDiaPath?.let { drawPath(it, Color(0xFF42A5F5), style = Stroke(width = 2.dp.toPx())) }
                            currentDiaPath = null
                        }
                    }
                    currentSysPath?.let { drawPath(it, lineColor, style = Stroke(width = 2.dp.toPx())) }
                    currentDiaPath?.let { drawPath(it, Color(0xFF42A5F5), style = Stroke(width = 2.dp.toPx())) }
                }
            } else {
                // Continuous Line Chart (Sleep & Heart Rate) with Gaps on missing null days
                val validVals = points.mapNotNull { it.value }
                if (validVals.isNotEmpty()) {
                    val minV = validVals.minOrNull() ?: 0f
                    val maxV = validVals.maxOrNull() ?: 1f
                    val range = (maxV - minV).let { if (it == 0f) 1f else it }

                    var currentSegmentPath: Path? = null

                    points.forEachIndexed { index, pt ->
                        val cx = (index + 0.5f) * stepX
                        val valV = pt.value

                        if (valV != null) {
                            val cy = chartH - 12.dp.toPx() - (((valV - minV) / range) * (chartH - 24.dp.toPx()))
                            val ptOffset = Offset(cx, cy)

                            if (currentSegmentPath == null) {
                                currentSegmentPath = Path().apply { moveTo(ptOffset.x, ptOffset.y) }
                            } else {
                                currentSegmentPath?.lineTo(ptOffset.x, ptOffset.y)
                            }

                            drawCircle(Color.White, radius = 3.5.dp.toPx(), center = ptOffset)
                            drawCircle(
                                color = if (selectedIndex == index) NotelPrimary else lineColor,
                                radius = if (selectedIndex == index) 5.dp.toPx() else 2.dp.toPx(),
                                center = ptOffset
                            )
                        } else {
                            currentSegmentPath?.let {
                                drawPath(it, lineColor, style = Stroke(width = 2.5.dp.toPx()))
                            }
                            currentSegmentPath = null
                        }
                    }
                    currentSegmentPath?.let {
                        drawPath(it, lineColor, style = Stroke(width = 2.5.dp.toPx()))
                    }
                }
            }
        }

        // X-Axis Weekday Labels Row
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .align(Alignment.BottomCenter)
                .height(20.dp),
            horizontalArrangement = Arrangement.SpaceAround,
            verticalAlignment = Alignment.CenterVertically
        ) {
            points.forEachIndexed { idx, pt ->
                val isSelected = selectedIndex == idx
                Text(
                    text = pt.dayLabel,
                    color = if (isSelected) NotelPrimary else NotelTextSecondary,
                    fontSize = 11.sp,
                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.semantics {
                        contentDescription = "${pt.dayLabel}: ${pt.value ?: "No data"}"
                    }
                )
            }
        }
    }
}
