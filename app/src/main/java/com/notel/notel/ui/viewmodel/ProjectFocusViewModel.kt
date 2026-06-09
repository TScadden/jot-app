package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.remote.JotApi
import com.notel.notel.data.remote.SyncProfileRequest
import com.notel.notel.data.remote.FocusSuggestion
import com.notel.notel.data.remote.FocusSuggestionsRequest
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
    val id: String? = null,
    val title: String,
    val desc: String? = null,
    val durationDays: Int,
    val startTimestamp: Long,
    val lockDayStr: String? = null,
    val logs: Map<String, Boolean> = emptyMap()
)

@Serializable
data class FocusStateDto(
    val activeTests: List<ActiveProjectTest> = emptyList(),
    val activeTest: ActiveProjectTest? = null,
    val selectedTestId: String? = null,
    val currentSubView: String = "input",
    val suggestions: List<FocusSuggestion> = emptyList(),
    val selectedSuggestion: FocusSuggestion? = null,
    val setupDuration: Int = 7
)

data class ProjectFocusUiState(
    val isLoading: Boolean = false,
    val activeTests: List<ActiveProjectTest> = emptyList(),
    val activeTest: ActiveProjectTest? = null,
    val selectedTestId: String? = null,
    val currentSubView: String = "input",
    val suggestions: List<FocusSuggestion> = emptyList(),
    val selectedSuggestion: FocusSuggestion? = null,
    val setupDuration: Int = 7,
    val isSuggestionsLoading: Boolean = false,
    val startTomorrow: Boolean = false,
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
            _uiState.value = _uiState.value.copy(
                activeTests = parsed?.activeTests ?: emptyList(),
                activeTest = parsed?.activeTest,
                selectedTestId = parsed?.selectedTestId,
                currentSubView = parsed?.currentSubView ?: "input",
                suggestions = parsed?.suggestions ?: emptyList(),
                selectedSuggestion = parsed?.selectedSuggestion,
                setupDuration = parsed?.setupDuration ?: 7
            )
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
                            activeTests = parsed?.activeTests ?: emptyList(),
                            activeTest = parsed?.activeTest,
                            selectedTestId = parsed?.selectedTestId,
                            currentSubView = parsed?.currentSubView ?: "input",
                            suggestions = parsed?.suggestions ?: emptyList(),
                            selectedSuggestion = parsed?.selectedSuggestion,
                            setupDuration = parsed?.setupDuration ?: 7,
                            isLoading = false
                        )
                    } else {
                        // Use local cache if server has nothing
                        val localJson = preferences.focusState.first()
                        val parsed = parseFocusState(localJson)
                        _uiState.value = _uiState.value.copy(
                            activeTests = parsed?.activeTests ?: emptyList(),
                            activeTest = parsed?.activeTest,
                            selectedTestId = parsed?.selectedTestId,
                            currentSubView = parsed?.currentSubView ?: "input",
                            suggestions = parsed?.suggestions ?: emptyList(),
                            selectedSuggestion = parsed?.selectedSuggestion,
                            setupDuration = parsed?.setupDuration ?: 7,
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

    fun submitStruggle(struggle: String) {
        if (struggle.isBlank()) return
        _uiState.value = _uiState.value.copy(isSuggestionsLoading = true, error = null)
        viewModelScope.launch {
            try {
                val res = api.getFocusSuggestions(FocusSuggestionsRequest(struggle))
                if (res.isSuccessful && res.body() != null) {
                    val list = res.body()!!.result
                    _uiState.value = _uiState.value.copy(
                        suggestions = list,
                        currentSubView = "suggestions",
                        isSuggestionsLoading = false
                    )
                    saveCurrentState()
                } else {
                    _uiState.value = _uiState.value.copy(
                        isSuggestionsLoading = false,
                        error = "Failed to load suggestions from server: ${res.code()}"
                    )
                }
            } catch (e: Exception) {
                _uiState.value = _uiState.value.copy(
                    isSuggestionsLoading = false,
                    error = e.message
                )
            }
        }
    }

    fun selectSuggestion(s: FocusSuggestion) {
        _uiState.value = _uiState.value.copy(
            selectedSuggestion = s,
            currentSubView = "setup",
            startTomorrow = false
        )
        saveCurrentState()
    }

    fun changeDuration(increment: Boolean) {
        val cur = _uiState.value.setupDuration
        val next = if (increment) (cur + 1).coerceAtMost(30) else (cur - 1).coerceAtLeast(3)
        _uiState.value = _uiState.value.copy(setupDuration = next)
        saveCurrentState()
    }

    fun setStartTomorrow(tomorrow: Boolean) {
        _uiState.value = _uiState.value.copy(startTomorrow = tomorrow)
    }

    fun setSubView(subView: String) {
        _uiState.value = _uiState.value.copy(currentSubView = subView)
        saveCurrentState()
    }

    fun lockInProject() {
        val suggestion = _uiState.value.selectedSuggestion ?: return
        val startMs = if (_uiState.value.startTomorrow) {
            System.currentTimeMillis() + (24L * 60L * 60L * 1000L)
        } else {
            System.currentTimeMillis()
        }
        val testId = "test_${System.currentTimeMillis()}_${(0..9999).random()}"
        val todayStr = java.time.format.DateTimeFormatter.ofPattern("EEE MMM dd yyyy", java.util.Locale.US)
            .format(java.time.ZonedDateTime.now(java.time.ZoneId.systemDefault()))
        val test = ActiveProjectTest(
            id = testId,
            title = suggestion.title,
            desc = suggestion.desc,
            durationDays = _uiState.value.setupDuration,
            startTimestamp = startMs,
            lockDayStr = todayStr,
            logs = emptyMap()
        )
        val updatedTests = _uiState.value.activeTests.toMutableList().apply { add(test) }
        _uiState.value = _uiState.value.copy(
            activeTests = updatedTests,
            activeTest = test,
            selectedTestId = testId,
            currentSubView = "splash"
        )
        saveCurrentState()
    }

    fun cancelActiveTest() {
        val targetId = _uiState.value.selectedTestId
        val updatedTests = _uiState.value.activeTests.filter { it.id != targetId }
        val fallbackTest = updatedTests.firstOrNull()
        _uiState.value = _uiState.value.copy(
            activeTests = updatedTests,
            activeTest = fallbackTest,
            selectedTestId = fallbackTest?.id,
            currentSubView = "input",
            suggestions = emptyList(),
            selectedSuggestion = null
        )
        saveCurrentState()
    }

    private fun saveCurrentState() {
        viewModelScope.launch {
            val state = FocusStateDto(
                activeTests = _uiState.value.activeTests,
                activeTest = _uiState.value.activeTest,
                selectedTestId = _uiState.value.selectedTestId,
                currentSubView = _uiState.value.currentSubView,
                suggestions = _uiState.value.suggestions,
                selectedSuggestion = _uiState.value.selectedSuggestion,
                setupDuration = _uiState.value.setupDuration
            )
            val json = lenientJson.encodeToString(state)
            preferences.setFocusState(json)
            try {
                api.syncProfile(SyncProfileRequest(focusState = json))
            } catch(e: Exception) {}
        }
    }

    /** Log a daily check-in for the active test and sync back to server */
    fun checkIn(dateStr: String, didIt: Boolean) {
        val targetId = _uiState.value.selectedTestId
        val updatedTests = _uiState.value.activeTests.map { test ->
            if (test.id == targetId || (targetId == null && test.title == _uiState.value.activeTest?.title)) {
                val updatedLogs = test.logs.toMutableMap()
                updatedLogs[dateStr] = didIt
                test.copy(logs = updatedLogs)
            } else {
                test
            }
        }
        val current = updatedTests.find { it.id == targetId || (targetId == null && it.title == _uiState.value.activeTest?.title) }
        _uiState.value = _uiState.value.copy(
            activeTests = updatedTests,
            activeTest = current
        )
        saveCurrentState()
    }

    /** Remove check-in for a given date and sync back to server */
    fun undoCheckIn(dateStr: String) {
        val targetId = _uiState.value.selectedTestId
        val updatedTests = _uiState.value.activeTests.map { test ->
            if (test.id == targetId || (targetId == null && test.title == _uiState.value.activeTest?.title)) {
                val updatedLogs = test.logs.toMutableMap()
                updatedLogs.remove(dateStr)
                test.copy(logs = updatedLogs)
            } else {
                test
            }
        }
        val current = updatedTests.find { it.id == targetId || (targetId == null && it.title == _uiState.value.activeTest?.title) }
        _uiState.value = _uiState.value.copy(
            activeTests = updatedTests,
            activeTest = current
        )
        saveCurrentState()
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
