package com.notel.notel.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.clickable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.activity.ComponentActivity
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.FitbitViewModel
import com.notel.notel.data.healthconnect.DailyHeartRateSummary
import com.notel.notel.data.preferences.NotelPreferences
import androidx.compose.runtime.LaunchedEffect
import kotlinx.coroutines.flow.first
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FitbitScreen(
    viewModel: FitbitViewModel = hiltViewModel(),
    onBack: () -> Unit
) {
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current
    // We read the DataStore through the ViewModel's state.historicalSpikes instead
    
    val healthConnectLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = viewModel.healthConnectManager.requestPermissionsActivityContract()
    ) { granted ->
        if (granted.containsAll(viewModel.healthConnectManager.permissions)) {
            viewModel.onPermissionsGranted()
        }
    }
    var showCompareCalendar by remember { mutableStateOf(false) }
    var showCalendar by remember { mutableStateOf(false) }
    var compareMode by remember { mutableStateOf("Days") }
    var selectedCompareDate by remember { mutableStateOf<Pair<String, Int>?>(null) }
    
    if (showCalendar && state.isConnected) {
        val initialDateMillis = remember(state.selectedHeartRateDate) {
            if (state.selectedHeartRateDate == "today") null
            else try {
                val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                    timeZone = java.util.TimeZone.getTimeZone("UTC")
                }
                sdf.parse(state.selectedHeartRateDate)?.time
            } catch(e: Exception) { null }
        }
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = initialDateMillis,
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    val formatted = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                        timeZone = java.util.TimeZone.getTimeZone("UTC")
                    }.format(java.util.Date(utcTimeMillis))
                    return state.historicalHeartRate.any { it.first == formatted }
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
                        viewModel.fetchHeartRateForDate(formatted)
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
                        return state.historicalHeartRate.any { it.first == formatted }
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
                            val hr = state.historicalHeartRate.find { it.first == formatted }?.second
                            if (hr != null) {
                                selectedCompareDate = formatted to hr
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
                        return state.historicalHeartRate.any { it.first == formatted }
                    }
                }
            )
            
            androidx.compose.runtime.LaunchedEffect(dateRangePickerState.selectedStartDateMillis, dateRangePickerState.selectedEndDateMillis) {
                val start = dateRangePickerState.selectedStartDateMillis
                val end = dateRangePickerState.selectedEndDateMillis
                if (start != null && end == null) {
                    val cal = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
                    cal.timeInMillis = start
                    cal.add(java.util.Calendar.DAY_OF_YEAR, -6)
                    dateRangePickerState.setSelection(cal.timeInMillis, start)
                }
            }
            
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
                                val hr = state.historicalHeartRate.find { it.first == dStr }?.second
                                if (hr != null) {
                                    sum += hr
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
                title = { Text("Daily Heart Rate", fontWeight = FontWeight.Bold, color = NotelTextPrimary) },
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
                        if (state.selectedHeartRateDate != "today") {
                            IconButton(onClick = { viewModel.fetchHeartRateForDate("today") }) {
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
            verticalArrangement = Arrangement.Center
        ) {
            if (!state.isConnected) {
                Icon(Icons.Default.FavoriteBorder, null, tint = NotelPrimary, modifier = Modifier.size(64.dp))
                Spacer(Modifier.height(16.dp))
                Text(
                    "Health Connect is not linked.",
                    color = NotelTextPrimary,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.Bold
                )
                Spacer(Modifier.height(8.dp))
                Text(
                    "Connect your device sensors to automatically pull your average daily heart rate history in order to identify trends against the rest of your log data.",
                    color = NotelTextSecondary,
                    fontSize = 14.sp,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                )
                Spacer(Modifier.height(32.dp))
                GlassyButton(
                    onClick = { healthConnectLauncher.launch(viewModel.healthConnectManager.permissions) },
                    modifier = Modifier.fillMaxWidth(0.8f),
                    containerColor = NotelPrimary
                ) {
                    Text("Connect Health Data", color = Color.White, fontWeight = FontWeight.Bold)
                }
            } else {
                if (state.isLoading && state.historicalHeartRate.isEmpty()) {
                    GlassySpinner(size = 48.dp)
                    Spacer(Modifier.height(16.dp))
                    Text("Fetching your vitals...", color = NotelTextSecondary)
                    Spacer(Modifier.height(8.dp))
                    Text("(Pulling 6 months of data may take a few seconds)", color = NotelTextSecondary, fontSize = 12.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                } else {
                    if (state.isLoading) {
                        CircularProgressIndicator(color = NotelPrimary, modifier = Modifier.size(24.dp))
                        Spacer(Modifier.height(16.dp))
                    }
                    GlassyCard(
                        modifier = Modifier.fillMaxWidth(),
                        color = NotelSurface
                    ) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally, 
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(Icons.Default.FavoriteBorder, null, tint = NotelPrimary, modifier = Modifier.size(64.dp))
                            Spacer(Modifier.height(16.dp))
                            Text(
                                if (state.selectedHeartRateDate == "today") "Awake Average Today" else "Awake Daily Average",
                                color = NotelTextSecondary,
                                fontSize = 14.sp
                            )
                            Spacer(Modifier.height(4.dp))
                            Text(
                                if (state.averageHeartRate > 0) "${state.averageHeartRate} bpm" else "-- bpm",
                                color = NotelTextPrimary,
                                fontSize = 48.sp,
                                fontWeight = FontWeight.Bold
                            )
                            if (state.asleepHeartRate > 0) {
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    "Asleep Average: ${state.asleepHeartRate} bpm",
                                    color = NotelPrimary,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.SemiBold
                                )
                            }
                            Spacer(Modifier.height(8.dp))
                            Text(
                                "Calories burned: ${if (state.caloriesBurned > 0) state.caloriesBurned.toString() else "--"} kcal",
                                color = NotelPrimary,
                                fontSize = 14.sp,
                                fontWeight = FontWeight.SemiBold
                            )
                            Spacer(Modifier.height(4.dp))
                            if (state.latestHeartRate > 0) {
                                Text(
                                    "Latest reading: ${state.latestHeartRate} bpm${if (state.latestHeartRateTime.isNotBlank()) "  ·  ${state.latestHeartRateTime}" else ""}",
                                    color = NotelTextSecondary.copy(alpha = 0.7f),
                                    fontSize = 10.sp
                                )
                            }
                        }
                    }
                    
                    // ── Orthostatic Spike Card ─────────────────────────────────
                    val todaySpikes = remember(state.heartRateData) {
                        val readings = state.heartRateData.map { it.second }
                        if (readings.isEmpty()) listOf(0, 0, 0, 0)
                        else {
                            val sorted = readings.sorted()
                            val max = sorted.last()
                            val p10 = sorted[(sorted.size * 0.10).toInt().coerceAtLeast(0)]
                            
                            // Group UI count the same way we group events below
                            val parser = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault())
                            var eventsCount = 0
                            var inEvent = false
                            var eventEndMs = 0L
                            for ((tMs, bpm) in state.heartRateData) {
                                if (bpm >= 100) {
                                    if (!inEvent || tMs > eventEndMs) {
                                        eventsCount++
                                        inEvent = true
                                    }
                                    eventEndMs = tMs + (5 * 60 * 1000)
                                }
                            }
                            
                            val delta = max - p10
                            listOf(max, eventsCount, delta, p10)
                        }
                    }

                    Spacer(Modifier.height(16.dp))
                    val maxBpm = todaySpikes[0]
                    val spikeCount = todaySpikes[1]
                    val maxDelta = todaySpikes[2]
                    val baseline = todaySpikes[3]
                    val isHighBurden = spikeCount >= 5 || maxDelta >= 50
                    val noData = maxBpm == 0
                    var showSpikeDetails by remember { mutableStateOf(false) }
                    
                    GlassyCard(
                        modifier = Modifier.fillMaxWidth().clickable { if (!noData) showSpikeDetails = !showSpikeDetails },
                        color = if (isHighBurden) Color(0xFF2A1020) else NotelSurface
                    ) {
                        if (noData) {
                            Column(modifier = Modifier.fillMaxWidth().padding(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(
                                    text = "💓 Orthostatic Spikes",
                                    color = NotelTextPrimary,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 16.sp
                                )
                                Spacer(Modifier.height(12.dp))
                                Text(
                                    "No intraday heart rate data available for today.",
                                    color = NotelTextSecondary,
                                    fontSize = 14.sp,
                                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                                )
                                Spacer(Modifier.height(8.dp))
                                Text(
                                    "Ensure your device is connected and syncing.",
                                    color = NotelTextSecondary.copy(alpha = 0.7f),
                                    fontSize = 11.sp,
                                    textAlign = androidx.compose.ui.text.style.TextAlign.Center
                                )
                            }
                        } else {
                            Box(modifier = Modifier.fillMaxWidth()) {
                                Column(modifier = Modifier.fillMaxWidth()) {
                                    Spacer(Modifier.height(8.dp))
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Text(
                                        text = if (isHighBurden) "⚠️ Orthostatic Spikes" else "💓 Orthostatic Spikes",
                                        color = if (isHighBurden) Color(0xFFFF6B6B) else NotelTextPrimary,
                                        fontWeight = FontWeight.Bold,
                                        fontSize = 16.sp,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        if (isHighBurden) {
                                            Text(
                                                "High Symptom Day",
                                                color = Color(0xFFFF6B6B),
                                                fontSize = 11.sp,
                                                fontWeight = FontWeight.SemiBold
                                            )
                                        }
                                    }
                                }
                                Spacer(Modifier.height(12.dp))
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceEvenly
                                ) {
                                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                        Text(
                                            "$maxBpm",
                                            color = Color(0xFFE2A123),
                                            fontSize = 28.sp,
                                            fontWeight = FontWeight.Black
                                        )
                                        Text("Peak bpm", color = NotelTextSecondary, fontSize = 11.sp)
                                    }
                                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                        Text(
                                            "$spikeCount",
                                            color = if (spikeCount >= 5) Color(0xFFFF6B6B) else NotelPrimary,
                                            fontSize = 28.sp,
                                            fontWeight = FontWeight.Black
                                        )
                                        Text("Spikes >100", color = NotelTextSecondary, fontSize = 11.sp)
                                    }
                                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                        Text(
                                            "$baseline ➝ $maxBpm",
                                            color = if (maxDelta >= 30) Color(0xFFFF6B6B) else NotelTextPrimary,
                                            fontSize = 24.sp,
                                            fontWeight = FontWeight.Black
                                        )
                                        Text("Largest Spike", color = NotelTextSecondary, fontSize = 11.sp)
                                    }
                                }
                                Spacer(Modifier.height(8.dp))
                                Text(
                                    "Avg: ${state.averageHeartRate} bpm  ·  Spikes hidden in average",
                                    color = NotelTextSecondary,
                                    fontSize = 11.sp
                                )
                                if (maxDelta >= 30) {
                                    Spacer(Modifier.height(6.dp))
                                    Text(
                                        "Significant orthostatic delta detected (+${maxDelta} bpm ≥ 30). This data is being sent to your AI.",
                                        color = Color(0xFFFF6B6B).copy(alpha = 0.8f),
                                        fontSize = 11.sp
                                    )
                                }
                                
                                if (showSpikeDetails && spikeCount > 0) {
                                    Spacer(Modifier.height(16.dp))
                                    HorizontalDivider(color = NotelTextSecondary.copy(alpha = 0.2f))
                                    Spacer(Modifier.height(12.dp))
                                    Text("Logged Spikes (≥100 bpm)", color = NotelTextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                                    Spacer(Modifier.height(8.dp))
                                    
                                    val parser = java.text.SimpleDateFormat("HH:mm:ss", java.util.Locale.getDefault())
                                    val formatter = java.text.SimpleDateFormat("h:mm a", java.util.Locale.getDefault())

                                    class SpikeEvent(val startTime: String, var endTime: String, var peakBpm: Int, var durationMins: Int)
                                    val events = mutableListOf<SpikeEvent>()
                                    var currentEvent: SpikeEvent? = null
                                    var currentEventEndMs = 0L

                                    state.heartRateData.forEach { (timeMs, bpm) ->
                                        if (bpm >= 100) {
                                            if (currentEvent == null || timeMs > currentEventEndMs) {
                                                currentEvent?.let { events.add(it) }
                                                currentEvent = SpikeEvent(timeMs.toString(), timeMs.toString(), bpm, 1)
                                            } else {
                                                currentEvent!!.endTime = timeMs.toString()
                                                currentEvent!!.peakBpm = maxOf(currentEvent!!.peakBpm, bpm)
                                                val startMs = currentEvent!!.startTime.toLongOrNull() ?: timeMs
                                                currentEvent!!.durationMins = maxOf(1, ((timeMs - startMs) / 60000).toInt())
                                            }
                                            // Keep the event alive for up to 5 minutes after the last spike reading
                                            currentEventEndMs = timeMs + (5 * 60 * 1000)
                                        }
                                    }
                                    currentEvent?.let { events.add(it) }

                                    events.forEach { event ->
                                        val displayTime = try {
                                            val tMs = event.startTime.toLongOrNull() ?: 0L
                                            if (tMs > 0) formatter.format(java.util.Date(tMs)) else event.startTime
                                        } catch (e: Exception) { event.startTime }

                                        Row(
                                            modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            verticalAlignment = Alignment.CenterVertically
                                        ) {
                                            Column {
                                                Text(displayTime, color = NotelTextSecondary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                                                if (event.durationMins > 1) {
                                                    Text("Duration: ~${event.durationMins}m", color = NotelTextSecondary.copy(alpha=0.7f), fontSize = 11.sp)
                                                }
                                            }
                                            Text(
                                                "${event.peakBpm} bpm peak", 
                                                color = if (event.peakBpm >= 120) Color(0xFFFF6B6B) else Color(0xFFE2A123), 
                                                fontWeight = FontWeight.Bold, 
                                                fontSize = 14.sp
                                            )
                                        }
                                    }
                                }
                                
                                if (state.historicalSpikes.isNotEmpty()) {
                                    val worstDay = state.historicalSpikes.maxByOrNull { it.spikeCount }
                                    if (worstDay != null && worstDay.spikeCount > spikeCount && worstDay.date != state.selectedHeartRateDate) {
                                        IconButton(
                                            onClick = { viewModel.fetchHeartRateForDate(worstDay.date) },
                                            modifier = Modifier
                                                .align(Alignment.BottomEnd)
                                                .padding(bottom = 8.dp, end = 8.dp)
                                                .size(24.dp)
                                        ) {
                                            Icon(
                                                Icons.AutoMirrored.Filled.ArrowForward,
                                                contentDescription = "Skip to worst day",
                                                tint = NotelPrimary.copy(alpha = 0.8f),
                                                modifier = Modifier.size(18.dp)
                                            )
                                        }
                                    }
                                }
                            }
                        }

                    if (state.connectedDevices.isNotEmpty()) {
                        Spacer(Modifier.height(24.dp))
                        GlassyCard(
                            modifier = Modifier.fillMaxWidth(),
                            color = NotelSurface
                        ) {
                            Column(modifier = Modifier.fillMaxWidth()) {
                                Text("Connected Devices", color = NotelTextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 16.sp)
                                Spacer(Modifier.height(8.dp))
                                state.connectedDevices.forEach { device ->
                                    Text("• $device", color = NotelTextSecondary, fontSize = 14.sp)
                                }
                            }
                        }
                    }
                    
                    Spacer(Modifier.height(32.dp))
                    
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
                    
                    selectedCompareDate?.let { (dateString, pastHr) ->
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
                                    val currentHr = if (compareMode == "Days") state.averageHeartRate else {
                                        val currentWeekData = state.historicalHeartRate.take(7)
                                        if (currentWeekData.isNotEmpty()) currentWeekData.map { it.second }.average().toInt() else state.averageHeartRate
                                    }
                                    val currentCal = if (compareMode == "Days") state.caloriesBurned else {
                                        val currentWeekCal = state.historicalCalories.take(7)
                                        if (currentWeekCal.isNotEmpty()) currentWeekCal.map { it.second }.average().toInt() else state.caloriesBurned
                                    }
                                    
                                    val pastCal = if (compareMode == "Days") {
                                        state.historicalCalories.find { it.first == dateString }?.second ?: 0
                                    } else {
                                        val cal = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
                                        val format = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
                                        val endDate = format.parse(dateString)
                                        if (endDate != null) {
                                            cal.time = endDate
                                            var sum = 0
                                            var count = 0
                                            for (i in 0 until 7) {
                                                val dStr = format.format(cal.time)
                                                val c = state.historicalCalories.find { it.first == dStr }?.second
                                                if (c != null) {
                                                    sum += c
                                                    count++
                                                }
                                                cal.add(java.util.Calendar.DAY_OF_YEAR, -1)
                                            }
                                            if (count > 0) sum / count else 0
                                        } else {
                                            state.historicalCalories.find { it.first == dateString }?.second ?: 0
                                        }
                                    }
                                    
                                    val diff = currentHr - pastHr
                                    val diffStr = if (diff >= 0) "+$diff" else "$diff"
                                    
                                    val diffCal = currentCal - pastCal
                                    val diffCalStr = if (diffCal >= 0) "+$diffCal" else "$diffCal"
                                    
                                    var pastSpikeDelta = 0
                                    var pastSpikeCount = 0
                                    if (compareMode == "Days") {
                                        val pastSpike = state.historicalSpikes.find { it.date == dateString }
                                        pastSpikeDelta = pastSpike?.maxDelta ?: 0
                                        pastSpikeCount = pastSpike?.spikeCount ?: 0
                                    } else {
                                        val cal = java.util.Calendar.getInstance(java.util.TimeZone.getTimeZone("UTC"))
                                        val format = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply { timeZone = java.util.TimeZone.getTimeZone("UTC") }
                                        val endDate = format.parse(dateString)
                                        if (endDate != null) {
                                            cal.time = endDate
                                            var sumD = 0
                                            var sumC = 0.0
                                            var count = 0
                                            for (i in 0 until 7) {
                                                val dStr = format.format(cal.time)
                                                val sp = state.historicalSpikes.find { it.date == dStr }
                                                if (sp != null) {
                                                    sumD += sp.maxDelta
                                                    sumC += sp.spikeCount
                                                    count++
                                                }
                                                cal.add(java.util.Calendar.DAY_OF_YEAR, -1)
                                            }
                                            if (count > 0) {
                                                pastSpikeDelta = sumD / count
                                                pastSpikeCount = Math.round(sumC / count).toInt()
                                            }
                                        } else {
                                            val pastSpike = state.historicalSpikes.find { it.date == dateString }
                                            pastSpikeDelta = pastSpike?.maxDelta ?: 0
                                            pastSpikeCount = pastSpike?.spikeCount ?: 0
                                        }
                                    }
                                    val currentSpikeDelta = if (compareMode == "Days") maxDelta else {
                                        val w = state.historicalSpikes.take(7)
                                        if (w.isNotEmpty()) w.map { it.maxDelta }.average().toInt() else maxDelta
                                    }
                                    val currentSpikeCount = if (compareMode == "Days") spikeCount else {
                                        val w = state.historicalSpikes.take(7)
                                        if (w.isNotEmpty()) Math.round(w.map { it.spikeCount }.average()).toInt() else spikeCount
                                    }
                                    
                                    val diffSpikeC = currentSpikeCount - pastSpikeCount
                                    val diffSpikeCStr = if (diffSpikeC >= 0) "+$diffSpikeC" else "$diffSpikeC"
                                    
                                    val diffSpikeD = currentSpikeDelta - pastSpikeDelta
                                    val diffSpikeDStr = if (diffSpikeD >= 0) "+$diffSpikeD" else "$diffSpikeD"
                                    
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
                                    
                                    Text(if (compareMode == "Days") "$displayDate: $pastHr bpm | ${if (pastCal > 0) pastCal else "--"} kcal | $pastSpikeCount spikes, +$pastSpikeDelta jump" else "$displayDate: $pastHr bpm avg | ${if (pastCal > 0) pastCal else "--"} kcal | ~$pastSpikeCount/d spikes, +$pastSpikeDelta avg jump", color = NotelTextPrimary, fontSize = 14.sp)
                                    Text(if (compareMode == "Days") "Today: $currentHr bpm | ${if (currentCal > 0) currentCal else "--"} kcal | $currentSpikeCount spikes, +$currentSpikeDelta jump" else "This Week: $currentHr bpm avg | ${if (currentCal > 0) currentCal else "--"} kcal | ~$currentSpikeCount/d spikes, +$currentSpikeDelta avg jump", color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
                                    Spacer(Modifier.height(12.dp))
                                    
                                    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
                                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                            Text("Avg HR", color = NotelTextSecondary, fontSize = 11.sp)
                                            Text("$diffStr bpm", color = if (diff > 0) MaterialTheme.colorScheme.error else NotelPrimary, fontSize = 14.sp, fontWeight = FontWeight.Black)
                                        }
                                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                            Text("Calories", color = NotelTextSecondary, fontSize = 11.sp)
                                            Text("$diffCalStr kcal", color = if (diffCal > 0) NotelPrimary else MaterialTheme.colorScheme.error, fontSize = 14.sp, fontWeight = FontWeight.Black)
                                        }
                                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                            Text("Events", color = NotelTextSecondary, fontSize = 11.sp)
                                            Text("$diffSpikeCStr", color = if (diffSpikeC > 0) MaterialTheme.colorScheme.error else NotelPrimary, fontSize = 14.sp, fontWeight = FontWeight.Black)
                                        }
                                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                            Text("Jump Mag", color = NotelTextSecondary, fontSize = 11.sp)
                                            Text("$diffSpikeDStr bpm", color = if (diffSpikeD > 0) MaterialTheme.colorScheme.error else NotelPrimary, fontSize = 14.sp, fontWeight = FontWeight.Black)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    Spacer(Modifier.height(48.dp))
                    
                    GlassyButton(
                        onClick = { viewModel.disconnect() },
                        modifier = Modifier.fillMaxWidth(0.8f),
                        containerColor = NotelSurfaceHigh
                    ) {
                        Text("Disconnect", color = NotelTextPrimary)
                    }
                }
                
                state.errorMessage?.takeIf { it != "Failed to fetch sleep data." }?.let { error ->
                    Spacer(Modifier.height(16.dp))
                    Text(error, color = MaterialTheme.colorScheme.error, fontSize = 12.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                }
            }
        }
    }
}
