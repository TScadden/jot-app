package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.FitbitViewModel
import com.notel.notel.ui.viewmodel.SleepData

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SleepScreen(
    viewModel: FitbitViewModel = hiltViewModel(),
    onBack: () -> Unit
) {
    val state by viewModel.state.collectAsState()
    var showCalendar by remember { mutableStateOf(false) }
    var showCompareCalendar by remember { mutableStateOf(false) }
    var compareMode by remember { mutableStateOf("Days") }
    var selectedCompareDate by remember { mutableStateOf<Pair<String, Int>?>(null) }
    var showSleepInfo by remember { mutableStateOf(false) }

    if (showSleepInfo) {
        AlertDialog(
            onDismissRequest = { showSleepInfo = false },
            confirmButton = {
                TextButton(onClick = { showSleepInfo = false }) {
                    Text("Got it", color = NotelPrimary)
                }
            },
            title = {
                Text("Sleep Science", fontWeight = FontWeight.Bold, color = NotelTextPrimary)
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        "Jot uses a 10-day rolling window to calculate your sleep debt. Surplus sleep (over 8h) is capped at 1.5h of recovery credit per night.",
                        fontSize = 14.sp,
                        color = NotelTextSecondary
                    )
                    Text(
                        "REM sleep is crucial for cognitive function and emotional regulation. Most adults need 1.5h to 2h of REM per night.",
                        fontSize = 14.sp,
                        color = NotelTextSecondary
                    )
                }
            },
            containerColor = NotelSurface,
            shape = RoundedCornerShape(24.dp)
        )
    }

    if (showCalendar && state.isConnected) {
        val initialDateMillis = remember(state.selectedSleepDate) {
            if (state.selectedSleepDate == "today") null
            else try {
                val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                    timeZone = java.util.TimeZone.getTimeZone("UTC")
                }
                sdf.parse(state.selectedSleepDate)?.time
            } catch(e: Exception) { null }
        }
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = initialDateMillis,
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    val formatted = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                        timeZone = java.util.TimeZone.getTimeZone("UTC")
                    }.format(java.util.Date(utcTimeMillis))
                    return state.historicalSleep.any { it.first == formatted }
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
                        viewModel.fetchSleepForDate(formatted)
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

    if (showCompareCalendar) {
        if (compareMode == "Days") {
            val datePickerState = rememberDatePickerState(
                selectableDates = object : SelectableDates {
                    override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                        val formatted = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                            timeZone = java.util.TimeZone.getTimeZone("UTC")
                        }.format(java.util.Date(utcTimeMillis))
                        return state.historicalSleep.any { it.first == formatted }
                    }
                }
            )
            
            DatePickerDialog(
                onDismissRequest = { showCompareCalendar = false },
                confirmButton = {
                    TextButton(onClick = {
                        datePickerState.selectedDateMillis?.let { millis ->
                            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                                timeZone = java.util.TimeZone.getTimeZone("UTC")
                            }
                            val formatted = sdf.format(java.util.Date(millis))
                            val mins = state.historicalSleep.find { it.first == formatted }?.second
                            if (mins != null) {
                                selectedCompareDate = formatted to mins
                            }
                        }
                        showCompareCalendar = false
                    }) {
                        Text("Compare", color = NotelPrimary)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showCompareCalendar = false }) {
                        Text("Cancel", color = NotelTextSecondary)
                    }
                }
            ) {
                DatePicker(state = datePickerState)
            }
        } else {
            val dateRangePickerState = rememberDateRangePickerState(
                selectableDates = object : SelectableDates {
                    override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                        val formatted = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                            timeZone = java.util.TimeZone.getTimeZone("UTC")
                        }.format(java.util.Date(utcTimeMillis))
                        return state.historicalSleep.any { it.first == formatted }
                    }
                }
            )
            
            DatePickerDialog(
                onDismissRequest = { showCompareCalendar = false },
                confirmButton = {
                    TextButton(onClick = {
                        dateRangePickerState.selectedEndDateMillis?.let { millis ->
                            val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                                timeZone = java.util.TimeZone.getTimeZone("UTC")
                            }
                            val cal = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
                            cal.timeInMillis = millis
                            var sum = 0
                            var count = 0
                            for (i in 0 until 7) {
                                val dStr = sdf.format(cal.time)
                                val mins = state.historicalSleep.find { it.first == dStr }?.second
                                if (mins != null) {
                                    sum += mins
                                    count++
                                }
                                cal.add(java.util.Calendar.DAY_OF_YEAR, -1)
                            }
                            if (count > 0) {
                                val formattedDate = sdf.format(java.util.Date(millis))
                                selectedCompareDate = formattedDate to (sum / count)
                            }
                        }
                        showCompareCalendar = false
                    }) {
                        Text("Compare", color = NotelPrimary)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showCompareCalendar = false }) {
                        Text("Cancel", color = NotelTextSecondary)
                    }
                }
            ) {
                DateRangePicker(
                    state = dateRangePickerState,
                    modifier = Modifier.weight(1f),
                    title = {
                        Text("Select resolving week day", modifier = Modifier.padding(16.dp))
                    },
                    headline = {
                        Text("Past 7 Days", modifier = Modifier.padding(horizontal = 16.dp))
                    }
                )
            }
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = { Text("Sleep Profile", fontWeight = FontWeight.Bold, color = NotelTextPrimary) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = NotelTextSecondary)
                    }
                },
                actions = {
                    if (state.isConnected) {
                        IconButton(onClick = { viewModel.sync(force = true) }) {
                            Icon(Icons.Default.Sync, "Sync", tint = NotelTextSecondary)
                        }
                        if (state.selectedSleepDate != "today") {
                            IconButton(onClick = { viewModel.fetchSleepForDate("today") }) {
                                Icon(Icons.Default.Today, "Today", tint = NotelTextSecondary)
                            }
                        }
                        IconButton(onClick = { showCalendar = true }) {
                            Icon(Icons.Default.CalendarMonth, "Select Date", tint = NotelTextSecondary)
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = if (!state.isConnected) Arrangement.Center else Arrangement.Top
        ) {
            if (!state.isConnected) {
                Column(
                    modifier = Modifier.fillMaxSize().padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Box(modifier = Modifier.size(120.dp), contentAlignment = Alignment.Center) {
                        Surface(
                            modifier = Modifier.fillMaxSize().graphicsLayer(alpha = 0.1f),
                            shape = CircleShape,
                            color = NotelPrimary
                        ) {}
                        Icon(
                            imageVector = Icons.Default.Hotel,
                            contentDescription = null,
                            tint = NotelPrimary,
                            modifier = Modifier.size(64.dp)
                        )
                    }
                    Spacer(Modifier.height(32.dp))
                    Text(
                        "Sleep Analysis",
                        color = NotelTextPrimary,
                        fontSize = 24.sp,
                        fontWeight = FontWeight.Black
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "Connect your health data to track sleep cycles and calculate your sleep debt automatically.",
                        color = NotelTextSecondary,
                        fontSize = 14.sp,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        lineHeight = 22.sp
                    )
                }
            } else {
                if (state.isLoading && state.historicalSleep.isEmpty()) {
                    GlassySpinner(size = 48.dp)
                    Spacer(Modifier.height(16.dp))
                    Text("Loading Sleep Data...", color = NotelTextSecondary)
                } else {
                    if (state.isLoading) {
                        LinearProgressIndicator(
                            modifier = Modifier.fillMaxWidth().height(2.dp),
                            color = NotelPrimary,
                            trackColor = Color.Transparent
                        )
                        Spacer(Modifier.height(16.dp))
                    }

                    val sd = state.sleepData ?: SleepData()
                    
                    GlassyCard(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { showSleepInfo = true },
                        color = NotelSurface
                    ) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally, 
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            // Pulsing/Breathing Bed Icon
                            val infiniteTransition = rememberInfiniteTransition(label = "sleepPulse")
                            val scale by infiniteTransition.animateFloat(
                                initialValue = 1f,
                                targetValue = 1.08f,
                                animationSpec = infiniteRepeatable(
                                    animation = tween(1500, easing = FastOutSlowInEasing),
                                    repeatMode = RepeatMode.Reverse
                                ),
                                label = "scale"
                            )

                            Icon(
                                imageVector = Icons.Default.Hotel, 
                                null, 
                                tint = NotelPrimary, 
                                modifier = Modifier
                                    .size(64.dp)
                                    .graphicsLayer(scaleX = scale, scaleY = scale)
                            )
                            Spacer(Modifier.height(16.dp))
                            Text(
                                if (state.selectedSleepDate == "today") "Time Asleep Today" else "Daily Time Asleep",
                                color = NotelTextSecondary,
                                fontSize = 14.sp
                            )
                            val hours = sd.minutesAsleep / 60
                            val mins = sd.minutesAsleep % 60
                            Text(
                                if (sd.minutesAsleep > 0) "${hours}h ${mins}m" else "-h -m",
                                color = NotelTextPrimary,
                                fontSize = 48.sp,
                                fontWeight = FontWeight.Black
                            )
                            
                            Spacer(Modifier.height(12.dp))
                            
                            // Deficit and REM rows (Replacements for HRV and Activity)
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.History, null, tint = Color(0xFFFF5252), modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(8.dp))
                                val debtH = Math.abs(state.sleepDebtMins) / 60
                                val debtM = Math.abs(state.sleepDebtMins) % 60
                                Text(
                                    "Deficit: -${debtH}h ${debtM}m",
                                    color = Color(0xFFFF5252),
                                    fontSize = 15.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                            
                            Spacer(Modifier.height(8.dp))
                            
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.AutoGraph, null, tint = Color(0xFF4FC3F7), modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(8.dp))
                                val remH = sd.remMinutes / 60
                                val remM = sd.remMinutes % 60
                                Text(
                                    if (sd.remMinutes > 0) "REM: ${remH}h ${remM}m" else "REM: -h -m",
                                    color = NotelTextPrimary.copy(alpha = 0.9f),
                                    fontSize = 15.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                            
                            Spacer(Modifier.height(12.dp))
                            
                            Surface(
                                color = NotelPrimary.copy(alpha = 0.1f),
                                shape = RoundedCornerShape(8.dp),
                                border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.2f))
                            ) {
                                Text(
                                    "Efficiency: ${sd.efficiency}%",
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp),
                                    color = NotelPrimary,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Black
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(24.dp))
                    
                    // Comparison section matching heart tab
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        GlassyButton(
                            onClick = { compareMode = "Days"; showCompareCalendar = true },
                            modifier = Modifier.weight(1f),
                            containerColor = if (compareMode == "Days") NotelPrimary else NotelSurfaceHigh
                        ) {
                            Text("Compare Days", color = if (compareMode == "Days") Color.White else NotelTextPrimary, fontWeight = FontWeight.Bold)
                        }
                        GlassyButton(
                            onClick = { compareMode = "Weeks"; showCompareCalendar = true },
                            modifier = Modifier.weight(1f),
                            containerColor = if (compareMode == "Weeks") NotelPrimary else NotelSurfaceHigh
                        ) {
                            Text("Compare Weeks", color = if (compareMode == "Weeks") Color.White else NotelTextPrimary, fontWeight = FontWeight.Bold)
                        }
                    }
                    
                    selectedCompareDate?.let { (dateString, pastMins) ->
                        Spacer(Modifier.height(16.dp))
                        GlassyCard(
                            modifier = Modifier.fillMaxWidth(),
                            color = NotelSurfaceHigh
                        ) {
                            Box(modifier = Modifier.fillMaxWidth()) {
                                IconButton(
                                    onClick = { selectedCompareDate = null },
                                    modifier = Modifier.align(Alignment.TopEnd)
                                ) {
                                    Icon(Icons.Default.Close, "Clear Compare", tint = NotelTextSecondary)
                                }
                                Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth().padding(top = 16.dp)) {
                                    val currentMins = if (compareMode == "Days") {
                                        state.sleepData?.minutesAsleep ?: 0
                                    } else {
                                        val currentWeekData = state.historicalSleep.take(7)
                                        if (currentWeekData.isNotEmpty()) currentWeekData.map { it.second }.average().toInt() else (state.sleepData?.minutesAsleep ?: 0)
                                    }
                                    
                                    val diff = currentMins - pastMins
                                    val diffH = Math.abs(diff) / 60
                                    val diffM = Math.abs(diff) % 60
                                    val diffStr = if (diff >= 0) "+${diffH}h ${diffM}m" else "-${diffH}h ${diffM}m"
                                    
                                    val displayFormatter = java.text.SimpleDateFormat("MMMM d", java.util.Locale.getDefault())
                                    val parseFormatter = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault())
                                    val displayDate = try {
                                        val parsed = parseFormatter.parse(dateString)
                                        if (parsed != null) {
                                            if (compareMode == "Days") displayFormatter.format(parsed)
                                            else "Week ending ${displayFormatter.format(parsed)}"
                                        } else dateString
                                    } catch (e: Exception) { dateString }
                                    
                                    Text(if (compareMode == "Days") "Daily Comparison" else "Weekly Comparison", color = NotelPrimary, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                                    Spacer(Modifier.height(12.dp))
                                    
                                    Text("$displayDate: ${pastMins / 60}h ${pastMins % 60}m avg", color = NotelTextPrimary, fontSize = 16.sp)
                                    Text(if (compareMode == "Days") "Selected: ${currentMins / 60}h ${currentMins % 60}m" else "This Week: ${currentMins / 60}h ${currentMins % 60}m avg", color = NotelTextPrimary, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
                                    Spacer(Modifier.height(8.dp))
                                    Text("Difference: $diffStr", color = if (diff < 0) MaterialTheme.colorScheme.error else NotelPrimary, fontSize = 18.sp, fontWeight = FontWeight.Black)
                                }
                            }
                        }
                    }
                    
                    Spacer(Modifier.height(24.dp))
                    
                    // Detailed Stages Grid (Extra)
                    Text("Sleep Stages", color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 18.sp, modifier = Modifier.align(Alignment.Start))
                    Spacer(Modifier.height(12.dp))
                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        GlassyCard(modifier = Modifier.weight(1f)) {
                            Column {
                                Text("Deep", color = NotelTextSecondary, fontSize = 12.sp)
                                Text("${sd.deepMinutes}m", color = NotelTextPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                        GlassyCard(modifier = Modifier.weight(1f)) {
                            Column {
                                Text("Light", color = NotelTextSecondary, fontSize = 12.sp)
                                Text("${sd.lightMinutes}m", color = NotelTextPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                    }
                }
            }
            Spacer(Modifier.height(100.dp))
        }
    }
}
