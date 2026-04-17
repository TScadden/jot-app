package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.model.Category
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import javax.inject.Inject

@Serializable
data class FactorWeight(val name: String, val weight: Float)

@Serializable
data class BodyLoadSnapshot(
    val date: String,
    val dayLabel: String,
    val score: Int,
    val factors: List<FactorWeight>,
    val adviceList: List<String>
)

data class BodyLoadState(
    val score: Int = -1,
    val factors: List<FactorWeight> = emptyList(),
    val adviceList: List<String> = emptyList(),
    val isLoading: Boolean = false,
    val activeCalories: Int = 0,
    val sleepMinutes: Int = 0,
    val jotCountDaily: Int = 0,
    val sleepDebtMins: Int = 0,
    val sleepDebtHistory: List<Triple<String, Double, Double>> = emptyList(),
    val historyScores: List<BodyLoadSnapshot> = emptyList(),
    val selectedFactor: String? = null,
    val selectedDate: String = LocalDate.now().toString(),
    val isHealthConnected: Boolean = true,
    val weather: WeatherState = WeatherState(),
    val currentStreak: Int = 0,
    val bestStreak: Int = 0,
    val hasSeenTheory: Boolean = true
)

data class WeatherState(
    val temp: Int = 0,
    val condition: String = "Clear",
    val uvIndex: Int = 0,
    val icon: String = "01d",
    val locationName: String = "Current Location",
    val unit: String = "F",
    val humidity: Int = 0,
    val windSpeed: Int = 0,
    val pressure: Int = 0
)

