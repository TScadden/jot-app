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
import androidx.compose.foundation.Canvas
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
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.FitbitViewModel
import com.notel.notel.data.healthconnect.DailyHeartRateSummary

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun FitbitScreen(
    viewModel: FitbitViewModel = hiltViewModel(),
    onBack: () -> Unit = {},
    onNavigateToSpikeReview: () -> Unit = {},
    onNavigateToHealthConnect: () -> Unit = {}
) {
    val state by viewModel.state.collectAsState()
    val context = LocalContext.current
    
    val healthConnectLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = viewModel.healthConnectManager.requestPermissionsActivityContract()
    ) { granted ->
        viewModel.onPermissionsGranted()
    }
    
    var showCalendar by remember { mutableStateOf(false) }
    var showHrInfo by remember { mutableStateOf(false) }

    if (showHrInfo) {
        AlertDialog(
            onDismissRequest = { showHrInfo = false },
            confirmButton = {
                TextButton(onClick = { showHrInfo = false }) {
                    Text("Got it", color = NotelPrimary)
                }
            },
            title = {
                Text("Heart Rate Insights", fontWeight = FontWeight.Bold, color = NotelTextPrimary)
            },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(
                        "Tabs tracks your 'Awake Average' to better understand your physiological load throughout the day.",
                        fontSize = 14.sp,
                        color = NotelTextSecondary
                    )
                    Text(
                        "Clinical Benchmarks:\n" +
                        "• Resting (RHR): 60 - 80 bpm\n" +
                        "• Tachycardia: >100 bpm at rest\n" +
                        "• Bradycardia: <60 bpm at rest",
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
        val initialDateMillis = remember(state.selectedHeartRateDate) {
            if (state.selectedHeartRateDate == "today") null
            else try {
                val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                    timeZone = java.util.TimeZone.getTimeZone("UTC")
                }
                sdf.parse(state.selectedHeartRateDate)?.time
            } catch (e: Exception) { null }
        }
        val todayUtcEnd = remember { java.time.LocalDate.now().plusDays(1).atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli() - 1 }
        val days180AgoUtc = remember { java.time.LocalDate.now().minusDays(180).atStartOfDay(java.time.ZoneOffset.UTC).toInstant().toEpochMilli() }
        val selectableDatesObj = remember(todayUtcEnd, days180AgoUtc) {
            object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    return utcTimeMillis in days180AgoUtc..todayUtcEnd
                }
            }
        }
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = initialDateMillis,
            selectableDates = selectableDatesObj
        )
        DatePickerDialog(
            onDismissRequest = { showCalendar = false },
            confirmButton = {
                TextButton(onClick = {
                    val selectedMillis = datePickerState.selectedDateMillis
                    showCalendar = false
                    selectedMillis?.let { millis ->
                        val sdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                            timeZone = java.util.TimeZone.getTimeZone("UTC")
                        }
                        val formatted = sdf.format(java.util.Date(millis))
                        val todayStr = java.time.LocalDate.now().toString()
                        val targetArg = if (formatted == todayStr) "today" else formatted
                        viewModel.fetchHeartRateForDate(targetArg)
                    }
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

    val displayDateLabel = remember(state.selectedHeartRateDate) {
        if (state.selectedHeartRateDate == "today" || state.selectedHeartRateDate == java.time.LocalDate.now().toString()) {
            "Today"
        } else {
            try {
                val parsed = java.time.LocalDate.parse(state.selectedHeartRateDate)
                parsed.format(java.time.format.DateTimeFormatter.ofPattern("MMM d"))
            } catch (e: Exception) {
                state.selectedHeartRateDate
            }
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Heart",
                        fontWeight = FontWeight.Black,
                        fontSize = 28.sp,
                        color = NotelTextPrimary
                    )
                },
                actions = {
                    if (state.isConnected) {
                        // Date selector dropdown pill
                        Surface(
                            shape = RoundedCornerShape(20.dp),
                            color = NotelSurfaceHigh,
                            border = BorderStroke(1.dp, NotelTextSecondary.copy(alpha = 0.2f)),
                            modifier = Modifier
                                .clickable { showCalendar = true }
                                .padding(end = 8.dp)
                        ) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
                            ) {
                                Text(
                                    text = displayDateLabel,
                                    color = NotelTextPrimary,
                                    fontWeight = FontWeight.SemiBold,
                                    fontSize = 13.sp
                                )
                                Spacer(Modifier.width(4.dp))
                                Icon(
                                    Icons.Default.KeyboardArrowDown,
                                    contentDescription = "Select Date",
                                    tint = NotelTextSecondary,
                                    modifier = Modifier.size(16.dp)
                                )
                            }
                        }

                        // Refresh button
                        IconButton(onClick = { viewModel.sync(force = true) }) {
                            Icon(Icons.Default.Refresh, "Refresh", tint = NotelTextSecondary)
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
                .padding(horizontal = 16.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            if (!state.isConnected) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center
                ) {
                    Box(modifier = Modifier.size(120.dp), contentAlignment = Alignment.Center) {
                        Surface(
                            modifier = Modifier
                                .fillMaxSize()
                                .graphicsLayer(alpha = 0.1f),
                            shape = CircleShape,
                            color = NotelPrimary
                        ) {}
                        Icon(
                            imageVector = Icons.Default.Favorite,
                            contentDescription = null,
                            tint = NotelPrimary,
                            modifier = Modifier.size(64.dp)
                        )
                    }
                    Spacer(Modifier.height(32.dp))
                    Text(
                        "Connect Vital Signs",
                        color = NotelTextPrimary,
                        fontSize = 24.sp,
                        fontWeight = FontWeight.Black
                    )
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "Link Health Connect to automatically sync your heart rate and sleep data.",
                        color = NotelTextSecondary,
                        fontSize = 14.sp,
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                        lineHeight = 22.sp
                    )
                    Spacer(Modifier.height(40.dp))
                    GlassyButton(
                        onClick = { healthConnectLauncher.launch(viewModel.healthConnectManager.permissions) },
                        modifier = Modifier.fillMaxWidth(0.9f),
                        containerColor = NotelPrimary
                    ) {
                        Text(
                            "Link Health Connect",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(vertical = 4.dp)
                        )
                    }
                }
            } else {
                // Inline status indicator when syncing without wiping visible cached data
                if (state.isLoading) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.Center,
                        modifier = Modifier
                            .fillMaxWidth()
                            .background(NotelSurface.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                            .padding(vertical = 6.dp, horizontal = 12.dp)
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(14.dp),
                            color = NotelPrimary,
                            strokeWidth = 2.dp
                        )
                        Spacer(Modifier.width(8.dp))
                        Text(
                            "Updating sync data...",
                            color = NotelTextSecondary,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium
                        )
                    }
                }

                // ── 1. PROMINENT SUMMARY CARD ──────────────────────────────
                GlassyCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { showHrInfo = true },
                    color = NotelSurface
                ) {
                    Column(
                        horizontalAlignment = Alignment.Start,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Icon(
                                imageVector = Icons.Default.Favorite,
                                contentDescription = null,
                                tint = Color(0xFF7C6EFF),
                                modifier = Modifier.size(48.dp)
                            )
                            Spacer(Modifier.width(16.dp))
                            Column {
                                Text(
                                    "Awake average",
                                    color = NotelTextSecondary,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium
                                )
                                Text(
                                    if (state.averageHeartRate > 0) "${state.averageHeartRate} bpm" else "-- bpm",
                                    color = NotelTextPrimary,
                                    fontSize = 40.sp,
                                    fontWeight = FontWeight.Black
                                )
                            }
                        }

                        Spacer(Modifier.height(16.dp))

                        Row(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            // Asleep average pill chip
                            Surface(
                                color = Color(0xFF1A1B36),
                                shape = RoundedCornerShape(16.dp),
                                border = BorderStroke(1.dp, Color(0xFF2C2E5D)),
                                modifier = Modifier.weight(1f)
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp)
                                ) {
                                    Icon(
                                        Icons.Default.NightsStay,
                                        contentDescription = null,
                                        tint = Color(0xFFA49BFF),
                                        modifier = Modifier.size(14.dp)
                                    )
                                    Spacer(Modifier.width(6.dp))
                                    Text(
                                        if (state.asleepHeartRate > 0) "Asleep ${state.asleepHeartRate} bpm" else "Asleep -- bpm",
                                        color = Color(0xFFA49BFF),
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                                    )
                                }
                            }

                            // Last reading pill chip
                            Surface(
                                color = Color(0xFF12233D),
                                shape = RoundedCornerShape(16.dp),
                                border = BorderStroke(1.dp, Color(0xFF1E3A66)),
                                modifier = Modifier.weight(1.2f)
                            ) {
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp)
                                ) {
                                    Icon(
                                        Icons.Default.BarChart,
                                        contentDescription = null,
                                        tint = Color(0xFF79B4FF),
                                        modifier = Modifier.size(14.dp)
                                    )
                                    Spacer(Modifier.width(6.dp))
                                    Text(
                                        if (state.latestHeartRate > 0) "Last ${state.latestHeartRate} bpm${if (state.latestHeartRateTime.isNotBlank()) " · ${state.latestHeartRateTime}" else ""}" else "Last -- bpm",
                                        color = Color(0xFF79B4FF),
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 1,
                                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                                    )
                                }
                            }
                        }
                    }
                }

                // ── 2. TODAY'S PATTERN CARD & GRAPH ─────────────────────────
                GlassyCard(
                    modifier = Modifier.fillMaxWidth(),
                    color = NotelSurface
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(
                                    "Today’s pattern",
                                    color = NotelTextPrimary,
                                    fontSize = 18.sp,
                                    fontWeight = FontWeight.Bold
                                )
                                Spacer(Modifier.width(6.dp))
                                Icon(
                                    Icons.Default.Info,
                                    contentDescription = "Info",
                                    tint = NotelTextSecondary,
                                    modifier = Modifier
                                        .size(16.dp)
                                        .clickable { showHrInfo = true }
                                )
                            }
                        }
                        Text(
                            "Heart rate from 12 AM to 11:59 PM",
                            color = NotelTextSecondary,
                            fontSize = 12.sp
                        )

                        Spacer(Modifier.height(16.dp))

                        HeartPatternGraph(
                            heartRateData = state.heartRateData,
                            selectedDateStr = state.selectedHeartRateDate,
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(210.dp)
                        )

                        Spacer(Modifier.height(16.dp))

                        // Graph Legend (FlowRow to prevent wrapping text vertically)
                        FlowRow(
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(
                                    modifier = Modifier
                                        .size(width = 16.dp, height = 3.dp)
                                        .background(Color(0xFF7C6EFF), RoundedCornerShape(2.dp))
                                )
                                Spacer(Modifier.width(6.dp))
                                Text("Heart rate", color = NotelTextSecondary, fontSize = 11.sp)
                            }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(
                                    modifier = Modifier
                                        .size(width = 14.dp, height = 10.dp)
                                        .background(Color(0xFF2A385E), RoundedCornerShape(2.dp))
                                )
                                Spacer(Modifier.width(6.dp))
                                Text("Resting range (45–70 bpm)", color = NotelTextSecondary, fontSize = 11.sp)
                            }
                            val peakBpmVal = remember(state.heartRateData) { state.heartRateData.maxOfOrNull { it.second } ?: 0 }
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(
                                    modifier = Modifier
                                        .size(8.dp)
                                        .background(Color(0xFFFF5252), CircleShape)
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    if (peakBpmVal > 0) "Peak $peakBpmVal bpm" else "Peak --",
                                    color = NotelTextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                        }
                    }
                }

                // ── 3. SIGNIFICANT SPIKES SUMMARY CARD ──────────────────────
                val todaySpikes = remember(state.heartRateData, state.isLoading) {
                    if (state.heartRateData.isEmpty()) listOf(0, 0, 0, 0)
                    else {
                        val readings = state.heartRateData.map { it.second }
                        val sorted = readings.sorted()
                        val max = sorted.last()
                        val p10 = sorted[(sorted.size * 0.10).toInt().coerceAtLeast(0)]
                        
                        var spikeCount = 0
                        var inEvent = false
                        var eventEndMs = 0L
                        var currentPeak = 0
                        
                        for ((tMs, bpm) in state.heartRateData) {
                            if (bpm >= 100) {
                                if (!inEvent || tMs > eventEndMs) {
                                    spikeCount++
                                    inEvent = true
                                    currentPeak = bpm
                                } else {
                                    currentPeak = maxOf(currentPeak, bpm)
                                }
                                eventEndMs = tMs + (5 * 60 * 1000)
                            }
                        }
                        val delta = max - p10
                        listOf(max, spikeCount, delta, p10)
                    }
                }

                val maxBpm = todaySpikes[0]
                val spikeCount = todaySpikes[1]
                val maxDelta = todaySpikes[2]

                val loadLevel = when {
                    maxBpm >= 130 || spikeCount >= 5 -> "High load"
                    maxBpm >= 110 || spikeCount >= 2 -> "Moderate load"
                    else -> "Normal load"
                }

                GlassyCard(
                    modifier = Modifier.fillMaxWidth(),
                    color = if (loadLevel == "High load") Color(0xFF2A121A) else NotelSurface
                ) {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Box(
                                    modifier = Modifier
                                        .size(36.dp)
                                        .background(Color(0xFF4A1820), CircleShape),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Icon(
                                        Icons.Default.Whatshot,
                                        contentDescription = null,
                                        tint = Color(0xFFFF5252),
                                        modifier = Modifier.size(20.dp)
                                    )
                                }
                                Spacer(Modifier.width(12.dp))
                                Column {
                                    Text(
                                        "$spikeCount significant spikes",
                                        color = NotelTextPrimary,
                                        fontSize = 16.sp,
                                        fontWeight = FontWeight.Bold
                                    )
                                    Text(
                                        loadLevel,
                                        color = Color(0xFFFF5252),
                                        fontSize = 13.sp,
                                        fontWeight = FontWeight.SemiBold
                                    )
                                }
                            }

                            Surface(
                                color = Color(0xFF4A1820),
                                shape = RoundedCornerShape(12.dp)
                            ) {
                                Text(
                                    loadLevel,
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                    color = Color(0xFFFF5252),
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }

                        Spacer(Modifier.height(16.dp))

                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceEvenly
                        ) {
                            SpikeMetricSmall(
                                label = "Peak",
                                value = if (maxBpm > 0) "$maxBpm" else "--",
                                unit = "bpm",
                                color = Color(0xFFFF5252)
                            )
                            SpikeMetricSmall(
                                label = "Largest jump",
                                value = if (maxDelta > 0) "+$maxDelta" else "--",
                                unit = "bpm",
                                color = NotelTextPrimary
                            )
                            SpikeMetricSmall(
                                label = "Total",
                                value = "$spikeCount",
                                unit = "events",
                                color = NotelTextPrimary
                            )
                        }

                        Spacer(Modifier.height(16.dp))

                        GlassyButton(
                            onClick = onNavigateToSpikeReview,
                            modifier = Modifier.fillMaxWidth(),
                            containerColor = Color(0xFF19223D)
                        ) {
                            Row(
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Text("Review spikes", color = NotelTextPrimary, fontWeight = FontWeight.SemiBold)
                                Icon(Icons.AutoMirrored.Filled.ArrowForward, contentDescription = null, tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                            }
                        }
                    }
                }

                // ── 4. HEALTH CONNECT STATUS ROW CARD ──────────────────────
                GlassyCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onNavigateToHealthConnect() },
                    color = NotelSurface
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp)
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(
                                modifier = Modifier
                                    .size(40.dp)
                                    .background(Color(0xFF1E284A), CircleShape),
                                contentAlignment = Alignment.Center
                            ) {
                                androidx.compose.foundation.Image(
                                    painter = androidx.compose.ui.res.painterResource(id = com.notel.notel.R.drawable.ic_health_connect),
                                    contentDescription = "Health Connect",
                                    modifier = Modifier.size(24.dp)
                                )
                            }
                            Spacer(Modifier.width(12.dp))
                            Column {
                                Text(
                                    "Health Connect",
                                    color = NotelTextPrimary,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 15.sp
                                )
                                Text(
                                    "Synced 2 min ago",
                                    color = NotelTextSecondary,
                                    fontSize = 12.sp
                                )
                            }
                        }
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowForward,
                            contentDescription = "View connection details",
                            tint = NotelTextSecondary,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                }

                // Extra scroll padding to ensure complete Health Connect card is visible above floating navigation bar
                Spacer(Modifier.height(72.dp))
            }
        }
    }
}

