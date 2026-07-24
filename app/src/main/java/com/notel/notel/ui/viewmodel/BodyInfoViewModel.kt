package com.notel.notel.ui.viewmodel

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.ui.graphics.Color
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.remote.GeminiService
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.util.BodyImpactEngine
import com.notel.notel.util.BodyRegionId
import com.notel.notel.util.EvaluatedBodyImpact
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

import com.notel.notel.data.preferences.NotelPreferences
import kotlinx.coroutines.flow.first

@HiltViewModel
class BodyInfoViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val geminiService: GeminiService,
    private val preferences: NotelPreferences
) : ViewModel() {

    private val _activeImpacts = MutableStateFlow<List<EvaluatedBodyImpact>>(emptyList())
    val activeImpacts: StateFlow<List<EvaluatedBodyImpact>> = _activeImpacts.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading: StateFlow<Boolean> = _isLoading.asStateFlow()

    init {
        observeLogs()
    }

    private fun observeLogs() {
        viewModelScope.launch {
            logRepository.getAllEntries().collect { entries ->
                if (entries.isEmpty()) {
                    _activeImpacts.value = emptyList()
                    _isLoading.value = false
                    return@collect
                }

                // 1. Immediately apply local rules so items show up instantly with zero lag
                val localImpacts = BodyImpactEngine.evaluateLogs(entries)
                _activeImpacts.value = localImpacts

                // 2. Set loading spinner while Gemini AI evaluates custom side-effects & duration
                _isLoading.value = true
                try {
                    val userContextStr = preferences.userContext.first()
                    val profileMedsStr = preferences.medications.first()
                    val combinedContext = "User Profile Context: $userContextStr\nProfile Medications: $profileMedsStr"

                    val result = geminiService.evaluateBodyImpacts(entries, userContext = combinedContext)
                    result.getOrNull()?.let { aiItems ->
                        if (aiItems.isNotEmpty()) {
                            val aiImpacts = aiItems.mapNotNull { item ->
                                val matchingLog = entries.find { it.id == item.logId }
                                val logSource = matchingLog?.source ?: ""
                                val logText = (matchingLog?.body ?: "").lowercase()
                                val isFromMedTab = logSource == "Medications Tab" || logText.contains("logged from medications tab")
                                val isMedOrPeptideItem = item.region.equals("PEPTIDE", ignoreCase = true) || item.region.equals("SYSTEMIC", ignoreCase = true)

                                // Ignore AI items for medications/peptides if the log entry was not created from the Medications Tab
                                if (isMedOrPeptideItem && !isFromMedTab) {
                                    return@mapNotNull null
                                }

                                val regionEnum = try {
                                    BodyRegionId.valueOf(item.region.uppercase())
                                } catch (e: Exception) {
                                    BodyRegionId.BACK
                                }
                                val timestamp = matchingLog?.timestamp ?: System.currentTimeMillis()
                                val displayText = matchingLog?.let { "${it.body} ${it.manualText}" } ?: item.status

                                EvaluatedBodyImpact(
                                    id = "ai_${item.logId}_${item.region}",
                                    regionId = regionEnum,
                                    regionName = item.regionName,
                                    status = item.status,
                                    details = item.details,
                                    color = when (regionEnum) {
                                        BodyRegionId.HEAD -> Color(0xFFFF7043)
                                        BodyRegionId.EYES -> Color(0xFFFFB300)
                                        BodyRegionId.LEFT_ARM, BodyRegionId.RIGHT_ARM -> Color(0xFFFF5252)
                                        BodyRegionId.ABDOMEN -> Color(0xFF26A69A)
                                        BodyRegionId.LEFT_SIDE, BodyRegionId.RIGHT_SIDE -> Color(0xFFAB47BC)
                                        BodyRegionId.BACK -> Color(0xFFEF5350)
                                        else -> Color(0xFF42A5F5)
                                    },
                                    icon = Icons.Default.Warning,
                                    timestamp = timestamp,
                                    durationMinutes = item.durationMinutes,
                                    originalLogText = displayText,
                                    relatedLogId = item.logId
                                )
                            }
                            if (aiImpacts.isNotEmpty()) {
                                _activeImpacts.value = aiImpacts
                            }
                        }
                    }
                } finally {
                    _isLoading.value = false
                }
            }
        }
    }
}
