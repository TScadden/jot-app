package com.notel.notel

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import kotlinx.coroutines.launch
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.Density
import androidx.compose.ui.geometry.Size
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Assignment
import androidx.compose.foundation.BorderStroke
import androidx.compose.material3.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.navigation.NavType
import androidx.navigation.compose.*
import androidx.navigation.navArgument
import androidx.navigation.navDeepLink
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.lifecycleScope
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalContext
import com.notel.notel.ui.screen.*
import com.notel.notel.ui.screen.CoachScreen
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.BodyLoadViewModel
import com.notel.notel.ui.viewmodel.FitbitViewModel
import dagger.hilt.android.AndroidEntryPoint
import androidx.glance.appwidget.updateAll

// Custom Bowtie shape for the main button
val BowtieShape = object : Shape {
    override fun createOutline(size: Size, layoutDirection: androidx.compose.ui.unit.LayoutDirection, density: Density): Outline {
        val path = Path().apply {
            moveTo(size.width * 0.25f, 0f)
            lineTo(size.width * 0.75f, 0f)
            lineTo(size.width, size.height * 0.25f)
            lineTo(size.width, size.height * 0.75f)
            lineTo(size.width * 0.75f, size.height)
            lineTo(size.width * 0.25f, size.height)
            lineTo(0f, size.height * 0.75f)
            lineTo(0f, size.height * 0.25f)
            close()
        }
        return Outline.Generic(path)
    }
}

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @javax.inject.Inject
    lateinit var habitRepository: com.notel.notel.data.repository.HabitRepository

    val selectWidgetAppWidgetIdState = mutableStateOf(-1)

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        
        android.util.Log.d("MainActivityWidget", "onCreate: intent=$intent, extras=${intent?.extras?.keySet()?.associateWith { intent.extras?.get(it) }}")
        val isSelectAction = intent?.action?.startsWith("com.notel.notel.ACTION_SELECT_HABIT_") == true
        val widgetId = if (isSelectAction) {
            intent?.action?.substringAfterLast("_")?.toIntOrNull() ?: -1
        } else {
            intent?.getIntExtra("EXTRA_APP_WIDGET_ID", -1) ?: -1
        }
        if ((intent?.getBooleanExtra("EXTRA_SELECT_WIDGET_HABIT", false) == true || isSelectAction) && widgetId != -1) {
            selectWidgetAppWidgetIdState.value = widgetId
            intent?.removeExtra("EXTRA_SELECT_WIDGET_HABIT")
            intent?.removeExtra("EXTRA_APP_WIDGET_ID")
        }
        setContent {
            val context = LocalContext.current
            val activity = context as? ComponentActivity
            // Provide a global instance of FitbitViewModel at the activity level
            // so it can handle the auth redirect regardless of current navigation destination.
            val fitbitViewModel: FitbitViewModel = hiltViewModel()
            val bodyLoadViewModel: BodyLoadViewModel = hiltViewModel()
            val quickLogViewModel: com.notel.notel.ui.viewmodel.QuickLogViewModel = hiltViewModel()
            val settingsViewModel: com.notel.notel.ui.viewmodel.SettingsViewModel = hiltViewModel()
            val notelPreferences = remember { com.notel.notel.data.preferences.NotelPreferences(context) }
            var selectWidgetAppWidgetId by selectWidgetAppWidgetIdState
            android.util.Log.d("MainActivityWidget", "setContent: selectWidgetAppWidgetId=$selectWidgetAppWidgetId")
            
            LaunchedEffect(Unit) {
                notelPreferences.updateStreak()
                com.notel.notel.worker.BodyLoadWorker.schedule(context)
                com.notel.notel.data.BleManager.getInstance(context).scanAndAutoStart(context, notelPreferences)
                com.notel.notel.util.NotificationHelper(context)

                // Active background polling loop (checks subscriptions and web graph reports every 7s)
                while (true) {
                    kotlinx.coroutines.delay(7000L)
                    try {
                        settingsViewModel.billingManager.checkSubscriptionStatus()
                        settingsViewModel.syncManager.pullAllData()
                    } catch (e: Exception) {
                        // Ignore periodic polling errors
                    }
                }
            }
            
            val lifecycleOwner = LocalLifecycleOwner.current
            val coroutineScope = rememberCoroutineScope()
            DisposableEffect(lifecycleOwner) {
                val observer = LifecycleEventObserver { _, event ->
                    if (event == Lifecycle.Event.ON_RESUME) {
                        coroutineScope.launch {
                            notelPreferences.updateStreak()
                            settingsViewModel.billingManager.checkSubscriptionStatus()
                        }
                    }
                }
                lifecycleOwner.lifecycle.addObserver(observer)
                onDispose {
                    lifecycleOwner.lifecycle.removeObserver(observer)
                }
            }

            DisposableEffect(activity) {
                val listener = androidx.core.util.Consumer<android.content.Intent> { intent ->
                    if (intent.data?.scheme == "com.notel.notel.fitbit" && intent.data?.host == "callback") {
                        val code = intent.data?.getQueryParameter("code")
                        val state = intent.data?.getQueryParameter("state") ?: ""
                        if (code != null) {
                            fitbitViewModel.exchangeCodeForToken(code, state)
                            intent.data = null
                        }
                    }
                }
                activity?.addOnNewIntentListener(listener)
                
                // Check initial intent in case the app was launched directly via link
                val initialData = activity?.intent?.data
                if (initialData?.scheme == "com.notel.notel.fitbit" && initialData.host == "callback") {
                    val code = initialData.getQueryParameter("code")
                    val state = initialData.getQueryParameter("state") ?: ""
                    if (code != null) {
                        fitbitViewModel.exchangeCodeForToken(code, state)
                        activity?.intent?.data = null
                    }
                }
                
                onDispose {
                    activity?.removeOnNewIntentListener(listener)
                }
            }

            NotelTheme {
                val navController = rememberNavController()
                val navBackStackEntry by navController.currentBackStackEntryAsState()
                val currentRoute = navBackStackEntry?.destination?.route
                val showNavLabels by notelPreferences.showNavLabels.collectAsState(initial = true)

                // Notification Permission Handling (mandatory for Android 13+)
                val permissionLauncher = androidx.activity.compose.rememberLauncherForActivityResult(
                    contract = androidx.activity.result.contract.ActivityResultContracts.RequestPermission(),
                    onResult = { }
                )
                LaunchedEffect(Unit) {
                    if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU) {
                        val hasPermission = androidx.core.content.ContextCompat.checkSelfPermission(
                            context,
                            android.Manifest.permission.POST_NOTIFICATIONS
                        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
                        if (!hasPermission) {
                            permissionLauncher.launch(android.Manifest.permission.POST_NOTIFICATIONS)
                        }
                    }
                }

                // Global reordering lock state for Information Center
                var isReorderingTiles by remember { mutableStateOf(false) }

                // Global banner states
                var aiInsight by remember { mutableStateOf<com.notel.notel.data.local.entity.AiInsight?>(null) }
                val reportViewModel: com.notel.notel.ui.viewmodel.SettingsViewModel = hiltViewModel()

                val isLoggedIn by notelPreferences.loggedIn.collectAsState(initial = false)
                LaunchedEffect(isLoggedIn) {
                    if (!isLoggedIn) {
                        aiInsight = null
                    }
                }

                // Banner State for one-time events
                data class TopBannerState(
                    val message: String,
                    val entryId: Long? = null,
                    val isError: Boolean = false,
                    val canUndo: Boolean = false
                )
                var activeBanner by remember { mutableStateOf<TopBannerState?>(null) }

                LaunchedEffect(Unit) {
                    quickLogViewModel.eventFlow.collect { event ->
                        when (event) {
                            is com.notel.notel.ui.viewmodel.QuickLogEvent.EntryLogged -> {
                                activeBanner = TopBannerState(message = event.message, entryId = event.entryId, canUndo = true)
                            }
                            is com.notel.notel.ui.viewmodel.QuickLogEvent.EntryRepeated -> {
                                activeBanner = TopBannerState(message = event.message, entryId = event.entryId, canUndo = true)
                            }
                            is com.notel.notel.ui.viewmodel.QuickLogEvent.EntryUndone -> {
                                activeBanner = TopBannerState(message = event.message, canUndo = false)
                            }
                            is com.notel.notel.ui.viewmodel.QuickLogEvent.SaveFailed -> {
                                activeBanner = TopBannerState(message = event.message, isError = true, canUndo = false)
                            }
                        }
                    }
                }

                LaunchedEffect(activeBanner) {
                    val current = activeBanner
                    if (current != null) {
                        kotlinx.coroutines.delay(3500)
                        if (activeBanner == current) {
                            activeBanner = null
                        }
                    }
                }

                LaunchedEffect(Unit) {
                    reportViewModel.aiInsightReadyEvent.collect { insight ->
                        if (insight.type != "BodyLoad") {
                            val route = navController.currentBackStackEntry?.destination?.route
                            if (route != "settings" && route?.startsWith("settings") != true) {
                                aiInsight = insight
                            }
                        }
                    }
                }

                val hasConsentedState by notelPreferences.hasConsented.collectAsState(initial = false)
                val introConsultationSeenState by notelPreferences.introConsultationSeen.collectAsState(initial = false)

                Box(modifier = Modifier.fillMaxSize()) {
                    // Main Content
                    NavHost(
                        navController = navController,
                        startDestination = "splash",
                        modifier = Modifier.fillMaxSize(),
                        enterTransition = { EnterTransition.None },
                        exitTransition = { ExitTransition.None },
                        popEnterTransition = { EnterTransition.None },
                        popExitTransition = { ExitTransition.None }
                    ) {
                        composable("splash") {
                            com.notel.notel.ui.screen.SplashScreen(
                                onNavigateNext = { isLoggedIn, isOnboarded ->
                                    if (isLoggedIn) {
                                        if (!hasConsentedState) {
                                            navController.navigate("consent") {
                                                popUpTo("splash") { inclusive = true }
                                            }
                                        } else if (!introConsultationSeenState) {
                                            navController.navigate("consultation_intro") {
                                                popUpTo("splash") { inclusive = true }
                                            }
                                        } else if (isOnboarded) {
                                            navController.navigate("body_load") {
                                                popUpTo("splash") { inclusive = true }
                                            }
                                        } else {
                                            navController.navigate("profile_setup") {
                                                popUpTo("splash") { inclusive = true }
                                            }
                                        }
                                    } else {
                                        navController.navigate("welcome_onboarding") {
                                            popUpTo("splash") { inclusive = true }
                                        }
                                    }
                                }
                            )
                        }
                        composable("welcome_onboarding") {
                            com.notel.notel.ui.screen.WelcomeOnboardingScreen(
                                onLogin = {
                                    navController.navigate("login?mode=login")
                                },
                                onSignUp = {
                                    navController.navigate("login?mode=register")
                                }
                            )
                        }
                        composable(
                            "login?mode={mode}",
                            arguments = listOf(androidx.navigation.navArgument("mode") { defaultValue = "register" })
                        ) { backStackEntry ->
                            val initialMode = backStackEntry.arguments?.getString("mode") ?: "register"
                            val loginViewModel: com.notel.notel.ui.screen.LoginViewModel = hiltViewModel()
                            LoginScreen(
                                initialMode = initialMode,
                                onBack = { navController.popBackStack() },
                                onLoginSuccess = { isComplete ->
                                    if (isComplete) {
                                        coroutineScope.launch {
                                            notelPreferences.setHasConsented(true)
                                            notelPreferences.setIntroConsultationSeen(true)
                                            notelPreferences.setOnboardingComplete(true)
                                            navController.navigate("body_load") { popUpTo("welcome_onboarding") { inclusive = true } }
                                        }
                                    } else {
                                        navController.navigate("consent") { popUpTo("welcome_onboarding") { inclusive = true } }
                                    }
                                }
                            )
                        }
                        composable("consent") {
                            com.notel.notel.ui.screen.ConsentScreen(
                                onBack = { navController.popBackStack() },
                                onConsent = {
                                    coroutineScope.launch {
                                        notelPreferences.setHasConsented(true)
                                        navController.navigate("consultation_intro") { popUpTo("consent") { inclusive = true } }
                                    }
                                },
                                onDecline = {
                                    coroutineScope.launch {
                                        notelPreferences.setLoggedIn(false)
                                        notelPreferences.setHasConsented(false)
                                        notelPreferences.setIntroConsultationSeen(false)
                                        navController.navigate("welcome_onboarding") { popUpTo(0) { inclusive = true } }
                                    }
                                }
                            )
                        }
                        composable("consultation_intro") {
                            com.notel.notel.ui.screen.ConsultationIntroScreen(
                                onBack = { navController.popBackStack() },
                                onContinue = {
                                    coroutineScope.launch {
                                        notelPreferences.setIntroConsultationSeen(true)
                                        navController.navigate("profile_setup")
                                    }
                                }
                            )
                        }
                        composable("profile_setup") {
                            ProfileSetupScreen(
                                onBack = { navController.popBackStack() },
                                onNavigateNext = { navController.navigate("conditions") }
                            )
                        }
                        composable("conditions") {
                            com.notel.notel.ui.screen.ConditionsScreen(
                                onBack = { navController.popBackStack() },
                                onNavigateNext = { navController.navigate("notification_onboarding") },
                                onSkip = { navController.navigate("notification_onboarding") }
                            )
                        }
                        composable("notification_onboarding") {
                            com.notel.notel.ui.screen.NotificationOnboardingScreen(
                                onBack = { navController.popBackStack() },
                                onNavigateNext = { navController.navigate("connections") },
                                onSkip = { navController.navigate("connections") }
                            )
                        }
                        composable("connections") {
                            ConnectionsScreen(
                                onBack = { navController.popBackStack() },
                                onNavigateNext = { navController.navigate("membership_onboarding") }
                            )
                        }
                        composable("membership_onboarding") {
                            com.notel.notel.ui.screen.MembershipOnboardingScreen(
                                onBack = { navController.popBackStack() },
                                onSubscribe = { navController.navigate("settings?menu=MEMBERSHIP") },
                                onSkip = { navController.navigate("setup_loading") }
                            )
                        }
                        composable("setup_loading") {
                            SetupLoadingScreen(onNavigateMain = { 
                                navController.navigate("body_load") {
                                    popUpTo("setup_loading") { inclusive = true }
                                }
                            })
                        }
                        composable("body_load") {
                            BodyLoadScreen(
                                viewModel = bodyLoadViewModel,
                                quickLogViewModel = quickLogViewModel,
                                onBack = { /* Root */ },
                                onNavigateToConnections = { navController.navigate("data_connections") },
                                onNavigateToHeart = { navController.navigate("fitbit") },
                                onNavigateToMembership = { navController.navigate("settings?menu=MEMBERSHIP") },
                                onNavigateToHabits = { navController.navigate("habits") },
                                onNavigateToReminders = { navController.navigate("reminders") },
                                onNavigateToLists = { navController.navigate("lists") },
                                onNavigateToNotes = { navController.navigate("notes") },
                                onNavigateToProjectFocus = { navController.navigate("project_focus") }
                            )
                        }
                        composable("habits") {
                            HabitsScreen(onBack = { navController.popBackStack() })
                        }
                        composable("project_focus") {
                            com.notel.notel.ui.screen.ProjectFocusScreen(onBack = { navController.popBackStack() })
                        }
                        composable("reminders") {
                            RemindersScreen(onBack = { navController.popBackStack() })
                        }
                        composable("lists") {
                            com.notel.notel.ui.screen.ListsScreen(onBack = { navController.popBackStack() })
                        }
                        composable("notes") {
                            com.notel.notel.ui.screen.NotesScreen(onBack = { navController.popBackStack() })
                        }
                        composable("data_connections") {
                            DataConnectionsScreen(onBack = { navController.popBackStack() })
                        }
                        composable("history") {
                            HistoryScreen(
                                onBack = { navController.popBackStack() },
                                onEntryClick = { id -> navController.navigate("detail/$id") }
                            )
                        }
                        composable("info") {
                            val settingsViewModel: com.notel.notel.ui.viewmodel.SettingsViewModel = hiltViewModel()
                            val isUnlimited by settingsViewModel.isUnlimited.collectAsState(initial = false)
                            InfoScreen(
                                onBack = { navController.popBackStack() },
                                onSleepClick = { navController.navigate("sleep") },
                                onBodyInfoClick = { navController.navigate("body_info") },
                                onMedicationsClick = { navController.navigate("medications") },
                                onKeyMetricsClick = { navController.navigate("key_metrics") },
                                onCoachClick = { 
                                    if (isUnlimited) navController.navigate("coach_history")
                                    else navController.navigate("settings?menu=MEMBERSHIP")
                                },
                                onTipsAndTricksClick = { 
                                    if (isUnlimited) navController.navigate("tips_and_tricks")
                                    else navController.navigate("settings?menu=MEMBERSHIP")
                                },
                                onFoodClick = { navController.navigate("food") },
                                onCommunityClick = { navController.navigate("community") },
                                onHabitsClick = { navController.navigate("habits") },
                                onRemindersClick = { navController.navigate("reminders") },
                                onListsClick = { navController.navigate("lists") },
                                onNotesClick = { navController.navigate("notes") },
                                onProjectFocusClick = { navController.navigate("project_focus") },
                                onNavigateToMembership = { navController.navigate("settings?menu=MEMBERSHIP") },
                                isUnlimited = isUnlimited,
                                onReorderStateChange = { isReorderingTiles = it }
                            )
                        }
                        composable("body_info") {
                            BodyInfoScreen(onBack = { navController.popBackStack() })
                        }
                        composable("medications") {
                            MedicationsScreen(onBack = { navController.popBackStack() })
                        }
                        composable("community") {
                            com.notel.notel.ui.screen.CommunityScreen(onBack = { navController.popBackStack() })
                        }
                        composable("tips_and_tricks") {
                            TipsAndTricksScreen(onBack = { navController.popBackStack() })
                        }
                        composable("food") {
                            FoodScreen(onBack = { navController.popBackStack() })
                        }
                        composable("coach_history") {
                            com.notel.notel.ui.screen.CoachHistoryScreen(
                                onBack = { navController.popBackStack() },
                                onNewChatClick = { navController.navigate("coach") },
                                onSessionClick = { sessionId -> navController.navigate("coach?sessionId=$sessionId") }
                            )
                        }
                        composable(
                            "coach?sessionId={sessionId}",
                            arguments = listOf(androidx.navigation.navArgument("sessionId") { nullable = true })
                        ) {
                            CoachScreen(onBack = { navController.popBackStack() })
                        }
                        composable("quick_log") {
                            QuickLogScreen(
                                viewModel = quickLogViewModel,
                                onNavigateToHistory = { navController.navigate("history") },
                                onNavigateToSettings = { navController.navigate("settings") },
                                onNavigateToMembership = { navController.navigate("settings?menu=MEMBERSHIP") },
                                onNavigateToTrends = { /* trends Lego piece coming soon */ },
                                onNavigateToFitbit = { /* fitbit Lego piece coming soon */ },
                                onNavigateToSleep = { /* sleep Lego piece coming soon */ },
                                onNavigateToBodyLoad = { navController.navigate("body_load") }
                            )
                        }
                        composable(
                            route = "detail/{entryId}",
                            arguments = listOf(navArgument("entryId") { type = NavType.LongType })
                        ) { backStack ->
                            val id = backStack.arguments?.getLong("entryId") ?: return@composable
                            EntryDetailScreen(
                                entryId = id,
                                onBack = { navController.popBackStack() }
                            )
                        }
                        composable(
                            route = "settings?menu={menu}",
                            arguments = listOf(navArgument("menu") { type = NavType.StringType; nullable = true })
                        ) { backStack ->
                            val menuStr = backStack.arguments?.getString("menu")
                            val initialMenu = if (menuStr != null) {
                                try { com.notel.notel.ui.screen.SettingsMenu.valueOf(menuStr) } catch(e: Exception) { com.notel.notel.ui.screen.SettingsMenu.MAIN }
                            } else com.notel.notel.ui.screen.SettingsMenu.MAIN
                            
                            val settingsViewModel: com.notel.notel.ui.viewmodel.SettingsViewModel = hiltViewModel()
                            SettingsScreen(
                                initialMenu = initialMenu,
                                viewModel = settingsViewModel,
                                onBack = { navController.popBackStack() },
                                onRestartOnboarding = {
                                    navController.navigate("profile_setup") {
                                        popUpTo("body_load") { inclusive = true }
                                    }
                                },
                                onLogout = {
                                    val intent = this@MainActivity.intent
                                    this@MainActivity.finish()
                                    this@MainActivity.startActivity(intent)
                                },
                                onNavigateToFile = { name, path, mime, docId ->
                                    val encName = java.net.URLEncoder.encode(name, "UTF-8")
                                    val encPath = java.net.URLEncoder.encode(path, "UTF-8")
                                    val encMime = java.net.URLEncoder.encode(mime, "UTF-8")
                                    val encDocId = java.net.URLEncoder.encode(docId, "UTF-8")
                                    navController.navigate("file_viewer?name=$encName&path=$encPath&mime=$encMime&docId=$encDocId")
                                }
                            )
                        }
                        composable("fitbit") {
                            FitbitScreen(viewModel = fitbitViewModel, onBack = { navController.popBackStack() })
                        }
                        composable("sleep") {
                            SleepScreen(onBack = { navController.popBackStack() })
                        }
                        composable("key_metrics") {
                            KeyMetricsScreen(
                                onBack = { navController.popBackStack() },
                                viewModel = fitbitViewModel
                            )
                        }
                        composable(
                            route = "file_viewer?name={name}&path={path}&mime={mime}&docId={docId}",
                            arguments = listOf(
                                navArgument("name") { type = NavType.StringType },
                                navArgument("path") { type = NavType.StringType },
                                navArgument("mime") { type = NavType.StringType },
                                navArgument("docId") { type = NavType.StringType; defaultValue = "" }
                            )
                        ) { backStack ->
                            val nameRaw = backStack.arguments?.getString("name") ?: ""
                            val pathRaw = backStack.arguments?.getString("path") ?: ""
                            val mimeRaw = backStack.arguments?.getString("mime") ?: ""
                            val docIdRaw = backStack.arguments?.getString("docId") ?: ""
                            
                            val name = java.net.URLDecoder.decode(nameRaw, "UTF-8")
                            val path = java.net.URLDecoder.decode(pathRaw, "UTF-8")
                            val mime = java.net.URLDecoder.decode(mimeRaw, "UTF-8")
                            val docId = java.net.URLDecoder.decode(docIdRaw, "UTF-8")
                            val settingsVm: com.notel.notel.ui.viewmodel.SettingsViewModel = hiltViewModel()
                            val docs by settingsVm.knowledgeDocuments.collectAsState()
                            val extractedText = remember(docId, docs) {
                                docs.find { it.id == docId }?.extractedText
                            }
                            FileViewerScreen(
                                fileName = name,
                                filePath = path,
                                mimeType = mime,
                                extractedText = extractedText,
                                onSaveEditedText = { newText ->
                                    settingsVm.updateDocumentExtractedText(docId, newText)
                                },
                                onBack = { navController.popBackStack() }
                            )
                        }
                    }

                    // Floating Glass Nav Banner
                    val hideNavRoutes = listOf("splash", "welcome_onboarding", "consent", "login", "consultation_intro", "profile_setup", "conditions", "notification_onboarding", "connections", "membership_onboarding", "setup_loading", "data_connections")
                    val isFileViewer = currentRoute?.startsWith("file_viewer") == true
                    val isLoginRoute = currentRoute?.startsWith("login") == true
                    val baseRoute = currentRoute?.substringBefore("?")
                    if (baseRoute !in hideNavRoutes && !isFileViewer && !isLoginRoute && currentRoute != null) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .align(Alignment.BottomCenter)
                                .padding(start = 24.dp, end = 24.dp, bottom = 12.dp)
                                .navigationBarsPadding()
                        ) {
                            Box(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .height(48.dp)
                                    .liquidGlass(
                                        shape = RoundedCornerShape(32.dp),
                                        color = NotelSurface,
                                        alpha = 0.9f,
                                        showBorder = true
                                    )
                            ) {
                                Row(
                                    modifier = Modifier.fillMaxSize(),
                                    horizontalArrangement = Arrangement.SpaceAround,
                                    verticalAlignment = Alignment.CenterVertically
                                ) {
                                    NavIcon(
                                        icon = Icons.Default.Home,
                                        label = "Home",
                                        isSelected = currentRoute == "body_load",
                                        showLabel = showNavLabels,
                                        onClick = { 
                                            if (!isReorderingTiles && currentRoute != "body_load") {
                                                navController.navigate("body_load") {
                                                    popUpTo(navController.graph.startDestinationId) { saveState = true }
                                                    launchSingleTop = true
                                                    restoreState = true
                                                }
                                            }
                                        }
                                    )
                                    NavIcon(
                                        icon = Icons.Default.Assignment,
                                        label = "Tools",
                                        isSelected = currentRoute == "info",
                                        showLabel = showNavLabels,
                                        onClick = { if (!isReorderingTiles) navController.navigate("info") }
                                    )
                                    // Center Pencil Button — no label, always purple, slightly larger
                                    Column(
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        verticalArrangement = Arrangement.Center,
                                        modifier = Modifier
                                            .clickable {
                                                if (!isReorderingTiles && currentRoute != "quick_log") {
                                                    navController.navigate("quick_log") {
                                                        popUpTo(navController.graph.startDestinationId) { saveState = true }
                                                        launchSingleTop = true
                                                        restoreState = true
                                                    }
                                                }
                                            }
                                            .padding(horizontal = 12.dp, vertical = 4.dp)
                                    ) {
                                        Icon(
                                            imageVector = Icons.Default.Edit,
                                            contentDescription = "New Note",
                                            tint = NotelPrimary,
                                            modifier = Modifier.size(24.dp)
                                        )
                                        if (showNavLabels) {
                                            Text(
                                                text = "",
                                                style = MaterialTheme.typography.labelSmall,
                                                fontSize = 9.sp
                                            )
                                        }
                                    }
                                    NavIcon(
                                        icon = Icons.Default.Favorite,
                                        label = "Heart",
                                        isSelected = currentRoute == "fitbit",
                                        showLabel = showNavLabels,
                                        onClick = { if (!isReorderingTiles) navController.navigate("fitbit") }
                                    )
                                    NavIcon(
                                        icon = Icons.Default.Settings,
                                        label = "Settings",
                                        isSelected = currentRoute == "settings",
                                        showLabel = showNavLabels,
                                        onClick = { if (!isReorderingTiles) navController.navigate("settings") }
                                    )
                                }
                            }
                        }
                    }



                    // Global Action Notification Banner (Slide-in top banner)
                    androidx.compose.animation.AnimatedVisibility(
                        visible = activeBanner != null,
                        enter = androidx.compose.animation.slideInVertically(initialOffsetY = { -it }) + androidx.compose.animation.fadeIn(),
                        exit = androidx.compose.animation.slideOutVertically(targetOffsetY = { -it }) + androidx.compose.animation.fadeOut(),
                        modifier = Modifier.align(Alignment.TopCenter).padding(horizontal = 16.dp, vertical = 8.dp).statusBarsPadding()
                    ) {
                        val banner = activeBanner
                        if (banner != null) {
                            Surface(
                                shape = RoundedCornerShape(16.dp),
                                color = NotelSurface,
                                tonalElevation = 8.dp,
                                shadowElevation = 8.dp,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .liquidGlass(shape = RoundedCornerShape(16.dp), color = NotelSurface, alpha = 0.95f)
                            ) {
                                Row(
                                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 12.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween
                                ) {
                                    Text(
                                        text = banner.message,
                                        style = MaterialTheme.typography.bodyMedium,
                                        fontWeight = FontWeight.SemiBold,
                                        color = if (banner.isError) Color(0xFFFF6B6B) else NotelTextPrimary,
                                        modifier = Modifier.weight(1f)
                                    )
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                                    ) {
                                        if (banner.canUndo && banner.entryId != null) {
                                            TextButton(
                                                onClick = {
                                                    quickLogViewModel.undoLastLog(banner.entryId)
                                                    activeBanner = null
                                                },
                                                contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp)
                                            ) {
                                                Text(
                                                    "Undo",
                                                    fontWeight = FontWeight.Bold,
                                                    color = NotelPrimary,
                                                    fontSize = 13.sp
                                                )
                                            }
                                        }
                                        IconButton(
                                            onClick = { activeBanner = null },
                                            modifier = Modifier.size(24.dp)
                                        ) {
                                            Icon(
                                                Icons.Default.Close,
                                                contentDescription = "Dismiss notification banner",
                                                tint = NotelTextSecondary
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // Global Top Banner Overlay (AI Insight Notification)
                    androidx.compose.animation.AnimatedVisibility(
                        visible = aiInsight != null && activeBanner == null,
                        enter = androidx.compose.animation.slideInVertically(initialOffsetY = { -it }) + androidx.compose.animation.fadeIn(),
                        exit = androidx.compose.animation.slideOutVertically(targetOffsetY = { -it }) + androidx.compose.animation.fadeOut(),
                        modifier = Modifier.align(Alignment.TopCenter).padding(16.dp).statusBarsPadding()
                    ) {
                        val insight = aiInsight
                        if (insight != null) {
                            Surface(
                                shape = RoundedCornerShape(16.dp),
                                color = NotelSurface,
                                tonalElevation = 12.dp,
                                shadowElevation = 12.dp,
                                modifier = Modifier.fillMaxWidth().clickable {
                                    navController.navigate("settings?menu=AI_AND_KNOWLEDGE")
                                    aiInsight = null
                                }.liquidGlass(shape = RoundedCornerShape(16.dp), color = NotelSurface, alpha = 0.9f)
                            ) {
                                Row(
                                    modifier = Modifier.padding(16.dp),
                                    verticalAlignment = Alignment.CenterVertically,
                                    horizontalArrangement = Arrangement.SpaceBetween
                                ) {
                                    Column(modifier = Modifier.weight(1f)) {
                                        Text(
                                            "AI Audit Complete! ✨",
                                            style = MaterialTheme.typography.titleMedium,
                                            color = NotelPrimary,
                                            fontWeight = FontWeight.ExtraBold
                                        )
                                        Text(
                                            "${insight.type} ready. Tap to view history.",
                                            style = MaterialTheme.typography.bodyMedium,
                                            color = NotelTextPrimary.copy(alpha = 0.9f)
                                        )
                                    }
                                    IconButton(onClick = { aiInsight = null }) {
                                        Icon(Icons.Default.Close, contentDescription = "Close", tint = NotelTextSecondary)
                                    }
                                }
                            }
                        }
                    }

                    if (selectWidgetAppWidgetId != -1) {
                            LaunchedEffect(Unit) {
                                habitRepository.fetchHabits()
                            }
                            val habits by habitRepository.habits.collectAsState()
                            android.util.Log.d("MainActivityWidget", "setContent: habits collected, size = ${habits.size}")

                            androidx.compose.material3.AlertDialog(
                                onDismissRequest = { selectWidgetAppWidgetId = -1 },
                                title = { Text("Select Habit for Widget", color = NotelTextPrimary) },
                                text = {
                                    Column {
                                        if (habits.isEmpty()) {
                                            Text("No habits found. Please create a habit first in the app.", color = NotelTextSecondary)
                                        } else {
                                            habits.forEach { habit ->
                                                Row(
                                                    modifier = Modifier
                                                        .fillMaxWidth()
                                                        .clickable {
                                                            val sPrefs = context.getSharedPreferences("single_habit_widget_prefs", android.content.Context.MODE_PRIVATE)
                                                            android.util.Log.d("MainActivityWidget", "Saving habit_id_$selectWidgetAppWidgetId = ${habit.id}")
                                                            sPrefs.edit().putString("habit_id_$selectWidgetAppWidgetId", habit.id).apply()
                                                            lifecycleScope.launch {
                                                                try {
                                                                    val manager = androidx.glance.appwidget.GlanceAppWidgetManager(context)
                                                                    val glanceId = manager.getGlanceIdBy(selectWidgetAppWidgetId)
                                                                    android.util.Log.d("MainActivityWidget", "Got glanceId=$glanceId for widgetId=$selectWidgetAppWidgetId, calling update")
                                                                    com.notel.notel.widget.SingleHabitWidget().update(context, glanceId)
                                                                } catch (e: Exception) {
                                                                    android.util.Log.e("MainActivityWidget", "Error updating single widget", e)
                                                                }
                                                            }
                                                            selectWidgetAppWidgetId = -1
                                                        }
                                                        .padding(vertical = 12.dp, horizontal = 4.dp),
                                                    verticalAlignment = Alignment.CenterVertically
                                                ) {
                                                    Text(habit.title, color = NotelTextPrimary, style = MaterialTheme.typography.bodyLarge)
                                                }
                                            }
                                        }
                                    }
                                },
                                confirmButton = {
                                    androidx.compose.material3.TextButton(onClick = { selectWidgetAppWidgetId = -1 }) {
                                        Text("Cancel", color = NotelPrimary)
                                    }
                                },
                                containerColor = NotelSurface,
                                textContentColor = NotelTextPrimary,
                                titleContentColor = NotelTextPrimary
                            )
                        }


            }
        }
    }
}

    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        android.util.Log.d("MainActivityWidget", "onNewIntent: intent=$intent, extras=${intent.extras?.keySet()?.associateWith { intent.extras?.get(it) }}")
        val isSelectAction = intent.action?.startsWith("com.notel.notel.ACTION_SELECT_HABIT_") == true
        val widgetId = if (isSelectAction) {
            intent.action?.substringAfterLast("_")?.toIntOrNull() ?: -1
        } else {
            intent.getIntExtra("EXTRA_APP_WIDGET_ID", -1)
        }
        if ((intent.getBooleanExtra("EXTRA_SELECT_WIDGET_HABIT", false) || isSelectAction) && widgetId != -1) {
            selectWidgetAppWidgetIdState.value = widgetId
            intent.removeExtra("EXTRA_SELECT_WIDGET_HABIT")
            intent.removeExtra("EXTRA_APP_WIDGET_ID")
        }
    }

    private val dateChangedReceiver = object : android.content.BroadcastReceiver() {
        override fun onReceive(context: android.content.Context, intent: android.content.Intent) {
            if (intent.action == android.content.Intent.ACTION_DATE_CHANGED ||
                intent.action == android.content.Intent.ACTION_TIME_CHANGED) {
                refreshWidgets()
            }
        }
    }

    private fun refreshWidgets() {
        lifecycleScope.launch {
            try {
                com.notel.notel.widget.HabitWidget().updateAll(this@MainActivity)
                com.notel.notel.widget.SingleHabitWidget().updateAll(this@MainActivity)
            } catch (e: Exception) { /* best effort */ }
        }
    }

    override fun onResume() {
        super.onResume()
        // Refresh widgets whenever app comes to foreground so they always match app state
        refreshWidgets()
        // Also listen for date changes (midnight rollover) while app is in foreground
        val filter = android.content.IntentFilter().apply {
            addAction(android.content.Intent.ACTION_DATE_CHANGED)
            addAction(android.content.Intent.ACTION_TIME_CHANGED)
        }
        registerReceiver(dateChangedReceiver, filter)
    }

    override fun onPause() {
        super.onPause()
        try { unregisterReceiver(dateChangedReceiver) } catch (e: Exception) { /* ignore */ }
    }
}


@Composable
fun NavIcon(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    isSelected: Boolean,
    showLabel: Boolean = true,
    onClick: () -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
        modifier = Modifier.clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 4.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = if (isSelected) NotelPrimary else NotelTextSecondary,
            modifier = Modifier.size(20.dp)
        )
        if (showLabel) {
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                fontSize = 9.sp,
                color = if (isSelected) NotelPrimary else NotelTextSecondary,
                fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal
            )
        }
    }
}

