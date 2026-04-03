package com.notel.notel.ui.screen

import androidx.compose.animation.*
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.foundation.clickable
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.data.local.entity.Category
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.QuickLogViewModel
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.*
import java.time.LocalDate
import java.time.format.DateTimeFormatter

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun QuickLogScreen(
    viewModel: QuickLogViewModel = hiltViewModel(),
    onNavigateToHistory: () -> Unit,
    onNavigateToSettings: () -> Unit,
    onNavigateToTrends: () -> Unit,
    onNavigateToFitbit: () -> Unit,
    onNavigateToSleep: () -> Unit,
    onNavigateToBodyLoad: () -> Unit = {}
) {
    val state by viewModel.uiState.collectAsState()
    val isGeneratingWeeklyRecap by viewModel.isGeneratingWeeklyRecap.collectAsState()
    val isGeneratingDeepResearch by viewModel.isGeneratingDeepResearch.collectAsState()

    // Auto-fetch chips once: when category is selected, user has credits/access, and no chips loaded yet
    LaunchedEffect(state.selectedCategory, state.userBalance, state.isUnlimited, state.autoAiSuggestions) {
        val hasAccess = state.isUnlimited || state.userBalance >= 0.01f
        if (state.autoAiSuggestions && state.selectedCategory != null && hasAccess &&
            state.chips.isEmpty() && !state.isLoadingChips && state.chipsError == null
        ) {
            viewModel.fetchSuggestions()
        }
    }

    // Snackbar on save
    val snackbarHostState = remember { SnackbarHostState() }
    LaunchedEffect(state.saveSuccess) {
        if (state.saveSuccess) {
            snackbarHostState.showSnackbar("Entry logged ✓")
            viewModel.resetSaveSuccess()
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Jot", 
                        style = MaterialTheme.typography.displaySmall, 
                        fontWeight = FontWeight.Black, 
                        color = NotelPrimary,
                        modifier = Modifier.clickable { viewModel.showOnboarding() }
                    )
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground),
                actions = {
                    IconButton(onClick = onNavigateToBodyLoad) {
                        Icon(Icons.Default.Person, contentDescription = "Body Load", tint = NotelPrimary)
                    }
                    IconButton(onClick = onNavigateToFitbit) {
                        Icon(Icons.Default.FavoriteBorder, contentDescription = "Heart Rate", tint = NotelPrimary)
                    }
                    IconButton(onClick = onNavigateToSleep) {
                        Icon(Icons.Default.Bed, contentDescription = "Sleep Profile", tint = NotelPrimary)
                    }
                    IconButton(onClick = onNavigateToTrends) {
                        Icon(Icons.Default.TrendingUp, contentDescription = "Trends", tint = NotelTextSecondary)
                    }
                    IconButton(onClick = onNavigateToHistory) {
                        Icon(Icons.Default.History, contentDescription = "History", tint = NotelTextSecondary)
                    }
                    IconButton(onClick = onNavigateToSettings) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings", tint = NotelTextSecondary)
                    }
                }
            )
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .imePadding()
        ) {
            // ── Smart Category Row ──────────────────────────────────────────────
            if (state.smartCategories.isNotEmpty()) {
                Text(
                    "Recommended for You",
                    style = MaterialTheme.typography.labelMedium,
                    color = NotelPrimary,
                    modifier = Modifier.padding(start = 16.dp, top = 8.dp)
                )
                LazyRow(
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    items(state.smartCategories) { cat ->
                        CategoryChip(
                            category = cat,
                            isSelected = cat.id == state.selectedCategory?.id,
                            onClick = { viewModel.selectCategory(cat) }
                        )
                    }
                }
            }

            // ── Category Row ──────────────────────────────────────────────
            Text(
                "All Categories",
                style = MaterialTheme.typography.labelMedium,
                color = NotelTextSecondary,
                modifier = Modifier.padding(start = 16.dp, top = 8.dp)
            )
            LazyRow(
                contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                val smartIds = state.smartCategories.map { it.id }.toSet()
                val otherCategories = state.categories.filter { it.id !in smartIds }
                items(otherCategories) { cat ->
                    CategoryChip(
                        category = cat,
                        isSelected = cat.id == state.selectedCategory?.id,
                        onClick = { viewModel.selectCategory(cat) }
                    )
                }
            }

            // ── Smart Action Card ──────────────────────────────────────────────
            state.smartAction?.let { action ->
                SmartActionCard(
                    action = action,
                    onDismiss = viewModel::dismissSmartAction,
                    onAccept = {
                        viewModel.acceptSmartAction(action)
                    }
                )
            }



            // ── AI Chip Tray ──────────────────────────────────────────────
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .weight(1f)
                    .padding(horizontal = 16.dp)
            ) {
                when {
                    !state.isUnlimited && state.userBalance < 0.01f -> NoBalancePrompt(onGoToSettings = onNavigateToSettings)
                    state.selectedCategory?.id == -1 -> {
                        val today = java.time.LocalDate.now().format(java.time.format.DateTimeFormatter.ISO_LOCAL_DATE)
                        var showClearHabitConfirm by remember { mutableStateOf(false) }
                        
                        Box(modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState())) {
                            Column {
                                FlowRow(
                                    modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp),
                                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                                    verticalArrangement = Arrangement.spacedBy(8.dp)
                                ) {
                                    state.habits.forEach { habit ->
                                        val isChecked = habit.logs.contains(today)
                                        Box(
                                            modifier = Modifier
                                                .clip(RoundedCornerShape(20.dp))
                                                .background(if (isChecked) NotelSurfaceHigh else NotelSurface)
                                                .clickable {
                                                    viewModel.toggleHabit(habit.id, !isChecked)
                                                }
                                                .border(
                                                    width = 1.dp,
                                                    color = if (isChecked) Color.Transparent else NotelPrimary.copy(alpha = 0.5f),
                                                    shape = RoundedCornerShape(20.dp)
                                                )
                                                .padding(horizontal = 16.dp, vertical = 10.dp),
                                            contentAlignment = Alignment.Center
                                        ) {
                                            Row(verticalAlignment = Alignment.CenterVertically) {
                                                if (isChecked) {
                                                    Icon(Icons.Default.CheckCircle, null, tint = NotelPrimary, modifier = Modifier.size(16.dp))
                                                    Spacer(Modifier.width(6.dp))
                                                }
                                                Text(
                                                    habit.title,
                                                    color = if (isChecked) NotelTextSecondary else NotelTextPrimary,
                                                    fontWeight = if (isChecked) FontWeight.Normal else FontWeight.SemiBold,
                                                    fontSize = 14.sp,
                                                    textDecoration = if (isChecked) androidx.compose.ui.text.style.TextDecoration.LineThrough else null
                                                )
                                            }
                                        }
                                    }
                                }
                                
                                if (state.habits.isNotEmpty()) {
                                    Spacer(Modifier.height(32.dp))
                                    TextButton(
                                        onClick = { showClearHabitConfirm = true },
                                        modifier = Modifier.align(Alignment.CenterHorizontally)
                                    ) {
                                        Icon(Icons.Default.DeleteSweep, "Clear habit logs", tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                                        Spacer(Modifier.width(6.dp))
                                        Text("Clear History Logs", color = NotelTextSecondary, fontSize = 12.sp)
                                    }
                                    Spacer(Modifier.height(16.dp))
                                }
                            }
                        }

                        if (showClearHabitConfirm) {
                            AlertDialog(
                                onDismissRequest = { showClearHabitConfirm = false },
                                title = { Text("Clear Habit Logs?", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                                text = { Text("This will wipe all historical habit streaks and completions. Habit list will remain. Cannot be undone.", color = NotelTextSecondary) },
                                confirmButton = {
                                    TextButton(onClick = {
                                        viewModel.clearHabitData()
                                        showClearHabitConfirm = false
                                    }) {
                                        Text("Clear", color = NotelPrimary)
                                    }
                                },
                                dismissButton = {
                                    TextButton(onClick = { showClearHabitConfirm = false }) {
                                        Text("Cancel", color = NotelTextSecondary)
                                    }
                                },
                                containerColor = NotelSurface
                            )
                        }
                    }
                    !state.autoAiSuggestions && state.chips.isEmpty() && !state.isLoadingChips -> {
                        Column(
                            modifier = Modifier.fillMaxSize(),
                            horizontalAlignment = Alignment.CenterHorizontally,
                            verticalArrangement = Arrangement.Center
                        ) {
                            Icon(Icons.Default.AutoAwesome, null, tint = NotelPrimary.copy(alpha = 0.5f), modifier = Modifier.size(48.dp))
                            Spacer(Modifier.height(16.dp))
                            Text("AI suggestions are paused", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                            Text("Click below to load tiles ($0.01)", color = NotelTextSecondary, fontSize = 12.sp)
                            Spacer(Modifier.height(20.dp))
                            GlassyButton(
                                onClick = { viewModel.fetchSuggestions() },
                                containerColor = NotelPrimary
                            ) {
                                Text("Load Suggestions", color = Color.White)
                            }
                        }
                    }
                    state.isLoadingChips -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            GlassySpinner(size = 48.dp)
                            Spacer(Modifier.height(12.dp))
                            Text("Getting suggestions…", color = NotelTextSecondary, fontSize = 14.sp)
                        }
                    }
                    state.chipsError != null -> Column(
                        modifier = Modifier.fillMaxSize(),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center
                    ) {
                        Text(state.chipsError!!, color = MaterialTheme.colorScheme.error, fontSize = 14.sp)
                        Spacer(Modifier.height(12.dp))
                        Button(onClick = { viewModel.fetchSuggestions(forceRefresh = true) }) { Text("Retry") }
                    }
                    else -> ChipGrid(
                        chips = state.chips,
                        selected = state.selectedChips,
                        onToggle = viewModel::toggleChip
                    )
                }
            }
            
            // ── Productivity Layer / Combo Preview ────────────────────────
            AnimatedVisibility(
                visible = state.manualText.isBlank() && state.selectedChips.isEmpty(),
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically()
            ) {
                var isProductivityExpanded by remember { mutableStateOf(false) }
                Column {
                    // ── Event Counter Bubble ─────────────────────────────
                    val activeCounter = state.eventCounters.firstOrNull { it.isFavorite } ?: state.eventCounters.firstOrNull()
                    if (activeCounter != null) {
                        val todayStart = java.util.Calendar.getInstance().apply {
                            set(java.util.Calendar.HOUR_OF_DAY, 0)
                            set(java.util.Calendar.MINUTE, 0)
                            set(java.util.Calendar.SECOND, 0)
                            set(java.util.Calendar.MILLISECOND, 0)
                        }.timeInMillis
                        
                        val diffMillis = activeCounter.targetDate - todayStart
                        var isUp = activeCounter.isUp
                        var finalDiffMillis = diffMillis
                        
                        if (!isUp && diffMillis < 0 && activeCounter.autoUp) {
                            isUp = true
                            finalDiffMillis = todayStart - activeCounter.targetDate
                        } else if (isUp) {
                            finalDiffMillis = todayStart - activeCounter.targetDate
                        }
                        
                        if (isUp || diffMillis >= 0) {
                            val daysRemaining = Math.max(0L, finalDiffMillis / 86400000L)
                            val direction = if (isUp) "since" else "until"
                            
                            var isCounterExpanded by remember { mutableStateOf(false) }
                            
                            Row(modifier = Modifier.fillMaxWidth().padding(end = 16.dp), horizontalArrangement = Arrangement.End) {
                                Box(
                                    modifier = Modifier
                                        .background(NotelPrimary.copy(alpha = 0.9f), RoundedCornerShape(24.dp))
                                        .clickable { isCounterExpanded = !isCounterExpanded }
                                        .padding(horizontal = 16.dp, vertical = 10.dp)
                                ) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(Icons.Default.Timer, null, tint = Color.White, modifier = Modifier.size(18.dp))
                                        if (isCounterExpanded) {
                                            Spacer(Modifier.width(8.dp))
                                            Text(
                                                text = "${activeCounter.name}: $daysRemaining days $direction",
                                                color = Color.White,
                                                fontWeight = FontWeight.Bold,
                                                fontSize = 12.sp,
                                                maxLines = 1,
                                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                                            )
                                        }
                                    }
                                }
                            }
                            Spacer(Modifier.height(12.dp))
                        }
                    }

                    // ── Productivity Agent ─────────────────────────────
                    ProductivityDashboard(
                        loggedDays = state.loggedDays,
                        onToggleDay = viewModel::toggleLoggedDay,
                        isExpanded = isProductivityExpanded,
                        onExpandedChange = { isProductivityExpanded = it }
                    )
                    Spacer(Modifier.height(12.dp))
                }
            }

            AnimatedVisibility(
                visible = state.selectedChips.isNotEmpty(),
                enter = fadeIn() + expandVertically(),
                exit = fadeOut() + shrinkVertically()
            ) {
                Column {
                    GlassyCard(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp),
                        color = NotelSurface
                    ) {
                        Text(
                            text = "Composed Logging Phrase",
                            style = MaterialTheme.typography.labelSmall,
                            color = NotelTextSecondary
                        )
                        Spacer(modifier = Modifier.height(4.dp))
                        Text(
                            text = buildString {
                                if (state.composedText.isNotBlank()) append(state.composedText)
                                if (state.manualText.isNotBlank()) {
                                    if (isNotEmpty()) append(" — ")
                                    append(state.manualText)
                                }
                            },
                            style = MaterialTheme.typography.bodyLarge,
                            color = NotelTextPrimary,
                            fontWeight = FontWeight.Medium
                        )
                    }
                    Spacer(Modifier.height(12.dp))
                }
            }

            // ── Manual Text Field ─────────────────────────────────────────
            val context = androidx.compose.ui.platform.LocalContext.current
            OutlinedTextField(
                value = state.manualText,
                onValueChange = viewModel::updateManualText,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp),
                placeholder = { Text("Add a custom note…", color = NotelTextSecondary) },
                trailingIcon = {
                    IconButton(onClick = { 
                        context.startActivity(Intent(context, VoiceLogActivity::class.java))
                    }) {
                        Icon(Icons.Default.Mic, null, tint = NotelPrimary)
                    }
                },
                shape = RoundedCornerShape(14.dp),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = NotelPrimary,
                    unfocusedBorderColor = NotelSurfaceHigh,
                    focusedTextColor = NotelTextPrimary,
                    unfocusedTextColor = NotelTextPrimary,
                    cursorColor = NotelPrimary,
                    unfocusedContainerColor = NotelSurface,
                    focusedContainerColor = NotelSurface
                )
            )

            Spacer(Modifier.height(12.dp))

            // ── AI Advice Dialog ────────────────────────────────────────────
            if (state.showAdviceDialog) {
                Dialog(onDismissRequest = { viewModel.dismissAdvice() }) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp)
                            .liquidGlass(shape = RoundedCornerShape(24.dp), color = NotelBackground, alpha = 0.9f)
                            .padding(24.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("AI Insights", fontWeight = FontWeight.Bold, fontSize = 18.sp, color = NotelTextPrimary)
                            }
                            Spacer(Modifier.height(16.dp))
                            when {
                                state.isLoadingAdvice -> {
                                    GlassySpinner(size = 48.dp)
                                    Spacer(Modifier.height(12.dp))
                                    Text("Analysing your recent entries…", color = NotelTextSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
                                }
                                state.adviceError != null -> {
                                    state.adviceError?.let { err ->
                                        Text(err, color = MaterialTheme.colorScheme.error, fontSize = 14.sp, textAlign = TextAlign.Center)
                                    }
                                }
                                state.advice != null -> {
                                    state.advice?.let { advice ->
                                        Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .heightIn(max = 300.dp)
                                                .verticalScroll(rememberScrollState())
                                        ) {
                                            Text(advice, color = NotelTextPrimary, fontSize = 15.sp, lineHeight = 22.sp)
                                        }
                                    }
                                }
                            }
                            Spacer(Modifier.height(20.dp))
                            GlassyButton(
                                onClick = { viewModel.dismissAdvice() },
                                modifier = Modifier.fillMaxWidth(),
                                containerColor = NotelSurfaceHigh
                            ) { Text("Dismiss", color = NotelTextPrimary) }
                        }
                    }
                }
            }
            
            // ── Onboarding Dialog ───────────────────────────────────────────
            if (state.showOnboardingDialog) {
                AlertDialog(
                    onDismissRequest = { viewModel.dismissOnboarding() },
                    title = { Text("Welcome to Jot!", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = { 
                        Text(
                            "Jot makes tracking your health simple. Pick a category, build an entry with AI suggestions, or write your own note. Tap Trends to see patterns over time!", 
                            color = NotelTextSecondary
                        ) 
                    },
                    confirmButton = {
                        TextButton(onClick = { viewModel.dismissOnboarding() }) {
                            Text("Get Started", color = NotelPrimary, fontWeight = FontWeight.Bold)
                        }
                    },
                    containerColor = NotelSurface,
                    shape = RoundedCornerShape(16.dp)
                )
            }

            // ── Free Credit Bonus Dialog ──────────────────────────────────
            if (state.showFreeCreditPopup) {
                AlertDialog(
                    onDismissRequest = { viewModel.dismissBonusPopup() },
                    title = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.AccountBalanceWallet, null, tint = NotelPrimary)
                            Spacer(Modifier.width(12.dp))
                            Text("Free Credits!", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                        }
                    },
                    text = {
                        Text(
                            "To get you started, we've added a free $1.00 to your wallet! Use it to explore AI suggestions, professional reports, and deep advice.",
                            color = NotelTextSecondary
                        )
                    },
                    confirmButton = {
                        TextButton(onClick = { viewModel.dismissBonusPopup() }) {
                            Text("Awesome!", color = NotelPrimary, fontWeight = FontWeight.Bold)
                        }
                    },
                    containerColor = NotelSurface,
                    shape = RoundedCornerShape(20.dp)
                )
            }

            // ── Compare Documents Dialog ────────────────────────────────────
            if (state.showComparisonDialog) {
                Dialog(onDismissRequest = { viewModel.dismissComparison() }) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(16.dp)
                            .liquidGlass(shape = RoundedCornerShape(24.dp), color = NotelBackground, alpha = 0.9f)
                            .padding(24.dp),
                        contentAlignment = Alignment.Center
                    ) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.CompareArrows, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Document Comparison", fontWeight = FontWeight.Bold, fontSize = 18.sp, color = NotelTextPrimary)
                            }
                            Spacer(Modifier.height(16.dp))
                            when {
                                state.isLoadingComparison -> {
                                    GlassySpinner(size = 48.dp)
                                    Spacer(Modifier.height(12.dp))
                                    Text("Comparing your logs against your documents…", color = NotelTextSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
                                }
                                state.comparisonError != null -> {
                                    state.comparisonError?.let { err ->
                                        Text(err, color = MaterialTheme.colorScheme.error, fontSize = 14.sp, textAlign = TextAlign.Center)
                                    }
                                }
                                state.comparisonResult != null -> {
                                    state.comparisonResult?.let { result ->
                                        Column(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .heightIn(max = 400.dp)
                                                .verticalScroll(rememberScrollState())
                                        ) {
                                            Text(result, color = NotelTextPrimary, fontSize = 15.sp, lineHeight = 22.sp)
                                        }
                                    }
                                }
                            }
                            Spacer(Modifier.height(20.dp))
                            GlassyButton(
                                onClick = { viewModel.dismissComparison() },
                                modifier = Modifier.fillMaxWidth(),
                                containerColor = NotelSurfaceHigh
                            ) { Text("Dismiss", color = NotelTextPrimary) }
                        }
                    }
                }
            }

            // ── Action buttons row ──────────────────────────────────────────
            val canLog = state.composedText.isNotBlank() || state.manualText.isNotBlank()
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                verticalAlignment = Alignment.Bottom
            ) {
                var isAiMenuExpanded by remember { mutableStateOf(false) }

                Column(modifier = Modifier.weight(1f)) {
                    AnimatedVisibility(
                        visible = isAiMenuExpanded,
                        enter = fadeIn() + expandVertically(expandFrom = Alignment.Top),
                        exit = fadeOut() + shrinkVertically(shrinkTowards = Alignment.Top)
                    ) {
                        Column(
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier.padding(bottom = 8.dp)
                        ) {
                            GlassyButton(
                                onClick = { 
                                    viewModel.generateDeepResearch()
                                    isAiMenuExpanded = false 
                                },
                                enabled = (state.isUnlimited || state.userBalance >= 0.10f) && !isGeneratingDeepResearch,
                                containerColor = if (state.isUnlimited || state.userBalance >= 0.10f) NotelSurfaceHigh else Color.Gray.copy(alpha = 0.2f),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                if (isGeneratingDeepResearch) {
                                    GlassySpinner(size = 20.dp)
                                } else {
                                    Icon(Icons.Default.Search, contentDescription = null, modifier = Modifier.size(18.dp), tint = NotelPrimary)
                                    Spacer(Modifier.width(6.dp))
                                    Text("Deep Advice", fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = NotelTextPrimary)
                                }
                            }
                            
                            GlassyButton(
                                onClick = { 
                                    viewModel.generateWeeklyRecap()
                                    isAiMenuExpanded = false 
                                },
                                enabled = (state.isUnlimited || state.userBalance >= 0.05f) && !isGeneratingWeeklyRecap,
                                containerColor = if (state.isUnlimited || state.userBalance >= 0.05f) NotelSurfaceHigh else Color.Gray.copy(alpha = 0.2f),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                if (isGeneratingWeeklyRecap) {
                                    GlassySpinner(size = 20.dp)
                                } else {
                                    Icon(Icons.Default.DateRange, contentDescription = null, modifier = Modifier.size(18.dp), tint = NotelPrimary)
                                    Spacer(Modifier.width(6.dp))
                                    Text("Weekly Recap", fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = NotelTextPrimary)
                                }
                            }

                            GlassyButton(
                                onClick = { 
                                    viewModel.requestAdvice()
                                    isAiMenuExpanded = false 
                                },
                                enabled = (state.isUnlimited || state.userBalance >= 0.01f) && !state.isLoadingAdvice,
                                containerColor = if (state.isUnlimited || state.userBalance >= 0.01f) NotelSurfaceHigh else Color.Gray.copy(alpha = 0.2f),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                if (state.isLoadingAdvice) {
                                    GlassySpinner(size = 20.dp)
                                } else {
                                    Icon(Icons.Default.AutoAwesome, contentDescription = null, modifier = Modifier.size(18.dp), tint = NotelPrimary)
                                    Spacer(Modifier.width(6.dp))
                                    Text("Basic Advice", fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = NotelTextPrimary)
                                }
                            }
                            
                            val isComparingDocuments by viewModel.isComparingDocuments.collectAsState()
                            GlassyButton(
                                onClick = { viewModel.compareDocuments() },
                                enabled = state.userBalance >= 0.05f && state.hasKnowledgeDocs && !isComparingDocuments,
                                containerColor = if (state.hasKnowledgeDocs && state.userBalance >= 0.05f) NotelSurfaceHigh else Color.Gray.copy(alpha = 0.3f),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                if (isComparingDocuments) {
                                    GlassySpinner(size = 20.dp)
                                } else {
                                    Icon(Icons.Default.CompareArrows, contentDescription = null, modifier = Modifier.size(18.dp), tint = if (state.hasKnowledgeDocs) NotelPrimary else NotelTextSecondary)
                                    Spacer(Modifier.width(6.dp))
                                    Text("Compare Docs", fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = if (state.hasKnowledgeDocs) NotelTextPrimary else NotelTextSecondary, maxLines = 1)
                                }
                            }
                        }
                    }

                    GlassyButton(
                        onClick = { isAiMenuExpanded = !isAiMenuExpanded },
                        containerColor = NotelSurfaceHigh,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Icon(
                            if (isAiMenuExpanded) Icons.Default.Close else Icons.Default.AutoAwesome, 
                            contentDescription = null, 
                            modifier = Modifier.size(18.dp), 
                            tint = NotelPrimary
                        )
                        Spacer(Modifier.width(6.dp))
                        Text(
                            if (isAiMenuExpanded) "Close" else "Learn More", 
                            fontWeight = FontWeight.SemiBold, 
                            fontSize = 15.sp, 
                            color = NotelTextPrimary
                        )
                    }
                }

                GlassyButton(
                    onClick = viewModel::saveEntry,
                    enabled = canLog && !state.isSaving,
                    containerColor = NotelPrimary,
                    modifier = Modifier.weight(1f)
                ) {
                    if (state.isSaving) {
                        GlassySpinner(size = 24.dp)
                    } else {
                        Icon(Icons.Default.Add, contentDescription = null, tint = Color.White)
                        Spacer(Modifier.width(8.dp))
                        Text("Log Entry", fontWeight = FontWeight.Bold, fontSize = 16.sp, color = Color.White)
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun CategoryChip(category: Category, isSelected: Boolean, onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        modifier = Modifier
            .liquidGlass(
                shape = RoundedCornerShape(12.dp),
                color = if (isSelected) NotelPrimary else NotelSurfaceHigh,
                alpha = if (isSelected) 0.6f else 0.3f
            ),
        color = Color.Transparent
    ) {
        Text(
            category.name,
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            color = if (isSelected) Color.White else NotelTextSecondary,
            fontSize = 13.sp,
            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ChipGrid(chips: List<String>, selected: List<String>, onToggle: (String) -> Unit) {
    FlowRow(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(vertical = 12.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        chips.forEach { chip ->
            val isSelected = chip in selected
            Surface(
                onClick = { onToggle(chip) },
                modifier = Modifier
                    .animateContentSize()
                    .liquidGlass(
                        shape = RoundedCornerShape(14.dp),
                        color = if (isSelected) NotelPrimary else NotelSurfaceHigh,
                        alpha = if (isSelected) 0.8f else 0.4f
                    ),
                color = Color.Transparent
            ) {
                Text(
                    chip,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                    color = if (isSelected) Color.White else NotelTextPrimary,
                    fontSize = 14.sp,
                    fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal
                )
            }
        }
    }
}

@Composable
private fun NoBalancePrompt(onGoToSettings: () -> Unit) {
    Column(
        modifier = Modifier.fillMaxSize(),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Icon(
            Icons.Default.AccountBalanceWallet, contentDescription = null,
            tint = NotelPrimary, modifier = Modifier.size(48.dp)
        )
        Spacer(Modifier.height(16.dp))
        Text("No credits remaining", color = NotelTextPrimary, fontSize = 18.sp, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        Text("Top up your wallet in settings to enable AI suggestions and insights.", color = NotelTextSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
        Spacer(Modifier.height(24.dp))
        GlassyButton(onClick = onGoToSettings, containerColor = NotelPrimary) {
            Text("Go to Wallet", color = Color.White)
        }
    }
}

@Composable
fun ProductivityDashboard(
    loggedDays: Set<String>,
    onToggleDay: (String) -> Unit,
    isExpanded: Boolean,
    onExpandedChange: (Boolean) -> Unit
) {
    val today = remember { LocalDate.now() }
    val formatter = remember { DateTimeFormatter.ISO_LOCAL_DATE }
    val sortedDates = remember(loggedDays) {
        loggedDays.mapNotNull { 
            try { LocalDate.parse(it, formatter) } catch (e: Exception) { null }
        }.sorted()
    }
    val firstDate = sortedDates.firstOrNull() ?: today
    val daysSinceStart = java.time.temporal.ChronoUnit.DAYS.between(firstDate, today)
    val cyclesCompleted = if (daysSinceStart >= 0) daysSinceStart / 90 else 0
    val gridStartDate = firstDate.plusDays((cyclesCompleted * 90))
    
    val daysCompleted = sortedDates.size
    
    var streak = 0
    if (sortedDates.contains(today)) {
        var tempDate = today
        while (sortedDates.contains(tempDate)) {
            streak++
            tempDate = tempDate.minusDays(1)
        }
    } else {
        var tempDate = today.minusDays(1)
        while (sortedDates.contains(tempDate)) {
            streak++
            tempDate = tempDate.minusDays(1)
        }
    }

    val currentPhase = ((daysCompleted - 1).coerceAtLeast(0) / 30) + 1 // Phase continues indefinitely
    
    val loggedInCurrentCycle = sortedDates.count { !it.isBefore(gridStartDate) && it.isBefore(gridStartDate.plusDays(90)) }
    val progressPercent = ((loggedInCurrentCycle.toFloat() / 90f) * 100).toInt().coerceAtMost(100)

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .liquidGlass(shape = RoundedCornerShape(20.dp), color = NotelBackground, alpha = 0.8f)
            .padding(16.dp)
            .animateContentSize()
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .clickable { onExpandedChange(!isExpanded) }
        ) {
            Icon(Icons.Default.Insights, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(20.dp))
            Spacer(Modifier.width(8.dp))
            Text("Productivity Agent", style = MaterialTheme.typography.titleMedium, color = NotelTextPrimary, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            Icon(
                if (isExpanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                contentDescription = null,
                tint = NotelTextSecondary
            )
        }
        
        if (isExpanded) {
            Spacer(Modifier.height(16.dp))
            
            // Stat Cards
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                StatCard("Days", "$daysCompleted", Modifier.weight(1f))
                StatCard("Streak", "$streak \uD83D\uDD25", Modifier.weight(1f))
                StatCard("Phase", "$currentPhase", Modifier.weight(1f))
                StatCard("Progress", "$progressPercent%", Modifier.weight(1f))
            }

            Spacer(Modifier.height(16.dp))
            Text("90-Day Journey", style = MaterialTheme.typography.labelMedium, color = NotelTextSecondary)
            Spacer(Modifier.height(8.dp))
            
            LazyRow(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                items(1) {
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        for (row in 0 until 3) {
                            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                for (col in 0 until 30) {
                                    val dayIndex = row * 30 + col
                                    val cellDate = gridStartDate.plusDays(dayIndex.toLong())
                                    val isDone = sortedDates.contains(cellDate)
                                    val isToday = cellDate == today
                                    val color = when {
                                        isDone -> Color(0xFF4CAF50) // Green
                                        isToday -> Color(0xFF2196F3) // Blue
                                        else -> NotelSurfaceHigh // Dark
                                    }
                                    Box(
                                        modifier = Modifier
                                            .size(20.dp)
                                            .clip(RoundedCornerShape(4.dp))
                                            .background(color)
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

@Composable
fun StatCard(label: String, value: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .background(NotelSurfaceHigh, RoundedCornerShape(12.dp))
            .padding(8.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(value, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.Bold, color = NotelTextPrimary)
        Text(label, style = MaterialTheme.typography.labelSmall, color = NotelTextSecondary, fontSize = 10.sp, maxLines = 1)
    }
}

@Composable
private fun SmartActionCard(
    action: com.notel.notel.ui.viewmodel.SmartAction,
    onDismiss: () -> Unit,
    onAccept: () -> Unit
) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp)
            .liquidGlass(
                shape = RoundedCornerShape(16.dp),
                color = NotelPrimary,
                alpha = 0.15f
            ),
        color = Color.Transparent
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Lightbulb, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(8.dp))
                Text(action.title, style = MaterialTheme.typography.titleMedium, color = NotelPrimary, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) {
                    Icon(Icons.Default.Close, contentDescription = "Dismiss", tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(action.description, style = MaterialTheme.typography.bodyMedium, color = NotelTextPrimary)
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                TextButton(onClick = onAccept) {
                    Text("Great Idea", color = NotelPrimary, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}
