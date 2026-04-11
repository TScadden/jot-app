package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.*
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.rounded.*
import androidx.compose.ui.graphics.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.BodyLoadViewModel
import com.notel.notel.ui.viewmodel.QuickLogViewModel
import com.notel.notel.ui.viewmodel.HabitViewModel
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.ui.viewmodel.EventCounterDto
import com.notel.notel.data.local.entity.Category
import java.time.LocalDate
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BodyLoadScreen(
    viewModel: BodyLoadViewModel = hiltViewModel(),
    onBack: () -> Unit,
    onNavigateToConnections: () -> Unit = {},
    quickLogViewModel: QuickLogViewModel = hiltViewModel(),
    habitViewModel: HabitViewModel = hiltViewModel()
) {
    val state by viewModel.uiState.collectAsState()
    val quickLogState by quickLogViewModel.uiState.collectAsState()
    val habits by habitViewModel.habits.collectAsState()

    // Auto-hide success message
    LaunchedEffect(quickLogState.saveSuccess) {
        if (quickLogState.saveSuccess) {
            kotlinx.coroutines.delay(3000)
            quickLogViewModel.resetSaveSuccess()
        }
    }

    // Auto-fetch suggestions if category is selected and auto is on
    LaunchedEffect(quickLogState.selectedCategory, quickLogState.autoAiSuggestions) {
        if (quickLogState.autoAiSuggestions && quickLogState.selectedCategory != null && quickLogState.chips.isEmpty()) {
            quickLogViewModel.fetchSuggestions()
        }
    }

    val sheetState = rememberModalBottomSheetState()
    var showTheorySheet by remember { mutableStateOf(false) }
    var showWeatherSheet by remember { mutableStateOf(false) }
    var showUvInfo by remember { mutableStateOf(false) }
    val todayStr = java.time.LocalDate.now().toString()
    val isToday = state.selectedDate == todayStr

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = "Home",
                        fontWeight = FontWeight.Black,
                        color = NotelTextPrimary,
                        fontSize = 22.sp
                    )
                },
                navigationIcon = {},
                actions = {
                    IconButton(
                        onClick = { showWeatherSheet = true },
                        modifier = Modifier.width(64.dp)
                    ) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(4.dp)
                        ) {
                            state.weather?.let { w ->
                                Text(
                                    text = "${w.temp}°",
                                    color = NotelTextPrimary.copy(alpha = 0.8f),
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                            Icon(
                                imageVector = Icons.Default.Cloud,
                                contentDescription = "Weather",
                                tint = NotelPrimary.copy(alpha = 0.7f),
                                modifier = Modifier.size(20.dp)
                            )
                        }
                    }
                    IconButton(onClick = onNavigateToConnections) {
                        Icon(
                            imageVector = Icons.Default.Watch,
                            contentDescription = "Connections",
                            tint = NotelPrimary,
                            modifier = Modifier.size(24.dp)
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = NotelBackground
                )
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize(),
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = 160.dp
            ),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            item {
                BodyLoadCard(
                    state = state,
                    counters = quickLogState.eventCounters,
                    onDaySelected = { viewModel.selectDay(it) },
                    onFactorSelected = { viewModel.selectFactor(it) },
                    onResetSelection = { viewModel.selectFactor(null) },
                    onShowTheory = { 
                        viewModel.markTheorySeen()
                        showTheorySheet = true 
                    },
                    onRefresh = { viewModel.refresh() },
                    onBackToToday = { viewModel.selectDay(todayStr) },
                    onLocationUpdate = { lat, lon, city ->
                        viewModel.updateLocation(lat, lon, city)
                    }
                )
            }

            // Success Indicator for Logs
            item {
                AnimatedVisibility(
                    visible = quickLogState.saveSuccess,
                    enter = expandVertically() + fadeIn(),
                    exit = shrinkVertically() + fadeOut()
                ) {
                    Surface(
                        modifier = Modifier.padding(16.dp),
                        color = Color(0xFF43A047).copy(alpha = 0.1f),
                        shape = RoundedCornerShape(12.dp),
                        border = BorderStroke(1.dp, Color(0xFF43A047).copy(alpha = 0.2f))
                    ) {
                        Row(modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.CheckCircle, "Success", tint = Color(0xFF43A047), modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Log saved successfully!", color = Color.White, fontSize = 12.sp)
                        }
                    }
                }
            }
            
            // Divider under streak area
            item {
                HorizontalDivider(
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    color = Color.White.copy(alpha = 0.05f)
                )
                
                Spacer(Modifier.height(16.dp))
            }

            // ── Recommended for You Layer ─────────────────────────────
            if (quickLogState.smartCategories.isNotEmpty()) {
                item {
                    Box(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp).padding(top = 8.dp),
                        contentAlignment = Alignment.CenterStart
                    ) {
                        Text(
                            "Recommended for You",
                            style = MaterialTheme.typography.labelMedium,
                            color = NotelPrimary
                        )

                        // Compact Inline Log Button - Fade only to prevent shifts
                        androidx.compose.animation.AnimatedVisibility(
                            visible = quickLogState.selectedChips.isNotEmpty(),
                            enter = fadeIn(animationSpec = tween(400)),
                            exit = fadeOut(animationSpec = tween(400)),
                            modifier = Modifier.align(Alignment.CenterEnd)
                        ) {
                            Surface(
                                onClick = { quickLogViewModel.saveEntry() },
                                color = NotelPrimary.copy(alpha = 0.15f),
                                shape = RoundedCornerShape(8.dp),
                                border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.3f))
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(Icons.Default.Check, "Log", tint = NotelPrimary, modifier = Modifier.size(12.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("LOG ENTRY", color = NotelPrimary, fontSize = 9.sp, fontWeight = FontWeight.Black, letterSpacing = 1.sp)
                                }
                            }
                        }
                    }
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 24.dp, vertical = 8.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(quickLogState.smartCategories) { cat ->
                            CategoryChipSmall(
                                category = cat,
                                isSelected = cat.id == quickLogState.selectedCategory?.id,
                                onClick = { quickLogViewModel.selectCategory(cat) }
                            )
                        }
                    }
                }
            }
            
            item { Spacer(Modifier.height(8.dp)) }
            
            // ── AI Suggestions Grid ─────────────────────────────
            item {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp)
                        .heightIn(min = 100.dp)
                ) {
                    when {
                        quickLogState.isLoadingChips -> Box(Modifier.fillMaxWidth().padding(vertical = 32.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(color = NotelPrimary, modifier = Modifier.size(24.dp))
                        }
                        quickLogState.chips.isEmpty() && !quickLogState.autoAiSuggestions -> {
                            Column(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text("No suggestions loaded", color = NotelTextSecondary, fontSize = 12.sp)
                                Spacer(Modifier.height(8.dp))
                                TextButton(onClick = { quickLogViewModel.fetchSuggestions() }) {
                                    Text("Load Suggestions", color = NotelPrimary, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                        else -> {
                            Column {
                                FlowRow(
                                    modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                    verticalArrangement = Arrangement.spacedBy(10.dp),
                                    maxItemsInEachRow = 2
                                ) {
                                    quickLogState.chips.forEach { chip ->
                                        val isSelected = chip in quickLogState.selectedChips
                                        Surface(
                                            onClick = { quickLogViewModel.toggleChip(chip) },
                                            modifier = Modifier
                                                .weight(1f)
                                                .animateContentSize()
                                                .clip(RoundedCornerShape(14.dp))
                                                .background(if (isSelected) NotelPrimary.copy(alpha = 0.8f) else NotelSurfaceHigh.copy(alpha = 0.2f))
                                                .border(
                                                    width = 1.dp,
                                                    color = if (isSelected) Color.Transparent else Color.White.copy(alpha = 0.05f),
                                                    shape = RoundedCornerShape(14.dp)
                                                ),
                                            color = Color.Transparent
                                        ) {
                                            Text(
                                                text = chip,
                                                modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                                                color = if (isSelected) Color.White else NotelTextPrimary,
                                                fontSize = 13.sp,
                                                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis
                                            )
                                        }
                                    }
                                    
                                    // Spacer if odd number of chips to maintain grid alignment
                                    if (quickLogState.chips.size % 2 != 0) {
                                        Spacer(Modifier.weight(1f))
                                    }
                                }

                                Text(
                                    text = "Quick notes are generated with AI using your data, so they may not always represent exactly what you are looking for.",
                                    color = NotelTextSecondary.copy(alpha = 0.6f),
                                    fontSize = 10.sp,
                                    lineHeight = 14.sp,
                                    modifier = Modifier.padding(top = 4.dp, bottom = 8.dp)
                                )
                            }
                        }
                    }
                }
            }

            // ── Daily Routine Section ─────────────────────────────
            item {
                Spacer(Modifier.height(24.dp))
                HorizontalDivider(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp),
                    color = Color.White.copy(alpha = 0.05f)
                )
                Spacer(Modifier.height(24.dp))
            }

            item {
                val checkedCount = habits.count { habitViewModel.isCheckedToday(it) }
                val progressRatio = if (habits.isEmpty()) 0f else checkedCount.toFloat() / habits.size.toFloat()
                var newHabitText by remember { mutableStateOf("") }

                Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp)) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            "Daily Routine",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary
                        )
                        if (habits.isNotEmpty()) {
                            Surface(
                                shape = RoundedCornerShape(12.dp),
                                color = NotelPrimary.copy(alpha = 0.1f),
                                border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.2f))
                            ) {
                                Text(
                                    "$checkedCount/${habits.size} DONE",
                                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                                    color = NotelPrimary,
                                    fontSize = 10.sp,
                                    fontWeight = FontWeight.Black,
                                    letterSpacing = 1.sp
                                )
                            }
                        }
                    }
                    
                    Spacer(Modifier.height(8.dp))
                    
                    // Glassy Progress Bar
                    Box(modifier = Modifier.fillMaxWidth().height(4.dp).clip(CircleShape).background(NotelSurfaceHigh.copy(alpha = 0.1f))) {
                        Box(modifier = Modifier.fillMaxWidth(progressRatio).fillMaxHeight().background(NotelPrimary))
                    }
                    
                    Spacer(Modifier.height(16.dp))
                    
                    // Horizontal scrolling habits or placeholder
                    if (habits.isEmpty()) {
                        Surface(
                            modifier = Modifier.fillMaxWidth().height(80.dp),
                            shape = RoundedCornerShape(20.dp),
                            color = NotelSurfaceHigh.copy(alpha = 0.1f),
                            border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                        ) {
                            Box(contentAlignment = Alignment.Center) {
                                Text("No habits yet. Add one below! 🔥", color = NotelTextSecondary, fontSize = 13.sp)
                            }
                        }
                    } else {
                        LazyRow(
                            modifier = Modifier.fillMaxWidth().offset(x = (-24).dp),
                            contentPadding = PaddingValues(horizontal = 24.dp),
                            horizontalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            items(habits) { habit ->
                                val isChecked = habitViewModel.isCheckedToday(habit)
                                val streak = habitViewModel.getStreak(habit)
                                
                                Surface(
                                    onClick = { habitViewModel.toggleHabit(habit.id, !isChecked) },
                                    modifier = Modifier
                                        .width(140.dp)
                                        .height(100.dp),
                                    shape = RoundedCornerShape(20.dp),
                                    color = if (isChecked) NotelPrimary.copy(alpha = 0.15f) else NotelSurfaceHigh.copy(alpha = 0.1f),
                                    border = BorderStroke(1.dp, if (isChecked) NotelPrimary.copy(alpha = 0.3f) else Color.White.copy(alpha = 0.05f))
                                ) {
                                    Column(
                                        modifier = Modifier.padding(12.dp),
                                        verticalArrangement = Arrangement.SpaceBetween
                                    ) {
                                        Row(
                                            modifier = Modifier.fillMaxWidth(),
                                            horizontalArrangement = Arrangement.SpaceBetween,
                                            verticalAlignment = Alignment.Top
                                        ) {
                                            Text(
                                                if (isChecked) "✅" else "🔥 $streak",
                                                fontSize = 11.sp,
                                                fontWeight = FontWeight.Bold,
                                                color = if (streak > 0) Color(0xFFE2A123) else NotelTextSecondary
                                            )
                                            IconButton(onClick = { habitViewModel.deleteHabit(habit.id) }, modifier = Modifier.size(16.dp)) {
                                                Icon(Icons.Default.Close, null, tint = NotelTextSecondary.copy(alpha = 0.5f), modifier = Modifier.size(10.dp))
                                            }
                                        }
                                        
                                        Column {
                                            Text(
                                                habit.title,
                                                color = NotelTextPrimary,
                                                fontSize = 13.sp,
                                                fontWeight = FontWeight.Bold,
                                                maxLines = 2,
                                                overflow = TextOverflow.Ellipsis,
                                                lineHeight = 16.sp
                                            )
                                            Text(
                                                habit.target_time ?: "Anytime",
                                                color = NotelTextSecondary,
                                                fontSize = 10.sp
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Spacer(Modifier.height(16.dp))

                    // Add Habit Input
                    OutlinedTextField(
                        value = newHabitText,
                        onValueChange = { newHabitText = it },
                        placeholder = { Text("Add new routine habit...", color = NotelTextSecondary, fontSize = 13.sp) },
                        modifier = Modifier.fillMaxWidth(),
                        trailingIcon = {
                            if (newHabitText.isNotBlank()) {
                                IconButton(onClick = {
                                    habitViewModel.addHabit(newHabitText)
                                    newHabitText = ""
                                }) {
                                    Icon(Icons.Default.Add, "Add", tint = NotelPrimary)
                                }
                            }
                        },
                        shape = RoundedCornerShape(16.dp),
                        singleLine = true,
                        textStyle = androidx.compose.ui.text.TextStyle(fontSize = 14.sp),
                        colors = OutlinedTextFieldDefaults.colors(
                            focusedBorderColor = NotelPrimary.copy(alpha = 0.5f),
                            unfocusedBorderColor = NotelSurfaceHigh.copy(alpha = 0.2f),
                            focusedTextColor = NotelTextPrimary,
                            unfocusedTextColor = NotelTextPrimary,
                            cursorColor = NotelPrimary,
                            focusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.05f),
                            unfocusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.05f)
                        )
                    )
                }
            }

            item {
                BodyLoadMonthView(
                    state = state,
                    onDaySelected = { viewModel.selectDay(it) }
                )
            }

            item { Spacer(Modifier.height(110.dp)) }

            if (state.error != null) {
                item {
                    Spacer(Modifier.height(16.dp))
                    Text(
                        state.error!!,
                        color = MaterialTheme.colorScheme.error,
                        fontSize = 12.sp,
                        modifier = Modifier.padding(horizontal = 32.dp)
                    )
                }
            }
        }
    }

    if (showTheorySheet) {
        ModalBottomSheet(
            onDismissRequest = { showTheorySheet = false },
            sheetState = sheetState,
            containerColor = NotelSurface
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(24.dp)
                    .padding(bottom = 40.dp)
            ) {
                Text(
                    text = "The Cup Theory",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = NotelPrimary
                )
                Spacer(Modifier.height(16.dp))
                Text(
                    text = "Think of your body's capacity as a cup. Every stressor—poor sleep, dehydration, high heart rate, or physical exertion—adds water to that cup.\n\n" +
                           "Your Body Load score is calculated using clinical biometric weighting:\n\n" +
                           "• 30% Autonomic Balance (HRV): Deviations from your 30-day RMSSD mean.\n" +
                           "• 25% Sleep Architecture: Accounting for your recent 'Sleep Debt'.\n" +
                           "• 20% Activity Stress: Your 7-day vs. 42-day workload ratio.\n" +
                           "• 15% Orthostatic Spikes: High HR events (>100bpm) that fill your cup.\n" +
                           "• 5% Heart Rate: Real-time RHR jumps from your baseline.\n" +
                           "• 5% Subjective Jots: AI context for pain, anxiety, and flares.\n\n" +
                           "When the cup is nearly empty, you feel resilient. When it's full, even a small drop can cause it to overflow, leading to symptom flares.",
                    color = NotelTextPrimary,
                    fontSize = 15.sp,
                    lineHeight = 22.sp
                )
                Spacer(Modifier.height(24.dp))
                Button(
                    onClick = { showTheorySheet = false },
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary)
                ) {
                    Text("Got it")
                }
            }
        }
    }

    if (showWeatherSheet) {
        ModalBottomSheet(
            onDismissRequest = { showWeatherSheet = false },
            containerColor = NotelSurface
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 32.dp)
                    .padding(bottom = 64.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                val weather = state.weather
                if (weather != null) {
                    Text(weather.locationName, color = NotelTextPrimary, fontSize = 20.sp, fontWeight = FontWeight.Black)
                    Text(weather.condition, color = NotelTextSecondary, fontSize = 14.sp)
                    
                    Spacer(Modifier.height(32.dp))
                    
                    FlowRow(
                        modifier = Modifier.fillMaxWidth(),
                        maxItemsInEachRow = 2,
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                        verticalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        // Temp Box
                        WeatherMetricBox(
                            icon = weather.icon,
                            value = "${weather.temp}°${weather.unit}",
                            label = "Temperature",
                            modifier = Modifier.weight(1f)
                        )
                        
                        // Humidity Box
                        WeatherMetricBox(
                            icon = "💧",
                            value = "${weather.humidity}%",
                            label = "Humidity",
                            modifier = Modifier.weight(1f)
                        )
                        
                        // Wind Box
                        WeatherMetricBox(
                            icon = "💨",
                            value = String.format("%.1f", weather.windSpeed),
                            subLabel = if (weather.unit == "F") "mph" else "km/h",
                            label = "Wind Velocity",
                            modifier = Modifier.weight(1f)
                        )
                        
                        // UV Box (Clickable)
                        Surface(
                            modifier = Modifier
                                .weight(1f)
                                .clip(RoundedCornerShape(20.dp))
                                .clickable { showUvInfo = true },
                            color = NotelSurfaceHigh.copy(alpha = 0.1f),
                            shape = RoundedCornerShape(20.dp),
                            border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                        ) {
                            Column(
                                modifier = Modifier.padding(16.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text("☀️", fontSize = 24.sp, color = if (weather.uvIndex > 5) NotelAccent else NotelTextPrimary)
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    text = String.format("%.1f", weather.uvIndex),
                                    color = if (weather.uvIndex > 5) NotelAccent else NotelTextPrimary,
                                    fontSize = 18.sp,
                                    fontWeight = FontWeight.Bold
                                )
                                Text("UV Index", color = NotelTextSecondary, fontSize = 11.sp)
                                if (weather.uvIndex > 5) {
                                    Text("High Risk", color = NotelAccent, fontSize = 9.sp, fontWeight = FontWeight.Black)
                                }
                            }
                        }
                    }
                    
                    if (weather.uvIndex > 5) {
                        Spacer(Modifier.height(24.dp))
                        Surface(
                            color = NotelAccent.copy(alpha = 0.1f),
                            shape = RoundedCornerShape(12.dp),
                            border = BorderStroke(1.dp, NotelAccent.copy(alpha = 0.3f))
                        ) {
                            Row(
                                modifier = Modifier.padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                Icon(Icons.Default.Warning, contentDescription = null, tint = NotelAccent, modifier = Modifier.size(16.dp))
                                Text("High UV levels detected. Consider sun protection.", color = NotelAccent, fontSize = 12.sp, fontWeight = FontWeight.Medium)
                            }
                        }
                    }
                } else {
                    CircularProgressIndicator(color = NotelPrimary)
                    Spacer(Modifier.height(16.dp))
                    Text("Fetching local weather...", color = NotelTextSecondary, fontSize = 14.sp)
                }
            }
        }
    }

    val uvSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)

    if (showUvInfo) {
        ModalBottomSheet(
            onDismissRequest = { showUvInfo = false },
            sheetState = uvSheetState,
            containerColor = NotelBackground, // Dark background like screenshot
            dragHandle = { BottomSheetDefaults.DragHandle(color = Color.White.copy(alpha = 0.2f)) }
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 24.dp)
                    .padding(bottom = 64.dp)
            ) {
                Text(
                    text = "UV INDEX",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Black,
                    color = Color.White,
                    letterSpacing = 2.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                // UV Index Ranges Card
                Surface(
                    color = NotelSurface,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("UV Index Ranges", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        Spacer(Modifier.height(16.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(12.dp).background(Color(0xFF66BB6A), CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Text("Low", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("0-2", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(12.dp).background(Color(0xFFFFD54F), CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Text("Moderate", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("3-5", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(12.dp).background(Color(0xFFFFB74D), CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Text("High", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("6-7", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(12.dp).background(Color(0xFFEF9A9A), CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Text("Very High", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("8-10", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Box(Modifier.size(12.dp).background(Color(0xFFCE93D8), CircleShape))
                            Spacer(Modifier.width(12.dp))
                            Text("Extreme", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("11+", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                    }
                }
                
                Spacer(Modifier.height(32.dp))
                
                Text("Why UV Index Matters", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "The UV Index measures the intensity of ultraviolet radiation from the sun. Excessive UV exposure causes sunburn, premature skin aging, eye damage, and significantly increases the risk of skin cancer including melanoma.\n\nUV radiation is highest between 10am and 4pm, at higher altitudes, near the equator, and during summer months. Reflection from water, sand, and snow can increase exposure.",
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 14.sp,
                    lineHeight = 20.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                // Optimal Threshold Card
                Surface(
                    color = Color(0xFF1A1C1E),
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color(0xFF4CAF50).copy(alpha = 0.2f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🎯", fontSize = 18.sp)
                            Spacer(Modifier.width(8.dp))
                            Text("Optimal Threshold: UV Index below 3", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "For skin longevity, aim to be outside only when UV is below 3, or before 10am / after 4pm. This is the safest range for unprotected skin exposure.",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
                
                Spacer(Modifier.height(16.dp))
                
                // Indoor UV Card
                Surface(
                    color = Color(0xFF1A1C1E),
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color(0xFFFFB74D).copy(alpha = 0.2f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Warning, contentDescription = null, tint = Color(0xFFFFB74D), modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Indoor UV Exposure", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "Standard windows do NOT block all UV rays. UVA penetrates glass and causes skin aging. Consider UV-blocking window film, or apply sunscreen even when indoors near windows.",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
                
                Spacer(Modifier.height(32.dp))
                
                Text("Sunscreen Guidance", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                Spacer(Modifier.height(12.dp))
                
                Surface(
                    color = NotelSurface,
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🧴", fontSize = 18.sp)
                            Spacer(Modifier.width(8.dp))
                            Text("Mineral Sunscreen (Recommended)", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "Use mineral/physical sunscreen with zinc oxide or titanium dioxide. These sit on skin and reflect UV, avoiding chemical absorption. Look for broad-spectrum (UVA + UVB) protection, SPF 30-50+.",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
                
                Spacer(Modifier.height(12.dp))
                
                Surface(
                    color = NotelSurface,
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🔄", fontSize = 18.sp)
                            Spacer(Modifier.width(8.dp))
                            Text("Reapplication", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "Reapply every 2 hours, or immediately after swimming or sweating. Most people apply only 25-50% of the recommended amount.",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
                
                Spacer(Modifier.height(32.dp))
                
                Text("Protection by Level", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                Spacer(Modifier.height(12.dp))
                
                // Risk Levels
                ProtectionLevelCard(
                    title = "Low (0-2) ✓ Safe Zone",
                    description = "Minimal risk. This is the ideal range for outdoor activities. Wear sunglasses on bright days for eye protection.",
                    color = Color(0xFF66BB6A)
                )
                Spacer(Modifier.height(12.dp))
                ProtectionLevelCard(
                    title = "Moderate (3-5)",
                    description = "Apply mineral sunscreen (SPF 30+), wear UV-blocking sunglasses and a hat. Limit midday exposure (10am-4pm).",
                    color = Color(0xFFFFD54F)
                )
                Spacer(Modifier.height(12.dp))
                ProtectionLevelCard(
                    title = "High (6-7)",
                    description = "Protection essential. Use SPF 30-50 mineral sunscreen, wear UPF clothing, wide-brim hat, and wrap-around sunglasses. Seek shade between 10am-4pm.",
                    color = Color(0xFFFFB74D)
                )
                Spacer(Modifier.height(12.dp))
                ProtectionLevelCard(
                    title = "Very High (8-10)",
                    description = "Avoid sun between 10am-4pm. Use SPF 50+ mineral sunscreen, full coverage UPF clothing, hat, and sunglasses are mandatory. Reapply sunscreen every 2 hours.",
                    color = Color(0xFFEF9A9A)
                )
                Spacer(Modifier.height(12.dp))
                ProtectionLevelCard(
                    title = "Extreme (11+)",
                    description = "Stay indoors during peak hours (10am-4pm). If outside, seek shade, wear full protective UPF clothing, SPF 50+ mineral sunscreen, and wrap-around sunglasses. Unprotected skin burns in minutes.",
                    color = Color(0xFFCE93D8)
                )
            }
        }
    }
}

@Composable
fun ProtectionLevelCard(title: String, description: String, color: Color) {
    Surface(
        color = NotelSurface,
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, color.copy(alpha = 0.2f))
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(title, color = color, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            Spacer(Modifier.height(8.dp))
            Text(description, color = Color.White.copy(alpha = 0.5f), fontSize = 12.sp, lineHeight = 18.sp)
        }
    }
}

@Composable
fun WeatherMetricBox(
    icon: String,
    value: String,
    label: String,
    subLabel: String? = null,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier,
        color = NotelSurfaceHigh.copy(alpha = 0.1f),
        shape = RoundedCornerShape(20.dp),
        border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(icon, fontSize = 24.sp)
            Spacer(Modifier.height(4.dp))
            Row(verticalAlignment = Alignment.Bottom) {
                Text(value, color = NotelTextPrimary, fontSize = 18.sp, fontWeight = FontWeight.Bold)
                if (subLabel != null) {
                    Spacer(Modifier.width(2.dp))
                    Text(subLabel, color = NotelTextSecondary, fontSize = 10.sp, modifier = Modifier.padding(bottom = 2.dp))
                }
            }
            Text(label, color = NotelTextSecondary, fontSize = 11.sp)
        }
    }
}

@Composable
private fun CategoryChipSmall(category: Category, isSelected: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        modifier = Modifier
            .animateContentSize()
            .clip(RoundedCornerShape(12.dp))
            .background(if (isSelected) NotelPrimary else NotelSurfaceHigh.copy(alpha = 0.2f))
            .border(
                width = 1.dp,
                color = if (isSelected) Color.Transparent else Color.White.copy(alpha = 0.05f),
                shape = RoundedCornerShape(12.dp)
            ),
        color = Color.Transparent
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.Center
        ) {
            Text(
                category.name,
                color = if (isSelected) Color.White else NotelTextSecondary,
                fontSize = 12.sp,
                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium
            )
        }
    }
}
