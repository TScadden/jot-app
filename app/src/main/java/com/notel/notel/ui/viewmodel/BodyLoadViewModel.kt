package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import com.notel.notel.ui.theme.*
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
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
    val avgHeartRate: Int = 0,
    val currentStreak: Int = 0,
    val bestStreak: Int = 0,
    val cupTheorySeen: Boolean = true,
    val error: String? = null
)

data class WeatherState(
    val temp: Int = 0,
    val condition: String = "Clear",
    val uvIndex: Double = 0.0,
    val icon: String = "01d",
    val locationName: String = "Current Location",
    val unit: String = "F",
    val humidity: Int = 0,
    val windSpeed: Double = 0.0,
    val pressure: Double = 0.0
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

    private var lastKnownLat: Double? = null
    private var lastKnownLon: Double? = null
    private var lastKnownCity: String? = null

    init {
        // Observe streak & theory data
        viewModelScope.launch {
            preferences.currentStreak.collect { s -> _uiState.update { it.copy(currentStreak = s) } }
        }
        viewModelScope.launch {
            preferences.bestStreak.collect { s -> _uiState.update { it.copy(bestStreak = s) } }
        }
        viewModelScope.launch {
            preferences.cupTheorySeen.collect { seen -> _uiState.update { it.copy(cupTheorySeen = seen) } }
        }
        viewModelScope.launch {
            // Re-update metrics whenever selectedDate, HR history, calorie history, or sleep history changes
            combine(
                _uiState.map { it.selectedDate }.distinctUntilChanged(),
                preferences.historicalHeartRate,
                preferences.historicalCalories,
                preferences.historicalSleep,
                preferences.todayAwakeAvgHr,
                logRepository.getAllEntries()
            ) { array ->
                val date = array[0] as String
                val hrStr = array[1] as String
                val calStr = array[2] as String
                val sleepStr = array[3] as String
                val todayAwake = array[4] as Int
                // array[5] is logEntries

                val json = kotlinx.serialization.json.Json { ignoreUnknownKeys = true }
                val today = LocalDate.now().toString()
                
                // 1. Heart Rate
                var hr = 0
                if (date == today && todayAwake > 0) {
                    hr = todayAwake
                } else {
                    try {
                        val points = json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(hrStr)
                        hr = points.find { it.date == date }?.value?.toInt() ?: 0
                    } catch(e: Exception) {}
                }

                // 2. Calories
                var cal = 0
                try {
                    val points = json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(calStr)
                    cal = points.find { it.date == date }?.value?.toInt() ?: 0
                } catch(e: Exception) {}

                // 3. Sleep
                var sleep = 0
                try {
                    val points = json.decodeFromString<List<com.notel.notel.data.model.BiomarkerPoint>>(sleepStr)
                    sleep = points.find { it.date == date }?.value?.toInt() ?: 0
                } catch(e: Exception) {}

                // 4. Jots
                val count = if (date == today) {
                    logRepository.getTodayJotCount()
                } else {
                    val start = LocalDate.parse(date).atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli()
                    val end = start + (24 * 60 * 60 * 1000L)
                    logRepository.getJotCountInRange(start, end)
                }

                MetricsUpdate(hr, cal, sleep, count)
            }.collect { update ->
                _uiState.update { it.copy(
                    avgHeartRate = update.hr,
                    activeCalories = update.cal,
                    sleepMinutes = update.sleep,
                    jotCountDaily = update.jots
                ) }
            }
        }
        selectDay(LocalDate.now().toString())
        fetchWeather()
    }

    private data class MetricsUpdate(val hr: Int, val cal: Int, val sleep: Int, val jots: Int)

    fun refresh(force: Boolean = false) {
        // No logic here yet.
    }

    fun selectDay(dateStr: String) {
        val today = LocalDate.now().toString()
        _uiState.update { it.copy(selectedDate = dateStr, isLoading = true) }
        
        viewModelScope.launch {
            try {
                // getDailyStatsSummary triggers the fetch/sync and updates local preferences.
                // We don't need to manually update metrics here because the 'combine' block 
                // in init observes the selectedDate and preference changes automatically.
                logRepository.getDailyStatsSummary(dateStr, forceRefresh = (dateStr == today))
                _uiState.update { it.copy(isLoading = false) }
            } catch (e: Exception) {
                _uiState.update { it.copy(isLoading = false) }
            }
        }
    }

    fun selectFactor(name: String?) {
        _uiState.update { it.copy(selectedFactor = name) }
    }

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

    fun markTheorySeen() {
        viewModelScope.launch {
            preferences.setCupTheorySeen(true)
        }
    }
}
