package com.notel.notel.ui.screen

import androidx.activity.compose.rememberLauncherForActivityResult
import kotlinx.coroutines.launch
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
    var selectedDate by remember { mutableStateOf(LocalDate.now()) }
    var showCalendar by remember { mutableStateOf(false) }

    // CSV Export states
    var showDownloadDialog by remember { mutableStateOf(false) }
    var selectedExportDays by remember { mutableIntStateOf(30) }
    var includeSpikes by remember { mutableStateOf(true) }
    val isExporting by viewModel.isExportingCsv.collectAsState()

    val context = androidx.compose.ui.platform.LocalContext.current
    val coroutineScope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        viewModel.fetchMetricsForDate("today")
    }

    LaunchedEffect(Unit) {
        viewModel.csvReadyEvent.collect { file ->
            val uri = androidx.core.content.FileProvider.getUriForFile(
                context,
                "${context.packageName}.provider",
                file
            )
            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                type = "text/csv"
                putExtra(android.content.Intent.EXTRA_STREAM, uri)
                addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            val chooser = android.content.Intent.createChooser(intent, "Share Biometrics CSV")
            context.startActivity(chooser)
        }
    }

    val displayDate = selectedDate.format(DateTimeFormatter.ofPattern("MMM d, yyyy"))

    if (showDownloadDialog) {
        AlertDialog(
            onDismissRequest = { if (!isExporting) showDownloadDialog = false },
            title = { Text("Export Biometrics CSV", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
            text = {
                Column(modifier = Modifier.fillMaxWidth()) {
                    Text(
                        "Select how far back you want the download to go:",
                        color = NotelTextSecondary,
                        fontSize = 14.sp,
                        modifier = Modifier.padding(bottom = 16.dp)
                    )
                    
                    val options = listOf(
                        7 to "Last 7 Days",
                        30 to "Last 30 Days",
                        90 to "Last 90 Days",
                        180 to "Last 180 Days",
                        -1 to "All Time"
                    )
                    
                    options.forEach { (days, label) ->
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { 
                                    selectedExportDays = days 
                                    if (days == -1) includeSpikes = false
                                }
                                .padding(vertical = 8.dp)
                        ) {
                            RadioButton(
                                selected = selectedExportDays == days,
                                onClick = { 
                                    selectedExportDays = days 
                                    if (days == -1) includeSpikes = false
                                },
                                colors = RadioButtonDefaults.colors(
                                    selectedColor = NotelPrimary,
                                    unselectedColor = NotelTextSecondary
                                )
                            )
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(label, color = NotelTextPrimary, fontSize = 16.sp)
                        }
                    }

                    Spacer(modifier = Modifier.height(16.dp))
                    HorizontalDivider(color = Color.White.copy(alpha = 0.1f))
                    Spacer(modifier = Modifier.height(12.dp))

                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                text = "Include Heart Rate Spikes", 
                                color = if (selectedExportDays == -1) NotelTextSecondary.copy(alpha = 0.5f) else NotelTextPrimary, 
                                fontSize = 15.sp, 
                                fontWeight = FontWeight.SemiBold
                            )
                            Text(
                                text = if (selectedExportDays == -1) "you can not toggle it on when you are on all time" else "Calculates POTS spikes. Turning off makes export instant.", 
                                color = if (selectedExportDays == -1) NotelPrimary else NotelTextSecondary, 
                                fontSize = 12.sp
                            )
                        }
                        Switch(
                            checked = includeSpikes,
                            onCheckedChange = { includeSpikes = it },
                            enabled = selectedExportDays != -1,
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = Color.White,
                                checkedTrackColor = NotelPrimary,
                                uncheckedThumbColor = NotelTextSecondary,
                                uncheckedTrackColor = NotelSurfaceHigh,
                                disabledCheckedThumbColor = Color.White.copy(alpha = 0.3f),
                                disabledCheckedTrackColor = NotelPrimary.copy(alpha = 0.3f),
                                disabledUncheckedThumbColor = NotelTextSecondary.copy(alpha = 0.3f),
                                disabledUncheckedTrackColor = NotelSurfaceHigh.copy(alpha = 0.3f)
                            )
                        )
                    }
                }
            },
            confirmButton = {
                Button(
                    onClick = {
                        viewModel.exportMetricsCsvAsync(selectedExportDays, includeSpikes)
                        showDownloadDialog = false
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                    enabled = !isExporting,
                    shape = RoundedCornerShape(12.dp)
                ) {
                    if (isExporting) {
                        CircularProgressIndicator(color = Color.White, modifier = Modifier.size(20.dp))
                    } else {
                        Text("Export", color = Color.White, fontWeight = FontWeight.Bold)
                    }
                }
            },
            dismissButton = {
                TextButton(onClick = { showDownloadDialog = false }, enabled = !isExporting) {
                    Text("Cancel", color = NotelTextSecondary)
                }
            },
            containerColor = NotelSurface,
            shape = RoundedCornerShape(16.dp)
        )
    }

    if (showCalendar) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = selectedDate.atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli(),
            selectableDates = object : SelectableDates {
                override fun isSelectableDate(utcTimeMillis: Long): Boolean {
                    if (utcTimeMillis > System.currentTimeMillis()) return false
                    
                    val localSdf = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).apply {
                        timeZone = java.util.TimeZone.getTimeZone(java.time.ZoneId.systemDefault().id)
                    }
                    val dateStr = localSdf.format(java.util.Date(utcTimeMillis))
                    val todayStr = java.time.LocalDate.now().toString()
                    
                    if (dateStr == todayStr) return true
                    
                    return state.historicalHeartRate.any { it.first == dateStr } || 
                           state.historicalSleep.any { it.first == dateStr } ||
                           state.historicalCalories.any { it.first == dateStr }
                }
            }
        )
        DatePickerDialog(
            onDismissRequest = { showCalendar = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { millis ->
                        val localDate = java.time.Instant.ofEpochMilli(millis).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
                        selectedDate = localDate
                        viewModel.fetchMetricsForDate(localDate.toString())
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
                    if (isExporting) {
                        CircularProgressIndicator(
                            color = NotelPrimary,
                            modifier = Modifier
                                .size(48.dp)
                                .padding(12.dp),
                            strokeWidth = 2.dp
                        )
                    } else {
                        IconButton(onClick = { showDownloadDialog = true }) {
                            Icon(Icons.Default.Download, "Export CSV", tint = NotelTextSecondary)
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
                    today.minusDays(it.toLong())
                }.reversed()

                last7Days.forEach { date ->
                    val dateStr = date.toString()
                    val todayStr = today.toString()
                    
                    val isSelected = selectedDate == date
                    val hasData = dateStr == todayStr ||
                                 state.historicalHeartRate.any { it.first == dateStr } || 
                                 state.historicalSleep.any { it.first == dateStr } ||
                                 state.historicalCalories.any { it.first == dateStr }
                    
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        modifier = Modifier
                            .width(44.dp)
                            .clickable(enabled = hasData) { 
                                selectedDate = date 
                                viewModel.fetchMetricsForDate(dateStr)
                            }
                            .alpha(if (hasData) 1f else 0.3f)
                    ) {
                        Text(
                            text = date.format(DateTimeFormatter.ofPattern("EEE")), 
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
                                text = date.dayOfMonth.toString(),
                                color = if (isSelected) NotelTextPrimary else if (hasData) NotelTextSecondary else Color.Gray,
                                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                                fontSize = 13.sp
                            )
                        }
                    }
                }
            }

            Spacer(Modifier.height(16.dp))

            Spacer(Modifier.height(2.dp))

            Spacer(Modifier.height(14.dp))

            // Premium Key Metrics Grid (Auto-populates if cached, else pulls heart rate and leaves others blank as requested)
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
                        value = if (state.isLoading) "--" else if (state.latestHeartRate > 0) "${state.latestHeartRate}" else "No Data Recorded",
                        unit = "BPM",
                        icon = Icons.Default.Favorite,
                        color = NotelPrimary,
                        isLoading = state.isLoading,
                        subtitle = "Last daily reading"
                    )
                }
                item {
                    MetricTile(
                        title = "Weight",
                        value = if (state.weightPounds > 0f) "${Math.round(state.weightPounds)}" else if (state.isLoading) "--" else "No Data Recorded",
                        unit = "lbs",
                        icon = Icons.Default.MonitorWeight,
                        color = Color(0xFF4FC3F7),
                        isLoading = state.isLoading && state.weightPounds <= 0f
                    )
                }
                item {
                    val brIsToday = selectedDate == java.time.LocalDate.now()
                    MetricTile(
                        title = "Breathing Rate",
                        value = if (state.isLoading) "--" else if (state.respiratoryRate > 0.0) String.format("%.1f", state.respiratoryRate) else "No Data Recorded",
                        unit = "brpm",
                        icon = Icons.Default.Air,
                        color = Color(0xFF81C784),
                        isLoading = state.isLoading,
                        subtitle = "Last daily reading",
                        customNote = if (brIsToday && state.respiratoryRate == 0.0 && !state.isLoading) "Breathing Rate is calculated at night. Check back tomorrow." else null
                    )
                }
                item {
                    val boIsToday = selectedDate == java.time.LocalDate.now()
                    MetricTile(
                        title = "Blood Oxygen",
                        value = if (state.isLoading) "--" else if (state.bloodOxygen > 0.0) String.format("%.1f", state.bloodOxygen) else "No Data Recorded",
                        unit = "%",
                        icon = Icons.Default.Opacity,
                        color = Color(0xFFFF8A65),
                        isLoading = state.isLoading,
                        subtitle = "Last daily reading",
                        customNote = if (boIsToday && state.bloodOxygen == 0.0 && !state.isLoading) "Blood Oxygen is calculated at night. Check back tomorrow." else null
                    )
                }
                item {
                    MetricTile(
                        title = "Resting HR",
                        value = if (state.isLoading) "--" else if (state.restingHeartRate > 0) "${state.restingHeartRate}" else "No Data Recorded",
                        unit = "BPM",
                        icon = Icons.Default.Bedtime,
                        color = Color(0xFFBA68C8),
                        isLoading = state.isLoading,
                        subtitle = "Last daily reading"
                    )
                }
                item {
                    val hrvIsToday = selectedDate == java.time.LocalDate.now()
                    MetricTile(
                        title = "HRV",
                        value = if (state.isLoading) "--" else if (state.currentHrv > 0.0) String.format("%.0f", state.currentHrv) else "No Data Recorded",
                        unit = "ms",
                        icon = Icons.Default.Timeline,
                        color = Color(0xFF4DB6AC),
                        isLoading = state.isLoading,
                        customNote = if (hrvIsToday && state.currentHrv == 0.0 && !state.isLoading) "HRV is calculated at night. Check back tomorrow." else null
                    )
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
    color: Color,
    isLoading: Boolean = false,
    subtitle: String? = null,
    customNote: String? = null
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .height(160.dp),
        shape = RoundedCornerShape(24.dp),
        color = NotelSurface.copy(alpha = 0.15f),
        border = androidx.compose.foundation.BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
    ) {
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
                    if (customNote != null) {
                        Text(
                            text = customNote,
                            color = NotelTextSecondary.copy(alpha = 0.7f),
                            fontSize = 11.sp,
                            lineHeight = 15.sp,
                            fontWeight = FontWeight.Normal,
                            modifier = Modifier.padding(bottom = 6.dp)
                        )
                    } else {
                        Row(verticalAlignment = Alignment.Bottom) {
                            Text(
                                text = value,
                                color = if (value == "No Data Recorded" || value == "--") NotelTextSecondary.copy(alpha = 0.6f) else NotelTextPrimary,
                                fontSize = if (value == "No Data Recorded") 13.sp else 32.sp,
                                fontWeight = if (value == "No Data Recorded" || value == "--") FontWeight.Normal else FontWeight.Black,
                                modifier = if (value == "No Data Recorded") Modifier.padding(bottom = 4.dp) else Modifier
                            )
                            if (value != "No Data Recorded" && value != "--") {
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    text = unit,
                                    color = NotelTextSecondary,
                                    fontSize = 12.sp,
                                    modifier = Modifier.padding(bottom = 6.dp)
                                )
                            }
                        }
                    }
                    
                    Spacer(Modifier.height(2.dp))

                    Text(
                        text = title,
                        color = NotelTextSecondary,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.Medium
                    )

                    if (subtitle != null && !isLoading && customNote == null && value != "No Data Recorded" && value != "--") {
                        Text(
                            text = subtitle,
                            color = NotelTextSecondary.copy(alpha = 0.5f),
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Normal,
                            modifier = Modifier.padding(top = 2.dp)
                        )
                    }
                }
            }
        }
    }
}
