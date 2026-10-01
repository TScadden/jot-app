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
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.ExperimentalFoundationApi
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
    onNavigateToMembership: () -> Unit = {},
    onNavigateToTrends: () -> Unit,
    onNavigateToFitbit: () -> Unit,
    onNavigateToSleep: () -> Unit
) {
    val state by viewModel.uiState.collectAsState()
    val isGeneratingWeeklyRecap by viewModel.isGeneratingWeeklyRecap.collectAsState()
    val isGeneratingDeepResearch by viewModel.isGeneratingDeepResearch.collectAsState()

    val palette57 = LocalNotelPalette.current
    val activeCatColor = remember(state.selectedCategory, palette57) {
        state.selectedCategory?.let { cat ->
            try { Color(android.graphics.Color.parseColor(cat.colorHex)) } catch (e: Exception) { palette57.primary }
        } ?: palette57.primary
    }

    val voiceLogLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = androidx.activity.result.contract.ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == android.app.Activity.RESULT_OK) {
            val msg = result.data?.getStringExtra("VOICE_LOG_MESSAGE") ?: "Voice entry logged"
            viewModel.onVoiceEntryLogged(msg)
        }
    }
    // if the "Auto Ping" (autoAiSuggestions) setting is turned ON.
    LaunchedEffect(state.selectedCategory, state.isUnlimited, state.autoAiSuggestions) {
        val hasAccess = state.isUnlimited
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
                title = {
                    Text(
                        "Quick Log",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground),
                actions = {
                    IconButton(onClick = onNavigateToTrends) {
                        Icon(
                            imageVector = Icons.Default.TrendingUp,
                            contentDescription = "Trends",
                            tint = NotelTextSecondary
                        )
                    }
                    IconButton(onClick = onNavigateToHistory) {
                        Icon(
                            imageVector = Icons.Default.History,
                            contentDescription = "History",
                            tint = NotelTextSecondary
                        )
                    }
                }
            )
        }
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = padding.calculateTopPadding())
        ) {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .imePadding(),
                contentPadding = PaddingValues(
                    top = 8.dp,
                    bottom = 180.dp
                )
            ) {
                item {
                    TodaySummaryStrip(
                        count = state.todayEntryCount,
                        onOpenHistory = onNavigateToHistory
                    )
                }

                item {
                    // ── Manual Text Field ─────────────────────────────
                    val context = androidx.compose.ui.platform.LocalContext.current

                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        val hasTypedText = state.manualText.trim().isNotBlank()
                        OutlinedTextField(
                            value = state.manualText,
                            onValueChange = viewModel::updateManualText,
                            modifier = Modifier.weight(1f),
                            placeholder = { Text("Add optional details about these symptoms…", color = NotelTextSecondary, fontSize = 13.sp) },
                            trailingIcon = {
                                AnimatedContent(
                                    targetState = state.isSaving to hasTypedText,
                                    transitionSpec = { fadeIn() togetherWith fadeOut() },
                                    label = "TrailingIconTransition"
                                ) { (isSaving, isTyped) ->
                                    if (isSaving) {
                                        Box(
                                            modifier = Modifier
                                                .size(48.dp),
                                            contentAlignment = Alignment.Center
                                        ) {
                                            CircularProgressIndicator(
                                                modifier = Modifier.size(18.dp),
                                                color = activeCatColor,
                                                strokeWidth = 2.dp
                                            )
                                        }
                                    } else if (isTyped) {
                                        IconButton(
                                            onClick = { viewModel.saveEntry() },
                                            modifier = Modifier.size(48.dp)
                                        ) {
                                            Icon(
                                                imageVector = Icons.Default.Add,
                                                contentDescription = "Log typed note",
                                                tint = activeCatColor
                                            )
                                        }
                                    } else {
                                        IconButton(
                                            onClick = {
                                                voiceLogLauncher.launch(Intent(context, com.notel.notel.VoiceLogActivity::class.java))
                                            },
                                            modifier = Modifier.size(48.dp)
                                        ) {
                                            Icon(
                                                imageVector = Icons.Default.Mic,
                                                contentDescription = "Voice Input",
                                                tint = activeCatColor
                                            )
                                        }
                                    }
                                }
                            },
                            shape = RoundedCornerShape(16.dp),
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = activeCatColor,
                                unfocusedBorderColor = activeCatColor.copy(alpha = 0.25f),
                                focusedTextColor = NotelTextPrimary,
                                unfocusedTextColor = NotelTextPrimary,
                                cursorColor = activeCatColor,
                                unfocusedContainerColor = NotelSurface,
                                focusedContainerColor = NotelSurface
                            )
                        )

                        IconButton(
                            onClick = { viewModel.repeatLastEntry() },
                            modifier = Modifier
                                .size(48.dp)
                                .clip(RoundedCornerShape(14.dp))
                                .background(NotelSurface)
                                .border(1.dp, NotelPrimary.copy(alpha = 0.25f), RoundedCornerShape(14.dp))
                        ) {
                            Icon(Icons.Default.Replay, contentDescription = "Repeat Last Entry", tint = NotelPrimary)
                        }
                    }

                    // ── All Categories ──────────────────────────────────────────────
                    Text(
                        "Categories",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary,
                        modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp)
                    )
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 6.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(state.categories, key = { it.stableKey }) { cat ->
                            CategoryChip(
                                category = cat,
                                isSelected = cat.id == state.selectedCategory?.id,
                                onClick = { viewModel.selectCategory(cat) },
                                onLongClick = if (cat.stableKey != "general" && !cat.isDefault) { { viewModel.requestDeleteCategory(cat) } } else null
                            )
                        }
                        item {
                            Box(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(NotelSurface)
                                    .border(
                                        width = 1.dp,
                                        color = NotelPrimary.copy(alpha = 0.25f),
                                        shape = RoundedCornerShape(12.dp)
                                    )
                                    .clickable { viewModel.showAddCategoryDialog() }
                                    .padding(horizontal = 16.dp, vertical = 10.dp)
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(Icons.Default.Add, null, tint = NotelPrimary, modifier = Modifier.size(16.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text(
                                        text = "Add",
                                        color = NotelTextSecondary,
                                        fontSize = 12.sp,
                                        fontWeight = FontWeight.Bold
                                    )
                                }
                            }
                        }
                    }

                    // ── Recent Suggestions Drawer ───────────────────────────────────────
                    if (state.recentSuggestions.isNotEmpty()) {
                        SectionLabel(
                            text = "Recent suggestions",
                            modifier = Modifier.padding(start = 16.dp, top = 8.dp, bottom = 4.dp)
                        )
                        LazyRow(
                            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                            horizontalArrangement = Arrangement.spacedBy(8.dp)
                        ) {
                            items(state.recentSuggestions) { entry ->
                                Box(
                                    modifier = Modifier
                                        .clip(RoundedCornerShape(12.dp))
                                        .background(NotelSurfaceHigh)
                                        .border(1.dp, NotelSurfaceHigh.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
                                        .clickable { viewModel.logFromRecent(entry) }
                                        .padding(horizontal = 12.dp, vertical = 8.dp)
                                ) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Icon(Icons.Default.History, null, tint = NotelTextSecondary, modifier = Modifier.size(14.dp))
                                        Spacer(Modifier.width(6.dp))
                                        Text(entry.body.take(25), color = NotelTextPrimary, fontSize = 12.sp)
                                    }
                                }
                            }
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
                            !state.isUnlimited -> Column(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text("Standard Access", color = NotelTextSecondary, fontSize = 14.sp, fontWeight = FontWeight.Bold)
                                Spacer(Modifier.height(8.dp))
                                TextButton(onClick = onNavigateToMembership) {
                                    Text("Click here to start Free Trial", color = NotelPrimary, fontWeight = FontWeight.Bold)
                                }
                            }
                            state.isLoadingChips -> Box(Modifier.fillMaxWidth().padding(vertical = 32.dp), contentAlignment = Alignment.Center) {
                                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                    GlassySpinner(size = 48.dp)
                                    Spacer(Modifier.height(12.dp))
                                    Text("Getting suggestions…", color = NotelTextSecondary, fontSize = 14.sp)
                                }
                            }
                            state.chipsError != null -> Column(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text(state.chipsError!!, color = MaterialTheme.colorScheme.error, fontSize = 13.sp, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                                Spacer(Modifier.height(12.dp))
                                TextButton(onClick = { viewModel.fetchSuggestions(forceRefresh = true) }) {
                                    Text("Retry", color = NotelPrimary, fontWeight = FontWeight.Bold)
                                }
                            }
                            !state.autoAiSuggestions && state.chips.isEmpty() -> Column(
                                modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text("No suggestions loaded", color = NotelTextSecondary, fontSize = 12.sp)
                                Spacer(Modifier.height(8.dp))
                                TextButton(onClick = { viewModel.fetchSuggestions(forceRefresh = true) }) {
                                    Text("Load Suggestions", color = NotelPrimary, fontWeight = FontWeight.Bold)
                                }
                            }
                            else -> ChipGrid(
                                chips = state.chips,
                                selected = state.selectedChips,
                                categoryColor = activeCatColor,
                                onToggle = viewModel::toggleChip
                            )
                        }
                    }
                }

                item {
                    AnimatedVisibility(
                        visible = state.selectedChips.isNotEmpty() || state.manualText.trim().isNotBlank() || state.saveError != null,
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
                                Column(modifier = Modifier.fillMaxWidth()) {
                                    // Card Header Row: Label on left, compact Log button on top-right
                                    Row(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalArrangement = Arrangement.SpaceBetween,
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Text(
                                            text = "Your quick note",
                                            style = MaterialTheme.typography.labelSmall,
                                            color = NotelTextSecondary
                                        )

                                        Button(
                                            onClick = { viewModel.saveEntry() },
                                            enabled = state.isLogEnabled,
                                            modifier = Modifier
                                                .widthIn(min = 72.dp)
                                                .height(48.dp),
                                            shape = RoundedCornerShape(Radii.chip),
                                            contentPadding = PaddingValues(horizontal = 16.dp, vertical = 0.dp),
                                            colors = ButtonDefaults.buttonColors(
                                                containerColor = activeCatColor,
                                                disabledContainerColor = activeCatColor.copy(alpha = 0.35f),
                                                contentColor = NotelOnAccent,
                                                disabledContentColor = NotelOnAccent.copy(alpha = 0.5f)
                                            )
                                        ) {
                                            if (state.isSaving) {
                                                CircularProgressIndicator(
                                                    modifier = Modifier.size(16.dp),
                                                    color = NotelOnAccent,
                                                    strokeWidth = 2.dp
                                                )
                                            } else {
                                                Row(
                                                    verticalAlignment = Alignment.CenterVertically,
                                                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                                                ) {
                                                    Icon(
                                                        imageVector = Icons.Default.Check,
                                                        contentDescription = null,
                                                        modifier = Modifier.size(14.dp),
                                                        tint = NotelOnAccent
                                                    )
                                                    Text(
                                                        text = "Log",
                                                        fontSize = 13.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                }
                                            }
                                        }
                                    }

                                    Spacer(modifier = Modifier.height(8.dp))

                                    // Full available width composed phrase
                                    Text(
                                        text = buildString {
                                            if (state.composedText.isNotBlank()) append(state.composedText)
                                            if (state.manualText.isNotBlank()) {
                                                if (isNotEmpty()) append(" · ")
                                                append(state.manualText.trim())
                                            }
                                        },
                                        style = MaterialTheme.typography.bodyLarge,
                                        color = NotelTextPrimary,
                                        fontWeight = FontWeight.Medium,
                                        modifier = Modifier.fillMaxWidth()
                                    )

                                    if (state.saveError != null) {
                                        Spacer(modifier = Modifier.height(8.dp))
                                        Text(
                                            text = state.saveError!!,
                                            color = MaterialTheme.colorScheme.error,
                                            fontSize = 12.sp,
                                            fontWeight = FontWeight.Medium
                                        )
                                    }
                                }
                            }
                            Spacer(Modifier.height(16.dp))
                        }
                    }
                }

                item {
                    Spacer(Modifier.height(12.dp))
                }

            } // Closes LazyColumn
        }

        // ── Overlays (Placed outside scroll area) ───────────────────────

        // AI Advice Dialog
        if (state.showAdviceDialog) {
            Dialog(onDismissRequest = { viewModel.dismissAdvice() }) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                        .clip(RoundedCornerShape(Radii.dialog))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.18f), RoundedCornerShape(Radii.dialog))
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
                                Text("Analyzing your recent entries…", color = NotelTextSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
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
                title = { Text("Welcome to Tabs!", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                text = { 
                    Text(
                        "Tabs makes tracking your health simple. Pick a category, build an entry with AI suggestions, or write your own note. Tap Trends to see patterns over time!", 
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

        // Compare Documents Dialog
        if (state.showComparisonDialog) {
            Dialog(onDismissRequest = { viewModel.dismissComparison() }) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                        .clip(RoundedCornerShape(Radii.dialog))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.18f), RoundedCornerShape(Radii.dialog))
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

        // Delete Category Confirmation Dialog
        state.categoryToDelete?.let { category ->
            AlertDialog(
                onDismissRequest = { viewModel.dismissDeleteConfirmation() },
                title = { Text("Delete Subject?", color = NotelTextPrimary) },
                text = { Text("Are you sure you want to delete '${category.name}'? This will remove the subject from your quick logging list.", color = NotelTextSecondary) },
                confirmButton = {
                    TextButton(onClick = { viewModel.confirmDeleteCategory() }) {
                        Text("Delete", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { viewModel.dismissDeleteConfirmation() }) {
                        Text("Cancel", color = NotelTextPrimary)
                    }
                },
                containerColor = NotelSurface,
                shape = RoundedCornerShape(16.dp)
            )
        }

        // Add Category AI Dialog
        if (state.showAddCategoryDialog) {
            Dialog(onDismissRequest = { viewModel.dismissAddCategory() }) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                        .clip(RoundedCornerShape(Radii.dialog))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.18f), RoundedCornerShape(Radii.dialog))
                        .padding(24.dp),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(22.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("New Category Ideas", fontWeight = FontWeight.Bold, fontSize = 18.sp, color = NotelTextPrimary)
                        }
                        Spacer(Modifier.height(8.dp))
                        Text(
                            "AI analyzed your notes to find new tracking opportunities.",
                            color = NotelTextSecondary,
                            fontSize = 13.sp,
                            textAlign = TextAlign.Center
                        )
                        Spacer(Modifier.height(16.dp))
                        
                        // Manual Entry Field
                        OutlinedTextField(
                            value = state.customCategoryName,
                            onValueChange = viewModel::updateCustomCategoryName,
                            placeholder = { Text("Or type your own...", color = NotelTextSecondary, fontSize = 14.sp) },
                            modifier = Modifier.fillMaxWidth(),
                            trailingIcon = {
                                if (state.isValidatingCategory) {
                                    CircularProgressIndicator(modifier = Modifier.size(20.dp), color = NotelPrimary, strokeWidth = 2.dp)
                                } else if (state.customCategoryName.isNotBlank()) {
                                    IconButton(onClick = viewModel::addCustomCategory) {
                                        Icon(Icons.Default.Check, null, tint = NotelPrimary)
                                    }
                                }
                            },
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = NotelPrimary,
                                unfocusedBorderColor = NotelPrimary.copy(alpha = 0.3f),
                                cursorColor = NotelPrimary,
                                focusedTextColor = NotelTextPrimary,
                                unfocusedTextColor = NotelTextPrimary
                            ),
                            shape = RoundedCornerShape(12.dp),
                            singleLine = true
                        )
                        
                        Spacer(Modifier.height(16.dp))
                        
                        when {
                            state.isLoadingSuggestions -> {
                                GlassySpinner(size = 48.dp)
                                Spacer(Modifier.height(12.dp))
                                Text("Analyzing your notes…", color = NotelTextSecondary, fontSize = 14.sp, textAlign = TextAlign.Center)
                            }
                            state.suggestionsError != null -> {
                                Text(state.suggestionsError!!, color = MaterialTheme.colorScheme.error, fontSize = 14.sp, textAlign = TextAlign.Center)
                                Spacer(Modifier.height(12.dp))
                                GlassyButton(onClick = { viewModel.loadSmartCategorySuggestions() }) { Text("Retry") }
                            }
                            state.suggestedCategories.isNotEmpty() -> {
                                Column(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .heightIn(max = 350.dp)
                                        .verticalScroll(rememberScrollState())
                                ) {
                                    @OptIn(ExperimentalLayoutApi::class)
                                    FlowRow(
                                        modifier = Modifier.fillMaxWidth(),
                                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                                        verticalArrangement = Arrangement.spacedBy(8.dp)
                                    ) {
                                        state.suggestedCategories.forEach { suggestion ->
                                            val name = suggestion.category ?: "Unknown"
                                            val isSelected = name in state.selectedSuggestedCategories
                                            Box(
                                                modifier = Modifier
                                                    .clip(RoundedCornerShape(14.dp))
                                                    .background(if (isSelected) NotelPrimary else NotelSurface)
                                                    .border(
                                                        width = 1.dp,
                                                        color = if (isSelected) NotelPrimary else NotelPrimary.copy(alpha = 0.20f),
                                                        shape = RoundedCornerShape(14.dp)
                                                    )
                                                    .clickable { viewModel.toggleSuggestedCategory(name) }
                                                    .padding(horizontal = 14.dp, vertical = 10.dp)
                                            ) {
                                                Column {
                                                    Text(
                                                        text = name,
                                                        color = if (isSelected) NotelOnAccent else NotelTextPrimary,
                                                        fontSize = 14.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                    if (suggestion.reason != null) {
                                                        Text(
                                                            text = suggestion.reason!!,
                                                            color = if (isSelected) NotelOnAccent.copy(alpha = 0.8f) else NotelTextSecondary,
                                                            fontSize = 11.sp,
                                                            lineHeight = 14.sp
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                            else -> {
                                Column(
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    modifier = Modifier.padding(vertical = 12.dp)
                                ) {
                                    Text(
                                        "Want personalized tracking subjects?",
                                        color = NotelTextSecondary,
                                        fontSize = 13.sp,
                                        textAlign = TextAlign.Center
                                    )
                                    Spacer(Modifier.height(12.dp))
                                    GlassyButton(
                                        onClick = { viewModel.loadSmartCategorySuggestions() },
                                        containerColor = NotelPrimary.copy(alpha = 0.2f),
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Icon(Icons.Default.AutoAwesome, null, tint = NotelPrimary, modifier = Modifier.size(16.dp))
                                        Spacer(Modifier.width(8.dp))
                                        Text("Generate AI Category Ideas", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                                    }
                                }
                            }
                        }
                        
                        Spacer(Modifier.height(24.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            GlassyButton(
                                onClick = { viewModel.dismissAddCategory() },
                                modifier = Modifier.weight(1f),
                                containerColor = NotelSurfaceHigh
                            ) { Text("Cancel", color = NotelTextPrimary) }
                            
                            if (state.selectedSuggestedCategories.isNotEmpty()) {
                                GlassyButton(
                                    onClick = { viewModel.addSelectedCategories() },
                                    modifier = Modifier.weight(1f),
                                    containerColor = NotelPrimary
                                ) { Text("Add Subject", color = NotelOnAccent) }
                            }
                        }
                    }
                }
            }
        }

    }
}

/**
 * Proactive "Today so far" summary strip: shows today's log count at the top of
 * Quick Log and taps through to History. Pure local data, no network.
 */
@Composable
private fun TodaySummaryStrip(
    count: Int,
    onOpenHistory: () -> Unit
) {
    val countText = when (count) {
        0 -> "No entries yet today"
        1 -> "1 entry logged today"
        else -> "$count entries logged today"
    }
    Surface(
        onClick = onOpenHistory,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp),
        shape = RoundedCornerShape(16.dp),
        color = NotelPrimary.copy(alpha = 0.08f),
        border = androidx.compose.foundation.BorderStroke(1.dp, NotelPrimary.copy(alpha = 0.18f))
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp)
        ) {
            Icon(
                imageVector = Icons.Default.Today,
                contentDescription = null,
                tint = NotelPrimary,
                modifier = Modifier.size(20.dp)
            )
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    "Today so far",
                    color = NotelTextPrimary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold
                )
                Text(
                    countText,
                    color = NotelTextSecondary,
                    fontSize = 12.sp
                )
            }
            Icon(
                imageVector = Icons.Default.ChevronRight,
                contentDescription = "View history",
                tint = NotelTextSecondary,
                modifier = Modifier.size(20.dp)
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun CategoryChip(category: Category, isSelected: Boolean, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
    val palette807 = LocalNotelPalette.current
    val catColor = remember(category, palette807) {
        try { Color(android.graphics.Color.parseColor(category.colorHex)) }
        catch (e: Exception) { palette807.primary }
    }
    Box(
        modifier = Modifier
            .clip(RoundedCornerShape(Radii.chip))
            .background(if (isSelected) catColor else NotelSurface)
            .border(
                width = 1.dp,
                color = if (isSelected) catColor else catColor.copy(alpha = 0.35f),
                shape = RoundedCornerShape(Radii.chip)
            )
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick
            )
            .padding(horizontal = 16.dp, vertical = 8.dp)
    ) {
        Text(
            text = category.name,
            color = if (isSelected) LegacyDarkChipInk else NotelTextSecondary,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold
        )
    }
}

@OptIn(ExperimentalLayoutApi::class)
@Composable
private fun ChipGrid(
    chips: List<String>,
    selected: List<String>,
    categoryColor: Color,
    onToggle: (String) -> Unit
) {
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
                val chipBg = if (isSelected) categoryColor else NotelSurface
                val chipBorder = if (isSelected) categoryColor else categoryColor.copy(alpha = 0.25f)
                Box(
                    modifier = Modifier
                        .weight(1f)
                        .animateContentSize()
                        .clip(RoundedCornerShape(Radii.chip))
                        .background(chipBg)
                        .border(
                            width = 1.dp,
                            color = chipBorder,
                            shape = RoundedCornerShape(Radii.chip)
                        )
                        .clickable { onToggle(chip) }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                ) {
                    Text(
                        text = chip,
                        color = if (isSelected) NotelOnAccent else NotelTextPrimary,
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
private fun SmartActionCard(
    action: com.notel.notel.ui.viewmodel.SmartAction,
    onDismiss: () -> Unit,
    onAccept: () -> Unit
) {
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(Radii.card))
            .background(NotelSurface)
            .border(1.dp, NotelPrimary.copy(alpha = 0.22f), RoundedCornerShape(Radii.card))
    ) {
        // Left accent strip
        Box(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .width(4.dp)
                .fillMaxHeight()
                .background(NotelPrimary, RoundedCornerShape(topStart = Radii.card, bottomStart = Radii.card))
        )
        Column(modifier = Modifier.padding(start = 16.dp, end = 12.dp, top = 14.dp, bottom = 14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    modifier = Modifier
                        .size(32.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(NotelPrimary.copy(alpha = 0.12f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Default.Lightbulb, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(10.dp))
                Text(action.title, style = MaterialTheme.typography.titleMedium, color = NotelPrimary, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss, modifier = Modifier.size(24.dp)) {
                    Icon(Icons.Default.Close, contentDescription = "Dismiss", tint = NotelTextSecondary, modifier = Modifier.size(14.dp))
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
