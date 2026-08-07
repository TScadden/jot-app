package com.notel.notel.ui.screen

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.accounts.AccountManager
import android.app.Activity
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
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.runtime.mutableStateMapOf
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.drawIntoCanvas
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.animation.core.animateFloat
import androidx.compose.foundation.border
import kotlinx.coroutines.*


enum class SettingsMenu {
    MAIN, USER_PROFILE, CUSTOMIZE, CONNECTED_APPS, AI_AND_KNOWLEDGE, EVENT_COUNTERS, MEMBERSHIP, NOTIFICATIONS, SYNC_SETTINGS, JOT_LIVE, DEBUG
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    initialMenu: SettingsMenu = SettingsMenu.MAIN,
    viewModel: SettingsViewModel = hiltViewModel(),
    onBack: () -> Unit,
    onRestartOnboarding: () -> Unit,
    onLogout: () -> Unit,
    onNavigateToFile: (name: String, path: String, mime: String, docId: String) -> Unit
) {
    val userContext by viewModel.userContext.collectAsState()
    val lastSyncTime by viewModel.lastSyncTime.collectAsState()
    val knowledgeBase by viewModel.knowledgeBase.collectAsState()
    val professionalUpdates by viewModel.professionalUpdates.collectAsState()
    val processedFiles by viewModel.processedFiles.collectAsState()
    val isUnlimited by viewModel.isUnlimited.collectAsState()
    val isAdmin by viewModel.isAdmin.collectAsState()
    val isProcessing by viewModel.isProcessingFile.collectAsState()
    val processError by viewModel.processError.collectAsState()
    val aiInsights by viewModel.aiInsights.collectAsState()
    val showProfessionalCheckIn by viewModel.showProfessionalCheckIn.collectAsState()
    val knowledgeDocuments by viewModel.knowledgeDocuments.collectAsState()
    
    val isGeneratingWeeklyRecap by viewModel.isGeneratingWeeklyRecap.collectAsState()
    val isGeneratingDeepResearch by viewModel.isGeneratingDeepResearch.collectAsState()
    
    val healthConnectConnected by viewModel.healthConnectConnected.collectAsState()
    val googleCalendarConnected by viewModel.googleCalendarConnected.collectAsState()
    val googleCalendarEmail by viewModel.googleCalendarEmail.collectAsState()
    
    val userAge by viewModel.userAge.collectAsState()
    val userHeight by viewModel.userHeight.collectAsState()
    val userWeight by viewModel.userWeight.collectAsState()
    val userGender by viewModel.userGender.collectAsState()
    val autoAiSuggestions by viewModel.autoAiSuggestions.collectAsState()
    val bleAutoConnectEnabled by viewModel.bleAutoConnectEnabled.collectAsState()
    val bodyLoadRemindersEnabled by viewModel.bodyLoadRemindersEnabled.collectAsState()
    val dailyCupUpdatesEnabled by viewModel.dailyCupUpdatesEnabled.collectAsState()
    val hrSpikeAlertsEnabled by viewModel.hrSpikeAlertsEnabled.collectAsState()
    val spikeThreshold by viewModel.spikeThreshold.collectAsState()
    val hrDeltaEnabled by viewModel.hrDeltaEnabled.collectAsState()
    val spikeDeltaThreshold by viewModel.spikeDeltaThreshold.collectAsState()
    val habitReminderEnabled by viewModel.habitReminderEnabled.collectAsState()
    val projectReminderEnabled by viewModel.projectReminderEnabled.collectAsState()
    val eventReminderEnabled by viewModel.eventReminderEnabled.collectAsState()
    val userContextHidden by viewModel.userContextHidden.collectAsState()
    val userNickname by viewModel.userNickname.collectAsState()
    val userTag by viewModel.userTag.collectAsState()
    val shareDataWithFriends by viewModel.shareDataWithFriends.collectAsState()
    val tutorialSeen by viewModel.settingsTutorialSeen.collectAsState()  // null = loading, false = not seen, true = seen
    val showNavLabels by viewModel.showNavLabels.collectAsState()

    val context = LocalContext.current

    val permissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        // No-op, the collectAsState will refresh
    }

    val googleAccountChooserLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.StartActivityForResult()
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) {
            val accountName = result.data?.getStringExtra(AccountManager.KEY_ACCOUNT_NAME)
            if (accountName != null) {
                viewModel.connectGoogleCalendar(accountName)
            }
        }
    }

    fun checkAndToggle(enabled: Boolean, onToggle: (Boolean) -> Unit) {
        if (enabled) {
            if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                val status = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
                if (status != PackageManager.PERMISSION_GRANTED) {
                    permissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                    return
                }
            }
        }
        onToggle(enabled)
    }

    // Screen dimensions for smart tooltip placement
    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val screenHeightDp = configuration.screenHeightDp

    // Scroll state exposed so the tutorial can auto-scroll to each target
    val scrollState = rememberScrollState()
    var selectedPlan by remember { mutableStateOf("monthly") }

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
    val activity = context as? android.app.Activity
    val fitbitViewModel: com.notel.notel.ui.viewmodel.FitbitViewModel = hiltViewModel()
    val fitbitState by fitbitViewModel.state.collectAsState()
    
    var showAllTimeTelemetryGraph by remember { mutableStateOf(false) }
    val telemetryHistoryStr by viewModel.heartRateHistory.collectAsState()
    val isPullingTelemetry by viewModel.isPullingTelemetry.collectAsState()
    val telemetryPoints = remember(telemetryHistoryStr) {
        try {
            if (telemetryHistoryStr.isNotBlank() && telemetryHistoryStr != "[]") {
                val rawList = kotlinx.serialization.json.Json.decodeFromString<List<com.notel.notel.data.TelemetryPoint>>(telemetryHistoryStr)
                downsampleTelemetryPoints(rawList)
            } else {
                emptyList()
            }
        } catch (e: Exception) {
            emptyList()
        }
    }
    
    var currentMenu by androidx.compose.runtime.saveable.rememberSaveable(
        stateSaver = androidx.compose.runtime.saveable.Saver(
            save = { it.name },
            restore = { SettingsMenu.valueOf(it) }
        )
    ) { mutableStateOf(initialMenu) }
    
    BackHandler(enabled = currentMenu != SettingsMenu.MAIN) {
        viewModel.flushProfilePush()
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
    
    var isContextFocused by remember { mutableStateOf(false) }
    var contextInput by remember { mutableStateOf("") }
    LaunchedEffect(userContext) {
        if (!isContextFocused) {
            contextInput = userContext
        }
    }
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
        // Relax checking: if they granted ANYTHING, check status.
        // Also if granted is empty but they come back, we check anyway.
        viewModel.checkHealthConnectStatus()
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
                        SettingsMenu.CUSTOMIZE -> "Customize"
                        SettingsMenu.CONNECTED_APPS -> "Connected Apps"
                        SettingsMenu.AI_AND_KNOWLEDGE -> "AI & Clinical Advocate"
                        SettingsMenu.EVENT_COUNTERS -> "Event Counters"
                        SettingsMenu.MEMBERSHIP -> "Membership"
                        SettingsMenu.NOTIFICATIONS -> "Notifications"
                        SettingsMenu.SYNC_SETTINGS -> "Sync Settings"
                        SettingsMenu.JOT_LIVE -> "Tabs Live Beta"
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
                    if (currentMenu == SettingsMenu.JOT_LIVE) {
                        IconButton(
                            onClick = {
                                showAllTimeTelemetryGraph = true
                                viewModel.pullTelemetryFromServer()
                            }
                        ) {
                            Icon(Icons.Default.ShowChart, "Show Telemetry Graph", tint = NotelPrimary)
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = NotelBackground)
            )
        }
    ) { padding ->
        if (currentMenu == SettingsMenu.DEBUG && isAdmin) {
            DebugScreen(onBack = { currentMenu = SettingsMenu.MAIN }, viewModel = viewModel, padding = padding)
        } else {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .padding(horizontal = 16.dp)
                    .verticalScroll(scrollState)
            ) {
                Spacer(Modifier.height(16.dp))
                
                // Top Segmented Tab Header (Details vs Membership)
                if (currentMenu == SettingsMenu.MAIN || currentMenu == SettingsMenu.MEMBERSHIP) {
                    Surface(
                        shape = RoundedCornerShape(14.dp),
                        color = NotelSurfaceHigh.copy(alpha = 0.5f),
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(bottom = 16.dp)
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .padding(4.dp),
                            horizontalArrangement = Arrangement.SpaceEvenly
                        ) {
                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(if (currentMenu == SettingsMenu.MAIN) NotelSurface else Color.Transparent)
                                    .clickable { currentMenu = SettingsMenu.MAIN }
                                    .padding(vertical = 10.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        imageVector = Icons.Default.Subtitles,
                                        contentDescription = null,
                                        tint = if (currentMenu == SettingsMenu.MAIN) NotelTextPrimary else NotelTextSecondary,
                                        modifier = Modifier.size(18.dp)
                                    )
                                    Spacer(Modifier.width(8.dp))
                                    Text(
                                        text = "Settings",
                                        color = if (currentMenu == SettingsMenu.MAIN) NotelTextPrimary else NotelTextSecondary,
                                        fontWeight = if (currentMenu == SettingsMenu.MAIN) FontWeight.Bold else FontWeight.Medium,
                                        fontSize = 14.sp
                                    )
                                }
                            }

                            Box(
                                modifier = Modifier
                                    .weight(1f)
                                    .clip(RoundedCornerShape(10.dp))
                                    .background(if (currentMenu == SettingsMenu.MEMBERSHIP) NotelSurface else Color.Transparent)
                                    .clickable { currentMenu = SettingsMenu.MEMBERSHIP }
                                    .padding(vertical = 10.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Icon(
                                        imageVector = Icons.Default.Wallet,
                                        contentDescription = null,
                                        tint = if (currentMenu == SettingsMenu.MEMBERSHIP) NotelTextPrimary else NotelTextSecondary,
                                        modifier = Modifier.size(18.dp)
                                    )
                                    Spacer(Modifier.width(8.dp))
                                    Text(
                                        text = "Membership",
                                        color = if (currentMenu == SettingsMenu.MEMBERSHIP) NotelTextPrimary else NotelTextSecondary,
                                        fontWeight = if (currentMenu == SettingsMenu.MEMBERSHIP) FontWeight.Bold else FontWeight.Medium,
                                        fontSize = 14.sp
                                    )
                                }
                            }
                        }
                    }
                }

                if (currentMenu == SettingsMenu.MEMBERSHIP) {
                    GlassyCard(
                        shape = RoundedCornerShape(16.dp),
                        color = NotelSurface
                    ) {
                        // Status row
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    if (isAdmin) "Admin Account" else if (isUnlimited) "Jot Premium" else "No Active Membership",
                                    color = NotelTextPrimary,
                                    fontWeight = FontWeight.Bold,
                                    fontSize = 18.sp
                                )
                                Spacer(Modifier.height(4.dp))
                                Text(
                                    if (isAdmin) "Developer Access · All Features Unlocked" else if (isUnlimited) "Premium Access · All Features Unlocked" else "Subscribe to unlock all AI features",
                                    color = if (isUnlimited) Color(0xFF4CAF50) else NotelTextSecondary,
                                    fontSize = 13.sp
                                )
                            }
                            Surface(
                                shape = RoundedCornerShape(12.dp),
                                color = if (isUnlimited) Color(0xFF4CAF50).copy(alpha = 0.15f) else NotelSurfaceHigh
                            ) {
                                Text(
                                    if (isAdmin) "ADMIN" else if (isUnlimited) "ACTIVE" else "INACTIVE",
                                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                                    color = if (isUnlimited) Color(0xFF4CAF50) else NotelTextSecondary,
                                    fontSize = 11.sp,
                                    fontWeight = FontWeight.Black
                                )
                            }
                        }

                        // Access Level Display
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                Text(
                                    if (isUnlimited) "Unlimited" else "Standard",
                                    color = NotelPrimary,
                                    fontSize = 32.sp,
                                    fontWeight = FontWeight.Black
                                )
                                Text(
                                    "MEMBERSHIP LEVEL",
                                    color = NotelTextSecondary,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold,
                                    letterSpacing = 1.sp
                                )
                            }
                        }
                        
                        Spacer(Modifier.height(12.dp))
                        
                        Text(
                            if (isUnlimited) "You have full unlimited access to all AI features." 
                            else "Standard account. Upgrade for unlimited AI insights and clinical reports.",
                            color = NotelTextSecondary,
                            fontSize = 13.sp,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth()
                        )

                        if (!isUnlimited) {
                            Spacer(Modifier.height(24.dp))
                            
                            // Plan 1: Monthly
                            val isMonthlySelected = selectedPlan == "monthly"
                            Surface(
                                onClick = { selectedPlan = "monthly" },
                                shape = RoundedCornerShape(16.dp),
                                color = if (isMonthlySelected) NotelPrimary.copy(alpha = 0.08f) else NotelSurfaceHigh,
                                border = BorderStroke(
                                    width = if (isMonthlySelected) 2.dp else 1.dp,
                                    color = if (isMonthlySelected) NotelPrimary else NotelPrimary.copy(alpha = 0.15f)
                                ),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(16.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    RadioButton(
                                        selected = isMonthlySelected,
                                        onClick = { selectedPlan = "monthly" },
                                        colors = RadioButtonDefaults.colors(
                                            selectedColor = NotelPrimary,
                                            unselectedColor = NotelTextSecondary
                                        )
                                    )
                                    Spacer(Modifier.width(12.dp))
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            text = "Monthly Plan",
                                            color = NotelTextPrimary,
                                            fontWeight = FontWeight.Bold,
                                            fontSize = 16.sp
                                        )
                                        Spacer(Modifier.height(2.dp))
                                        Text(
                                            text = "7-day free trial, then $5.99/mo",
                                            color = NotelTextSecondary,
                                            fontSize = 13.sp
                                        )
                                    }
                                    Surface(
                                        shape = RoundedCornerShape(8.dp),
                                        color = NotelPrimary.copy(alpha = 0.12f),
                                        modifier = Modifier.padding(horizontal = 4.dp)
                                    ) {
                                        Text(
                                            text = "FREE TRIAL",
                                            color = NotelPrimary,
                                            fontSize = 9.sp,
                                            fontWeight = FontWeight.Bold,
                                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                                        )
                                    }
                                }
                            }
                            
                            Spacer(Modifier.height(12.dp))
                            
                            // Plan 2: Yearly
                            val isYearlySelected = selectedPlan == "yearly"
                            Surface(
                                onClick = { selectedPlan = "yearly" },
                                shape = RoundedCornerShape(16.dp),
                                color = if (isYearlySelected) NotelPrimary.copy(alpha = 0.08f) else NotelSurfaceHigh,
                                border = BorderStroke(
                                    width = if (isYearlySelected) 2.dp else 1.dp,
                                    color = if (isYearlySelected) NotelPrimary else NotelPrimary.copy(alpha = 0.15f)
                                ),
                                modifier = Modifier.fillMaxWidth()
                            ) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .padding(16.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    RadioButton(
                                        selected = isYearlySelected,
                                        onClick = { selectedPlan = "yearly" },
                                        colors = RadioButtonDefaults.colors(
                                            selectedColor = NotelPrimary,
                                            unselectedColor = NotelTextSecondary
                                        )
                                    )
                                    Spacer(Modifier.width(12.dp))
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            text = "Yearly Plan",
                                            color = NotelTextPrimary,
                                            fontWeight = FontWeight.Bold,
                                            fontSize = 16.sp
                                        )
                                        Spacer(Modifier.height(2.dp))
                                        Text(
                                            text = "7-day free trial, then $39.99/yr",
                                            color = NotelTextSecondary,
                                            fontSize = 13.sp
                                        )
                                    }
                                    Surface(
                                        shape = RoundedCornerShape(8.dp),
                                        color = Color(0xFF4CAF50).copy(alpha = 0.12f),
                                        modifier = Modifier.padding(horizontal = 4.dp)
                                    ) {
                                        Text(
                                            text = "SAVE 45% • BEST VALUE",
                                            color = Color(0xFF4CAF50),
                                            fontSize = 9.sp,
                                            fontWeight = FontWeight.Bold,
                                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp)
                                        )
                                    }
                                }
                            }
                            
                            Spacer(Modifier.height(24.dp))
                            
                            // CTA Button
                            GlassyButton(
                                onClick = {
                                    activity?.let {
                                        viewModel.purchaseCredits(
                                            it,
                                            if (selectedPlan == "monthly") "jot_membership_monthly" else "jot_membership_yearly"
                                        )
                                    }
                                },
                                modifier = Modifier.fillMaxWidth(),
                                containerColor = NotelPrimary
                            ) {
                                Icon(Icons.Default.Star, null, tint = Color.White, modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(8.dp))
                                Text("Start 7-Day Free Trial", color = Color.White, fontWeight = FontWeight.Bold)
                            }
                            
                            Spacer(Modifier.height(12.dp))
                            
                            Text(
                                text = "Google Play billing applies. Recurring billing. Cancel anytime in Google Play Subscriptions.",
                                color = NotelTextSecondary.copy(alpha = 0.6f),
                                fontSize = 11.sp,
                                textAlign = TextAlign.Center,
                                modifier = Modifier.fillMaxWidth()
                            )
                        } else {
                            Spacer(Modifier.height(20.dp))
                            Text(
                                "Thank you for being a member! Your support keeps Tabs improving.",
                                color = NotelTextSecondary,
                                fontSize = 12.sp,
                                fontWeight = FontWeight.Medium
                            )
                        }
                    } // Close GlassyCard
                } // Close if (currentMenu == SettingsMenu.MEMBERSHIP)

                if (currentMenu == SettingsMenu.MAIN) {
                    // 1. Personal Context Card
                    GlassyCard(shape = RoundedCornerShape(20.dp), color = NotelSurface, modifier = Modifier.onGloballyPositioned { coordPersonalCtx = it }) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Personal Context", color = NotelTextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                            IconButton(
                                onClick = { viewModel.toggleUserContextHidden() },
                                modifier = Modifier.size(48.dp)
                            ) {
                                Icon(
                                    if (userContextHidden) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                                    contentDescription = if (userContextHidden) "Show personal context" else "Hide personal context",
                                    tint = NotelPrimary,
                                    modifier = Modifier.size(22.dp)
                                )
                            }
                        }
                        Spacer(Modifier.height(2.dp))
                        Text("Tell Tabs about your goals (e.g. 'training for a marathon').", color = NotelTextSecondary, fontSize = 12.sp)
                        Spacer(Modifier.height(8.dp))
                        
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .then(if (userContextHidden) Modifier.clickable { viewModel.toggleUserContextHidden() } else Modifier)
                        ) {
                            if (!userContextHidden || userContext.isBlank()) {
                                OutlinedTextField(
                                    value = contextInput, 
                                    onValueChange = { contextInput = it; viewModel.saveUserContext(it) },
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .onFocusChanged { isContextFocused = it.isFocused },
                                    minLines = 2, 
                                    maxLines = 4,
                                    enabled = true,
                                    placeholder = { Text("Add background info here…", color = NotelTextSecondary, fontSize = 12.sp) },
                                    shape = RoundedCornerShape(12.dp),
                                    colors = OutlinedTextFieldDefaults.colors(
                                        focusedBorderColor = NotelPrimary, 
                                        unfocusedBorderColor = NotelSurfaceHigh, 
                                        focusedTextColor = NotelTextPrimary, 
                                        unfocusedTextColor = NotelTextPrimary,
                                        disabledTextColor = NotelTextPrimary,
                                        disabledBorderColor = NotelSurfaceHigh
                                    )
                                )
                            } else {
                                Box(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .height(80.dp)
                                        .background(NotelSurfaceHigh, RoundedCornerShape(12.dp))
                                        .padding(12.dp),
                                    contentAlignment = Alignment.Center
                                ) {
                                    Column(
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        verticalArrangement = Arrangement.Center
                                    ) {
                                        Text(
                                            "Hidden for your privacy", 
                                            color = NotelTextPrimary, 
                                            fontWeight = FontWeight.Bold,
                                            fontSize = 14.sp
                                        )
                                        Spacer(Modifier.height(2.dp))
                                        Text(
                                            "Click eye icon or tap here to reveal", 
                                            color = NotelTextSecondary, 
                                            fontSize = 11.sp
                                        )
                                    }
                                }
                            }
                        }
                    }

                    Spacer(Modifier.height(16.dp))

                    // 2. Main Grouped Settings Card
                    GlassyCard(
                        shape = RoundedCornerShape(20.dp),
                        color = NotelSurface,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Column {
                            // Row 1: User Profile
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { currentMenu = SettingsMenu.USER_PROFILE }
                                    .onGloballyPositioned { coordUserProfile = it }
                                    .padding(horizontal = 16.dp, vertical = 16.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(Icons.Default.Person, contentDescription = null, tint = NotelTextSecondary, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(16.dp))
                                Text("User Profile", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 15.sp, modifier = Modifier.weight(1f))
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = NotelTextSecondary.copy(alpha = 0.6f))
                            }
                            HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.6f), thickness = 1.dp)

                            // Row 2: Customize
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { currentMenu = SettingsMenu.CUSTOMIZE }
                                    .padding(horizontal = 16.dp, vertical = 16.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(Icons.Default.Tune, contentDescription = null, tint = NotelTextSecondary, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(16.dp))
                                Text("Customize", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 15.sp, modifier = Modifier.weight(1f))
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = NotelTextSecondary.copy(alpha = 0.6f))
                            }
                            HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.6f), thickness = 1.dp)

                            // Row 3: AI & Clinical Advocate
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { currentMenu = SettingsMenu.AI_AND_KNOWLEDGE }
                                    .onGloballyPositioned { coordAiKnowledge = it }
                                    .padding(horizontal = 16.dp, vertical = 16.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(Icons.Default.AutoAwesome, contentDescription = null, tint = NotelTextSecondary, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(16.dp))
                                Text("AI & Clinical Advocate", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 15.sp, modifier = Modifier.weight(1f))
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = NotelTextSecondary.copy(alpha = 0.6f))
                            }
                            HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.6f), thickness = 1.dp)

                            // Row 3: Event Counters
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { currentMenu = SettingsMenu.EVENT_COUNTERS }
                                    .onGloballyPositioned { coordEventCounters = it }
                                    .padding(horizontal = 16.dp, vertical = 16.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(Icons.Default.Timer, contentDescription = null, tint = NotelTextSecondary, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(16.dp))
                                Text("Event Counters", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 15.sp, modifier = Modifier.weight(1f))
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = NotelTextSecondary.copy(alpha = 0.6f))
                            }
                            HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.6f), thickness = 1.dp)

                            // Row 4: Notifications
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { currentMenu = SettingsMenu.NOTIFICATIONS }
                                    .padding(horizontal = 16.dp, vertical = 16.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(Icons.Default.Notifications, contentDescription = null, tint = NotelTextSecondary, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(16.dp))
                                Text("Notifications", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 15.sp, modifier = Modifier.weight(1f))
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = NotelTextSecondary.copy(alpha = 0.6f))
                            }
                            HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.6f), thickness = 1.dp)

                            // Row 5: Sync Settings
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { currentMenu = SettingsMenu.SYNC_SETTINGS }
                                    .padding(horizontal = 16.dp, vertical = 16.dp),
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Icon(Icons.Default.Sync, contentDescription = null, tint = NotelTextSecondary, modifier = Modifier.size(22.dp))
                                Spacer(Modifier.width(16.dp))
                                Text("Sync Settings", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 15.sp, modifier = Modifier.weight(1f))
                                Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = NotelTextSecondary.copy(alpha = 0.6f))
                            }

                            // Row 6: Tabs Live Beta (Admins / Unlimited only)
                            if (isAdmin) {
                                HorizontalDivider(color = NotelSurfaceHigh.copy(alpha = 0.6f), thickness = 1.dp)
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { currentMenu = SettingsMenu.JOT_LIVE }
                                        .padding(horizontal = 16.dp, vertical = 16.dp),
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(Icons.Default.Bluetooth, contentDescription = null, tint = NotelTextSecondary, modifier = Modifier.size(22.dp))
                                    Spacer(Modifier.width(16.dp))
                                    Text("Tabs Live Beta", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 15.sp, modifier = Modifier.weight(1f))
                                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = NotelTextSecondary.copy(alpha = 0.6f))
                                }
                            }
                        }
                    }

                    Spacer(Modifier.height(16.dp))

                    // 3. Singled-Out Connected Apps Card
                    GlassyCard(
                        shape = RoundedCornerShape(20.dp),
                        color = NotelSurface,
                        modifier = Modifier
                            .fillMaxWidth()
                            .onGloballyPositioned { coordConnectedApps = it }
                    ) {
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { currentMenu = SettingsMenu.CONNECTED_APPS }
                                .padding(horizontal = 16.dp, vertical = 16.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Icon(Icons.Default.Favorite, contentDescription = null, tint = NotelPrimary, modifier = Modifier.size(22.dp))
                            Spacer(Modifier.width(16.dp))
                            Text("Connected Apps", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 15.sp, modifier = Modifier.weight(1f))
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, contentDescription = null, tint = NotelTextSecondary.copy(alpha = 0.6f))
                        }
                    }

                    Spacer(Modifier.height(24.dp))

                    // 4. Prominent Log Out Pill Button
                    Button(
                        onClick = { showLogoutDialog = true },
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(52.dp),
                        shape = RoundedCornerShape(26.dp),
                        colors = ButtonDefaults.buttonColors(
                            containerColor = Color(0xFF801515),
                            contentColor = Color.White
                        )
                    ) {
                        Text("Log out", fontWeight = FontWeight.Bold, fontSize = 16.sp)
                    }

                    if (isAdmin) {
                        Spacer(Modifier.height(8.dp))
                        Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                            TextButton(onClick = { currentMenu = SettingsMenu.DEBUG }) {
                                Icon(Icons.Default.BugReport, null, tint = NotelTextSecondary.copy(alpha = 0.5f), modifier = Modifier.size(14.dp))
                                Spacer(Modifier.width(4.dp))
                                Text("Developer Terminal Options", color = NotelTextSecondary.copy(alpha = 0.5f), fontSize = 11.sp)
                            }
                        }
                    }

                    Spacer(Modifier.height(24.dp))

                    // 5. Clean Footer Details
                    Column(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalAlignment = Alignment.CenterHorizontally
                    ) {
                        Text(
                            text = "Tabs v1.0",
                            color = NotelTextSecondary,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 13.sp
                        )
                        Spacer(Modifier.height(6.dp))
                        Text(
                            text = "Terms & Disclosures",
                            color = NotelPrimary,
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Medium,
                            modifier = Modifier.clickable {
                                try {
                                    val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse("https://jottracker.com/privacy.html"))
                                    context.startActivity(intent)
                                } catch (_: Exception) {}
                            }
                        )
                        Spacer(Modifier.height(4.dp))
                        TextButton(onClick = { showRestartDialog = true }) {
                            Text("Reset Account Status", color = Color.Red.copy(alpha = 0.5f), fontSize = 10.sp)
                        }
                    }

                    Spacer(Modifier.height(40.dp))
                }

            if (currentMenu == SettingsMenu.CUSTOMIZE) {
                Text("NAVIGATION & APPEARANCE", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))

                GlassyCard(
                    shape = RoundedCornerShape(16.dp),
                    color = NotelSurface
                ) {
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(vertical = 4.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Show Navigation Bar Labels", color = NotelTextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 14.sp)
                            Spacer(Modifier.height(2.dp))
                            Text("Display text under icons in bottom navigation banner", color = NotelTextSecondary, fontSize = 11.sp)
                        }
                        Switch(
                            checked = showNavLabels,
                            onCheckedChange = { viewModel.setShowNavLabels(it) },
                            colors = SwitchDefaults.colors(
                                checkedThumbColor = NotelTextPrimary,
                                checkedTrackColor = NotelPrimary
                            )
                        )
                    }
                }
            }

            if (currentMenu == SettingsMenu.EVENT_COUNTERS) {
            Text("EVENT COUNTER", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))

            val eventCounters by viewModel.eventCounters.collectAsState()
            val cHistory by viewModel.counterHistory.collectAsState()

            var showCounterDialog by remember { mutableStateOf(false) }
            var editCounter by remember { mutableStateOf<com.notel.notel.ui.viewmodel.EventCounterDto?>(null) }

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
            Spacer(Modifier.height(16.dp))

            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface
            ) {
                if (eventCounters.isNotEmpty()) {
                    val activeCounters = eventCounters.filter { !it.isArchived }
                    val archivedCounters = eventCounters.filter { it.isArchived }

                    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        activeCounters.forEach { counter ->
                            val todayStart = java.util.Calendar.getInstance().apply {
                                set(java.util.Calendar.HOUR_OF_DAY, 0)
                                set(java.util.Calendar.MINUTE, 0)
                                set(java.util.Calendar.SECOND, 0)
                                set(java.util.Calendar.MILLISECOND, 0)
                            }.timeInMillis
                            val daysRemaining = Math.max(0L, Math.abs(todayStart - counter.targetDate) / 86400000L)
                            val isUp = counter.isUp || (counter.autoUp && todayStart > counter.targetDate)
                            val direction = if (isUp) "since" else "until"
                            
                            GlassyCard(
                                shape = RoundedCornerShape(12.dp),
                                color = NotelSurfaceHigh.copy(alpha = 0.5f)
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
                                        onClick = { viewModel.toggleArchiveCounter(counter.id) },
                                        modifier = Modifier.size(48.dp)
                                    ) {
                                        Icon(Icons.Default.Archive, "Archive counter ${counter.name}", tint = NotelTextSecondary, modifier = Modifier.size(20.dp))
                                    }
                                    IconButton(
                                        onClick = { 
                                            editCounter = counter
                                            showCounterDialog = true
                                        },
                                        modifier = Modifier.size(48.dp)
                                    ) {
                                        Icon(Icons.Default.Edit, "Edit counter ${counter.name}", tint = NotelTextSecondary, modifier = Modifier.size(20.dp))
                                    }
                                    IconButton(
                                        onClick = { viewModel.endCounterAndSave(counter.id) },
                                        modifier = Modifier.size(48.dp)
                                    ) {
                                        Icon(Icons.Default.Delete, "End counter ${counter.name}", tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(20.dp))
                                    }
                                }
                            }
                        }

                        if (archivedCounters.isNotEmpty()) {
                            Spacer(Modifier.height(8.dp))
                            Text("ARCHIVED", fontSize = 10.sp, color = NotelTextSecondary, fontWeight = FontWeight.Black, modifier = Modifier.padding(horizontal = 4.dp))
                            archivedCounters.forEach { counter ->
                                val todayStart = java.util.Calendar.getInstance().apply {
                                    set(java.util.Calendar.HOUR_OF_DAY, 0)
                                    set(java.util.Calendar.MINUTE, 0)
                                    set(java.util.Calendar.SECOND, 0)
                                    set(java.util.Calendar.MILLISECOND, 0)
                                }.timeInMillis
                                val daysRemaining = Math.max(0L, Math.abs(todayStart - counter.targetDate) / 86400000L)
                                val isUp = counter.isUp || (counter.autoUp && todayStart > counter.targetDate)
                                val direction = if (isUp) "since" else "until"

                                GlassyCard(
                                    shape = RoundedCornerShape(12.dp),
                                    color = NotelSurfaceHigh.copy(alpha = 0.2f)
                                ) {
                                    Row(
                                        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 6.dp).alpha(0.5f),
                                        verticalAlignment = Alignment.CenterVertically
                                    ) {
                                        Column(modifier = Modifier.weight(1f)) {
                                            Text(counter.name, color = NotelTextPrimary, fontWeight = FontWeight.SemiBold, fontSize = 12.sp)
                                            Text("$daysRemaining days $direction", color = NotelTextSecondary, fontSize = 10.sp)
                                        }
                                        IconButton(
                                            onClick = { viewModel.toggleArchiveCounter(counter.id) },
                                            modifier = Modifier.size(48.dp)
                                        ) {
                                            Icon(Icons.Default.Unarchive, "Unarchive counter ${counter.name}", tint = NotelTextSecondary, modifier = Modifier.size(20.dp))
                                        }
                                        IconButton(
                                            onClick = { viewModel.endCounterAndSave(counter.id) },
                                            modifier = Modifier.size(48.dp)
                                        ) {
                                            Icon(Icons.Default.Delete, "End counter ${counter.name}", tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(20.dp))
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("Track important upcoming or past events. All active counters will show on the main screen and sync with the AI.", color = NotelTextSecondary, fontSize = 12.sp)
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
                    Text("PHYSICIAN PROTOCOLS", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                    Spacer(Modifier.height(8.dp))

                    var showProfessionalDialog by remember { mutableStateOf(false) }

                    GlassyCard(
                        shape = RoundedCornerShape(16.dp),
                        color = NotelSurface
                    ) {
                        Text("New Physician Protocol", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                        Spacer(Modifier.height(4.dp))
                        Text(
                            "Did your doctor or specialist suggest a new protocol, medication change, or routine? Add it here for AI compliance tracking.",
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
                                        Text("New Clinical Protocol", fontSize = 18.sp, fontWeight = FontWeight.Bold, color = NotelTextPrimary)
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

                // ── FILE KNOWLEDGE BASE + ORIGINAL DOCUMENTS (merged) ────────────
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
                                                val titleText = "Extraction ${index + 1}"
                                                
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

                    // ── ORIGINAL DOCUMENTS (collapsible, inside same card) ────────
                    if (knowledgeDocuments.isNotEmpty()) {
                        Spacer(Modifier.height(16.dp))
                        HorizontalDivider(color = NotelSurfaceHigh, thickness = 0.5.dp)
                        Spacer(Modifier.height(12.dp))

                        var isDocsExpanded by remember { mutableStateOf(false) }
                        var showClearAllDialog by remember { mutableStateOf(false) }

                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { isDocsExpanded = !isDocsExpanded }
                                .padding(vertical = 4.dp),
                            horizontalArrangement = Arrangement.SpaceBetween,
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(
                                    Icons.Default.Folder,
                                    contentDescription = null,
                                    tint = NotelPrimary,
                                    modifier = Modifier.size(16.dp)
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    "Original Documents (${knowledgeDocuments.size})",
                                    color = NotelPrimary,
                                    fontSize = 12.sp,
                                    fontWeight = FontWeight.Bold
                                )
                            }
                            Icon(
                                if (isDocsExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                                contentDescription = "Toggle Documents",
                                tint = NotelPrimary
                            )
                        }

                        if (isDocsExpanded) {
                            Spacer(Modifier.height(8.dp))
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                knowledgeDocuments.forEach { doc ->
                                    DocumentTile(
                                        doc = doc,
                                        onView = { onNavigateToFile(doc.name, doc.filePath, doc.mimeType, doc.id) },
                                        onDelete = { viewModel.deleteDocument(doc) }
                                    )
                                }
                            }

                            if (knowledgeDocuments.isNotEmpty()) {
                                Row(
                                    modifier = Modifier
                                        .fillMaxWidth()
                                        .clickable { showClearAllDialog = true }
                                        .padding(vertical = 12.dp),
                                    horizontalArrangement = Arrangement.Center,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    Icon(Icons.Default.DeleteSweep, null, tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(14.dp))
                                    Spacer(Modifier.width(4.dp))
                                    Text("Clear All Files", color = MaterialTheme.colorScheme.error, fontSize = 11.sp, fontWeight = FontWeight.Medium)
                                }
                            }

                            if (showClearAllDialog) {
                                AlertDialog(
                                    onDismissRequest = { showClearAllDialog = false },
                                    title = { Text("Clear All Files?", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                                    text = { Text("This will permanently delete all ${knowledgeDocuments.size} uploaded files. This cannot be undone.", color = NotelTextSecondary) },
                                    confirmButton = {
                                        TextButton(onClick = {
                                            viewModel.clearAllDocuments()
                                            showClearAllDialog = false
                                        }) {
                                            Text("Delete All", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold)
                                        }
                                    },
                                    dismissButton = {
                                        TextButton(onClick = { showClearAllDialog = false }) {
                                            Text("Cancel", color = NotelTextSecondary)
                                        }
                                    },
                                    containerColor = NotelSurface
                                )
                            }
                        }
                    }
                } // end GlassyCard

                Spacer(Modifier.height(24.dp))
                Text("AI CONFIGURATION", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                GlassyCard(
                    shape = RoundedCornerShape(16.dp),
                    color = NotelSurface
                ) {
                    Column(verticalArrangement = Arrangement.spacedBy(20.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Auto AI Pings", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                Text(
                                    "Automatically load smart tiles when opening the app.",
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

                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Daily Cup Score", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                Text(
                                    "A daily notification summarizing your Body Cup score calculation.",
                                    color = NotelTextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                            Switch(
                                checked = dailyCupUpdatesEnabled,
                                onCheckedChange = { checkAndToggle(it) { enabled -> viewModel.setDailyCupUpdatesEnabled(enabled) } },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = NotelPrimary,
                                    checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                    uncheckedThumbColor = NotelTextSecondary,
                                    uncheckedTrackColor = NotelSurfaceHigh
                                )
                            )
                        }
                    }
                }

                Spacer(Modifier.height(24.dp))

                Text("CLINICAL ADVOCACY", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))

                GlassyCard(
                    shape = RoundedCornerShape(16.dp),
                    color = NotelSurface
                ) {
                    Text("Audit (PDF)", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Generate a data-dense PDF summary of your trends, spikes, and compliance for your physician.",
                        color = NotelTextSecondary,
                        fontSize = 12.sp
                    )
                    
                    val isGenerating by viewModel.isGeneratingReport.collectAsState()
                    val generatedFile by viewModel.generatedReport.collectAsState()
                    val hasLogs = viewModel.allLogs.collectAsState().value.isNotEmpty()
                    val isDeepBusy by viewModel.isGeneratingDeepResearch.collectAsState()
                    val isProtocolBusy by viewModel.isGeneratingWeeklyRecap.collectAsState()
                    
                    val isAnyAiBusy = isGenerating || isDeepBusy || isProtocolBusy
                    var activeReportType by remember { mutableStateOf<String?>(null) }
                    
                    LaunchedEffect(isGenerating) {
                        if (!isGenerating) {
                            activeReportType = null
                        }
                    }

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

                    Row(
                        modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Max),
                        horizontalArrangement = Arrangement.spacedBy(12.dp)
                    ) {
                        val isFullGenerating = isGenerating && activeReportType == "full"
                        GlassyButton(
                            onClick = {
                                activeReportType = "full"
                                viewModel.generateProfessionalReport(last30DaysOnly = false)
                            },
                            modifier = Modifier.weight(1f).fillMaxHeight(),
                            enabled = !isAnyAiBusy && hasLogs,
                            containerColor = NotelSurfaceHigh
                        ) {
                            if (isFullGenerating) {
                                GlassySpinner(size = 18.dp)
                            } else {
                                Icon(
                                    Icons.Default.PictureAsPdf,
                                    null,
                                    tint = if (!isAnyAiBusy && hasLogs) NotelPrimary else NotelTextSecondary.copy(alpha = 0.4f),
                                    modifier = Modifier.size(18.dp)
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    "Full Audit",
                                    color = if (!isAnyAiBusy && hasLogs) NotelTextPrimary else NotelTextSecondary.copy(alpha = 0.4f),
                                    fontSize = 12.sp,
                                    maxLines = 1
                                )
                            }
                        }

                        val isMonthGenerating = isGenerating && activeReportType == "month"
                        GlassyButton(
                            onClick = {
                                activeReportType = "month"
                                viewModel.generateProfessionalReport(last30DaysOnly = true)
                            },
                            modifier = Modifier.weight(1f).fillMaxHeight(),
                            enabled = !isAnyAiBusy && hasLogs,
                            containerColor = NotelSurfaceHigh
                        ) {
                            if (isMonthGenerating) {
                                GlassySpinner(size = 18.dp)
                            } else {
                                Icon(
                                    Icons.Default.PictureAsPdf,
                                    null,
                                    tint = if (!isAnyAiBusy && hasLogs) NotelPrimary else NotelTextSecondary.copy(alpha = 0.4f),
                                    modifier = Modifier.size(18.dp)
                                )
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    "This Month",
                                    color = if (!isAnyAiBusy && hasLogs) NotelTextPrimary else NotelTextSecondary.copy(alpha = 0.4f),
                                    fontSize = 12.sp,
                                    maxLines = 1
                                )
                            }
                        }
                    }

                    Spacer(Modifier.height(16.dp))
                    HorizontalDivider(color = NotelSurfaceHigh, thickness = 0.5.dp)
                    Spacer(Modifier.height(16.dp))

                    // NEW: Deep Research & Protocol Comparison
                    Text("AI Research Terminal", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                    Spacer(Modifier.height(4.dp))
                    Text(
                        "Run advanced multi-point analysis on your long-term data and uploaded protocols.",
                        color = NotelTextSecondary,
                        fontSize = 12.sp
                    )
                    Spacer(Modifier.height(16.dp))

                    Row(modifier = Modifier.fillMaxWidth().height(IntrinsicSize.Max), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                        GlassyButton(
                            onClick = { viewModel.generateDeepResearch() },
                            modifier = Modifier.weight(1f).fillMaxHeight(),
                            enabled = !isAnyAiBusy && hasLogs,
                            containerColor = NotelSurfaceHigh
                        ) {
                            if (isDeepBusy) GlassySpinner(size = 18.dp)
                            else {
                                Icon(Icons.Default.Search, null, tint = if (!isAnyAiBusy && hasLogs) NotelPrimary else NotelTextSecondary.copy(alpha = 0.4f), modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text("Deep Audit", color = if (!isAnyAiBusy && hasLogs) NotelTextPrimary else NotelTextSecondary.copy(alpha = 0.4f), fontSize = 12.sp, maxLines = 1)
                            }
                        }

                        GlassyButton(
                            onClick = { viewModel.generateWeeklyRecap() },
                            modifier = Modifier.weight(1f).fillMaxHeight(),
                            enabled = !isAnyAiBusy && hasLogs,
                            containerColor = NotelSurfaceHigh
                        ) {
                            if (isProtocolBusy) GlassySpinner(size = 18.dp)
                            else {
                                Icon(Icons.Default.AssignmentTurnedIn, null, tint = if (!isAnyAiBusy && hasLogs) NotelPrimary else NotelTextSecondary.copy(alpha = 0.4f), modifier = Modifier.size(18.dp))
                                Spacer(Modifier.width(6.dp))
                                Text("Weekly Recap", color = if (!isAnyAiBusy && hasLogs) NotelTextPrimary else NotelTextSecondary.copy(alpha = 0.4f), fontSize = 11.sp, maxLines = 1, softWrap = false)
                            }
                        }
                    }

                    if (!hasLogs) {
                        Spacer(Modifier.height(6.dp))
                        Text(
                            "Add some notes first to generate a report.",
                            color = NotelTextSecondary.copy(alpha = 0.5f),
                            fontSize = 11.sp
                        )
                    }
                }

                Spacer(Modifier.height(24.dp))

                Text("AI INSIGHTS HISTORY", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))

                if (aiInsights.isEmpty()) {
                    Text("No AI insights generated yet. Perform an AI action to see it here.", color = NotelTextSecondary, fontSize = 14.sp)
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
                            val displayInsights = remember(aiInsights) {
                                aiInsights.filter { it.type != "BodyLoad" && it.type != "Biometrics" }.take(15)
                            }
                            displayInsights.forEach { insight ->
                                InsightTile(insight = insight, onDelete = { viewModel.deleteAiInsight(insight.id) })
                            }
                        }
                    }
                }
                Spacer(Modifier.height(24.dp))
            }
            if (currentMenu == SettingsMenu.CONNECTED_APPS) {
                


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

            Text("INTEGRATED APPS", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))

            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface
            ) {
                if (googleCalendarConnected) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.CalendarMonth, null, tint = NotelPrimary, modifier = Modifier.size(28.dp))
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Google Calendar Active", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                            Text("Connected as $googleCalendarEmail", color = NotelTextSecondary, fontSize = 12.sp)
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    GlassyButton(
                        onClick = { viewModel.disconnectGoogleCalendar() },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelSurfaceHigh
                    ) {
                        Text("Disconnect Google Calendar", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                    }
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.CalendarMonth, null, tint = NotelTextSecondary, modifier = Modifier.size(28.dp))
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Google Calendar", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                            Text("Let your AI Clinical Advocate schedule events and update calendars.", color = NotelTextSecondary, fontSize = 12.sp)
                        }
                    }
                    Spacer(Modifier.height(16.dp))
                    GlassyButton(
                        onClick = {
                            try {
                                val intent = AccountManager.newChooseAccountIntent(
                                    null,
                                    null,
                                    arrayOf("com.google"),
                                    false,
                                    null,
                                    null,
                                    null,
                                    null
                                )
                                googleAccountChooserLauncher.launch(intent)
                            } catch (e: Exception) {
                                e.printStackTrace()
                            }
                        },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelPrimary.copy(alpha = 0.8f)
                    ) {
                        Text("Connect Google Calendar", color = Color.White, fontWeight = FontWeight.Bold)
                    }
                }
            }

            Spacer(Modifier.height(24.dp))

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


            Spacer(Modifier.height(24.dp))

            }


            if (currentMenu == SettingsMenu.USER_PROFILE) {
            Text("USER PROFILE", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(8.dp))

            var editingNickname by remember { mutableStateOf("") }
            var isEditingNickname by remember { mutableStateOf(false) }
            var nicknameError by remember { mutableStateOf<String?>(null) }
            var isSavingNickname by remember { mutableStateOf(false) }

            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface,
                modifier = Modifier.padding(bottom = 16.dp)
            ) {
                Column(modifier = Modifier.fillMaxWidth().padding(16.dp)) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                        modifier = Modifier.fillMaxWidth()
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(
                                imageVector = Icons.Default.Face,
                                contentDescription = null,
                                tint = NotelPrimary,
                                modifier = Modifier.size(28.dp)
                            )
                            Spacer(Modifier.width(12.dp))
                            Column {
                                Text("Nickname", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                if (!isEditingNickname) {
                                    Row(verticalAlignment = Alignment.CenterVertically) {
                                        Text(
                                            text = userNickname.ifBlank { "Not set" },
                                            color = if (userNickname.isBlank()) NotelTextSecondary else NotelPrimary,
                                            fontSize = 14.sp,
                                            fontWeight = FontWeight.SemiBold
                                        )
                                        if (userNickname.isNotBlank() && userTag.isNotBlank()) {
                                            Spacer(Modifier.width(4.dp))
                                            Text(
                                                text = "#$userTag",
                                                color = NotelTextSecondary,
                                                fontSize = 12.sp,
                                                fontWeight = FontWeight.Medium
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        
                        if (!isEditingNickname) {
                            GlassyButton(
                                onClick = {
                                    editingNickname = userNickname
                                    nicknameError = null
                                    isEditingNickname = true
                                },
                                containerColor = NotelSurfaceHigh
                            ) {
                                Text("Edit", color = NotelTextPrimary, fontSize = 12.sp)
                            }
                        }
                    }

                    if (isEditingNickname) {
                        Spacer(Modifier.height(12.dp))
                        OutlinedTextField(
                            value = editingNickname,
                            onValueChange = {
                                editingNickname = it
                                nicknameError = null
                            },
                            placeholder = { Text("Enter nickname...", color = NotelTextSecondary) },
                            singleLine = true,
                            isError = nicknameError != null,
                            colors = OutlinedTextFieldDefaults.colors(
                                focusedBorderColor = NotelPrimary,
                                cursorColor = NotelPrimary,
                                focusedTextColor = NotelTextPrimary,
                                unfocusedTextColor = NotelTextPrimary
                            ),
                            modifier = Modifier.fillMaxWidth()
                        )
                        if (nicknameError != null) {
                            Spacer(Modifier.height(4.dp))
                            Text(
                                text = nicknameError!!,
                                color = androidx.compose.ui.graphics.Color(0xFFFF5252),
                                fontSize = 11.sp
                            )
                        }

                        Spacer(Modifier.height(12.dp))
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(8.dp),
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            GlassyButton(
                                onClick = { isEditingNickname = false },
                                modifier = Modifier.weight(1f),
                                containerColor = NotelSurfaceHigh
                            ) {
                                Text("Cancel", color = NotelTextPrimary)
                            }
                            GlassyButton(
                                onClick = {
                                    isSavingNickname = true
                                    viewModel.updateNickname(editingNickname) { success, error ->
                                        isSavingNickname = false
                                        if (success) {
                                            isEditingNickname = false
                                        } else {
                                            nicknameError = error ?: "Unknown error"
                                        }
                                    }
                                },
                                enabled = !isSavingNickname,
                                modifier = Modifier.weight(1f),
                                containerColor = NotelPrimary
                            ) {
                                if (isSavingNickname) {
                                    CircularProgressIndicator(
                                        color = NotelTextPrimary,
                                        modifier = Modifier.size(16.dp),
                                        strokeWidth = 2.dp
                                    )
                                } else {
                                    Text("Save", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                                }
                            }
                        }
                    }
                }
            }
            
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
                    val roundedHeight = Math.round(userHeight)
                    val ft = roundedHeight / 12
                    val inch = roundedHeight % 12
                    Text("Height: $ft'$inch\" ($roundedHeight in)", color = NotelTextSecondary, fontSize = 13.sp)
                }
                if (userWeight > 0f) Text("Weight: ${Math.round(userWeight)} lbs", color = NotelTextSecondary, fontSize = 13.sp)
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
                val heightInches = Math.round(userHeight)
                val initialFeet = if (heightInches > 0) (heightInches / 12).toString() else ""
                val initialInches = if (heightInches > 0) (heightInches % 12).toString() else ""
                var editHeightFeet by remember { mutableStateOf(initialFeet) }
                var editHeightInches by remember { mutableStateOf(initialInches) }
                var editWeight by remember { mutableStateOf(if (userWeight > 0f) Math.round(userWeight).toString() else "") }
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
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(8.dp)
                            ) {
                                OutlinedTextField(
                                    value = editHeightFeet,
                                    onValueChange = { editHeightFeet = it },
                                    label = { Text("Height (ft)") },
                                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number),
                                    singleLine = true,
                                    modifier = Modifier.weight(1f),
                                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary, focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary)
                                )
                                OutlinedTextField(
                                    value = editHeightInches,
                                    onValueChange = { editHeightInches = it },
                                    label = { Text("Height (in)") },
                                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(keyboardType = androidx.compose.ui.text.input.KeyboardType.Number),
                                    singleLine = true,
                                    modifier = Modifier.weight(1f),
                                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary, focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary)
                                )
                            }
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
                            val feet = editHeightFeet.toIntOrNull() ?: 0
                            val inches = editHeightInches.toIntOrNull() ?: 0
                            val totalInches = (feet * 12 + inches).toFloat()
                            viewModel.saveUserProfile(
                                age = editAge.toIntOrNull() ?: 0,
                                height = totalInches,
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

            Spacer(Modifier.height(16.dp))

            // Medications section
            var isMedicationsExpanded by remember { mutableStateOf(false) }
            val medicationsList by viewModel.medications.collectAsState()
            var showAddMedicationDialog by remember { mutableStateOf(false) }

            // AI Import states
            var aiText by remember { mutableStateOf("") }
            var selectedDocText by remember { mutableStateOf("") }
            var selectedDocName by remember { mutableStateOf("No document selected") }
            var isDocDropdownExpanded by remember { mutableStateOf(false) }
            var isAiExtracting by remember { mutableStateOf(false) }
            var aiError by remember { mutableStateOf<String?>(null) }

            // Manual Add states
            var newMedName by remember { mutableStateOf("") }
            var newMedStartDate by remember { mutableStateOf("") }
            var newMedEndDate by remember { mutableStateOf("") }
            var newMedIsPresent by remember { mutableStateOf(true) }

            // Dialog tab state
            var addTabMode by remember { mutableStateOf(0) } // 0 = Manual, 1 = AI Import

            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface
            ) {
                Box(modifier = Modifier.fillMaxWidth()) {
                    Column(modifier = Modifier.fillMaxWidth()) {
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { isMedicationsExpanded = !isMedicationsExpanded }
                        ) {
                            Icon(Icons.Default.Medication, null, tint = NotelPrimary, modifier = Modifier.size(28.dp))
                            Spacer(Modifier.width(12.dp))
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Medications", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                Text("Track your current and historical medications", color = NotelTextSecondary, fontSize = 12.sp)
                            }
                            Icon(
                                imageVector = if (isMedicationsExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                                contentDescription = if (isMedicationsExpanded) "Collapse" else "Expand",
                                tint = NotelTextSecondary
                            )
                        }

                        if (isMedicationsExpanded) {
                            Spacer(Modifier.height(16.dp))
                            if (medicationsList.isEmpty()) {
                                Text(
                                    "No medications added yet. Tap the + button to add one manually.",
                                    color = NotelTextSecondary,
                                    fontSize = 13.sp,
                                    modifier = Modifier.padding(bottom = 8.dp)
                                )
                            } else {
                                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                    medicationsList.forEach { med ->
                                        Row(
                                            modifier = Modifier
                                                .fillMaxWidth()
                                                .background(NotelSurfaceHigh.copy(alpha = 0.3f), RoundedCornerShape(12.dp))
                                                .padding(12.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.SpaceBetween
                                        ) {
                                            Column(modifier = Modifier.weight(1f)) {
                                                Text(med.name, color = NotelTextPrimary, fontWeight = FontWeight.Bold, fontSize = 14.sp)
                                                val dateRange = if (med.isPresent) {
                                                    "Started: ${med.startDate} • Present"
                                                } else {
                                                    "Started: ${med.startDate} • Ended: ${med.endDate}"
                                                }
                                                Text(dateRange, color = NotelTextSecondary, fontSize = 12.sp)
                                            }
                                            IconButton(
                                                onClick = { viewModel.deleteMedication(med.id) },
                                                modifier = Modifier.size(24.dp)
                                            ) {
                                                Icon(Icons.Default.Delete, "Delete", tint = MaterialTheme.colorScheme.error, modifier = Modifier.size(20.dp))
                                            }
                                        }
                                    }
                                }
                            }
                            Spacer(Modifier.height(48.dp)) // padding so the floating + button doesn't overlap content
                        }
                    }

                    // Floating + Button inside the bottom right of the card when expanded
                    if (isMedicationsExpanded) {
                        FloatingActionButton(
                            onClick = { showAddMedicationDialog = true },
                            containerColor = NotelPrimary,
                            contentColor = Color.White,
                            modifier = Modifier
                                .align(Alignment.BottomEnd)
                                .size(40.dp)
                                .padding(0.dp),
                            shape = RoundedCornerShape(12.dp)
                        ) {
                            Icon(Icons.Default.Add, "Add Medication", modifier = Modifier.size(20.dp))
                        }
                    }
                }
            }

            if (showAddMedicationDialog) {
                AlertDialog(
                    onDismissRequest = { showAddMedicationDialog = false },
                    title = { Text("Add Medication", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = {
                        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                            OutlinedTextField(
                                value = newMedName,
                                onValueChange = { newMedName = it },
                                label = { Text("Medication Name", color = NotelTextSecondary) },
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary, focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary)
                            )
                            OutlinedTextField(
                                value = newMedStartDate,
                                onValueChange = { newMedStartDate = it },
                                label = { Text("Started Date (e.g. Jun 2026)", color = NotelTextSecondary) },
                                singleLine = true,
                                colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary, focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary)
                            )
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable { newMedIsPresent = !newMedIsPresent }
                            ) {
                                Checkbox(
                                    checked = newMedIsPresent,
                                    onCheckedChange = { newMedIsPresent = it },
                                    colors = CheckboxDefaults.colors(checkedColor = NotelPrimary)
                                )
                                Spacer(Modifier.width(8.dp))
                                Text("Still taking (Present)", color = NotelTextPrimary, fontSize = 14.sp)
                            }
                            if (!newMedIsPresent) {
                                OutlinedTextField(
                                    value = newMedEndDate,
                                    onValueChange = { newMedEndDate = it },
                                    label = { Text("Ended Date (e.g. Jul 2026)", color = NotelTextSecondary) },
                                    singleLine = true,
                                    colors = OutlinedTextFieldDefaults.colors(focusedBorderColor = NotelPrimary, cursorColor = NotelPrimary, focusedTextColor = NotelTextPrimary, unfocusedTextColor = NotelTextPrimary)
                                )
                            }
                        }
                    },
                    confirmButton = {
                        TextButton(
                            onClick = {
                                if (newMedName.isNotBlank()) {
                                    viewModel.addMedication(
                                        name = newMedName,
                                        startDate = newMedStartDate,
                                        endDate = newMedEndDate,
                                        isPresent = newMedIsPresent
                                    )
                                    // Reset fields
                                    newMedName = ""
                                    newMedStartDate = ""
                                    newMedEndDate = ""
                                    newMedIsPresent = true
                                    showAddMedicationDialog = false
                                }
                            },
                            enabled = newMedName.isNotBlank()
                        ) {
                            Text("Add", color = NotelPrimary)
                        }
                    },
                    dismissButton = {
                        TextButton(
                            onClick = { showAddMedicationDialog = false }
                        ) {
                            Text("Cancel", color = NotelTextSecondary)
                        }
                    },
                    containerColor = NotelSurface
                )
            }

            Spacer(Modifier.height(16.dp))

            // Privacy & Deletion section (GDPR & CCPA Compliant)
            var showDeleteAccountConfirmDialog by remember { mutableStateOf(false) }
            var isDeletingAccount by remember { mutableStateOf(false) }
            var accountDeleteError by remember { mutableStateOf<String?>(null) }
            var isPrivacyExpanded by remember { mutableStateOf(false) }

            GlassyCard(
                shape = RoundedCornerShape(16.dp),
                color = NotelSurface
            ) {
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { isPrivacyExpanded = !isPrivacyExpanded }
                ) {
                    Icon(Icons.Default.Security, null, tint = NotelPrimary, modifier = Modifier.size(28.dp))
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Privacy & Deletion", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                        Text("GDPR / CCPA compliance data deletion options", color = NotelTextSecondary, fontSize = 12.sp)
                    }
                    Icon(
                        imageVector = if (isPrivacyExpanded) Icons.Default.KeyboardArrowUp else Icons.Default.KeyboardArrowDown,
                        contentDescription = if (isPrivacyExpanded) "Collapse" else "Expand",
                        tint = NotelTextSecondary
                    )
                }

                if (isPrivacyExpanded) {
                    Spacer(Modifier.height(12.dp))
                    Text(
                        "You have the right to request deletion of all your sync information, logs, files, and credentials from our cloud servers and database permanently.",
                        color = NotelTextSecondary,
                        fontSize = 11.sp
                    )
                    Spacer(Modifier.height(16.dp))
                    GlassyButton(
                        onClick = { showDeleteAccountConfirmDialog = true },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = MaterialTheme.colorScheme.error.copy(alpha = 0.15f)
                    ) {
                        Text("Permanently Delete Account & Data", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold)
                    }

                    if (accountDeleteError != null) {
                        Spacer(Modifier.height(8.dp))
                        Text(accountDeleteError!!, color = MaterialTheme.colorScheme.error, fontSize = 12.sp)
                    }
                }
            }

            if (showDeleteAccountConfirmDialog) {
                AlertDialog(
                    onDismissRequest = { if (!isDeletingAccount) showDeleteAccountConfirmDialog = false },
                    title = { Text("Delete Account and Data?", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = {
                        Text(
                            "This action is permanent and cannot be undone. All your notes, history, files, health sync logs, and account profiles will be instantly purged from our servers and database.",
                            color = NotelTextSecondary,
                            fontSize = 14.sp
                        )
                    },
                    confirmButton = {
                        TextButton(
                            onClick = {
                                isDeletingAccount = true
                                viewModel.deleteAccount(
                                    onSuccess = {
                                        isDeletingAccount = false
                                        showDeleteAccountConfirmDialog = false
                                        onLogout() // Wipes current local session state and redirects to login screen
                                    },
                                    onError = { error ->
                                        isDeletingAccount = false
                                        accountDeleteError = error
                                    }
                                )
                            },
                            enabled = !isDeletingAccount
                        ) {
                            if (isDeletingAccount) {
                                GlassySpinner(size = 18.dp)
                            } else {
                                Text("Delete Permanently", color = MaterialTheme.colorScheme.error)
                            }
                        }
                    },
                    dismissButton = {
                        TextButton(
                            onClick = { showDeleteAccountConfirmDialog = false },
                            enabled = !isDeletingAccount
                        ) {
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
                                    "A daily ping at 9:00 AM to check your Cup level, unless you've already logged in.",
                                    color = NotelTextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                            Switch(
                                checked = bodyLoadRemindersEnabled,
                                onCheckedChange = { checkAndToggle(it) { enabled -> viewModel.setBodyLoadRemindersEnabled(enabled) } },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = NotelPrimary,
                                    checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                    uncheckedThumbColor = NotelTextSecondary,
                                    uncheckedTrackColor = NotelSurfaceHigh
                                )
                            )
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
                                onCheckedChange = { checkAndToggle(it) { enabled -> viewModel.setHabitReminderEnabled(enabled) } },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = NotelPrimary,
                                    checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                    uncheckedThumbColor = NotelTextSecondary,
                                    uncheckedTrackColor = NotelSurfaceHigh
                                )
                            )
                        }

                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Project Reminders", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                Text(
                                    "Daily ping at 8:00 PM if you have unchecked project tasks remaining.",
                                    color = NotelTextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                            Switch(
                                checked = projectReminderEnabled,
                                onCheckedChange = { checkAndToggle(it) { enabled -> viewModel.setProjectReminderEnabled(enabled) } },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = NotelPrimary,
                                    checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                    uncheckedThumbColor = NotelTextSecondary,
                                    uncheckedTrackColor = NotelSurfaceHigh
                                )
                            )
                        }

                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text("Event Reminders", color = NotelTextPrimary, fontWeight = FontWeight.Medium)
                                Text(
                                    "Daily ping at 9:00 AM on the day of scheduled events.",
                                    color = NotelTextSecondary,
                                    fontSize = 11.sp
                                )
                            }
                            Switch(
                                checked = eventReminderEnabled,
                                onCheckedChange = { checkAndToggle(it) { enabled -> viewModel.setEventReminderEnabled(enabled) } },
                                colors = SwitchDefaults.colors(
                                    checkedThumbColor = NotelPrimary,
                                    checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                                    uncheckedThumbColor = NotelTextSecondary,
                                    uncheckedTrackColor = NotelSurfaceHigh
                                )
                            )
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
                                    onCheckedChange = { checked ->
                                        checkAndToggle(checked) { it ->
                                            viewModel.setHrSpikeAlertsEnabled(it)
                                            if (it && (tempSpikeThreshold.isBlank() || (tempSpikeThreshold.toIntOrNull() ?: 0) < 40)) {
                                                tempSpikeThreshold = "110"
                                                viewModel.setSpikeThreshold(110)
                                            }
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
                        }
                    }
                }
            }

            val isSyncing by viewModel.isSyncing.collectAsState()
            
            LaunchedEffect(Unit) {
                viewModel.syncError.collect { msg ->
                    snackbarHostState.showSnackbar(msg)
                }
            }

            // ── Sync Settings Screen ─────────────────────────────────────
            if (currentMenu == SettingsMenu.SYNC_SETTINGS) {
                val isManualSyncing by viewModel.isManualSyncing.collectAsState()
                val isRecovering by viewModel.isRecovering.collectAsState()
                val lastSyncTimeSync by viewModel.lastSyncTime.collectAsState()

                Text("PRIVACY", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                GlassyCard(shape = RoundedCornerShape(16.dp), color = NotelSurface) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text("Share data with friends", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 14.sp)
                            Text("Allow mutual friends to see your daily sleep, heart rate, and score", color = NotelTextSecondary, fontSize = 11.sp)
                        }
                        Switch(
                            checked = shareDataWithFriends,
                            onCheckedChange = { viewModel.setShareDataWithFriends(it) },
                            colors = SwitchDefaults.colors(checkedThumbColor = Color.White, checkedTrackColor = NotelPrimary)
                        )
                    }
                }

                Spacer(Modifier.height(24.dp))
                Text("MANUAL SYNC", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                GlassyCard(shape = RoundedCornerShape(16.dp), color = NotelSurface) {
                    Text(
                        "Manually push all your local data to the cloud and pull the latest from the server. This happens automatically in the background, but you can trigger it here anytime.",
                        color = NotelTextSecondary,
                        fontSize = 12.sp
                    )
                    Spacer(Modifier.height(12.dp))
                    GlassyButton(
                        onClick = { viewModel.manualSync() },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelPrimary,
                        enabled = !isManualSyncing && !isRecovering
                    ) {
                        if (isManualSyncing) {
                            GlassySpinner(size = 20.dp)
                            Spacer(Modifier.width(8.dp))
                            Text("Syncing...", color = Color.White, fontWeight = FontWeight.Bold)
                        } else {
                            Icon(Icons.Default.CloudUpload, "Sync", tint = Color.White)
                            Spacer(Modifier.width(8.dp))
                            Text("Sync Now", color = Color.White, fontWeight = FontWeight.Bold)
                        }
                    }
                    if (lastSyncTimeSync > 0L) {
                        Spacer(Modifier.height(8.dp))
                        val formatted = java.text.SimpleDateFormat("MMM d, h:mm a", java.util.Locale.getDefault())
                            .format(java.util.Date(lastSyncTimeSync))
                        Text(
                            "Last synced: $formatted",
                            color = NotelTextSecondary.copy(alpha = 0.6f),
                            fontSize = 11.sp
                        )
                    }
                }

                Spacer(Modifier.height(24.dp))
                Text("RECOVERY", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                GlassyCard(shape = RoundedCornerShape(16.dp), color = NotelSurface) {
                    Text(
                        "If your data appears missing or out of date, use this to pull a fresh copy from the server and restore everything.",
                        color = NotelTextSecondary,
                        fontSize = 12.sp
                    )
                    Spacer(Modifier.height(12.dp))
                    GlassyButton(
                        onClick = { viewModel.recoverAccountData() },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelSurfaceHigh,
                        enabled = !isRecovering && !isManualSyncing
                    ) {
                        if (isRecovering) {
                            GlassySpinner(size = 20.dp)
                            Spacer(Modifier.width(8.dp))
                            Text("Recovering...", color = NotelTextSecondary, fontWeight = FontWeight.Bold)
                        } else {
                            Icon(Icons.Default.CloudDownload, "Recover", tint = NotelPrimary)
                            Spacer(Modifier.width(8.dp))
                            Text("Recover Account Data", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                        }
                    }
                }

                Spacer(Modifier.height(24.dp))
                Text("LOCAL CACHE", fontSize = 12.sp, color = NotelTextSecondary, fontWeight = FontWeight.SemiBold)
                Spacer(Modifier.height(8.dp))
                GlassyCard(shape = RoundedCornerShape(16.dp), color = NotelSurface) {
                    Text(
                        "Delete all locally cached Key Metrics (weights, breathing rates, SpO2, and resting heart rates) saved on this device. This triggers a fresh sync from Health Connect or Fitbit on your next reload.",
                        color = NotelTextSecondary,
                        fontSize = 12.sp
                    )
                    Spacer(Modifier.height(12.dp))
                    GlassyButton(
                        onClick = { viewModel.clearKeyMetricsCache() },
                        modifier = Modifier.fillMaxWidth(),
                        containerColor = NotelSurfaceHigh
                    ) {
                        Icon(Icons.Default.DeleteSweep, "Clear Cache", tint = Color(0xFFFF8A65))
                        Spacer(Modifier.width(8.dp))
                        Text("Clear Key Metrics Cache", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                    }
                }
            }

            if (currentMenu == SettingsMenu.JOT_LIVE) {
                val hasAsked by viewModel.hasVisibleBandAsked.collectAsState()
                var showAskedDialog by remember { mutableStateOf(false) }
                var showWarningDialog by remember { mutableStateOf(false) }
                var lastAskedState by remember { mutableStateOf<Boolean?>(null) }

                LaunchedEffect(hasAsked) {
                    if (lastAskedState != hasAsked) {
                        lastAskedState = hasAsked
                        if (!hasAsked) {
                            showAskedDialog = true
                        }
                    }
                }

                if (showAskedDialog) {
                    AlertDialog(
                        onDismissRequest = { 
                            showAskedDialog = false
                            viewModel.markVisibleBandAsked()
                        },
                        title = { Text("Visible Band", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                        text = { Text("Do you have a Visible Band?", color = NotelTextSecondary) },
                        confirmButton = {
                            TextButton(onClick = {
                                showAskedDialog = false
                                viewModel.markVisibleBandAsked()
                            }) {
                                Text("Yes", color = NotelPrimary, fontWeight = FontWeight.Bold)
                            }
                        },
                        dismissButton = {
                            TextButton(onClick = {
                                showAskedDialog = false
                                showWarningDialog = true
                            }) {
                                Text("No", color = NotelTextSecondary)
                            }
                        },
                        containerColor = NotelSurface
                    )
                }

                if (showWarningDialog) {
                    AlertDialog(
                        onDismissRequest = {
                            showWarningDialog = false
                            viewModel.markVisibleBandAsked()
                        },
                        title = { Text("Notice", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                        text = { Text("This feature may not work and works best with a visible band.", color = NotelTextSecondary) },
                        confirmButton = {
                            TextButton(onClick = {
                                showWarningDialog = false
                                viewModel.markVisibleBandAsked()
                            }) {
                                Text("OK", color = NotelPrimary, fontWeight = FontWeight.Bold)
                            }
                        },
                        containerColor = NotelSurface
                    )
                }

                // Render the main Jot Live monitor panel content
                TabsLiveScreenContent(viewModel = viewModel)
            }



            

            if (showLogoutDialog) {
                val logoutError by viewModel.logoutError.collectAsState()
                val isLoggingOut by viewModel.isLoggingOut.collectAsState()
                
                AlertDialog(
                    onDismissRequest = { if (!isLoggingOut) { showLogoutDialog = false; viewModel.clearLogoutError() } },
                    title = { Text("Logout?", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = { 
                        Column {
                            Text(
                                if (isLoggingOut) "Saving and syncing your data to the cloud. Please wait..."
                                else "Your data will be synced to the cloud before logging out.",
                                color = NotelTextSecondary
                            )
                            if (logoutError != null) {
                                Spacer(Modifier.height(12.dp))
                                Text(
                                    logoutError!!,
                                    color = MaterialTheme.colorScheme.error,
                                    fontSize = 13.sp,
                                    fontWeight = FontWeight.Medium
                                )
                            }
                        }
                    },
                    confirmButton = {
                        TextButton(
                            onClick = {
                                viewModel.logout {
                                    showLogoutDialog = false
                                    onLogout()
                                }
                            },
                            enabled = !isLoggingOut
                        ) {
                            if (isLoggingOut) {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    GlassySpinner(size = 18.dp)
                                    Spacer(Modifier.width(8.dp))
                                    Text("Saving...", color = NotelPrimary)
                                }
                            } else {
                                Text("Logout", color = NotelPrimary)
                            }
                        }
                    },
                    dismissButton = {
                        TextButton(
                            onClick = { showLogoutDialog = false; viewModel.clearLogoutError() },
                            enabled = !isLoggingOut
                        ) {
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
    if (showAllTimeTelemetryGraph) {
        Dialog(onDismissRequest = { showAllTimeTelemetryGraph = false }) {
            Surface(
                shape = RoundedCornerShape(24.dp),
                color = NotelSurface,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(420.dp)
                    .liquidGlass(shape = RoundedCornerShape(24.dp), color = NotelSurface, alpha = 0.95f)
            ) {
                Column(
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(20.dp),
                    horizontalAlignment = Alignment.CenterHorizontally
                ) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically
                    ) {
                        Text(
                            text = "ALL-TIME TELEMETRY HISTORY",
                            fontSize = 12.sp,
                            fontWeight = FontWeight.Bold,
                            color = NotelTextPrimary
                        )
                        IconButton(onClick = { showAllTimeTelemetryGraph = false }) {
                            Icon(Icons.Default.Close, contentDescription = "Close", tint = NotelTextSecondary)
                        }
                    }

                    Spacer(modifier = Modifier.height(16.dp))

                    if (isPullingTelemetry) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(220.dp),
                            contentAlignment = Alignment.Center
                        ) {
                            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                                CircularProgressIndicator(color = NotelPrimary, modifier = Modifier.size(32.dp))
                                Spacer(modifier = Modifier.height(12.dp))
                                Text("Fetching live heart history from server...", color = NotelTextSecondary, fontSize = 11.sp)
                            }
                        }
                    } else {
                        if (telemetryPoints.isEmpty()) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(220.dp),
                                contentAlignment = Alignment.Center
                            ) {
                                Text("No telemetry history found on server.", color = NotelTextSecondary, fontSize = 12.sp)
                            }
                        } else {
                            InteractiveTelemetryGraph(
                                records = telemetryPoints,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(220.dp),
                                lineColor = NotelPrimary
                            )
                        }
                    }

                    Spacer(modifier = Modifier.height(16.dp))

                    Text(
                        text = "Total Points: ${telemetryPoints.size} | Sync: Connected",
                        fontSize = 11.sp,
                        color = NotelTextSecondary,
                        fontWeight = FontWeight.SemiBold
                    )
                }
            }
        }
    }
    }
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
            val formattedInsightText = remember(insight.text) {
                var txt = insight.text
                if (txt.contains("<") && txt.contains(">")) {
                    txt = android.text.Html.fromHtml(txt, android.text.Html.FROM_HTML_MODE_LEGACY).toString()
                }
                txt.replace("[SECTION]", "")
                   .replace("[BULLET]", "•")
                   .replace("[ITALIC]", "")
                   .replace("[BOLD]", "")
                   .replace("*", "")
                   .trim()
            }
            Text(
                text = formattedInsightText,
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
    viewModel: SettingsViewModel,
    padding: PaddingValues
) {
    val context = LocalContext.current
    val logs by viewModel.systemLogs.collectAsState()
    
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(padding)
            .padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 80.dp)
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
                GlassyButton(onClick = { viewModel.testHabitNotification(context) }, modifier = Modifier.fillMaxWidth()) {
                    Text("Habit", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
            
            item {
                GlassyButton(onClick = { viewModel.testProjectNotification(context) }, modifier = Modifier.fillMaxWidth()) {
                    Text("Project", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
            item {
                GlassyButton(onClick = { viewModel.testSpikeNotification(context) }, modifier = Modifier.fillMaxWidth()) {
                    Text("Spike", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
            item {
                GlassyButton(onClick = { viewModel.testReminderNotification(context) }, modifier = Modifier.fillMaxWidth()) {
                    Text("Reminder", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
            item {
                GlassyButton(onClick = { viewModel.recoverAccountData() }, modifier = Modifier.fillMaxWidth(), containerColor = NotelSurfaceHigh) {
                    Text("Force Sync", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
            item {
                GlassyButton(onClick = { viewModel.refreshThisWeeksScores() }, modifier = Modifier.fillMaxWidth(), containerColor = NotelSurfaceHigh) {
                    Text("Refresh Week", color = NotelTextPrimary, fontSize = 10.sp)
                }
            }
        }
        
        Spacer(Modifier.height(16.dp))
        Text("Modify Streaks", color = NotelTextSecondary, fontWeight = FontWeight.Bold)
        Spacer(Modifier.height(8.dp))
        
        var customCurrentStr by remember { mutableStateOf("") }
        var customBestStr by remember { mutableStateOf("") }
        
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            OutlinedTextField(
                value = customCurrentStr,
                onValueChange = { customCurrentStr = it },
                label = { Text("Current", fontSize = 10.sp) },
                modifier = Modifier.weight(1f),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = NotelTextPrimary,
                    unfocusedTextColor = NotelTextPrimary,
                    focusedBorderColor = NotelPrimary,
                    unfocusedBorderColor = NotelSurfaceHigh
                ),
                singleLine = true
            )
            OutlinedTextField(
                value = customBestStr,
                onValueChange = { customBestStr = it },
                label = { Text("Best", fontSize = 10.sp) },
                modifier = Modifier.weight(1f),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedTextColor = NotelTextPrimary,
                    unfocusedTextColor = NotelTextPrimary,
                    focusedBorderColor = NotelPrimary,
                    unfocusedBorderColor = NotelSurfaceHigh
                ),
                singleLine = true
            )
            GlassyButton(
                onClick = {
                    val currentVal = customCurrentStr.toIntOrNull() ?: 0
                    val bestVal = customBestStr.toIntOrNull() ?: 0
                    viewModel.setCustomStreak(currentVal, bestVal)
                    customCurrentStr = ""
                    customBestStr = ""
                },
                modifier = Modifier.padding(top = 4.dp),
                containerColor = NotelPrimary
            ) {
                Text("Set", color = Color.White, fontSize = 12.sp, fontWeight = FontWeight.Bold)
            }
        }

        Spacer(Modifier.height(16.dp))

        // ── Last Sync Report ─────────────────────────────────────────────────
        val syncLines = logs.filter { it.body.startsWith("SYNC_") }
        if (syncLines.isNotEmpty()) {
            // Find the most recent SYNC_START to slice out the latest cycle
            val lastStartIdx = syncLines.indexOfLast { it.body.startsWith("SYNC_START") }
            val currentCycle = if (lastStartIdx >= 0) syncLines.drop(lastStartIdx) else syncLines

            Text("Last Sync Report", color = NotelTextSecondary, fontWeight = FontWeight.Bold)
            Spacer(Modifier.height(8.dp))
            androidx.compose.foundation.layout.Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color.Black.copy(alpha = 0.4f), shape = RoundedCornerShape(10.dp))
                    .padding(12.dp)
            ) {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    currentCycle.forEach { entry ->
                        val (icon, tint, label) = when {
                            entry.body.startsWith("SYNC_OK")    -> Triple("✓", Color(0xFF4CAF50), entry.body.removePrefix("SYNC_OK: "))
                            entry.body.startsWith("SYNC_FAIL")  -> Triple("✗", Color(0xFFE53935), entry.body.removePrefix("SYNC_FAIL: "))
                            entry.body.startsWith("SYNC_SKIP")  -> Triple("–", Color(0xFFFFA726), entry.body.removePrefix("SYNC_SKIP: "))
                            entry.body.startsWith("SYNC_DONE")  -> Triple("✓", Color(0xFF4CAF50), entry.body.removePrefix("SYNC_DONE: "))
                            entry.body.startsWith("SYNC_ERROR") -> Triple("✗", Color(0xFFE53935), entry.body.removePrefix("SYNC_ERROR: "))
                            entry.body.startsWith("SYNC_START") -> Triple("→", Color(0xFF90CAF9), entry.body.removePrefix("SYNC_START: "))
                            else -> Triple("·", NotelTextSecondary, entry.body)
                        }
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            Text(icon, color = tint, fontSize = 13.sp, fontWeight = FontWeight.Black,
                                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
                                modifier = Modifier.width(16.dp))
                            Text(label, color = tint, fontSize = 11.sp,
                                fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
                        }
                    }
                }
            }
            Spacer(Modifier.height(16.dp))
        }

        // ── Raw System Log ────────────────────────────────────────────────────
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

@Composable
fun DocumentTile(
    doc: com.notel.notel.data.local.entity.KnowledgeDocument,
    onView: () -> Unit,
    onDelete: () -> Unit
) {
    val isExtracted = !doc.extractedText.isNullOrBlank()
    Surface(
        onClick = onView,
        shape = RoundedCornerShape(12.dp),
        color = NotelSurfaceHigh.copy(alpha = 0.5f),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(12.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Box {
                Icon(
                    imageVector = when {
                        doc.mimeType == "application/pdf" -> Icons.Default.PictureAsPdf
                        doc.mimeType.startsWith("image/") -> Icons.Default.Image
                        else -> Icons.Default.Description
                    },
                    contentDescription = null,
                    tint = NotelPrimary,
                    modifier = Modifier.size(28.dp)
                )
                if (isExtracted) {
                    Box(
                        modifier = Modifier
                            .size(10.dp)
                            .align(Alignment.TopEnd)
                            .background(
                                color = Color(0xFF4CAF50),
                                shape = CircleShape
                            )
                    )
                }
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = doc.name,
                    color = NotelTextPrimary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = when (doc.mimeType) {
                            "application/pdf" -> "PDF"
                            "text/plain" -> "Text"
                            else -> doc.mimeType.substringAfter("/").uppercase()
                        },
                        color = NotelTextSecondary,
                        fontSize = 10.sp
                    )
                    if (isExtracted) {
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "• AI read",
                            color = Color(0xFF4CAF50),
                            fontSize = 10.sp,
                            fontWeight = FontWeight.Medium
                        )
                    } else {
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = "• Extracting…",
                            color = NotelTextSecondary.copy(alpha = 0.6f),
                            fontSize = 10.sp
                        )
                    }
                }
            }
            
            var showDeleteDialog by remember { mutableStateOf(false) }
            
            IconButton(onClick = { showDeleteDialog = true }, modifier = Modifier.size(32.dp)) {
                Icon(
                    Icons.Default.Delete, 
                    "Delete document", 
                    tint = MaterialTheme.colorScheme.error.copy(alpha = 0.6f),
                    modifier = Modifier.size(18.dp)
                )
            }
            
            if (showDeleteDialog) {
                AlertDialog(
                    onDismissRequest = { showDeleteDialog = false },
                    title = { Text("Trash File?", color = NotelTextPrimary, fontWeight = FontWeight.Bold) },
                    text = { Text("Are you sure you want to permanently delete '${doc.name}'?", color = NotelTextSecondary) },
                    confirmButton = {
                        TextButton(onClick = {
                            onDelete()
                            showDeleteDialog = false
                        }) {
                            Text("Delete", color = MaterialTheme.colorScheme.error, fontWeight = FontWeight.Bold)
                        }
                    },
                    dismissButton = {
                        TextButton(onClick = { showDeleteDialog = false }) {
                            Text("Cancel", color = NotelTextSecondary)
                        }
                    },
                    containerColor = NotelSurface
                )
            }
        }
    }
}

@Composable
fun TabsLiveScreenContent(
    viewModel: SettingsViewModel
) {
    val context = LocalContext.current
    val connectionState by viewModel.bleConnectionState.collectAsState()
    val scannedDevices by viewModel.scannedBleDevices.collectAsState()
    val liveHeartRate by viewModel.liveHeartRate.collectAsState()
    val rawBytes by viewModel.bleRawBytes.collectAsState()
    
    val isServiceRunning by viewModel.isHrLoggingServiceRunning.collectAsState()
    val isSwitchingConnection by viewModel.isBleSwitchingConnection.collectAsState()
    val bleAutoConnectEnabled by viewModel.bleAutoConnectEnabled.collectAsState()

    var savedFiles by remember {
        mutableStateOf(context.filesDir.listFiles { _, name -> name.endsWith(".csv") }?.toList() ?: emptyList())
    }



    var selectedGraphFile by remember { mutableStateOf<java.io.File?>(null) }
    var showGattParamsDialog by remember { mutableStateOf(false) }

    val refreshFilesList = {
        savedFiles = context.filesDir.listFiles { _, name -> name.endsWith(".csv") }?.toList() ?: emptyList()
    }

    val activeFileName by viewModel.hrActiveFileName.collectAsState()

    val activeFile = remember(activeFileName) {
        val fileName = activeFileName
        if (fileName != null) {
            java.io.File(context.filesDir, fileName)
        } else null
    }

    var liveSessionPoints by remember { mutableStateOf<List<com.notel.notel.data.HeartRateRecord>>(emptyList()) }

    val serviceMinHr by viewModel.hrSessionMin.collectAsState()
    val serviceMaxHr by viewModel.hrSessionMax.collectAsState()
    val serviceMax15sJump by viewModel.hrMax15sJump.collectAsState()

    val realtimeMin = if (isServiceRunning) (serviceMinHr ?: 0) else 0
    val realtimeMax = if (isServiceRunning) (serviceMaxHr ?: 0) else 0
    val realtime15sJump = if (isServiceRunning) (serviceMax15sJump ?: 0) else 0

    LaunchedEffect(isServiceRunning, liveHeartRate, activeFile) {
        if (isServiceRunning && activeFile != null && activeFile.exists()) {
            val list = mutableListOf<com.notel.notel.data.HeartRateRecord>()
            try {
                activeFile.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        val parts = line.split(",")
                        if (parts.size >= 2) {
                            // CSV stores BPM as "[76 BPM]" — strip brackets and label before parsing
                            val rawBpm = parts[1].replace("[", "").replace("]", "").replace("BPM", "").trim()
                            rawBpm.toIntOrNull()?.let { bpm ->
                                val time = parts[0].trim()
                                if (time.contains(":") && !time.contains("BPM")) {
                                    list.add(com.notel.notel.data.HeartRateRecord(time, bpm))
                                }
                            }
                        }
                    }
                }
            } catch (e: Exception) {
                e.printStackTrace()
            }
            liveSessionPoints = list
        } else {
            liveSessionPoints = emptyList()
        }
    }

    val requiredPermissions = remember {
        val basePermissions = if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT
            )
        } else {
            arrayOf(
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.BLUETOOTH,
                Manifest.permission.BLUETOOTH_ADMIN
            )
        }
        
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
            basePermissions + Manifest.permission.POST_NOTIFICATIONS
        } else {
            basePermissions
        }
    }

    var hasPermissions by remember {
        mutableStateOf(
            requiredPermissions.all {
                ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
            }
        )
    }

    val launcher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestMultiplePermissions()
    ) { results ->
        hasPermissions = results.values.all { it }
    }

    if (!hasPermissions) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Icon(
                imageVector = Icons.Default.Warning,
                contentDescription = "Warning",
                tint = NotelPrimary,
                modifier = Modifier.size(48.dp)
            )
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = "Permissions Required",
                color = NotelTextPrimary,
                fontWeight = FontWeight.Bold,
                fontSize = 16.sp
            )
            Spacer(modifier = Modifier.height(6.dp))
            Text(
                text = "Tabs Live Beta requires Bluetooth and Notification permissions to connect to your band and record logs in the background.",
                color = NotelTextSecondary,
                fontSize = 12.sp,
                textAlign = TextAlign.Center
            )
            Spacer(modifier = Modifier.height(16.dp))
            GlassyButton(
                onClick = { launcher.launch(requiredPermissions) },
                containerColor = NotelPrimary
            ) {
                Text("Grant Permissions", color = Color.White, fontWeight = FontWeight.Bold)
            }
        }
        return
    }

    Column(
        modifier = Modifier.fillMaxWidth(),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Text(
            text = "JOT LIVE BETA",
            fontSize = 20.sp,
            fontWeight = FontWeight.ExtraBold,
            color = NotelPrimary,
            letterSpacing = 2.sp,
            modifier = Modifier.padding(vertical = 8.dp)
        )

        // Pulse heart animation card
        HeartMonitorCard(
            connectionState = if (isServiceRunning) com.notel.notel.data.ConnectionState.Connected("Background Log", "ACTIVE") else connectionState,
            heartRate = liveHeartRate,
            modifier = Modifier.height(260.dp)
        )

        Spacer(modifier = Modifier.height(16.dp))

        // Session statistics card
        GlassyCard(
            shape = RoundedCornerShape(16.dp),
            color = NotelSurface
        ) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(8.dp),
                horizontalArrangement = Arrangement.SpaceAround,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("HIGHEST", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = NotelTextSecondary)
                    Spacer(modifier = Modifier.height(2.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = if (realtimeMax > 0) "$realtimeMax" else "-",
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            color = NotelPrimary
                        )
                        Spacer(modifier = Modifier.width(2.dp))
                        Text("BPM", fontSize = 8.sp, color = NotelTextSecondary)
                    }
                }
                Box(modifier = Modifier.width(1.dp).height(24.dp).background(NotelSurfaceHigh))
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("MAX JUMP (15S)", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = NotelTextSecondary)
                    Spacer(modifier = Modifier.height(2.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = if (realtime15sJump > 0) "$realtime15sJump" else "-",
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            color = NotelPrimary
                        )
                        Spacer(modifier = Modifier.width(2.dp))
                        Text("BPM", fontSize = 8.sp, color = NotelTextSecondary)
                    }
                }
                Box(modifier = Modifier.width(1.dp).height(24.dp).background(NotelSurfaceHigh))
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("LOWEST", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = NotelTextSecondary)
                    Spacer(modifier = Modifier.height(2.dp))
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = if (realtimeMin > 0) "$realtimeMin" else "-",
                            fontSize = 18.sp,
                            fontWeight = FontWeight.Bold,
                            color = NotelPrimary
                        )
                        Spacer(modifier = Modifier.width(2.dp))
                        Text("BPM", fontSize = 8.sp, color = NotelTextSecondary)
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Device Controls & Scan List Panel
        GlassyCard(
            shape = RoundedCornerShape(16.dp),
            color = NotelSurface
        ) {
            Column(modifier = Modifier.padding(16.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = if (isServiceRunning && !isSwitchingConnection) "ACTIVE SESSION LOG" else "BAND MONITORING",
                        fontSize = 12.sp,
                        fontWeight = FontWeight.Bold,
                        color = NotelTextPrimary
                    )

                    Row(verticalAlignment = Alignment.CenterVertically) {
                        if (isServiceRunning && !isSwitchingConnection) {
                            IconButton(onClick = { showGattParamsDialog = true }) {
                                Icon(Icons.Default.Settings, "GATT Params", tint = NotelTextSecondary)
                            }
                            Spacer(modifier = Modifier.width(4.dp))
                            Button(
                                onClick = {
                                    viewModel.stopHrLoggingService()
                                    refreshFilesList()
                                },
                                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFFFF4D4D).copy(alpha = 0.2f)),
                                shape = RoundedCornerShape(8.dp),
                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                                modifier = Modifier.height(28.dp)
                            ) {
                                Text("STOP LOG", color = Color(0xFFFF4D4D), fontSize = 10.sp, fontWeight = FontWeight.Bold)
                            }
                        } else {
                            val isScanning = connectionState is com.notel.notel.data.ConnectionState.Scanning
                            Button(
                                onClick = {
                                    if (isScanning) viewModel.stopBleScan() else viewModel.startBleScan()
                                },
                                colors = ButtonDefaults.buttonColors(
                                    containerColor = if (isScanning) Color(0xFFFF4D4D).copy(alpha = 0.2f) else NotelPrimary
                                ),
                                shape = RoundedCornerShape(12.dp)
                            ) {
                                if (isScanning) {
                                    CircularProgressIndicator(modifier = Modifier.size(12.dp), color = Color(0xFFFF4D4D), strokeWidth = 2.dp)
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Text("STOP SCAN", color = Color(0xFFFF4D4D), fontSize = 10.sp)
                                } else {
                                    Icon(Icons.Default.Refresh, "Scan", modifier = Modifier.size(12.dp))
                                    Spacer(modifier = Modifier.width(4.dp))
                                    Text("SCAN BAND", fontSize = 10.sp, color = Color.White)
                                }
                            }
                        }
                    }
                }

                // Add compact Auto Connect row inside the Band Monitoring box
                Spacer(modifier = Modifier.height(10.dp))
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(8.dp))
                        .background(NotelSurfaceHigh.copy(alpha = 0.3f))
                        .padding(horizontal = 10.dp, vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Auto Connect", color = NotelTextPrimary, fontWeight = FontWeight.Medium, fontSize = 12.sp)
                        Text("Re-connect automatically when band is near", color = NotelTextSecondary, fontSize = 9.sp)
                    }
                    Switch(
                        checked = bleAutoConnectEnabled,
                        onCheckedChange = { viewModel.setBleAutoConnectEnabled(it) },
                        modifier = Modifier.scale(0.8f),
                        colors = SwitchDefaults.colors(
                            checkedThumbColor = NotelPrimary,
                            checkedTrackColor = NotelPrimary.copy(alpha = 0.4f),
                            uncheckedThumbColor = NotelTextSecondary,
                            uncheckedTrackColor = NotelSurfaceHigh
                        )
                    )
                }

                Spacer(modifier = Modifier.height(8.dp))

                if (isServiceRunning && !isSwitchingConnection) {
                    Text("LIVE GRAPH (SESSION HISTORY)", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = NotelPrimary)
                    Spacer(modifier = Modifier.height(4.dp))
                    InteractiveHeartRateGraph(
                        records = liveSessionPoints,
                        lineColor = NotelPrimary,
                        modifier = Modifier.fillMaxWidth().height(160.dp)
                    )
                } else if (scannedDevices.isEmpty() && connectionState is com.notel.notel.data.ConnectionState.Scanning) {
                    Box(modifier = Modifier.fillMaxWidth().height(100.dp), contentAlignment = Alignment.Center) {
                        Column(horizontalAlignment = Alignment.CenterHorizontally) {
                            CircularProgressIndicator(modifier = Modifier.size(20.dp), color = NotelPrimary)
                            Spacer(modifier = Modifier.height(8.dp))
                            Text("Searching for BLE heart rate bands...", color = NotelTextSecondary, fontSize = 11.sp)
                        }
                    }
                } else if (scannedDevices.isEmpty()) {
                    Box(modifier = Modifier.fillMaxWidth().height(80.dp), contentAlignment = Alignment.Center) {
                        Text("No band connected. Tap SCAN BAND to scan.", color = NotelTextSecondary, fontSize = 12.sp)
                    }
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        scannedDevices.forEach { device ->
                            DeviceRow(
                                device = device,
                                onClick = {
                                    if (isSwitchingConnection) {
                                        viewModel.connectBleDevice(device)
                                    } else {
                                        viewModel.startHrLoggingService(device)
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Saved sessions CSV log lists
        SavedSessionsPanel(
            savedFiles = savedFiles,
            onViewGraph = { file -> selectedGraphFile = file },
            onShare = { file -> shareCsvFile(context, file) },
            onDelete = { file ->
                viewModel.deleteSessionCsvFile(file) {
                    refreshFilesList()
                }
            },
            modifier = Modifier.fillMaxWidth()
        )
    }

    selectedGraphFile?.let { file ->
        SessionGraphDialog(
            file = file,
            onDismissRequest = { selectedGraphFile = null }
        )
    }
}

@Composable
fun InteractiveTelemetryGraph(
    records: List<com.notel.notel.data.TelemetryPoint>,
    modifier: Modifier = Modifier,
    lineColor: Color = NotelPrimary
) {
    if (records.size < 2) {
        Box(
            modifier = modifier.background(NotelSurfaceHigh.copy(alpha = 0.5f), RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center
        ) {
            Text("No telemetry data synchronized yet.", color = NotelTextSecondary, fontSize = 11.sp)
        }
        return
    }

    val minBpm = records.minOf { it.bpm }
    val maxBpm = records.maxOf { it.bpm }

    val minLimit = (minBpm - 5).coerceAtLeast(0)
    val maxLimit = maxBpm + 5
    val range = maxLimit - minLimit

    var touchX by remember { mutableStateOf<Float?>(null) }
    var selectedRecord by remember { mutableStateOf<com.notel.notel.data.TelemetryPoint?>(null) }

    val textPaint = remember {
        android.graphics.Paint().apply {
            color = android.graphics.Color.GRAY
            textSize = 28f
            typeface = android.graphics.Typeface.MONOSPACE
            textAlign = android.graphics.Paint.Align.RIGHT
        }
    }

    val labelPaint = remember {
        android.graphics.Paint().apply {
            color = android.graphics.Color.WHITE
            textSize = 24f
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            textAlign = android.graphics.Paint.Align.CENTER
        }
    }

    val sdf = remember { java.text.SimpleDateFormat("MM/dd h:mm a", java.util.Locale.getDefault()) }
    val tooltipSdf = remember { java.text.SimpleDateFormat("MMM dd, h:mm:ss a", java.util.Locale.getDefault()) }

    Box(
        modifier = modifier
            .background(NotelSurfaceHigh.copy(alpha = 0.3f), RoundedCornerShape(12.dp))
            .border(1.dp, NotelSurfaceHigh, RoundedCornerShape(12.dp))
    ) {
        androidx.compose.foundation.Canvas(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = 16.dp, bottom = 24.dp, start = 16.dp, end = 52.dp)
                .pointerInput(records) {
                    detectDragGestures(
                        onDragStart = { offset -> touchX = offset.x },
                        onDrag = { change, _ -> touchX = change.position.x },
                        onDragEnd = { touchX = null; selectedRecord = null },
                        onDragCancel = { touchX = null; selectedRecord = null }
                    )
                }
        ) {
            val width = size.width
            val height = size.height

            val yLines = 3
            for (i in 0 until yLines) {
                val fraction = i.toFloat() / (yLines - 1)
                val y = height * fraction
                val value = maxLimit - (fraction * range).toInt()
                
                drawLine(
                    color = NotelSurfaceHigh,
                    start = Offset(0f, y),
                    end = Offset(width, y),
                    strokeWidth = 1.dp.toPx()
                )
                
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        "$value",
                        width + 42.dp.toPx(),
                        y + 4.dp.toPx(),
                        textPaint
                    )
                }
            }

            val path = androidx.compose.ui.graphics.Path()
            val fillPath = androidx.compose.ui.graphics.Path()

            records.forEachIndexed { index, record ->
                val x = index * (width / (records.size - 1))
                val y = height - (record.bpm - minLimit) * (height / range)

                if (index == 0) {
                    path.moveTo(x, y)
                    fillPath.moveTo(x, height)
                    fillPath.lineTo(x, y)
                } else {
                    path.lineTo(x, y)
                    fillPath.lineTo(x, y)
                }

                if (index == records.size - 1) {
                    fillPath.lineTo(x, height)
                    fillPath.close()
                }
            }

            drawPath(
                path = fillPath,
                brush = Brush.verticalGradient(
                    colors = listOf(lineColor.copy(alpha = 0.2f), Color.Transparent)
                )
            )

            drawPath(
                path = path,
                color = lineColor,
                style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx())
            )

            if (records.size >= 2) {
                val indicesToShow = listOf(0, records.size / 2, records.size - 1)
                indicesToShow.forEach { idx ->
                    val record = records[idx]
                    val x = idx * (width / (records.size - 1))
                    val cleanTime = sdf.format(java.util.Date(record.timestamp))

                    drawIntoCanvas { canvas ->
                        canvas.nativeCanvas.drawText(
                            cleanTime,
                            x,
                            height + 18.dp.toPx(),
                            labelPaint
                        )
                    }
                }
            }

            touchX?.let { tx ->
                val coercedX = tx.coerceIn(0f, width)
                val index = (coercedX / width * (records.size - 1)).toInt().coerceIn(0, records.size - 1)
                val record = records[index]
                selectedRecord = record

                val x = index * (width / (records.size - 1))
                val y = height - (record.bpm - minLimit) * (height / range)

                drawLine(
                    color = Color.White.copy(alpha = 0.5f),
                    start = Offset(x, 0f),
                    end = Offset(x, height),
                    strokeWidth = 1.dp.toPx()
                )

                drawCircle(
                    color = lineColor,
                    radius = 4.dp.toPx(),
                    center = Offset(x, y)
                )
                drawCircle(
                    color = Color.White,
                    radius = 2.dp.toPx(),
                    center = Offset(x, y)
                )
            }
        }

        selectedRecord?.let { record ->
            Card(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(8.dp)
                    .border(1.dp, lineColor.copy(alpha = 0.3f), RoundedCornerShape(8.dp)),
                colors = CardDefaults.cardColors(containerColor = NotelSurfaceHigh),
                shape = RoundedCornerShape(8.dp)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "${record.bpm} BPM",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = lineColor
                    )
                    Text(
                        text = tooltipSdf.format(java.util.Date(record.timestamp)),
                        fontSize = 9.sp,
                        color = NotelTextSecondary
                    )
                }
            }
        }
    }
}

