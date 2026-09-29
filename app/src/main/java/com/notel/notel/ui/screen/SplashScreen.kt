package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.R
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.sync.SyncManager
import com.notel.notel.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class SplashViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    private val syncManager: SyncManager
) : ViewModel() {

    fun checkAuthState(onResult: (isLoggedIn: Boolean, isOnboarded: Boolean) -> Unit) {
        viewModelScope.launch {
            val isLoggedIn = preferences.loggedIn.first()
            val isOnboarded = preferences.onboardingComplete.first()

            if (isLoggedIn) {
                // Background sync asynchronously without blocking splash transition
                viewModelScope.launch {
                    try {
                        syncManager.pullAllData()
                    } catch (_: Exception) {}
                }
            }

            onResult(isLoggedIn, isOnboarded)
        }
    }
}

@Composable
fun SplashScreen(
    viewModel: SplashViewModel = hiltViewModel(),
    onNavigateNext: (isLoggedIn: Boolean, isOnboarded: Boolean) -> Unit
) {
    var animState by remember { mutableStateOf(0) } // 0 = start, 1 = fadeIn, 2 = slideOut

    // Entry anims — untouched. Fade in with a slight overshoot scale, hold at 1.05
    // through the exit (the slide replaces the old shrink).
    val alphaAnim by animateFloatAsState(
        targetValue = when (animState) {
            1 -> 1f
            2 -> 1f
            else -> 0f
        },
        animationSpec = tween(
            durationMillis = 650,
            easing = FastOutSlowInEasing
        ),
        label = "SplashAlpha"
    )

    val scaleAnim by animateFloatAsState(
        targetValue = when (animState) {
            1 -> 1.05f
            2 -> 1.05f
            else -> 0.8f
        },
        animationSpec = tween(
            durationMillis = 650,
            easing = FastOutSlowInEasing
        ),
        label = "SplashScale"
    )

    // Exit: content sweeps upward off the top of the screen over 650ms with
    // FastOutSlowInEasing (no spring, no overshoot — Master Bible motion).
    // Alpha holds at 1 through the first 60% of the travel, then fades to 0
    // in the final stretch so nothing pops off-screen.
    val exitProgress by animateFloatAsState(
        targetValue = if (animState == 2) 1f else 0f,
        animationSpec = tween(
            durationMillis = 650,
            easing = FastOutSlowInEasing
        ),
        label = "SplashExit"
    )
    val exitAlpha = if (exitProgress < 0.6f) 1f else 1f - (exitProgress - 0.6f) / 0.4f

    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val screenHeightPx = remember(configuration, density) {
        with(density) { configuration.screenHeightDp.dp.toPx() }
    }

    LaunchedEffect(Unit) {
        animState = 1 // Fade In
        delay(1200)   // Hold visible with glass glow
        animState = 2 // Slide Out
        delay(650)    // Complete slide out transition

        viewModel.checkAuthState { isLoggedIn, isOnboarded ->
            onNavigateNext(isLoggedIn, isOnboarded)
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(NotelBackground),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier
                .alpha(alphaAnim)
                .scale(scaleAnim)
                .graphicsLayer {
                    // Exit slide: translate upward off the top of the screen.
                    // Chained alphas multiply, so entry alpha * exit alpha is correct.
                    translationY = -exitProgress * screenHeightPx
                    alpha = exitAlpha
                }
        ) {
            // Tabs sticky note logo
            Image(
                painter = painterResource(id = R.drawable.ic_tabs_note),
                contentDescription = "Tabs Logo",
                modifier = Modifier.size(130.dp)
            )

            Spacer(modifier = Modifier.height(24.dp))

            Text(
                text = "Tabs",
                fontSize = 36.sp,
                fontWeight = FontWeight.Black,
                color = NotelPrimary,
                letterSpacing = 2.sp
            )

            Spacer(modifier = Modifier.height(6.dp))

            Text(
                text = "Health & Symptom Intelligence",
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = NotelTextSecondary
            )
        }
    }
}
