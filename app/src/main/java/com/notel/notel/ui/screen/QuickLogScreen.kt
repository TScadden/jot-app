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
    onNavigateToSleep: () -> Unit,
    onNavigateToBodyLoad: () -> Unit = {}
) {
    val state by viewModel.uiState.collectAsState()
    val isGeneratingWeeklyRecap by viewModel.isGeneratingWeeklyRecap.collectAsState()
    val isGeneratingDeepResearch by viewModel.isGeneratingDeepResearch.collectAsState()

    val activeCatColor = remember(state.selectedCategory) {
        state.selectedCategory?.let { cat ->
            try { Color(android.graphics.Color.parseColor(cat.colorHex)) } catch (e: Exception) { NotelPrimary }
        } ?: NotelPrimary
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
                        "Home",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground),
                actions = {
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
                // ── Manual Text Field ─────────────────────────────
                val context = androidx.compose.ui.platform.LocalContext.current

                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 16.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    OutlinedTextField(
                        value = state.manualText,
                        onValueChange = viewModel::updateManualText,
                        modifier = Modifier.weight(1f),
                        placeholder = { Text("Universal Quick-Add (e.g. 200mg Advil, 6/10 headache)…", color = NotelTextSecondary, fontSize = 13.sp) },
                        trailingIcon = {
                            if (state.manualText.isNotBlank()) {
                                IconButton(onClick = { viewModel.parseAndShowProposals() }) {
                                    Icon(Icons.Default.AutoAwesome, "Parse Input", tint = activeCatColor)
                                }
                            } else {
                                IconButton(onClick = {
                                    voiceLogLauncher.launch(Intent(context, com.notel.notel.VoiceLogActivity::class.java))
                                }) {
                                    Icon(Icons.Default.Mic, null, tint = activeCatColor)
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
                    items(state.categories) { cat ->
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
                                    text = "ADD",
                                    color = NotelTextSecondary,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold,
                                    letterSpacing = 0.5.sp
                                )
                            }
                        }
                    }
                }

                // ── Pinned Templates Drawer ─────────────────────────────────────────
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 4.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        "PINNED TEMPLATES",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelPrimary,
                        letterSpacing = 0.5.sp
                    )
                    IconButton(
                        onClick = { viewModel.openTemplateManager() },
                        modifier = Modifier.size(24.dp)
                    ) {
                        Icon(
                            if (state.pinnedTemplates.isEmpty()) Icons.Default.Add else Icons.Default.Tune,
                            contentDescription = if (state.pinnedTemplates.isEmpty()) "Create Template" else "Manage Templates",
                            tint = NotelPrimary,
                            modifier = Modifier.size(16.dp)
                        )
                    }
                }
                if (state.pinnedTemplates.isNotEmpty()) {
                    LazyRow(
                        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(state.pinnedTemplates) { t ->
                            Box(
                                modifier = Modifier
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(NotelSurface)
                                    .border(1.dp, NotelPrimary.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
                                    .clickable { viewModel.logFromTemplate(t) }
                                    .padding(horizontal = 14.dp, vertical = 8.dp)
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        if (t.isMedication) Icons.Default.Medication else Icons.Default.PushPin,
                                        null,
                                        tint = NotelPrimary,
                                        modifier = Modifier.size(14.dp)
                                    )
                                    Spacer(Modifier.width(6.dp))
                                    Text(t.title, color = NotelTextPrimary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                                }
                            }
                        }
                    }
                } else {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp)
                            .clip(RoundedCornerShape(14.dp))
                            .background(NotelSurface)
                            .border(1.dp, NotelPrimary.copy(alpha = 0.15f), RoundedCornerShape(14.dp))
                            .padding(horizontal = 14.dp, vertical = 10.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            "Save common entries for one-tap logging.",
                            color = NotelTextSecondary,
                            fontSize = 12.sp,
                            modifier = Modifier.weight(1f)
                        )
                        Spacer(Modifier.width(8.dp))
                        Box(
                            modifier = Modifier
                                .clip(RoundedCornerShape(8.dp))
                                .background(NotelPrimary.copy(alpha = 0.15f))
                                .clickable { viewModel.openCreateTemplateDialog() }
                                .padding(horizontal = 10.dp, vertical = 6.dp)
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Add, null, tint = NotelPrimary, modifier = Modifier.size(12.dp))
                                Spacer(Modifier.width(4.dp))
                                Text(
                                    "Create template",
                                    color = NotelPrimary,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                        }
                    }
                }

                // ── Recent Suggestions Drawer ───────────────────────────────────────
                if (state.recentSuggestions.isNotEmpty()) {
                    Text(
                        "RECENT SUGGESTIONS",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextSecondary,
                        modifier = Modifier.padding(start = 16.dp, top = 8.dp, bottom = 4.dp),
                        letterSpacing = 0.5.sp
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
                        .clip(RoundedCornerShape(22.dp))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.18f), RoundedCornerShape(22.dp))
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
                        .clip(RoundedCornerShape(22.dp))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.18f), RoundedCornerShape(22.dp))
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
                        .clip(RoundedCornerShape(22.dp))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.18f), RoundedCornerShape(22.dp))
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
                                                        color = if (isSelected) Color.White else NotelTextPrimary,
                                                        fontSize = 14.sp,
                                                        fontWeight = FontWeight.Bold
                                                    )
                                                    if (suggestion.reason != null) {
                                                        Text(
                                                            text = suggestion.reason!!,
                                                            color = if (isSelected) Color.White.copy(alpha = 0.8f) else NotelTextSecondary,
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
                                ) { Text("Add Subject", color = Color.White) }
                            }
                        }
                    }
                }
            }
        }

        // Proposal Confirmation Dialog
        if (state.showProposalConfirmation) {
            Dialog(onDismissRequest = { viewModel.dismissProposals() }) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                        .clip(RoundedCornerShape(22.dp))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.2f), RoundedCornerShape(22.dp))
                        .padding(20.dp)
                ) {
                    Column {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(22.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Confirm Parsed Proposals", fontWeight = FontWeight.Bold, fontSize = 18.sp, color = NotelTextPrimary)
                        }
                        Spacer(Modifier.height(12.dp))
                        Text(
                            "Review and adjust the extracted entry items before saving:",
                            color = NotelTextSecondary,
                            fontSize = 13.sp
                        )
                        Spacer(Modifier.height(16.dp))

                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .heightIn(max = 300.dp)
                                .verticalScroll(rememberScrollState()),
                            verticalArrangement = Arrangement.spacedBy(10.dp)
                        ) {
                            state.proposals.forEachIndexed { index, proposal ->
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clip(RoundedCornerShape(12.dp))
                                        .background(NotelSurfaceHigh)
                                        .padding(12.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            text = proposal.intent.name,
                                            fontWeight = FontWeight.Bold,
                                            fontSize = 12.sp,
                                            color = NotelPrimary
                                        )
                                        Spacer(Modifier.height(2.dp))
                                        Text(
                                            text = proposal.summaryText,
                                            fontSize = 14.sp,
                                            color = NotelTextPrimary
                                        )
                                    }
                                    IconButton(onClick = { viewModel.removeProposal(index) }) {
                                        Icon(Icons.Default.Close, contentDescription = "Remove item", tint = NotelTextSecondary, modifier = Modifier.size(18.dp))
                                    }
                                }
                            }
                        }

                        Spacer(Modifier.height(20.dp))
                        Column(
                            verticalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            GlassyButton(
                                onClick = { viewModel.confirmProposals() },
                                modifier = Modifier.fillMaxWidth(),
                                containerColor = NotelPrimary,
                                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 12.dp)
                            ) {
                                Text("Confirm & Save", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                            }
                            
                            Row(
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                GlassyButton(
                                    onClick = { viewModel.dismissProposals() },
                                    modifier = Modifier.weight(1f),
                                    containerColor = NotelSurfaceHigh,
                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp)
                                ) {
                                    Text("Cancel", color = NotelTextPrimary, fontSize = 13.sp, maxLines = 1)
                                }

                                GlassyButton(
                                    onClick = {
                                        viewModel.saveProposalsAsTemplates()
                                        viewModel.confirmProposals()
                                    },
                                    modifier = Modifier.weight(1.4f),
                                    containerColor = NotelSurfaceHigh,
                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 10.dp)
                                ) {
                                    Text("Save + Template", color = NotelPrimary, fontSize = 13.sp, fontWeight = FontWeight.Bold, maxLines = 1)
                                }
                            }
                        }
                    }
                }
            }
        }

        // ── Template Management Dialog ──────────────────────────────────────
        if (state.showTemplateManagementDialog) {
            Dialog(onDismissRequest = { viewModel.closeTemplateManager() }) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                        .clip(RoundedCornerShape(22.dp))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.2f), RoundedCornerShape(22.dp))
                        .padding(20.dp)
                ) {
                    Column {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Tune, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(22.dp))
                            Spacer(Modifier.width(8.dp))
                            Text("Manage Pinned Templates", fontWeight = FontWeight.Bold, fontSize = 18.sp, color = NotelTextPrimary)
                        }
                        Spacer(Modifier.height(16.dp))

                        if (state.pinnedTemplates.isEmpty()) {
                            Text("Save common entries for one-tap logging.", color = NotelTextSecondary, fontSize = 14.sp)
                            Spacer(Modifier.height(12.dp))
                            GlassyButton(
                                onClick = { viewModel.openCreateTemplateDialog() },
                                modifier = Modifier.fillMaxWidth(),
                                containerColor = NotelPrimary.copy(alpha = 0.2f)
                            ) {
                                Icon(Icons.Default.Add, null, tint = NotelPrimary, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Create Template", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                            }
                        } else {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .heightIn(max = 300.dp)
                                    .verticalScroll(rememberScrollState()),
                                verticalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                state.pinnedTemplates.forEach { t ->
                                    Row(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .clip(RoundedCornerShape(12.dp))
                                            .background(NotelSurfaceHigh)
                                            .padding(10.dp),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Icon(
                                            if (t.isMedication) Icons.Default.Medication else Icons.Default.PushPin,
                                            null,
                                            tint = NotelPrimary,
                                            modifier = Modifier.size(16.dp)
                                        )
                                        Spacer(Modifier.width(8.dp))
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(t.title, color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                                            Text(t.body, color = NotelTextSecondary, fontSize = 11.sp, maxLines = 1)
                                        }
                                        IconButton(onClick = { viewModel.reorderTemplate(t, moveUp = true) }, modifier = Modifier.size(24.dp)) {
                                            Icon(Icons.Default.KeyboardArrowUp, "Move Up", tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                                        }
                                        IconButton(onClick = { viewModel.reorderTemplate(t, moveUp = false) }, modifier = Modifier.size(24.dp)) {
                                            Icon(Icons.Default.KeyboardArrowDown, "Move Down", tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                                        }
                                        IconButton(onClick = { viewModel.openEditTemplate(t) }, modifier = Modifier.size(24.dp)) {
                                            Icon(Icons.Default.Edit, "Edit", tint = NotelPrimary, modifier = Modifier.size(16.dp))
                                        }
                                        IconButton(onClick = { viewModel.requestDeleteTemplate(t) }, modifier = Modifier.size(24.dp)) {
                                            Icon(Icons.Default.Delete, "Delete", tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(16.dp))
                                        }
                                    }
                                }
                            }
                            Spacer(Modifier.height(12.dp))
                            GlassyButton(
                                onClick = { viewModel.openCreateTemplateDialog() },
                                modifier = Modifier.fillMaxWidth(),
                                containerColor = NotelPrimary.copy(alpha = 0.2f)
                            ) {
                                Icon(Icons.Default.Add, null, tint = NotelPrimary, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Add New Template", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                            }
                        }

                        Spacer(Modifier.height(20.dp))
                        GlassyButton(
                            onClick = { viewModel.closeTemplateManager() },
                            modifier = Modifier.fillMaxWidth(),
                            containerColor = NotelSurfaceHigh
                        ) { Text("Close", color = NotelTextPrimary) }
                    }
                }
            }
        }

        // ── Template Edit / Create Dialog ──────────────────────────────────
        if (state.showTemplateEditDialog && state.templateToEdit != null) {
            val template = state.templateToEdit!!
            val isNew = template.id == 0L
            var titleText by remember(template) { mutableStateOf(template.title) }
            var bodyText by remember(template) { mutableStateOf(template.body) }
            var isMed by remember(template) { mutableStateOf(template.isMedication) }

            Dialog(onDismissRequest = { viewModel.closeTemplateManager() }) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                        .clip(RoundedCornerShape(22.dp))
                        .background(NotelSurface)
                        .border(1.dp, NotelPrimary.copy(alpha = 0.2f), RoundedCornerShape(22.dp))
                        .padding(20.dp)
                ) {
                    Column {
                        Text(if (isNew) "Create Template" else "Edit Template", fontWeight = FontWeight.Bold, fontSize = 18.sp, color = NotelTextPrimary)
                        Spacer(Modifier.height(12.dp))
                        OutlinedTextField(
                            value = titleText,
                            onValueChange = { titleText = it },
                            label = { Text("Title", color = NotelTextSecondary) },
                            modifier = Modifier.fillMaxWidth(),
                            singleLine = true
                        )
                        Spacer(Modifier.height(8.dp))
                        OutlinedTextField(
                            value = bodyText,
                            onValueChange = { bodyText = it },
                            label = { Text("Body Text", color = NotelTextSecondary) },
                            modifier = Modifier.fillMaxWidth()
                        )
                        Spacer(Modifier.height(8.dp))
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(checked = isMed, onCheckedChange = { isMed = it })
                            Text("Requires Medication Confirmation", color = NotelTextPrimary, fontSize = 12.sp, fontWeight = FontWeight.SemiBold)
                        }
                        Text(
                            "When enabled, tapping this template opens a confirmation dialog to verify dosage before saving instead of logging instantly.",
                            color = NotelTextSecondary,
                            fontSize = 11.sp,
                            modifier = Modifier.padding(start = 32.dp, top = 2.dp)
                        )
                        Spacer(Modifier.height(16.dp))
                        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            GlassyButton(
                                onClick = { viewModel.closeTemplateManager() },
                                modifier = Modifier.weight(1f),
                                containerColor = NotelSurfaceHigh
                            ) { Text("Cancel", color = NotelTextPrimary) }

                            GlassyButton(
                                onClick = { viewModel.saveEditedTemplate(titleText, bodyText, template.categorySlug, isMed) },
                                modifier = Modifier.weight(1f),
                                containerColor = NotelPrimary
                            ) { Text(if (isNew) "Create" else "Save Changes", color = Color.White, fontWeight = FontWeight.Bold) }
                        }
                    }
                }
            }
        }

        // ── Delete Template Confirmation Dialog ─────────────────────────────
        state.templateToDelete?.let { template ->
            AlertDialog(
                onDismissRequest = { viewModel.dismissDeleteTemplate() },
                title = { Text("Delete Template?", color = NotelTextPrimary) },
                text = { Text("Are you sure you want to delete template '${template.title}'? This will not delete historical log entries.", color = NotelTextSecondary) },
                confirmButton = {
                    TextButton(onClick = { viewModel.confirmDeleteTemplate() }) {
                        Text("Delete", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold)
                    }
                },
                dismissButton = {
                    TextButton(onClick = { viewModel.dismissDeleteTemplate() }) {
                        Text("Cancel", color = NotelTextPrimary)
                    }
                },
                containerColor = NotelSurface,
                shape = RoundedCornerShape(16.dp)
            )
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun CategoryChip(category: Category, isSelected: Boolean, onClick: () -> Unit, onLongClick: (() -> Unit)? = null) {
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
            .combinedClickable(
                onClick = onClick,
                onLongClick = onLongClick
            )
            .padding(horizontal = 16.dp, vertical = 8.dp)
    ) {
        Text(
            text = category.name.uppercase(),
            color = if (isSelected) Color(0xFF0A0A0E) else NotelTextSecondary,
            fontSize = 12.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.8.sp
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
                        .clip(RoundedCornerShape(16.dp))
                        .background(chipBg)
                        .border(
                            width = 1.dp,
                            color = chipBorder,
                            shape = RoundedCornerShape(16.dp)
                        )
                        .clickable { onToggle(chip) }
                        .padding(horizontal = 14.dp, vertical = 12.dp)
                ) {
                    Text(
                        text = chip,
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
    val hasAnyLogs = sortedDates.isNotEmpty()
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

    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp)
            .clip(RoundedCornerShape(20.dp))
            .background(NotelSurface)
            .border(1.dp, NotelPrimary.copy(alpha = 0.15f), RoundedCornerShape(20.dp))
            .padding(16.dp)
            .animateContentSize()
    ) {
        Column {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onExpandedChange(!isExpanded) }
            ) {
                Box(
                    modifier = Modifier
                        .size(34.dp)
                        .clip(RoundedCornerShape(10.dp))
                        .background(NotelPrimary.copy(alpha = 0.12f)),
                    contentAlignment = Alignment.Center
                ) {
                    Icon(Icons.Default.Insights, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(18.dp))
                }
                Spacer(Modifier.width(10.dp))
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
                    StatCard("Streak", "${if (hasAnyLogs) streak.coerceAtLeast(1) else 0} 🔥", Modifier.weight(1f))
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
                                            isDone -> Color(0xFF4CAF50)
                                            isToday -> Color(0xFF2196F3)
                                            else -> NotelSurfaceHigh
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
}

@Composable
fun StatCard(label: String, value: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .background(NotelSurfaceHigh.copy(alpha = 0.5f), RoundedCornerShape(12.dp))
            .border(1.dp, NotelPrimary.copy(alpha = 0.12f), RoundedCornerShape(12.dp))
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
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .clip(RoundedCornerShape(18.dp))
            .background(NotelSurface)
            .border(1.dp, NotelPrimary.copy(alpha = 0.22f), RoundedCornerShape(18.dp))
    ) {
        // Left accent strip
        Box(
            modifier = Modifier
                .align(Alignment.CenterStart)
                .width(4.dp)
                .fillMaxHeight()
                .background(NotelPrimary, RoundedCornerShape(topStart = 18.dp, bottomStart = 18.dp))
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
