package com.notel.notel.ui.screen

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.background
import androidx.compose.foundation.BorderStroke
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.*
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material.icons.filled.CurrencyExchange
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.hilt.navigation.compose.hiltViewModel
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.SettingsViewModel
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.activity.compose.BackHandler
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import androidx.compose.ui.draw.scale
import kotlinx.coroutines.*

enum class SettingsMenu {
    MAIN, USER_PROFILE, CONNECTED_APPS, AI_AND_KNOWLEDGE, EVENT_COUNTERS, WALLET, NOTIFICATIONS, DEBUG
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    viewModel: SettingsViewModel = hiltViewModel(),
    onBack: () -> Unit,
    onRestartOnboarding: () -> Unit,
    onLogout: () -> Unit
) {
    val userContext by viewModel.userContext.collectAsState()
    val knowledgeBase by viewModel.knowledgeBase.collectAsState()
    val professionalUpdates by viewModel.professionalUpdates.collectAsState()
    val processedFiles by viewModel.processedFiles.collectAsState()
    val userBalance by viewModel.userBalance.collectAsState()
    val isUnlimited by viewModel.isUnlimited.collectAsState()
    val isProcessing by viewModel.isProcessingFile.collectAsState()
    val processError by viewModel.processError.collectAsState()
    val aiInsights by viewModel.aiInsights.collectAsState()
    val showProfessionalCheckIn by viewModel.showProfessionalCheckIn.collectAsState()
    
    val isGeneratingWeeklyRecap by viewModel.isGeneratingWeeklyRecap.collectAsState()
    val isGeneratingDeepResearch by viewModel.isGeneratingDeepResearch.collectAsState()
    
    val healthConnectConnected by viewModel.healthConnectConnected.collectAsState()
    val redditSubreddits by viewModel.redditSubreddits.collectAsState()
    val isRefreshingReddit by viewModel.isRefreshingReddit.collectAsState()
    
    val userAge by viewModel.userAge.collectAsState()
    val userHeight by viewModel.userHeight.collectAsState()
    val userWeight by viewModel.userWeight.collectAsState()
    val userGender by viewModel.userGender.collectAsState()
    val autoAiSuggestions by viewModel.autoAiSuggestions.collectAsState()
    val bodyLoadRemindersEnabled by viewModel.bodyLoadRemindersEnabled.collectAsState()
    val dailyCupUpdatesEnabled by viewModel.dailyCupUpdatesEnabled.collectAsState()
    val hrSpikeAlertsEnabled by viewModel.hrSpikeAlertsEnabled.collectAsState()
    val spikeThreshold by viewModel.spikeThreshold.collectAsState()
    val hrDeltaEnabled by viewModel.hrDeltaEnabled.collectAsState()
    val spikeDeltaThreshold by viewModel.spikeDeltaThreshold.collectAsState()
    val habitReminderEnabled by viewModel.habitReminderEnabled.collectAsState()
    val tutorialSeen by viewModel.settingsTutorialSeen.collectAsState()  // null = loading, false = not seen, true = seen

    // Screen dimensions for smart tooltip placement
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val screenHeightDp = configuration.screenHeightDp

    // Scroll state exposed so the tutorial can auto-scroll to each target
    val scrollState = rememberScrollState()

    // Tutorial state
    var tutorialStep by remember { mutableStateOf(-1) }  // -1 = not started yet
    // Coords for each of the 6 tutorial targets
    var coordPersonalCtx   by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var coordWallet        by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var coordUserProfile   by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var coordConnectedApps by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var coordAiKnowledge   by remember { mutableStateOf<LayoutCoordinates?>(null) }
    var coordEventCounters by remember { mutableStateOf<LayoutCoordinates?>(null) }

    // Auto-start tutorial on first-ever visit (only when DataStore confirms never-seen)
    LaunchedEffect(tutorialSeen) {
        if (tutorialSeen == false && tutorialStep == -1) {
            tutorialStep = 0
        }
    }

    // Helper: coords for the current step
    val currentTutorialCoords: LayoutCoordinates? = when (tutorialStep) {
        0 -> coordPersonalCtx
        1 -> coordWallet
        2 -> coordUserProfile
        3 -> coordConnectedApps
        4 -> coordAiKnowledge
        5 -> coordEventCounters
        else -> null
    }

    // Auto-scroll so the highlighted element is comfortably visible
    LaunchedEffect(tutorialStep, currentTutorialCoords) {
        val coords = currentTutorialCoords ?: return@LaunchedEffect
        if (tutorialStep < 0) return@LaunchedEffect
        // coordWallet is in the top bar — no scrolling needed for it
        if (tutorialStep == 1) return@LaunchedEffect
        kotlinx.coroutines.delay(80) // let layout settle after step change
        try {
            val bounds = coords.boundsInWindow()
            val screenHeightPx = with(density) { screenHeightDp.dp.toPx() }
            // Aim to place the element at 35% from the top of the screen
            val targetElementY = screenHeightPx * 0.35f
            val deltaY = bounds.top - targetElementY
            val newScroll = (scrollState.value + deltaY).toInt().coerceAtLeast(0)
            scrollState.animateScrollTo(newScroll)
        } catch (_: Exception) { /* ignore layout not yet attached */ }
    }
    
    val snackbarHostState = remember { SnackbarHostState() }
    val context = LocalContext.current
    val activity = context as? android.app.Activity
    
    var currentMenu by remember { mutableStateOf(SettingsMenu.MAIN) }
    
    BackHandler(enabled = currentMenu != SettingsMenu.MAIN) {
        currentMenu = SettingsMenu.MAIN
    }
    
    fun shareFile(context: android.content.Context, file: java.io.File) {
        val uri = androidx.core.content.FileProvider.getUriForFile(
            context,
            "${context.packageName}.provider",
            file
        )
        val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
            type = "application/pdf"
            putExtra(android.content.Intent.EXTRA_STREAM, uri)
            addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        val chooser = android.content.Intent.createChooser(intent, "Share Professional Report")
        context.startActivity(chooser)
    }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        viewModel.reportReadyEvent.collect { file ->
            if (currentMenu == SettingsMenu.AI_AND_KNOWLEDGE) {
                // If the user is specifically in the AI screen, give them the share sheet now
                shareFile(context, file)
            } else {
                // Otherwise a non-intrusive banner on this screen too
                snackbarHostState.showSnackbar(
                    message = "Professional Report is ready and saved to your phone!",
                    actionLabel = "Share",
                    duration = androidx.compose.material3.SnackbarDuration.Long
                ).let { result ->
                    if (result == androidx.compose.material3.SnackbarResult.ActionPerformed) {
                        shareFile(context, file)
                    }
                }
            }
        }
    }
    
    // Ensure that if we have a generated report from a foreground task, we don't accidentally
    // show it when revisiting the screen unless it's a fresh event.
    // The SharedFlow already handles this by default as it doesn't replay.
    
    LaunchedEffect(Unit) {
        viewModel.billingEvents.collect { message ->
            snackbarHostState.showSnackbar(message)
        }
    }
    
    // The SharedFlow already handles this by default as it doesn't replay.

    var showProfileDialog by remember { mutableStateOf(false) }
    
    var contextInput by remember(userContext) { mutableStateOf(userContext) }
    var customAmountInput by remember { mutableStateOf("") }
    
    var showInsightsHistory by remember { mutableStateOf(false) }
    var showRestartDialog by remember { mutableStateOf(false) }
    var showLogoutDialog by remember { mutableStateOf(false) }
    var showTextNoteDialog by remember { mutableStateOf(false) }

    var showEditUpdateDialog by remember { mutableStateOf(false) }
    var editUpdateIndex by remember { mutableStateOf(0) }
    var editUpdateText by remember { mutableStateOf("") }

    var showEditFactDialog by remember { mutableStateOf(false) }
    var editFactIndex by remember { mutableStateOf(0) }
    var editFactText by remember { mutableStateOf("") }

    val filePicker = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.GetContent()
    ) { uri ->
        uri?.let { viewModel.ingestFile(it, context.contentResolver) }
    }

    val healthConnectLauncher = rememberLauncherForActivityResult(
        contract = viewModel.healthConnectManager.requestPermissionsActivityContract()
    ) { granted ->
        if (granted.containsAll(viewModel.healthConnectManager.permissions)) {
            viewModel.checkHealthConnectStatus()
        }
    }

    val requestNotificationPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission()
    ) { isGranted: Boolean ->
        if (isGranted) {
            // Permission granted, can proceed with testing notifications
        } else {
            // Permission denied, show a message or handle accordingly
            // For example, show a snackbar
            // snackbarHostState.showSnackbar("Notification permission denied.")
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
    Scaffold(
        containerColor = NotelBackground,
        snackbarHost = { SnackbarHost(snackbarHostState) },
        topBar = {
            TopAppBar(
                title = { 
                    val titleText = when (currentMenu) {
                        SettingsMenu.MAIN -> "Settings"
                        SettingsMenu.USER_PROFILE -> "User Profile"
                        SettingsMenu.CONNECTED_APPS -> "Connected Apps"
                        SettingsMenu.AI_AND_KNOWLEDGE -> "AI & Knowledge Base"
                        SettingsMenu.EVENT_COUNTERS -> "Event Counters"
                        SettingsMenu.WALLET -> "Wallet & Usage"
                        SettingsMenu.NOTIFICATIONS -> "Notifications"
                        SettingsMenu.DEBUG -> "Developer Terminal"
                    }
                    Text(titleText, fontWeight = FontWeight.Bold, color = NotelTextPrimary) 
                },
                navigationIcon = {
                    IconButton(onClick = {
                        if (currentMenu == SettingsMenu.MAIN) onBack() else currentMenu = SettingsMenu.MAIN
                    }) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = NotelTextSecondary)
                    }
                },
                actions = {
                    if (currentMenu == SettingsMenu.MAIN) {
                        IconButton(
                            onClick = { currentMenu = SettingsMenu.WALLET },
                            modifier = Modifier.onGloballyPositioned { coordWallet = it }
                        ) {
                            Icon(Icons.Default.AccountBalanceWallet, "Wallet", tint = NotelPrimary)
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
                .padding(horizontal = 16.dp)
                .verticalScroll(scrollState)
        ) {
            Spacer(Modifier.height(16.dp))
            
            if (currentMenu == SettingsMenu.MAIN) {
                // Wallet moved to its own tab
            }

            if (currentMenu == SettingsMenu.WALLET) {
            Text("WALLET & USAGE", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))

            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(if (isUnlimited) "Infinite AI Access" else "Available Credits", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(4.dp))
                        if (isUnlimited) {
                            Text(
                                "∞",
                                color = NotelPrimary,
                                fontSize = 42.sp,
                                fontWeight = FontWeight.Black
                            )
                        } else {
                            Text(
                                "$${String.format("%.2f", userBalance)}",
                                color = NotelPrimary,
                                fontSize = 28.sp,
                                fontWeight = FontWeight.Black
                            )
                        }
                    }
                    Icon(
                        if (isUnlimited) Icons.Default.AutoAwesome else Icons.Default.AccountBalanceWallet,
                        contentDescription = null,
                        tint = NotelPrimary,
                        modifier = Modifier.size(40.dp)
                    )
                }

                Spacer(Modifier.height(16.dp))
                
                Text(
                    if (isUnlimited) "You have exclusive unlimited access. No billing applies." 
                    else "You are billed $0.01 per AI action. Your balance covers server and API costs with a small markup for development.",
                    color = NotelTextSecondary,
                    fontSize = 12.sp
                )

                if (!isUnlimited) {
                    Spacer(Modifier.height(20.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        GlassyButton(
                            onClick = { activity?.let { viewModel.purchaseCredits(it, "jot_credits_5") } },
                            modifier = Modifier.weight(1f),
                            containerColor = NotelPrimary
                        ) {
                            Text("Add $5", color = Color.White, fontWeight = FontWeight.Bold)
                        }
                        GlassyButton(
                            onClick = { activity?.let { viewModel.purchaseCredits(it, "jot_credits_10") } },
                            modifier = Modifier.weight(1f),
                            containerColor = NotelSurfaceHigh
                        ) {
                            Text("Add $10", color = NotelTextPrimary)
                        }
                    }

                    Spacer(Modifier.height(16.dp))
                    
                    GlassyButton(
                        onClick = { 
                            activity?.let { viewModel.purchaseCredits(it, "jot_credit_unit") }
                        },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelSurfaceHigh
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp), tint = NotelPrimary)
                            Spacer(Modifier.width(8.dp))
                            Text("Add Custom Amount ($1/unit)", color = NotelTextPrimary)
                        }
                    }
                    
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "Note: For custom amounts, select the quantity you'd like to purchase in the Google Play window (each unit is $1.00).",
                        color = NotelTextSecondary,
                        fontSize = 11.sp,
                        fontWeight = FontWeight.Medium,
                        lineHeight = 16.sp
                    )
                }
            } // Close GlassyCard
            } // Close if (currentMenu == SettingsMenu.WALLET)

            if (currentMenu == SettingsMenu.MAIN) {
                // 2. Personal Context
                Text("BACKGROUND CONTEXT", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                GlassyCard(shape = RoundedCornerShape(16.dp), color = NotelSurface, modifier = Modifier.onGloballyPositioned { coordPersonalCtx = it }) {
                    Text("Personal Context", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 14.sp)
                    Spacer(Modifier.height(4.dp))
                    Text("Tell Jot about your goals (e.g. 'training for a marathon').", color = NotelTextSecondary, fontSize = 11.sp)
                    Spacer(Modifier.height(8.dp))
                    OutlinedTextField(
                        value = contextInput, onValueChange = { contextInput = it; viewModel.saveUserContext(it.trim()) },
                        modifier = Modifier.fillMaxWidth(), minLines = 2, maxLines = 4,
                        placeholder = { Text("Add background info here…", color = NotelTextSecondary, fontSize = 12.sp) },
                        shape = RoundedCornerShape(12.dp),
                        colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, unfocusedBorderColor = NotelSurfaceHigh, focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary)
                    )
                }

                Spacer(Modifier.height(24.dp))
                Text("SETTINGS", fontSize = 12.sp, color = NotelPrimary, fontWeight = FontWeight.SemiBold, modifier = Modifier.clickable { viewModel.resetSettingsTutorial(); tutorialStep = 0 }.padding(vertical = 4.dp))
                Spacer(Modifier.height(8.dp))

                SettingsMenuCard("User Profile", Icons.Default.Person, modifier = Modifier.onGloballyPositioned { coordUserProfile = it }) { currentMenu = SettingsMenu.USER_PROFILE }
                SettingsMenuCard("Connected Apps", Icons.Default.Favorite, modifier = Modifier.onGloballyPositioned { coordConnectedApps = it }) { currentMenu = SettingsMenu.CONNECTED_APPS }
                SettingsMenuCard("AI & Knowledge Base", Icons.Default.AutoAwesome, modifier = Modifier.onGloballyPositioned { coordAiKnowledge = it }) { currentMenu = SettingsMenu.AI_AND_KNOWLEDGE }
                SettingsMenuCard("Event Counters", Icons.Default.Timer, modifier = Modifier.onGloballyPositioned { coordEventCounters = it }) { currentMenu = SettingsMenu.EVENT_COUNTERS }
                SettingsMenuCard("Notifications", Icons.Default.Notifications) { currentMenu = SettingsMenu.NOTIFICATIONS }
            }
            
            if (currentMenu == SettingsMenu.DEBUG && isUnlimited) {
                DebugScreen(onBack = { currentMenu = SettingsMenu.MAIN }, viewModel = viewModel)
            }


            if (currentMenu == SettingsMenu.EVENT_COUNTERS) {
            Text("EVENT COUNTER", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))

            val eventCounters by viewModel.eventCounters.collectAsState()
            val cHistory by viewModel.counterHistory.collectAsState()

            var showCounterDialog by remember { mutableStateOf(false) }
            var editCounter by remember { mutableStateOf<com.notel.notel.ui.viewmodel.EventCounterDto?>(null) }

            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface
            ) {
                if (eventCounters.isNotEmpty()) {
                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        eventCounters.forEach { counter ->
                            val todayStart = java.util.Calendar.getInstance().apply {
                                set(java.util.Calendar.HOUR_OF_DAY, 0)
                                set(java.util.Calendar.MINUTE, 0)
                                set(java.util.Calendar.SECOND, 0)
                                set(java.util.Calendar.MILLISECOND, 0)
                            }.timeInMillis
                            val daysRemaining = Math.max(0L, Math.abs(todayStart - counter.targetDate) / 86400000L)
                            val direction = if (counter.isUp) "since" else "until"
                            
                            GlassyCard(
                                shape = RoundedCornerShape(12.dp),
                                color = if (counter.isFavorite) NotelPrimary.copy(alpha = 0.1f) else NotelSurfaceHigh.copy(alpha = 0.5f)
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(counter.name, color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 13.sp)
                                        Text("$daysRemaining days $direction", color = NotelPrimary, fontSize = 11.sp)
                                    }
                                    IconButton(
                                        onClick = { viewModel.toggleFavoriteCounter(counter.id) },
                                        modifier = Modifier.size(28.dp)
                                    ) {
                                        Icon(if (counter.isFavorite) Icons.Default.Star else Icons.Default.StarOutline, "Favorite", tint = if (counter.isFavorite) Color.Yellow else NotelTextSecondary, modifier = Modifier.size(16.dp))
                                    }
                                    IconButton(
                                        onClick = { 
                                            editCounter = counter
                                            showCounterDialog = true
                                        },
                                        modifier = Modifier.size(28.dp)
                                    ) {
                                        Icon(Icons.Default.Edit, "Edit", tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                                    }
                                    IconButton(
                                        onClick = { viewModel.endCounterAndSave(counter.id) },
                                        modifier = Modifier.size(28.dp)
                                    ) {
                                        Icon(Icons.Default.Delete, "End", tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(16.dp))
                                    }
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    GlassyButton(
                        onClick = { 
                            editCounter = null
                            showCounterDialog = true 
                        },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelSurfaceHigh
                    ) {
                        Icon(Icons.Default.Add, "Add Counter", tint = NotelPrimary)
                        Spacer(Modifier.width(8.dp))
                        Text("Add New Counter", color = NotelTextPrimary)
                    }
                } else {
                    Text("Track important upcoming or past events. The favorite one shows on the main screen and syncs with the AI.", color = NotelTextSecondary, fontSize = 12.sp)
                    Spacer(Modifier.height(16.dp))
                    GlassyButton(
                        onClick = { 
                            editCounter = null
                            showCounterDialog = true 
                        },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelSurfaceHigh
                    ) {
                        Icon(Icons.Default.Timer, "Add Counter", tint = NotelPrimary)
                        Spacer(Modifier.width(8.dp))
                        Text("Add New Counter", color = NotelTextPrimary)
                    }
                }

                if (cHistory.isNotEmpty()) {
                    Spacer(Modifier.height(16.dp))
                    Text("Past Counters:", color = NotelTextSecondary, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(4.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        cHistory.forEach { ch ->
                            Text("${ch.name} (Ended: ${java.text.SimpleDateFormat("MMM dd, yyyy", java.util.Locale.getDefault()).format(java.util.Date(ch.endedAt))})", color = NotelTextSecondary, fontSize = 11.sp)
                        }
                    }
                }
            }

            if (showCounterDialog) {
                var editName by remember { mutableStateOf(editCounter?.name ?: "") }
                var selectedDateMillis by remember { mutableStateOf(editCounter?.targetDate ?: System.currentTimeMillis()) }
                var editIsUp by remember { mutableStateOf(editCounter?.isUp ?: false) }
                var editAuto by remember { mutableStateOf(editCounter?.autoUp ?: false) }

                val context = LocalContext.current
                val calendar = java.util.Calendar.getInstance()
                calendar.timeInMillis = selectedDateMillis
                val datePickerDialog = android.app.DatePickerDialog(
                    context,
                    { _, year, month, dayOfMonth ->
                        val newCal = java.util.Calendar.getInstance()
                        newCal.set(year, month, dayOfMonth, 0, 0, 0)
                        selectedDateMillis = newCal.timeInMillis
                        // Auto-toggle Count Up if date is in the past
                        if (newCal.timeInMillis < System.currentTimeMillis()) {
                            editIsUp = true
                        } else {
                            editIsUp = false
                        }
                    },
                    calendar.get(java.util.Calendar.YEAR),
                    calendar.get(java.util.Calendar.MONTH),
                    calendar.get(java.util.Calendar.DAY_OF_MONTH)
                )

                val displayDate = java.text.SimpleDateFormat("MMM dd, yyyy", java.util.Locale.getDefault()).format(java.util.Date(selectedDateMillis))

                AlertDialog(
                    onDismissRequest = { showCounterDialog = false },
                    title = { Text(if (editCounter != null) "Edit Counter" else "New Counter", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedTextField(
                                value = editName, onValueChange = { editName = it },
                                label = { Text("Event Name (e.g. Next Doctor Appt)") },
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, unfocusedTextColor = NotelTextPrimary, focusedTextColor = NotelTextPrimary)
                            )
                            
                            OutlinedTextField(
                                value = displayDate,
                                onValueChange = { },
                                readOnly = true,
                                label = { Text("Event Date") },
                                trailingIcon = {
                                    IconButton(onClick = { datePickerDialog.show() }) {
                                        Icon(Icons.Default.DateRange, "Select Date")
                                    }
                                },
                                modifier = Modifier.fillMaxWidth().clickable { datePickerDialog.show() },
                                 colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, unfocusedTextColor = NotelTextPrimary, focusedTextColor = NotelTextPrimary)
                            )
                            
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text("Count Up (Past Event)?", color = NotelTextPrimary, fontSize = 12.sp, modifier = Modifier.weight(1f))
                                Switch(checked = editIsUp, onCheckedChange = { editIsUp = it })
                            }
                            if (!editIsUp) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text("Auto switch to Count Up when day arrives?", color = NotelTextPrimary, fontSize = 12.sp, modifier = Modifier.weight(1f))
                                    Switch(checked = editAuto, onCheckedChange = { editAuto = it })
                                }
                            }
                        }
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            val id = editCounter?.id ?: java.util.UUID.randomUUID().toString()
                            viewModel.saveCounter(id, editName, selectedDateMillis, editIsUp, editAuto)
                            showCounterDialog = false
                        }) {
                            Text("Save", color = NotelPrimary)
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { showCounterDialog = false }) {
                            Text("Cancel", color = NotelTextSecondary)
                        }
                    },
                    containerColor = NotelSurface
                )
            }
            
            }

            Spacer(Modifier.height(24.dp))
            
            if (currentMenu == SettingsMenu.AI_AND_KNOWLEDGE) {
                if (showProfessionalCheckIn) {
                    val lowerCtx = userContext.lowercase()
                    val lowerKB = knowledgeBase.lowercase()

                    val professionalType = when {
                        lowerCtx.contains("doctor") || lowerCtx.contains("dr.") || lowerKB.contains("doctor") || lowerKB.contains("dr.") -> "Doctor"
                        lowerCtx.contains("coach") || lowerKB.contains("coach") -> "Coach"
                        lowerCtx.contains("therapist") || lowerKB.contains("therapist") -> "Therapist"
                        else -> "Professional"
                    }
                    Text("PROFESSIONAL UPDATES", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(8.dp))

                    var showProfessionalDialog by remember { mutableStateOf(false) }

                    GlassyCard(
                        shape = RoundedCornerShape(16.dp),
                        color = NotelSurface
                    ) {
                        Text("$professionalType Check-in", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "Did your $professionalType suggest any new protocols, dose changes, or routines? Add them here so the AI can track your compliance.",
                            color = NotelTextSecondary,
                            fontSize = 12.sp
                        )
                        
                        Spacer(Modifier.height(16.dp))

                        GlassyButton(
                            onClick = { showProfessionalDialog = true },
                            modifier = Modifier.fillMaxWidth(),
                            containerColor = NotelPrimary.copy(alpha = 0.8f)
                        ) {
                            Text("Add $professionalType Update", color = Color.White, fontWeight = FontWeight.Bold)
                        }

                        if (showProfessionalDialog) {
                            var updateNote by remember { mutableStateOf("") }
                            Dialog(onDismissRequest = { showProfessionalDialog = false }) {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(16.dp)
                                        .liquidGlass(shape = RoundedCornerShape(24.dp), color = NotelBackground, alpha = 1f)
                                        .padding(24.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Column {
                                        Text("New $professionalType Update", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = NotelTextPrimary)
                                        Spacer(Modifier.height(16.dp))
                                        OutlinedTextField(
                                            value = updateNote,
                                            onValueChange = { updateNote = it },
                                            label = { Text("What did they say?") },
                                            modifier = Modifier.fillMaxWidth().height(150.dp),
                                            colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                                                focusedBorderColor = NotelPrimary, unfocusedBorderColor = NotelPrimary.copy(alpha=0.5f),
                                                focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary
                                            )
                                        )
                                        Spacer(Modifier.height(16.dp))
                                        Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                                            TextButton(onClick = { showProfessionalDialog = false }) { Text("Cancel", color = NotelTextSecondary) }
                                            Spacer(Modifier.width(8.dp))
                                            TextButton(
                                                onClick = {
                                                    if (updateNote.isNotBlank()) {
                                                        viewModel.addProfessionalUpdate(professionalType, updateNote)
                                                    }
                                                    showProfessionalDialog = false
                                                },
                                                enabled = updateNote.isNotBlank()
                                            ) { Text("Save Update", color = NotelPrimary) }
                                        }
                                    }
                                }
                            }
                        }

                        if (professionalUpdates.isNotBlank()) {
                            Spacer(Modifier.height(16.dp))
                            var isProUpdatesExpanded by remember { mutableStateOf(false) }

                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { isProUpdatesExpanded = !isProUpdatesExpanded }
                                    .padding(vertical = 4.dp),
                                horizontalArrangement = Arrangement.SpaceBetween,
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("Past $professionalType Updates", color = NotelPrimary, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                                Icon(
                                    if (isProUpdatesExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                                    contentDescription = "Toggle Updates",
                                    tint = NotelPrimary
                                )
                            }

                            if (isProUpdatesExpanded) {
                                Spacer(Modifier.height(8.dp))
                                
                                val updatesList = professionalUpdates.split("\n\n").filter { it.isNotBlank() }
                                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    updatesList.forEachIndexed { index, update ->
                                        Surface(
                                            shape = RoundedCornerShape(12.dp),
                                            color = NotelSurfaceHigh.copy(alpha = 0.5f),
                                            modifier = Modifier.fillMaxWidth()
                                        ) {
                                            Row(
                                                modifier = Modifier.padding(12.dp),
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                Text(
                                                    text = update.trim(),
                                                    color = NotelTextPrimary,
                                                    fontSize = 13.sp,
                                                    lineHeight = 18.sp,
                                                    modifier = Modifier.weight(1f)
                                                )
                                                Row {
                                                    IconButton(
                                                        onClick = {
                                                            editUpdateIndex = index
                                                            editUpdateText = update.trim()
                                                            showEditUpdateDialog = true
                                                        },
                                                        modifier = Modifier.size(24.dp)
                                                    ) {
                                                        Icon(Icons.Default.Edit, "Edit update", tint = NotelPrimary, modifier = Modifier.size(16.dp))
                                                    }
                                                    Spacer(Modifier.width(8.dp))
                                                    IconButton(
                                                        onClick = { viewModel.deleteProfessionalUpdate(index) },
                                                        modifier = Modifier.size(24.dp)
                                                    ) {
                                                        Icon(
                                                            Icons.Default.Delete, 
                                                            "Delete update", 
                                                            tint = MaterialTheme.colorScheme.error.copy(alpha=0.7f), 
                                                            modifier = Modifier.size(16.dp)
                                                        )
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                if (showEditUpdateDialog) {
                                    Dialog(onDismissRequest = { showEditUpdateDialog = false }) {
                                        Box(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .padding(16.dp)
                                                .liquidGlass(shape = RoundedCornerShape(24.dp), color = NotelBackground, alpha = 1f)
                                                .padding(24.dp),
                                            contentAlignment = Alignment.Center
                                        ) {
                                            Column {
                                                Text("Edit $professionalType Update", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = NotelTextPrimary)
                                                Spacer(Modifier.height(16.dp))
                                                OutlinedTextField(
                                                    value = editUpdateText,
                                                    onValueChange = { editUpdateText = it },
                                                    label = { Text("Update content") },
                                                    modifier = Modifier.fillMaxWidth().height(150.dp),
                                                    colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                                                        focusedBorderColor = NotelPrimary, unfocusedBorderColor = NotelPrimary.copy(alpha=0.5f),
                                                        focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary
                                                    )
                                                )
                                                Spacer(Modifier.height(16.dp))
                                                Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                                                    TextButton(onClick = { showEditUpdateDialog = false }) { Text("Cancel", color = NotelTextSecondary) }
                                                    Spacer(Modifier.width(8.dp))
                                                    TextButton(
                                                        onClick = {
                                                            if (editUpdateText.isNotBlank()) {
                                                                viewModel.editProfessionalUpdate(editUpdateIndex, editUpdateText)
                                                            }
                                                            showEditUpdateDialog = false
                                                        },
                                                        enabled = editUpdateText.isNotBlank()
                                                    ) { Text("Save Changes", color = NotelPrimary) }
                                                }
                                            }
                                        }
                                    }
                                }
                                
                                TextButton(
                                    onClick = { viewModel.clearProfessionalUpdates() },
                                    modifier = Modifier.align(Alignment.End)
                                ) {
                                    Text("Clear Updates", color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
                                }
                            }
                        }
                    }
                    Spacer(Modifier.height(24.dp))
                }

                // ── FILE KNOWLEDGE BASE (top of AI tab) ──────────────────────────
                Text("FILE KNOWLEDGE BASE", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))

                GlassyCard(
                    shape = RoundedCornerShape(16.dp),
                    color = NotelSurface
                ) {
                    Text("Digital Knowledge Extraction", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Upload notes or PDFs to extract permanent knowledge (patterns, triggers, facts) that Gemini will remember.",
                        color = NotelTextSecondary,
                        fontSize = 12.sp
                    )

                    Spacer(Modifier.height(16.dp))

                    if (isProcessing) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            GlassySpinner(size = 32.dp)
                            Spacer(Modifier.width(12.dp))
                            Text("Gemini is reading your files...", color = NotelTextPrimary, fontSize = 14.sp)
                        }
                    } else {
                        GlassyButton(
                            onClick = { filePicker.launch("*/*") },
                            modifier = Modifier.fillMaxWidth(),
                            containerColor = NotelSurfaceHigh
                        ) {
                            Icon(Icons.Default.UploadFile, null, tint = NotelPrimary)
                            Spacer(Modifier.width(8.dp))
                            Text("Select Document / PDF", color = NotelTextPrimary)
                        }

                        Spacer(Modifier.height(8.dp))

                        GlassyButton(
                            onClick = { showTextNoteDialog = true },
                            modifier = Modifier.fillMaxWidth(),
                            containerColor = NotelSurfaceHigh
                        ) {
                            Icon(Icons.Default.PostAdd, null, tint = NotelPrimary)
                            Spacer(Modifier.width(8.dp))
                            Text("Add Text Note", color = NotelTextPrimary)
                        }
                    }

                    if (showTextNoteDialog) {
                        var noteTitle by remember { mutableStateOf("") }
                        var noteBody by remember { mutableStateOf("") }
                        
                        Dialog(onDismissRequest = { showTextNoteDialog = false }) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(16.dp)
                                    .liquidGlass(shape = RoundedCornerShape(24.dp), color = NotelBackground, alpha = 1f)
                                    .padding(24.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Column {
                                    Text("Add Text Note", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = NotelTextPrimary)
                                    Spacer(Modifier.height(16.dp))
                                    OutlinedTextField(
                                        value = noteTitle,
                                        onValueChange = { noteTitle = it },
                                        label = { Text("Title (Optional)") },
                                        modifier = Modifier.fillMaxWidth(),
                                        colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                                            focusedBorderColor = NotelPrimary, unfocusedBorderColor = NotelPrimary.copy(alpha=0.5f),
                                            focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary
                                        )
                                    )
                                    Spacer(Modifier.height(8.dp))
                                    OutlinedTextField(
                                        value = noteBody,
                                        onValueChange = { noteBody = it },
                                        label = { Text("Note content / Text message") },
                                        modifier = Modifier.fillMaxWidth().height(150.dp),
                                        colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                                            focusedBorderColor = NotelPrimary, unfocusedBorderColor = NotelPrimary.copy(alpha=0.5f),
                                            focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary
                                        )
                                    )
                                    Spacer(Modifier.height(16.dp))
                                    Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                                        TextButton(onClick = { showTextNoteDialog = false }) { Text("Cancel", color = NotelTextSecondary) }
                                        Spacer(Modifier.width(8.dp))
                                        TextButton(
                                            onClick = {
                                                if (noteBody.isNotBlank()) {
                                                    val title = if (noteTitle.isNotBlank()) noteTitle else "Text Note"
                                                    viewModel.processManualTextNote(title, noteBody)
                                                }
                                                showTextNoteDialog = false
                                            },
                                            enabled = noteBody.isNotBlank()
                                        ) { Text("Process", color = NotelPrimary) }
                                    }
                                }
                            }
                        }
                    }

                    processError?.let {
                        Spacer(Modifier.height(8.dp))
                        Text(it, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
                    }

                    if (processedFiles.isNotBlank()) {
                        Spacer(Modifier.height(16.dp))
                        Text("Processed Files:", color = NotelTextSecondary, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                        Text(processedFiles, color = NotelTextSecondary, fontSize = 12.sp)
                    }

                    if (knowledgeBase.isNotBlank()) {
                        Spacer(Modifier.height(16.dp))
                        var isFactsExpanded by remember { mutableStateOf(false) }

                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { isFactsExpanded = !isFactsExpanded }
                                .padding(vertical = 4.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Extracted Facts", color = NotelPrimary, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                            Icon(
                                if (isFactsExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                                contentDescription = "Toggle Facts",
                                tint = NotelPrimary
                            )
                        }
                        
                        if (isFactsExpanded) {
                            Spacer(Modifier.height(8.dp))
                            
                            val facts = knowledgeBase.split("\n\n").filter { it.isNotBlank() }
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                facts.forEachIndexed { index, fact ->
                                    var expanded by remember { mutableStateOf(false) }
                                    Surface(
                                        onClick = { expanded = !expanded },
                                        shape = RoundedCornerShape(12.dp),
                                        color = NotelSurfaceHigh.copy(alpha = 0.5f),
                                        modifier = Modifier.fillMaxWidth()
                                    ) {
                                        Column(modifier = Modifier.padding(12.dp)) {
                                            Row(
                                                modifier = Modifier.fillMaxWidth(),
                                                horizontalArrangement = Arrangement.SpaceBetween,
                                                verticalAlignment = Alignment.CenterVertically
                                            ) {
                                                val filesList = processedFiles.split(",").map { it.trim() }.filter { it.isNotBlank() }
                                                val titleText = if (index in filesList.indices) {
                                                    "Extraction from: ${filesList[index]}"
                                                } else {
                                                    "Extraction ${index + 1}"
                                                }
                                                
                                                Text(
                                                    text = titleText,
                                                    color = NotelPrimary,
                                                    fontSize = 11.sp,
                                                    fontWeight = FontWeight.SemiBold
                                                )
                                                Row {
                                                    IconButton(
                                                        onClick = {
                                                            editFactIndex = index
                                                            editFactText = fact.trim()
                                                            showEditFactDialog = true
                                                        },
                                                        modifier = Modifier.size(24.dp)
                                                    ) {
                                                        Icon(Icons.Default.Edit, "Edit fact", tint = NotelPrimary, modifier = Modifier.size(16.dp))
                                                    }
                                                    Spacer(Modifier.width(8.dp))
                                                    IconButton(
                                                        onClick = { viewModel.deleteKnowledgeItem(index) },
                                                        modifier = Modifier.size(24.dp)
                                                    ) {
                                                        Icon(Icons.Default.Delete, "Delete extraction", tint = MaterialTheme.colorScheme.error.copy(alpha=0.7f), modifier = Modifier.size(16.dp))
                                                    }
                                                }
                                            }
                                            Spacer(Modifier.height(6.dp))
                                            Text(
                                                text = fact.trim(),
                                                color = NotelTextPrimary,
                                                fontSize = 13.sp,
                                                lineHeight = 18.sp,
                                                maxLines = if (expanded) Int.MAX_VALUE else 3,
                                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                                            )
                                            if (!expanded) {
                                                Spacer(Modifier.height(4.dp))
                                                Text("Tap to expand", color = NotelTextSecondary, fontSize = 11.sp)
                                            }
                                        }
                                    }
                                }
                            }
                            
                            if (showEditFactDialog) {
                                Dialog(onDismissRequest = { showEditFactDialog = false }) {
                                    Box(
                                        modifier = Modifier
                                            .fillMaxWidth()
                                            .padding(16.dp)
                                            .liquidGlass(shape = RoundedCornerShape(24.dp), color = NotelBackground, alpha = 1f)
                                            .padding(24.dp),
                                        contentAlignment = Alignment.Center
                                    ) {
                                        Column {
                                            Text("Edit Extracted Fact", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = NotelTextPrimary)
                                            Spacer(Modifier.height(16.dp))
                                            OutlinedTextField(
                                                value = editFactText,
                                                onValueChange = { editFactText = it },
                                                label = { Text("Fact content") },
                                                modifier = Modifier.fillMaxWidth().height(200.dp),
                                                colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                                                    focusedBorderColor = NotelPrimary, unfocusedBorderColor = NotelPrimary.copy(alpha=0.5f),
                                                    focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary
                                                )
                                            )
                                            Spacer(Modifier.height(16.dp))
                                            Row(horizontalArrangement = Arrangement.End, modifier = Modifier.fillMaxWidth()) {
                                                TextButton(onClick = { showEditFactDialog = false }) { Text("Cancel", color = NotelTextSecondary) }
                                                Spacer(Modifier.width(8.dp))
                                                TextButton(
                                                    onClick = {
                                                        if (editFactText.isNotBlank()) {
                                                            viewModel.editKnowledgeItem(editFactIndex, editFactText)
                                                        }
                                                        showEditFactDialog = false
                                                    },
                                                    enabled = editFactText.isNotBlank()
                                                ) { Text("Save Changes", color = NotelPrimary) }
                                            }
                                        }
                                    }
                                }
                            }

                            TextButton(
                                onClick = { viewModel.clearKnowledge() },
                                modifier = Modifier.align(Alignment.End)
                            ) {
                                    Text("Clear Knowledge Base", color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
                                }
                            }
                        }
                    }

                Spacer(Modifier.height(24.dp))
                Text("AI CONFIGURATION", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                GlassyCard(
                    shape = RoundedCornerShape(16.dp),
                    color = NotelSurface
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Auto AI Pings", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                            Text(
                                "Automatically load smart tiles when opening the app. Turn off to save credits ($0.01/ping).",
                                color = NotelTextSecondary,
                                fontSize = 11.sp
                            )
                        }
                        Switch(
                            checked = autoAiSuggestions,
                            onCheckedChange = { viewModel.setAutoAiSuggestions(it) },
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = NotelPrimary,
                                checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                uncheckedThumbColor = NotelTextSecondary,
                                uncheckedTrackColor = NotelSurfaceHigh
                            )
                        )
                    }
                }

                Spacer(Modifier.height(24.dp))

                Text("PROFESSIONAL DIAGNOSTICS", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))

                GlassyCard(
                    shape = RoundedCornerShape(16.dp),
                    color = NotelSurface
                ) {
                    Text("Professional report (PDF)", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Generate a professional PDF summary of your trends and logs for personal review or sharing.",
                        color = NotelTextSecondary,
                        fontSize = 12.sp
                    )
                    
                    val isGenerating by viewModel.isGeneratingReport.collectAsState()
                    val generatedFile by viewModel.generatedReport.collectAsState()
                    
                    LaunchedEffect(generatedFile) {
                        generatedFile?.let { file ->
                            val uri = androidx.core.content.FileProvider.getUriForFile(
                                context,
                                "${context.packageName}.provider",
                                file
                            )
                            val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply {
                                type = "application/pdf"
                                putExtra(android.content.Intent.EXTRA_STREAM, uri)
                                addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            }
                            context.startActivity(android.content.Intent.createChooser(intent, "Share Professional Report"))
                            viewModel.resetGeneratedReport()
                        }
                    }

                    Spacer(Modifier.height(16.dp))

                    GlassyButton(
                        onClick = { viewModel.generateProfessionalReport() },
                        modifier = Modifier.fillMaxWidth(),
                        enabled = !isGenerating,
                        containerColor = NotelSurfaceHigh
                    ) {
                        if (isGenerating) {
                            GlassySpinner(size = 20.dp)
                        } else {
                            Icon(Icons.Default.PictureAsPdf, null, tint = NotelPrimary)
                            Spacer(Modifier.width(8.dp))
                            Text("Export Professional Report", color = NotelTextPrimary)
                        }
                    }
                }

                Spacer(Modifier.height(24.dp))

                Text("AI INSIGHTS HISTORY", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))

                if (aiInsights.isEmpty()) {
                    Text("No AI insights generated yet. Click 'Learn More' on the Jot screen to start.", color = NotelTextSecondary, fontSize = 14.sp)
                } else {
                    if (!showInsightsHistory) {
                        GlassyButton(
                            onClick = { showInsightsHistory = true },
                            modifier = Modifier.fillMaxWidth(),
                            containerColor = NotelSurfaceHigh
                        ) {
                            Text("Show Past AI Insights", color = NotelTextPrimary)
                        }
                    } else {
                        GlassyButton(
                            onClick = { showInsightsHistory = false },
                            modifier = Modifier.fillMaxWidth(),
                            containerColor = NotelSurfaceHigh
                        ) {
                            Text("Hide AI Insights", color = NotelTextPrimary)
                        }
                        Spacer(Modifier.height(12.dp))
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            aiInsights.forEach { insight ->
                                InsightTile(insight = insight, onDelete = { viewModel.deleteAiInsight(insight.id) })
                            }
                        }
                    }
                }
                Spacer(Modifier.height(24.dp))
            }


            if (currentMenu == SettingsMenu.CONNECTED_APPS) {
                var viewingSubreddit by remember { mutableStateOf<String?>(null) }

                if (viewingSubreddit != null) {
                    val subState = redditSubreddits.find { it.name == viewingSubreddit }
                    val summary = viewModel.getSubredditSummary(viewingSubreddit!!)
                    val posts = subState?.scannedPosts ?: emptyList()
                    AlertDialog(
                        onDismissRequest = { viewingSubreddit = null },
                        title = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Forum, null, tint = Color(0xFFFF4500), modifier = Modifier.size(24.dp))
                                Text(" r/$viewingSubreddit Knowledge", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                            }
                        },
                        text = {
                            Column(modifier = Modifier.heightIn(max = 500.dp).verticalScroll(rememberScrollState())) {
                                Text("AI OVERVIEW", fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, color = NotelTextSecondary.copy(alpha = 0.7f), letterSpacing = 1.sp)
                                Spacer(Modifier.height(4.dp))
                                Text(summary, color = NotelTextPrimary, fontSize = 14.sp, lineHeight = 20.sp)

                                if (posts.isNotEmpty()) {
                                    val threadsWithComments = posts.filter { it.comments.isNotEmpty() }
                                    if (threadsWithComments.isNotEmpty()) {
                                        Spacer(Modifier.height(24.dp))
                                        Text("SCANNED THREADS (Tap title for comments)", fontSize = 10.sp, fontWeight = FontWeight.ExtraBold, color = NotelTextSecondary.copy(alpha = 0.7f), letterSpacing = 1.sp)
                                        Spacer(Modifier.height(8.dp))
                                        
                                        // Stable expansion state using a map
                                        val expansions = remember { mutableStateMapOf<String, Boolean>() }
                                        
                                        threadsWithComments.forEach { post ->
                                            val key = post.url ?: post.title
                                            val isExpanded = expansions[key] ?: false
                                            Surface(
                                                color = NotelSurfaceHigh.copy(alpha = 0.4f),
                                                shape = RoundedCornerShape(12.dp),
                                                modifier = Modifier.fillMaxWidth().padding(bottom = 8.dp)
                                            ) {
                                                Column(
                                                    modifier = Modifier
                                                        .clickable { expansions[key] = !isExpanded }
                                                        .padding(12.dp)
                                                ) {
                                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                                        Text(
                                                            post.title,
                                                            color = NotelTextPrimary,
                                                            fontWeight = if (isExpanded) FontWeight.Bold else FontWeight.Medium,
                                                            fontSize = 12.sp,
                                                            modifier = Modifier.weight(1f)
                                                        )
                                                        Text(
                                                            "${post.comments.size}",
                                                            color = NotelPrimary,
                                                            fontSize = 10.sp,
                                                            fontWeight = FontWeight.Bold,
                                                            modifier = Modifier.padding(end = 4.dp)
                                                        )
                                                        Icon(
                                                            if (isExpanded) {
                                                                androidx.compose.material.icons.Icons.Default.KeyboardArrowUp
                                                            } else {
                                                                androidx.compose.material.icons.Icons.Default.KeyboardArrowDown
                                                            },
                                                            null,
                                                            tint = NotelTextSecondary,
                                                            modifier = Modifier.size(16.dp)
                                                        )
                                                    }
                                                    if (isExpanded) {
                                                        Spacer(Modifier.height(12.dp))
                                                        post.comments.forEach { comment ->
                                                            Row(modifier = Modifier.padding(bottom = 8.dp).fillMaxWidth()) {
                                                                Box(
                                                                    Modifier.width(2.dp).height(24.dp)
                                                                        .background(NotelPrimary.copy(alpha = 0.4f), RoundedCornerShape(1.dp))
                                                                )
                                                                Spacer(Modifier.width(8.dp))
                                                                Text(comment, color = NotelTextSecondary, fontSize = 11.sp, lineHeight = 16.sp)
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    } else {
                                        Spacer(Modifier.height(24.dp))
                                        Text("No detailed comments found for your recent scan. The AI summary above still uses the main thread content.", 
                                            color = NotelTextSecondary, fontSize = 11.sp, textAlign = TextAlign.Center)
                                    }
                                }
                            }
                        },
                        confirmButton = {
                            TextButton(onClick = { viewingSubreddit = null }) {
                                Text("Close", color = NotelPrimary)
                            }
                        },
                        containerColor = NotelSurface,
                        shape = RoundedCornerShape(20.dp)
                    )
                }

            Text("LOCAL CONNECTIONS", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))

            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface
            ) {
                if (healthConnectConnected) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Favorite, null, tint = NotelPrimary, modifier = Modifier.size(28.dp))
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Health Connect Active", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                            Text("Live synchronization active", color = NotelTextSecondary, fontSize = 12.sp)
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    Text("• Connected to local device sensors", color = NotelTextSecondary, fontSize = 13.sp)
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.FavoriteBorder, null, tint = NotelPrimary, modifier = Modifier.size(28.dp))
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Google Health Connect", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                            Text("Connect to grab data from Garmin, Oura, Fitbit and more.", color = NotelTextSecondary, fontSize = 12.sp)
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    GlassyButton(
                        onClick = { 
                            healthConnectLauncher.launch(viewModel.healthConnectManager.permissions)
                        },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelPrimary.copy(alpha = 0.8f)
                    ) {
                        Text("Connect Health Data", color = Color.White, fontWeight = FontWeight.Bold)
                    }
                }
            }

            Spacer(Modifier.height(24.dp))
            val fitbitViewModel: com.notel.notel.ui.viewmodel.FitbitViewModel = hiltViewModel()
            val fitbitState by fitbitViewModel.state.collectAsState()

            Text("ADVANCED DATA SOURCES", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))

            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface
            ) {
                if (fitbitState.isFitbitConnected) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.CloudQueue, null, tint = NotelPrimary, modifier = Modifier.size(28.dp))
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Fitbit Cloud Active", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                            Text("Pulling 6-month history directly", color = NotelTextSecondary, fontSize = 12.sp)
                        }
                    }
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.CloudOff, null, tint = NotelPrimary, modifier = Modifier.size(28.dp))
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Fitbit Direct API", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                            Text("Bypass Health Connect limits to pull your full 6-month history instantly.", color = NotelTextSecondary, fontSize = 12.sp)
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    GlassyButton(
                        onClick = { fitbitViewModel.connectFitbit(context) },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelSurfaceHigh
                    ) {
                        Text("Connect Fitbit Directly", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

            // Reddit state and notifications
            val redditRefreshQueue by viewModel.redditRefreshQueue.collectAsState()

            androidx.compose.runtime.LaunchedEffect(Unit) {
                launch {
                    viewModel.redditError.collect { err ->
                        snackbarHostState.showSnackbar(err)
                    }
                }
                launch {
                    viewModel.redditSynced.collect { msg ->
                        snackbarHostState.showSnackbar(msg)
                    }
                }
            }

            Text("COMMUNITY KNOWLEDGE", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))

            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Forum, null, tint = Color(0xFFFF4500), modifier = Modifier.size(28.dp))
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Reddit Subreddits", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                        Text(
                            "Link communities to pull deep health insights directly into your AI context.",
                            color = NotelTextSecondary,
                            fontSize = 12.sp
                        )
                    }
                }

                if (redditRefreshQueue.isNotEmpty()) {
                    Spacer(Modifier.height(16.dp))
                    Column {
                        Text("REFRESH QUEUE", fontSize = 9.sp, fontWeight = FontWeight.SemiBold, color = NotelTextSecondary.copy(alpha = 0.6f), letterSpacing = 1.sp)
                        Spacer(Modifier.height(4.dp))
                        androidx.compose.foundation.lazy.LazyRow(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            contentPadding = PaddingValues(end = 12.dp)
                        ) {
                            items(redditRefreshQueue.size) { index ->
                                val subName = redditRefreshQueue[index]
                                val isActive = isRefreshingReddit == subName
                                Surface(
                                    color = if (isActive) NotelPrimary.copy(alpha = 0.15f) else NotelSurfaceHigh.copy(alpha = 0.4f),
                                    shape = RoundedCornerShape(8.dp),
                                    border = if (isActive) BorderStroke(1.dp, NotelPrimary) else null
                                ) {
                                    Row(Modifier.padding(horizontal = 10.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                                        if (isActive) {
                                            GlassySpinner(size = 12.dp)
                                            Spacer(Modifier.width(6.dp))
                                        }
                                        Text(subName, color = NotelTextPrimary, fontSize = 11.sp, fontWeight = if (isActive) FontWeight.Bold else FontWeight.Medium)
                                    }
                                }
                            }
                        }
                    }
                }

                Spacer(Modifier.height(16.dp))

                var redditInput by remember { mutableStateOf("") }

                OutlinedTextField(
                    value = redditInput,
                    onValueChange = { redditInput = it },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                    placeholder = { Text("e.g. POTS  or  r/dysautonomia", color = NotelTextSecondary, fontSize = 13.sp) },
                    leadingIcon = { Text("r/", color = NotelPrimary, fontWeight = FontWeight.Bold, fontSize = 14.sp) },
                    shape = RoundedCornerShape(12.dp),
                    colors = OutlinedTextFieldDefaults.colors(
                        focusedBorderColor = Color(0xFFFF4500),
                        unfocusedBorderColor = NotelSurfaceHigh,
                        focusedTextColor = NotelTextPrimary,
                        unfocusedTextColor = NotelTextPrimary
                    )
                )

                Spacer(Modifier.height(12.dp))

                GlassyButton(
                    onClick = {
                        if (redditInput.isNotBlank() && isRefreshingReddit == null) {
                            viewModel.addOrRefreshSubreddit(redditInput.trim())
                            redditInput = ""
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = redditInput.isNotBlank() && isRefreshingReddit == null,
                    containerColor = if (redditInput.isNotBlank()) Color(0xFFFF4500).copy(alpha = 0.85f) else NotelSurfaceHigh
                ) {
                    if (isRefreshingReddit != null && redditInput.isBlank()) {
                        GlassySpinner(size = 20.dp)
                        Spacer(Modifier.width(8.dp))
                        Text("Scanning posts...", color = Color.White, fontWeight = FontWeight.Bold)
                    } else {
                        Icon(Icons.Default.Search, null, tint = if (redditInput.isNotBlank()) Color.White else NotelTextSecondary, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.width(8.dp))
                        Text("Scan Subreddit (Top 10 Posts)", color = if (redditInput.isNotBlank()) Color.White else NotelTextSecondary, fontWeight = FontWeight.Bold)
                    }
                }

                if (redditSubreddits.isNotEmpty()) {
                    Spacer(Modifier.height(20.dp))
                    Text("Linked Subreddits", color = NotelTextSecondary, fontSize = 12.sp, fontWeight = FontWeight.Bold)
                    Spacer(Modifier.height(8.dp))
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        redditSubreddits.forEach { sub ->
                            val isThisRefreshing = isRefreshingReddit == sub.name
                            Surface(
                                shape = RoundedCornerShape(12.dp),
                                color = NotelSurfaceHigh.copy(alpha = 0.6f),
                                modifier = Modifier.fillMaxWidth(),
                                onClick = { viewingSubreddit = sub.name }
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Column(modifier = Modifier.weight(1f)) {
                                        Row(verticalAlignment = Alignment.CenterVertically) {
                                            Text(
                                                "r/${sub.name}",
                                                color = Color(0xFFFF4500),
                                                fontWeight = FontWeight.Bold,
                                                fontSize = 13.sp
                                            )
                                            if (sub.autoUpdate) {
                                                Spacer(Modifier.width(6.dp))
                                                Box(Modifier.size(6.dp).background(Color(0xFF4CAF50), CircleShape))
                                            }
                                        }
                                        val lastFetchedStr = if (sub.lastFetched > 0L) {
                                            val diff = System.currentTimeMillis() - sub.lastFetched
                                            when {
                                                diff < 60 * 60 * 1000L -> "Updated just now"
                                                diff < 24 * 60 * 60 * 1000L -> {
                                                    val hrs = (diff / (60 * 60 * 1000L)).toInt()
                                                    "Updated ${hrs}h ago"
                                                }
                                                else -> {
                                                    val days = (diff / (24 * 60 * 60 * 1000L)).toInt()
                                                    "Updated ${days}d ago"
                                                }
                                            }
                                        } else "Never synced"
                                        Text("$lastFetchedStr · ${sub.postsAnalyzed} posts", color = NotelTextSecondary, fontSize = 11.sp)
                                    }

                                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                        Text("AUTO", fontSize = 9.sp, fontWeight = FontWeight.Bold, color = if (sub.autoUpdate) NotelPrimary else NotelTextSecondary)
                                        Switch(
                                            checked = sub.autoUpdate,
                                            onCheckedChange = { viewModel.toggleAutoUpdate(sub.name) },
                                            modifier = Modifier.scale(0.6f),
                                            colors = SwitchDefaults.colors(
                                                checkedThumbColor = NotelPrimary,
                                                checkedTrackColor = NotelPrimary.copy(alpha = 0.3f)
                                            )
                                        )
                                    }

                                    // Refresh button
                                    if (isThisRefreshing) {
                                        GlassySpinner(size = 20.dp)
                                    } else {
                                        IconButton(
                                            onClick = { viewModel.addOrRefreshSubreddit(sub.name) },
                                            modifier = Modifier.size(32.dp)
                                        ) {
                                            Icon(Icons.Default.Refresh, "Refresh r/${sub.name}", tint = NotelTextSecondary, modifier = Modifier.size(18.dp))
                                        }
                                    }
                                    Spacer(Modifier.width(4.dp))
                                    // Remove button
                                    IconButton(
                                        onClick = { viewModel.removeSubreddit(sub.name) },
                                        modifier = Modifier.size(32.dp),
                                        enabled = !isThisRefreshing
                                    ) {
                                        Icon(Icons.Default.Delete, "Remove r/${sub.name}", tint = MaterialTheme.colorScheme.error.copy(alpha = 0.7f), modifier = Modifier.size(18.dp))
                                    }
                                }
                            }

                        }
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        "Community knowledge is automatically included in all AI analysis, advice, and reports.",
                        color = NotelTextSecondary,
                        fontSize = 11.sp
                    )
                }
            }

            Spacer(Modifier.height(24.dp))

            }


            if (currentMenu == SettingsMenu.USER_PROFILE) {
            Text("USER PROFILE", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))
            
            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Person, null, tint = NotelPrimary, modifier = Modifier.size(28.dp))
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Personal Health Profile", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                        Text("Fetched from Fitbit or manually updated", color = NotelTextSecondary, fontSize = 12.sp)
                    }
                }
                Spacer(Modifier.height(16.dp))
                if (userAge > 0) Text("Age: $userAge", color = NotelTextSecondary, fontSize = 13.sp)
                if (userHeight > 0f) {
                    val ft = (userHeight / 12).toInt()
                    val inch = (userHeight % 12).toInt()
                    Text("Height: $ft'$inch\" (${userHeight.toInt()} in)", color = NotelTextSecondary, fontSize = 13.sp)
                }
                if (userWeight > 0f) Text("Weight: ${userWeight} lbs", color = NotelTextSecondary, fontSize = 13.sp)
                if (userGender.isNotBlank()) Text("Gender: $userGender", color = NotelTextSecondary, fontSize = 13.sp)
                
                Spacer(Modifier.height(16.dp))
                GlassyButton(
                    onClick = { showProfileDialog = true },
                    modifier = Modifier.fillMaxWidth(),
                    containerColor = NotelSurfaceHigh
                ) {
                    Text("Edit Profile", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                }

                val isSyncingProfile by viewModel.isSyncingProfile.collectAsState()

                Spacer(Modifier.height(8.dp))
                GlassyButton(
                    onClick = { viewModel.syncHealthProfile() },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = !isSyncingProfile,
                    containerColor = NotelSurfaceHigh
                ) {
                    if (isSyncingProfile) {
                        GlassySpinner(size = 20.dp)
                    } else {
                        Icon(Icons.Default.Sync, null, tint = NotelPrimary)
                        Spacer(Modifier.width(8.dp))
                        Text("Auto-Fill from Connected Apps", color = NotelTextPrimary)
                    }
                }
                
                
                if (healthConnectConnected) {
                    Spacer(Modifier.height(8.dp))
                    Text("Powered by Health Connect", color = NotelTextSecondary, fontSize = 12.sp, modifier = Modifier.align(Alignment.CenterHorizontally))
                }
            }
            
            if (showProfileDialog) {
                var editAge by remember { mutableStateOf(if (userAge > 0) userAge.toString() else "") }
                var editHeight by remember { mutableStateOf(if (userHeight > 0f) userHeight.toString() else "") }
                var editWeight by remember { mutableStateOf(if (userWeight > 0f) userWeight.toString() else "") }
                var editGender by remember { mutableStateOf(userGender) }
                
                AlertDialog(
                    onDismissRequest = { showProfileDialog = false },
                    title = { Text("Edit Profile", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedTextField(
                                value = editAge, onValueChange = { editAge = it },
                                label = { Text("Age") },
                                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number),
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary, focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary)
                            )
                            OutlinedTextField(
                                value = editGender, onValueChange = { editGender = it },
                                label = { Text("Gender") },
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary, focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary)
                            )
                            OutlinedTextField(
                                value = editHeight, onValueChange = { editHeight = it },
                                label = { Text("Height") },
                                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number),
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary, focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary)
                            )
                            OutlinedTextField(
                                value = editWeight, onValueChange = { editWeight = it },
                                label = { Text("Weight") },
                                keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number),
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary, focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary)
                            )
                        }
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            viewModel.saveUserProfile(
                                age = editAge.toIntOrNull() ?: 0,
                                height = editHeight.toFloatOrNull() ?: 0f,
                                weight = editWeight.toFloatOrNull() ?: 0f,
                                gender = editGender
                            )
                            showProfileDialog = false
                        }) {
                            Text("Save", color = NotelPrimary)
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { showProfileDialog = false }) {
                            Text("Cancel", color = NotelTextSecondary)
                        }
                    },
                    containerColor = NotelSurface
                )
            }
            
            Spacer(Modifier.height(24.dp))
            }

            if (currentMenu == SettingsMenu.NOTIFICATIONS) {
                Text("NOTIFICATIONS", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))

                GlassyCard(
                    shape = RoundedCornerShape(16.dp),
                    color = NotelSurface
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Cup Reminder", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                Text(
                                    "A ping if you haven't checked your Cup level by the afternoon.",
                                    color = NotelTextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                            Switch(
                                checked = bodyLoadRemindersEnabled,
                                onCheckedChange = { viewModel.setBodyLoadRemindersEnabled(it) },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = NotelPrimary,
                                    checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                    uncheckedThumbColor = NotelTextSecondary,
                                    uncheckedTrackColor = NotelSurfaceHigh
                                )
                            )
                        }
                        
                        TextButton(
                            onClick = { 
                                if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                                    viewModel.testDailyReminder(context)
                                } else {
                                    requestNotificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                }
                            },
                            modifier = Modifier.align(Alignment.Start)
                        ) {
                            Text("Test Cup Reminder Notification", color = NotelPrimary, fontSize = 12.sp)
                        }

                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Body Load Summary", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                Text(
                                    "A summary of your final physiological load at 9:00 PM. Tap to learn more.",
                                    color = NotelTextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                            Switch(
                                checked = dailyCupUpdatesEnabled,
                                onCheckedChange = { viewModel.setDailyCupUpdatesEnabled(it) },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = NotelPrimary,
                                    checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                    uncheckedThumbColor = NotelTextSecondary,
                                    uncheckedTrackColor = NotelSurfaceHigh
                                )
                            )
                        }

                        TextButton(
                            onClick = { 
                                if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                                    viewModel.testBodyLoadNotification(context)
                                } else {
                                    requestNotificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                }
                            },
                            modifier = Modifier.align(Alignment.Start)
                        ) {
                            Text("Test Cup Summary Notification", color = NotelPrimary, fontSize = 12.sp)
                        }

                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Habit Reminders", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                Text(
                                    "Daily ping at 7:00 PM if you have unchecked habits remaining.",
                                    color = NotelTextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                            Switch(
                                checked = habitReminderEnabled,
                                onCheckedChange = { viewModel.setHabitReminderEnabled(it) },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = NotelPrimary,
                                    checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                    uncheckedThumbColor = NotelTextSecondary,
                                    uncheckedTrackColor = NotelSurfaceHigh
                                )
                            )
                        }
                        
                        TextButton(
                            onClick = { 
                                if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                                    viewModel.testHabitNotification(context)
                                } else {
                                    requestNotificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                }
                            },
                            modifier = Modifier.align(Alignment.Start)
                        ) {
                            Text("Test Habit Reminder Notification", color = NotelPrimary, fontSize = 12.sp)
                        }

                        Column {
                            val initialThreshold = remember { spikeThreshold }
                            var tempSpikeThreshold by remember { mutableStateOf(initialThreshold.toString()) }
                            
                            DisposableEffect(Unit) {
                                onDispose {
                                    val finalVal = tempSpikeThreshold.toIntOrNull()
                                    if (finalVal == null || finalVal < 40) {
                                        viewModel.setSpikeThreshold(110)
                                    }
                                }
                            }

                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("HR Spike Alerts", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                    Text(
                                        "Real-time alert when your heart rate exceeds ${if (tempSpikeThreshold.isNotBlank()) tempSpikeThreshold else "110"} BPM.",
                                        color = NotelTextSecondary,
                                        fontSize = 11.sp
                                    )
                                }
                                Switch(
                                    checked = hrSpikeAlertsEnabled,
                                    onCheckedChange = { 
                                        viewModel.setHrSpikeAlertsEnabled(it)
                                        if (it && (tempSpikeThreshold.isBlank() || (tempSpikeThreshold.toIntOrNull() ?: 0) < 40)) {
                                            tempSpikeThreshold = "110"
                                            viewModel.setSpikeThreshold(110)
                                        }
                                    },
                                    colors = SwitchDefaults.colors(
                                        checkedThumbColor = NotelPrimary,
                                        checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                        uncheckedThumbColor = NotelTextSecondary,
                                        uncheckedTrackColor = NotelSurfaceHigh
                                    )
                                )
                            }
                            
                            if (hrSpikeAlertsEnabled) {
                                Spacer(Modifier.height(16.dp))
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Text("Alert Threshold", color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                                    OutlinedTextField(
                                        value = tempSpikeThreshold,
                                        onValueChange = { newVal ->
                                            val filtered = newVal.filter { it.isDigit() }
                                            if (filtered.length <= 3) {
                                                tempSpikeThreshold = filtered
                                                val intVal = filtered.toIntOrNull()
                                                if (intVal != null && intVal in 40..250) {
                                                    viewModel.setSpikeThreshold(intVal)
                                                }
                                            }
                                        },
                                        modifier = Modifier.width(130.dp),
                                        singleLine = true,
                                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                        suffix = { Text("BPM", color = NotelTextSecondary, fontSize = 12.sp) },
                                        colors = OutlinedTextFieldDefaults.colors(
                                            focusedBorderColor = NotelPrimary,
                                            unfocusedBorderColor = NotelSurfaceHigh,
                                            focusedTextColor = NotelTextPrimary,
                                            unfocusedTextColor = NotelTextPrimary,
                                            focusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.5f),
                                            unfocusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.3f)
                                        ),
                                        shape = RoundedCornerShape(12.dp)
                                    )
                                }
                            }

                            // ── Delta Spike Setting ──
                            val initialDelta = remember { spikeDeltaThreshold }
                            var tempDeltaThreshold by remember { mutableStateOf(initialDelta.toString()) }

                            Spacer(Modifier.height(24.dp))
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Column(modifier = Modifier.weight(1f)) {
                                    Text("Delta Spike Alerts", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                    Text(
                                        "Alert if BPM jumps more than ${if (tempDeltaThreshold.isNotBlank()) tempDeltaThreshold else "30"} points relative to your last reading (checked every 2-5 mins).",
                                        color = NotelTextSecondary,
                                        fontSize = 11.sp
                                    )
                                }
                                Switch(
                                    checked = hrDeltaEnabled,
                                    onCheckedChange = { 
                                        viewModel.setHrDeltaEnabled(it)
                                        if (it && (tempDeltaThreshold.isBlank() || (tempDeltaThreshold.toIntOrNull() ?: 0) < 5)) {
                                            tempDeltaThreshold = "30"
                                            viewModel.setSpikeDeltaThreshold(30)
                                        }
                                    },
                                    colors = SwitchDefaults.colors(
                                        checkedThumbColor = NotelPrimary,
                                        checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                        uncheckedThumbColor = NotelTextSecondary,
                                        uncheckedTrackColor = NotelSurfaceHigh
                                    )
                                )
                            }
                            
                            if (hrDeltaEnabled) {
                                Spacer(Modifier.height(16.dp))
                                Row(
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween,
                                    modifier = Modifier.fillMaxWidth()
                                ) {
                                    Text("Jump Threshold", color = NotelTextPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                                    OutlinedTextField(
                                        value = tempDeltaThreshold,
                                        onValueChange = { newVal ->
                                            val filtered = newVal.filter { it.isDigit() }
                                            if (filtered.length <= 2) {
                                                tempDeltaThreshold = filtered
                                                val intVal = filtered.toIntOrNull()
                                                if (intVal != null && intVal in 5..99) {
                                                    viewModel.setSpikeDeltaThreshold(intVal)
                                                }
                                            }
                                        },
                                        modifier = Modifier.width(130.dp),
                                        singleLine = true,
                                        prefix = { Text("+", color = NotelPrimary) },
                                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                                        colors = OutlinedTextFieldDefaults.colors(
                                            focusedBorderColor = NotelPrimary,
                                            unfocusedBorderColor = NotelSurfaceHigh,
                                            focusedTextColor = NotelTextPrimary,
                                            unfocusedTextColor = NotelTextPrimary,
                                            focusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.5f),
                                            unfocusedContainerColor = NotelSurfaceHigh.copy(alpha = 0.3f)
                                        ),
                                        shape = RoundedCornerShape(12.dp)
                                    )
                                }
                            }

                            TextButton(
                                onClick = { 
                                    if (ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
                                        viewModel.testSpikeNotification(context)
                                    } else {
                                        requestNotificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                                    }
                                },
                                modifier = Modifier.align(Alignment.Start)
                            ) {
                                Text("Test Spike Alert Notification", color = NotelPrimary, fontSize = 12.sp)
                            }
                        }
                    }
                }
                Spacer(Modifier.height(24.dp))
            }

            val isSyncing by viewModel.isSyncing.collectAsState()
            
            LaunchedEffect(Unit) {
                viewModel.syncError.collect { msg ->
                    snackbarHostState.showSnackbar(msg)
                }
            }

            if (currentMenu == SettingsMenu.MAIN) {
                Spacer(Modifier.height(16.dp))

                GlassyButton(
                    onClick = { showLogoutDialog = true },
                    modifier = Modifier.fillMaxWidth(),
                    containerColor = NotelSurfaceHigh
                ) {
                    Icon(Icons.Default.Logout, "Logout", tint = NotelPrimary)
                    Spacer(Modifier.width(8.dp))
                    Text("Logout / Switch Account", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                }

                if (isUnlimited) {
                    Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) {
                        TextButton(onClick = { currentMenu = SettingsMenu.DEBUG }) {
                            Icon(Icons.Default.BugReport, null, tint = NotelTextSecondary.copy(alpha = 0.5f), modifier = Modifier.size(14.dp))
                            Spacer(Modifier.width(4.dp))
                            Text("Developer Options", color = NotelTextSecondary.copy(alpha = 0.5f), fontSize = 10.sp)
                        }
                    }
                }
                
                Spacer(Modifier.height(32.dp))
                Text("About", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                Card(
                    shape = RoundedCornerShape(16.dp),
                    colors = CardDefaults.cardColors(containerColor = NotelSurface)
                ) {
                    ListItem(
                        headlineContent = { Text("Jot", color = NotelTextPrimary) },
                        supportingContent = { Text("Version 1.0", color = NotelTextSecondary) },
                        leadingContent = { Icon(Icons.Default.Info, null, tint = NotelPrimary) },
                        colors = ListItemDefaults.colors(containerColor = NotelSurface)
                    )
                }
                
                Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                    TextButton(onClick = { showRestartDialog = true }) {
                        Text("Reset Account Status", color = Color.Red.copy(alpha = 0.6f), fontSize = 10.sp)
                    }
                }
            }
            

            if (showLogoutDialog) {
                AlertDialog(
                    onDismissRequest = { showLogoutDialog = false },
                    title = { Text("Logout?", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = { Text("Are you sure you want to log out?", color = NotelTextSecondary) },
                    confirmButton = {
                        TextButton(onClick = {
                            viewModel.logout {
                                onLogout()
                            }
                            showLogoutDialog = false
                        }) {
                            Text("Logout", color = NotelPrimary)
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { showLogoutDialog = false }) {
                            Text("Cancel", color = NotelTextSecondary)
                        }
                    },
                    containerColor = NotelSurface
                )
            }

            if (showRestartDialog) {
                AlertDialog(
                    onDismissRequest = { showRestartDialog = false },
                    title = { Text("Reset Account?", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = { 
                        Text("Are you sure? This will wipe your checkmark from the server and let you start the introduction tour over again.", color = NotelTextSecondary) 
                    },
                    confirmButton = {
                        TextButton(onClick = {
                            viewModel.restartOnboarding(onRestartOnboarding)
                            showRestartDialog = false
                        }) {
                            Text("Reset", color = Color.Red)
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { showRestartDialog = false }) {
                            Text("Cancel", color = NotelTextSecondary)
                        }
                    },
                    containerColor = NotelSurface
                )
            }
            Spacer(Modifier.height(48.dp))
        }
    }

    // ── Tutorial overlay — sits above the Scaffold so it can cover the top bar ──
    if (tutorialStep in 0..<settingsTutorialSteps.size) {
        SettingsTutorialOverlay(
            targetCoords = currentTutorialCoords,
            currentStep = tutorialStep,
            totalSteps = settingsTutorialSteps.size,
            screenHeightDp = screenHeightDp,
            onNext = {
                if (tutorialStep < settingsTutorialSteps.size - 1) {
                    tutorialStep++
                } else {
                    tutorialStep = -1
                    viewModel.markSettingsTutorialSeen()
                }
            },
            onSkip = {
                tutorialStep = -1
                viewModel.markSettingsTutorialSeen()
            }
        )
    }
    }
}
@Composable
fun InsightTile(insight: com.notel.notel.data.local.entity.AiInsight, onDelete: () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    val format = remember { java.text.SimpleDateFormat("MMM dd, yyyy h:mm a", java.util.Locale.getDefault()) }
    
    Surface(
        onClick = { expanded = !expanded },
        color = Color.Transparent,
        shape = RoundedCornerShape(12.dp),
        modifier = Modifier.fillMaxWidth().liquidGlass(shape = RoundedCornerShape(12.dp), color = NotelSurface, alpha = 0.5f)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                Text(
                    text = "${format.format(java.util.Date(insight.timestamp))} • ${insight.type}",
                    color = NotelPrimary,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f)
                )
                IconButton(onClick = onDelete, modifier = Modifier.size(24.dp)) {
                    Icon(Icons.Default.Delete, "Delete", tint = NotelTextSecondary, modifier = Modifier.size(16.dp))
                }
            }
            Spacer(Modifier.height(6.dp))
            Text(
                text = insight.text,
                color = NotelTextPrimary,
                fontSize = 14.sp,
                lineHeight = 20.sp,
                maxLines = if (expanded) Int.MAX_VALUE else 2,
                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
            )
            if (!expanded) {
                Spacer(Modifier.height(4.dp))
                Text("Tap to expand", color = NotelTextSecondary, fontSize = 11.sp)
            }
        }
    }
}