@Composable
fun HeartMonitorCard(
    connectionState: com.notel.notel.data.ConnectionState,
    heartRate: Int?,
    modifier: Modifier = Modifier
) {
    val bpm = heartRate ?: 70
    val pulseDuration = (60000 / bpm).coerceIn(300, 2000)

    val infiniteTransition = androidx.compose.animation.core.rememberInfiniteTransition(label = "pulse")
    val scale by infiniteTransition.animateFloat(
        initialValue = 1f,
        targetValue = 1.25f,
        animationSpec = androidx.compose.animation.core.infiniteRepeatable(
            animation = androidx.compose.animation.core.tween(durationMillis = pulseDuration / 2, easing = androidx.compose.animation.core.FastOutSlowInEasing),
            repeatMode = androidx.compose.animation.core.RepeatMode.Reverse
        ),
        label = "heartScale"
    )

    GlassyCard(
        shape = RoundedCornerShape(24.dp),
        color = NotelSurface,
        modifier = modifier.fillMaxWidth()
    ) {
        Box(
            modifier = Modifier.fillMaxSize().padding(16.dp),
            contentAlignment = Alignment.Center
        ) {
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                val tintColor = if (heartRate != null) NotelPrimary else NotelTextSecondary.copy(alpha = 0.3f)
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.size(110.dp)
                ) {
                    if (heartRate != null) {
                        Box(
                            modifier = Modifier
                                .size(90.dp)
                                .scale(scale)
                                .background(NotelPrimary.copy(alpha = 0.1f), shape = CircleShape)
                        )
                    }

                    Icon(
                        imageVector = Icons.Default.Favorite,
                        contentDescription = "Pulsing Heart",
                        tint = tintColor,
                        modifier = Modifier
                            .size(75.dp)
                            .scale(if (heartRate != null) scale else 1f)
                    )
                }

                Spacer(modifier = Modifier.height(8.dp))

                Text(
                    text = heartRate?.toString() ?: "--",
                    fontSize = 48.sp,
                    fontWeight = FontWeight.Black,
                    color = NotelTextPrimary
                )

                Text(
                    text = "BPM",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Bold,
                    color = NotelPrimary,
                    letterSpacing = 2.sp
                )

                Spacer(modifier = Modifier.height(8.dp))

                val statusText = when (connectionState) {
                    is com.notel.notel.data.ConnectionState.Disconnected -> "DISCONNECTED"
                    is com.notel.notel.data.ConnectionState.Scanning -> "SCANNING FOR DEVICE..."
                    is com.notel.notel.data.ConnectionState.Connecting -> "CONNECTING..."
                    is com.notel.notel.data.ConnectionState.Connected -> "CONNECTED: ${connectionState.deviceName.uppercase()}"
                    is com.notel.notel.data.ConnectionState.Error -> "ERROR: ${connectionState.message.uppercase()}"
                }
                val statusColor = when (connectionState) {
                    is com.notel.notel.data.ConnectionState.Connected -> Color(0xFF4CAF50)
                    is com.notel.notel.data.ConnectionState.Scanning -> Color(0xFFFFC107)
                    is com.notel.notel.data.ConnectionState.Connecting -> Color(0xFF2196F3)
                    is com.notel.notel.data.ConnectionState.Error -> Color(0xFFF44336)
                    else -> NotelTextSecondary
                }

                Text(
                    text = statusText,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    color = statusColor,
                    letterSpacing = 1.sp,
                    textAlign = TextAlign.Center
                )
            }
        }
    }
}

