package com.notel.notel

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.Composable
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import androidx.navigation.navDeepLink
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.platform.LocalContext
import com.notel.notel.ui.screen.*
import com.notel.notel.ui.theme.NotelTheme
import com.notel.notel.ui.viewmodel.FitbitViewModel
import dagger.hilt.android.AndroidEntryPoint
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            NotelTheme {
                NotelNavGraph()
            }
        }
    }
}

@Composable
fun NotelNavGraph() {
    val navController = rememberNavController()
    val context = LocalContext.current

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

            // Handle background sync on resume
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

            // Extract the 'code' if it's a deep link callback
            val intent = (LocalContext.current as? androidx.activity.ComponentActivity)?.intent
            val code = intent?.data?.getQueryParameter("code")
            
            androidx.compose.runtime.LaunchedEffect(code) {
                if (code != null) {
                    fitbitViewModel.exchangeCodeForToken(code)
                    // Clear the intent data so it doesn't trigger again on config change
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
}