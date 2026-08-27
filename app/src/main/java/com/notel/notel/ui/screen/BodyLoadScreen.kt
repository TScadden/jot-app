package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.animation.core.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import kotlinx.coroutines.flow.collectLatest
import androidx.compose.foundation.shape.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
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
import com.notel.notel.ui.viewmodel.TodayPlanItem
import com.notel.notel.ui.viewmodel.ActionStatus
import com.notel.notel.ui.viewmodel.TodayTrendsState
import com.notel.notel.ui.viewmodel.isOverdue
import com.notel.notel.data.local.entity.UserListItem
import com.notel.notel.data.local.entity.UserList
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.ui.viewmodel.EventCounterDto
import com.notel.notel.data.local.entity.Category
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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



    var showWeatherSheet by remember { mutableStateOf(false) }
    var showUvInfo by remember { mutableStateOf(false) }
    var showTempInfo by remember { mutableStateOf(false) }
    var showHumidityInfo by remember { mutableStateOf(false) }
    var showWindInfo by remember { mutableStateOf(false) }
    var showPressureInfo by remember { mutableStateOf(false) }
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
            // ── 1. Restored Black Health Metrics Box ─────────────────────────────
            item {
                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    shape = RoundedCornerShape(12.dp),
                    color = Color.Black.copy(alpha = 0.3f),
                    border = BorderStroke(1.dp, Color.White.copy(alpha = 0.1f))
                ) {
                    Box(modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 12.dp)) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceEvenly,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            // Heart Rate
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier.clickable { onNavigateToHeart() }
                            ) {
                                Icon(Icons.Default.Favorite, contentDescription = "Heart Rate", tint = NotelPrimary, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    text = if (state.avgHeartRate > 0) "${state.avgHeartRate}" else "--",
                                    color = Color.White,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }

                            Spacer(Modifier.width(2.dp))
                            VerticalDivider(modifier = Modifier.height(16.dp), color = Color.White.copy(alpha = 0.15f))
                            Spacer(Modifier.width(2.dp))

                            // Calories
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Whatshot, contentDescription = "Calories", tint = Color(0xFFFF5252), modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    text = if (state.activeCalories > 0) "${state.activeCalories}" else "--",
                                    color = Color.White,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }

                            Spacer(Modifier.width(2.dp))
                            VerticalDivider(modifier = Modifier.height(16.dp), color = Color.White.copy(alpha = 0.15f))
                            Spacer(Modifier.width(2.dp))

                            // Logs
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Edit, contentDescription = "Logs", tint = Color(0xFF66BB6A), modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    text = "${state.jotCountDaily}",
                                    color = Color.White,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }

                            Spacer(Modifier.width(2.dp))
                            VerticalDivider(modifier = Modifier.height(16.dp), color = Color.White.copy(alpha = 0.15f))
                            Spacer(Modifier.width(2.dp))

                            // Sleep
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Nightlight, contentDescription = "Sleep", tint = Color(0xFF42A5F5), modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(4.dp))
                                val sleepStr = if (state.sleepMinutes > 0) {
                                    val h = state.sleepMinutes / 60
                                    val m = state.sleepMinutes % 60
                                    if (h > 0) "${h}h${m}m" else "${m}m"
                                } else "--"
                                Text(
                                    text = sleepStr,
                                    color = Color.White,
                                    fontSize = 14.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }
                    }
                }
            }

            // ── 2. Compact Streak Boxes & Rotating Event Counters Row ─────────────────────
            item {
                val activeCounters = quickLogState.eventCounters.filter { !it.isArchived }
                val infinitePageCount = if (activeCounters.size > 1) 10000 else activeCounters.size
                val pagerState = rememberPagerState(
                    initialPage = if (activeCounters.size > 1) 5000 else 0,
                    pageCount = { infinitePageCount }
                )

                if (activeCounters.size > 1) {
                    LaunchedEffect(activeCounters.size) {
                        snapshotFlow { pagerState.settledPage }.collectLatest { settledIndex ->
                            kotlinx.coroutines.delay(10000)
                            pagerState.animateScrollToPage(settledIndex + 1)
                        }
                    }
                }

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    // Left: Streak Boxes (Current Streak & Best/Record Streak)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        // Current Streak Box
                        Surface(
                            modifier = Modifier.height(34.dp),
                            shape = RoundedCornerShape(8.dp),
                            color = NotelSurfaceHigh.copy(alpha = 0.15f),
                            border = BorderStroke(1.dp, Color.White.copy(alpha = 0.08f))
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("🔥", fontSize = 12.sp)
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    text = "${state.currentStreak}",
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = Color(0xFFFFB74D)
                                )
                            }
                        }

                        // Best Streak (Record) Box
                        Surface(
                            modifier = Modifier.height(34.dp),
                            shape = RoundedCornerShape(8.dp),
                            color = NotelSurfaceHigh.copy(alpha = 0.15f),
                            border = BorderStroke(1.dp, Color.White.copy(alpha = 0.08f))
                        ) {
                            Row(
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 6.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("🏆", fontSize = 12.sp)
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    text = "${state.bestStreak}",
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold,
                                    color = Color(0xFFFFD700)
                                )
                            }
                        }
                    }

                    // Right: Event Counters Rotating Pager
                    if (activeCounters.isNotEmpty()) {
                        Column(
                            modifier = Modifier
                                .weight(1f)
                                .padding(start = 12.dp),
                            horizontalAlignment = Alignment.End
                        ) {
                            HorizontalPager(
                                state = pagerState,
                                modifier = Modifier.fillMaxWidth(),
                                verticalAlignment = Alignment.CenterVertically
                            ) { page ->
                                val counterIndex = page % activeCounters.size
                                val counter = activeCounters[counterIndex]

                                val targetLocalDate = java.time.Instant.ofEpochMilli(counter.targetDate)
                                    .atZone(java.time.ZoneId.systemDefault())
                                    .toLocalDate()
                                val today = java.time.LocalDate.now()

                                val diffDays = java.time.temporal.ChronoUnit.DAYS.between(targetLocalDate, today)
                                var isCalculatedUp = counter.isUp
                                var finalDays = diffDays

                                if (!isCalculatedUp && diffDays > 0 && counter.autoUp) {
                                    isCalculatedUp = true
                                    finalDays = diffDays
                                } else if (isCalculatedUp) {
                                    finalDays = diffDays
                                } else {
                                    finalDays = -diffDays
                                }

                                val daysCount = Math.max(0L, finalDays).toString()

                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.End
                                ) {
                                    Text(
                                        text = if (isCalculatedUp) "SINCE ${counter.name.uppercase()}" else "UNTIL ${counter.name.uppercase()}",
                                        fontSize = 9.sp,
                                        fontWeight = FontWeight.Black,
                                        color = NotelPrimary.copy(alpha = 0.8f),
                                        letterSpacing = 0.5.sp,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                        modifier = Modifier.weight(1f).padding(end = 6.dp),
                                        textAlign = TextAlign.End
                                    )

                                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Text(
                                                text = daysCount,
                                                fontSize = 14.sp,
                                                fontWeight = FontWeight.Black,
                                                color = NotelTextPrimary,
                                                modifier = Modifier.padding(end = 2.dp)
                                            )
                                            Text(
                                                text = "DAYS",
                                                fontSize = 8.sp,
                                                fontWeight = FontWeight.Bold,
                                                color = NotelTextSecondary,
                                                letterSpacing = 0.5.sp
                                            )
                                        }

                                        if (activeCounters.size > 1) {
                                            Row(
                                                modifier = Modifier.padding(top = 2.dp),
                                                horizontalArrangement = Arrangement.spacedBy(3.dp),
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                repeat(activeCounters.size) { iteration ->
                                                    val isCurrent = (pagerState.currentPage % activeCounters.size) == iteration
                                                    val color = if (isCurrent) NotelPrimary else NotelSurfaceHigh.copy(alpha = 0.3f)
                                                    Box(
                                                        modifier = Modifier
                                                            .size(if (isCurrent) 4.dp else 3.dp)
                                                            .background(color, CircleShape)
                                                    )
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // Fallback when no active event counters exist
                        val upcomingText = if (todayState.upcomingEvents.isNotEmpty()) {
                            val firstEvent = todayState.upcomingEvents.first()
                            "📅 ${firstEvent.title} · ${firstEvent.dateOrCountdownText}"
                        } else {
                            "📅 No upcoming events"
                        }
                        Text(
                            text = upcomingText,
                            color = NotelTextSecondary,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier
                                .padding(start = 8.dp)
                        )
                    }
                }
            }

            // ── 3. Expandable Today Summary Section ─────────────────────────────
            item {
                val savedTodaySummaryExpanded by todayViewModel.todaySummaryExpanded.collectAsState(initial = true)
                var localExpanded by remember { mutableStateOf<Boolean?>(null) }
                val isSummaryExpanded = localExpanded ?: savedTodaySummaryExpanded

                Surface(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                    color = NotelSurface,
                    shape = RoundedCornerShape(18.dp),
                    border = BorderStroke(1.dp, GlassBorder)
                ) {
                    Column(modifier = Modifier.padding(16.dp)) {
                        // Header Row (Clickable, 48dp+ target)
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(min = 48.dp)
                                .clip(RoundedCornerShape(12.dp))
                                .clickable {
                                    val nextState = !isSummaryExpanded
                                    localExpanded = nextState
                                    todayViewModel.setTodaySummaryExpanded(nextState)
                                },
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.SpaceBetween
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        imageVector = Icons.Default.Today,
                                        contentDescription = null,
                                        tint = NotelPrimary,
                                        modifier = Modifier.size(20.dp)
                                    )
                                    Spacer(Modifier.width(8.dp))
                                    Text(
                                        text = "Today Summary",
                                        fontWeight = FontWeight.Bold,
                                        color = NotelTextPrimary,
                                        fontSize = 16.sp
                                    )
                                }
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    text = todayState.summaryText,
                                    color = NotelTextSecondary,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium
                                )
                            }

                            IconButton(
                                onClick = {
                                    val nextState = !isSummaryExpanded
                                    localExpanded = nextState
                                    todayViewModel.setTodaySummaryExpanded(nextState)
                                }
                            ) {
                                Icon(
                                    imageVector = if (isSummaryExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                                    contentDescription = if (isSummaryExpanded) "Collapse Today Summary" else "Expand Today Summary",
                                    tint = NotelPrimary,
                                    modifier = Modifier.size(26.dp)
                                )
                            }
                        }

                        // Expanded Content: Today's Plan & Trends
                        AnimatedVisibility(
                            visible = isSummaryExpanded,
                            enter = expandVertically() + fadeIn(),
                            exit = shrinkVertically() + fadeOut()
                        ) {
                            Column(modifier = Modifier.padding(top = 12.dp)) {
                                HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
                                Spacer(Modifier.height(12.dp))

                                // Sub-section 1: Today's Plan
                                Text(
                                    text = "Today's Plan",
                                    fontWeight = FontWeight.Bold,
                                    color = NotelTextPrimary,
                                    fontSize = 14.sp
                                )
                                Spacer(Modifier.height(6.dp))

                                if (todayState.todayPlanItems.isEmpty()) {
                                    Text(
                                        text = "No plans recorded today",
                                        color = NotelTextSecondary,
                                        fontSize = 12.sp,
                                        modifier = Modifier.padding(vertical = 6.dp)
                                    )
                                } else {
                                    // Actionable Plan Items
                                    todayState.todayPlanItems.forEach { planItem ->
                                        val isOverdue = planItem.isOverdue()
                                        val alpha = if (planItem.isCompleted) 0.5f else 1.0f
                                        Surface(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(vertical = 3.dp),
                                            color = NotelSurfaceHigh.copy(alpha = alpha),
                                            shape = RoundedCornerShape(10.dp),
                                            border = if (isOverdue) BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.5f)) else null
                                        ) {
                                            Row(
                                                modifier = Modifier.padding(10.dp),
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                // Checkbox / Icon based on item type
                                                when (planItem) {
                                                    is TodayPlanItem.ScheduledReminder -> {
                                                        IconButton(
                                                            onClick = { todayViewModel.completeReminder(planItem.reminder.id) },
                                                            modifier = Modifier.size(32.dp)
                                                        ) {
                                                            Icon(
                                                                imageVector = if (planItem.isCompleted) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                                                                contentDescription = if (planItem.isCompleted) "Completed" else "Mark complete",
                                                                tint = if (planItem.isCompleted) NotelPrimary else NotelTextSecondary,
                                                                modifier = Modifier.size(18.dp)
                                                            )
                                                        }
                                                        Spacer(Modifier.width(6.dp))
                                                    }
                                                    is TodayPlanItem.ScheduledHabit -> {
                                                        IconButton(
                                                            onClick = { todayViewModel.toggleHabit(planItem.habit.id, !planItem.isCompleted) },
                                                            modifier = Modifier.size(32.dp)
                                                        ) {
                                                            Icon(
                                                                imageVector = if (planItem.isCompleted) Icons.Default.CheckCircle else Icons.Default.RadioButtonUnchecked,
                                                                contentDescription = if (planItem.isCompleted) "Completed" else "Toggle habit",
                                                                tint = if (planItem.isCompleted) NotelPrimary else NotelTextSecondary,
                                                                modifier = Modifier.size(18.dp)
                                                            )
                                                        }
                                                        Spacer(Modifier.width(6.dp))
                                                    }
                                                    is TodayPlanItem.ScheduledMedication -> {
                                                        Icon(
                                                            imageVector = when (planItem.status) {
                                                                ActionStatus.TAKEN -> Icons.Default.CheckCircle
                                                                ActionStatus.SKIPPED -> Icons.Default.Block
                                                                ActionStatus.SNOOZED -> Icons.Default.AccessTime
                                                                else -> Icons.Default.RadioButtonUnchecked
                                                            },
                                                            contentDescription = null,
                                                            tint = when (planItem.status) {
                                                                ActionStatus.TAKEN -> NotelPrimary
                                                                ActionStatus.SKIPPED -> NotelTextSecondary
                                                                ActionStatus.SNOOZED -> Color(0xFFFFA500)
                                                                else -> if (isOverdue) MaterialTheme.colorScheme.error else NotelTextSecondary
                                                            },
                                                            modifier = Modifier.size(18.dp)
                                                        )
                                                        Spacer(Modifier.width(10.dp))
                                                    }
                                                }

                                                Column(modifier = Modifier.weight(1f)) {
                                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                                        Text(
                                                            text = planItem.title,
                                                            fontWeight = if (planItem.isCompleted) FontWeight.Normal else FontWeight.Medium,
                                                            color = NotelTextPrimary.copy(alpha = alpha),
                                                            fontSize = 13.sp,
                                                            textDecoration = if (planItem.isCompleted) TextDecoration.LineThrough else TextDecoration.None,
                                                            modifier = Modifier.weight(1f)
                                                        )
                                                        if (isOverdue) {
                                                            Text(
                                                                text = "Overdue",
                                                                color = MaterialTheme.colorScheme.error,
                                                                fontWeight = FontWeight.Bold,
                                                                fontSize = 11.sp,
                                                                modifier = Modifier.padding(end = 8.dp)
                                                            )
                                                        }
                                                    }
                                                    if (planItem is TodayPlanItem.ScheduledMedication) {
                                                        Text(
                                                            text = "${planItem.dose} · ${planItem.timeDisplay}",
                                                            color = NotelTextSecondary.copy(alpha = alpha),
                                                            fontSize = 11.sp
                                                        )
                                                    } else {
                                                        Text(
                                                            text = planItem.timeDisplay,
                                                            color = NotelTextSecondary.copy(alpha = alpha),
                                                            fontSize = 11.sp
                                                        )
                                                    }
                                                }

                                                if (planItem is TodayPlanItem.ScheduledMedication) {
                                                    Spacer(Modifier.width(8.dp))
                                                    if (planItem.status == ActionStatus.PENDING || planItem.status == ActionStatus.SNOOZED) {
                                                        Row(
                                                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                                                            verticalAlignment = Alignment.CenterVertically
                                                        ) {
                                                            FilledTonalIconButton(
                                                                onClick = { todayViewModel.markMedicationAction(planItem.medication.id, ActionStatus.TAKEN, planItem.timeLabel) },
                                                                modifier = Modifier.size(32.dp),
                                                                colors = IconButtonDefaults.filledTonalIconButtonColors(
                                                                    containerColor = NotelPrimary.copy(alpha = 0.15f),
                                                                    contentColor = NotelPrimary
                                                                )
                                                            ) {
                                                                Icon(Icons.Default.Check, contentDescription = "Take Medication", modifier = Modifier.size(16.dp))
                                                            }
                                                            IconButton(
                                                                onClick = { todayViewModel.markMedicationAction(planItem.medication.id, ActionStatus.SKIPPED, planItem.timeLabel) },
                                                                modifier = Modifier.size(32.dp)
                                                            ) {
                                                                Icon(Icons.Default.Block, contentDescription = "Skip Medication", tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                                                            }
                                                        }
                                                    } else {
                                                        Row(
                                                            verticalAlignment = Alignment.CenterVertically,
                                                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                                                        ) {
                                                            Text(
                                                                text = when (planItem.status) {
                                                                    ActionStatus.TAKEN -> "Taken"
                                                                    ActionStatus.SKIPPED -> "Skipped"
                                                                    else -> ""
                                                                },
                                                                color = when (planItem.status) {
                                                                    ActionStatus.TAKEN -> NotelPrimary
                                                                    ActionStatus.SKIPPED -> NotelTextSecondary
                                                                    else -> NotelTextPrimary
                                                                },
                                                                fontSize = 12.sp,
                                                                fontWeight = FontWeight.Bold
                                                            )
                                                            IconButton(
                                                                onClick = { todayViewModel.markMedicationAction(planItem.medication.id, ActionStatus.PENDING, planItem.timeLabel) },
                                                                modifier = Modifier.size(28.dp)
                                                            ) {
                                                                Icon(Icons.Default.Undo, contentDescription = "Undo action", tint = NotelTextSecondary, modifier = Modifier.size(14.dp))
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                Spacer(Modifier.height(14.dp))
                                HorizontalDivider(color = Color.White.copy(alpha = 0.08f))
                                Spacer(Modifier.height(12.dp))

                                // Sub-section 2: Trends (formerly What Changed)
                                Row(
                                    modifier = Modifier.fillMaxWidth(),
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Text(
                                        text = "Trends",
                                        fontWeight = FontWeight.Bold,
                                        color = NotelTextPrimary,
                                        fontSize = 14.sp
                                    )
                                    IconButton(
                                        onClick = { todayViewModel.loadHealthComparisons() },
                                        modifier = Modifier.size(24.dp)
                                    ) {
                                        Icon(Icons.Default.Refresh, contentDescription = "Refresh Trends", tint = NotelTextSecondary, modifier = Modifier.size(14.dp))
                                    }
                                }
                                Spacer(Modifier.height(6.dp))

                                when (val ts = todayState.trendsState) {
                                    is TodayTrendsState.Loading -> {
                                        Box(Modifier.fillMaxWidth().padding(vertical = 12.dp), contentAlignment = Alignment.Center) {
                                            CircularProgressIndicator(color = NotelPrimary, modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                                        }
                                    }
                                    is TodayTrendsState.Empty -> {
                                        Text(
                                            text = "Not enough data yet",
                                            color = NotelTextSecondary,
                                            fontSize = 12.sp,
                                            modifier = Modifier.padding(vertical = 4.dp)
                                        )
                                    }
                                    is TodayTrendsState.Error -> {
                                        Text(
                                            text = ts.message,
                                            color = MaterialTheme.colorScheme.error,
                                            fontSize = 12.sp
                                        )
                                    }
                                    is TodayTrendsState.Ready -> {
                                        val items: List<com.notel.notel.data.repository.HealthComparisonItem> = ts.items
                                        items.forEach { comp ->
                                            Surface(
                                                modifier = Modifier
                                                    .fillMaxWidth()
                                                    .padding(vertical = 4.dp),
                                                color = NotelSurfaceHigh,
                                                shape = RoundedCornerShape(10.dp),
                                                border = BorderStroke(1.dp, GlassBorder)
                                            ) {
                                                Column(modifier = Modifier.padding(10.dp)) {
                                                    Row(
                                                        modifier = Modifier.fillMaxWidth(),
                                                        horizontalArrangement = Arrangement.SpaceBetween,
                                                        verticalAlignment = Alignment.CenterVertically
                                                    ) {
                                                        Text(comp.metricName, fontWeight = FontWeight.Bold, fontSize = 13.sp, color = NotelTextPrimary)
                                                        Text(comp.dataSource, fontSize = 10.sp, color = NotelTextSecondary)
                                                    }
                                                    Spacer(Modifier.height(3.dp))
                                                    Text(comp.differenceText, fontSize = 12.sp, color = NotelPrimary, fontWeight = FontWeight.SemiBold)
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



            // ── 3C. Active AI Insight Section ──────────────────────────────
            if (todayState.primaryInsight != null) {
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

@Composable
fun isReducedMotionEnabled(): Boolean {
    val context = androidx.compose.ui.platform.LocalContext.current
    return remember(context) {
        val resolver = context.contentResolver
        val animatorScale = android.provider.Settings.Global.getFloat(
            resolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE,
            1.0f
        )
        animatorScale == 0.0f
    }
}

@Composable
private fun UnifiedMetricTile(
    iconEmoji: String,
    valueText: String,
    labelText: String,
    tileDescription: String,
    modifier: Modifier = Modifier
) {
    Surface(
        modifier = modifier
            .width(104.dp)
            .height(72.dp)
            .semantics { contentDescription = tileDescription },
        color = Color(0xFF141416),
        shape = RoundedCornerShape(12.dp),
        border = BorderStroke(1.dp, GlassBorder)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.SpaceBetween
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(text = iconEmoji, fontSize = 14.sp)
                Text(
                    text = labelText,
                    fontSize = 10.sp,
                    color = NotelTextSecondary,
                    fontWeight = FontWeight.Medium
                )
            }
            Text(
                text = valueText,
                fontSize = 15.sp,
                color = NotelTextPrimary,
                fontWeight = FontWeight.Bold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis
            )
        }
    }
}

@Composable
private fun MetricChip(icon: String, value: String) {
    Surface(
        color = NotelSurfaceHigh.copy(alpha = 0.6f),
        shape = RoundedCornerShape(8.dp),
        border = BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.15f))
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(icon, fontSize = 12.sp)
            Spacer(Modifier.width(4.dp))
            Text(value, fontSize = 11.sp, fontWeight = FontWeight.Bold, color = NotelTextPrimary)
        }
    }
}
