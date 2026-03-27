package com.notel.notel.worker

import android.content.Context
import androidx.hilt.work.HiltWorker
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import com.notel.notel.data.preferences.NotelPreferences
import com.notel.notel.data.repository.HabitRepository
import com.notel.notel.util.NotificationHelper
import dagger.assisted.Assisted
import dagger.assisted.AssistedInject
import kotlinx.coroutines.flow.first

@HiltWorker
class HabitReminderWorker @AssistedInject constructor(
    @Assisted context: Context,
    @Assisted params: WorkerParameters,
    private val preferences: NotelPreferences,
    private val habitRepository: HabitRepository
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        if (!preferences.loggedIn.first()) return Result.success()
        if (!preferences.habitReminderEnabled.first()) return Result.success()

        // Sync habits first to get latest state
        habitRepository.fetchHabits()
        
        val habits = habitRepository.habits.value
        val today = habitRepository.todayDateString()
        
        val anyUnchecked = habits.any { today !in it.logs }

        if (anyUnchecked) {
            NotificationHelper(applicationContext).showHabitReminder()
        }

        return Result.success()
    }
}
