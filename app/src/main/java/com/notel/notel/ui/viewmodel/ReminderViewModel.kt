package com.notel.notel.ui.viewmodel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.notel.notel.data.local.entity.Reminder
import com.notel.notel.data.repository.ReminderRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class ReminderViewModel @Inject constructor(
    private val repository: ReminderRepository
) : ViewModel() {

    val reminders: StateFlow<List<Reminder>> = repository.reminders
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5000), emptyList())

    fun addReminder(
        title: String,
        type: String,
        fixedHour: Int = 12,
        fixedMinute: Int = 0,
        intervalHours: Int = 2,
        intervalMinutes: Int = 0,
        startHour: Int = 8,
        startMinute: Int = 0,
        endHour: Int = 21,
        endMinute: Int = 0,
        daysOfWeekConfig: String = ""
    ) {
        if (title.isBlank()) return
        viewModelScope.launch {
            repository.addReminder(
                Reminder(
                    title           = title.trim(),
                    type            = type,
                    fixedHour       = fixedHour,
                    fixedMinute     = fixedMinute,
                    intervalHours   = intervalHours,
                    intervalMinutes = intervalMinutes,
                    startHour       = startHour,
                    startMinute     = startMinute,
                    endHour         = endHour,
                    endMinute       = endMinute,
                    daysOfWeekConfig = daysOfWeekConfig
                )
            )
        }
    }

    fun deleteReminder(reminder: Reminder) {
        viewModelScope.launch { repository.deleteReminder(reminder) }
    }

    fun toggleEnabled(reminder: Reminder) {
        viewModelScope.launch { repository.toggleEnabled(reminder) }
    }
}