@Composable
fun SettingsMenuCard(
    title: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    modifier: Modifier = Modifier,
    onClick: () -> Unit
) {
    GlassyCard(
        shape = RoundedCornerShape(16.dp),
        color = NotelSurface,
        modifier = modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .clickable(onClick = onClick)
                .padding(vertical = 12.dp, horizontal = 12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(icon, null, tint = NotelPrimary, modifier = Modifier.size(28.dp))
            Spacer(Modifier.width(16.dp))
            Text(title, color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 16.sp, modifier = Modifier.weight(1f))
            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = NotelTextSecondary)
        }
    }
    Spacer(Modifier.height(16.dp))
}

@Composable
fun DebugScreen(
    onBack: () -> Unit,
    viewModel: SettingsViewModel
) {
    val context = LocalContext.current
    val logs by viewModel.allLogs.collectAsState()
    
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClick = onBack) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = NotelPrimary)
            }
            Spacer(Modifier.width(8.dp))
            Text("Internal Debug Terminal", fontSize = 20.sp, fontWeight = FontWeight.Bold, color = NotelPrimary)
        }
        Spacer(Modifier.height(16.dp))
        
        Text("Notification Testing", color = NotelTextSecondary, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        
        androidx.compose.foundation.lazy.grid.LazyVerticalGrid(
            columns = androidx.compose.foundation.lazy.grid.GridCells.Fixed(2),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            item {
                GlassyButton(onClick = { viewModel.testDailyReminder(context) }, modifier = Modifier.fillMaxWidth()) {
                    Text("Daily", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
            item {
                GlassyButton(onClick = { viewModel.testBodyLoadNotification(context) }, modifier = Modifier.fillMaxWidth()) {
                    Text("Body Load", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
            item {
                GlassyButton(onClick = { viewModel.testHabitNotification(context) }, modifier = Modifier.fillMaxWidth()) {
                    Text("Habit", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
            item {
                GlassyButton(onClick = { viewModel.testSpikeNotification(context) }, modifier = Modifier.fillMaxWidth()) {
                    Text("Spike", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
            item {
                GlassyButton(onClick = { viewModel.recoverAccountData() }, modifier = Modifier.fillMaxWidth(), containerColor = NotelSurfaceHigh) {
                    Text("Force Sync", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
        }
        
        Spacer(Modifier.height(16.dp))
        Text("System Logs (${logs.size})", color = NotelTextSecondary, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        
        androidx.compose.foundation.lazy.LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f)
                .background(Color.Black.copy(alpha = 0.5f), shape = RoundedCornerShape(8.dp))
                .padding(8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            items(logs.size) { index ->
                val log = logs[index]
                Text(
                    text = "[${java.text.SimpleDateFormat("MM/dd HH:mm", java.util.Locale.getDefault()).format(log.timestamp)}] ${log.body}",
                    color = Color.Green,
                    fontSize = 11.sp,
                    fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace
                )
            }
        }
    }
}
