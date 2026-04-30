package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.Category
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.CategoryRepository
import com.notel.notel.data.repository.LogRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import com.notel.notel.data.sync.SyncManager
import javax.inject.Inject
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.data.repository.HabitRepository

data class SmartAction(
    val title: String,
    val description: String,
    val type: String, // CATEGORY_SUGGESTION, TIP
    val metadata: String = ""
)

data class QuickLogUiState(
    val categories: List<Category> = emptyList(),
    val selectedCategory: Category? = null,
    val chips: List<String> = emptyList(),
    val selectedChips: List<String> = emptyList(),
    val composedText: String = "",
    val manualText: String = "",
    val isLoadingChips: Boolean = false,
    val chipsError: String? = null,
    val retryAfterSeconds: Int = 0,
    val isSaving: Boolean = false,
    val saveSuccess: Boolean = false,
    // AI Advice
    val isLoadingAdvice: Boolean = false,
    val advice: String? = null,
    val adviceError: String? = null,
    val showAdviceDialog: Boolean = false,
    val showOnboardingDialog: Boolean = false,
    val loggedDays: Set<String> = emptySet(),
    val hasKnowledgeDocs: Boolean = false,
    // Document Comparison
    val isLoadingComparison: Boolean = false,
    val comparisonResult: String? = null,
    val comparisonError: String? = null,
    val showComparisonDialog: Boolean = false,
    val userBalance: Float = 0f,
    val showFreeCreditPopup: Boolean = false,
    val isUnlimited: Boolean = false,
    val smartCategories: List<Category> = emptyList(),
    val smartAction: SmartAction? = null,
    val autoAiSuggestions: Boolean = false,
    val eventCounters: List<com.notel.notel.ui.viewmodel.EventCounterDto> = emptyList(),
    val habits: List<HabitDtoModel> = emptyList()
)

