package com.notel.notel.ui.screen

import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
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
import com.notel.notel.ui.theme.NotelBackground
import com.notel.notel.ui.theme.NotelPrimary
import com.notel.notel.ui.theme.NotelTextSecondary
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
    var startAnimation by remember { mutableStateOf(false) }

    // Smooth Alpha and Scale animations for the logo fade-in & fade-out
    val alphaAnim by animateFloatAsState(
        targetValue = if (startAnimation) 1f else 0f,
        animationSpec = tween(
            durationMillis = 800,
            easing = FastOutSlowInEasing
        ),
        label = "SplashAlpha"
    )

    val scaleAnim by animateFloatAsState(
        targetValue = if (startAnimation) 1f else 0.85f,
        animationSpec = tween(
            durationMillis = 800,
            easing = FastOutSlowInEasing
        ),
        label = "SplashScale"
    )

    LaunchedEffect(Unit) {
        startAnimation = true
        delay(1100) // Hold logo visible smoothly
        
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
            Box(
                modifier = Modifier
                    .size(88.dp)
                    .background(NotelPrimary.copy(alpha = 0.15f), shape = androidx.compose.foundation.shape.CircleShape)
                    .padding(16.dp),
                contentAlignment = Alignment.Center
            ) {
                Text(
                    text = "J",
                    color = NotelPrimary,
                    fontSize = 44.sp,
                    fontWeight = FontWeight.Black
                )
            }

            Spacer(modifier = Modifier.height(16.dp))

            Text(
                text = "Jot",
                fontSize = 32.sp,
                fontWeight = FontWeight.Black,
                color = NotelPrimary,
                letterSpacing = 1.sp
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
