package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.healthconnect.HealthConnectManager
import com.notel.notel.data.local.dao.AiInsightDao
import com.notel.notel.data.local.dao.MedicationDao
import com.notel.notel.data.local.dao.ReminderDao
import com.notel.notel.data.local.dao.ScheduledDoseOccurrenceDao
import com.notel.notel.data.local.entity.AiInsight
import com.notel.notel.data.local.entity.LogEntry
import com.notel.notel.data.local.entity.Medication
import com.notel.notel.data.local.entity.Reminder
import com.notel.notel.data.local.entity.ScheduledDoseOccurrence
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.HabitRepository
import com.notel.notel.data.repository.HealthComparisonItem
import com.notel.notel.data.repository.HealthComparisonRepository
import com.notel.notel.data.repository.ScheduledDoseRepository
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.data.sync.SyncManager
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import javax.inject.Inject

sealed class TodayPlanItem {
    abstract val id: String
    abstract val title: String
    abstract val timeDisplay: String
    abstract val isCompleted: Boolean

    data class ScheduledMedication(
        val medication: Medication,
        val dose: String,
        val timeLabel: String,
        override val isCompleted: Boolean,
        val status: ActionStatus = ActionStatus.PENDING
    ) : TodayPlanItem() {
        override val id: String = "med_${medication.id}_$timeLabel"
        override val title: String = medication.name
        override val timeDisplay: String = timeLabel
    }

    data class ScheduledReminder(
        val reminder: Reminder,
        override val isCompleted: Boolean
    ) : TodayPlanItem() {
        override val id: String = "rem_${reminder.id}"
        override val title: String = reminder.title
        override val timeDisplay: String = String.format("%02d:%02d", reminder.fixedHour, reminder.fixedMinute)
    }

    data class ScheduledHabit(
        val habit: HabitDtoModel,
        override val isCompleted: Boolean
    ) : TodayPlanItem() {
        override val id: String = "habit_${habit.id}"
        override val title: String = habit.title
        override val timeDisplay: String = habit.target_time ?: "Anytime"
    }
}

enum class ActionStatus {
    PENDING, TAKEN, SKIPPED, SNOOZED
}

data class NeedsAttentionItem(
    val id: String,
    val title: String,
    val typeText: String,
    val detailText: String,
    val itemType: ItemType,
    val medication: Medication? = null,
    val reminder: Reminder? = null,
    val habit: HabitDtoModel? = null,
    val scheduledTime: String = "Daily",
    val currentStatus: ActionStatus = ActionStatus.PENDING
) {
    enum class ItemType {
        MEDICATION, REMINDER, HABIT, SYNC_FAILED
    }
}

sealed class TodayTrendsState {
    object Loading : TodayTrendsState()
    data class Ready(val items: List<HealthComparisonItem>) : TodayTrendsState()
    object Empty : TodayTrendsState()
    data class Error(val message: String) : TodayTrendsState()
}

data class TodayUiState(
    val mode: String = "SIMPLE", // "SIMPLE" or "DETAILED"
    val summaryText: String = "",
    val remainingCount: Int = 0,
    val overdueCount: Int = 0,
    val needsAttentionItems: List<NeedsAttentionItem> = emptyList(),
    val todayPlanItems: List<TodayPlanItem> = emptyList(),
    val trendsState: TodayTrendsState = TodayTrendsState.Loading,
    val trendsItems: List<HealthComparisonItem> = emptyList(),
    val primaryInsight: AiInsight? = null,
    val supportingEntries: List<LogEntry> = emptyList(),
    val hiddenSections: Set<String> = emptySet(),
    val sectionOrder: List<String> = listOf("TODAY_PLAN", "HOW_IM_DOING", "TRENDS", "AI_INSIGHT", "QUICK_ACTIONS"),
    val isOffline: Boolean = false,
    val isSyncFailed: Boolean = false,
    val errorBannerMessage: String? = null
) {
    val whatChangedItems: List<HealthComparisonItem>
        get() = trendsItems
}

