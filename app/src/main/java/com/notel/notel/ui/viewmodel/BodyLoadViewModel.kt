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
    val weather: WeatherState? = null,
    val latestBpm: Int = 0
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

        // Reactive Health Updates
        viewModelScope.launch {
            preferences.todaySpikeCount.collect { count ->
                val today = java.time.LocalDate.now().toString()
                // Only update from reactive flow if we are looking at 'Today'
                if (_uiState.value.selectedDate == today) {
                    _uiState.update { it.copy(spikeCount = count) }
                }
            }
        }
        viewModelScope.launch {
            preferences.latestBpm.collect { bpm ->
                _uiState.update { it.copy(latestBpm = bpm) }
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
            
            val today = java.time.LocalDate.now().toString()
            val stats = if (allHistory[dateStr]?.containsKey("spikeCount") == true) {
                allHistory[dateStr]!!
            } else {
                logRepository.getDailyStatsSummary(dateStr).filterValues { it is Number }.mapValues { (it.value as Number).toDouble() }
            }
            
            _uiState.update { it.copy(
                activeCalories = (stats["calories"] ?: 0.0).toInt(),
                sleepMinutes = (stats["sleepMins"] ?: 0.0).toInt(),
                jotCountDaily = (stats["jotCountDaily"] ?: 0.0).toInt(),
                spikeCount = (stats["spikeCount"] ?: 0.0).toInt(),
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
            
            // 1. Instant Load from Cache (for non-forced resume)
            val statsJson = preferences.lastKnownStats.first()
            val allHistory: Map<String, Map<String, Double>> = try {
                if (statsJson.isNotBlank()) Json.decodeFromString(statsJson) else emptyMap()
            } catch(e: Exception) { emptyMap() }
            
            if (allHistory.isNotEmpty()) {
                val todayCache = allHistory[todayStr]
                val cacheSleep = (todayCache?.get("sleepMins") ?: 0.0).toInt()
                val cacheCals = (todayCache?.get("calories") ?: 0.0).toInt()
                val cacheJots = (todayCache?.get("jotCountDaily") ?: 0.0).toInt()
                val cacheSpikes = (todayCache?.get("spikeCount") ?: 0.0).toInt()
                
                // Only update if data has actually changed to prevent UI flicker
                if (cacheSleep != _uiState.value.sleepMinutes || cacheCals != _uiState.value.activeCalories || cacheJots != _uiState.value.jotCountDaily || cacheSpikes != _uiState.value.spikeCount) {
                    _uiState.update { it.copy(
                        activeCalories = cacheCals,
                        sleepMinutes = cacheSleep,
                        jotCountDaily = cacheJots,
                        spikeCount = cacheSpikes,
                        sleepDebtMins = ((todayCache?.get("sleepDebt") ?: 0.0) * 60).toInt(),
                        historyScores = (0..6).map { i ->
                            val d = java.time.LocalDate.now().minusDays(i.toLong()).toString()
                            BodyLoadSnapshot(d, java.time.LocalDate.parse(d).format(java.time.format.DateTimeFormatter.ofPattern("EEE")), 0, emptyList(), emptyList())
                        }.reversed()
                    ) }
                }
            }

            val todayCache = allHistory[todayStr]
            val isCacheMissingToday = todayCache == null
            // Only consider '0' stale if it's been at least 15 mins since last attempt
            val isCacheStaleZero = todayCache != null && (todayCache["sleepMins"] ?: 0.0) == 0.0 && (now - lastRefresh) > (15 * 60 * 1000L)
            
            // Critical: If the cache exists but was created before the spikeCount field was added, force a refresh
            val isCacheMissingSpikes = todayCache != null && !todayCache.containsKey("spikeCount")
            
            // 2. Refresh rule: force or 3-hours or if today's cache is missing/broken
            val shouldRefresh = force || (now - lastRefresh) > (3 * 60 * 60 * 1000L) || 
                               lastRefresh == 0L || isCacheMissingToday || isCacheStaleZero || isCacheMissingSpikes
            
            if (!shouldRefresh) return@launch

            // Show loader ONLY if manual refresh. Passive refreshes are silent.
            if (force) {
                _uiState.update { it.copy(isLoading = true) }
            }
            
            // 3. Smart Refresh
            // All other refreshes only fetch 'Today' and merge into cache.
            val lastUpdateDay = java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.US).format(java.util.Date(lastRefresh))
            val isFullHistoryNeeded = lastUpdateDay != todayStr || force
            
            val updatedHistory = allHistory.toMutableMap()
            
            if (isFullHistoryNeeded) {
                // Full Sync (happens on first launch of the day)
                (0..6).forEach { i ->
                    val d = java.time.LocalDate.now().minusDays(i.toLong()).toString()
                    val dayStats = logRepository.getDailyStatsSummary(d)
                    val statsMap = dayStats.filterValues { it is Number }.mapValues { (it.value as Number).toDouble() }
                    
                    // Protective merge
                    val existing = updatedHistory[d]
                    val merged = statsMap.toMutableMap()
                    if (merged["sleepMins"] == 0.0 && (existing?.get("sleepMins") ?: 0.0) > 0.0) merged["sleepMins"] = existing!!["sleepMins"]!!
                    if (merged["calories"] == 0.0 && (existing?.get("calories") ?: 0.0) > 0.0) merged["calories"] = existing!!["calories"]!!
                    
                    updatedHistory[d] = merged
                }
            } else {
                // Incremental Sync (Today Only)
                val todayStats = logRepository.getDailyStatsSummary(todayStr)
                val statsMap = todayStats.filterValues { it is Number }.mapValues { (it.value as Number).toDouble() }
                
                // Protective merge
                val existing = updatedHistory[todayStr]
                val merged = statsMap.toMutableMap()
                if (merged["sleepMins"] == 0.0 && (existing?.get("sleepMins") ?: 0.0) > 0.0) merged["sleepMins"] = existing!!["sleepMins"]!!
                if (merged["calories"] == 0.0 && (existing?.get("calories") ?: 0.0) > 0.0) merged["calories"] = existing!!["calories"]!!
                
                updatedHistory[todayStr] = merged
            }
            
            // 4. Persistence
            preferences.setLastKnownStats(Json.encodeToString(updatedHistory))
            preferences.setLastBodyLoadRefresh(now)
            
            // 5. Final UI Update
            val todayStats = logRepository.getDailyStatsSummary(todayStr)
            val finalToday = updatedHistory[todayStr] ?: emptyMap()
            
            _uiState.update { it.copy(
                isLoading = false,
                activeCalories = (finalToday["calories"] ?: 0.0).toInt(),
                sleepMinutes = (finalToday["sleepMins"] ?: 0.0).toInt(),
                jotCountDaily = (finalToday["jotCountDaily"] ?: 0.0).toInt(),
                spikeCount = (finalToday["spikeCount"] ?: 0.0).toInt(),
                sleepDebtMins = ((finalToday["sleepDebt"] ?: 0.0) * 60).toInt(),
                sleepDebtHistory = todayStats["sleepDebtHistory"] as? List<Triple<String, Double, Double>> ?: emptyList(),
                historyScores = (0..6).map { i ->
                    val d = java.time.LocalDate.now().minusDays(i.toLong()).toString()
                    BodyLoadSnapshot(d, java.time.LocalDate.parse(d).format(java.time.format.DateTimeFormatter.ofPattern("EEE")), 0, emptyList(), emptyList())
                }.reversed()
            ) }
        }
    }

    private suspend fun loadTodayFromStorage(todayStr: String) {
        val cachedScore = preferences.lastBodyLoadScore.first()
        val cachedFactors = preferences.lastBodyLoadFactors.first()
        val cachedAdvice = preferences.lastBodyLoadAdvice.first() ?: ""
        val cachedStatsJson = preferences.lastKnownStats.first()
        
        val stats: Map<String, Double> = try {
            if (cachedStatsJson.isNotBlank()) Json.decodeFromString(cachedStatsJson) else emptyMap()
        } catch(e: Exception) { emptyMap() }

        _uiState.update { it.copy(
            score = cachedScore,
            factors = parseFactors(cachedFactors),
            adviceList = splitAdvice(cachedAdvice),
            activeCalories = stats["calories"]?.toInt() ?: 0,
            sleepMinutes = stats["sleepMins"]?.toInt() ?: 0,
            jotCountDaily = stats["jotCountDaily"]?.toInt() ?: 0,
            historyScores = getHistoricalScores()
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
