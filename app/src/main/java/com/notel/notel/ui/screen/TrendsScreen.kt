package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.TrendingUp
import androidx.compose.material.icons.filled.List
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.window.Dialog
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.TrendsViewModel
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TrendsScreen(
    viewModel: TrendsViewModel = hiltViewModel(),
    onBack: () -> Unit,
    onNavigateToEntry: (Long) -> Unit
) {
    val state by viewModel.state.collectAsState()
    var showSymptomsDialog by remember { mutableStateOf(false) }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = { Text("Visual Trends", fontWeight = FontWeight.Bold, color = NotelTextPrimary) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = NotelTextSecondary)
                    }
                },
                actions = {
                    IconButton(onClick = { showSymptomsDialog = true }) {
                        Icon(Icons.Default.List, "Most Used Symptoms", tint = NotelTextSecondary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        if (state.isLoading) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                GlassySpinner(size = 48.dp)
            }
        } else {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .verticalScroll(rememberScrollState())
                    .padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(24.dp)
            ) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(16.dp))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.18f), RoundedCornerShape(16.dp))
                        .clickable { viewModel.clearSelection() }
                        .padding(16.dp)
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.TrendingUp, null, tint = NotelPrimary, modifier = Modifier.size(32.dp))
                        Spacer(Modifier.width(16.dp))
                        Column {
                            Text("LOG VOLUME", color = NotelPrimary, fontSize = 11.sp, fontWeight = FontWeight.Bold, letterSpacing = 0.8.sp)
                            Text("${state.totalLogs} Total Entries", color = NotelTextPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                            if (state.selectedHour != null) {
                                Text("Tap to reset filter", color = NotelPrimary.copy(alpha = 0.7f), fontSize = 11.sp)
                            }
                        }
                    }
                }

                // Day Selector
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    IconButton(onClick = { viewModel.previousDay() }) {
                        Icon(Icons.Default.ChevronLeft, "Previous Day", tint = NotelTextPrimary)
                    }
                    Text(
                        text = state.dateLabel,
                        color = NotelTextPrimary,
                        fontWeight = FontWeight.Bold,
                        fontSize = 16.sp,
                        modifier = Modifier.clickable { viewModel.clearSelection() }
                    )
                    IconButton(onClick = { viewModel.nextDay() }, enabled = state.dayOffset < 0) {
                        Icon(
                            Icons.Default.ChevronRight, 
                            "Next Day", 
                            tint = if (state.dayOffset < 0) NotelTextPrimary else NotelTextSecondary.copy(alpha = 0.5f)
                        )
                    }
                }
                
                Column {
                    Text(
                        text = if (state.selectedHour != null) "Logs at ${formatHour(state.selectedHour!!)}" else "Log Activity by Hour",
                        color = NotelPrimary, fontWeight = FontWeight.Bold, fontSize = 13.sp, letterSpacing = 0.6.sp
                    )
                    Spacer(Modifier.height(8.dp))
                    Box(
                        modifier = Modifier.fillMaxWidth().height(220.dp)
                            .clip(RoundedCornerShape(16.dp)).background(NotelSurface)
                            .border(1.dp, NotelPrimary.copy(alpha = 0.18f), RoundedCornerShape(16.dp)).padding(16.dp)
                    ) {
                        HourlyDensityChart(data = state.frequencyByHour, selectedHour = state.selectedHour, onHourSelected = { viewModel.selectHour(it) })
                    }
                }

                // Category Distribution
                if (state.selectedHour == null) {
                    Text("Category Focus", color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        state.categories.forEach { cat ->
                            val count = state.frequencyByCategory[cat.id] ?: 0
                            if (count > 0) {
                                CategoryProgressRow(
                                    name = cat.name,
                                    count = count,
                                    total = state.totalLogs,
                                    colorHex = cat.colorHex
                                )
                            }
                        }
                    }
                }

                if (state.selectedHour != null && state.filteredLogs.isNotEmpty()) {
                    Text("Entries for this hour", color = NotelPrimary, fontWeight = FontWeight.Bold, fontSize = 13.sp, letterSpacing = 0.6.sp)
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        state.filteredLogs.forEach { entry ->
                            Box(
                                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                                    .background(NotelSurface).border(1.dp, NotelPrimary.copy(alpha = 0.18f), RoundedCornerShape(12.dp))
                                    .clickable { onNavigateToEntry(entry.id) }.padding(12.dp)
                            ) {
                                Column {
                                    Text(SimpleDateFormat("h:mm a, MMM dd", Locale.getDefault()).format(Date(entry.timestamp)), color = NotelPrimary.copy(alpha = 0.6f), fontSize = 11.sp, fontWeight = FontWeight.Medium)
                                    Spacer(Modifier.height(4.dp))
                                    Text(entry.body, color = NotelTextPrimary, fontSize = 14.sp)
                                }
                            }
                        }
                    }
                }

                if (state.selectedSymptom != null && state.logsForSymptom.isNotEmpty()) {
                    Text("Logs for '${state.selectedSymptom}'", color = NotelPrimary, fontWeight = FontWeight.Bold, fontSize = 13.sp, letterSpacing = 0.6.sp)
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        state.logsForSymptom.forEach { entry ->
                            Box(
                                modifier = Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp))
                                    .background(NotelSurface).border(1.dp, NotelPrimary.copy(alpha = 0.18f), RoundedCornerShape(12.dp))
                                    .clickable { onNavigateToEntry(entry.id) }.padding(12.dp)
                            ) {
                                Column {
                                    Text(SimpleDateFormat("h:mm a, MMM dd", Locale.getDefault()).format(Date(entry.timestamp)), color = NotelPrimary.copy(alpha = 0.6f), fontSize = 11.sp, fontWeight = FontWeight.Medium)
                                    Spacer(Modifier.height(4.dp))
                                    Text(entry.body, color = NotelTextPrimary, fontSize = 14.sp)
                                }
                            }
                        }
                    }
                }
                
                Spacer(Modifier.height(100.dp))
            }
        }
        
        if (showSymptomsDialog) {
            Dialog(onDismissRequest = { showSymptomsDialog = false }) {
                Box(
                    modifier = Modifier.fillMaxWidth().padding(16.dp)
                        .clip(RoundedCornerShape(20.dp)).background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.25f), RoundedCornerShape(20.dp)).padding(24.dp)
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("MOST USED SYMPTOMS", color = NotelPrimary, fontWeight = FontWeight.Bold, fontSize = 13.sp, letterSpacing = 0.8.sp)
                        Spacer(Modifier.height(16.dp))
                        if (state.topChips.isEmpty()) {
                            Text("No symptoms logged yet.", color = NotelTextSecondary, fontSize = 14.sp)
                        } else {
                            @OptIn(ExperimentalLayoutApi::class)
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                state.topChips.forEach { (chip, count) ->
                                    val isSel = state.selectedSymptom == chip
                                    Box(
                                        modifier = Modifier.clip(RoundedCornerShape(10.dp))
                                            .background(if (isSel) NotelPrimary else NotelSurfaceHigh)
                                            .border(1.dp, if (isSel) NotelPrimary else NotelPrimary.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
                                            .clickable { viewModel.selectSymptom(chip); showSymptomsDialog = false }
                                            .padding(horizontal = 12.dp, vertical = 6.dp)
                                    ) {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Text(chip, color = if (isSel) Color.White else NotelTextPrimary, fontSize = 13.sp)
                                            Spacer(Modifier.width(6.dp))
                                            Text(count.toString(), color = if (isSel) Color.White else NotelPrimary, fontSize = 11.sp, fontWeight = FontWeight.Bold)
                                        }
                                    }
                                }
                            }
                        }
                        Spacer(Modifier.height(24.dp))
                        GlassyButton(onClick = { showSymptomsDialog = false }, modifier = Modifier.fillMaxWidth(), containerColor = NotelSurfaceHigh) {
                            Text("Close", color = NotelTextPrimary)
                        }
                    }
                }
            }
        }
    }
}