@HiltViewModel
class BodyLoadViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val categoryRepository: CategoryRepository,
    private val preferences: NotelPreferences
) : ViewModel() {

    private val _uiState = MutableStateFlow(BodyLoadState())
    val uiState = _uiState.asStateFlow()
    private val weatherApi = com.notel.notel.data.remote.WeatherApi()

    init {
        // 1. Initial Load from storage
        viewModelScope.launch {
            loadInitialState()
        }
        
        // 2. Periodic/Auto refresh
        refresh(force = false)
        fetchWeather()
        
        // 3. Observe persistent stats
        observePersistentData()
    }

    private fun observePersistentData() {
        viewModelScope.launch {
            preferences.currentStreak.collect { s -> _uiState.update { it.copy(currentStreak = s) } }
        }
        viewModelScope.launch {
            preferences.bestStreak.collect { s -> _uiState.update { it.copy(bestStreak = s) } }
        }
        viewModelScope.launch {
            preferences.cupTheorySeen.collect { seen -> _uiState.update { it.copy(hasSeenTheory = seen) } }
        }
    }

    fun markTheorySeen() {
        viewModelScope.launch {
            preferences.setCupTheorySeen(true)
        }
    }

    private suspend fun loadInitialState() {
        val todayStr = LocalDate.now().toString()
        val statsJson = preferences.lastKnownStats.first()
        val allHistory = parseHistory(statsJson)
        
        val cachedAdvice = preferences.lastBodyLoadAdvice.first() ?: ""
        val cachedFactors = preferences.lastBodyLoadFactors.first()
        
        updateUiFromMap(allHistory, todayStr, cachedFactors, cachedAdvice)
    }

    fun refresh(force: Boolean = false) {
        if (_uiState.value.isLoading) return
        
        viewModelScope.launch {
            val todayStr = LocalDate.now().toString()
            val now = System.currentTimeMillis()
            val lastRefresh = preferences.lastBodyLoadRefresh.first()
            
            // 1. Get current stats map
            val statsJson = preferences.lastKnownStats.first()
            val allHistory = parseHistory(statsJson).toMutableMap()
            
            // 2. Update local health stats for last 7 days (Silent)
            val last7Days = (0..6).map { LocalDate.now().minusDays(it.toLong()).toString() }
            last7Days.forEach { date ->
                val dayRaw = logRepository.getDailyStatsSummary(date)
                val existing = allHistory[date] ?: emptyMap()
                val merged = dayRaw.filterValues { it is Number }.mapValues { (it.value as Number).toDouble() }.toMutableMap()
                
                // Keep existing scores
                if (existing.containsKey("score")) merged["score"] = existing["score"]!!
                else if (!merged.containsKey("score")) merged["score"] = -1.0
                
                allHistory[date] = merged
            }
            
            // 3. Update UI with merged data before AI
            updateUiFromMap(allHistory, todayStr, preferences.lastBodyLoadFactors.first(), preferences.lastBodyLoadAdvice.first() ?: "")

            // 4. Identify days needing AI
            val isTodayStale = force || (now - lastRefresh) > (3 * 60 * 60 * 1000L)
            val daysToProcess = mutableListOf<String>()
            
            if (isTodayStale) daysToProcess.add(todayStr)
            last7Days.drop(1).forEach { d ->
                if ((allHistory[d]?.get("score") ?: -1.0) == -1.0) {
                    daysToProcess.add(d)
                }
            }
            
            if (daysToProcess.isEmpty()) {
                saveHistory(allHistory)
                preferences.setLastBodyLoadRefresh(now)
                return@launch
            }

            // 5. Show loading only if today is missing or forced
            if (force || (allHistory[todayStr]?.get("score") ?: -1.0) == -1.0) {
                _uiState.update { it.copy(isLoading = true) }
            }

            // 6. Sequential Processing
            val categories = categoryRepository.getAllCategories().first()
            for (date in daysToProcess) {
                val result = logRepository.getBodyLoad(categories, date)
                result.onSuccess { response ->
                    val dayMap = allHistory[date]?.toMutableMap() ?: mutableMapOf()
                    dayMap["score"] = response.score.toDouble()
                    allHistory[date] = dayMap
                    
                    if (date == todayStr) {
                        preferences.setLastBodyLoadData(response.score, response.factors.joinToString(","), response.advice)
                        _uiState.update { it.copy(
                            score = response.score,
                            factors = response.factors.map { FactorWeight(it, 1f) },
                            adviceList = listOf(response.advice ?: "")
                        ) }
                    }
                    
                    // Progressive history update
                    updateHistoryRow(allHistory, last7Days)
                    saveHistory(allHistory)
                }
            }
            
            preferences.setLastBodyLoadRefresh(System.currentTimeMillis())
            _uiState.update { it.copy(isLoading = false) }
        }
    }

    private fun updateUiFromMap(history: Map<String, Map<String, Double>>, todayStr: String, cachedFactors: String, cachedAdvice: String) {
        val today = history[todayStr] ?: emptyMap()
        val score = today["score"]?.toInt() ?: -1
        
        _uiState.update { it.copy(
            score = if (score >= 0) score else -1,
            activeCalories = today["calories"]?.toInt() ?: 0,
            sleepMinutes = today["sleepMins"]?.toInt() ?: 0,
            jotCountDaily = today["jotCountDaily"]?.toInt() ?: 0,
            sleepDebtMins = ((today["sleepDebt"] ?: 0.0) * 60).toInt(),
            factors = parseFactors(cachedFactors),
            adviceList = splitAdvice(cachedAdvice),
            historyScores = (0..6).map { i ->
                val d = LocalDate.now().minusDays(i.toLong()).toString()
                val s = history[d]?.get("score")?.toInt() ?: -1
                BodyLoadSnapshot(d, LocalDate.parse(d).format(DateTimeFormatter.ofPattern("EEE")), s, emptyList(), emptyList())
            }.reversed()
        ) }
    }

    private fun updateHistoryRow(history: Map<String, Map<String, Double>>, days: List<String>) {
        _uiState.update { state ->
            state.copy(
                historyScores = days.map { d ->
                    val s = history[d]?.get("score")?.toInt() ?: -1
                    BodyLoadSnapshot(d, LocalDate.parse(d).format(DateTimeFormatter.ofPattern("EEE")), s, emptyList(), emptyList())
                }.reversed()
            )
        }
    }

    private suspend fun saveHistory(history: Map<String, Map<String, Double>>) {
        preferences.setLastKnownStats(Json.encodeToString(history))
    }

    private fun parseHistory(json: String): Map<String, Map<String, Double>> {
        if (json.isBlank()) return emptyMap()
        return try {
            Json.decodeFromString(json)
        } catch (e: Exception) { emptyMap() }
    }

    private fun parseFactors(f: String): List<FactorWeight> {
        if (f.isBlank()) return emptyList()
        return f.split(",").map { FactorWeight(it.trim(), 1f) }
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
        _uiState.update { it.copy(selectedFactor = name) }
    }

    fun selectDay(dateStr: String) {
        viewModelScope.launch {
            _uiState.update { it.copy(selectedDate = dateStr) }
            val history = parseHistory(preferences.lastKnownStats.first())
            val day = history[dateStr] ?: emptyMap()
            _uiState.update { it.copy(
                activeCalories = day["calories"]?.toInt() ?: 0,
                sleepMinutes = day["sleepMins"]?.toInt() ?: 0,
                jotCountDaily = day["jotCountDaily"]?.toInt() ?: 0,
                sleepDebtMins = ((day["sleepDebt"] ?: 0.0) * 60).toInt()
            ) }
        }
    }

    private fun splitAdvice(a: String): List<String> {
        if (a.isBlank()) return emptyList()
        return if (a.contains("|")) {
            a.split("|").map { it.trim() }.filter { it.isNotBlank() }
        } else {
            a.split("\n").map { it.trim().removePrefix("-").trim() }.filter { it.isNotBlank() }
        }
    }
}