@Composable
fun InteractiveHeartRateGraph(
    records: List<com.notel.notel.data.HeartRateRecord>,
    modifier: Modifier = Modifier,
    lineColor: Color = NotelPrimary
) {
    if (records.size < 2) {
        Box(
            modifier = modifier.background(NotelSurfaceHigh.copy(alpha = 0.5f), RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center
        ) {
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Awaiting data coordinates...", color = NotelTextSecondary, fontSize = 11.sp)
                Spacer(modifier = Modifier.height(4.dp))
                Text("(Graph averages every 10s. Display starts in ~20-30s)", color = NotelTextSecondary.copy(alpha = 0.6f), fontSize = 9.sp)
            }
        }
        return
    }

    val minBpm = records.minOf { it.bpm }
    val maxBpm = records.maxOf { it.bpm }

    val minLimit = (minBpm - 5).coerceAtLeast(0)
    val maxLimit = maxBpm + 5
    val range = maxLimit - minLimit

    var touchX by remember { mutableStateOf<Float?>(null) }
    var selectedRecord by remember { mutableStateOf<com.notel.notel.data.HeartRateRecord?>(null) }

    val textPaint = remember {
        android.graphics.Paint().apply {
            color = android.graphics.Color.GRAY
            textSize = 28f
            typeface = android.graphics.Typeface.MONOSPACE
            textAlign = android.graphics.Paint.Align.RIGHT
        }
    }

    val labelPaint = remember {
        android.graphics.Paint().apply {
            color = android.graphics.Color.WHITE
            textSize = 24f
            typeface = android.graphics.Typeface.DEFAULT_BOLD
            textAlign = android.graphics.Paint.Align.CENTER
        }
    }

    Box(
        modifier = modifier
            .background(NotelSurfaceHigh.copy(alpha = 0.3f), RoundedCornerShape(12.dp))
            .border(1.dp, NotelSurfaceHigh, RoundedCornerShape(12.dp))
    ) {
        androidx.compose.foundation.Canvas(
            modifier = Modifier
                .fillMaxSize()
                .padding(top = 16.dp, bottom = 24.dp, start = 16.dp, end = 52.dp)
                .pointerInput(records) {
                    detectDragGestures(
                        onDragStart = { offset ->
                            touchX = offset.x
                        },
                        onDrag = { change, _ ->
                            touchX = change.position.x
                        },
                        onDragEnd = {
                            touchX = null
                            selectedRecord = null
                        },
                        onDragCancel = {
                            touchX = null
                            selectedRecord = null
                        }
                    )
                }
        ) {
            val width = size.width
            val height = size.height

            val yLines = 3
            for (i in 0 until yLines) {
                val fraction = i.toFloat() / (yLines - 1)
                val y = height * fraction
                val value = maxLimit - (fraction * range).toInt()
                
                drawLine(
                    color = NotelSurfaceHigh,
                    start = Offset(0f, y),
                    end = Offset(width, y),
                    strokeWidth = 1.dp.toPx()
                )
                
                drawIntoCanvas { canvas ->
                    canvas.nativeCanvas.drawText(
                        "$value",
                        width + 42.dp.toPx(),
                        y + 4.dp.toPx(),
                        textPaint
                    )
                }
            }

            val path = androidx.compose.ui.graphics.Path()
            val fillPath = androidx.compose.ui.graphics.Path()

            records.forEachIndexed { index, record ->
                val x = index * (width / (records.size - 1))
                val y = height - (record.bpm - minLimit) * (height / range)

                if (index == 0) {
                    path.moveTo(x, y)
                    fillPath.moveTo(x, height)
                    fillPath.lineTo(x, y)
                } else {
                    path.lineTo(x, y)
                    fillPath.lineTo(x, y)
                }

                if (index == records.size - 1) {
                    fillPath.lineTo(x, height)
                    fillPath.close()
                }
            }

            drawPath(
                path = fillPath,
                brush = Brush.verticalGradient(
                    colors = listOf(lineColor.copy(alpha = 0.2f), Color.Transparent)
                )
            )

            drawPath(
                path = path,
                color = lineColor,
                style = androidx.compose.ui.graphics.drawscope.Stroke(width = 2.dp.toPx())
            )

            if (records.size >= 2) {
                val indicesToShow = listOf(0, records.size / 2, records.size - 1)
                indicesToShow.forEach { idx ->
                    val record = records[idx]
                    val x = idx * (width / (records.size - 1))
                    
                    val rawTime = record.timestamp
                    val cleanTime = if (rawTime.contains(" ")) {
                        val parts = rawTime.split(" ")
                        val time = parts.getOrNull(1) ?: ""
                        val amPm = parts.getOrNull(2) ?: ""
                        val shortTime = if (time.contains(":")) time.substringBeforeLast(":") else time
                        if (amPm.isNotEmpty()) "$shortTime $amPm" else shortTime
                    } else {
                        if (rawTime.contains(":")) {
                            rawTime.substringBeforeLast(":")
                        } else rawTime
                    }

                    drawIntoCanvas { canvas ->
                        canvas.nativeCanvas.drawText(
                            cleanTime,
                            x,
                            height + 18.dp.toPx(),
                            labelPaint
                        )
                    }
                }
            }

            touchX?.let { tx ->
                val coercedX = tx.coerceIn(0f, width)
                val index = (coercedX / width * (records.size - 1)).toInt().coerceIn(0, records.size - 1)
                val record = records[index]
                selectedRecord = record

                val x = index * (width / (records.size - 1))
                val y = height - (record.bpm - minLimit) * (height / range)

                drawLine(
                    color = Color.White.copy(alpha = 0.5f),
                    start = Offset(x, 0f),
                    end = Offset(x, height),
                    strokeWidth = 1.dp.toPx()
                )

                drawCircle(
                    color = lineColor,
                    radius = 4.dp.toPx(),
                    center = Offset(x, y)
                )
                drawCircle(
                    color = Color.White,
                    radius = 2.dp.toPx(),
                    center = Offset(x, y)
                )
            }
        }

        selectedRecord?.let { record ->
            Card(
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(8.dp)
                    .border(1.dp, lineColor.copy(alpha = 0.3f), RoundedCornerShape(8.dp)),
                colors = CardDefaults.cardColors(containerColor = NotelSurfaceHigh),
                shape = RoundedCornerShape(8.dp)
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    Text(
                        text = "${record.bpm} BPM",
                        fontSize = 11.sp,
                        fontWeight = FontWeight.ExtraBold,
                        color = lineColor
                    )
                    Box(modifier = Modifier.width(1.dp).height(10.dp).background(NotelTextSecondary))
                    val displayTime = if (record.timestamp.contains(" ")) {
                        val parts = record.timestamp.split(" ")
                        val time = parts.getOrNull(1) ?: ""
                        val amPm = parts.getOrNull(2) ?: ""
                        if (amPm.isNotEmpty()) "$time $amPm" else time
                    } else {
                        record.timestamp
                    }
                    Text(
                        text = displayTime,
                        fontSize = 10.sp,
                        color = NotelTextPrimary,
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace
                    )
                }
            }
        }
    }
}