private fun formatHour(hour: Int): String {
    return when {
        hour == 0 -> "12 AM"
        hour < 12 -> "$hour AM"
        hour == 12 -> "12 PM"
        else -> "${hour - 12} PM"
    }
}

@Composable
fun HourlyDensityChart(
    data: Map<Int, Int>,
    selectedHour: Int?,
    onHourSelected: (Int) -> Unit
) {
    val maxVal = data.values.maxOrNull()?.coerceAtLeast(1) ?: 1
    val animatedProgress = remember { Animatable(0f) }
    
    LaunchedEffect(Unit) {
        animatedProgress.animateTo(1f, tween(1000, easing = FastOutSlowInEasing))
    }

    Box(modifier = Modifier.fillMaxSize().padding(top = 16.dp, bottom = 8.dp)) {
        androidx.compose.foundation.lazy.LazyRow(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            items(24) { hour ->
                val count = data[hour] ?: 0
                val isSelected = selectedHour == hour
                val label = when {
                    hour == 0 -> "12am"
                    hour < 12 -> "${hour}am"
                    hour == 12 -> "12pm"
                    else -> "${hour - 12}pm"
                }

                Column(
                    modifier = Modifier
                        .fillMaxHeight()
                        .width(32.dp)
                        .clickable { onHourSelected(hour) },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Bottom
                ) {
                    if (count > 0) {
                        Text(
                            text = count.toString(),
                            style = TextStyle(
                                color = if (isSelected) NotelPrimary else NotelTextSecondary,
                                fontSize = 10.sp,
                                fontWeight = FontWeight.Bold
                            ),
                            modifier = Modifier.padding(bottom = 4.dp)
                        )
                    }
                    
                    val barHeight = (count.toFloat() / maxVal) * 120.dp.value
                    Box(
                        modifier = Modifier
                            .width(12.dp)
                            .height((barHeight * animatedProgress.value).dp)
                            .background(
                                brush = if (isSelected) {
                                    Brush.verticalGradient(listOf(NotelPrimary, NotelPrimary))
                                } else {
                                    Brush.verticalGradient(listOf(NotelPrimary.copy(alpha = 0.6f), NotelPrimary.copy(alpha = 0.2f)))
                                },
                                shape = RoundedCornerShape(topStart = 4.dp, topEnd = 4.dp)
                            )
                    )
                    
                    Spacer(Modifier.height(8.dp))
                    
                    Text(
                        text = label,
                        style = TextStyle(
                            color = if (isSelected) NotelPrimary else NotelTextSecondary,
                            fontSize = 9.sp, 
                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium
                        ),
                        maxLines = 1
                    )
                }
            }
        }
    }
}

@Composable
fun CategoryProgressRow(name: String, count: Int, total: Int, colorHex: String) {
    val percentage = if (total > 0) count.toFloat() / total else 0f
    val color = try { Color(android.graphics.Color.parseColor(colorHex)) } catch (_: Exception) { NotelPrimary }
    val animatedPercentage by animateFloatAsState(targetValue = percentage, animationSpec = tween(1000, easing = FastOutSlowInEasing), label = "progress")
    Column(modifier = Modifier.fillMaxWidth()) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text(name, color = NotelTextPrimary, fontSize = 14.sp)
            Text("$count", color = color, fontSize = 14.sp, fontWeight = FontWeight.Bold)
        }
        Spacer(Modifier.height(6.dp))
        Box(modifier = Modifier.fillMaxWidth().height(8.dp).clip(RoundedCornerShape(4.dp)).background(NotelSurfaceHigh)) {
            Box(modifier = Modifier.fillMaxWidth(animatedPercentage).fillMaxHeight().background(color, RoundedCornerShape(4.dp)))
        }
    }
}