@HiltViewModel
class QuickLogViewModel @Inject constructor(
    private val logRepository: LogRepository,
    private val categoryRepository: CategoryRepository,
    private val preferences: NotelPreferences,
    private val habitRepository: HabitRepository,
    private val syncManager: SyncManager
) : ViewModel() {
    
    private val dismissedActions = mutableSetOf<String>()

    private val _uiState = MutableStateFlow(QuickLogUiState())
    val uiState: StateFlow<QuickLogUiState> = _uiState.asStateFlow()

    val isGeneratingWeeklyRecap = logRepository.isGeneratingWeeklyRecap
    val isGeneratingDeepResearch = logRepository.isGeneratingDeepResearch
    val isComparingDocuments = logRepository.isComparingDocuments

    /** Debounce job — cancels any in-flight category switch before starting a new one */
    private var fetchJob: Job? = null
    private var debounceJob: Job? = null

    /** In-memory cache: category ID → chip list. Persists for the lifetime of the ViewModel. */
    private val chipCache = mutableMapOf<Int, List<String>>()

    private var hasAttemptedInitialRecovery = false

    init {
        // Observe categories to populate UI
        viewModelScope.launch {
            categoryRepository.getAllCategories().collect { cats ->
                _uiState.update { state ->
                    val selected = state.selectedCategory ?: cats.firstOrNull()
                    state.copy(categories = cats, selectedCategory = selected)
                }
                
                // DATA RECOVERY SAFETY NET:
                // If local categories are empty (common after login/logout cleanup), try to pull from server.
                // We use a flag to prevent an infinite loop if the server also has no categories.
                if (cats.isEmpty() && preferences.loggedIn.first() && !hasAttemptedInitialRecovery) {
                    hasAttemptedInitialRecovery = true
                    syncManager.pullAllData()
                } else {
                    calculateSmartRanking()
                }
            }
        }
        viewModelScope.launch {
            preferences.onboardingComplete.collect { complete ->
                _uiState.update { it.copy(showOnboardingDialog = !complete) }
            }
        }
        viewModelScope.launch {
            preferences.loggedDays.collect { json ->
                val days: Set<String> = try {
                    if (json.isNotBlank()) {
                        Json.decodeFromString(json)
                    } else emptySet()
                } catch (e: Exception) {
                    emptySet()
 
                }
                _uiState.update { it.copy(loggedDays = days) }
            }
        }
        viewModelScope.launch {
            preferences.knowledgeBase.collect { kb ->
                _uiState.update { it.copy(hasKnowledgeDocs = kb.isNotBlank()) }
            }
        }
        viewModelScope.launch {
            preferences.userBalance.collect { bal ->
                _uiState.update { it.copy(userBalance = bal) }
            }
        }
        viewModelScope.launch {
            preferences.showFreeCreditPopup.collect { show ->
                _uiState.update { it.copy(showFreeCreditPopup = show) }
            }
        }
        viewModelScope.launch {
            preferences.isUnlimited.collect { unlimited ->
                _uiState.update { it.copy(isUnlimited = unlimited) }
            }
        }
        viewModelScope.launch {
            preferences.autoAiSuggestions.collect { auto ->
                _uiState.update { it.copy(autoAiSuggestions = auto) }
                if (auto && _uiState.value.chips.isEmpty() && !_uiState.value.isLoadingChips && _uiState.value.selectedCategory != null) {
                    fetchSuggestions()
                }
            }
        }
        viewModelScope.launch {
            preferences.eventCounters.collect { json ->
                val list = try {
                    if (json.isNotBlank()) kotlinx.serialization.json.Json.decodeFromString<List<com.notel.notel.ui.viewmodel.EventCounterDto>>(json) else emptyList()
                } catch(e: Exception) { emptyList() }
                _uiState.update { it.copy(eventCounters = list) }
            }
        }
        viewModelScope.launch {
            habitRepository.habits.collect { list ->
                _uiState.update { it.copy(habits = list) }
                calculateSmartRanking()
            }
        }
        viewModelScope.launch {
            habitRepository.fetchHabits()
        }
    }

    fun selectCategory(category: Category) {
        val cached = chipCache[category.id]
        _uiState.update {
            it.copy(
                selectedCategory = category,
                selectedChips = emptyList(),
                composedText = "",
                // Immediately show cached chips if available — no spinner needed
                chips = cached ?: emptyList(),
                isLoadingChips = cached == null && it.autoAiSuggestions,
                chipsError = null,
                retryAfterSeconds = 0
            )
        }
        if (cached != null) return  // Already have chips — skip the API call
        if (!_uiState.value.autoAiSuggestions) return // Skip fetch if auto is off

        // Debounce: if user switches quickly, cancel the previous fetch
        debounceJob?.cancel()
        debounceJob = viewModelScope.launch {
            delay(300) // 300ms debounce — ignore rapid taps
            fetchSuggestions(category)
        }
    }

    /**
     * Fetch suggestions from the AI.
     * @param forceRefresh if true, bypass the cache and re-fetch (used by the Retry button).
     */
    fun fetchSuggestions(
        category: Category? = _uiState.value.selectedCategory,
        forceRefresh: Boolean = false
    ) {
        val cat = category ?: return

        // 1. Check local VM cache (already cleaned/truncated)
        if (!forceRefresh) {
            val cached = chipCache[cat.id]
            if (cached != null) {
                _uiState.update { it.copy(chips = cached, isLoadingChips = false, chipsError = null) }
                return
            }
            
            // 2. Check Repository-level session cache (survives tab switches)
            val repoCached = logRepository.getCachedSuggestions(cat.id)
            if (repoCached != null) {
                val cleaned = processRawChips(repoCached)
                chipCache[cat.id] = cleaned
                _uiState.update { it.copy(chips = cleaned, isLoadingChips = false, chipsError = null) }
                return
            }
        }

        // 3. Fallback: If not cached and auto-AI is off AND this isn't a forced manual load — don't auto-fetch
        if (!forceRefresh && !_uiState.value.autoAiSuggestions) {
             return
        }

        fetchJob?.cancel()
        fetchJob = viewModelScope.launch {
            _uiState.update { it.copy(isLoadingChips = true, chipsError = null, retryAfterSeconds = 0) }
            logRepository.getChipSuggestions(cat).fold(
                onSuccess = { rawChips ->
                    val chips = processRawChips(rawChips)
                    chipCache[cat.id] = chips  // store in cache
                    _uiState.update { it.copy(chips = chips, isLoadingChips = false) }
                },
                onFailure = { err ->
                    val msg = err.message ?: "Failed to load suggestions"
                    val waitMatch = Regex("(\\d+) seconds").find(msg)
                    val seconds = waitMatch?.groupValues?.get(1)?.toIntOrNull() ?: 0
                    _uiState.update {
                        it.copy(
                            isLoadingChips = false,
                            chipsError = msg,
                            retryAfterSeconds = seconds
                        )
                    }
                    if (seconds > 0) {
                        for (s in seconds - 1 downTo 0) {
                            delay(1000)
                            _uiState.update { it.copy(retryAfterSeconds = s) }
                        }
                    }
                }
            )
        }
    }

    fun toggleChip(chip: String) {
        _uiState.update { state ->
            val current = state.selectedChips.toMutableList()
            if (chip in current) current.remove(chip) else current.add(chip)
            state.copy(
                selectedChips = current,
                composedText = current.joinToString(" · ")
            )
        }
    }

    fun updateManualText(text: String) = _uiState.update { it.copy(manualText = text) }

    fun saveEntry() {
        val state = _uiState.value
        val category = state.selectedCategory ?: return
        val body = buildString {
            if (state.composedText.isNotBlank()) append(state.composedText)
            if (state.manualText.isNotBlank()) {
                if (isNotEmpty()) append(" — ")
                append(state.manualText)
            }
        }.ifBlank { return }

        viewModelScope.launch {
            _uiState.update { it.copy(isSaving = true) }
            
            // User requested: if no tiles/chips added, default to General (ID 7)
            val finalCategoryId = if (state.selectedChips.isEmpty()) 7 else category.id
            
            // Mark today as logged
            val todayStr = LocalDate.now().format(DateTimeFormatter.ISO_LOCAL_DATE)
            val updatedDays = state.loggedDays + todayStr
            preferences.setLoggedDays(Json.encodeToString(updatedDays))

            logRepository.insertEntry(
                LogEntry(
                    categoryId = finalCategoryId,
                    body = body,
                    chips = Json.encodeToString(state.selectedChips),
                    manualText = "", // No longer storing redundant manual text separately
                    source = if (state.selectedChips.isNotEmpty()) "Combined" else "Manual"
                )
            )
            
            // Invalidate cache for this category so next fetch reflects the new entry
            chipCache.remove(category.id)
            _uiState.update {
                it.copy(
                    isSaving = false,
                    saveSuccess = true,
                    selectedChips = emptyList(),
                    composedText = "",
                    manualText = ""
                )
            }
            calculateSmartRanking()
            
            // Final push to ensure profile data (logged days, counters) is updated
            syncManager.syncAllData()
        }
    }

    private fun calculateSmartRanking() {
        viewModelScope.launch {
            val recentEntries = logRepository.getRecentEntriesAll(50)
            val categories = _uiState.value.categories
            if (categories.isEmpty()) return@launch

            // 1. Scoring Map
            val scores = mutableMapOf<Int, Int>()

            // 2. Frequency Weighting (Recent activity)
            recentEntries.forEach { entry ->
                scores[entry.categoryId] = (scores[entry.categoryId] ?: 0) + 2
            }

            // 3. Contextual Awareness (Time of Day Weighting)
            val hour = java.time.LocalTime.now().hour
            when (hour) {
                in 5..10 -> { // Morning: Sleep, Heart Rate, Symptoms
                    scores[3] = (scores[3] ?: 0) + 10 // Sleep
                    scores[1] = (scores[1] ?: 0) + 5  // Heart Rate
                    scores[5] = (scores[5] ?: 0) + 5  // Symptoms
                }
                in 11..16 -> { // Afternoon: Calories, General
                    scores[2] = (scores[2] ?: 0) + 10 // Calories
                    scores[7] = (scores[7] ?: 0) + 5  // General
                }
                in 17..23 -> { // Evening: Mood, Personal, Medication
                    scores[4] = (scores[4] ?: 0) + 10 // Mood
                    scores[6] = (scores[6] ?: 0) + 8  // Personal
                    scores[8] = (scores[8] ?: 0) + 10 // Medication
                }
            }

            val finalSmart = categories
                .filter { it.id != 7 } // Exclude General from smart list (it's always available)
                .sortedByDescending { scores[it.id] ?: 0 }
                .take(5) // Only top 5

            _uiState.update { state ->
                // If auto AI is on, default to the first recommended tile instead of the plain first category
                val isDefaultSelected = state.selectedCategory == null || state.selectedCategory.id == categories.firstOrNull()?.id
                val newlySelected = if (state.autoAiSuggestions && finalSmart.isNotEmpty() && isDefaultSelected) finalSmart.first() else state.selectedCategory
                
                state.copy(smartCategories = finalSmart, selectedCategory = newlySelected)
            }
            
            val finalSelected = _uiState.value.selectedCategory
            val state = _uiState.value
            if (state.autoAiSuggestions && finalSelected != null && state.chips.isEmpty() && !state.isLoadingChips && state.chipsError == null) {
                fetchSuggestions(finalSelected)
            }
            
            checkForSmartActions(recentEntries)
        }
    }

    private fun checkForSmartActions(recent: List<LogEntry>) {
        // Feature disabled per user request
    }

    fun acceptSmartAction(action: SmartAction) {
        viewModelScope.launch {
            if (action.type == "CATEGORY_SUGGESTION") {
                val name = action.metadata
                val maxId = categoryRepository.getMaxCategoryId()
                val newCategory = Category(
                    id = maxId + 1,
                    name = name.replaceFirstChar { it.uppercase() },
                    icon = "Label", // Default icon
                    colorHex = "#4ECDC4", // Fresh teal
                    isDefault = false,
                    sortOrder = (_uiState.value.categories.minOfOrNull { it.sortOrder } ?: 0) - 1
                )
                categoryRepository.insertCategory(newCategory)
                dismissedActions.add(name.lowercase())
            }
            dismissSmartAction()
        }
    }

    fun dismissSmartAction() {
        val current = _uiState.value.smartAction
        if (current != null) {
            dismissedActions.add(current.metadata.lowercase())
        }
        _uiState.update { it.copy(smartAction = null) }
    }

    fun resetSaveSuccess() = _uiState.update { it.copy(saveSuccess = false) }

    fun requestAdvice() {
        val cats = _uiState.value.categories
        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingAdvice = true, adviceError = null, showAdviceDialog = true) }
            logRepository.getAdvice(cats).fold(
                onSuccess = { text ->
                    _uiState.update { it.copy(isLoadingAdvice = false, advice = text) }
                },
                onFailure = { err ->
                    _uiState.update {
                        it.copy(isLoadingAdvice = false, adviceError = err.message ?: "Something went wrong.")
                    }
                }
            )
        }
    }

    fun generateWeeklyRecap() {
        val cats = _uiState.value.categories
        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingAdvice = true, adviceError = null, showAdviceDialog = true) }
            logRepository.getWeeklyRecap(cats).fold(
                onSuccess = { text ->
                    _uiState.update { it.copy(isLoadingAdvice = false, advice = text) }
                },
                onFailure = { err ->
                    _uiState.update {
                        it.copy(isLoadingAdvice = false, adviceError = err.message ?: "Basic Advice failed.")
                    }
                }
            )
        }
    }

    fun generateDeepResearch() {
        val cats = _uiState.value.categories
        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingAdvice = true, adviceError = null, showAdviceDialog = true) }
            logRepository.getDeepResearch(cats).fold(
                onSuccess = { text ->
                    _uiState.update { it.copy(isLoadingAdvice = false, advice = text) }
                },
                onFailure = { err ->
                    _uiState.update {
                        it.copy(isLoadingAdvice = false, adviceError = err.message ?: "Deep Advice failed.")
                    }
                }
            )
        }
    }

    fun compareDocuments() {
        val cats = _uiState.value.categories
        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingComparison = true, comparisonError = null, showComparisonDialog = true) }
            logRepository.getDocumentComparison(cats).fold(
                onSuccess = { text ->
                    _uiState.update { it.copy(isLoadingComparison = false, comparisonResult = text) }
                },
                onFailure = { err ->
                    _uiState.update {
                        it.copy(isLoadingComparison = false, comparisonError = err.message ?: "Something went wrong.")
                    }
                }
            )
        }
    }

    fun dismissComparison() = _uiState.update { it.copy(showComparisonDialog = false, comparisonResult = null, comparisonError = null) }

    fun dismissAdvice() = _uiState.update { it.copy(showAdviceDialog = false, advice = null, adviceError = null) }

    fun dismissOnboarding() {
        _uiState.update { it.copy(showOnboardingDialog = false) }
        viewModelScope.launch {
            preferences.setOnboardingComplete(true)
        }
    }

    fun showOnboarding() {
        _uiState.update { it.copy(showOnboardingDialog = true) }
    }

    fun toggleLoggedDay(dateStr: String) {
        val currentDays = _uiState.value.loggedDays
        val updatedDays = if (currentDays.contains(dateStr)) {
            currentDays - dateStr
        } else {
            currentDays + dateStr
        }
        _uiState.update { it.copy(loggedDays = updatedDays) }
        viewModelScope.launch {
            preferences.setLoggedDays(Json.encodeToString(updatedDays))
            syncManager.syncAllData()
        }
    }

    fun dismissBonusPopup() {
        viewModelScope.launch {
            preferences.setShowFreeCreditPopup(false)
        }
    }

    fun toggleHabit(habitId: String, isCompleted: Boolean) {
        viewModelScope.launch {
            val today = LocalDate.now().format(DateTimeFormatter.ISO_LOCAL_DATE)
            habitRepository.toggleHabitLog(habitId, today, isCompleted)
            habitRepository.fetchHabits() // Refresh
        }
    }

    fun clearHabitData() {
        viewModelScope.launch {
            habitRepository.clearHabitData()
            habitRepository.fetchHabits()
        }
    }

    private fun processRawChips(raw: List<String>): List<String> {
        return raw.map { 
            val cleaned = it.replace(Regex("\\(.*?\\)"), "") // Remove () and everything inside
              .replace("?", "")
              .trim()
              .replace("\\s+".toRegex(), " ")
            
            val words = cleaned.split(" ")
            val truncated = if (words.size > 3) {
                words.take(3).joinToString(" ")
            } else {
                cleaned
            }
            
            if (truncated.length > 20) {
                truncated.take(20).trim()
            } else {
                truncated
            }
        }.filter { it.isNotBlank() }
    }
}
