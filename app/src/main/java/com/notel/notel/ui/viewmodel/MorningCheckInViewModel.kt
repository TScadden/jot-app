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
 * Tabs Lab prototype: morning check-in / energy snapshot.
 * Local only. Reads and writes a single new DataStore key (tabs_lab_morning_checkin),
 * never synced to the server, fully cleared by uninstalling Tabs Lab.
 */
data class MorningCheckInUiState(
    val selectedLevel: Int = 0,
    val note: String = "",
    val savedToday: Boolean = false,
    val justSaved: Boolean = false
)

@HiltViewModel
class MorningCheckInViewModel @Inject constructor(
    private val preferences: NotelPreferences
) : ViewModel() {

    companion object {
        val ENERGY_LEVELS = listOf(
            1 to "Empty",
            2 to "Low",
            3 to "Steady",
            4 to "Good",
            5 to "Full"
        )
    }

    private val _uiState = MutableStateFlow(MorningCheckInUiState())
    val uiState = _uiState.asStateFlow()

    init {
        viewModelScope.launch {
            preferences.morningCheckinLab.collect { json ->
                if (json.isBlank()) return@collect
                try {
                    val obj = JSONObject(json)
                    if (obj.optString("date", "") == LocalDate.now().toString()) {
                        val level = obj.optInt("energy", 0).coerceIn(0, 5)
                        val note = obj.optString("note", "")
                        _uiState.update {
                            it.copy(selectedLevel = level, note = note, savedToday = true)
                        }
                    }
                } catch (e: Exception) {
                    // Prototype: corrupted local data is ignored, never crashes
                }
            }
        }
    }

    fun selectLevel(level: Int) {
        if (level !in 1..5) return
        _uiState.update { it.copy(selectedLevel = level, justSaved = false) }
    }

    fun updateNote(note: String) {
        _uiState.update { it.copy(note = note, justSaved = false) }
    }

    fun saveCheckIn() {
        val state = _uiState.value
        if (state.selectedLevel !in 1..5) return
        viewModelScope.launch {
            val json = JSONObject()
                .put("date", LocalDate.now().toString())
                .put("energy", state.selectedLevel)
                .put("note", state.note.trim())
                .toString()
            preferences.setMorningCheckinLab(json)
            _uiState.update { it.copy(savedToday = true, justSaved = true) }
        }
    }
}
