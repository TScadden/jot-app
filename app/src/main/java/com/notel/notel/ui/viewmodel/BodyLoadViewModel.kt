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
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.Json
import javax.inject.Inject

data class FactorWeight(
    val name: String,
    val weight: Float
)

data class WeatherState(
    val temp: Int = 0,
    val condition: String = "Clear",
    val uvIndex: Double = 0.0,
    val icon: String = "☀️",
    val locationName: String = "Unknown",
    val unit: String = "F",
    val humidity: Int = 0,
    val windSpeed: Double = 0.0
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
    val sleepDebtMins: Int = 0,
    val jotCount7Days: Int = 0,
    val jotCountDaily: Int = 0,
    val spikeCount: Int = 0,
    val currentStreak: Int = 0,
    val bestStreak: Int = 0,
    
    // History for the top row (Day score list)
    val historyScores: List<BodyLoadSnapshot> = emptyList(),
    val selectedDate: String = java.time.LocalDate.now().toString(), // "yyyy-MM-dd"
    val selectedFactor: String? = null,
    val sleepDebtHistory: List<Triple<String, Double, Double>> = emptyList(),
    val cupTheorySeen: Boolean = false,
    val weather: WeatherState? = null
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
    private val weatherApi = com.notel.notel.data.remote.WeatherApi()

    init {
        refresh(force = false)
        fetchWeather()
    }

    private var lastKnownLat: Double? = null
    private var lastKnownLon: Double? = null
    private var lastKnownCity: String? = null

    fun updateLocation(lat: Double, lon: Double, city: String) {
        lastKnownLat = lat
        lastKnownLon = lon
        lastKnownCity = city
        fetchWeather()
    }

    private fun fetchWeather() {
        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            weatherApi.getDetailedWeather(lastKnownLat, lastKnownLon, lastKnownCity)?.let { info ->
                _uiState.update { it.copy(
                    weather = WeatherState(
                        temp = info.temp,
                        condition = info.condition,
                        uvIndex = info.uvIndex,
                        icon = info.icon,
                        locationName = info.locationName,
                        unit = info.unit,
                        humidity = info.humidity,
                        windSpeed = info.windSpeed
                    )
                ) }
            }
        }
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
                activeCalories = stats["calories"] as? Int ?: (stats["calories"] as? Double)?.toInt() ?: 0,
                sleepMinutes = stats["sleepMins"] as? Int ?: (stats["sleepMins"] as? Double)?.toInt() ?: 0,
                sleepDebtMins = ((stats["sleepDebt"] as? Double ?: 0.0) * 60).toInt(),
                sleepDebtHistory = stats["sleepDebtHistory"] as? List<Triple<String, Double, Double>> ?: emptyList(),
                spikeCount = stats["spikeCount"] as? Int ?: (stats["spikeCount"] as? Double)?.toInt() ?: 0,
                jotCount7Days = stats["jotCount"] as? Int ?: (stats["jotCount"] as? Double)?.toInt() ?: 0,
                jotCountDaily = stats["jotCountDaily"] as? Int ?: (stats["jotCountDaily"] as? Double)?.toInt() ?: 0
            )
        }
    }

    fun refresh(force: Boolean = false) {
        if (_uiState.value.isLoading) return
        
        viewModelScope.launch {
            val now = System.currentTimeMillis()
            val todayStr = java.time.LocalDate.now().toString()
            val lastRefresh = preferences.lastBodyLoadRefresh.first()
            val cachedStatsJson = preferences.lastKnownStats.first()
            
            val json = Json { ignoreUnknownKeys = true }
            val cachedStats: Map<String, Double> = try {
                if (cachedStatsJson.isNotBlank() && cachedStatsJson != "{}") {
                    json.decodeFromString<Map<String, Double>>(cachedStatsJson)
                } else emptyMap()
            } catch (e: Exception) { emptyMap() }

            // Auto-refresh rule: 3 hours
            val shouldAutoRefresh = (now - lastRefresh) > (3 * 60 * 60 * 1000L) || lastRefresh == 0L

            if (!force && !shouldAutoRefresh) {
                // Restore purely from cache including stats to avoid loading times
                val cachedAdvice = preferences.lastBodyLoadAdvice.first() ?: ""
                val cachedFactors = preferences.lastBodyLoadFactors.first()
                val cachedScore = preferences.lastBodyLoadScore.first()
                val history = getHistoricalScores().sortedByDescending { it.date }
                
                _uiState.update { it.copy(
                    activeCalories = cachedStats["calories"]?.toInt() ?: 0,
                    sleepMinutes = cachedStats["sleepMins"]?.toInt() ?: 0,
                    score = cachedScore,
                    factors = parseFactors(cachedFactors),
                    adviceList = splitAdvice(cachedAdvice),
                    historyScores = history,
                    selectedDate = todayStr,
                    isLoading = false
                ) }
                return@launch
            }

            _uiState.update { it.copy(isLoading = true, error = null) }
            
            // FULL REFRESH (Force or Timer expired)
            fetchWeather()
            
            // 1. Fetch current stats
            val stats = logRepository.getDailyStatsSummary(todayStr)
            val sleepMins = stats["sleepMins"] as? Int ?: (stats["sleepMins"] as? Double)?.toInt() ?: 0

            // Save stats for next startup
            val statsToSave = stats.filterValues { it is Number }.mapValues { (it.value as Number).toDouble() }
            preferences.setLastKnownStats(json.encodeToString(statsToSave))
            
            val history = getHistoricalScores().toMutableList()
            
            // ── Heuristic Logic: Fill gaps for ALL 7 days ──────────────────
            val sdfDay = java.text.SimpleDateFormat("EEE", java.util.Locale.US)
            val last7Days = (0..6).map { java.time.LocalDate.now().minusDays(it.toLong()) }
            
            val finalHistory = mutableListOf<BodyLoadSnapshot>()
            last7Days.forEach { dateObj ->
                val dStr = dateObj.toString()
                val existing = history.find { it.date == dStr }
                val dStats = logRepository.getDailyStatsSummary(dStr)
                val dSleep = dStats["sleepMins"] as? Int ?: (dStats["sleepMins"] as? Double)?.toInt() ?: 0
                
                if (existing != null) {
                    val maskedScore = if (dSleep == 0) 0 else existing.score
                    finalHistory.add(existing.copy(score = maskedScore))
                } else {
                    val hScore = calculateHeuristicScore(dStats)
                    val displayDayStr = sdfDay.format(java.util.Date.from(dateObj.atStartOfDay(java.time.ZoneId.systemDefault()).toInstant()))
                    if (hScore > 0) {
                        finalHistory.add(BodyLoadSnapshot(
                            date = dStr, displayDay = displayDayStr, score = hScore,
                            factors = listOf(FactorWeight("Biometric Heuristic", 0.5f)),
                            adviceList = listOf("Heuristic analysis based on raw sensor data.")
                        ))
                    } else {
                        finalHistory.add(BodyLoadSnapshot(dStr, displayDayStr, 0, emptyList(), emptyList()))
                    }
                }
            }
            
            val sortedHistory = finalHistory.sortedByDescending { it.date }
            val todaySnapshot = sortedHistory.find { it.date == todayStr }
            
            _uiState.update { it.copy(
                activeCalories = stats["calories"] as? Int ?: (stats["calories"] as? Double)?.toInt() ?: 0,
                sleepMinutes = stats["sleepMins"] as? Int ?: (stats["sleepMins"] as? Double)?.toInt() ?: 0,
                sleepDebtMins = ((stats["sleepDebt"] as? Double ?: 0.0) * 60).toInt(),
                sleepDebtHistory = stats["sleepDebtHistory"] as? List<Triple<String, Double, Double>> ?: emptyList(),
                spikeCount = stats["spikeCount"] as? Int ?: (stats["spikeCount"] as? Double)?.toInt() ?: 0,
                jotCount7Days = stats["jotCount"] as? Int ?: (stats["jotCount"] as? Double)?.toInt() ?: 0,
                jotCountDaily = stats["jotCountDaily"] as? Int ?: (stats["jotCountDaily"] as? Double)?.toInt() ?: 0,
                currentStreak = preferences.currentStreak.first(),
                bestStreak = preferences.bestStreak.first(),
                historyScores = sortedHistory,
                selectedDate = todayStr,
                score = todaySnapshot?.score ?: 0,
                factors = todaySnapshot?.factors ?: emptyList(),
                adviceList = todaySnapshot?.adviceList ?: emptyList(),
                cupTheorySeen = preferences.cupTheorySeen.first()
            ) }

            if (!force && !shouldAutoRefresh) {
                return@launch
            }

            _uiState.update { it.copy(isLoading = true, error = null) }
            val allCats = categoryRepository.getAllCategories().first()
            
            val loadResult = logRepository.getBodyLoad(allCats)
            val res = loadResult.getOrNull()
            if (res != null) {
                val finalScore = if (_uiState.value.sleepMinutes == 0) 0 else res.score
                val finalAdvice = if (_uiState.value.sleepMinutes == 0) 
                    listOf("Body Load calculation is awaiting today's sleep data for clinical accuracy.") 
                else splitAdvice(res.advice ?: "")
                
                _uiState.update { it.copy(
                    score = finalScore,
                    factors = parseFactors(res.factors.joinToString(", ")),
                    adviceList = finalAdvice,
                    isLoading = false
                ) }
                preferences.setLastBodyLoadRefresh(now)
                preferences.setLastBodyLoadData(
                    res.score,
                    res.factors.joinToString(", "),
                    res.advice ?: ""
                )
            } else {
                _uiState.update { it.copy(isLoading = false, error = null) }
            }

            // Refresh history after new result (suspend call out of non-suspend lambda)
            _uiState.update { it.copy(historyScores = getHistoricalScores().sortedByDescending { h -> h.date }) }
        }
    }

    private fun calculateHeuristicScore(stats: Map<String, Any>): Int {
        val sleepMins = stats["sleepMins"] as? Int ?: (stats["sleepMins"] as? Double)?.toInt() ?: 0
        if (sleepMins == 0) return 0 // REQUIRE sleep data for a valid score

        val hrv = stats["hrv"] as? Double ?: 0.0
        val hrvMean = stats["hrvMean"] as? Double ?: 50.0
        val sleepDebt = stats["sleepDebt"] as? Double ?: 0.0
        val spikes = stats["spikeCount"] as? Double ?: 0.0
        val acwr = stats["acwr"] as? Double ?: 1.0
        val jots = stats["jotCountDaily"] as? Double ?: 0.0

        // Start with a base load
        var cupScore = 15.0 // Calm baseline

        // 1. HRV Impact (30%) - Higher HRV is lower load
        val hrvDelta = hrvMean - hrv
        if (hrv > 0) cupScore += (hrvDelta * 0.8).coerceIn(-20.0, 30.0)

        // 2. Sleep Debt (25%) - Negative balance adds load
        if (sleepDebt < 0) cupScore += (Math.abs(sleepDebt) * 8.0).coerceAtMost(25.0)

        // 3. Spikes (15%) - Each spike adds stress
        cupScore += (spikes * 4.0).coerceAtMost(15.0)

        // 4. Activity (20%) - ACWR > 1.3 adds load
        if (acwr > 1.3) cupScore += ((acwr - 1.3) * 15.0).coerceAtMost(20.0)

        // 5. Jots (10%) - Each entry suggests active symptoms
        cupScore += (jots * 3.0).coerceAtMost(10.0)

        return cupScore.toInt().coerceIn(5, 100)
    }

    fun markTheorySeen() {
        viewModelScope.launch {
            preferences.setCupTheorySeen(true)
            _uiState.value = _uiState.value.copy(cupTheorySeen = true)
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
