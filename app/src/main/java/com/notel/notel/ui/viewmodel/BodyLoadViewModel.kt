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
        // We are starting from scratch. No logic here yet.
    }

    fun refresh(force: Boolean = false) {
        // No logic here yet.
    }

    fun selectDay(dateStr: String) {
        _uiState.update { it.copy(selectedDate = dateStr) }
    }

    fun selectFactor(name: String?) {
        _uiState.update { it.copy(selectedFactor = name) }
    }

    fun markTheorySeen() {
        viewModelScope.launch {
            preferences.setCupTheorySeen(true)
        }
    }
}
