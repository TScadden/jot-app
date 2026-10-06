package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.FlareForecastRepository
import com.notel.notel.data.research.FlareForecast
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

sealed class FlareForecastUiState {
    object Loading : FlareForecastUiState()
    data class Ready(val forecast: FlareForecast.Forecast) : FlareForecastUiState()
    data class Error(val message: String) : FlareForecastUiState()
}

@HiltViewModel
class FlareForecastViewModel @Inject constructor(
    private val repository: FlareForecastRepository,
    private val preferences: NotelPreferences
) : ViewModel() {

    private val _state = MutableStateFlow<FlareForecastUiState>(FlareForecastUiState.Loading)
    val state: StateFlow<FlareForecastUiState> = _state.asStateFlow()

    init {
        refresh()
    }

    fun refresh() {
        viewModelScope.launch(Dispatchers.IO) {
            _state.value = FlareForecastUiState.Loading
            try {
                val forecast = repository.computeForecast()
                _state.value = FlareForecastUiState.Ready(forecast)
            } catch (e: Exception) {
                _state.value = FlareForecastUiState.Error("Could not compute the forecast. Try again later.")
            }
        }
    }
}
