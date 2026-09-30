package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.time.LocalDate
import javax.inject.Inject

/**
 * Tabs Lab energy check-in (Sep 2026, simplified): a compact 1-5 energy rating
 * that lives on the Quick Log screen. One tap saves today's rating immediately;
 * tapping a different number updates it.
 *
 * Local only. Reads and writes the existing DataStore key (tabs_lab_morning_checkin),
 * never synced to the server, fully cleared by uninstalling Tabs Lab.
 */
data class EnergyCheckInUiState(
    val selectedLevel: Int = 0
)

@HiltViewModel
class EnergyCheckInViewModel @Inject constructor(
    private val preferences: NotelPreferences
) : ViewModel() {

    private val _uiState = MutableStateFlow(EnergyCheckInUiState())
    val uiState = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            preferences.morningCheckinLab.collect { json ->
                if (json.isBlank()) return@collect
                try {
                    val obj = JSONObject(json)
                    if (obj.optString("date", "") == LocalDate.now().toString()) {
                        val level = obj.optInt("energy", 0).coerceIn(0, 5)
                        _uiState.update { it.copy(selectedLevel = level) }
                    } else {
                        // A rating from a previous day does not carry over.
                        _uiState.update { it.copy(selectedLevel = 0) }
                    }
                } catch (e: Exception) {
                    // Corrupted local data is ignored, never crashes.
                }
            }
        }
    }

    /** One tap saves today's rating. Tapping another number updates it. */
    fun selectLevel(level: Int) {
        if (level !in 1..5) return
        viewModelScope.launch {
            val json = JSONObject()
                .put("date", LocalDate.now().toString())
                .put("energy", level)
                .toString()
            preferences.setMorningCheckinLab(json)
            _uiState.update { it.copy(selectedLevel = level) }
        }
    }
}
