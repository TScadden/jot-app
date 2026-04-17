package com.notel.notel.ui.screen

import android.content.Intent
import com.notel.notel.VoiceLogActivity

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
import androidx.compose.ui.text.style.TextOverflow
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

    // Auto-fetch chips once...
    LaunchedEffect(state.selectedCategory, state.userBalance, state.isUnlimited, state.autoAiSuggestions) {
        val hasAccess = state.isUnlimited || state.userBalance >= 0.01f
        if (state.autoAiSuggestions && state.selectedCategory != null && hasAccess &&
            state.chips.isEmpty() && !state.isLoadingChips && state.chipsError == null
        ) {
            viewModel.fetchSuggestions()
        }
    }

    // Reset saveSuccess without showing snackbar
    LaunchedEffect(state.saveSuccess) {
        if (state.saveSuccess) {
            kotlinx.coroutines.delay(1000)
            viewModel.resetSaveSuccess()
        }
    }

    Scaffold(
        containerColor = NotelBackground,
        topBar = {
            TopAppBar(
                title = { },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground),
                actions = { }
            )
        }
    ) { padding ->
        LazyColumn(
            modifier = Modifier
                .fillMaxSize()
                .imePadding(),
            contentPadding = PaddingValues(
                top = padding.calculateTopPadding(),
                bottom = 160.dp
            )
        ) {
            item {
                // ── Manual Text Field Moved to Top ─────────────────────────────
                val context = androidx.compose.ui.platform.LocalContext.current
                OutlinedTextField(
                    value = state.manualText,
                    onValueChange = viewModel::updateManualText,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 8.dp),
                    placeholder = { Text("Add a custom note…", color = NotelTextSecondary) },
                    trailingIcon = {
                        if (state.manualText.isNotBlank()) {
                            IconButton(onClick = viewModel::saveEntry) {
                                if (state.isSaving) {
                                    GlassySpinner(size = 20.dp)
                                } else {
                                    Icon(Icons.Default.AddCircle, null, tint = NotelPrimary)
                                }
                            }
                        } else {
                            IconButton(onClick = { 
                                context.startActivity(Intent(context, com.notel.notel.VoiceLogActivity::class.java))
                            }) {
                                Icon(Icons.Default.Mic, null, tint = NotelPrimary)
                            }
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

                // ── All Categories ──────────────────────────────────────────────
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
                    items(state.categories) { cat ->
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
            }

            item {
                // ── AI Chip Tray ──────────────────────────────────────────────
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp)
                ) {
                when {
                    !state.isUnlimited && state.userBalance < 0.01f -> NoBalancePrompt(onGoToSettings = onNavigateToSettings)
                    !state.autoAiSuggestions && state.chips.isEmpty() && !state.isLoadingChips -> {
                        Column(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                            horizontalAlignment = Alignment.CenterHorizontally
                        ) {
                            Text("No suggestions loaded", color = NotelTextSecondary, fontSize = 12.sp)
                            Spacer(Modifier.height(8.dp))
                            TextButton(onClick = { viewModel.fetchSuggestions(forceRefresh = true) }) {
                                Text("Load Suggestions", color = NotelPrimary, fontWeight = FontWeight.Bold)
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
        }

        item {
                // ── Productivity Layer / Combo Preview ────────────────────────
                AnimatedVisibility(
                    visible = state.manualText.isBlank() && state.selectedChips.isEmpty(),
                    enter = fadeIn() + expandVertically(),
                    exit = fadeOut() + shrinkVertically()
                ) {
                    var isProductivityExpanded by remember { mutableStateOf(false) }
                    Column {
                        // Removed Counter Clock / Event Bubble
                    }
                }
            }

            item {
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
            }

            item {
                Spacer(Modifier.height(12.dp))
            }

        } // Closes LazyColumn

        // ── Overlays (Placed outside scroll area) ───────────────────────

        // AI Advice Dialog
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

        // Onboarding Dialog
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

        // Free Credit Bonus Dialog
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

        // Compare Documents Dialog
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

        // ── Magical AI Bubble (Floating Action) ────────────────────────
        var isAiExpanded by remember { mutableStateOf(false) }
        
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(bottom = 120.dp, start = 24.dp), // Left side and slightly higher
            contentAlignment = Alignment.BottomStart // Moved to Left
        ) {
            Box(
                modifier = Modifier
                    .animateContentSize(
                        animationSpec = spring(
                            dampingRatio = Spring.DampingRatioLowBouncy,
                            stiffness = Spring.StiffnessLow
                        )
                    )
                    .liquidGlass(
                        shape = if (isAiExpanded) RoundedCornerShape(20.dp) else CircleShape,
                        color = NotelPrimary,
                        alpha = if (isAiExpanded) 1f else 0.8f,
                        showBorder = true
                    )
                    .clickable { isAiExpanded = !isAiExpanded }
                    .padding(if (isAiExpanded) 12.dp else 14.dp)
            ) {
                if (!isAiExpanded) {
                    Icon(
                        Icons.Default.AutoAwesome,
                        contentDescription = "AI Magic",
                        tint = Color.White,
                        modifier = Modifier.size(28.dp)
                    )
                } else {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = Modifier.wrapContentWidth()
                    ) {
                        // Expert Research Tile
                        Surface(
                            onClick = { 
                                isAiExpanded = false
                                viewModel.generateDeepResearch() 
                            },
                            color = Color.White.copy(alpha = 0.15f),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Column(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Icon(Icons.Default.TravelExplore, null, tint = Color.White, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.height(4.dp))
                                Text("Research", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                            }
                        }
                        
                        // Analyze Changes Tile
                        Surface(
                            onClick = { 
                                isAiExpanded = false
                                viewModel.compareDocuments() 
                            },
                            color = Color.White.copy(alpha = 0.15f),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Column(
                                modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Icon(Icons.Default.CompareArrows, null, tint = Color.White, modifier = Modifier.size(20.dp))
                                Spacer(Modifier.height(4.dp))
                                Text("Analyze", color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold)
                            }
                        }

                        // Close "X"
                        IconButton(
                            onClick = { isAiExpanded = false },
                            modifier = Modifier.size(32.dp)
                        ) {
                            Icon(Icons.Default.Close, null, tint = Color.White.copy(alpha = 0.5f), modifier = Modifier.size(16.dp))
                        }
                    }
                }
            }
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
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Text(
                category.name,
                color = if (isSelected) Color.White else NotelTextSecondary,
                fontSize = 13.sp,
                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Medium
            )
        }
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ChipGrid(chips: List<String>, selected: List<String>, onToggle: (String) -> Unit) {
    Column {
        FlowRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
            maxItemsInEachRow = 2
        ) {
            chips.forEach { chip ->
                val isSelected = chip in selected
                Surface(
                    onClick = { onToggle(chip) },
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
            if (chips.size % 2 != 0) {
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
