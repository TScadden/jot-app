package com.notel.notel.ui.screen

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.FitbitViewModel
import java.time.LocalDate
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun KeyMetricsScreen(
    onBack: () -> Unit,
    viewModel: FitbitViewModel = hiltViewModel()
) {
    val state by viewModel.state.collectAsState()
    var showCalendar by remember { mutableStateOf(false) }

    val displayDate = if (state.selectedKeyMetricsDate == "today") {
        LocalDate.now().format(DateTimeFormatter.ofPattern("MMM d, yyyy"))
    } else {
        try {
            LocalDate.parse(state.selectedKeyMetricsDate).format(DateTimeFormatter.ofPattern("MMM d, yyyy"))
        } catch(e: Exception) { state.selectedKeyMetricsDate }
    }

    if (showCalendar) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = if (state.selectedKeyMetricsDate == "today") {
                System.currentTimeMillis()
            } else {
                try {
                    val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                        timeZone = java.util.TimeZone.getTimeZone("UTC")
                    }
                    sdf.parse(state.selectedKeyMetricsDate)?.time
                } catch(e: Exception) { System.currentTimeMillis() }
            },
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    return utcTimeMillis <= System.currentTimeMillis()
                }
            }
        )
        DatePickerDialog(
            onDismissRequest = { showCalendar = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                            timeZone = java.util.TimeZone.getTimeZone("UTC")
                        }
                        val formatted = sdf.format(java.util.Date(millis))
                        viewModel.fetchMetricsForDate(formatted)
                    }
                    showCalendar = false
                }) {
                    Text("Select", color = NotelPrimary)
                }
            },
            dismissButton = {
                TextButton(onClick = { showCalendar = false }) {
                    Text("Cancel", color = NotelTextSecondary)
                }
            }
        ) {
            DatePicker(state = datePickerState)
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = { 
                    Column {
                        Text("Key Metrics", fontWeight = FontWeight.Black, color = NotelTextPrimary, fontSize = 20.sp)
                        Text(displayDate, color = NotelPrimary, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = NotelTextSecondary)
                    }
                },
                actions = {
                    if (state.selectedKeyMetricsDate != "today") {
                        IconButton(onClick = { viewModel.fetchMetricsForDate("today") }) {
                            Icon(Icons.Default.Today, "Today", tint = NotelTextSecondary)
                        }
                    }
                    IconButton(onClick = { showCalendar = true }) {
                        Icon(Icons.Default.CalendarMonth, "Select Date", tint = NotelTextSecondary)
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent)
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            // Day Selector (Last 7 Days)
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.SpaceBetween
            ) {
                val today = LocalDate.now()
                val last7Days = (0..6).map { 
                    val d = today.minusDays(it.toLong())
                    d.toString() to d.format(DateTimeFormatter.ofPattern("EEE"))
                }.reversed()

                last7Days.forEach { (dateStr, dayLabel) ->
                    val isSelected = (state.selectedKeyMetricsDate == "today" && dateStr == today.toString()) || 
                                   state.selectedKeyMetricsDate == dateStr
                    
                    val hasData = state.historicalHeartRate.any { it.first == dateStr } || 
                                 state.historicalSleep.any { it.first == dateStr } ||
                                 dateStr == today.toString()

                    val isFuture = try { LocalDate.parse(dateStr).isAfter(today) } catch(e: Exception) { false }
                    
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier
                            .width(44.dp)
                            .clickable(enabled = !isFuture) { viewModel.fetchMetricsForDate(dateStr) }
                            .alpha(if (isFuture) 0.3f else if (!hasData) 0.5f else 1f)
                    ) {
                        Text(
                            text = dayLabel, 
                            color = if (isSelected) NotelPrimary else NotelTextSecondary, 
                            fontSize = 12.sp, 
                            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                            modifier = Modifier.padding(bottom = 6.dp)
                        )
                        Box(
                            modifier = Modifier
                                .size(36.dp)
                                .background(
                                    if (isSelected) NotelPrimary.copy(alpha = 0.2f) else Color.Transparent, 
                                    CircleShape
                                )
                                .border(
                                    width = if (isSelected) 2.dp else 1.dp,
                                    color = if (isSelected) NotelPrimary else if (hasData) NotelSurfaceHigh.copy(alpha = 0.5f) else Color.Gray.copy(alpha = 0.3f),
                                    shape = CircleShape
                                ),
                            contentAlignment = Alignment.Center
                         ) {
                            Text(
                                text = dateStr.substring(8),
                                color = if (isSelected) NotelTextPrimary else if (hasData) NotelTextSecondary else Color.Gray,
                                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                                fontSize = 13.sp
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            if (state.isLoading) {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = NotelPrimary)
                }
            } else {
                LazyVerticalGrid(
                    columns = GridCells.Fixed(2),
                    contentPadding = PaddingValues(bottom = 100.dp),
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(horizontal = 16.dp),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    item {
                        MetricTile(
                            title = "Heart Rate",
                            value = if (state.latestHeartRate > 0) "${state.latestHeartRate}" else "--",
                            unit = "BPM",
                            icon = Icons.Default.Favorite,
                            color = NotelPrimary
                        )
                    }
                    item {
                        MetricTile(
                            title = "Weight",
                            value = if (state.weightPounds > 0) String.format("%.1f", state.weightPounds) else "--",
                            unit = "lbs",
                            icon = Icons.Default.MonitorWeight,
                            color = Color(0xFF4FC3F7)
                        )
                    }
                    item {
                        MetricTile(
                            title = "Breathing Rate",
                            value = if (state.respiratoryRate > 0) String.format("%.1f", state.respiratoryRate) else "--",
                            unit = "brpm",
                            icon = Icons.Default.Air,
                            color = Color(0xFF81C784)
                        )
                    }
                    item {
                        MetricTile(
                            title = "Blood Oxygen",
                            value = if (state.bloodOxygen > 0) String.format("%.1f", state.bloodOxygen) else "--",
                            unit = "%",
                            icon = Icons.Default.Opacity,
                            color = Color(0xFFFF8A65)
                        )
                    }
                    item {
                        MetricTile(
                            title = "Resting HR",
                            value = if (state.restingHeartRate > 0) "${state.restingHeartRate}" else "--",
                            unit = "BPM",
                            icon = Icons.Default.Bedtime,
                            color = Color(0xFFBA68C8)
                        )
                    }
                    item {
                        MetricTile(
                            title = "HRV",
                            value = if (state.todayHRV > 0) String.format("%.0f", state.todayHRV) else "--",
                            unit = "ms",
                            icon = Icons.Default.Timeline,
                            color = Color(0xFF4DB6AC)
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun MetricTile(
    title: String,
    value: String,
    unit: String,
    icon: ImageVector,
    color: Color
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .height(160.dp),
        shape = RoundedCornerShape(24.dp),
        color = NotelSurface.copy(alpha = 0.15f),
        border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
    ) {
        // Glow effect
        Box(
            modifier = Modifier
                .fillMaxSize()
                .border(
                    width = 1.dp,
                    color = color.copy(alpha = 0.1f),
                    shape = RoundedCornerShape(24.dp)
                )
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(20.dp),
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Box(
                        modifier = Modifier
                            .size(32.dp)
                            .background(color.copy(alpha = 0.15f), RoundedCornerShape(8.dp)),
                        contentAlignment = Alignment.Center
                    ) {
                        Icon(icon, null, tint = color, modifier = Modifier.size(18.dp))
                    }
                }

                Column {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(
                            text = value,
                            color = NotelTextPrimary,
                            fontSize = 32.sp,
                            fontWeight = FontWeight.Black
                        )
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = unit,
                            color = NotelTextSecondary,
                            fontSize = 12.sp,
                            modifier = Modifier.padding(bottom = 6.dp)
                        )
                    }
                    Text(
                        text = title,
                        color = NotelTextSecondary,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium
                    )
                }
            }
        }
    }
}
