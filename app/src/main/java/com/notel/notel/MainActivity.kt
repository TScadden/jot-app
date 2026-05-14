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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalContext
import com.notel.notel.ui.screen.*
import com.notel.notel.ui.theme.*
import com.notel.notel.ui.viewmodel.BodyLoadViewModel
import com.notel.notel.ui.viewmodel.FitbitViewModel
import dagger.hilt.android.AndroidEntryPoint

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
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val context = LocalContext.current
            val activity = context as? ComponentActivity
            // Provide a global instance of FitbitViewModel at the activity level
            // so it can handle the auth redirect regardless of current navigation destination.
            val fitbitViewModel: FitbitViewModel = hiltViewModel()
            val bodyLoadViewModel: BodyLoadViewModel = hiltViewModel()
            val quickLogViewModel: com.notel.notel.ui.viewmodel.QuickLogViewModel = hiltViewModel()
            val notelPreferences = remember { com.notel.notel.data.preferences.NotelPreferences(context) }
            
            LaunchedEffect(Unit) {
                notelPreferences.updateStreak()
                com.notel.notel.worker.BodyLoadWorker.schedule(context)
            }
            
            DisposableEffect(activity) {
                val listener = androidx.core.util.Consumer<android.content.Intent> { intent ->
                    if (intent.data?.scheme == "potscube" && intent.data?.host == "callback") {
                        val code = intent.data?.getQueryParameter("code")
                        if (code != null) {
                            fitbitViewModel.exchangeCodeForToken(code)
                            intent.data = null
                        }
                    }
                }
                activity?.addOnNewIntentListener(listener)
                
                // Check initial intent in case the app was launched directly via link
                val initialData = activity?.intent?.data
                if (initialData?.scheme == "potscube" && initialData.host == "callback") {
                    val code = initialData.getQueryParameter("code")
                    if (code != null) {
                        fitbitViewModel.exchangeCodeForToken(code)
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

                Box(modifier = Modifier.fillMaxSize()) {
                    // Main Content
                    NavHost(
                        navController = navController,
                        startDestination = "login",
                        modifier = Modifier.fillMaxSize(),
                        enterTransition = { EnterTransition.None },
                        exitTransition = { ExitTransition.None },
                        popEnterTransition = { EnterTransition.None },
                        popExitTransition = { ExitTransition.None }
                    ) {
                        composable("login") {
                            val loginViewModel: com.notel.notel.ui.screen.LoginViewModel = hiltViewModel()
                            LoginScreen(
                                onLoginSuccess = { isComplete ->
                                    if (isComplete) {
                                        navController.navigate("body_load") { popUpTo("login") { inclusive = true } }
                                    } else {
                                        navController.navigate("profile_setup") { popUpTo("login") { inclusive = true } }
                                    }
                                }
                            )
                        }
                        composable("profile_setup") {
                            ProfileSetupScreen(onNavigateNext = { navController.navigate("connections") })
                        }
                        composable("connections") {
                            ConnectionsScreen(onNavigateNext = { navController.navigate("setup_loading") })
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
                                onNavigateToMembership = { navController.navigate("settings?menu=MEMBERSHIP") }
                            )
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
                                    navController.navigate("login") {
                                        popUpTo(0) { inclusive = true }
                                    }
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
                            val fitbitViewModel: com.notel.notel.ui.viewmodel.FitbitViewModel = hiltViewModel()
                            FitbitScreen(viewModel = fitbitViewModel, onBack = { navController.popBackStack() })
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
                    val hideNavRoutes = listOf("login", "profile_setup", "connections", "setup_loading", "data_connections")
                    val isFileViewer = currentRoute?.startsWith("file_viewer") == true
                    if (currentRoute !in hideNavRoutes && !isFileViewer && currentRoute != null) {
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
                                        onClick = { 
                                            if (currentRoute != "body_load") {
                                                navController.navigate("body_load") {
                                                    popUpTo(navController.graph.startDestinationId) { saveState = true }
                                                    launchSingleTop = true
                                                    restoreState = true
                                                }
                                            }
                                        }
                                    )
                                    NavIcon(
                                        icon = Icons.Default.List,
                                        label = "History",
                                        isSelected = currentRoute == "history",
                                        onClick = { navController.navigate("history") }
                                    )
                                    // Center Pencil Button — no label, always purple, slightly larger
                                    Column(
                                        horizontalAlignment = Alignment.CenterHorizontally,
                                        modifier = Modifier
                                            .clickable {
                                                if (currentRoute != "quick_log") {
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
                                            modifier = Modifier.size(24.dp).offset(y = 5.dp)
                                        )
                                        // Invisible text to match NavIcon height so everything stays leveled
                                        Text(
                                            text = "",
                                            style = MaterialTheme.typography.labelSmall,
                                            fontSize = 9.sp
                                        )
                                    }
                                    NavIcon(
                                        icon = Icons.Default.Favorite,
                                        label = "Heart",
                                        isSelected = currentRoute == "fitbit",
                                        onClick = { navController.navigate("fitbit") }
                                    )
                                    NavIcon(
                                        icon = Icons.Default.Settings,
                                        label = "Settings",
                                        isSelected = currentRoute == "settings",
                                        onClick = { navController.navigate("settings") }
                                    )
                                }
                            }
                        }
                    }
                }
            }
    }
}

