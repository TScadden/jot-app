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
    val windSpeed: Double = 0.0,
    val pressure: Double = 0.0
)

data class BodyLoadState(
    val score: Int = 0,
    val factors: List<FactorWeight> = emptyList(),
    val adviceList: List<String> = emptyList(),
    val isLoading: Boolean = false,
    val error: String? = null,
    val isHealthConnected: Boolean = true,
    
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
        
        // Observe streak data
        viewModelScope.launch {
            preferences.currentStreak.collect { streak ->
                _uiState.update { it.copy(currentStreak = streak) }
            }
        }
        viewModelScope.launch {
            preferences.bestStreak.collect { streak ->
                _uiState.update { it.copy(bestStreak = streak) }
            }
        }
    }

    private var lastKnownLat: Double? = null
    private var lastKnownLon: Double? = null
    private var lastKnownCity: String? = null

    fun updateLocation(lat: Double, lon: Double, city: String) {
        lastKnownLat = lat
        lastKnownLon = lon
        lastKnownCity = city
        viewModelScope.launch {
            preferences.setLastKnownLocation(lat, lon, city)
            fetchWeather()
        }
    }

    private fun fetchWeather() {
        viewModelScope.launch(kotlinx.coroutines.Dispatchers.IO) {
            val lat = lastKnownLat ?: preferences.lastKnownLat.first().takeIf { it != 0.0 }
            val lon = lastKnownLon ?: preferences.lastKnownLon.first().takeIf { it != 0.0 }
            val city = lastKnownCity ?: preferences.lastKnownCity.first()

            weatherApi.getDetailedWeather(lat, lon, city)?.let { info ->
                _uiState.update { it.copy(
                    weather = WeatherState(
                        temp = info.temp,
                        condition = info.condition,
                        uvIndex = info.uvIndex,
                        icon = info.icon,
                        locationName = info.locationName,
                        unit = info.unit,
                        humidity = info.humidity,
                        windSpeed = info.windSpeed,
                        pressure = info.pressure
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
            _uiState.update { it.copy(selectedDate = dateStr) }
            
            // Try cache first
            val statsJson = preferences.lastKnownStats.first()
            val allHistory: Map<String, Map<String, Double>> = try {
                if (statsJson.isNotBlank()) Json.decodeFromString(statsJson) else emptyMap()
            } catch(e: Exception) { emptyMap() }
            
            val stats = allHistory[dateStr] ?: logRepository.getDailyStatsSummary(dateStr).filterValues { it is Number }.mapValues { (it.value as Number).toDouble() }
            
            _uiState.update { it.copy(
                activeCalories = (stats["calories"] ?: 0.0).toInt(),
                sleepMinutes = (stats["sleepMins"] ?: 0.0).toInt(),
                jotCountDaily = (stats["jotCountDaily"] ?: 0.0).toInt(),
                sleepDebtMins = ((stats["sleepDebt"] ?: 0.0) * 60).toInt()
            ) }
        }
    }


    fun refresh(force: Boolean = false) {
        if (_uiState.value.isLoading) return
        
        viewModelScope.launch {
            val now = System.currentTimeMillis()
            val lastRefresh = preferences.lastBodyLoadRefresh.first()
            val todayStr = java.time.LocalDate.now().toString()
            
            // 1. Instant Load from Cache
            val statsJson = preferences.lastKnownStats.first()
            val allHistory: MutableMap<String, MutableMap<String, Double>> = try {
                if (statsJson.isNotBlank()) {
                    Json.decodeFromString<Map<String, Map<String, Double>>>(statsJson)
                        .mapValues { it.value.toMutableMap() }.toMutableMap()
                } else mutableMapOf()
            } catch(e: Exception) { mutableMapOf() }
            
            // 2. Refresh local stats for last 7 days silently
            val categories = categoryRepository.getAllCategories().first()
            val last7Days = (0..6).map { java.time.LocalDate.now().minusDays(it.toLong()).toString() }
            
            last7Days.forEach { d ->
                val dayRawStats = logRepository.getDailyStatsSummary(d)
                val dayStatsMap = dayRawStats.filterValues { it is Number }
                    .mapValues { (it.value as Number).toDouble() }
                
                val existing = allHistory[d] ?: mutableMapOf()
                val merged = dayStatsMap.toMutableMap()
                
                // Protective merge (preserve scores and non-zero stats)
                if (merged["sleepMins"] == 0.0 && (existing["sleepMins"] ?: 0.0) > 0.0) merged["sleepMins"] = existing["sleepMins"]!!
                if (merged["calories"] == 0.0 && (existing["calories"] ?: 0.0) > 0.0) merged["calories"] = existing["calories"]!!
                if (existing.containsKey("score")) merged["score"] = existing["score"]!!
                
                allHistory[d] = merged
            }

            // 3. Determine which days need AI Scoring
            val isTodayStale = force || (now - lastRefresh) > (3 * 60 * 60 * 1000L)
            val daysNeedingAi = mutableListOf<String>()
            
            if (isTodayStale) daysNeedingAi.add(todayStr)
            
            // Fill historical gaps (Yesterday back to 7 days)
            last7Days.drop(1).forEach { d ->
                if ((allHistory[d]?.get("score") ?: 0.0) == 0.0) {
                    daysNeedingAi.add(d)
                }
            }

            // 4. Update UI with current known data before remote calls
            val currentToday = allHistory[todayStr] ?: emptyMap()
            val todayStatsFull = logRepository.getDailyStatsSummary(todayStr)
            _uiState.update { state ->
                state.copy(
                    activeCalories = currentToday["calories"]?.toInt() ?: 0,
                    sleepMinutes = currentToday["sleepMins"]?.toInt() ?: 0,
                    jotCountDaily = currentToday["jotCountDaily"]?.toInt() ?: 0,
                    score = currentToday["score"]?.toInt() ?: 0,
                    sleepDebtMins = ((currentToday["sleepDebt"] ?: 0.0) * 60).toInt(),
                    sleepDebtHistory = todayStatsFull["sleepDebtHistory"] as? List<Triple<String, Double, Double>> ?: emptyList(),
                    historyScores = last7Days.map { d ->
                        val h = allHistory[d] ?: emptyMap()
                        BodyLoadSnapshot(d, java.time.LocalDate.parse(d).format(java.time.format.DateTimeFormatter.ofPattern("EEE")), (h["score"] ?: 0.0).toInt(), emptyList(), emptyList())
                    }.reversed()
                )
            }

            if (daysNeedingAi.isEmpty()) {
                preferences.setLastKnownStats(Json.encodeToString(allHistory))
                return@launch
            }

            // 5. Loading Indicator Rule: Only if '-' or manual refresh
            val todayScore = allHistory[todayStr]?.get("score") ?: 0.0
            if (force || todayScore == 0.0) {
                _uiState.update { it.copy(isLoading = true) }
            }

            // 6. Sequential AI calls (Today -> Yesterday -> ...)
            for (d in daysNeedingAi) {
                val result = logRepository.getBodyLoad(categories, d)
                result.onSuccess { response ->
                    val h = allHistory[d] ?: mutableMapOf()
                    h["score"] = response.score.toDouble()
                    allHistory[d] = h
                    
                    if (d == todayStr) {
                        _uiState.update { state ->
                            state.copy(
                                score = response.score,
                                factors = response.factors.map { FactorWeight(it, 1f) },
                                adviceList = listOf(response.advice ?: "")
                            )
                        }
                        preferences.setLastBodyLoadData(
                            response.score,
                            response.factors.joinToString(","),
                            response.advice
                        )
                    }
                    
                    // Progressive UI update for the history row
                    _uiState.update { state ->
                        state.copy(
                            historyScores = last7Days.map { day ->
                                val stats = allHistory[day] ?: emptyMap()
                                BodyLoadSnapshot(day, java.time.LocalDate.parse(day).format(java.time.format.DateTimeFormatter.ofPattern("EEE")), (stats["score"] ?: 0.0).toInt(), emptyList(), emptyList())
                            }.reversed()
                        )
                    }
                }
                // Save incrementally
                preferences.setLastKnownStats(Json.encodeToString(allHistory))
            }

            preferences.setLastBodyLoadRefresh(now)
            _uiState.update { it.copy(isLoading = false) }
        }
    }

    private suspend fun loadTodayFromStorage(todayStr: String) {
        val cachedAdvice = preferences.lastBodyLoadAdvice.first() ?: ""
        val cachedFactors = preferences.lastBodyLoadFactors.first()
        val statsJson = preferences.lastKnownStats.first()
        
        val allHistory: Map<String, Map<String, Double>> = try {
            if (statsJson.isNotBlank()) Json.decodeFromString(statsJson) else emptyMap()
        } catch(e: Exception) { emptyMap() }

        val todayStats = allHistory[todayStr] ?: emptyMap()
        val todayStatsFull = logRepository.getDailyStatsSummary(todayStr)

        _uiState.update { it.copy(
            score = todayStats["score"]?.toInt() ?: 0,
            factors = parseFactors(cachedFactors),
            adviceList = splitAdvice(cachedAdvice),
            activeCalories = todayStats["calories"]?.toInt() ?: 0,
            sleepMinutes = todayStats["sleepMins"]?.toInt() ?: 0,
            jotCountDaily = todayStats["jotCountDaily"]?.toInt() ?: 0,
            sleepDebtMins = ((todayStats["sleepDebt"] ?: 0.0) * 60).toInt(),
            sleepDebtHistory = todayStatsFull["sleepDebtHistory"] as? List<Triple<String, Double, Double>> ?: emptyList(),
            historyScores = (0..6).map { i ->
                val d = java.time.LocalDate.now().minusDays(i.toLong()).toString()
                val score = allHistory[d]?.get("score")?.toInt() ?: 0
                BodyLoadSnapshot(d, java.time.LocalDate.parse(d).format(java.time.format.DateTimeFormatter.ofPattern("EEE")), score, emptyList(), emptyList())
            }.reversed()
        ) }
    }

    private fun updateUiWithRawStats(stats: Map<String, Any>, date: String) {
        _uiState.update { it.copy(
            activeCalories = (stats["calories"] as? Number)?.toInt() ?: 0,
            sleepMinutes = (stats["sleepMins"] as? Number)?.toInt() ?: 0,
            jotCountDaily = (stats["jotCountDaily"] as? Number)?.toInt() ?: 0,
            sleepDebtMins = ((stats["sleepDebt"] as? Number)?.toDouble() ?: 0.0).let { (it * 60).toInt() },
            sleepDebtHistory = stats["sleepDebtHistory"] as? List<Triple<String, Double, Double>> ?: emptyList()
        ) }
    }

    private suspend fun performHistoricalSync(todayStr: String) {
        // Stripped per user request.
    }

    private fun parseFactors(factorsStr: String): List<FactorWeight> {
        if (factorsStr.isBlank()) return emptyList()
        return try {
            factorsStr.split(",").map { part ->
                val pair = part.split(":")
                val name = pair[0].trim()
                val weight = if (pair.size > 1) pair[1].trim().toFloatOrNull() ?: 0.2f else 0.2f
                FactorWeight(name, weight)
            }.filter { it.name.isNotBlank() }
        } catch (e: Exception) { emptyList() }
    }

    private fun splitAdvice(advice: String): List<String> {
        if (advice.isBlank()) return emptyList()
        return advice.split(Regex("[\\n\\*\\•\\-]"))
            .map { it.trim().removePrefix("-").removePrefix("•").trim() }
            .filter { it.length > 5 }
            .take(3)
    }

    private suspend fun getHistoricalScores(): List<BodyLoadSnapshot> {
        val insightsStr = preferences.aiInsights.first()
        val insights: List<com.notel.notel.data.local.entity.AiInsight> = try {
            if (insightsStr.isNotBlank()) Json.decodeFromString(insightsStr) else emptyList()
        } catch(e: Exception) { return emptyList() }
        
        val bodyLoads = insights.filter { it.type == "BodyLoad" }
            .filter { (System.currentTimeMillis() - it.timestamp) < (8L * 24 * 60 * 60 * 1000) }
            .sortedByDescending { it.timestamp }
            
        val sdfDay = java.text.SimpleDateFormat("EEE", java.util.Locale.US)
        val sdfDate = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US)
        
        return bodyLoads.map { insight ->
            val date = sdfDate.format(java.util.Date(insight.timestamp))
            val displayDay = sdfDay.format(java.util.Date(insight.timestamp))
            val rawText = insight.text
            val scorePart = if (rawText.contains("Body Load:")) rawText.substringAfter("Body Load:").substringBefore("|").trim() else "0"
            val score = scorePart.toIntOrNull() ?: 0
            val factorsStr = if (rawText.contains("Factors:")) rawText.substringAfter("Factors:").substringBefore("|").trim() else ""
            val adviceStr = if (rawText.contains("Advice:")) rawText.substringAfter("Advice:").trim() else ""
            
            BodyLoadSnapshot(date, displayDay, score, parseFactors(factorsStr), splitAdvice(adviceStr))
        }.distinctBy { it.date }
    }

    fun markTheorySeen() {
        viewModelScope.launch {
            preferences.setCupTheorySeen(true)
            _uiState.value = _uiState.value.copy(cupTheorySeen = true)
        }
    }
}
