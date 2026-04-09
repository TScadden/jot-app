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
    val spikeCount: Int = 0,
    
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
            
            // Fetch raw stats for this day
            val stats = logRepository.getDailyStatsSummary(dateStr)
            
            if (snapshot != null) {
                _uiState.value = _uiState.value.copy(
                    selectedDate = dateStr,
                    score = snapshot.score,
                    factors = snapshot.factors,
                    adviceList = snapshot.adviceList,
                    activeCalories = stats["calories"]?.toInt() ?: 0,
                    sleepMinutes = stats["sleepMins"]?.toInt() ?: 0,
                    spikeCount = stats["spikeCount"]?.toInt() ?: 0,
                    jotCount7Days = stats["jotCount"]?.toInt() ?: 0
                )
            } else if (dateStr == java.time.LocalDate.now().toString()) {
                // Today but no snapshot yet? Just load stats
                val currentAdvice = preferences.lastBodyLoadAdvice.first() ?: ""
                val currentFactors = preferences.lastBodyLoadFactors.first()
                _uiState.value = _uiState.value.copy(
                    selectedDate = dateStr,
                    score = preferences.lastBodyLoadScore.first(),
                    factors = parseFactors(currentFactors),
                    adviceList = splitAdvice(currentAdvice),
                    activeCalories = stats["calories"]?.toInt() ?: 0,
                    sleepMinutes = stats["sleepMins"]?.toInt() ?: 0,
                    spikeCount = stats["spikeCount"]?.toInt() ?: 0,
                    jotCount7Days = stats["jotCount"]?.toInt() ?: 0
                )
            }
        }
    }

    fun refresh(force: Boolean = true) {
        if (_uiState.value.isLoading) return
        
        viewModelScope.launch {
            val lastRefresh = preferences.lastBodyLoadRefresh.first()
            val now = System.currentTimeMillis()
            val todayStr = java.time.LocalDate.now().toString()
            
            val isNewDay = if (lastRefresh == 0L) true else {
                val calendarLast = java.util.Calendar.getInstance().apply { timeInMillis = lastRefresh }
                val calendarNow = java.util.Calendar.getInstance().apply { timeInMillis = now }
                calendarLast.get(java.util.Calendar.DAY_OF_YEAR) != calendarNow.get(java.util.Calendar.DAY_OF_YEAR) ||
                calendarLast.get(java.util.Calendar.YEAR) != calendarNow.get(java.util.Calendar.YEAR)
            }

            // Always fetch daily stats regardless of whether we run AI
            val stats = logRepository.getDailyStatsSummary(todayStr)
            val history = getHistoricalScores()
            
            _uiState.value = _uiState.value.copy(
                activeCalories = stats["calories"]?.toInt() ?: 0,
                sleepMinutes = stats["sleepMins"]?.toInt() ?: 0,
                spikeCount = stats["spikeCount"]?.toInt() ?: 0,
                jotCount7Days = stats["jotCount"]?.toInt() ?: 0,
                historyScores = history,
                selectedDate = todayStr
            )

            if (!force && !isNewDay) {
                // Not forced and already ran today - Load from cache
                val cachedAdvice = preferences.lastBodyLoadAdvice.first() ?: ""
                val cachedFactors = preferences.lastBodyLoadFactors.first()
                _uiState.value = _uiState.value.copy(
                    score = preferences.lastBodyLoadScore.first(),
                    factors = parseFactors(cachedFactors),
                    adviceList = splitAdvice(cachedAdvice),
                    isLoading = false
                )
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
                        error = e.message ?: "Analysis failed"
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
        
        // 1. Split by hard delimiters (newlines, bullets, asterisks, pipes, semicolons)
        val parts = advice.split(Regex("[\\n\\*\\•\\-\\|\\;]"))
            .flatMap { s ->
                // 2. Split by numbered lists ("1. ", "2. ")
                s.split(Regex("\\d+\\.\\s+"))
            }
            .flatMap { s ->
                // 3. Fallback: Split by periods followed by space and Capital letter
                s.split(Regex("(?<=\\.)\\s+(?=[A-Z])"))
            }
            .map { it.trim().removePrefix("-").removePrefix("•").trim() }
            .filter { it.length > 10 }
            
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
            
            val factorsStr = insight.text.substringAfter("Factors: ").substringBefore(" |")
            val adviceStr = insight.text.substringAfter("Advice: ").trim()
            
            BodyLoadSnapshot(date, displayDay, score, parseFactors(factorsStr), splitAdvice(adviceStr))
        }
    }
}