@Composable
fun DeviceRow(device: com.notel.notel.data.BleDevice, onClick: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(NotelSurfaceHigh.copy(alpha = 0.5f))
            .clickable { onClick() }
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Column {
            Text(text = device.name, fontSize = 13.sp, fontWeight = FontWeight.Bold, color = NotelTextPrimary)
            Spacer(modifier = Modifier.height(2.dp))
            Text(text = device.address, fontSize = 10.sp, color = NotelTextSecondary, fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace)
        }

        Box(
            modifier = Modifier
                .clip(RoundedCornerShape(8.dp))
                .background(NotelPrimary.copy(alpha = 0.15f))
                .padding(horizontal = 8.dp, vertical = 4.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Default.PlayArrow,
                    contentDescription = "Record",
                    tint = NotelPrimary,
                    modifier = Modifier.size(12.dp)
                )
                Spacer(modifier = Modifier.width(4.dp))
                Text("RECORD", fontSize = 9.sp, fontWeight = FontWeight.Bold, color = NotelPrimary)
            }
        }
    }
}

@Composable
fun SavedSessionsPanel(
    savedFiles: List<java.io.File>,
    onViewGraph: (java.io.File) -> Unit,
    onShare: (java.io.File) -> Unit,
    onDelete: (java.io.File) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    GlassyCard(
        shape = RoundedCornerShape(16.dp),
        color = NotelSurface,
        modifier = modifier
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = "SAVED CSV SESSIONS",
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                color = NotelTextPrimary,
                letterSpacing = 1.sp
            )

            Spacer(modifier = Modifier.height(8.dp))

            if (savedFiles.isEmpty()) {
                Text(
                    text = "No saved logs found. Start a recording session to log data.",
                    color = NotelTextSecondary,
                    fontSize = 11.sp,
                    modifier = Modifier.padding(vertical = 8.dp)
                )
            } else {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    savedFiles.sortedByDescending { it.lastModified() }.forEach { file ->
                        SavedSessionRow(
                            file = file,
                            onViewGraph = { onViewGraph(file) },
                            onShare = { onShare(file) },
                            onDownload = { downloadCsvFile(context, file) },
                            onDelete = { onDelete(file) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun SavedSessionRow(
    file: java.io.File,
    onViewGraph: () -> Unit,
    onShare: () -> Unit,
    onDownload: () -> Unit,
    onDelete: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(NotelSurfaceHigh.copy(alpha = 0.5f))
            .border(1.dp, NotelSurfaceHigh, RoundedCornerShape(12.dp))
            .padding(10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        Column(modifier = Modifier.weight(1f)) {
            val displayName = try {
                val rawPart = file.name.replace("heart_rate_session_", "").replace(".csv", "")
                val parser = java.text.SimpleDateFormat("yyyyMMdd_HHmmss", java.util.Locale.getDefault())
                val formatter = java.text.SimpleDateFormat("MMM d, yyyy h:mm a", java.util.Locale.getDefault())
                val parsedDate = parser.parse(rawPart)
                if (parsedDate != null) {
                    "SESSION: " + formatter.format(parsedDate).uppercase()
                } else {
                    file.name.substringBeforeLast(".csv").uppercase()
                }
            } catch (e: Exception) {
                file.name.substringBeforeLast(".csv").uppercase()
            }
            Text(
                text = displayName,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = NotelTextPrimary
            )
            Spacer(modifier = Modifier.height(2.dp))
            val lengthText = try {
                var duration: String? = null
                file.bufferedReader().useLines { lines ->
                    for (line in lines) {
                        if (line.contains("Duration:")) {
                            duration = line.substringAfter("Duration:").trim()
                            break
                        }
                    }
                }
                duration ?: {
                    val linesCount = file.readLines().count { line ->
                        val parts = line.split(",")
                        if (parts.size >= 2) {
                            val bpmClean = parts[1].replace("[", "").replace("]", "").replace("BPM", "").trim()
                            bpmClean.toIntOrNull() != null && parts[0].contains(":") && !parts[0].contains("BPM")
                        } else false
                    }
                    val totalSeconds = linesCount * 10
                    val hours = totalSeconds / 3600
                    val minutes = (totalSeconds % 3600) / 60
                    val seconds = totalSeconds % 60
                    when {
                        hours > 0 -> "${hours}h ${minutes}m ${seconds}s"
                        minutes > 0 -> "${minutes}m ${seconds}s"
                        else -> "${seconds}s"
                    }
                }()
            } catch (e: Exception) {
                "Unknown length"
            }
            Text(
                text = "Duration: $lengthText",
                fontSize = 10.sp,
                color = NotelTextSecondary
            )
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .background(NotelPrimary.copy(alpha = 0.15f))
                    .clickable { onViewGraph() }
                    .padding(horizontal = 12.dp, vertical = 12.dp) // Increase padding to ensure >= 48dp touch target
            ) {
                Text("GRAPH", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = NotelPrimary)
            }

            IconButton(onClick = onShare, modifier = Modifier.size(48.dp)) {
                Icon(
                    imageVector = Icons.Default.Share,
                    contentDescription = "Share session CSV file",
                    tint = NotelPrimary,
                    modifier = Modifier.size(20.dp)
                )
            }

            IconButton(onClick = onDownload, modifier = Modifier.size(48.dp)) {
                Icon(
                    imageVector = Icons.Default.Download,
                    contentDescription = "Download session CSV file",
                    tint = NotelPrimary,
                    modifier = Modifier.size(20.dp)
                )
            }

            IconButton(onClick = onDelete, modifier = Modifier.size(48.dp)) {
                Icon(
                    imageVector = Icons.Default.Delete,
                    contentDescription = "Delete session CSV log",
                    tint = Color(0xFFFF4D4D),
                    modifier = Modifier.size(20.dp)
                )
            }
        }
    }
}

@Composable
fun SessionGraphDialog(file: java.io.File, onDismissRequest: () -> Unit) {
    val points = remember(file) {
        val list = mutableListOf<com.notel.notel.data.HeartRateRecord>()
        try {
            file.bufferedReader().useLines { lines ->
                lines.forEach { line ->
                    val parts = line.split(",")
                    if (parts.size >= 2) {
                        // CSV stores BPM as "[76 BPM]" — strip brackets and label before parsing
                        val rawBpm = parts[1].replace("[", "").replace("]", "").replace("BPM", "").trim()
                        rawBpm.toIntOrNull()?.let { bpm ->
                            val time = parts[0].trim()
                            if (time.contains(":") && !time.contains("BPM")) {
                                list.add(com.notel.notel.data.HeartRateRecord(time, bpm))
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
        list
    }

    Dialog(onDismissRequest = onDismissRequest) {
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .height(380.dp)
                .border(1.dp, NotelSurfaceHigh, RoundedCornerShape(24.dp)),
            colors = CardDefaults.cardColors(containerColor = NotelSurface)
        ) {
            Column(
                modifier = Modifier.fillMaxSize().padding(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.SpaceBetween
            ) {
                Text(
                    text = "SESSION TREND GRAPH",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = NotelTextPrimary,
                    letterSpacing = 1.sp
                )

                if (points.size < 2) {
                    Box(modifier = Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                        Text("Awaiting more logs to draw chart...", color = NotelTextSecondary, fontSize = 12.sp)
                    }
                } else {
                    val minBpm = points.minOf { it.bpm }
                    val maxBpm = points.maxOf { it.bpm }
                    val avgBpm = points.map { it.bpm }.average().toInt()

                    Column(modifier = Modifier.fillMaxWidth().weight(1f), verticalArrangement = Arrangement.Center) {
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp),
                            horizontalArrangement = Arrangement.SpaceEvenly
                        ) {
                            StatPill(label = "MIN HR", value = "$minBpm")
                            StatPill(label = "AVG HR", value = "$avgBpm")
                            StatPill(label = "MAX HR", value = "$maxBpm")
                        }

                        InteractiveHeartRateGraph(
                            records = points,
                            lineColor = NotelPrimary,
                            modifier = Modifier.fillMaxWidth().height(160.dp)
                        )
                    }
                }

                Button(
                    onClick = onDismissRequest,
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("CLOSE GRAPH", color = Color.White, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@Composable
fun StatPill(label: String, value: String) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(text = label, fontSize = 9.sp, color = NotelTextSecondary, fontWeight = FontWeight.Bold)
        Spacer(modifier = Modifier.height(2.dp))
        Text(text = value, fontSize = 13.sp, fontWeight = FontWeight.ExtraBold, color = NotelTextPrimary)
    }
}

@Composable
fun GattParamsDialog(
    rawBytes: String?,
    onDismissRequest: () -> Unit,
    onSwitchConnection: () -> Unit
) {
    Dialog(onDismissRequest = onDismissRequest) {
        Card(
            modifier = Modifier
                .fillMaxWidth()
                .border(1.dp, NotelSurfaceHigh, RoundedCornerShape(24.dp)),
            colors = CardDefaults.cardColors(containerColor = NotelSurface)
        ) {
            Column(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text(
                    text = "GATT BLUETOOTH PARAMS",
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Bold,
                    color = NotelTextPrimary,
                    letterSpacing = 1.sp
                )

                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    GattParamRow(label = "Heart Rate Service (GATT API)", value = "0000180d-0000-1000-8000-00805f9b34fb")
                    GattParamRow(label = "HR Measurement (Endpoint)", value = "00002a37-0000-1000-8000-00805f9b34fb")
                    GattParamRow(label = "Notification Descriptor", value = "00002902-0000-1000-8000-00805f9b34fb")
                    GattParamRow(label = "Raw Bytes Stream (Live)", value = rawBytes ?: "Disconnected")
                }

                Button(
                    onClick = {
                        onSwitchConnection()
                        onDismissRequest()
                    },
                    colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("Switch Connection", color = Color.White, fontWeight = FontWeight.Bold)
                }

                Button(
                    onClick = onDismissRequest,
                    colors = ButtonDefaults.buttonColors(containerColor = NotelSurfaceHigh),
                    shape = RoundedCornerShape(12.dp),
                    modifier = Modifier.fillMaxWidth()
                ) {
                    Text("CLOSE SETTINGS", color = NotelTextPrimary, fontWeight = FontWeight.Bold)
                }
            }
        }
    }
}

@Composable
fun GattParamRow(label: String, value: String) {
    Column {
        Text(text = label.uppercase(), fontSize = 8.sp, color = NotelTextSecondary, fontWeight = FontWeight.Bold)
        Spacer(modifier = Modifier.height(2.dp))
        Text(
            text = value,
            fontSize = 10.sp,
            color = if (value.startsWith("Receiving") || value.startsWith("Awaiting") || value.startsWith("...")) NotelTextSecondary else NotelTextPrimary,
            fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace,
            modifier = Modifier.fillMaxWidth()
        )
    }
}

private fun shareCsvFile(context: android.content.Context, file: java.io.File) {
    try {
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
        context.startActivity(android.content.Intent.createChooser(intent, "Share Heart Rate CSV"))
    } catch (e: Exception) {
        android.widget.Toast.makeText(context, "Failed to share file: ${e.localizedMessage}", android.widget.Toast.LENGTH_SHORT).show()
    }
}

private fun downloadCsvFile(context: android.content.Context, file: java.io.File) {
    try {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.Q) {
            val contentResolver = context.contentResolver
            val contentValues = android.content.ContentValues().apply {
                put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, file.name)
                put(android.provider.MediaStore.MediaColumns.MIME_TYPE, "text/csv")
                put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, android.os.Environment.DIRECTORY_DOWNLOADS)
            }
            val uri = contentResolver.insert(android.provider.MediaStore.Downloads.EXTERNAL_CONTENT_URI, contentValues)
            if (uri != null) {
                contentResolver.openOutputStream(uri).use { outputStream ->
                    file.inputStream().use { inputStream ->
                        inputStream.copyTo(outputStream!!)
                    }
                }
                android.widget.Toast.makeText(context, "Saved to Downloads folder", android.widget.Toast.LENGTH_SHORT).show()
            } else {
                android.widget.Toast.makeText(context, "Failed to create file in Downloads", android.widget.Toast.LENGTH_SHORT).show()
            }
        } else {
            val downloadsDir = android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS)
            if (!downloadsDir.exists()) {
                downloadsDir.mkdirs()
            }
            val destFile = java.io.File(downloadsDir, file.name)
            file.copyTo(destFile, overwrite = true)
            android.widget.Toast.makeText(context, "Saved to Downloads: ${destFile.absolutePath}", android.widget.Toast.LENGTH_LONG).show()
        }
    } catch (e: Exception) {
        android.widget.Toast.makeText(context, "Download failed: ${e.localizedMessage}", android.widget.Toast.LENGTH_SHORT).show()
    }
}

private fun downsampleTelemetryPoints(points: List<com.notel.notel.data.TelemetryPoint>): List<com.notel.notel.data.TelemetryPoint> {
    if (points.size <= 200) return points
    val sortedPoints = points.sortedBy { it.timestamp }
    val firstTime = sortedPoints.first().timestamp
    val lastTime = sortedPoints.last().timestamp
    val totalDurationMs = lastTime - firstTime
    val bucketMs = when {
        totalDurationMs <= 21_600_000L -> 60_000L      // <= 6 hours: 1 min
        totalDurationMs <= 86_400_000L -> 300_000L     // <= 24 hours: 5 min
        totalDurationMs <= 259_200_000L -> 900_000L    // <= 3 days: 15 min
        else -> 3_600_000L                             // > 3 days: 1 hour
    }
    return sortedPoints.groupBy { (it.timestamp - firstTime) / bucketMs }
        .map { (_, group) ->
            val avgBpm = group.map { it.bpm }.average().toInt()
            val avgTimestamp = group.map { it.timestamp }.average().toLong()
            com.notel.notel.data.TelemetryPoint(timestamp = avgTimestamp, bpm = avgBpm)
        }
        .sortedBy { it.timestamp }
}