@Composable
fun NavIcon(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.clickable(onClick = onClick).padding(horizontal = 12.dp, vertical = 4.dp)
    ) {
        Icon(
            imageVector = icon,
            contentDescription = label,
            tint = if (isSelected) NotelPrimary else NotelTextSecondary,
            modifier = Modifier.size(20.dp)
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            fontSize = 9.sp,
            color = if (isSelected) NotelPrimary else NotelTextSecondary,
            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal
        )
    }
}

@Composable
fun NotelNavGraph() {
    val navController = rememberNavController()
    val context = LocalContext.current

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

    // Global banner states
    var reportFile by remember { mutableStateOf<java.io.File?>(null) }
    var aiInsight by remember { mutableStateOf<com.notel.notel.data.local.entity.AiInsight?>(null) }
    val reportViewModel: com.notel.notel.ui.viewmodel.SettingsViewModel = hiltViewModel()

    LaunchedEffect(Unit) {
        reportViewModel.reportReadyEvent.collect { file: java.io.File ->
            val route = navController.currentBackStackEntry?.destination?.route
            if (route != "settings") {
                reportFile = file
            }
        }
    }

    LaunchedEffect(Unit) {
        reportViewModel.aiInsightReadyEvent.collect { insight ->
            val route = navController.currentBackStackEntry?.destination?.route
            if (route != "settings") {
                aiInsight = insight
            }
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        NavHost(navController = navController, startDestination = "login") {
            composable("login") {
                val loginViewModel: com.notel.notel.ui.screen.LoginViewModel = hiltViewModel()
                LoginScreen(
                    onLoginSuccess = { isComplete ->
                        if (isComplete) {
                            navController.navigate("quick_log") { popUpTo("login") { inclusive = true } }
                        } else {
                            navController.navigate("profile_setup") { popUpTo("login") { inclusive = true } }
                        }
                    }
                )
            }
            composable("profile_setup") {
                ProfileSetupScreen(onNavigateNext = { navController.navigate("connections") })
            }
            composable("connections") {
                ConnectionsScreen(onNavigateNext = { navController.navigate("setup_loading") })
            }
            composable("setup_loading") {
                SetupLoadingScreen(onNavigateMain = { 
                    navController.navigate("quick_log") {
                        popUpTo("setup_loading") { inclusive = true }
                    }
                })
            }
            composable(
                "quick_log",
                deepLinks = listOf(navDeepLink { uriPattern = "potscube://callback.*" })
            ) { backStackEntry ->
                val fitbitViewModel: FitbitViewModel = hiltViewModel()
                val syncViewModel: com.notel.notel.ui.viewmodel.SyncViewModel = hiltViewModel()

                val lifecycleOwner = LocalLifecycleOwner.current
                DisposableEffect(lifecycleOwner) {
                    val observer = LifecycleEventObserver { _, event ->
                        if (event == Lifecycle.Event.ON_RESUME) {
                            fitbitViewModel.sync()
                            syncViewModel.triggerSync()
                        }
                    }
                    lifecycleOwner.lifecycle.addObserver(observer)
                    onDispose {
                        lifecycleOwner.lifecycle.removeObserver(observer)
                    }
                }

                val intent = (LocalContext.current as? androidx.activity.ComponentActivity)?.intent
                val code = intent?.data?.getQueryParameter("code")
                LaunchedEffect(code) {
                    if (code != null) {
                        fitbitViewModel.exchangeCodeForToken(code)
                        intent?.data = null
                    }
                }

                QuickLogScreen(
                    onNavigateToHistory = { navController.navigate("history") },
                    onNavigateToSettings = { navController.navigate("settings") },
                    onNavigateToMembership = { navController.navigate("settings?menu=MEMBERSHIP") },
                    onNavigateToTrends = { navController.navigate("trends") },
                    onNavigateToFitbit = { navController.navigate("fitbit") },
                    onNavigateToSleep = { navController.navigate("sleep") },
                    onNavigateToBodyLoad = { navController.navigate("body_load") }
                )
            }
            composable("sleep") {
                val fitbitViewModel: FitbitViewModel = hiltViewModel()
                SleepScreen(viewModel = fitbitViewModel, onBack = { navController.popBackStack() })
            }
            composable("history") {
                HistoryScreen(
                    onBack = { navController.popBackStack() },
                    onEntryClick = { id -> navController.navigate("detail/$id") }
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
                
                SettingsScreen(
                    initialMenu = initialMenu,
                    onBack = { navController.popBackStack() },
                    onRestartOnboarding = {
                        navController.navigate("profile_setup") {
                            popUpTo("quick_log") { inclusive = true }
                        }
                    },
                    onLogout = {
                        navController.navigate("login") {
                            popUpTo(0) { inclusive = true }
                        }
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
            composable("trends") {
                TrendsScreen(
                    onBack = { navController.popBackStack() },
                    onNavigateToEntry = { id -> navController.navigate("detail/$id") }
                )
            }
            composable("fitbit") {
                val fitbitViewModel: FitbitViewModel = hiltViewModel()
                FitbitScreen(viewModel = fitbitViewModel, onBack = { navController.popBackStack() })
            }
            composable("body_load") {
                BodyLoadScreen(
                    onBack = { navController.popBackStack() },
                    onNavigateToMembership = { navController.navigate("settings?menu=MEMBERSHIP") }
                )
            }
        }

        // Global Top Banner Overlay (Medical Report Notification)
        androidx.compose.animation.AnimatedVisibility(
            visible = reportFile != null,
            enter = androidx.compose.animation.slideInVertically(initialOffsetY = { -it }) + androidx.compose.animation.fadeIn(),
            exit = androidx.compose.animation.slideOutVertically(targetOffsetY = { -it }) + androidx.compose.animation.fadeOut(),
            modifier = Modifier.align(Alignment.TopCenter).padding(16.dp).statusBarsPadding()
        ) {
            val file = reportFile
            if (file != null) {
                Surface(
                    shape = RoundedCornerShape(16.dp),
                    color = NotelPrimary,
                    tonalElevation = 12.dp,
                    shadowElevation = 12.dp,
                    modifier = Modifier.fillMaxWidth().clickable {
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
                        context.startActivity(android.content.Intent.createChooser(intent, "Share Report"))
                        reportFile = null
                    }
                ) {
                    Row(
                        modifier = Modifier.padding(16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween
                    ) {
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                "Medical Report Ready! ✓",
                                style = MaterialTheme.typography.titleMedium,
                                color = Color.White,
                                fontWeight = FontWeight.ExtraBold
                            )
                            Text(
                                "Downloaded to phone. Tap to share.",
                                style = MaterialTheme.typography.bodyMedium,
                                color = Color.White.copy(alpha = 0.9f)
                            )
                        }
                        IconButton(onClick = { reportFile = null }) {
                            Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
                        }
                    }
                }
            }
        }

        // Global Top Banner Overlay (AI Insight Notification)
        androidx.compose.animation.AnimatedVisibility(
            visible = aiInsight != null,
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
    }
}}
