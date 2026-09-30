package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.remote.HabitDtoModel
import com.notel.notel.data.repository.HabitRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class HabitViewModel @Inject constructor(
    private val habitRepository: HabitRepository
) : ViewModel() {

    val habits: StateFlow<List<HabitDtoModel>> = habitRepository.habits
    val isLoading: StateFlow<Boolean> = habitRepository.isLoading
    val error: StateFlow<String?> = habitRepository.error

    init {
        loadHabits()
    }

    fun loadHabits() {
        viewModelScope.launch {
            habitRepository.fetchHabits()
        }
    }

    fun addHabit(title: String, targetTime: String = "Anytime") {
        if (title.isBlank()) return
        viewModelScope.launch {
            val result = habitRepository.createHabit(title.trim(), targetTime)
            if (result.isSuccess) {
                // Re-fetch to get server-assigned ID and confirm persistence
                habitRepository.fetchHabits()
            }
        }
    }

    fun deleteHabit(habitId: String) {
        viewModelScope.launch {
            habitRepository.deleteHabit(habitId)
            habitRepository.fetchHabits()
        }
    }

    fun toggleHabit(habitId: String, isCompleted: Boolean) {
        val today = habitRepository.todayDateString()
        viewModelScope.launch {
            habitRepository.toggleHabitLog(habitId, today, isCompleted)
        }
    }

    fun isCheckedToday(habit: HabitDtoModel): Boolean {
        val today = habitRepository.todayDateString()
        return today in habit.logs
    }

    fun getStreak(habit: HabitDtoModel): Int {
        return habitRepository.calculateStreak(habit.logs)
    }

    /** One day in the 7 day pacing strip, oldest first. */
    data class HabitDayMark(
        val dayLabel: String,
        val completed: Boolean,
        val isToday: Boolean
    )

    /**
     * Last 7 days ending today, oldest first. Pure local read of the habit's
     * already synced log dates (yyyy-MM-dd strings); no network, no server writes.
     */
    fun getLast7DayMarks(habit: HabitDtoModel): List<HabitDayMark> {
        val today = java.time.LocalDate.now()
        val logDates = habit.logs.toSet()
        val labelFmt = java.time.format.DateTimeFormatter.ofPattern("E", java.util.Locale.getDefault())
        return (6 downTo 0).map { daysBack ->
            val date = today.minusDays(daysBack.toLong())
            val label = date.format(labelFmt).take(1).uppercase(java.util.Locale.getDefault())
            HabitDayMark(
                dayLabel = label,
                completed = date.toString() in logDates,
                isToday = daysBack == 0
            )
        }
    }

    fun getOverallStreak(): Int {
        return habitRepository.calculateOverallStreak(habits.value)
    }

    fun clearHabitData() {
        viewModelScope.launch {
            habitRepository.clearHabitData()
            loadHabits()
        }
    }
}
