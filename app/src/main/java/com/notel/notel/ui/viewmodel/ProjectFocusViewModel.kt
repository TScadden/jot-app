package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.JotApi
import com.notel.notel.data.remote.SyncProfileRequest
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject

@Serializable
data class ActiveProjectTest(
    val title: String,
    val desc: String? = null,
    val durationDays: Int,
    val startTimestamp: Long,
    val logs: Map<String, Boolean> = emptyMap()
)

@Serializable
data class FocusStateDto(
    val activeTest: ActiveProjectTest? = null
)

data class ProjectFocusUiState(
    val isLoading: Boolean = false,
    val activeTest: ActiveProjectTest? = null,
    val error: String? = null
)

private val lenientJson = Json {
    ignoreUnknownKeys = true
    isLenient = true
    coerceInputValues = true
}

@HiltViewModel
class ProjectFocusViewModel @Inject constructor(
    private val preferences: NotelPreferences,
    private val api: JotApi
) : ViewModel() {

    private val _uiState = MutableStateFlow(ProjectFocusUiState())
    val uiState: StateFlow<ProjectFocusUiState> = _uiState.asStateFlow()

    init {
        loadFromPrefs()
        syncFromServer()
    }

    private fun loadFromPrefs() {
        viewModelScope.launch {
            val json = preferences.focusState.first()
            val parsed = parseFocusState(json)
            _uiState.value = _uiState.value.copy(activeTest = parsed?.activeTest)
        }
    }

    private fun syncFromServer() {
        viewModelScope.launch {
            _uiState.value = _uiState.value.copy(isLoading = true)
            try {
                val response = api.pullData()
                if (response.isSuccessful) {
                    val focusJson = response.body()?.profile?.focusState
                    if (!focusJson.isNullOrBlank() && focusJson != "{}") {
                        preferences.setFocusState(focusJson)
                        val parsed = parseFocusState(focusJson)
                        _uiState.value = _uiState.value.copy(
                            activeTest = parsed?.activeTest,
                            isLoading = false
                        )
                    } else {
                        // Use local cache if server has nothing
                        val localJson = preferences.focusState.first()
                        val parsed = parseFocusState(localJson)
                        _uiState.value = _uiState.value.copy(
                            activeTest = parsed?.activeTest,
                            isLoading = false
                        )
                    }
                } else {
                    _uiState.value = _uiState.value.copy(isLoading = false)
                }
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isLoading = false,
                    error = e.message
                )
            }
        }
    }

    /** Log a daily check-in for the active test and sync back to server */
    fun checkIn(dateStr: String, didIt: Boolean) {
        val current = _uiState.value.activeTest ?: return
        val updatedLogs = current.logs.toMutableMap()
        updatedLogs[dateStr] = didIt
        val updated = current.copy(logs = updatedLogs)
        _uiState.value = _uiState.value.copy(activeTest = updated)

        viewModelScope.launch {
            val focusStateObj = FocusStateDto(activeTest = updated)
            val json = lenientJson.encodeToString(focusStateObj)
            preferences.setFocusState(json)
            // Push to server so the website sees it too
            try {
                api.syncProfile(SyncProfileRequest(focusState = json))
            } catch (e: Exception) {
                // Best effort — local is already saved
            }
        }
    }

    private fun parseFocusState(json: String): FocusStateDto? {
        if (json.isBlank() || json == "{}") return null
        return try {
            lenientJson.decodeFromString<FocusStateDto>(json)
        } catch (e: Exception) {
            null
        }
    }
}
