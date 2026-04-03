package com.notel.notel

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.clickable
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
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
import com.notel.notel.ui.viewmodel.FitbitViewModel
import android.content.Intent
import android.net.Uri
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.collectLatest
import com.notel.notel.R

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        syncShortcuts()
        setContent {
            NotelTheme {
                NotelNavGraph()
            }
        }
    }

    /**
     * Manually pushes Jot's capabilities to the system's ShortcutManager.
     * This helps Google Assistant "see" the app and its BII (Built-In Intents)
     * even before it is indexed naturally.
     */
    private fun syncShortcuts() {
        try {
            val noteShortcut = ShortcutInfoCompat.Builder(this, "create_note_voice")
                .setShortLabel("Create Note")
                .setLongLabel("Make a new note in Jot")
                .setIcon(IconCompat.createWithResource(this, R.drawable.ic_jot_launcher))
                .addCapabilityBinding("actions.intent.OPEN_APP_FEATURE", null, null)
                .setIntent(Intent(Intent.ACTION_VIEW, Uri.parse("jot://create-note")))
                .build()

            val healthShortcut = ShortcutInfoCompat.Builder(this, "health_note_voice")
                .setShortLabel("Health Note")
                .setLongLabel("Log a health note in Jot")
                .setIcon(IconCompat.createWithResource(this, R.drawable.ic_jot_launcher))
                .addCapabilityBinding("actions.intent.OPEN_APP_FEATURE", null, null)
                .setIntent(Intent(Intent.ACTION_VIEW, Uri.parse("jot://health-note")))
                .build()

            ShortcutManagerCompat.addDynamicShortcuts(this, listOf(noteShortcut, healthShortcut))
        } catch (e: Exception) {
            e.printStackTrace()
        }
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

    // Global banner for PDF professional reports
    var reportFile by remember { mutableStateOf<java.io.File?>(null) }
    val reportViewModel: com.notel.notel.ui.viewmodel.SettingsViewModel = hiltViewModel()

    LaunchedEffect(Unit) {
        reportViewModel.reportReadyEvent.collect { file: java.io.File ->
            val route = navController.currentBackStackEntry?.destination?.route
            // Only show the global banner if we AREN'T on the settings screen.
            // The settings screen handles its own context-aware (AI vs other) notification.
            if (route != "settings") {
                reportFile = file
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
            composable("settings") {
                SettingsScreen(
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
                BodyLoadScreen(onBack = { navController.popBackStack() })
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
    }
}