@Composable
fun HeartPatternGraph(
    heartRateData: List<Pair<Long, Int>>,
    modifier: Modifier = Modifier,
    selectedDateStr: String = "today"
) {
    val textMeasurer = rememberTextMeasurer()
    val zoneId = remember { java.time.ZoneId.systemDefault() }
    val context = LocalContext.current
    val is24Hour = remember(context) { android.text.format.DateFormat.is24HourFormat(context) }
    
    val targetDate = remember(selectedDateStr) {
        try {
            if (selectedDateStr == "today" || selectedDateStr.isBlank()) java.time.LocalDate.now()
            else java.time.LocalDate.parse(selectedDateStr)
        } catch(e: Exception) {
            java.time.LocalDate.now()
        }
    }

    val defaultStartMs = remember(targetDate) { targetDate.atStartOfDay(zoneId).toInstant().toEpochMilli() }
    val defaultEndMs = remember(targetDate) { targetDate.atTime(23, 59, 59).atZone(zoneId).toInstant().toEpochMilli() }

    val (startTimeMs, endTimeMs) = remember(targetDate) {
        defaultStartMs to defaultEndMs
    }
    
    val peakPoint = remember(heartRateData) {
        heartRateData.maxByOrNull { it.second }
    }

    Box(modifier = modifier) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            val leftPadding = 36.dp.toPx()
            val rightPadding = 16.dp.toPx()
            val topPadding = 24.dp.toPx()
            val bottomPadding = 28.dp.toPx()
            
            val graphWidth = size.width - leftPadding - rightPadding
            val graphHeight = size.height - topPadding - bottomPadding
            
            val minY = 20f
            val maxY = 180f
            
            fun yToPx(bpm: Float): Float {
                val clamped = bpm.coerceIn(minY, maxY)
                val ratio = (clamped - minY) / (maxY - minY)
                return topPadding + graphHeight * (1f - ratio)
            }
            
            fun xToPx(tMs: Long): Float {
                val duration = (endTimeMs - startTimeMs).coerceAtLeast(1L)
                val ratio = (tMs - startTimeMs).toFloat() / duration.toFloat()
                return leftPadding + graphWidth * ratio.coerceIn(0f, 1f)
            }

            // 1. Draw horizontal grid lines & Y-axis labels
            val yTicks = listOf(180, 140, 100, 60, 20)
            yTicks.forEach { tick ->
                val y = yToPx(tick.toFloat())
                drawLine(
                    color = Color(0xFF222F4C),
                    start = Offset(leftPadding, y),
                    end = Offset(size.width - rightPadding, y),
                    strokeWidth = 1.dp.toPx(),
                    pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(6f, 6f), 0f)
                )
                
                val textLayoutResult = textMeasurer.measure(
                    text = AnnotatedString("$tick"),
                    style = TextStyle(color = Color(0xFF7A8FAF), fontSize = 10.sp)
                )
                drawText(
                    textLayoutResult = textLayoutResult,
                    topLeft = Offset(leftPadding - textLayoutResult.size.width - 8.dp.toPx(), y - textLayoutResult.size.height / 2f)
                )
            }

            // 2. Draw Resting Range shaded band (45-70 bpm)
            val restingTop = yToPx(70f)
            val restingBottom = yToPx(45f)
            drawRect(
                color = Color(0xFF1B2847).copy(alpha = 0.6f),
                topLeft = Offset(leftPadding, restingTop),
                size = Size(graphWidth, restingBottom - restingTop)
            )

            // 3. Draw X-axis time labels & vertical grid lines across 24h (12 AM to 12 AM next day)
            val hourIntervals = listOf(0, 6, 12, 18, 24)
            hourIntervals.forEach { hr ->
                val labelTimeMs = if (hr == 24) {
                    targetDate.plusDays(1).atStartOfDay(zoneId).toInstant().toEpochMilli()
                } else {
                    targetDate.atTime(hr, 0).atZone(zoneId).toInstant().toEpochMilli()
                }
                val x = xToPx(labelTimeMs)
                
                // Vertical grid line for time tick
                drawLine(
                    color = Color(0xFF1D2A47),
                    start = Offset(x, topPadding),
                    end = Offset(x, topPadding + graphHeight),
                    strokeWidth = 1.dp.toPx(),
                    pathEffect = androidx.compose.ui.graphics.PathEffect.dashPathEffect(floatArrayOf(4f, 4f), 0f)
                )

                val labelText = if (is24Hour) {
                    if (hr == 24) "00:00" else String.format(java.util.Locale.US, "%02d:00", hr)
                } else {
                    when {
                        hr == 0 || hr == 24 -> "12 AM"
                        hr == 12 -> "12 PM"
                        hr > 12 -> "${hr - 12} PM"
                        else -> "$hr AM"
                    }
                }
                val textLayoutResult = textMeasurer.measure(
                    text = AnnotatedString(labelText),
                    style = TextStyle(color = Color(0xFF7A8FAF), fontSize = 10.sp, fontWeight = FontWeight.Medium)
                )
                val textWidth = textLayoutResult.size.width.toFloat()
                val clampedTextX = (x - textWidth / 2f).coerceIn(
                    leftPadding,
                    size.width - rightPadding - textWidth
                )
                
                drawText(
                    textLayoutResult = textLayoutResult,
                    topLeft = Offset(clampedTextX, size.height - bottomPadding + 6.dp.toPx())
                )
            }

            // 4. Draw Heart Rate Curve
            if (heartRateData.size >= 2) {
                val path = Path()
                heartRateData.forEachIndexed { index, point ->
                    val x = xToPx(point.first)
                    val y = yToPx(point.second.toFloat())
                    if (index == 0) {
                        path.moveTo(x, y)
                    } else {
                        path.lineTo(x, y)
                    }
                }
                drawPath(
                    path = path,
                    color = Color(0xFF7C6EFF),
                    style = Stroke(width = 2.5.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round)
                )
            }

            // 5. Highlight Peak Point
            if (peakPoint != null && peakPoint.second > 0) {
                val peakX = xToPx(peakPoint.first)
                val peakY = yToPx(peakPoint.second.toFloat())

                drawCircle(
                    color = Color(0xFFFF5252),
                    radius = 5.dp.toPx(),
                    center = Offset(peakX, peakY)
                )
                drawCircle(
                    color = Color.White,
                    radius = 2.dp.toPx(),
                    center = Offset(peakX, peakY)
                )

                val peakTextResult = textMeasurer.measure(
                    text = AnnotatedString("${peakPoint.second}"),
                    style = TextStyle(color = Color(0xFFFF5252), fontSize = 12.sp, fontWeight = FontWeight.Bold)
                )
                drawText(
                    textLayoutResult = peakTextResult,
                    topLeft = Offset((peakX - peakTextResult.size.width / 2f).coerceIn(leftPadding, size.width - rightPadding - peakTextResult.size.width), peakY - peakTextResult.size.height - 6.dp.toPx())
                )
            }
        }
    }
}

@Composable
fun SpikeMetricSmall(
    label: String,
    value: String,
    unit: String,
    color: Color = NotelTextPrimary,
    subtext: String? = null
) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            text = label.uppercase(),
            color = NotelTextSecondary,
            fontSize = 10.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.5.sp
        )
        Spacer(Modifier.height(2.dp))
        Text(
            text = value,
            color = color,
            fontSize = 24.sp,
            fontWeight = FontWeight.Black
        )
        Text(
            text = unit,
            color = NotelTextSecondary,
            fontSize = 10.sp
        )
        if (subtext != null) {
            Text(
                text = subtext,
                color = NotelTextSecondary.copy(alpha = 0.7f),
                fontSize = 9.sp,
                fontWeight = FontWeight.Medium
            )
        }
    }
}
