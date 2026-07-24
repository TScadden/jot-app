package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
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
    var animState by remember { mutableStateOf(0) } // 0 = start, 1 = fadeIn, 2 = fadeOut

    val alphaAnim by animateFloatAsState(
        targetValue = when (animState) {
            1 -> 1f
            2 -> 0f
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
            2 -> 0.9f
            else -> 0.8f
        },
        animationSpec = tween(
            durationMillis = 650,
            easing = FastOutSlowInEasing
        ),
        label = "SplashScale"
    )

    LaunchedEffect(Unit) {
        animState = 1 // Fade In
        delay(1200)   // Hold visible with glass glow
        animState = 2 // Fade Out
        delay(650)    // Complete fade out transition

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
        ) {
            // Large Glass 'J' Emblem
            Box(
                modifier = Modifier
                    .size(130.dp)
                    .clip(CircleShape)
                    .liquidGlass(
                        shape = CircleShape,
                        color = NotelSurface,
                        alpha = 0.85f,
                        showBorder = true
                    )
                    .border(2.dp, NotelPrimary.copy(alpha = 0.6f), CircleShape),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "J",
                    color = NotelPrimary,
                    fontSize = 72.sp,
                    fontWeight = FontWeight.Black
                )
            }

            Spacer(modifier = Modifier.height(24.dp))

            Text(
                text = "Jot",
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
