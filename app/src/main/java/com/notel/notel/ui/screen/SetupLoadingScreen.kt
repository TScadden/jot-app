package com.notel.notel.ui.screen

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.R
import com.notel.notel.data.local.dao.CategoryDao
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.GeminiService
import com.notel.notel.data.sync.SyncManager
import com.notel.notel.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class SetupLoadingViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    private val geminiService: GeminiService,
    private val categoryDao: CategoryDao,
    private val syncManager: SyncManager
) : ViewModel() {

    var isFinished by mutableStateOf(false)
        private set

    fun finalizeSetup(onReady: () -> Unit) {
        viewModelScope.launch {
            val userContext = preferences.userContext.first()

            val generatedCats = if (userContext.isNotBlank()) {
                val result = geminiService.generateCategories(userContext)
                val aiCats = result.getOrNull() ?: emptyList()
                if (aiCats.isNotEmpty()) aiCats else listOf("Sleep", "Energy", "Mood", "Diet", "Activity")
            } else {
                listOf("Sleep", "Energy", "Mood", "Diet", "Activity")
            }

            categoryDao.clearCustomCategories()

            val currentMax = categoryDao.getMaxCategoryId() ?: 0
            var nextId = if (currentMax < 7) 8 else currentMax + 1

            val colors = listOf("#FF6B6B", "#FFB347", "#6BCB77", "#4ECDC4", "#4D96FF", "#A566FF", "#FFD93D")
            val icons = listOf("Favorite", "Restaurant", "MonitorWeight", "Medication", "EmojiEvents", "Bedtime", "Mood")

            val catsToInsert = generatedCats.take(5).mapIndexed { index, name ->
                Category(
                    id = nextId++,
                    name = name,
                    icon = icons[index % icons.size],
                    colorHex = colors[index % colors.size],
                    isDefault = false,
                    sortOrder = index
                )
            }

            categoryDao.insertAll(catsToInsert)

            delay(2000)
            preferences.setOnboardingComplete(true)

            syncManager.pushCategories()
            syncManager.pushProfileData()

            isFinished = true
            onReady()
        }
    }
}

@Composable
fun SetupLoadingScreen(
    viewModel: SetupLoadingViewModel = hiltViewModel(),
    onNavigateMain: () -> Unit
) {
    var dotCount by remember { mutableStateOf(1) }

    LaunchedEffect(Unit) {
        viewModel.finalizeSetup {}
    }

    LaunchedEffect(viewModel.isFinished) {
        if (!viewModel.isFinished) {
            while (true) {
                delay(500)
                dotCount = (dotCount % 3) + 1
            }
        }
    }

    val dots = ".".repeat(dotCount)

    Scaffold(
        containerColor = NotelBackground
    ) { padding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp)
        ) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .align(Alignment.Center),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center
            ) {
                Spacer(Modifier.weight(1f))

                // GLOWING ORB WITH TABS LOGO
                Box(
                    modifier = Modifier
                        .size(180.dp)
                        .shadow(24.dp, CircleShape, spotColor = NotelPrimary)
                        .clip(CircleShape)
                        .background(
                            Brush.radialGradient(
                                colors = listOf(
                                    Color(0xFFE8D5FF),
                                    NotelPrimary.copy(alpha = 0.85f),
                                    NotelPrimary
                                )
                            )
                        ),
                    contentAlignment = Alignment.Center
                ) {
                    Image(
                        painter = painterResource(id = R.drawable.ic_tabs_note),
                        contentDescription = "Tabs Logo",
                        modifier = Modifier.size(110.dp)
                    )
                }

                Spacer(Modifier.height(48.dp))

                Text(
                    text = "Welcome to Tabs",
                    fontSize = 28.sp,
                    fontWeight = FontWeight.Bold,
                    color = NotelPrimary,
                    textAlign = TextAlign.Center
                )

                Spacer(Modifier.height(14.dp))

                Text(
                    text = if (viewModel.isFinished) "Your profile is all set up!" else "Getting your profile ready$dots",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.Medium,
                    color = NotelTextSecondary,
                    textAlign = TextAlign.Center
                )

                Spacer(Modifier.weight(1f))

                // BUTTON APPEARS ONLY WHEN FINISHED
                if (viewModel.isFinished) {
                    Button(
                        onClick = onNavigateMain,
                        colors = ButtonDefaults.buttonColors(containerColor = NotelPrimary),
                        shape = RoundedCornerShape(24.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(54.dp)
                    ) {
                        Text(
                            text = "Start keeping Tabs",
                            color = Color.White,
                            fontWeight = FontWeight.Bold,
                            fontSize = 16.sp
                        )
                    }
                    Spacer(Modifier.height(16.dp))
                }
            }
        }
    }
}
