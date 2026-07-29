package com.notel.notel.ui.screen

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject
import com.notel.notel.data.remote.GeminiService
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.local.entity.Category

@HiltViewModel
class SetupLoadingViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    private val geminiService: GeminiService,
    private val categoryRepository: CategoryRepository,
    private val syncManager: com.notel.notel.data.sync.SyncManager
) : ViewModel() {
    
    fun finalizeSetup(onComplete: () -> Unit) {
        viewModelScope.launch {
            val userContext = preferences.userContext.first()

            val generatedCats = if (userContext.isNotBlank()) {
                val result = geminiService.generateCategories(userContext)
                val aiCats = result.getOrNull() ?: emptyList()
                if (aiCats.isNotEmpty()) aiCats else listOf("Sleep", "Energy", "Mood", "Diet", "Activity")
            } else {
                listOf("Sleep", "Energy", "Mood", "Diet", "Activity")
            }
            
            // Wipe the old categories out except General (id 7)
            categoryRepository.clearCustomCategories()
            
            // Get the highest max ID to avoid primary key constraints, default to 8 since 1-7 are baseline
            val currentMax = categoryRepository.getMaxCategoryId()
            var nextId = if (currentMax < 7) 8 else currentMax + 1
            
            val colors = listOf("#FF6B6B", "#FFB347", "#6BCB77", "#4ECDC4", "#4D96FF", "#A566FF", "#FFD93D")
            val icons = listOf("Favorite", "Restaurant", "MonitorWeight", "Medication", "EmojiEvents", "Bedtime", "Mood")
            
            val catsToInsert = generatedCats.take(5).mapIndexed { index, name ->
                val newId = nextId++
                Category(
                    id = newId,
                    name = name,
                    icon = icons[index % icons.size],
                    colorHex = colors[index % colors.size],
                    isDefault = false, // mark custom
                    sortOrder = index
                )
            }
            
            // Save new AI categories to database
            categoryRepository.insertAll(catsToInsert)

            // Simulate the processing phase minimum delay for UX
            delay(1500)
            preferences.setOnboardingComplete(true)
            
            // Push final status and categories to server immediately
            syncManager.syncAllData()
            
            onComplete()
        }
    }
}

@Composable
fun SetupLoadingScreen(
    viewModel: SetupLoadingViewModel = hiltViewModel(),
    onNavigateMain: () -> Unit
) {
    LaunchedEffect(Unit) {
        viewModel.finalizeSetup {
            onNavigateMain()
        }
    }

    Box(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            GlassySpinner(size = 80.dp)
            Spacer(modifier = Modifier.height(32.dp))
            Text("Setting up your Tabs database...", color = NotelPrimary, fontSize = 24.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
            Spacer(modifier = Modifier.height(16.dp))
            Text("Building custom models based on your lifestyle profile.", color = NotelTextSecondary, fontSize = 16.sp, textAlign = TextAlign.Center)
        }
    }
}
