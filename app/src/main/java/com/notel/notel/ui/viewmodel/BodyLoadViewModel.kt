package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.remote.BodyLoadResponse
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import javax.inject.Inject

data class FactorWeight(
    val name: String,
    val weight: Float
)

data class BodyLoadState(
    val score: Int = 0,
    val factors: List<FactorWeight> = emptyList(),
    val adviceList: List<String> = emptyList(),
    val isLoading: Boolean = false,
    val error: String? = null,
    
    // Detailed stats for the sub-pillars
    val activeCalories: Int = 0,
    val sleepMinutes: Int = 0,
    val jotCount7Days: Int = 0,
    val jotCountDaily: Int = 0,
    val spikeCount: Int = 0,
    val currentStreak: Int = 0,
    val bestStreak: Int = 0,
    
    // History for the top row (Day score list)
    val historyScores: List<BodyLoadSnapshot> = emptyList(),
    val selectedDate: String = java.time.LocalDate.now().toString(), // "yyyy-MM-dd"
    val selectedFactor: String? = null
)

data class BodyLoadSnapshot(
    val date: String,    // "yyyy-MM-dd"
    val displayDay: String, // "Fri"
    val score: Int,
    val factors: List<FactorWeight>,
    val adviceList: List<String>
)

@HiltViewModel
class BodyLoadViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val categoryRepository: CategoryRepository,
    private val preferences: com.notel.notel.data.preferences.NotelPreferences
) : ViewModel() {

    private val _uiState = MutableStateFlow(BodyLoadState())
    val uiState = _uiState.asStateFlow()

    init {
        refresh(force = false)
    }

    fun selectFactor(name: String?) {
        _uiState.value = _uiState.value.copy(selectedFactor = name)
    }

    fun selectDay(dateStr: String) {
        viewModelScope.launch {
            val history = _uiState.value.historyScores
            val snapshot = history.find { it.date == dateStr }
            
            // 1. Immediately update the UI with AI snapshot / cache data so there is no delay
            if (snapshot != null) {
                _uiState.value = _uiState.value.copy(
                    selectedDate = dateStr,
                    score = snapshot.score,
                    factors = snapshot.factors,
                    adviceList = snapshot.adviceList
                )
            } else if (dateStr == java.time.LocalDate.now().toString()) {
                val currentAdvice = preferences.lastBodyLoadAdvice.first() ?: ""
                val currentFactors = preferences.lastBodyLoadFactors.first()
                _uiState.value = _uiState.value.copy(
                    selectedDate = dateStr,
                    score = preferences.lastBodyLoadScore.first(),
                    factors = parseFactors(currentFactors),
                    adviceList = splitAdvice(currentAdvice)
                )
            }

            // 2. Fetch raw stats for this day and merge them in
            val stats = logRepository.getDailyStatsSummary(dateStr)
            
            _uiState.value = _uiState.value.copy(
                activeCalories = stats["calories"]?.toInt() ?: 0,
                sleepMinutes = stats["sleepMins"]?.toInt() ?: 0,
                spikeCount = stats["spikeCount"]?.toInt() ?: 0,
                jotCount7Days = stats["jotCount"]?.toInt() ?: 0,
                jotCountDaily = stats["jotCountDaily"]?.toInt() ?: 0
            )
        }
    }

    fun refresh(force: Boolean = true) {
        if (_uiState.value.isLoading) return
        
        viewModelScope.launch {
            val lastRefresh = preferences.lastBodyLoadRefresh.first()
            val now = System.currentTimeMillis()
            val todayStr = java.time.LocalDate.now().toString()
            
            // Immediately load cached body load so UI doesn't look empty/loading
            if (_uiState.value.factors.isEmpty()) {
                val cachedAdvice = preferences.lastBodyLoadAdvice.first() ?: ""
                val cachedFactors = preferences.lastBodyLoadFactors.first()
                val cachedScore = preferences.lastBodyLoadScore.first()
                _uiState.value = _uiState.value.copy(
                    score = cachedScore,
                    factors = parseFactors(cachedFactors),
                    adviceList = splitAdvice(cachedAdvice)
                )
            }

            // Always fetch daily stats regardless of whether we run AI
            val stats = logRepository.getDailyStatsSummary(todayStr)
            val history = getHistoricalScores()
            
            _uiState.value = _uiState.value.copy(
                activeCalories = stats["calories"]?.toInt() ?: 0,
                sleepMinutes = stats["sleepMins"]?.toInt() ?: 0,
                spikeCount = stats["spikeCount"]?.toInt() ?: 0,
                jotCount7Days = stats["jotCount"]?.toInt() ?: 0,
                jotCountDaily = stats["jotCountDaily"]?.toInt() ?: 0,
                currentStreak = preferences.currentStreak.first(),
                bestStreak = preferences.bestStreak.first(),
                historyScores = history,
                selectedDate = todayStr
            )

            // Auto-refresh rule: 1 hour (3,600,000 ms)
            val shouldAutoRefresh = (now - lastRefresh) > (60 * 60 * 1000L)

            if (!force && !shouldAutoRefresh) {
                return@launch
            }

            _uiState.value = _uiState.value.copy(isLoading = true, error = null)
            val allCats = categoryRepository.getAllCategories().first()
            
            logRepository.getBodyLoad(allCats)
                .onSuccess { res ->
                    _uiState.value = _uiState.value.copy(
                        score = res.score,
                        factors = parseFactors(res.factors.joinToString(", ")),
                        adviceList = splitAdvice(res.advice ?: ""),
                        isLoading = false
                    )
                    preferences.setLastBodyLoadRefresh(now)
                    preferences.setLastBodyLoadData(
                        res.score,
                        res.factors.joinToString(", "),
                        res.advice ?: ""
                    )
                    // Refresh history after new result
                    _uiState.value = _uiState.value.copy(historyScores = getHistoricalScores())
                }
                .onFailure { e ->
                    _uiState.value = _uiState.value.copy(
                        isLoading = false,
                        error = null // Fail silently so we don't display 'api error' on the UI
                    )
                }
        }
    }

    private fun parseFactors(factorsStr: String): List<FactorWeight> {
        if (factorsStr.isBlank()) return emptyList()
        return try {
            factorsStr.split(",").map { part ->
                val pair = part.split(":")
                val name = pair[0].trim()
                val weight = if (pair.size > 1) pair[1].trim().toFloatOrNull() ?: 0.1f else 0.2f
                FactorWeight(name, weight)
            }.filter { it.name.isNotBlank() }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun splitAdvice(advice: String): List<String> {
        if (advice.isBlank()) return emptyList()
        if (advice.contains("error", ignoreCase = true) || advice.contains("Exception", ignoreCase = true)) return emptyList()
        
        // 1. Split by hard delimiters (newlines, bullets, asterisks, pipes, semicolons)
        var parts = advice.split(Regex("[\\n\\*\\•\\-\\|\\;]"))
            .map { it.trim().removePrefix("-").removePrefix("•").trim() }
            .filter { it.length > 10 }
            
        // If the AI completely failed to format and just gave us a giant paragraph, chunk it by sentences instead
        if (parts.size <= 1) {
            parts = advice.split(Regex("(?<=\\.)(?=\\s|$)"))
                .map { it.trim().removePrefix("-").removePrefix("•").removePrefix(Regex("\\d+\\.\\s+").toString()).trim() }
                .filter { it.length > 10 }
                .chunked(2) { chunk -> chunk.joinToString(" ") }
        } else {
            // Otherwise, we have parts, let's limit each part to 2 sentences max
            parts = parts.map { piece ->
                val sentences = piece.split(Regex("(?<=\\.)(?=\\s|$)"))
                sentences.take(2).joinToString("").trim()
            }.filter { it.isNotEmpty() }
        }
            
        return parts.take(3)
    }

    private suspend fun getHistoricalScores(): List<BodyLoadSnapshot> {
        val insightsStr = preferences.aiInsights.first()
        val insights: List<com.notel.notel.data.local.entity.AiInsight> = try {
            if (insightsStr.isNotBlank()) 
                kotlinx.serialization.json.Json.decodeFromString<List<com.notel.notel.data.local.entity.AiInsight>>(insightsStr) 
            else emptyList()
        } catch(e: Exception) { return emptyList() }
        
        val bodyLoads = insights.filter { it.type == "BodyLoad" }
            .filter { (System.currentTimeMillis() - it.timestamp) < (7L * 24 * 60 * 60 * 1000) }
            .sortedByDescending { it.timestamp }
            
        val sdfDay = java.text.SimpleDateFormat("EEE", java.util.Locale.US)
        val sdfDate = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
        
        return bodyLoads.map { insight ->
            val date = sdfDate.format(java.util.Date(insight.timestamp))
            val displayDay = sdfDay.format(java.util.Date(insight.timestamp))
            
            val score = if (insight.text.contains("Cup %: ")) {
                insight.text.substringAfter("Cup %: ").substringBefore(" |").trim().toIntOrNull() ?: 0
            } else {
                insight.text.substringAfter("Body Load: ").substringBefore(" |").trim().toIntOrNull() ?: 0
            }
            
            val factorsStr = if (insight.text.contains("Factors: ")) {
                insight.text.substringAfter("Factors: ").substringBefore(" |")
            } else ""
            
            val adviceStr = if (insight.text.contains("Advice: ")) {
                insight.text.substringAfter("Advice: ").trim()
            } else ""
            
            BodyLoadSnapshot(date, displayDay, score, parseFactors(factorsStr), splitAdvice(adviceStr))
        }
    }
}
