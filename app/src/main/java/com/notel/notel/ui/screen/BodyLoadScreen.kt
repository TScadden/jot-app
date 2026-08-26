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
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
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
import com.notel.notel.ui.viewmodel.ReminderViewModel
import com.notel.notel.ui.viewmodel.NotesViewModel
import com.notel.notel.ui.viewmodel.ListsViewModel
import com.notel.notel.data.local.entity.UserListItem
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.ui.viewmodel.EventCounterDto
import com.notel.notel.data.local.entity.Category
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun BodyLoadScreen(
    viewModel: BodyLoadViewModel = hiltViewModel(),
    onBack: () -> Unit,
    onNavigateToConnections: () -> Unit = {},
    onNavigateToMembership: () -> Unit = {},
    onNavigateToHeart: () -> Unit = {},
    onNavigateToHabits: () -> Unit = {},
    onNavigateToReminders: () -> Unit = {},
    onNavigateToLists: () -> Unit = {},
    onNavigateToNotes: () -> Unit = {},
    onNavigateToProjectFocus: () -> Unit = {},
    quickLogViewModel: QuickLogViewModel = hiltViewModel(),
    habitViewModel: HabitViewModel = hiltViewModel(),
    reminderViewModel: ReminderViewModel = hiltViewModel(),
    notesViewModel: NotesViewModel = hiltViewModel(),
    listsViewModel: ListsViewModel = hiltViewModel(),
    todayViewModel: com.notel.notel.ui.viewmodel.TodayViewModel = hiltViewModel()
) {
    val state by viewModel.uiState.collectAsState()
    val quickLogState by quickLogViewModel.uiState.collectAsState()
    val todayState by todayViewModel.uiState.collectAsState()
    val habits by habitViewModel.habits.collectAsState()
    val reminders by reminderViewModel.reminders.collectAsState()
    val notes: List<com.notel.notel.data.local.entity.UserListItem> by notesViewModel.notes.collectAsState()
    val lists: List<com.notel.notel.data.local.entity.UserList> by listsViewModel.lists.collectAsState()

    val coroutineScope = rememberCoroutineScope()

    // Refresh data on entry (respects 1-hour auto-limit unless forced)
    LaunchedEffect(Unit) {
        viewModel.refresh(force = false)
    }

    // Day Rollover / Auto-Refresh detector
    LaunchedEffect(Unit) {
        var lastCheckedToday = java.time.LocalDate.now().toString()
        while (true) {
            val currentToday = java.time.LocalDate.now().toString()
            if (currentToday != lastCheckedToday) {
                lastCheckedToday = currentToday
                viewModel.selectDay(currentToday)
                viewModel.refresh(force = true)
            }
            kotlinx.coroutines.delay(10000) // check every 10 seconds for snappy rollovers
        }
    }

    // Auto-fetch suggestions if category is selected and auto is on
    LaunchedEffect(quickLogState.selectedCategory, quickLogState.autoAiSuggestions, quickLogState.isUnlimited) {
        if (quickLogState.isUnlimited && quickLogState.autoAiSuggestions && quickLogState.selectedCategory != null && quickLogState.chips.isEmpty()) {
            quickLogViewModel.fetchSuggestions()
        }
    }

    val sheetState = rememberModalBottomSheetState()
    var showTheorySheet by remember { mutableStateOf(false) }
    var showWeatherSheet by remember { mutableStateOf(false) }
    var showUvInfo by remember { mutableStateOf(false) }
    var showTempInfo by remember { mutableStateOf(false) }
    var showHumidityInfo by remember { mutableStateOf(false) }
    var showWindInfo by remember { mutableStateOf(false) }
    var showPressureInfo by remember { mutableStateOf(false) }
    var showTodayCustomization by remember { mutableStateOf(false) }
    val todayStr = java.time.LocalDate.now().toString()
    val isToday = state.selectedDate == todayStr

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = "Today",
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
                    IconButton(onClick = { showTodayCustomization = true }) {
                        Icon(
                            imageVector = Icons.Default.Tune,
                            contentDescription = "Customize Today",
                            tint = NotelTextSecondary,
                            modifier = Modifier.size(22.dp)
                        )
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
            // ── 1. Today Summary Section ─────────────────────────────────────
            item {
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    color = NotelSurface,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, GlassBorder)
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = Icons.Default.Today,
                                contentDescription = null,
                                tint = NotelPrimary,
                                modifier = Modifier.size(20.dp)
                            )
                            Spacer(Modifier.width(8.dp))
                            Text(
                                text = "Today's Summary",
                                fontWeight = FontWeight.Bold,
                                color = NotelTextPrimary,
                                fontSize = 16.sp
                            )
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            text = todayState.summaryText,
                            color = NotelTextSecondary,
                            fontSize = 14.sp
                        )
                    }
                }
            }



            // ── 3. Today's Plan Section ─────────────────────────────────────
            if (todayState.todayPlanItems.isNotEmpty()) {
                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp)
                    ) {
                        Text(
                            text = "Today's Plan",
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary,
                            fontSize = 15.sp,
                            modifier = Modifier.padding(bottom = 8.dp)
                        )
                        todayState.todayPlanItems.forEach { planItem ->
                            val alpha = if (planItem.isCompleted) 0.5f else 1.0f
                            Surface(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 3.dp),
                                color = NotelSurface.copy(alpha = alpha),
                                shape = RoundedCornerShape(10.dp)
                            ) {
                                Row(
                                    modifier = Modifier.padding(10.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(
                                        imageVector = if (planItem.isCompleted) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                                        contentDescription = null,
                                        tint = if (planItem.isCompleted) NotelPrimary else NotelTextSecondary,
                                        modifier = Modifier.size(18.dp)
                                    )
                                    Spacer(Modifier.width(10.dp))
                                    Text(
                                        text = planItem.title,
                                        fontWeight = if (planItem.isCompleted) FontWeight.Normal else FontWeight.Medium,
                                        color = NotelTextPrimary.copy(alpha = alpha),
                                        fontSize = 13.sp,
                                        textDecoration = if (planItem.isCompleted) TextDecoration.LineThrough else TextDecoration.None,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Text(
                                        text = planItem.timeDisplay,
                                        color = NotelTextSecondary.copy(alpha = alpha),
                                        fontSize = 12.sp
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // ── 3B. What Changed Section (Health Comparisons) ───────────────
            if (!todayState.hiddenSections.contains("WHAT_CHANGED") && todayState.whatChangedItems.isNotEmpty()) {
                item {
                    Column(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp)
                    ) {
                        Text(
                            text = "What Changed",
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary,
                            fontSize = 15.sp,
                            modifier = Modifier.padding(bottom = 8.dp)
                        )
                        todayState.whatChangedItems.forEach { comp ->
                            Surface(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(vertical = 4.dp),
                                color = NotelSurface,
                                shape = RoundedCornerShape(12.dp),
                                border = BorderStroke(1.dp, GlassBorder)
                            ) {
                                Column(modifier = Modifier.padding(12.dp)) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalArrangement = Arrangement.SpaceBetween,
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Text(comp.metricName, fontWeight = FontWeight.Bold, fontSize = 14.sp, color = NotelTextPrimary)
                                        Text(comp.dataSource, fontSize = 11.sp, color = NotelTextSecondary)
                                    }
                                    Spacer(Modifier.height(4.dp))
                                    Text(comp.differenceText, fontSize = 13.sp, color = NotelPrimary, fontWeight = FontWeight.SemiBold)
                                    Spacer(Modifier.height(2.dp))
                                    Text("${comp.currentPeriod} vs ${comp.comparisonPeriod}", fontSize = 12.sp, color = NotelTextSecondary)
                                }
                            }
                        }
                    }
                }
            }

            // ── 3C. Active AI Insight Section ──────────────────────────────
            if (!todayState.hiddenSections.contains("AI_INSIGHT") && todayState.primaryInsight != null) {
                val insight = todayState.primaryInsight!!
                item {
                    Surface(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        color = NotelSurface,
                        shape = RoundedCornerShape(14.dp),
                        border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.3f))
                    ) {
                        Column(modifier = Modifier.padding(14.dp)) {
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Surface(
                                    color = NotelPrimary.copy(alpha = 0.15f),
                                    shape = RoundedCornerShape(6.dp)
                                ) {
                                    Text(
                                        text = insight.classification,
                                        modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                                        color = NotelPrimary,
                                        fontSize = 10.sp,
                                        fontWeight = FontWeight.Bold
                                    )
                                }
                                IconButton(
                                    onClick = { todayViewModel.dismissInsight(insight.id) },
                                    modifier = Modifier.size(24.dp)
                                ) {
                                    Icon(Icons.Default.Close, contentDescription = "Dismiss Insight", tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                                }
                            }
                            Spacer(Modifier.height(8.dp))
                            Text(text = insight.text, fontWeight = FontWeight.Medium, fontSize = 14.sp, color = NotelTextPrimary)
                            Spacer(Modifier.height(6.dp))
                            Text(text = "Based on: ${insight.dataUsed} (${insight.dateRangeText})", fontSize = 12.sp, color = NotelTextSecondary)
                            Spacer(Modifier.height(4.dp))
                            Text(text = insight.plainLanguageReason, fontSize = 12.sp, color = NotelTextSecondary.copy(alpha = 0.8f))
                            Spacer(Modifier.height(10.dp))
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(text = "Confidence: ${(insight.confidence * 100).toInt()}%", fontSize = 11.sp, color = NotelTextSecondary)
                                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                    FilterChip(
                                        selected = insight.feedbackState == "HELPFUL",
                                        onClick = { todayViewModel.submitInsightFeedback(insight.id, true) },
                                        label = { Text("Helpful", fontSize = 11.sp) }
                                    )
                                    FilterChip(
                                        selected = insight.feedbackState == "NOT_HELPFUL",
                                        onClick = { todayViewModel.submitInsightFeedback(insight.id, false) },
                                        label = { Text("Not Helpful", fontSize = 11.sp) }
                                    )
                                }
                            }
                        }
                    }
                }
            }

            // ── 4. Quick Actions Section ────────────────────────────────────
            item {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    Surface(
                        onClick = { quickLogViewModel.saveEntry() },
                        modifier = Modifier.weight(1f),
                        color = NotelPrimary.copy(alpha = 0.15f),
                        shape = RoundedCornerShape(12.dp),
                        border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.4f))
                    ) {
                        Row(
                            modifier = Modifier.padding(vertical = 10.dp, horizontal = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center
                        ) {
                            Icon(Icons.Default.Add, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Log Entry", fontSize = 12.sp, color = NotelPrimary, fontWeight = FontWeight.Bold)
                        }
                    }

                    Surface(
                        onClick = {
                            val last = quickLogState.recentSuggestions.firstOrNull()
                            if (last != null) quickLogViewModel.logFromRecent(last)
                        },
                        modifier = Modifier.weight(1f),
                        color = NotelSurface,
                        shape = RoundedCornerShape(12.dp),
                        border = BorderStroke(1.dp, GlassBorder)
                    ) {
                        Row(
                            modifier = Modifier.padding(vertical = 10.dp, horizontal = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center
                        ) {
                            Icon(Icons.Default.Repeat, contentDescription = null, tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Repeat Last", fontSize = 12.sp, color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                        }
                    }

                    Surface(
                        onClick = { },
                        modifier = Modifier.weight(1f),
                        color = NotelSurface,
                        shape = RoundedCornerShape(12.dp),
                        border = BorderStroke(1.dp, GlassBorder)
                    ) {
                        Row(
                            modifier = Modifier.padding(vertical = 10.dp, horizontal = 8.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.Center
                        ) {
                            Icon(Icons.Default.Bookmark, contentDescription = null, tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Templates", fontSize = 12.sp, color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                        }
                    }
                }
            }

            item {
                BodyLoadCard(
                    state = state,
                    counters = quickLogState.eventCounters,
                    onDaySelected = { viewModel.selectDay(it) },
                    onDayDoubleClicked = { viewModel.selectDayAndForceRefresh(it) },
                    onFactorSelected = { factor ->
                        if (factor == "Heart") onNavigateToHeart()
                        else viewModel.selectFactor(factor)
                    },
                    onResetSelection = { viewModel.selectFactor(null) },
                    onShowTheory = { 
                        viewModel.markTheorySeen()
                        showTheorySheet = true 
                    },
                    onRefresh = { viewModel.refresh(force = true) },
                    onBackToToday = { viewModel.selectDay(todayStr) },
                    onLocationUpdate = { lat, lon, city ->
                        viewModel.updateLocation(lat, lon, city)
                    }
                )
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
                        !quickLogState.isUnlimited -> Column(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text("You do not have a membership", color = NotelTextSecondary, fontSize = 12.sp)
                            Spacer(Modifier.height(8.dp))
                            TextButton(onClick = onNavigateToMembership) {
                                Text("Go to Settings to start Free Trial", color = NotelTextSecondary.copy(alpha = 0.5f), fontWeight = FontWeight.Bold)
                            }
                        }
                        quickLogState.isLoadingChips -> Box(Modifier.fillMaxWidth().padding(vertical = 32.dp), contentAlignment = Alignment.Center) {
                            CircularProgressIndicator(color = NotelPrimary, modifier = Modifier.size(24.dp))
                        }
                        quickLogState.chipsError != null -> Column(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text(quickLogState.chipsError!!, color = MaterialTheme.colorScheme.error, fontSize = 13.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                            Spacer(Modifier.height(12.dp))
                            TextButton(onClick = { quickLogViewModel.fetchSuggestions(forceRefresh = true) }) {
                                Text("Retry", color = NotelPrimary, fontWeight = FontWeight.Bold)
                            }
                        }
                        quickLogState.isOffline && quickLogState.chips.isEmpty() -> {
                            Column(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text("Connection Error: You are offline.", color = MaterialTheme.colorScheme.error, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                Spacer(Modifier.height(4.dp))
                                Text("Load Suggestions is unavailable.", color = NotelTextSecondary, fontSize = 11.sp)
                                Spacer(Modifier.height(12.dp))
                                TextButton(onClick = { quickLogViewModel.fetchSuggestions(forceRefresh = true) }) {
                                    Text("Retry Connection", color = NotelPrimary, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                        quickLogState.chips.isEmpty() -> {
                            Column(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text("No suggestions loaded", color = NotelTextSecondary, fontSize = 12.sp)
                                Spacer(Modifier.height(8.dp))
                                TextButton(onClick = { quickLogViewModel.fetchSuggestions(forceRefresh = true) }) {
                                    Text("Load Suggestions", color = NotelPrimary, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                        else -> {
                            val activeCatColor = remember(quickLogState.selectedCategory) {
                                quickLogState.selectedCategory?.let { cat ->
                                    try { Color(android.graphics.Color.parseColor(cat.colorHex)) } catch (e: Exception) { NotelPrimary }
                                } ?: NotelPrimary
                            }
                            Column {
                                FlowRow(
                                    modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                                    horizontalArrangement = Arrangement.spacedBy(10.dp),
                                    verticalArrangement = Arrangement.spacedBy(10.dp),
                                    maxItemsInEachRow = 2
                                ) {
                                    quickLogState.chips.forEach { chip ->
                                        val isSelected = chip in quickLogState.selectedChips
                                        val chipBg = if (isSelected) activeCatColor else NotelSurface
                                        val chipBorder = if (isSelected) activeCatColor else activeCatColor.copy(alpha = 0.25f)
                                        Surface(
                                            onClick = { quickLogViewModel.toggleChip(chip) },
                                            modifier = Modifier
                                                .weight(1f)
                                                .animateContentSize()
                                                .clip(RoundedCornerShape(14.dp))
                                                .background(chipBg)
                                                .border(
                                                    width = 1.dp,
                                                    color = chipBorder,
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
                var isRoutineExpanded by remember { mutableStateOf(false) }
                val context = androidx.compose.ui.platform.LocalContext.current
                val prefs = remember { com.notel.notel.data.preferences.NotelPreferences(context) }
                val savedOrderJson by prefs.infoTileOrder.collectAsState(initial = "")

                val sortedRoutineTabs = remember(savedOrderJson) {
                    val allRoutineKeys = listOf("habits", "reminders", "lists", "notes", "project_focus")
                    if (savedOrderJson.isNotBlank()) {
                        val parsedIds = try {
                            kotlinx.serialization.json.Json.decodeFromString<List<String>>(savedOrderJson)
                        } catch (e: Exception) {
                            emptyList()
                        }
                        val userOrdered = parsedIds.filter { it in allRoutineKeys }
                        val missing = allRoutineKeys.filter { it !in userOrdered }
                        (userOrdered + missing).take(4)
                    } else {
                        listOf("habits", "project_focus")
                    }
                }

                Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 24.dp)) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clip(RoundedCornerShape(12.dp))
                            .clickable { isRoutineExpanded = !isRoutineExpanded }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "Daily Routine",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.Bold,
                                color = NotelTextPrimary
                            )
                            }
                            Spacer(Modifier.height(2.dp))
                            Text(
                                "Manage your habits, reminders, lists, notes & project experiments.",
                                color = NotelTextSecondary,
                                fontSize = 12.sp
                            )
                        }
                        IconButton(onClick = { isRoutineExpanded = !isRoutineExpanded }) {
                            Icon(
                                imageVector = if (isRoutineExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                                contentDescription = if (isRoutineExpanded) "Collapse Daily Routine" else "Expand Daily Routine",
                                tint = NotelPrimary,
                                modifier = Modifier.size(28.dp)
                            )
                        }
                    }

                    AnimatedVisibility(
                        visible = isRoutineExpanded,
                        enter = fadeIn() + expandVertically(),
                        exit = fadeOut() + shrinkVertically()
                    ) {
                        Column {
                            Spacer(Modifier.height(12.dp))

                            sortedRoutineTabs.forEach { tabKey ->
                                when (tabKey) {
                                    "habits" -> {
                                        // ── Habits Tile ───────────────────────────────────
                                        val checkedCount = habits.count { habitViewModel.isCheckedToday(it) }
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .height(76.dp)
                                                .border(
                                                    width = 3.dp,
                                                    color = NotelPrimary.copy(alpha = 0.12f),
                                                    shape = RoundedCornerShape(22.dp)
                                                )
                                                .border(
                                                    width = 6.dp,
                                                    color = NotelPrimary.copy(alpha = 0.04f),
                                                    shape = RoundedCornerShape(24.dp)
                                                )
                                                .liquidGlass(
                                                    shape = RoundedCornerShape(20.dp),
                                                    color = NotelSurface,
                                                    alpha = 0.8f,
                                                    showBorder = true
                                                )
                                                .clickable { onNavigateToHabits() }
                                                .padding(horizontal = 20.dp, vertical = 12.dp)
                                        ) {
                                            Row(
                                                modifier = Modifier.fillMaxSize(),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.Start
                                            ) {
                                                Icon(
                                                    imageVector = Icons.Default.CheckCircle,
                                                    contentDescription = null,
                                                    tint = NotelPrimary,
                                                    modifier = Modifier.size(28.dp)
                                                )
                                                Spacer(Modifier.width(14.dp))
                                                Column {
                                                    Text(
                                                        text = "Habits",
                                                        color = NotelTextPrimary,
                                                        fontSize = 16.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                    Text(
                                                        text = if (habits.isEmpty()) "No habits yet"
                                                               else "$checkedCount/${habits.size} done today",
                                                        color = NotelTextSecondary,
                                                        fontSize = 11.sp,
                                                        fontWeight = FontWeight.Medium
                                                    )
                                                }
                                            }
                                        }
                                        Spacer(Modifier.height(12.dp))
                                    }

                                    "reminders" -> {
                                        // ── Reminders Tile ──────────────────────
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .height(76.dp)
                                                .border(
                                                    width = 3.dp,
                                                    color = NotelPrimary.copy(alpha = 0.12f),
                                                    shape = RoundedCornerShape(22.dp)
                                                )
                                                .border(
                                                    width = 6.dp,
                                                    color = NotelPrimary.copy(alpha = 0.04f),
                                                    shape = RoundedCornerShape(24.dp)
                                                )
                                                .liquidGlass(
                                                    shape = RoundedCornerShape(20.dp),
                                                    color = NotelSurface,
                                                    alpha = 0.8f,
                                                    showBorder = true
                                                )
                                                .clickable { onNavigateToReminders() }
                                                .padding(horizontal = 20.dp, vertical = 12.dp)
                                        ) {
                                            Row(
                                                modifier = Modifier.fillMaxSize(),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.Start
                                            ) {
                                                Icon(
                                                    imageVector = Icons.Default.Notifications,
                                                    contentDescription = null,
                                                    tint = NotelPrimary,
                                                    modifier = Modifier.size(28.dp)
                                                )
                                                Spacer(Modifier.width(14.dp))
                                                Column {
                                                    Text(
                                                        text = "Reminders",
                                                        color = NotelTextPrimary,
                                                        fontSize = 16.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                    Text(
                                                        text = if (reminders.isEmpty()) "No reminders yet" 
                                                               else "${reminders.size} Reminders",
                                                        color = NotelTextSecondary,
                                                        fontSize = 11.sp,
                                                        fontWeight = FontWeight.Medium
                                                    )
                                                }
                                            }
                                        }
                                        Spacer(Modifier.height(12.dp))
                                    }

                                    "lists" -> {
                                        // ── Lists Tile ───────────────────────────────────────────────
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .height(76.dp)
                                                .border(
                                                    width = 3.dp,
                                                    color = NotelPrimary.copy(alpha = 0.12f),
                                                    shape = RoundedCornerShape(22.dp)
                                                )
                                                .border(
                                                    width = 6.dp,
                                                    color = NotelPrimary.copy(alpha = 0.04f),
                                                    shape = RoundedCornerShape(24.dp)
                                                )
                                                .liquidGlass(
                                                    shape = RoundedCornerShape(20.dp),
                                                    color = NotelSurface,
                                                    alpha = 0.8f,
                                                    showBorder = true
                                                )
                                                .clickable { onNavigateToLists() }
                                                .padding(horizontal = 20.dp, vertical = 12.dp)
                                        ) {
                                            Row(
                                                modifier = Modifier.fillMaxSize(),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.Start
                                            ) {
                                                Icon(
                                                    imageVector = Icons.Default.List,
                                                    contentDescription = null,
                                                    tint = NotelPrimary,
                                                    modifier = Modifier.size(28.dp)
                                                )
                                                Spacer(Modifier.width(14.dp))
                                                Column {
                                                    Text(
                                                        text = "Lists",
                                                        color = NotelTextPrimary,
                                                        fontSize = 16.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                    val userLists = lists.filter { list -> list.name != "__user_notes__" }
                                                    Text(
                                                        text = if (userLists.isEmpty()) "No lists yet"
                                                               else "${userLists.size} ${if (userLists.size == 1) "List" else "Lists"}",
                                                        color = NotelTextSecondary,
                                                        fontSize = 11.sp,
                                                        fontWeight = FontWeight.Medium
                                                    )
                                                }
                                            }
                                        }
                                        Spacer(Modifier.height(12.dp))
                                    }

                                    "notes" -> {
                                        // ── Notes Tile ───────────────────────────────────────────────
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .height(76.dp)
                                                .border(
                                                    width = 3.dp,
                                                    color = NotelPrimary.copy(alpha = 0.12f),
                                                    shape = RoundedCornerShape(22.dp)
                                                )
                                                .border(
                                                    width = 6.dp,
                                                    color = NotelPrimary.copy(alpha = 0.04f),
                                                    shape = RoundedCornerShape(24.dp)
                                                )
                                                .liquidGlass(
                                                    shape = RoundedCornerShape(20.dp),
                                                    color = NotelSurface,
                                                    alpha = 0.8f,
                                                    showBorder = true
                                                )
                                                .clickable { onNavigateToNotes() }
                                                .padding(horizontal = 20.dp, vertical = 12.dp)
                                        ) {
                                            Row(
                                                modifier = Modifier.fillMaxSize(),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.Start
                                            ) {
                                                Icon(
                                                    imageVector = androidx.compose.material.icons.Icons.Default.Edit,
                                                    contentDescription = null,
                                                    tint = NotelPrimary,
                                                    modifier = Modifier.size(28.dp)
                                                )
                                                Spacer(Modifier.width(14.dp))
                                                Column {
                                                    Text(
                                                        text = "Notes",
                                                        color = NotelTextPrimary,
                                                        fontSize = 16.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                    Text(
                                                        text = if (notes.isEmpty()) "No notes yet"
                                                               else "${notes.size} ${if (notes.size == 1) "Note" else "Notes"}",
                                                        color = NotelTextSecondary,
                                                        fontSize = 11.sp,
                                                        fontWeight = FontWeight.Medium
                                                    )
                                                }
                                            }
                                        }
                                        Spacer(Modifier.height(12.dp))
                                    }

                                    "project_focus" -> {
                                        // ── Project Focus Tile ────────────────────────────────────
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .height(76.dp)
                                                .border(
                                                    width = 3.dp,
                                                    color = NotelPrimary.copy(alpha = 0.12f),
                                                    shape = RoundedCornerShape(22.dp)
                                                )
                                                .border(
                                                    width = 6.dp,
                                                    color = NotelPrimary.copy(alpha = 0.04f),
                                                    shape = RoundedCornerShape(24.dp)
                                                )
                                                .liquidGlass(
                                                    shape = RoundedCornerShape(20.dp),
                                                    color = NotelSurface,
                                                    alpha = 0.8f,
                                                    showBorder = true
                                                )
                                                .clickable { onNavigateToProjectFocus() }
                                                .padding(horizontal = 20.dp, vertical = 12.dp)
                                        ) {
                                            Row(
                                                modifier = Modifier.fillMaxSize(),
                                                verticalAlignment = Alignment.CenterVertically,
                                                horizontalArrangement = Arrangement.Start
                                            ) {
                                                Icon(
                                                    imageVector = Icons.Default.Science,
                                                    contentDescription = null,
                                                    tint = NotelPrimary,
                                                    modifier = Modifier.size(28.dp)
                                                )
                                                Spacer(Modifier.width(14.dp))
                                                Column {
                                                    Text(
                                                        text = "Project Focus",
                                                        color = NotelTextPrimary,
                                                        fontSize = 16.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                    Text(
                                                        text = "Track your experiments",
                                                        color = NotelTextSecondary,
                                                        fontSize = 11.sp,
                                                        fontWeight = FontWeight.Medium
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
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
                    .verticalScroll(rememberScrollState())
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
                    text = "Think of your body's capacity as a 'Cup'. Every stressor—poor sleep, elevated heart rate, physical exertion, or subjective strain—adds 'water' to that cup.\n\n" +
                           "Your Body Load score (0-100) represents how much of your cup is currently full:\n\n" +
                           "• LOW (15-40): High Resilience. Your cup is mostly empty; you have plenty of room for activity.\n" +
                           "• MODERATE (41-65): Managing Load. You have used a fair amount of your daily capacity.\n" +
                           "• HIGH (66-90+): High Strain. Your cup is nearly full. Even small drops (stressors) could cause an 'overflow' (a flare or crash).\n\n" +
                           "To give you an accurate forecast, **each day's score is computed statically from yesterday's total metrics**, letting you see exactly how yesterday's exertion and sleep impact your body today.\n\n" +
                           "Your score is weighted dynamically using key biomarker markers (scaled when Tabs are logged):\n" +
                           "• Subjective Tabs: 40% (if present; 0% otherwise)\n" +
                           "• Sleep: 30% (if Tabs present; 40% otherwise)\n" +
                           "• Heart Rate: 20% (if Tabs present; 40% otherwise)\n" +
                           "• Active Calories: 10% (if Tabs present; 20% otherwise)",
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
                    .padding(horizontal = 24.dp)
                    .padding(bottom = 64.dp),
                horizontalAlignment = Alignment.CenterHorizontally
            ) {
                val weather = state.weather
                if (weather != null) {
                    Text(
                        text = weather.locationName.uppercase(),
                        color = NotelTextPrimary,
                        fontSize = 18.sp,
                        fontWeight = FontWeight.Black,
                        letterSpacing = 1.5.sp
                    )
                    Spacer(Modifier.height(4.dp))
                    Text(
                        text = weather.condition,
                        color = NotelTextSecondary,
                        fontSize = 13.sp
                    )
                    
                    Spacer(Modifier.height(24.dp))
                    
                    GlassyCard(
                        shape = RoundedCornerShape(20.dp),
                        color = NotelSurfaceHigh.copy(alpha = 0.3f),
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column {
                            // Row 1: Temperature
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { showTempInfo = true }
                                    .padding(vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text(weather.icon, fontSize = 24.sp)
                                Spacer(Modifier.width(16.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("Temperature", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 14.sp)
                                    Text("Tap to see optimal temperature ranges", color = NotelTextSecondary, fontSize = 11.sp)
                                }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        text = "${weather.temp}°${weather.unit}",
                                        color = NotelTextPrimary,
                                        fontSize = 15.sp,
                                        fontWeight = FontWeight.Bold
                                    )
                                    Spacer(Modifier.width(4.dp))
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                        contentDescription = null,
                                        tint = NotelTextSecondary.copy(alpha = 0.6f),
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                            }
                            HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.4f), thickness = 0.5.dp)

                            // Row 2: Humidity
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { showHumidityInfo = true }
                                    .padding(vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("💧", fontSize = 24.sp)
                                Spacer(Modifier.width(16.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("Humidity", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 14.sp)
                                    Text("Tap to see comfort levels & hydration guidance", color = NotelTextSecondary, fontSize = 11.sp)
                                }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        text = "${weather.humidity}%",
                                        color = NotelTextPrimary,
                                        fontSize = 15.sp,
                                        fontWeight = FontWeight.Bold
                                    )
                                    Spacer(Modifier.width(4.dp))
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                        contentDescription = null,
                                        tint = NotelTextSecondary.copy(alpha = 0.6f),
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                            }
                            HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.4f), thickness = 0.5.dp)

                            // Row 3: Wind Velocity
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { showWindInfo = true }
                                    .padding(vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("💨", fontSize = 24.sp)
                                Spacer(Modifier.width(16.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("Wind Velocity", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 14.sp)
                                    Text("Tap to see wind chill & training impact", color = NotelTextSecondary, fontSize = 11.sp)
                                }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Row(verticalAlignment = Alignment.Bottom) {
                                        Text(
                                            text = String.format("%.1f", weather.windSpeed),
                                            color = NotelTextPrimary,
                                            fontSize = 15.sp,
                                            fontWeight = FontWeight.Bold
                                        )
                                        Spacer(Modifier.width(2.dp))
                                        Text(
                                            text = if (weather.unit == "F") "mph" else "km/h",
                                            color = NotelTextSecondary,
                                            fontSize = 11.sp,
                                            modifier = Modifier.padding(bottom = 1.dp)
                                        )
                                    }
                                    Spacer(Modifier.width(4.dp))
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                        contentDescription = null,
                                        tint = NotelTextSecondary.copy(alpha = 0.6f),
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                            }
                            HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.4f), thickness = 0.5.dp)

                            // Row 4: UV Index (clickable)
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { showUvInfo = true }
                                    .padding(vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("☀️", fontSize = 24.sp, color = if (weather.uvIndex > 5) NotelAccent else NotelTextPrimary)
                                Spacer(Modifier.width(16.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(
                                            text = "UV Index",
                                            color = if (weather.uvIndex > 5) NotelAccent else NotelTextPrimary,
                                            fontWeight = FontWeight.Medium,
                                            fontSize = 14.sp
                                        )
                                        if (weather.uvIndex > 5) {
                                            Spacer(Modifier.width(8.dp))
                                            Surface(
                                                color = NotelAccent.copy(alpha = 0.15f),
                                                shape = RoundedCornerShape(4.dp)
                                            ) {
                                                Text(
                                                    text = "HIGH RISK",
                                                    color = NotelAccent,
                                                    fontSize = 8.sp,
                                                    fontWeight = FontWeight.Black,
                                                    modifier = Modifier.padding(horizontal = 4.dp, vertical = 2.dp)
                                                )
                                            }
                                        }
                                    }
                                    Text("Tap to see safe exposure times", color = NotelTextSecondary, fontSize = 11.sp)
                                }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text(
                                        text = String.format("%.1f", weather.uvIndex),
                                        color = if (weather.uvIndex > 5) NotelAccent else NotelTextPrimary,
                                        fontSize = 15.sp,
                                        fontWeight = FontWeight.Bold
                                    )
                                    Spacer(Modifier.width(4.dp))
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                        contentDescription = null,
                                        tint = NotelTextSecondary.copy(alpha = 0.6f),
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                            }
                            HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.4f), thickness = 0.5.dp)

                            // Row 5: Pressure
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { showPressureInfo = true }
                                    .padding(vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("⏲️", fontSize = 24.sp)
                                Spacer(Modifier.width(16.dp))
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("Barometric Pressure", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 14.sp)
                                    Text("Tap to see joint pain & migraine triggers", color = NotelTextSecondary, fontSize = 11.sp)
                                }
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Row(verticalAlignment = Alignment.Bottom) {
                                        Text(
                                            text = String.format("%.0f", weather.pressure),
                                            color = NotelTextPrimary,
                                            fontSize = 15.sp,
                                            fontWeight = FontWeight.Bold
                                        )
                                        Spacer(Modifier.width(2.dp))
                                        Text(
                                            text = "hPa",
                                            color = NotelTextSecondary,
                                            fontSize = 11.sp,
                                            modifier = Modifier.padding(bottom = 1.dp)
                                        )
                                    }
                                    Spacer(Modifier.width(4.dp))
                                    Icon(
                                        imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                        contentDescription = null,
                                        tint = NotelTextSecondary.copy(alpha = 0.6f),
                                        modifier = Modifier.size(16.dp)
                                    )
                                }
                            }
                        }
                    }
                    
                    if (weather.uvIndex > 5) {
                        Spacer(Modifier.height(20.dp))
                        Surface(
                            color = NotelAccent.copy(alpha = 0.1f),
                            shape = RoundedCornerShape(12.dp),
                            border = BorderStroke(1.dp, NotelAccent.copy(alpha = 0.3f)),
                            modifier = Modifier.fillMaxWidth()
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

    val tempSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    if (showTempInfo) {
        ModalBottomSheet(
            onDismissRequest = { showTempInfo = false },
            sheetState = tempSheetState,
            containerColor = NotelBackground,
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
                    text = "TEMPERATURE",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Black,
                    color = Color.White,
                    letterSpacing = 2.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                Surface(
                    color = NotelSurface,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("Ambient Temp & Sleep Recovery", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        Spacer(Modifier.height(12.dp))
                        Text(
                            text = "Ambient temperature strongly influences body load recovery. Sleep studies show that cooler rooms support deeper, higher-quality sleep.",
                            color = Color.White.copy(alpha = 0.7f),
                            fontSize = 14.sp,
                            lineHeight = 20.sp
                        )
                        Spacer(Modifier.height(16.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("❄️", fontSize = 18.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("Optimal Sleep Range", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("60°F - 67°F\n(15°C - 19°C)", color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, textAlign = TextAlign.End)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🏠", fontSize = 18.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("Comfortable Room Range", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("68°F - 72°F\n(20°C - 22°C)", color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, textAlign = TextAlign.End)
                        }
                    }
                }
                
                Spacer(Modifier.height(24.dp))
                
                Text("Why Temperature Matters", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "Extreme temperatures place additional strain on the cardiovascular system. In hot weather, the heart beats faster to pump blood to the skin for cooling. In freezing weather, blood vessels constrict to conserve core heat, raising blood pressure.\n\nWorking out in temperatures above 80°F (27°C) or below 32°F (0°C) elevates overall physiological strain, requiring slower pacing and adequate recovery times.",
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 14.sp,
                    lineHeight = 20.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                Surface(
                    color = Color(0xFF1A1C1E),
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color(0xFF4CAF50).copy(alpha = 0.2f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🏃", fontSize = 18.sp)
                            Spacer(Modifier.width(8.dp))
                            Text("Workout Performance Guidance", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "Avoid strenuous outdoor exertion during midday heat waves. Ensure you hydrate with both water and electrolytes to compensate for sweat loss and preserve heart rate variability (HRV).",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
            }
        }
    }

    val humiditySheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    if (showHumidityInfo) {
        ModalBottomSheet(
            onDismissRequest = { showHumidityInfo = false },
            sheetState = humiditySheetState,
            containerColor = NotelBackground,
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
                    text = "HUMIDITY",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Black,
                    color = Color.White,
                    letterSpacing = 2.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                Surface(
                    color = NotelSurface,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("Comfort and Health Ranges", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        Spacer(Modifier.height(12.dp))
                        Text(
                            text = "Relative humidity indicates the moisture levels in the air. Both very high and very low humidity can cause bodily strain.",
                            color = Color.White.copy(alpha = 0.7f),
                            fontSize = 14.sp,
                            lineHeight = 20.sp
                        )
                        Spacer(Modifier.height(16.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🟢", fontSize = 12.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("Optimal Humidity Zone", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("30% - 50%", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🔴", fontSize = 12.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("High Humidity (Sticky/Hot)", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("> 60%", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🔵", fontSize = 12.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("Low Humidity (Dry/Irritating)", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("< 30%", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                    }
                }
                
                Spacer(Modifier.height(24.dp))
                
                Text("How Humidity Affects Your Body", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "High humidity prevents sweat from evaporating efficiently. Because sweat cannot evaporate, your body cannot cool itself down, causing core temperature and heart rate to rise quickly.\n\nLow humidity (below 30%) dries out the mucous membranes in your nose and throat, compromising your immune system's first line of defense and making you more susceptible to viruses.",
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 14.sp,
                    lineHeight = 20.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                Surface(
                    color = Color(0xFF1A1C1E),
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color(0xFFFFB74D).copy(alpha = 0.2f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("💡", fontSize = 18.sp)
                            Spacer(Modifier.width(8.dp))
                            Text("Hydration & Air Quality Tips", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "In dry weather, consider using a humidifier in your bedroom. In high humidity, drink extra water, wear loose moisture-wicking clothing, and limit high-intensity workouts to ventilated indoor spaces.",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
            }
        }
    }

    val windSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    if (showWindInfo) {
        ModalBottomSheet(
            onDismissRequest = { showWindInfo = false },
            sheetState = windSheetState,
            containerColor = NotelBackground,
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
                    text = "WIND VELOCITY",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Black,
                    color = Color.White,
                    letterSpacing = 2.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                Surface(
                    color = NotelSurface,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("Wind Thresholds & Exertion Impact", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        Spacer(Modifier.height(12.dp))
                        Text(
                            text = "Wind velocity affects physical drag during outdoor workouts and convective heat loss (wind chill factor).",
                            color = Color.White.copy(alpha = 0.7f),
                            fontSize = 14.sp,
                            lineHeight = 20.sp
                        )
                        Spacer(Modifier.height(16.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🍃", fontSize = 18.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("Calm & Pleasant Range", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("< 12 mph\n(< 19 km/h)", color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, textAlign = TextAlign.End)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("💨", fontSize = 18.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("Resistant & Aerobic Strain", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("12 - 20 mph\n(19 - 32 km/h)", color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, textAlign = TextAlign.End)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("🌪️", fontSize = 18.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("High Wind Alert", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("> 20 mph\n(> 32 km/h)", color = Color.White.copy(alpha = 0.6f), fontSize = 12.sp, textAlign = TextAlign.End)
                        }
                    }
                }
                
                Spacer(Modifier.height(24.dp))
                
                Text("Wind Chill & Drag Forces", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "Convective heat loss increases with wind speed. In cold temperatures, strong winds strip away the thin boundary layer of warm air surrounding your skin, causing your body temperature to drop rapidly.\n\nFor cyclists and runners, headwind dramatically increases aerobic resistance. Sustained wind speeds above 15 mph can increase energy cost/heart rate by up to 20-30% to maintain the same pace, elevating training load.",
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 14.sp,
                    lineHeight = 20.sp
                )
            }
        }
    }

    val pressureSheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    if (showPressureInfo) {
        ModalBottomSheet(
            onDismissRequest = { showPressureInfo = false },
            sheetState = pressureSheetState,
            containerColor = NotelBackground,
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
                    text = "BAROMETRIC PRESSURE",
                    fontSize = 20.sp,
                    fontWeight = FontWeight.Black,
                    color = Color.White,
                    letterSpacing = 2.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                Surface(
                    color = NotelSurface,
                    shape = RoundedCornerShape(16.dp),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.05f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Text("Barometric Reference Ranges", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 16.sp)
                        Spacer(Modifier.height(12.dp))
                        Text(
                            text = "Barometric pressure measures the weight of the atmosphere. Rapid swings can trigger physical symptoms.",
                            color = Color.White.copy(alpha = 0.7f),
                            fontSize = 14.sp,
                            lineHeight = 20.sp
                        )
                        Spacer(Modifier.height(16.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("☀️", fontSize = 18.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("High/Stable Pressure", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("> 1020 hPa", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("⛅", fontSize = 18.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("Standard Sea Level", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("1013 hPa", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                        HorizontalDivider(Modifier.padding(vertical = 12.dp), color = Color.White.copy(alpha = 0.05f))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("⛈️", fontSize = 18.sp)
                            Spacer(Modifier.width(12.dp))
                            Text("Low/Stormy Pressure", color = Color.White.copy(alpha = 0.8f), fontSize = 14.sp, modifier = Modifier.weight(1f))
                            Text("< 1009 hPa", color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp)
                        }
                    }
                }
                
                Spacer(Modifier.height(24.dp))
                
                Text("How Atmospheric Pressure Impacts You", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 18.sp)
                Spacer(Modifier.height(12.dp))
                Text(
                    text = "A sudden drop in barometric pressure (often preceding stormy weather) allows joint tissues, tendons, and fluids to expand slightly. This expansion can cause aches in arthritic joints or old injuries.\n\nFurthermore, barometric drops affect blood flow and oxygen tension in tissues. The pressure difference between the atmosphere and your sinuses can cause sinus pressure, vascular headaches, and migraines.",
                    color = Color.White.copy(alpha = 0.6f),
                    fontSize = 14.sp,
                    lineHeight = 20.sp
                )
                
                Spacer(Modifier.height(24.dp))
                
                Surface(
                    color = Color(0xFF1A1C1E),
                    shape = RoundedCornerShape(12.dp),
                    border = BorderStroke(1.dp, Color(0xFFEF9A9A).copy(alpha = 0.2f))
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("⚠️", fontSize = 18.sp)
                            Spacer(Modifier.width(8.dp))
                            Text("Vulnerability Warning", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "If you notice a rapid drop in barometric pressure, stay hydrated, keep joint temperatures warm, and anticipate potential headaches by scheduling recovery-focused, low-strain activities.",
                            color = Color.White.copy(alpha = 0.5f),
                            fontSize = 12.sp,
                            lineHeight = 18.sp
                        )
                    }
                }
            }
        }
    }

    if (showTodayCustomization) {
        TodayCustomizationBottomSheet(
            viewModel = todayViewModel,
            onDismiss = { showTodayCustomization = false }
        )
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
    val catColor = remember(category) {
        try { Color(android.graphics.Color.parseColor(category.colorHex)) }
        catch (e: Exception) { NotelPrimary }
    }

    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(10.dp))
            .background(if (isSelected) catColor else NotelSurface)
            .border(
                width = 1.dp,
                color = if (isSelected) catColor else catColor.copy(alpha = 0.35f),
                shape = RoundedCornerShape(10.dp)
            )
            .clickable { onClick() }
            .padding(horizontal = 14.dp, vertical = 8.dp)
    ) {
        Text(
            text = category.name.uppercase(),
            color = if (isSelected) Color(0xFF0A0A0E) else NotelTextSecondary,
            fontSize = 11.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.8.sp
        )
    }
}
