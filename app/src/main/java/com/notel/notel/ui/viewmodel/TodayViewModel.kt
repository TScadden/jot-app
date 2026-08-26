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

data class TodayUiState(
    val mode: String = "SIMPLE", // "SIMPLE" or "DETAILED"
    val summaryText: String = "",
    val needsAttentionItems: List<NeedsAttentionItem> = emptyList(),
    val todayPlanItems: List<TodayPlanItem> = emptyList(),
    val whatChangedItems: List<HealthComparisonItem> = emptyList(),
    val primaryInsight: AiInsight? = null,
    val supportingEntries: List<LogEntry> = emptyList(),
    val hiddenSections: Set<String> = emptySet(),
    val sectionOrder: List<String> = listOf("TODAY_PLAN", "HOW_IM_DOING", "WHAT_CHANGED", "AI_INSIGHT", "QUICK_ACTIONS"),
    val isOffline: Boolean = false,
    val isSyncFailed: Boolean = false
)

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

    private val _completedReminders = MutableStateFlow<Set<Int>>(emptySet())
    private val _isRetryingSync = MutableStateFlow(false)
    private val _whatChanged = MutableStateFlow<List<HealthComparisonItem>>(emptyList())

    private val todayStr: String
        get() = LocalDate.now().format(DateTimeFormatter.ISO_LOCAL_DATE)

    init {
        loadHealthComparisons()
    }

    private fun loadHealthComparisons() {
        viewModelScope.launch(Dispatchers.IO) {
            val items = healthComparisonRepository.getWhatChangedComparisons(todayStr)
            _whatChanged.value = items
        }
    }

    val uiState: StateFlow<TodayUiState> = combine(
        medicationDao.getAllMedications(),
        reminderDao.getAllReminders(),
        habitRepository.habits,
        scheduledDoseOccurrenceDao.getOccurrencesForDate(todayStr),
        _completedReminders,
        _whatChanged,
        aiInsightDao.getPrimaryActiveInsight(),
        preferences.todayMode,
        preferences.todayHiddenSections,
        preferences.todaySectionOrder
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
        val completedReminders = args[4] as Set<Int>
        @Suppress("UNCHECKED_CAST")
        val whatChangedItems = args[5] as List<HealthComparisonItem>
        val primaryInsight = args[6] as? AiInsight
        val todayMode = args[7] as String
        @Suppress("UNCHECKED_CAST")
        val hiddenSections = args[8] as Set<String>
        @Suppress("UNCHECKED_CAST")
        val sectionOrder = args[9] as List<String>

        val activeMeds = medsList.filter { !it.isArchived }
        val enabledReminders = remindersList.filter { it.isEnabled }
        val currentDateStr = todayStr

        val occurrenceMap = occurrencesList.associateBy { it.occurrenceKey }

        val attentionList = mutableListOf<NeedsAttentionItem>()

        // 1. Scheduled medications
        activeMeds.forEach { med ->
            val times = if (med.timesPerDay > 1) listOf("Morning", "Evening") else listOf("Daily")
            times.forEach { timeLabel ->
                val key = "med_${med.id}_${currentDateStr}_${timeLabel}"
                val occ = occurrenceMap[key]
                val status = when (occ?.status) {
                    "TAKEN" -> ActionStatus.TAKEN
                    "SKIPPED" -> ActionStatus.SKIPPED
                    "SNOOZED" -> ActionStatus.SNOOZED
                    else -> ActionStatus.PENDING
                }

                if (status == ActionStatus.PENDING) {
                    attentionList.add(
                        NeedsAttentionItem(
                            id = key,
                            title = med.name,
                            typeText = "Medication ($timeLabel)",
                            detailText = if (med.dose.isNotBlank()) "Dose: ${med.dose} • ${med.frequency}" else med.frequency,
                            itemType = NeedsAttentionItem.ItemType.MEDICATION,
                            medication = med,
                            scheduledTime = timeLabel,
                            currentStatus = status
                        )
                    )
                }
            }
        }

        // 2. Reminders
        enabledReminders.forEach { rem ->
            if (!completedReminders.contains(rem.id)) {
                attentionList.add(
                    NeedsAttentionItem(
                        id = "rem_${rem.id}",
                        title = rem.title,
                        typeText = "Reminder",
                        detailText = String.format("Due %02d:%02d", rem.fixedHour, rem.fixedMinute),
                        itemType = NeedsAttentionItem.ItemType.REMINDER,
                        reminder = rem
                    )
                )
            }
        }

        // 3. Habits
        habitsList.forEach { habit ->
            val isCheckedToday = habit.logs.contains(currentDateStr)
            if (!isCheckedToday) {
                attentionList.add(
                    NeedsAttentionItem(
                        id = "habit_${habit.id}",
                        title = habit.title,
                        typeText = "Habit",
                        detailText = "Target: ${habit.target_time ?: "Anytime"}",
                        itemType = NeedsAttentionItem.ItemType.HABIT,
                        habit = habit
                    )
                )
            }
        }

        // Today's Plan
        val planList = mutableListOf<TodayPlanItem>()

        activeMeds.forEach { med ->
            val times = if (med.timesPerDay > 1) listOf("Morning", "Evening") else listOf("Daily")
            times.forEach { timeLabel ->
                val key = "med_${med.id}_${currentDateStr}_${timeLabel}"
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
            val isDone = completedReminders.contains(rem.id)
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

        val medCount = activeMeds.size
        val remCount = enabledReminders.size
        val habitCount = habitsList.size
        val summaryStr = buildString {
            if (medCount == 0 && remCount == 0 && habitCount == 0) {
                append("Your schedule for today is clear.")
            } else {
                append("Today you have ")
                val parts = mutableListOf<String>()
                if (medCount > 0) parts.add("$medCount scheduled medication${if (medCount > 1) "s" else ""}")
                if (remCount > 0) parts.add("$remCount reminder${if (remCount > 1) "s" else ""}")
                if (habitCount > 0) parts.add("$habitCount habit${if (habitCount > 1) "s" else ""}")
                append(parts.joinToString(", "))
                append(".")
            }
        }

        TodayUiState(
            mode = todayMode,
            summaryText = summaryStr,
            needsAttentionItems = attentionList,
            todayPlanItems = sortedPlan,
            whatChangedItems = whatChangedItems,
            primaryInsight = primaryInsight,
            hiddenSections = hiddenSections,
            sectionOrder = sectionOrder,
            isOffline = false,
            isSyncFailed = false
        )
    }.stateIn(
        scope = viewModelScope,
        started = SharingStarted.WhileSubscribed(5000),
        initialValue = TodayUiState()
    )

    fun markMedicationAction(medicationId: Long, action: ActionStatus, scheduledTime: String = "Daily", snoozedUntilMs: Long? = null) {
        viewModelScope.launch(Dispatchers.IO) {
            val dateStr = todayStr
            val allMeds = medicationDao.getAllMedications().firstOrNull() ?: emptyList()
            val med = allMeds.firstOrNull { it.id == medicationId } ?: return@launch

            scheduledDoseRepository.recordDoseAction(
                medicationId = medicationId,
                medicationName = med.name,
                medicationDose = med.dose,
                scheduledDate = dateStr,
                scheduledTime = scheduledTime,
                action = action,
                snoozedUntilMs = snoozedUntilMs
            )
        }
    }

    fun completeReminder(reminderId: Int) {
        _completedReminders.update { current ->
            current + reminderId
        }
    }

    fun toggleHabit(habitId: String, isCompleted: Boolean) {
        val today = LocalDate.now().format(DateTimeFormatter.ISO_LOCAL_DATE)
        viewModelScope.launch(Dispatchers.IO) {
            habitRepository.toggleHabitLog(habitId, today, isCompleted)
            habitRepository.fetchHabits()
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