@HiltViewModel
class TodayViewModel @Inject constructor(
    private val medicationDao: MedicationDao,
    private val reminderDao: ReminderDao,
    private val habitRepository: HabitRepository,
    private val scheduledDoseOccurrenceDao: ScheduledDoseOccurrenceDao,
    private val scheduledDoseRepository: ScheduledDoseRepository,
    private val healthComparisonRepository: HealthComparisonRepository,
    private val aiInsightDao: AiInsightDao,
    private val syncManager: SyncManager,
    private val preferences: NotelPreferences
) : ViewModel() {

    private val _isRetryingSync = MutableStateFlow(false)
    private val _trendsState = MutableStateFlow<TodayTrendsState>(TodayTrendsState.Loading)
    private val _trendsItems = MutableStateFlow<List<HealthComparisonItem>>(emptyList())
    private val _errorBanner = MutableStateFlow<String?>(null)

    private val todayStr: String
        get() = LocalDate.now().format(DateTimeFormatter.ISO_LOCAL_DATE)

    init {
        loadHealthComparisons()
    }

    fun loadHealthComparisons() {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val newItems = healthComparisonRepository.getWhatChangedComparisons(todayStr)
                val currentItems = _trendsItems.value

                if (newItems.isNotEmpty()) {
                    _trendsItems.value = newItems
                    _trendsState.value = TodayTrendsState.Ready(newItems)
                } else if (currentItems.isNotEmpty()) {
                    val staleItems = currentItems.map { it.copy(isStaleOrOffline = true) }
                    _trendsItems.value = staleItems
                    _trendsState.value = TodayTrendsState.Ready(staleItems)
                } else {
                    _trendsItems.value = emptyList()
                    _trendsState.value = TodayTrendsState.Empty
                }
            } catch (e: Exception) {
                val currentItems = _trendsItems.value
                if (currentItems.isNotEmpty()) {
                    val staleItems = currentItems.map { it.copy(isStaleOrOffline = true) }
                    _trendsItems.value = staleItems
                    _trendsState.value = TodayTrendsState.Ready(staleItems)
                } else {
                    _trendsState.value = TodayTrendsState.Error(e.message ?: "Failed to calculate trends")
                }
            }
        }
    }

    val uiState: StateFlow<TodayUiState> = combine(
        medicationDao.getAllMedications(),
        reminderDao.getAllReminders(),
        habitRepository.habits,
        scheduledDoseOccurrenceDao.getOccurrencesForDate(todayStr),
        preferences.getCompletedReminders(todayStr),
        _trendsItems,
        _trendsState,
        aiInsightDao.getPrimaryActiveInsight(),
        preferences.todayMode,
        preferences.todayHiddenSections,
        preferences.todaySectionOrder,
        _errorBanner
    ) { args ->
        @Suppress("UNCHECKED_CAST")
        val medsList = args[0] as List<Medication>
        @Suppress("UNCHECKED_CAST")
        val remindersList = args[1] as List<Reminder>
        @Suppress("UNCHECKED_CAST")
        val habitsList = args[2] as List<HabitDtoModel>
        @Suppress("UNCHECKED_CAST")
        val occurrencesList = args[3] as List<ScheduledDoseOccurrence>
        @Suppress("UNCHECKED_CAST")
        val completedReminderIds = args[4] as Set<Int>
        @Suppress("UNCHECKED_CAST")
        val trendsItems = args[5] as List<HealthComparisonItem>
        val trendsState = args[6] as TodayTrendsState
        val primaryInsight = args[7] as? AiInsight
        val todayMode = args[8] as String
        @Suppress("UNCHECKED_CAST")
        val hiddenSections = args[9] as Set<String>
        @Suppress("UNCHECKED_CAST")
        val sectionOrder = args[10] as List<String>
        val errorMsg = args[11] as? String

        val activeMeds = medsList.filter { !it.isArchived }
        val enabledReminders = remindersList.filter { it.isEnabled }
        val currentDateStr = todayStr

        val occurrenceMap = occurrencesList.associateBy { it.occurrenceKey }

        // Consolidated Today's Plan
        val planList = mutableListOf<TodayPlanItem>()

        activeMeds.forEach { med ->
            val times = if (med.timesPerDay > 1) listOf("Morning", "Evening") else listOf("Daily")
            times.forEach { timeLabel ->
                val identifier = med.uuid.trim().ifEmpty { med.id.toString() }
                val normalizedSlot = timeLabel.trim().lowercase(java.util.Locale.US).replace("\\s+".toRegex(), "_")
                val key = "med_${identifier}_${currentDateStr}_${normalizedSlot}"
                val occ = occurrenceMap[key]
                val status = when (occ?.status) {
                    "TAKEN" -> ActionStatus.TAKEN
                    "SKIPPED" -> ActionStatus.SKIPPED
                    "SNOOZED" -> ActionStatus.SNOOZED
                    else -> ActionStatus.PENDING
                }
                val isTaken = status == ActionStatus.TAKEN
                planList.add(
                    TodayPlanItem.ScheduledMedication(
                        medication = med,
                        dose = med.dose,
                        timeLabel = timeLabel,
                        isCompleted = isTaken,
                        status = status
                    )
                )
            }
        }

        enabledReminders.forEach { rem ->
            val isDone = completedReminderIds.contains(rem.id)
            planList.add(
                TodayPlanItem.ScheduledReminder(
                    reminder = rem,
                    isCompleted = isDone
                )
            )
        }

        habitsList.forEach { habit ->
            val isDone = habit.logs.contains(currentDateStr)
            planList.add(
                TodayPlanItem.ScheduledHabit(
                    habit = habit,
                    isCompleted = isDone
                )
            )
        }

        val sortedPlan = planList.sortedWith(
            compareBy<TodayPlanItem> { it.isCompleted }
                .thenBy { it.timeDisplay }
        )

        val remainingCount = planList.count { !it.isCompleted }
        val currentHour = java.time.LocalTime.now().hour
        val overdueCount = planList.count { item ->
            !item.isCompleted && when (item) {
                is TodayPlanItem.ScheduledMedication -> item.timeLabel == "Morning" && currentHour >= 12
                is TodayPlanItem.ScheduledReminder -> item.reminder.fixedHour < currentHour
                is TodayPlanItem.ScheduledHabit -> false
            }
        }

        val summaryStr = when {
            remainingCount > 0 -> {
                "$remainingCount item${if (remainingCount > 1) "s" else ""} remaining${if (overdueCount > 0) " · $overdueCount overdue" else ""}"
            }
            planList.isNotEmpty() -> "Everything planned for today is complete"
            else -> "No plans recorded today"
        }

        // Clean out legacy NEEDS_ATTENTION section identifier from user settings if present
        val cleanHiddenSections = hiddenSections.filter { it != "NEEDS_ATTENTION" }.toSet()
        val cleanSectionOrder = sectionOrder.filter { it != "NEEDS_ATTENTION" }

        TodayUiState(
            mode = todayMode,
            summaryText = summaryStr,
            remainingCount = remainingCount,
            overdueCount = overdueCount,
            needsAttentionItems = emptyList(),
            todayPlanItems = sortedPlan,
            trendsState = trendsState,
            trendsItems = trendsItems,
            primaryInsight = primaryInsight,
            hiddenSections = cleanHiddenSections,
            sectionOrder = if (cleanSectionOrder.isEmpty()) listOf("TODAY_PLAN", "HOW_IM_DOING", "TRENDS", "AI_INSIGHT", "QUICK_ACTIONS") else cleanSectionOrder,
            isOffline = false,
            isSyncFailed = false,
            errorBannerMessage = errorMsg
        )
    }.distinctUntilChanged().stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5000),
        initialValue = TodayUiState()
    )

    fun markMedicationAction(medicationId: Long, action: ActionStatus, scheduledTime: String = "Daily", snoozedUntilMs: Long? = null) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                val dateStr = todayStr
                val allMeds = medicationDao.getAllMedications().firstOrNull() ?: emptyList()
                val med = allMeds.firstOrNull { it.id == medicationId } ?: return@launch

                scheduledDoseRepository.recordDoseAction(
                    medicationUuid = med.uuid,
                    medicationId = medicationId,
                    medicationName = med.name,
                    medicationDose = med.dose,
                    scheduledDate = dateStr,
                    scheduledTime = scheduledTime,
                    action = action,
                    snoozedUntilMs = snoozedUntilMs
                )
            } catch (e: Exception) {
                _errorBanner.value = "Failed to record medication action: ${e.message}"
            }
        }
    }

    fun completeReminder(reminderId: Int, isCompleted: Boolean = true) {
        viewModelScope.launch(Dispatchers.IO) {
            try {
                preferences.setCompletedReminder(todayStr, reminderId, isCompleted)
            } catch (e: Exception) {
                _errorBanner.value = "Failed to update reminder: ${e.message}"
            }
        }
    }

    fun toggleHabit(habitId: String, isCompleted: Boolean) {
        val today = todayStr
        viewModelScope.launch(Dispatchers.IO) {
            val res = habitRepository.toggleHabitLog(habitId, today, isCompleted)
            if (res.isFailure) {
                _errorBanner.value = "Failed to update habit: ${res.exceptionOrNull()?.message}"
            }
        }
    }

    fun submitInsightFeedback(insightId: String, isHelpful: Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            val feedbackStr = if (isHelpful) "HELPFUL" else "NOT_HELPFUL"
            aiInsightDao.updateFeedback(insightId, feedbackStr)
        }
    }

    fun dismissInsight(insightId: String) {
        viewModelScope.launch(Dispatchers.IO) {
            aiInsightDao.updateDismissed(insightId, true)
        }
    }

    fun setMode(mode: String) {
        viewModelScope.launch(Dispatchers.IO) {
            preferences.setTodayMode(mode)
        }
    }

    val todaySummaryExpanded: Flow<Boolean> = preferences.todaySummaryExpanded
    val todayPlanExpanded: Flow<Boolean> = preferences.todayPlanExpanded
    val whatChangedExpanded: Flow<Boolean> = preferences.whatChangedExpanded

    fun setTodaySummaryExpanded(expanded: Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            preferences.setTodaySummaryExpanded(expanded)
        }
    }

    fun setTodayPlanExpanded(expanded: Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            preferences.setTodayPlanExpanded(expanded)
        }
    }

    fun setWhatChangedExpanded(expanded: Boolean) {
        viewModelScope.launch(Dispatchers.IO) {
            preferences.setWhatChangedExpanded(expanded)
        }
    }

    fun updateHiddenSections(hidden: Set<String>) {
        viewModelScope.launch(Dispatchers.IO) {
            preferences.setTodayHiddenSections(hidden)
        }
    }

    fun updateSectionOrder(order: List<String>) {
        viewModelScope.launch(Dispatchers.IO) {
            preferences.setTodaySectionOrder(order)
        }
    }

    fun retrySync() {
        if (_isRetryingSync.value) return
        _isRetryingSync.value = true
        viewModelScope.launch(Dispatchers.IO) {
            try {
                syncManager.syncAllData()
            } finally {
                _isRetryingSync.value = false
            }
        }
    }
}

fun TodayPlanItem.isOverdue(): Boolean {
    if (isCompleted) return false
    val now = java.time.LocalTime.now()
    return when (this) {
        is TodayPlanItem.ScheduledMedication -> {
            when (timeLabel) {
                "Morning" -> now.hour >= 12
                "Evening" -> now.hour >= 20
                "Daily" -> now.hour >= 18
                else -> false
            }
        }
        is TodayPlanItem.ScheduledReminder -> {
            val remHour = reminder.fixedHour
            val remMin = reminder.fixedMinute
            now.hour > remHour || (now.hour == remHour && now.minute > remMin)
        }
        is TodayPlanItem.ScheduledHabit -> {
            val target = habit.target_time
            if (target != null && target != "Anytime") {
                val parts = target.split(":")
                if (parts.size == 2) {
                    val hour = parts[0].toIntOrNull()
                    val min = parts[1].toIntOrNull()
                    if (hour != null && min != null) {
                        return now.hour > hour || (now.hour == hour && now.minute > min)
                    }
                }
            }
            false
        }
    }
}
